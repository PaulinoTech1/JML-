<#
.SYNOPSIS
    Read-only access review: stale accounts, privileged roles, guests, and
    license waste. Produces CSV reports and a console summary.
.DESCRIPTION
    This script NEVER mutates anything. It is safe to run on a schedule and
    is the evidence-gathering half of a quarterly access review.

    Checks:
      1. Stale accounts: no interactive sign-in for >= StaleDays.
      2. Privileged role assignments: Global Admin, Privileged Authentication
         Admin, and other high-impact directory roles, including via groups.
      3. Guest users: age of the guest account and last sign-in.
      4. License waste: disabled accounts that still hold licenses.

    Output: one CSV per check in the report directory, plus a console table.
.EXAMPLE
    ./Review-AccessReview.ps1 -Interactive
.EXAMPLE
    ./Review-AccessReview.ps1 -StaleDays 60 -ReportDirectory ./reports
#>

[CmdletBinding()]
param(
    [int]$StaleDays = 90,
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..' 'config' 'lifecycle-config.json'),
    [string]$ReportDirectory = (Join-Path $PSScriptRoot '..' 'reports'),
    [string]$LogDirectory = (Join-Path $PSScriptRoot '..' 'logs'),
    [switch]$Interactive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'modules' 'IdentityLifecycle.Common.psm1') -Force
Import-Module Microsoft.Graph.Users -ErrorAction Stop
Import-Module Microsoft.Graph.Identity.Governance -ErrorAction Stop
Import-Module Microsoft.Graph.Reports -ErrorAction Stop

# Read-only: force dry-run semantics for the audit trail even though nothing mutates.
Set-LifecycleMode -Apply $false
$run = Initialize-LifecycleRun -ScriptName 'Review-AccessReview' -LogDirectory $LogDirectory
if (-not (Test-Path -Path $ReportDirectory)) { New-Item -ItemType Directory -Path $ReportDirectory -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

try {
    if ($Interactive) {
        Connect-LifecycleGraph -Interactive -Scopes @('User.Read.All', 'Directory.Read.All', 'RoleManagement.Read.Directory', 'AuditLog.Read.All')
    }
    else {
        Connect-LifecycleGraph -Scopes @('User.Read.All', 'Directory.Read.All', 'RoleManagement.Read.Directory', 'AuditLog.Read.All')
    }
    $null = Get-LifecycleConfig -Path $ConfigPath

    $cutoff = (Get-Date).AddDays(-$StaleDays)

    # --- 1. Stale accounts ---
    Write-Host 'Checking for stale accounts...' -ForegroundColor Cyan
    $users = Get-MgUser -All -Property 'id,userPrincipalName,displayName,accountEnabled,createdDateTime,signInActivity,userType' -ErrorAction Stop
    $stale = @($users | Where-Object {
        $_.UserType -eq 'Member' -and $_.AccountEnabled -and
        ($null -eq $_.SignInActivity.LastSignInDateTime -or $_.SignInActivity.LastSignInDateTime -lt $cutoff)
    } | Select-Object UserPrincipalName, DisplayName,
        @{ N = 'LastSignIn'; E = { $_.SignInActivity.LastSignInDateTime } },
        @{ N = 'Created'; E = { $_.CreatedDateTime } })
    $stale | Export-Csv -Path (Join-Path $ReportDirectory "stale-accounts-$stamp.csv") -NoTypeInformation -Encoding utf8
    Write-Host ("  Stale accounts (>= {0} days, enabled members): {1}" -f $StaleDays, $stale.Count) -ForegroundColor Yellow
    Write-LifecycleAudit -Action 'Review.StaleAccounts' -Target 'tenant' -Result 'Executed' -Detail ("count={0}" -f $stale.Count) | Out-Null

    # --- 2. Privileged role assignments ---
    Write-Host 'Checking privileged role assignments...' -ForegroundColor Cyan
    $privilegedRoles = @(
        'Global Administrator',
        'Privileged Authentication Administrator',
        'Privileged Role Administrator',
        'Security Administrator',
        'Exchange Administrator',
        'SharePoint Administrator',
        'User Administrator',
        'Cloud Application Administrator',
        'Application Administrator'
    )
    $roleDefs = Get-MgRoleManagementDirectoryRoleDefinition -All -ErrorAction Stop |
        Where-Object { $privilegedRoles -contains $_.DisplayName }
    $privAssignments = foreach ($roleDef in $roleDefs) {
        $assignments = Get-MgRoleManagementDirectoryRoleAssignment -Filter ("roleDefinitionId eq '{0}'" -f $roleDef.Id) -All -ExpandProperty principal -ErrorAction Stop
        foreach ($a in $assignments) {
            [pscustomobject]@{
                Role        = $roleDef.DisplayName
                Principal   = $a.Principal.DisplayName
                PrincipalUPN = $a.Principal.AdditionalProperties['userPrincipalName']
                PrincipalType = $a.Principal.AdditionalProperties['@odata.type']
            }
        }
    }
    $privAssignments = @($privAssignments)
    $privAssignments | Export-Csv -Path (Join-Path $ReportDirectory "privileged-roles-$stamp.csv") -NoTypeInformation -Encoding utf8
    Write-Host ("  Privileged role assignments: {0}" -f $privAssignments.Count) -ForegroundColor Yellow
    Write-LifecycleAudit -Action 'Review.PrivilegedRoles' -Target 'tenant' -Result 'Executed' -Detail ("count={0}" -f $privAssignments.Count) | Out-Null

    # --- 3. Guest users ---
    Write-Host 'Checking guest users...' -ForegroundColor Cyan
    $guests = @($users | Where-Object { $_.UserType -eq 'Guest' } | Select-Object UserPrincipalName, DisplayName, AccountEnabled,
        @{ N = 'LastSignIn'; E = { $_.SignInActivity.LastSignInDateTime } },
        @{ N = 'Created'; E = { $_.CreatedDateTime } },
        @{ N = 'AgeDays'; E = { [int]((Get-Date) - $_.CreatedDateTime).TotalDays } })
    $guests | Export-Csv -Path (Join-Path $ReportDirectory "guest-users-$stamp.csv") -NoTypeInformation -Encoding utf8
    Write-Host ("  Guest users: {0}" -f $guests.Count)
    Write-LifecycleAudit -Action 'Review.Guests' -Target 'tenant' -Result 'Executed' -Detail ("count={0}" -f $guests.Count) | Out-Null

    # --- 4. License waste: disabled accounts still licensed ---
    Write-Host 'Checking for license waste...' -ForegroundColor Cyan
    $waste = @($users | Where-Object { -not $_.AccountEnabled } | ForEach-Object {
        $licenses = Get-MgUserLicenseDetail -UserId $_.Id -ErrorAction SilentlyContinue
        if ($licenses.Count -gt 0) {
            [pscustomobject]@{
                UserPrincipalName = $_.UserPrincipalName
                DisplayName       = $_.DisplayName
                LicenseCount      = $licenses.Count
            }
        }
    })
    $waste = @($waste)
    $waste | Export-Csv -Path (Join-Path $ReportDirectory "license-waste-$stamp.csv") -NoTypeInformation -Encoding utf8
    Write-Host ("  Disabled accounts holding licenses: {0}" -f $waste.Count) -ForegroundColor Yellow
    Write-LifecycleAudit -Action 'Review.LicenseWaste' -Target 'tenant' -Result 'Executed' -Detail ("count={0}" -f $waste.Count) | Out-Null

    Write-Host ''
    Write-Host '=== Access review summary ===' -ForegroundColor Cyan
    Write-Host ("Stale accounts:            {0}" -f $stale.Count)
    Write-Host ("Privileged assignments:    {0}" -f $privAssignments.Count)
    Write-Host ("Guest users:               {0}" -f $guests.Count)
    Write-Host ("License waste (disabled):  {0}" -f $waste.Count)
    Write-Host ("Reports: {0}" -f $ReportDirectory)
    Write-Host ("Audit log: {0}" -f $run.AuditLogPath)
}
finally {
    Disconnect-LifecycleGraph
}
