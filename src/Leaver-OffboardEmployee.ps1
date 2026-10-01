<#
.SYNOPSIS
    Offboards an employee from Entra ID: kills sessions, disables the
    account, strips access, removes licenses.
.DESCRIPTION
    LEAVER half of joiner/mover/leaver lifecycle automation.

    THIS IS THE DESTRUCTIVE SCRIPT. Guardrails:
      - DRY-RUN BY DEFAULT. Without -Apply nothing is touched.
      - With -Apply, a TYPED confirmation is required
        ("DISABLE user@domain"). -Force skips the prompt for scheduled runs,
        but -Force REQUIRES -ChangeTicket with the approved change record
        reference, which is written to the audit log. -Force without a ticket
        fails closed.
      - Order of operations is deliberate and documented below.

    Order of operations:
      1. Revoke all refresh sessions/tokens (kills active access first).
      2. Disable the account (blocks new sign-ins).
      3. Remove all direct group memberships.
      4. Remove all licenses.
      5. Stamp employeeLeaveDateTime.

    Mailbox handling is intentionally OUT OF SCOPE for the Graph-only core:
    converting to a shared mailbox or setting forwarding requires Exchange
    Online. See docs/RUNBOOK.md for the manual step.

    Device wipe is OPTIONAL and separately gated: -IncludeDevices wipes the
    user's Intune-enrolled devices, but it REQUIRES -ChangeTicket with the
    approved change record reference (in every mode, including interactive),
    and the authorization is written to the audit log. Remote wipe is a
    destructive, separately-permissioned Intune action: a wipe issued
    against the wrong account is unrecoverable, so it is never part of the
    default offboarding flow. Only enable it when your process calls for
    it (e.g. lost or stolen devices), and only the DeviceManagement
    scopes documented in docs/APP_REGISTRATION.md are needed for it.
.EXAMPLE
    # Dry run: show the full offboarding plan
    ./Leaver-OffboardEmployee.ps1 -UserPrincipalName 'ada.lovelace@contoso.com' -Interactive
.EXAMPLE
    # Live with typed confirmation
    ./Leaver-OffboardEmployee.ps1 -UserPrincipalName 'ada.lovelace@contoso.com' -Apply
.EXAMPLE
    # Scheduled run: -Force requires the approved change record reference
    ./Leaver-OffboardEmployee.ps1 -UserPrincipalName 'ada.lovelace@contoso.com' -Apply -Force -ChangeTicket 'CHG-1234'
.EXAMPLE
    # Scheduled run with device wipe: ticket is mandatory for the wipe
    ./Leaver-OffboardEmployee.ps1 -UserPrincipalName 'ada.lovelace@contoso.com' -Apply -Force -ChangeTicket 'CHG-1234' -IncludeDevices
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UserPrincipalName,
    [datetime]$LastDay = (Get-Date).Date,
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..' 'config' 'lifecycle-config.json'),
    [string]$LogDirectory = (Join-Path $PSScriptRoot '..' 'logs'),
    [switch]$Interactive,
    [switch]$Apply,
    [switch]$Force,
    [string]$ChangeTicket = '',
    [switch]$IncludeDevices
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'modules' 'IdentityLifecycle.Common.psm1') -Force
Import-Module Microsoft.Graph.Users -ErrorAction Stop
Import-Module Microsoft.Graph.Groups -ErrorAction Stop

# Least-privilege scopes for the leaver's job only (interactive/delegated mode).
# App-only permissions come from the app registration; see docs/APP_REGISTRATION.md.
$leaverScopes = @('User.ReadWrite.All', 'GroupMember.ReadWrite.All', 'Directory.Read.All')
if ($IncludeDevices.IsPresent) {
    # Device wipe is a separately-permissioned Intune action: request the
    # wipe scope only when the wipe is actually requested.
    $leaverScopes += 'DeviceManagementManagedDevices.PrivilegedOperations.All'
}

Set-LifecycleMode -Apply $Apply.IsPresent
$run = Initialize-LifecycleRun -ScriptName 'Leaver-OffboardEmployee' -LogDirectory $LogDirectory
Write-Host ("Run {0} | dryRun={1} | audit: {2}" -f $run.RunId, $run.DryRun, $run.AuditLogPath) -ForegroundColor Cyan

# Authorization gate: unattended offboarding requires a change record.
Assert-LeaverForceAuthorization -Force $Force.IsPresent -ChangeTicket $ChangeTicket
if ($Force.IsPresent) {
    Write-LifecycleAudit -Action 'Leaver.ForceAuthorization' -Target $UserPrincipalName -Result 'Executed' `
        -Detail ("changeTicket={0}" -f $ChangeTicket) | Out-Null
}

# Device-wipe gate: wiping enrolled devices is destructive and separately
# permissioned, so it is never implicit. It requires an explicit
# -ChangeTicket reference in EVERY mode (interactive included), and the
# authorization is audit-logged with the ticket.
if ($IncludeDevices.IsPresent) {
    if ([string]::IsNullOrWhiteSpace($ChangeTicket)) {
        throw "Device wipe requested (-IncludeDevices) without -ChangeTicket. Remote wipe requires an approved change record reference; re-run with -ChangeTicket '<ticket>'."
    }
    Write-LifecycleAudit -Action 'Leaver.DeviceWipeAuthorization' -Target $UserPrincipalName -Result 'Executed' `
        -Detail ("changeTicket={0}" -f $ChangeTicket) | Out-Null
}

if ($Apply.IsPresent -and -not $Force.IsPresent) {
    $expected = "DISABLE $UserPrincipalName"
    Write-Host ("Type '{0}' to confirm offboarding. Anything else aborts." -f $expected) -ForegroundColor Red
    $answer = Read-Host 'Confirm'
    if ($answer -ne $expected) {
        Write-Host 'Confirmation did not match. Aborting; nothing was changed.' -ForegroundColor Yellow
        Write-LifecycleAudit -Action 'Leaver.Abort' -Target $UserPrincipalName -Result 'Skipped' -Detail 'Typed confirmation did not match.' | Out-Null
        return
    }
}

try {
    if ($Interactive) { Connect-LifecycleGraph -Interactive -Scopes $leaverScopes } else { Connect-LifecycleGraph -Scopes $leaverScopes }
    $null = Get-LifecycleConfig -Path $ConfigPath  # validated for fail-closed behavior

    $user = Get-MgUser -Filter ("userPrincipalName eq '{0}'" -f $UserPrincipalName) -ErrorAction Stop
    if (-not $user) { throw "User '$UserPrincipalName' not found." }

    # --- 1. Revoke sessions FIRST: kill active access before anything else ---
    Invoke-LifecycleStep -Action 'User.RevokeSessions' -Target $UserPrincipalName `
        -Detail 'Invalidates all refresh tokens / sessions.' -ScriptBlock {
            Revoke-MgUserSignInSession -UserId $user.Id | Out-Null
        } | Out-Null

    # --- 2. Disable the account ---
    if ($user.AccountEnabled) {
        Invoke-LifecycleStep -Action 'User.Disable' -Target $UserPrincipalName -ScriptBlock {
            Update-MgUser -UserId $user.Id -AccountEnabled:$false
        } | Out-Null
    }
    else {
        Write-LifecycleAudit -Action 'User.Disable' -Target $UserPrincipalName -Result 'Skipped' -Detail 'Account already disabled.' | Out-Null
    }

    # --- 3. Remove all direct group memberships ---
    $memberOf = Get-MgUserMemberOf -UserId $user.Id -All -ErrorAction Stop
    $groups = @($memberOf | Where-Object { $_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.group' })
    Write-Host ("Removing {0} direct group memberships." -f $groups.Count)
    foreach ($g in $groups) {
        $groupId = $g.Id
        $groupName = $g.AdditionalProperties['displayName']
        Invoke-LifecycleStep -Action 'GroupMember.Remove' -Target "$UserPrincipalName -> $groupName" -ScriptBlock {
            Remove-MgGroupMemberByRef -GroupId $groupId -DirectoryObjectId $user.Id
        } | Out-Null
    }

    # --- 4. Remove all licenses ---
    $licenseDetails = Get-MgUserLicenseDetail -UserId $user.Id -ErrorAction Stop
    if ($licenseDetails.Count -gt 0) {
        $skuIds = @($licenseDetails | ForEach-Object { $_.SkuId })
        Invoke-LifecycleStep -Action 'License.RemoveAll' -Target $UserPrincipalName `
            -Detail ("count={0}" -f $skuIds.Count) -ScriptBlock {
                Set-MgUserLicense -UserId $user.Id -AddLicenses @() -RemoveLicenses $skuIds
            } | Out-Null
    }
    else {
        Write-LifecycleAudit -Action 'License.RemoveAll' -Target $UserPrincipalName -Result 'Skipped' -Detail 'No licenses assigned.' | Out-Null
    }

    # --- 5. Stamp the leave date ---
    Invoke-LifecycleStep -Action 'User.SetLeaveDate' -Target $UserPrincipalName `
        -Detail ("employeeLeaveDateTime={0:yyyy-MM-dd}" -f $LastDay) -ScriptBlock {
            Update-MgUser -UserId $user.Id -EmployeeLeaveDateTime $LastDay.ToUniversalTime().ToString('o')
        } | Out-Null

    # --- 6. Optional, gated: wipe enrolled mobile devices ---
    # Reached only when -IncludeDevices was passed AND a -ChangeTicket was
    # provided (enforced above). Dry-run mode plans but never executes.
    if ($IncludeDevices.IsPresent) {
        Import-Module Microsoft.Graph.DeviceManagement -ErrorAction Stop
        $devices = @(Get-MgUserManagedDevice -UserId $user.Id -All -ErrorAction Stop)
        Write-Host ("Wiping {0} enrolled devices." -f $devices.Count) -ForegroundColor Red
        foreach ($device in $devices) {
            $deviceId = $device.Id
            $deviceName = $device.DeviceName
            Invoke-LifecycleStep -Action 'Device.Wipe' -Target ("{0} ({1})" -f $deviceName, $deviceId) `
                -Detail ("changeTicket={0}" -f $ChangeTicket) -ScriptBlock {
                    Invoke-MgWipeUserManagedDevice -UserId $user.Id -ManagedDeviceId $deviceId
                } | Out-Null
        }
        if ($devices.Count -eq 0) {
            Write-LifecycleAudit -Action 'Device.Wipe' -Target $UserPrincipalName -Result 'Skipped' -Detail 'No enrolled devices found.' | Out-Null
        }
    }

    Write-Host ("Done. Audit log: {0}" -f $run.AuditLogPath) -ForegroundColor Cyan
    Write-Host 'Follow docs/RUNBOOK.md for the mailbox step (shared mailbox conversion / forwarding via Exchange Online).' -ForegroundColor Yellow
    if ($run.DryRun) {
        Write-Host 'This was a DRY RUN. Re-run with -Apply to perform these actions.' -ForegroundColor Yellow
    }
}
finally {
    Disconnect-LifecycleGraph
}
