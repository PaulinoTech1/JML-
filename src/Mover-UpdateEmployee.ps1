<#
.SYNOPSIS
    Reconciles an employee's access after a department or role change.
.DESCRIPTION
    MOVER half of joiner/mover/leaver lifecycle automation.

    DRY-RUN BY DEFAULT. Without -Apply, the full add/remove plan is computed
    and logged as Planned; nothing in Entra ID is touched.

    Reconciliation rules:
      - Groups/licenses in the target role mapping but missing are ADDED.
      - Groups/licenses the user has that are inside the managed universe
        (every group/license referenced by ANY role mapping) but NOT in the
        target mapping are REMOVED.
      - Anything assigned manually outside lifecycle management is NEVER
        removed. The mover does not nuke access it did not grant.
    Idempotent: re-running with no changes produces an empty plan.
.EXAMPLE
    # Dry run: show the plan
    ./Mover-UpdateEmployee.ps1 -UserPrincipalName 'ada.lovelace@contoso.com' -NewDepartment 'IT' -NewJobTitle 'Sysadmin' -Interactive
.EXAMPLE
    # Live
    ./Mover-UpdateEmployee.ps1 -UserPrincipalName 'ada.lovelace@contoso.com' -NewDepartment 'IT' -Apply
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UserPrincipalName,
    [Parameter(Mandatory)][string]$NewDepartment,
    [string]$NewJobTitle = '',
    [string]$NewManagerUPN = '',
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
$run = Initialize-LifecycleRun -ScriptName 'Mover-UpdateEmployee' -LogDirectory $LogDirectory
Write-Host ("Run {0} | dryRun={1} | audit: {2}" -f $run.RunId, $run.DryRun, $run.AuditLogPath) -ForegroundColor Cyan

try {
    if ($Interactive) { Connect-LifecycleGraph -Interactive } else { Connect-LifecycleGraph }

    $null = Get-LifecycleConfig -Path $ConfigPath  # validated; fail-closed on bad config
    $mapping = Get-RoleMapping -Path $RoleMapPath -Department $NewDepartment
    $managedUniverse = Get-ManagedGroupUniverse -Path $RoleMapPath

    $user = Get-MgUser -Filter ("userPrincipalName eq '{0}'" -f $UserPrincipalName) -ErrorAction Stop
    if (-not $user) { throw "User '$UserPrincipalName' not found." }

    # --- Group reconciliation ---
    $memberOf = Get-MgUserMemberOf -UserId $user.Id -All -ErrorAction Stop
    $currentGroups = @($memberOf | Where-Object { $_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.group' } |
        ForEach-Object { $_.AdditionalProperties['displayName'] } | Where-Object { $_ })

    $groupPlan = Compare-MembershipPlan -Current $currentGroups -Target $mapping['groups'] -ManagedUniverse $managedUniverse
    Write-Host ("Groups: +{0} add, -{1} remove, ={2} keep" -f $groupPlan.Add.Count, $groupPlan.Remove.Count, $groupPlan.Keep.Count)

    foreach ($groupName in $groupPlan.Add) {
        $group = Get-MgGroup -Filter ("displayName eq '{0}'" -f $groupName) -ErrorAction Stop
        if (-not $group) {
            Write-Warning "Group '$groupName' not found in tenant. Skipped."
            continue
        }
        Invoke-LifecycleStep -Action 'GroupMember.Add' -Target "$UserPrincipalName -> $($group.DisplayName)" -ScriptBlock {
            New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $user.Id
        } | Out-Null
    }
    foreach ($groupName in $groupPlan.Remove) {
        $group = Get-MgGroup -Filter ("displayName eq '{0}'" -f $groupName) -ErrorAction Stop
        if (-not $group) { continue }
        Invoke-LifecycleStep -Action 'GroupMember.Remove' -Target "$UserPrincipalName -> $($group.DisplayName)" `
            -Detail 'Removed: in managed universe, not in target role mapping.' -ScriptBlock {
                Remove-MgGroupMemberByRef -GroupId $group.Id -DirectoryObjectId $user.Id
            } | Out-Null
    }

    # --- License reconciliation ---
    $licenseDetails = Get-MgUserLicenseDetail -UserId $user.Id -ErrorAction Stop
    $skus = Get-MgSubscribedSku -ErrorAction Stop
    $partNumberOf = @{}
    foreach ($sku in $skus) { $partNumberOf[$sku.SkuId] = $sku.SkuPartNumber }
    $currentLicenses = @($licenseDetails | ForEach-Object { $partNumberOf[$_.SkuId] } | Where-Object { $_ })

    $allManagedLicenses = @(
        (Get-Content -Path $RoleMapPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10 -AsHashtable).Values |
            ForEach-Object { $_['licenses'] } | Select-Object -Unique
    )
    $licensePlan = Compare-MembershipPlan -Current $currentLicenses -Target $mapping['licenses'] -ManagedUniverse $allManagedLicenses
    Write-Host ("Licenses: +{0} add, -{1} remove, ={2} keep" -f $licensePlan.Add.Count, $licensePlan.Remove.Count, $licensePlan.Keep.Count)

    if ($licensePlan.Add.Count -gt 0) {
        $addLicenses = @($licensePlan.Add | ForEach-Object {
            $partNumber = $_
            $sku = $skus | Where-Object { $_.SkuPartNumber -eq $partNumber }
            if ($sku) { @{ SkuId = $sku.SkuId } }
        } | Where-Object { $_ })
        if ($addLicenses.Count -gt 0) {
            Invoke-LifecycleStep -Action 'License.Assign' -Target $UserPrincipalName `
                -Detail ("add={0}" -f ($licensePlan.Add -join ',')) -ScriptBlock {
                    Set-MgUserLicense -UserId $user.Id -AddLicenses $addLicenses -RemoveLicenses @()
                } | Out-Null
        }
    }
    if ($licensePlan.Remove.Count -gt 0) {
        $removeSkuIds = @($licensePlan.Remove | ForEach-Object {
            $partNumber = $_
            ($skus | Where-Object { $_.SkuPartNumber -eq $partNumber }).SkuId
        } | Where-Object { $_ })
        if ($removeSkuIds.Count -gt 0) {
            Invoke-LifecycleStep -Action 'License.Remove' -Target $UserPrincipalName `
                -Detail ("remove={0}" -f ($licensePlan.Remove -join ',')) -ScriptBlock {
                    Set-MgUserLicense -UserId $user.Id -AddLicenses @() -RemoveLicenses $removeSkuIds
                } | Out-Null
        }
    }

    # --- Attribute updates ---
    $updates = @{}
    if ($user.Department -ne $NewDepartment) { $updates['Department'] = $NewDepartment }
    if ($NewJobTitle -and $user.JobTitle -ne $NewJobTitle) { $updates['JobTitle'] = $NewJobTitle }
    if ($updates.Count -gt 0) {
        Invoke-LifecycleStep -Action 'User.UpdateAttributes' -Target $UserPrincipalName `
            -Detail (($updates.GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key, $_.Value }) -join ' ') -ScriptBlock {
                Update-MgUser -UserId $user.Id -Department $NewDepartment -JobTitle $NewJobTitle
            } | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($NewManagerUPN)) {
        $manager = Get-MgUser -Filter ("userPrincipalName eq '{0}'" -f $NewManagerUPN) -ErrorAction Stop
        if ($manager) {
            Invoke-LifecycleStep -Action 'User.SetManager' -Target "$UserPrincipalName -> $NewManagerUPN" -ScriptBlock {
                Set-MgUserManagerByRef -UserId $user.Id -BodyParameter @{ '@odata.id' = ("https://graph.microsoft.com/v1.0/users/{0}" -f $manager.Id) }
            } | Out-Null
        }
    }

    $totalChanges = $groupPlan.Add.Count + $groupPlan.Remove.Count + $licensePlan.Add.Count + $licensePlan.Remove.Count + $updates.Count
    if ($totalChanges -eq 0) {
        Write-Host 'No changes required. Access already matches the target role mapping.' -ForegroundColor Green
    }
    Write-Host ("Done. Audit log: {0}" -f $run.AuditLogPath) -ForegroundColor Cyan
    if ($run.DryRun) {
        Write-Host 'This was a DRY RUN. Re-run with -Apply to perform these actions.' -ForegroundColor Yellow
    }
}
finally {
    Disconnect-LifecycleGraph
}
