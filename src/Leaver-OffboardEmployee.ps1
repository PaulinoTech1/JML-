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
      3. Remove ALL direct group memberships (not just the managed
         universe: unlike the mover, the leaver assumes no access should
         survive. Recovery is the JSONL audit log plus manual re-adds;
         see docs/RUNBOOK.md).
      4. Remove all licenses.
      5. Stamp employeeLeaveDateTime.
      6. Optionally wipe enrolled devices (-IncludeDevices, separately gated).

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

# Fail-closed config validation first: also provides the optional
# 'changeTicketPattern' used by the gates below.
$config = Get-LifecycleConfig -Path $ConfigPath

# Authorization gate: unattended offboarding requires a change record.
Assert-LeaverForceAuthorization -Force $Force.IsPresent -ChangeTicket $ChangeTicket -TicketPattern $config.changeTicketPattern
if ($Force.IsPresent) {
    Write-LifecycleAudit -Action 'Leaver.ForceAuthorization' -Target $UserPrincipalName -Result 'Executed' `
        -Detail ("changeTicket={0}" -f $ChangeTicket) | Out-Null
}

# Device-wipe gate: wiping enrolled devices is destructive and separately
# permissioned, so it is never implicit. It requires an explicit
# -ChangeTicket reference in EVERY mode (interactive included), and the
# authorization is audit-logged with the ticket.
if ($IncludeDevices.IsPresent) {
    Assert-ChangeTicket -ChangeTicket $ChangeTicket -TicketPattern $config.changeTicketPattern -Context 'Device wipe (-IncludeDevices)'
    Write-LifecycleAudit -Action 'Leaver.DeviceWipeAuthorization' -Target $UserPrincipalName -Result 'Executed' `
        -Detail ("changeTicket={0}" -f $ChangeTicket) | Out-Null
}

if ($Apply.IsPresent -and -not $Force.IsPresent) {
    $expected = "DISABLE $UserPrincipalName"
    Write-Host ("Configured tenant: {0}" -f $config.tenantId) -ForegroundColor Cyan
    Write-Host ("Type '{0}' to confirm offboarding. Anything else aborts." -f $expected) -ForegroundColor Red
    $answer = Read-Host 'Confirm'
    if ($answer -ne $expected) {
        Write-Host 'Confirmation did not match. Aborting; nothing was changed.' -ForegroundColor Yellow
        Write-LifecycleAudit -Action 'Leaver.Abort' -Target $UserPrincipalName -Result 'Skipped' -Detail 'Typed confirmation did not match.' | Out-Null
        return
    }
}

$userLock = $null
try {
    if ($Interactive) { Connect-LifecycleGraph -TenantId $config.tenantId -Interactive -Scopes $leaverScopes } else { Connect-LifecycleGraph -TenantId $config.tenantId -Scopes $leaverScopes }

    $userMatches = @(Get-MgUser -Filter ("userPrincipalName eq '{0}'" -f (ConvertTo-GraphFilterLiteral $UserPrincipalName)) -Property 'id,accountEnabled' -ErrorAction Stop)
    if ($userMatches.Count -ne 1) { throw "Expected exactly one user for '$UserPrincipalName'; found $($userMatches.Count)." }
    $user = $userMatches[0]
    if ($Apply.IsPresent) {
        $userLock = Enter-LifecycleUserLock -TenantId $config.tenantId -UserId $user.Id
        # Do not base live decisions on a read made before ownership.
        $user = Get-MgUser -UserId $user.Id -Property 'id,accountEnabled' -ErrorAction Stop
    }

    # --- 1. Revoke sessions FIRST: kill active access before anything else ---
    Invoke-LifecycleStep -Action 'User.RevokeSessions' -Target $UserPrincipalName `
        -Detail 'Invalidates all refresh tokens / sessions.' -ScriptBlock {
            Revoke-MgUserSignInSession -UserId $user.Id | Out-Null
        } | Out-Null

    # --- 2. Disable the account ---
    # Only an explicit Boolean false proves that disabling is unnecessary.
    if ($null -eq $user.PSObject.Properties['AccountEnabled'] -or
        $user.AccountEnabled -isnot [bool] -or $user.AccountEnabled) {
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
    $licenseDetails = @(Get-MgUserLicenseDetail -UserId $user.Id -ErrorAction Stop)
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

    # --- Post-apply verification: re-query and assert the intended end state.
    # Warn, don't throw: Graph eventual consistency can lag, and a false
    # failure here must not mask the audit trail. Any mismatch needs
    # operator review, not an automatic retry.
    if ($Apply.IsPresent) {
        $recheck = Get-MgUser -UserId $user.Id -Property 'id,accountEnabled' -ErrorAction Stop
        $remainingGroups = @(Get-MgUserMemberOf -UserId $user.Id -All -ErrorAction Stop |
            Where-Object { $_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.group' })
        $knownState = $null -ne $recheck -and $null -ne $recheck.PSObject.Properties['AccountEnabled'] -and $recheck.AccountEnabled -is [bool]
        $enabledState = if ($knownState) { $recheck.AccountEnabled } else { 'unknown' }
        $verifyDetail = ("accountEnabled={0} remainingDirectGroups={1}" -f $enabledState, $remainingGroups.Count)
        if (-not $knownState -or $enabledState -ne $false -or $remainingGroups.Count -gt 0) {
            Write-Warning ("Post-apply verification FAILED: {0}. Review the audit log; the tenant may need reconciliation." -f $verifyDetail)
            Write-LifecycleAudit -Action 'Verify.OffboardState' -Target $UserPrincipalName -Result 'Failed' -Detail $verifyDetail | Out-Null
        }
        else {
            Write-LifecycleAudit -Action 'Verify.OffboardState' -Target $UserPrincipalName -Result 'Executed' -Detail $verifyDetail | Out-Null
        }
    }

    # --- Partial-failure summary. Steps are sequential with no automatic
    # rollback: rolling back a half-finished offboarding could re-enable an
    # account that must stay disabled. Reconcile from the audit log;
    # see docs/RUNBOOK.md ("Recovering from a partial failure").
    $failedSteps = Get-LifecycleFailedStepCount
    if ($failedSteps -gt 0) {
        Write-Warning ("{0} step(s) FAILED. The tenant may be partially offboarded. Reconcile from the audit log before re-running: {1}" -f $failedSteps, $run.AuditLogPath)
        Write-LifecycleAudit -Action 'Run.PartialFailure' -Target 'Leaver-OffboardEmployee' -Result 'Failed' -Detail ("failedSteps={0}" -f $failedSteps) | Out-Null
    }

    Write-Host ("Done. Audit log: {0}" -f $run.AuditLogPath) -ForegroundColor Cyan
    Write-Host 'Follow docs/RUNBOOK.md for the mailbox step (shared mailbox conversion / forwarding via Exchange Online).' -ForegroundColor Yellow
    if ($run.DryRun) {
        Write-Host 'This was a DRY RUN. Re-run with -Apply to perform these actions.' -ForegroundColor Yellow
    }
}
finally {
    try { Disconnect-LifecycleGraph }
    finally { if ($null -ne $userLock) { Exit-LifecycleUserLock -Lock $userLock } }
}
