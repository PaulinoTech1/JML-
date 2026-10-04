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
$script:DryRun          = $true
$script:AuditLogPath    = $null
$script:RunId           = $null
$script:FailedStepCount = 0

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
    $script:FailedStepCount = 0
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
        Register-LifecycleStepFailure -Action $Action -Target $Target -Detail $_.Exception.Message
        Write-Error ("FAILED {0} -> {1}: {2}" -f $Action, $Target, $_.Exception.Message)
    }
}

function Get-LifecycleFailedStepCount {
    <#
    .SYNOPSIS
        Returns the number of lifecycle steps that failed in the current run.
        Steps are sequential and independent: a failed group add does not
        roll back earlier steps. Callers print an end-of-run summary and the
        operator reconciles from the JSONL audit log. Automatic rollback is
        deliberately not attempted (rolling back a half-finished offboarding
        could re-enable an account that must stay disabled).
    #>
    [CmdletBinding()]
    param()
    return $script:FailedStepCount
}

function Register-LifecycleStepFailure {
    <#
    .SYNOPSIS
        Records a failed step that bypasses Invoke-LifecycleStep (e.g. a
        lookup that fails before the mutation choke point is reached).
        Audits the failure and increments the run's failed-step counter so
        the end-of-run summary stays accurate.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Target,
        [string]$Detail = ''
    )
    $script:FailedStepCount++
    Write-LifecycleAudit -Action $Action -Target $Target -Result 'Failed' -Detail $Detail | Out-Null
}

function ConvertTo-GraphFilterLiteral {
    <#
    .SYNOPSIS
        Escapes a string for embedding in a Microsoft Graph $filter expression.
        OData string literals escape a single quote by doubling it ('').
        Without this, a UPN containing ' breaks the filter or alters the
        query. Graph is not SQL, but the failure mode is real.
    .EXAMPLE
        ConvertTo-GraphFilterLiteral "o'brien@contoso.com"  # o''brien@contoso.com
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Value
    )
    return $Value.Replace("'", "''")
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
        Entry points pass the validated config tenant ID. If the tenant
        environment variable is set, it must agree with that ID.
        Client (app) ID comes from -ClientId or LIFECYCLE_CLIENT_ID.
        Certificate auth is strongly preferred: a client secret lives in
        process memory and can leak into shell history if exported
        interactively. See docs/APP_REGISTRATION.md.
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
    $expectedTenant = [guid]::Empty
    if (-not [guid]::TryParseExact($TenantId, 'D', [ref]$expectedTenant) -or $expectedTenant -eq [guid]::Empty) {
        throw 'TenantId must be a nonzero tenant GUID.'
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LIFECYCLE_TENANT_ID)) {
        $environmentTenant = [guid]::Empty
        if (-not [guid]::TryParseExact($env:LIFECYCLE_TENANT_ID, 'D', [ref]$environmentTenant) -or $environmentTenant -ne $expectedTenant) {
            throw 'LIFECYCLE_TENANT_ID does not match the configured tenantId. Correct the environment or config before running.'
        }
    }
    $TenantId = $expectedTenant.ToString('D')

    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    switch ($PSCmdlet.ParameterSetName) {
        'Interactive' {
            Write-Host 'Interactive sign-in requested (testing mode).' -ForegroundColor Cyan
            Connect-MgGraph -TenantId $TenantId -Scopes $Scopes -ContextScope Process -NoWelcome
        }
        'AppCert' {
            if ([string]::IsNullOrWhiteSpace($CertificateThumbprint)) { throw 'Certificate thumbprint missing. Set LIFECYCLE_CERT_THUMBPRINT.' }
            if ([string]::IsNullOrWhiteSpace($ClientId)) { throw 'ClientId is required for app-only auth. Set LIFECYCLE_CLIENT_ID.' }
            Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -CertificateThumbprint $CertificateThumbprint -ContextScope Process -NoWelcome
        }
        default {
            if ([string]::IsNullOrWhiteSpace($ClientId)) { throw 'ClientId is required for app-only auth. Set LIFECYCLE_CLIENT_ID.' }
            if ($null -eq $ClientSecret -or $ClientSecret.Length -eq 0) {
                throw 'Client secret missing. Set LIFECYCLE_CLIENT_SECRET env var or use -Interactive / certificate auth.'
            }
            Write-Warning 'Client-secret auth in use. Prefer certificate auth (LIFECYCLE_CERT_THUMBPRINT); see docs/APP_REGISTRATION.md.'
            $credential = [pscredential]::new($ClientId, $ClientSecret)
            Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $credential -ContextScope Process -NoWelcome
        }
    }

    $context = Get-MgContext
    $actualTenant = [guid]::Empty
    if ($null -eq $context -or $null -eq $context.PSObject.Properties['TenantId'] -or
        -not [guid]::TryParseExact([string]$context.TenantId, 'D', [ref]$actualTenant) -or $actualTenant -ne $expectedTenant) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        throw 'Authenticated Graph tenant does not match the configured tenantId. No lifecycle mutations are permitted.'
    }
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

    foreach ($field in @('tenantId', 'domain', 'upnPattern', 'usageLocation')) {
        if ($null -eq $config -or $null -eq $config.PSObject.Properties[$field] -or
            $config.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($config.$field)) {
            throw ("Config validation failed: required field '{0}' is missing or empty in {1}." -f $field, $Path)
        }
    }
    $tenantGuid = [guid]::Empty
    if (-not [guid]::TryParseExact($config.tenantId, 'D', [ref]$tenantGuid) -or $tenantGuid -eq [guid]::Empty) {
        throw 'Config validation failed: tenantId must be a nonzero tenant GUID.'
    }
    $config.tenantId = $tenantGuid.ToString('D')
    # Tenant-size boundary. This tool is sized for small and mid-size
    # businesses (default ceiling: 1000 users); tenant-wide reads are not
    # paged beyond the Graph SDK defaults, so Review-AccessReview fails
    # closed above this instead of mis-reporting. Override maxTenantUsers
    # in lifecycle-config.json if your tenant is legitimately larger.
    # NOTE: this module runs under Set-StrictMode, so a possibly-missing
    # property must be probed via PSObject.Properties (a static
    # $config.maxTenantUsers reference throws PropertyNotFoundException).
    if ($null -eq $config.PSObject.Properties['maxTenantUsers']) {
        $config | Add-Member -NotePropertyName 'maxTenantUsers' -NotePropertyValue 1000
    }
    elseif ($config.maxTenantUsers -le 0) {
        throw ("Config validation failed: 'maxTenantUsers' must be a positive number in {0}." -f $Path)
    }
    # Optional change-ticket format enforcement. Absent = any non-empty
    # ticket reference satisfies the gate (presence check only; approval is
    # process control, not code control). Present = the ticket must match.
    # An invalid regex fails closed here, at config load, not at 2 AM.
    if ($null -eq $config.PSObject.Properties['changeTicketPattern']) {
        $config | Add-Member -NotePropertyName 'changeTicketPattern' -NotePropertyValue ''
    }
    elseif (-not [string]::IsNullOrWhiteSpace($config.changeTicketPattern)) {
        try {
            [void][regex]::new($config.changeTicketPattern)
        }
        catch {
            throw ("Config validation failed: 'changeTicketPattern' is not a valid regex in {0}: {1}" -f $Path, $_.Exception.Message)
        }
    }
    return $config
}

function Get-RoleMapping {
    <#
    .SYNOPSIS
        Returns the group/license mapping for a department. Fails closed on
        unknown departments so nobody gets provisioned with a wrong role.
        Groups MUST be objects with 'id' (Entra object ID) and 'name'.
        Display names are never used for resolution: a rename or a duplicate
        display name must not be able to redirect membership changes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Department,
        [object]$Mappings
    )
    if (-not $PSBoundParameters.ContainsKey('Mappings')) {
        if (-not (Test-Path -Path $Path)) {
            throw ("Role mapping file not found: {0}. Copy config/role-mappings.json.example and fill it in." -f $Path)
        }
        $Mappings = Get-Content -Path $Path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10 -AsHashtable
    }

    if ($mappings -isnot [System.Collections.IDictionary]) {
        throw 'Role mapping validation failed: the root must be an object.'
    }
    if (-not $mappings.Contains($Department)) {
        $valid = ($mappings.Keys | Sort-Object) -join ', '
        throw ("Unknown department '{0}'. Valid departments: {1}." -f $Department, $valid)
    }
    $mapping = $mappings[$Department]
    if ($mapping -isnot [System.Collections.IDictionary]) {
        throw ("Role mapping validation failed: department '{0}' must be an object." -f $Department)
    }
    foreach ($field in @('groups', 'licenses')) {
        if (-not $mapping.Contains($field) -or $mapping[$field] -isnot [array]) {
            throw ("Role mapping validation failed: department '{0}' requires an explicit '{1}' array; use [] for intentionally empty access." -f $Department, $field)
        }
    }
    foreach ($g in $mapping['groups']) {
        $isObject = $g -is [System.Collections.IDictionary]
        $hasId = $isObject -and $g['id'] -is [string] -and -not [string]::IsNullOrWhiteSpace($g['id'])
        $hasName = $isObject -and $g['name'] -is [string] -and -not [string]::IsNullOrWhiteSpace($g['name'])
        $groupGuid = [guid]::Empty
        if (-not $hasId -or -not $hasName -or
            -not [guid]::TryParseExact($g['id'], 'D', [ref]$groupGuid) -or $groupGuid -eq [guid]::Empty) {
            throw ("Role mapping validation failed: department '{0}': every group must be an object with 'id' and 'name' (Entra object ID, not display name). " -f $Department +
                "Look up IDs with: Get-MgGroup -Filter ""displayName eq 'sg-name'"" | Select-Object Id, DisplayName")
        }
    }
    foreach ($license in $mapping['licenses']) {
        if ($license -isnot [string] -or [string]::IsNullOrWhiteSpace($license)) {
            throw ("Role mapping validation failed: department '{0}' licenses must contain nonempty SKU strings." -f $Department)
        }
    }
    return $mapping
}

function Get-ManagedGroupUniverse {
    <#
    .SYNOPSIS
        Returns every group ID referenced by any role mapping. The mover
        only removes memberships inside this universe, so manually assigned
        access outside lifecycle management is never touched. IDs, not
        display names: the universe must be immune to renames.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    $access = Get-ManagedAccessUniverse -Path $Path
    # Unary comma: without it PowerShell unrolls a one-element array on output
    # and callers receive a bare string (whose .Count is not 1) instead of an
    # array. The contract is "array of IDs", including the empty case.
    return ,@($access.GroupIds)
}

function Get-ManagedAccessUniverse {
    <#
    .SYNOPSIS
        Builds both removal universes from one validated policy snapshot.
        Underscore-prefixed metadata is never access policy.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $mappings = Get-Content -Path $Path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10 -AsHashtable
    if ($mappings -isnot [System.Collections.IDictionary]) {
        throw 'Role mapping validation failed: the root must be an object.'
    }
    $groups = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $licenses = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $roles = $mappings
    foreach ($metadata in @($roles.Keys | Where-Object { $_.StartsWith('_') })) { $roles.Remove($metadata) }
    foreach ($dept in $roles.Keys) {
        $mapping = Get-RoleMapping -Path $Path -Department $dept -Mappings $mappings
        foreach ($group in $mapping['groups']) { [void]$groups.Add($group['id']) }
        foreach ($license in $mapping['licenses']) { [void]$licenses.Add($license) }
    }
    return [pscustomobject]@{ RoleMappings = $roles; GroupIds = @($groups); Licenses = @($licenses) }
}

function Enter-LifecycleUserLock {
    <#
    .SYNOPSIS
        Excludes cooperating live mover/leaver runs for one tenant/user on
        this host. Contention and abandoned ownership require reconciliation.
        This is not a distributed lock or a Graph authorization boundary.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][guid]$TenantId,
        [Parameter(Mandatory)][guid]$UserId
    )
    if ($TenantId -eq [guid]::Empty -or $UserId -eq [guid]::Empty) {
        throw 'A user lock requires nonzero tenant and user object IDs.'
    }
    $name = 'JML-{0}-{1}' -f $TenantId.ToString('D'), $UserId.ToString('D')
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $name = 'Global\' + $name }
    $mutex = [System.Threading.Mutex]::new($false, $name)
    try {
        try {
            $acquired = $mutex.WaitOne(0)
        }
        catch [System.Threading.AbandonedMutexException] {
            # WaitOne grants ownership when abandonment is reported.
            $mutex.ReleaseMutex()
            throw 'Previous lifecycle run abandoned the user lock. Reconcile the audit and tenant state before retrying.'
        }
        if (-not $acquired) {
            throw 'Another lifecycle run holds the user lock. Wait for it to finish and reconcile state before retrying.'
        }
        return $mutex
    }
    catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-LifecycleUserLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Threading.Mutex]$Lock)
    try { $Lock.ReleaseMutex() }
    finally { $Lock.Dispose() }
}

function Assert-ChangeTicket {
    <#
    .SYNOPSIS
        Validates a change-ticket reference for a gated operation.
        Always requires a non-empty value. When the config supplies
        'changeTicketPattern', the ticket must also match that regex.
        Honest scope: this checks the reference is present and well-formed.
        It does NOT verify approval in an ITSM, check a signature, or stop
        an operator from inventing a ticket ID. That is process control,
        enforced by your change process and the audit log, not by this code.
    #>
    [CmdletBinding()]
    param(
        [string]$ChangeTicket,
        [string]$TicketPattern = '',
        [string]$Context = 'This operation'
    )
    if ([string]::IsNullOrWhiteSpace($ChangeTicket)) {
        throw ("{0} requires -ChangeTicket with the approved change record reference (e.g. -ChangeTicket `"CHG-1234`")." -f $Context)
    }
    if (-not [string]::IsNullOrWhiteSpace($TicketPattern) -and $ChangeTicket -notmatch $TicketPattern) {
        throw ("Change ticket '{0}' does not match the required format '{1}' (config 'changeTicketPattern')." -f $ChangeTicket, $TicketPattern)
    }
}

function Assert-LeaverForceAuthorization {
    <#
    .SYNOPSIS
        Fails closed when -Force is used without a change-ticket reference.
        Unattended mass offboarding without an approved change record is not
        permitted; the ticket reference is audit-logged by the caller.
    #>
    [CmdletBinding()]
    param(
        [bool]$Force,
        [string]$ChangeTicket,
        [string]$TicketPattern = ''
    )
    if ($Force) {
        Assert-ChangeTicket -ChangeTicket $ChangeTicket -TicketPattern $TicketPattern -Context '-Force'
    }
}

function Assert-TenantSize {
    <#
    .SYNOPSIS
        Fails closed when the tenant exceeds the tool's designed size.
        Tenant-wide reads are not paged beyond the Graph SDK defaults, so
        results on large tenants may be incomplete. This tool is sized for
        small-business tenants; it refuses rather than mis-reports.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$UserCount,
        [Parameter(Mandatory)][int]$MaxUsers
    )
    if ($UserCount -gt $MaxUsers) {
        throw ("Tenant has {0} users, above the designed limit of {1} (config 'maxTenantUsers'). " -f $UserCount, $MaxUsers +
            "This tool is sized for small-business tenants and fails closed rather than returning incomplete results.")
    }
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
    'Get-LifecycleFailedStepCount',
    'Register-LifecycleStepFailure',
    'ConvertTo-GraphFilterLiteral',
    'Assert-ChangeTicket',
    'Enter-LifecycleUserLock',
    'Exit-LifecycleUserLock',
    'Connect-LifecycleGraph',
    'Disconnect-LifecycleGraph',
    'Get-LifecycleConfig',
    'Get-RoleMapping',
    'Get-ManagedGroupUniverse',
    'Get-ManagedAccessUniverse',
    'Assert-LeaverForceAuthorization',
    'Assert-TenantSize',
    'Compare-MembershipPlan',
    'New-LifecycleUpn',
    'New-TemporaryPassword'
)
