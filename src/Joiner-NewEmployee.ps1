<#
.SYNOPSIS
    Provisions a new employee in Entra ID: account, groups, licenses, manager.
.DESCRIPTION
    JOINER half of joiner/mover/leaver lifecycle automation.

    DRY-RUN BY DEFAULT. Without -Apply, every step is logged as Planned and
    nothing in Entra ID is touched. Run it once without -Apply, review the
    audit log, then run with -Apply.

    Idempotent: if the UPN already exists the script skips creation and
    reports the existing account instead of failing or duplicating.

    Account enablement: if -StartDate is in the future the account is created
    DISABLED and must be enabled on the start date (see docs/RUNBOOK.md).
    The temporary password is generated with a CSPRNG and is NEVER written
    to the audit log or console. Hand it to HR through a secure channel.
.EXAMPLE
    # Dry run (default): show what would happen
    ./Joiner-NewEmployee.ps1 -FirstName Ada -LastName Lovelace -Department Engineering -JobTitle 'Sysadmin' -ManagerUPN 'boss@contoso.com' -Interactive
.EXAMPLE
    # Live run with app-only auth (secret from env var)
    $env:LIFECYCLE_TENANT_ID='...'; $env:LIFECYCLE_CLIENT_ID='...'; $env:LIFECYCLE_CLIENT_SECRET='...'
    ./Joiner-NewEmployee.ps1 -FirstName Ada -LastName Lovelace -Department Engineering -Apply
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$FirstName,
    [Parameter(Mandatory)][string]$LastName,
    [Parameter(Mandatory)][string]$Department,
    [string]$JobTitle = '',
    [string]$ManagerUPN = '',
    [datetime]$StartDate = (Get-Date).Date,
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..' 'config' 'lifecycle-config.json'),
    [string]$RoleMapPath = (Join-Path $PSScriptRoot '..' 'config' 'role-mappings.json'),
    [string]$LogDirectory = (Join-Path $PSScriptRoot '..' 'logs'),
    [switch]$Interactive,
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'modules' 'IdentityLifecycle.Common.psm1') -Force
Import-Module Microsoft.Graph.Users -ErrorAction Stop
Import-Module Microsoft.Graph.Groups -ErrorAction Stop

Set-LifecycleMode -Apply $Apply.IsPresent
$run = Initialize-LifecycleRun -ScriptName 'Joiner-NewEmployee' -LogDirectory $LogDirectory
Write-Host ("Run {0} | dryRun={1} | audit: {2}" -f $run.RunId, $run.DryRun, $run.AuditLogPath) -ForegroundColor Cyan

try {
    if ($Interactive) { Connect-LifecycleGraph -Interactive } else { Connect-LifecycleGraph }

    $config  = Get-LifecycleConfig -Path $ConfigPath
    $mapping = Get-RoleMapping -Path $RoleMapPath -Department $Department

    $upn = New-LifecycleUpn -FirstName $FirstName -LastName $LastName -Pattern $config.upnPattern -Domain $config.domain
    Write-Host "Target UPN: $upn"

    # --- Idempotency: never create a duplicate ---
    $existing = Get-MgUser -Filter ("userPrincipalName eq '{0}'" -f $upn) -ConsistencyLevel eventual -CountVariable _count -ErrorAction Stop
    if ($existing) {
        Write-LifecycleAudit -Action 'User.Create' -Target $upn -Result 'Skipped' -Detail 'UPN already exists; no duplicate created.' | Out-Null
        Write-Host "User $upn already exists. Nothing to do (idempotent skip)." -ForegroundColor Yellow
        return
    }

    $enableNow = $StartDate.Date -le (Get-Date).Date
    $tempPassword = New-TemporaryPassword

    # --- 1. Create the account ---
    $newUser = Invoke-LifecycleStep -Action 'User.Create' -Target $upn `
        -Detail ("department={0} title={1} enabled={2}" -f $Department, $JobTitle, $enableNow) `
        -ScriptBlock {
            New-MgUser -UserPrincipalName $upn `
                -DisplayName ("{0} {1}" -f $FirstName.Trim(), $LastName.Trim()) `
                -GivenName $FirstName.Trim() -Surname $LastName.Trim() `
                -MailNickname ($upn.Split('@')[0]) `
                -Department $Department -JobTitle $JobTitle `
                -UsageLocation $config.usageLocation `
                -AccountEnabled:$enableNow `
                -PasswordProfile @{ Password = $tempPassword; ForceChangePasswordNextSignIn = $true }
        }

    # In live mode the new user object comes back from the script block; in
    # dry-run mode there is no object, so resolve group/license targets by name.
    if ($newUser) { $targetUserId = $newUser.Id } else { $targetUserId = $null }

    # --- 2. Group memberships from the role mapping ---
    foreach ($groupName in $mapping['groups']) {
        $group = Get-MgGroup -Filter ("displayName eq '{0}'" -f $groupName) -ErrorAction Stop
        if (-not $group) {
            Write-LifecycleAudit -Action 'GroupMember.Add' -Target "$upn -> $groupName" -Result 'Failed' -Detail 'Group not found in tenant.' | Out-Null
            Write-Warning "Group '$groupName' not found in tenant. Skipped."
            continue
        }
        Invoke-LifecycleStep -Action 'GroupMember.Add' -Target "$upn -> $($group.DisplayName)" -ScriptBlock {
            New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $targetUserId
        } | Out-Null
    }

    # --- 3. Licenses from the role mapping ---
    if ($mapping['licenses'].Count -gt 0) {
        $skus = Get-MgSubscribedSku -ErrorAction Stop
        $addLicenses = foreach ($partNumber in $mapping['licenses']) {
            $sku = $skus | Where-Object { $_.SkuPartNumber -eq $partNumber }
            if (-not $sku) {
                Write-Warning "License SKU '$partNumber' not found in tenant. Skipped."
                Write-LifecycleAudit -Action 'License.Assign' -Target "$upn -> $partNumber" -Result 'Failed' -Detail 'SKU not found in tenant.' | Out-Null
                continue
            }
            @{ SkuId = $sku.SkuId }
        }
        if ($addLicenses.Count -gt 0) {
            Invoke-LifecycleStep -Action 'License.Assign' -Target $upn `
                -Detail ("skus={0}" -f (($mapping['licenses']) -join ',')) `
                -ScriptBlock {
                    Set-MgUserLicense -UserId $targetUserId -AddLicenses $addLicenses -RemoveLicenses @()
                } | Out-Null
        }
    }

    # --- 4. Manager ---
    if (-not [string]::IsNullOrWhiteSpace($ManagerUPN)) {
        $manager = Get-MgUser -Filter ("userPrincipalName eq '{0}'" -f $ManagerUPN) -ErrorAction Stop
        if ($manager) {
            Invoke-LifecycleStep -Action 'User.SetManager' -Target "$upn -> $ManagerUPN" -ScriptBlock {
                Set-MgUserManagerByRef -UserId $targetUserId -BodyParameter @{ '@odata.id' = ("https://graph.microsoft.com/v1.0/users/{0}" -f $manager.Id) }
            } | Out-Null
        }
        else {
            Write-Warning "Manager '$ManagerUPN' not found. Skipped."
        }
    }

    if (-not $enableNow) {
        Write-Host ("Account created DISABLED (start date {0:d}). Enable on start date per docs/RUNBOOK.md." -f $StartDate) -ForegroundColor Yellow
        Write-LifecycleAudit -Action 'User.EnableDeferred' -Target $upn -Result 'Planned' -Detail ("enable on {0:yyyy-MM-dd}" -f $StartDate) | Out-Null
    }

    Write-Host ("Done. Audit log: {0}" -f $run.AuditLogPath) -ForegroundColor Cyan
    if ($run.DryRun) {
        Write-Host 'This was a DRY RUN. Re-run with -Apply to perform these actions.' -ForegroundColor Yellow
    }
    else {
        Write-Host 'REMINDER: hand the temporary password to HR through a secure channel. It was not logged.' -ForegroundColor Red
    }
}
finally {
    Disconnect-LifecycleGraph
}
