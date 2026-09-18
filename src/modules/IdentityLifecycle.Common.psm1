<#
.SYNOPSIS
    Shared helpers for the identity lifecycle (JML) automation scripts.
.DESCRIPTION
    Provides Graph connection handling, config loading, dry-run execution
    gating, and JSONL audit logging. Every mutating script in this repo
    funnels through Invoke-LifecycleStep so that dry-run mode is enforced
    in exactly one place.
.NOTES
    Safety model:
      - Dry-run is the DEFAULT. Nothing mutates Entra ID unless the caller
        passes -Apply to the script, which flips the module into live mode.
      - Every planned, executed, skipped, or failed action is appended to a
        JSONL audit log. The log records that a password was set, never the
        password itself.
      - Secrets (client secrets, certificates) are read from environment
        variables or the local certificate store. They are never read from
        files in this repo and never written to the audit log.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Module-scoped run state. Scripts set this via Set-LifecycleMode.
$script:DryRun       = $true
$script:AuditLogPath = $null
$script:RunId        = $null

function Set-LifecycleMode {
    <#
    .SYNOPSIS
        Flips the module between dry-run (default) and live mode.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [bool]$Apply
    )
    $script:DryRun = -not $Apply
}

function Initialize-LifecycleRun {
    <#
    .SYNOPSIS
        Starts a new run: creates the audit log file and returns run metadata.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptName,
        [Parameter(Mandatory)][string]$LogDirectory
    )
    $script:RunId = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    if (-not (Test-Path -Path $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }
    $script:AuditLogPath = Join-Path $LogDirectory ("lifecycle-{0}-{1}.jsonl" -f $timestamp, $script:RunId)
    New-Item -ItemType File -Path $script:AuditLogPath -Force | Out-Null

    Write-LifecycleAudit -Action 'Run.Start' -Target $ScriptName -Result 'Executed' `
        -Detail ("dryRun={0}" -f $script:DryRun) | Out-Null

    return [pscustomobject]@{
        RunId        = $script:RunId
        AuditLogPath = $script:AuditLogPath
        DryRun       = $script:DryRun
    }
}

function Write-LifecycleAudit {
    <#
    .SYNOPSIS
        Appends one JSONL audit entry. Never call with secret values in -Detail.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][ValidateSet('Planned', 'Executed', 'Skipped', 'Failed')][string]$Result,
        [string]$Detail = ''
    )
    $entry = [ordered]@{
        timestamp = [DateTime]::UtcNow.ToString('o')
        runId     = $script:RunId
        actor     = [Environment]::UserName
        action    = $Action
        target    = $Target
        result    = $Result
        detail    = $Detail
        dryRun    = $script:DryRun
    }
    $line = $entry | ConvertTo-Json -Compress -Depth 5
    if ($script:AuditLogPath) {
        Add-Content -Path $script:AuditLogPath -Value $line -Encoding utf8
    }
    return [pscustomobject]$entry
}

function Invoke-LifecycleStep {
    <#
    .SYNOPSIS
        The single choke point for every mutation. In dry-run mode the action
        is logged as Planned and the script block never runs.
    .PARAMETER Action
        Short verb phrase, e.g. 'User.Create', 'GroupMember.Add'.
    .PARAMETER Target
        The object being acted on, e.g. a UPN or group name.
    .PARAMETER Detail
        Human-readable context. Must not contain secrets.
    .PARAMETER ScriptBlock
        The mutation to run in live mode. Its output is returned.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Target,
        [string]$Detail = '',
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    if ($script:DryRun) {
        Write-LifecycleAudit -Action $Action -Target $Target -Result 'Planned' -Detail $Detail | Out-Null
        Write-Host ("[DRY RUN] would {0} -> {1} {2}" -f $Action, $Target, $Detail) -ForegroundColor Yellow
        return $null
    }
    try {
        $output = & $ScriptBlock
        Write-LifecycleAudit -Action $Action -Target $Target -Result 'Executed' -Detail $Detail | Out-Null
        Write-Host ("[APPLIED] {0} -> {1}" -f $Action, $Target) -ForegroundColor Green
        return $output
    }
    catch {
        Write-LifecycleAudit -Action $Action -Target $Target -Result 'Failed' -Detail $_.Exception.Message | Out-Null
        Write-Error ("FAILED {0} -> {1}: {2}" -f $Action, $Target, $_.Exception.Message)
    }
}

function Connect-LifecycleGraph {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
        Justification = 'The client secret arrives via the LIFECYCLE_CLIENT_SECRET environment variable, the documented secret channel for automation. Converting it to a SecureString at the boundary is the correct handling; the plaintext is never logged, persisted, or transmitted outside the Graph auth call.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Interactive',
        Justification = 'The Interactive switch selects its parameter set; the branch is dispatched via $PSCmdlet.ParameterSetName, which is the idiomatic use of a switch-only parameter set selector.')]
    <#
    .SYNOPSIS
        Connects to Microsoft Graph for lifecycle automation.
    .DESCRIPTION
        Supports three auth modes, in order of preference for automation:
          1. App-only with certificate (thumbprint in LIFECYCLE_CERT_THUMBPRINT)
          2. App-only with client secret (secret in LIFECYCLE_CLIENT_SECRET env var)
          3. Interactive delegated sign-in (-Interactive), for testing only.
        Tenant ID comes from -TenantId or LIFECYCLE_TENANT_ID.
        Client (app) ID comes from -ClientId or LIFECYCLE_CLIENT_ID.
    #>
    [CmdletBinding(DefaultParameterSetName = 'AppSecret')]
    param(
        [string]$TenantId = $env:LIFECYCLE_TENANT_ID,
        [string]$ClientId = $env:LIFECYCLE_CLIENT_ID,
        [Parameter(ParameterSetName = 'AppSecret')]
        [securestring]$ClientSecret = $(if ($env:LIFECYCLE_CLIENT_SECRET) { ConvertTo-SecureString -String $env:LIFECYCLE_CLIENT_SECRET -AsPlainText -Force } else { $null }),
        [Parameter(ParameterSetName = 'AppCert')]
        [string]$CertificateThumbprint = $env:LIFECYCLE_CERT_THUMBPRINT,
        [Parameter(ParameterSetName = 'Interactive')]
        [switch]$Interactive,
        [string[]]$Scopes = @('User.ReadWrite.All', 'GroupMember.ReadWrite.All', 'Directory.Read.All', 'Organization.Read.All')
    )

    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        throw 'TenantId is required. Set LIFECYCLE_TENANT_ID or pass -TenantId.'
    }

    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    switch ($PSCmdlet.ParameterSetName) {
        'Interactive' {
            Write-Host 'Interactive sign-in requested (testing mode).' -ForegroundColor Cyan
            Connect-MgGraph -TenantId $TenantId -Scopes $Scopes -NoWelcome
        }
        'AppCert' {
            if ([string]::IsNullOrWhiteSpace($CertificateThumbprint)) { throw 'Certificate thumbprint missing. Set LIFECYCLE_CERT_THUMBPRINT.' }
            if ([string]::IsNullOrWhiteSpace($ClientId)) { throw 'ClientId is required for app-only auth. Set LIFECYCLE_CLIENT_ID.' }
            Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -CertificateThumbprint $CertificateThumbprint -NoWelcome
        }
        default {
            if ([string]::IsNullOrWhiteSpace($ClientId)) { throw 'ClientId is required for app-only auth. Set LIFECYCLE_CLIENT_ID.' }
            if ($null -eq $ClientSecret -or $ClientSecret.Length -eq 0) {
                throw 'Client secret missing. Set LIFECYCLE_CLIENT_SECRET env var or use -Interactive / certificate auth.'
            }
            $credential = [pscredential]::new($ClientId, $ClientSecret)
            Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $credential -NoWelcome
        }
    }

    $context = Get-MgContext
    Write-LifecycleAudit -Action 'Graph.Connect' -Target $TenantId -Result 'Executed' `
        -Detail ("authType={0} scopes={1}" -f $context.AuthType, ($context.Scopes -join ',')) | Out-Null
}

function Get-LifecycleConfig {
    <#
    .SYNOPSIS
        Loads and validates lifecycle-config.json. Fails closed on bad config.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    if (-not (Test-Path -Path $Path)) {
        throw ("Config file not found: {0}. Copy config/lifecycle-config.json.example and fill it in." -f $Path)
    }
    $config = Get-Content -Path $Path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10

    foreach ($field in @('domain', 'upnPattern', 'usageLocation')) {
        if ([string]::IsNullOrWhiteSpace($config.$field)) {
            throw ("Config validation failed: required field '{0}' is missing or empty in {1}." -f $field, $Path)
        }
    }
    return $config
}

function Get-RoleMapping {
    <#
    .SYNOPSIS
        Returns the group/license mapping for a department. Fails closed on
        unknown departments so nobody gets provisioned with a wrong role.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Department
    )
    if (-not (Test-Path -Path $Path)) {
        throw ("Role mapping file not found: {0}. Copy config/role-mappings.json.example and fill it in." -f $Path)
    }
    $mappings = Get-Content -Path $Path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10 -AsHashtable

    if (-not $mappings.ContainsKey($Department)) {
        $valid = ($mappings.Keys | Sort-Object) -join ', '
        throw ("Unknown department '{0}'. Valid departments: {1}." -f $Department, $valid)
    }
    $mapping = $mappings[$Department]
    foreach ($field in @('groups', 'licenses')) {
        if ($null -eq $mapping[$field]) { $mapping[$field] = @() }
    }
    return $mapping
}

function Get-ManagedGroupUniverse {
    <#
    .SYNOPSIS
        Returns every group name referenced by any role mapping. The mover
        only removes memberships inside this universe, so manually assigned
        access outside lifecycle management is never touched.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    $mappings = Get-Content -Path $Path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10 -AsHashtable
    $universe = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($dept in $mappings.Keys) {
        foreach ($g in $mappings[$dept]['groups']) { [void]$universe.Add($g) }
    }
    return @($universe)
}

function Compare-MembershipPlan {
    <#
    .SYNOPSIS
        Pure function: computes add/remove/keep sets for group or license
        reconciliation. Unit-tested; no Graph calls.
    #>
    [CmdletBinding()]
    param(
        [string[]]$Current = @(),
        [string[]]$Target = @(),
        [string[]]$ManagedUniverse = @()
    )
    $currentSet = [System.Collections.Generic.HashSet[string]]::new($Current, [StringComparer]::OrdinalIgnoreCase)
    $targetSet  = [System.Collections.Generic.HashSet[string]]::new($Target, [StringComparer]::OrdinalIgnoreCase)
    $managedSet = [System.Collections.Generic.HashSet[string]]::new($ManagedUniverse, [StringComparer]::OrdinalIgnoreCase)

    $add = @($targetSet | Where-Object { -not $currentSet.Contains($_) } | Sort-Object)
    # Only remove memberships that are inside the managed universe. Anything
    # assigned manually outside lifecycle management is left alone.
    $remove = @($currentSet | Where-Object { $managedSet.Contains($_) -and -not $targetSet.Contains($_) } | Sort-Object)
    $keep = @($currentSet | Where-Object { $targetSet.Contains($_) } | Sort-Object)

    return [pscustomobject]@{ Add = $add; Remove = $remove; Keep = $keep }
}

function New-LifecycleUpn {
    <#
    .SYNOPSIS
        Builds a UPN from the configured pattern. Pure function, unit-tested.
    .EXAMPLE
        New-LifecycleUpn -FirstName 'Ada' -LastName 'Lovelace' -Pattern '{first}.{last}' -Domain 'contoso.com'
        # -> ada.lovelace@contoso.com
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FirstName,
        [Parameter(Mandatory)][string]$LastName,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Domain
    )
    $local = $Pattern.Replace('{first}', $FirstName.Trim().ToLower()).Replace('{last}', $LastName.Trim().ToLower())
    # Strip anything that is not legal in a UPN local part.
    $local = $local -replace "[^a-z0-9._-]", ""
    if ([string]::IsNullOrWhiteSpace($local) -or $local -notmatch '[a-z0-9]') {
        throw 'UPN local part has no usable characters after sanitization.'
    }
    return ("{0}@{1}" -f $local, $Domain.Trim().ToLower())
}

function New-TemporaryPassword {
    <#
    .SYNOPSIS
        Generates a cryptographically random temporary password. The value is
        returned to the caller and MUST NOT be written to logs. Callers hand
        it to HR through an out-of-band secure channel.
    #>
    [CmdletBinding()]
    param(
        [int]$Length = 20
    )
    $alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#$%^&*'.ToCharArray()
    $bytes = New-Object byte[] $Length
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
}

function Disconnect-LifecycleGraph {
    [CmdletBinding()]
    param()
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}

Export-ModuleMember -Function @(
    'Set-LifecycleMode',
    'Initialize-LifecycleRun',
    'Write-LifecycleAudit',
    'Invoke-LifecycleStep',
    'Connect-LifecycleGraph',
    'Disconnect-LifecycleGraph',
    'Get-LifecycleConfig',
    'Get-RoleMapping',
    'Get-ManagedGroupUniverse',
    'Compare-MembershipPlan',
    'New-LifecycleUpn',
    'New-TemporaryPassword'
)
