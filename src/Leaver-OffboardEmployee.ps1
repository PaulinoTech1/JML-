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
        but -Force is intended for automation with an approved change record,
        not for casual use.
      - Order of operations is deliberate and documented below.

    Order of operations:
      1. Revoke all refresh sessions/tokens (kills active access first).
      2. Disable the account (blocks new sign-ins).
      3. Remove all direct group memberships.
      4. Remove all licenses.
      5. Stamp employeeLeaveDateTime.
      6. Optionally wipe enrolled mobile devices (-IncludeDevices).

    Mailbox handling is intentionally OUT OF SCOPE for the Graph-only core:
    converting to a shared mailbox or setting forwarding requires Exchange
    Online. See docs/RUNBOOK.md for the manual step.
.EXAMPLE
    # Dry run: show the full offboarding plan
    ./Leaver-OffboardEmployee.ps1 -UserPrincipalName 'ada.lovelace@contoso.com' -Interactive
.EXAMPLE
    # Live with typed confirmation
    ./Leaver-OffboardEmployee.ps1 -UserPrincipalName 'ada.lovelace@contoso.com' -Apply
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UserPrincipalName,
    [datetime]$LastDay = (Get-Date).Date,
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..' 'config' 'lifecycle-config.json'),
    [string]$LogDirectory = (Join-Path $PSScriptRoot '..' 'logs'),
    [switch]$Interactive,
    [switch]$IncludeDevices,
    [switch]$Apply,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'modules' 'IdentityLifecycle.Common.psm1') -Force
Import-Module Microsoft.Graph.Users -ErrorAction Stop
Import-Module Microsoft.Graph.Groups -ErrorAction Stop

Set-LifecycleMode -Apply $Apply.IsPresent
$run = Initialize-LifecycleRun -ScriptName 'Leaver-OffboardEmployee' -LogDirectory $LogDirectory
Write-Host ("Run {0} | dryRun={1} | audit: {2}" -f $run.RunId, $run.DryRun, $run.AuditLogPath) -ForegroundColor Cyan

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
    if ($Interactive) { Connect-LifecycleGraph -Interactive } else { Connect-LifecycleGraph }
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

    # --- 6. Optional: wipe enrolled mobile devices ---
    if ($IncludeDevices) {
        Import-Module Microsoft.Graph.DeviceManagement -ErrorAction Stop
        $devices = Get-MgUserManagedDevice -UserId $user.Id -All -ErrorAction Stop
        Write-Host ("Wiping {0} enrolled devices." -f $devices.Count) -ForegroundColor Red
        foreach ($device in $devices) {
            Invoke-LifecycleStep -Action 'Device.Wipe' -Target ("{0} ({1})" -f $device.DeviceName, $device.Id) -ScriptBlock {
                Invoke-MgWipeUserManagedDevice -UserId $user.Id -ManagedDeviceId $device.Id
            } | Out-Null
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
