BeforeAll {
    $leaverPath = Join-Path $PSScriptRoot '../src/Leaver-OffboardEmployee.ps1'
    $moverPath = Join-Path $PSScriptRoot '../src/Mover-UpdateEmployee.ps1'
    $configPath = Join-Path $TestDrive 'config.json'
    '{"tenantId":"11111111-1111-1111-1111-111111111111","domain":"example.com","upnPattern":"{first}.{last}","usageLocation":"US"}' | Set-Content -LiteralPath $configPath
    $rolesPath = Join-Path $TestDrive 'roles.json'
    '{"IT":{"groups":[],"licenses":[]}}' | Set-Content -LiteralPath $rolesPath
    # Preload fake Graph modules into isolated runspaces. No tenant is contacted.
    $fakeModules = Join-Path $TestDrive 'modules'
    New-Item -ItemType Directory -Path $fakeModules | Out-Null
    @{
        'Microsoft.Graph.Authentication' = @'
function Connect-MgGraph {
    param($TenantId, $Scopes, $ClientSecretCredential, $ClientId, $CertificateThumbprint, $ContextScope, [switch]$NoWelcome)
    $global:LeaverState.Calls.Add('Connect:' + $TenantId)
    $global:LeaverState.ConnectedTenant = $TenantId
}
function Get-MgContext {
    $tenant = if ($global:LeaverState.ContextTenant) { $global:LeaverState.ContextTenant } else { $global:LeaverState.ConnectedTenant }
    [pscustomobject]@{ TenantId = $tenant; AuthType = 'Mock'; Scopes = @() }
}
function Disconnect-MgGraph { [CmdletBinding()]param() }
'@
        'Microsoft.Graph.Users' = @'
function Get-MgUser {
    [CmdletBinding()]param($Filter, $UserId, $Property)
    $global:LeaverState.Calls.Add('Select:' + ($Property -join ','))
    if ($Filter) { $global:LeaverState.Calls.Add('Filter:' + $Filter) }
    $global:LeaverState.ReadCount++
    $enabled = $global:LeaverState.Enabled
    if ($global:LeaverState.UnknownVerification -and $global:LeaverState.ReadCount -ge 3) { $enabled = $null }
    $user = [pscustomobject]@{ Id = $global:LeaverState.UserId; AccountEnabled = $enabled; Department = 'IT'; JobTitle = '' }
    if ($global:LeaverState.MissingAccountState) { $user.PSObject.Properties.Remove('AccountEnabled') }
    return $user
}
function Revoke-MgUserSignInSession {
    param($UserId)
    $global:LeaverState.Calls.Add('Revoke:' + $UserId)
    if ($global:LeaverState.Entered) {
        $global:LeaverState.Entered.Set()
        if (-not $global:LeaverState.Release.Wait(10000)) { throw 'Test did not release the first worker' }
    }
    if ($global:LeaverState.FailRevoke) { throw 'Simulated revoke failure' }
}
function Update-MgUser {
    param($UserId, $AccountEnabled, $EmployeeLeaveDateTime)
    if ($PSBoundParameters.ContainsKey('AccountEnabled')) {
        $global:LeaverState.Calls.Add('Disable:' + $UserId)
        $global:LeaverState.Enabled = $AccountEnabled
    }
    else { $global:LeaverState.Calls.Add('LeaveDate:' + $UserId) }
}
function Get-MgUserMemberOf { [CmdletBinding()]param($UserId, [switch]$All) }
function Get-MgUserLicenseDetail {
    [CmdletBinding()]param($UserId)
    for ($i = 0; $i -lt $global:LeaverState.LicenseCount; $i++) {
        [pscustomobject]@{ SkuId = '33333333-3333-3333-3333-333333333333' }
    }
}
function Set-MgUserLicense {
    param($UserId, $AddLicenses, $RemoveLicenses)
    $global:LeaverState.Calls.Add('RemoveLicenses:' + $RemoveLicenses.Count)
}
'@
        'Microsoft.Graph.Groups' = @'
function Remove-MgGroupMemberByRef { param($GroupId, $DirectoryObjectId) throw 'Unexpected group mutation' }
function Get-MgSubscribedSku { [CmdletBinding()]param() }
'@
    }.GetEnumerator() | ForEach-Object {
        $moduleDirectory = Join-Path $fakeModules $_.Key
        New-Item -ItemType Directory -Path $moduleDirectory | Out-Null
        $_.Value | Set-Content -LiteralPath (Join-Path $moduleDirectory ($_.Key + '.psm1'))
    }

    function New-LifecycleWorker {
        param($State, [bool]$ApplyMode = $true, [string]$Upn = 'same-user@example.com', [switch]$Mover)
        $scriptFile = if ($Mover) { $moverPath } else { $leaverPath }
        $logPath = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $State.Logs = $logPath
        $worker = [powershell]::Create()
        [void]$worker.AddScript({
            param($Modules, $Script, $Config, $Roles, $Logs, $State, $ApplyMode, $Upn, $Mover)
            $global:LeaverState = $State
            Get-ChildItem -LiteralPath $Modules -Filter '*.psm1' -Recurse | ForEach-Object { Import-Module $_.FullName -Global }
            $PSDefaultParameterValues = @{
                'Connect-LifecycleGraph:ClientId' = '22222222-2222-2222-2222-222222222222'
                'Connect-LifecycleGraph:ClientSecret' = (ConvertTo-SecureString 'offline-test-only' -AsPlainText -Force)
            }
            if ($Mover) {
                & $Script -ConfigPath $Config -RoleMapPath $Roles -LogDirectory $Logs -UserPrincipalName $Upn -NewDepartment IT -Apply:$ApplyMode
            }
            else {
                & $Script -ConfigPath $Config -LogDirectory $Logs -UserPrincipalName $Upn -Force -ChangeTicket 'CHG-TEST' -Apply:$ApplyMode
            }
        }).AddArgument($fakeModules).AddArgument($scriptFile).AddArgument($configPath).AddArgument($rolesPath).
            AddArgument($logPath).AddArgument($State).AddArgument($ApplyMode).AddArgument($Upn).AddArgument($Mover.IsPresent)
        return $worker
    }

    function New-LeaverState {
        param($Enabled = $true)
        return [hashtable]::Synchronized(@{
            Enabled = $Enabled; Calls = [System.Collections.Concurrent.ConcurrentBag[string]]::new()
            UserId = '44444444-4444-4444-4444-444444444444'; ReadCount = 0; LicenseCount = 0
            ContextTenant = ''; ConnectedTenant = ''; UnknownVerification = $false; MissingAccountState = $false
            FailRevoke = $false; Entered = $null; Release = $null; Logs = ''
        })
    }

    function Get-TestAudit {
        param($State)
        Get-ChildItem -LiteralPath $State.Logs -Filter '*.jsonl' | Get-Content | ForEach-Object { $_ | ConvertFrom-Json }
    }
    $previousTenantEnvironment = $env:LIFECYCLE_TENANT_ID
    $env:LIFECYCLE_TENANT_ID = $null
    $previousModulePathEnvironment = $env:PSModulePath
    $env:PSModulePath = $fakeModules + [IO.Path]::PathSeparator + $env:PSModulePath
}

AfterAll {
    $env:LIFECYCLE_TENANT_ID = $previousTenantEnvironment
    $env:PSModulePath = $previousModulePathEnvironment
}

Describe 'Offline leaver workflow regressions' {
    It 'performs no mutations in dry-run with empty groups and licenses' {
        $state = New-LeaverState
        $worker = New-LifecycleWorker -State $state -ApplyMode $false
        try {
            $worker.Invoke() | Out-Null
            $worker.HadErrors | Should -Be $false
            @($state.Calls | Where-Object { $_ -match '^(Revoke|Disable|LeaveDate|RemoveLicenses):' }).Count | Should -Be 0
        }
        finally { $worker.Dispose() }
    }

    It 'escapes an injected UPN predicate as a single Graph string literal' {
        $state = New-LeaverState
        $worker = New-LifecycleWorker -State $state -ApplyMode $false -Upn "x' or accountEnabled eq true or userPrincipalName eq 'x"
        try {
            $worker.Invoke() | Out-Null
            $worker.HadErrors | Should -Be $false
            $state.Calls | Should -Contain "Filter:userPrincipalName eq 'x'' or accountEnabled eq true or userPrincipalName eq ''x'"
        }
        finally { $worker.Dispose() }
    }

    It 'finishes offboarding when the SDK emits zero, one or multiple licenses' -TestCases @(
        @{ Count = 0 }; @{ Count = 1 }; @{ Count = 2 }
    ) {
        param($Count)
        $state = New-LeaverState
        $state.LicenseCount = $Count
        $worker = New-LifecycleWorker -State $state
        try {
            $worker.Invoke() | Out-Null
            $worker.HadErrors | Should -Be $false
            $state.Calls | Should -Contain ('LeaveDate:' + $state.UserId)
            if ($Count -gt 0) { $state.Calls | Should -Contain ('RemoveLicenses:' + $Count) }
            else { $state.Calls | Should -Not -Contain 'RemoveLicenses:0' }
            (Get-TestAudit $state | Where-Object action -EQ 'Verify.OffboardState').result | Should -Be 'Executed'
        }
        finally { $worker.Dispose() }
    }

    It 'disables true or unknown account state and skips only explicit false' -TestCases @(
        @{ Enabled = $true; Expected = 1 }
        @{ Enabled = $null; Expected = 1 }
        @{ Enabled = $false; Expected = 0 }
    ) {
        param($Enabled, $Expected)
        $state = New-LeaverState -Enabled $Enabled
        $worker = New-LifecycleWorker -State $state
        try {
            $worker.Invoke() | Out-Null
            $worker.HadErrors | Should -Be $false
            @($state.Calls | Where-Object { $_ -eq ('Disable:' + $state.UserId) }).Count | Should -Be $Expected
            $state.Calls | Should -Contain 'Select:id,accountEnabled'
        }
        finally { $worker.Dispose() }
    }

    It 'disables an account even when the initial response omits accountEnabled' {
        $state = New-LeaverState
        $state.MissingAccountState = $true
        $worker = New-LifecycleWorker -State $state
        try {
            $worker.Invoke() | Out-Null
            $worker.HadErrors | Should -Be $false
            $state.Calls | Should -Contain ('Disable:' + $state.UserId)
            (Get-TestAudit $state | Where-Object action -EQ 'Verify.OffboardState').result | Should -Be 'Failed'
        }
        finally { $worker.Dispose() }
    }

    It 'does not report unknown post-apply account state as verified' {
        $state = New-LeaverState
        $state.UnknownVerification = $true
        $worker = New-LifecycleWorker -State $state
        try {
            $worker.Invoke() | Out-Null
            $worker.HadErrors | Should -Be $false
            (Get-TestAudit $state | Where-Object action -EQ 'Verify.OffboardState').result | Should -Be 'Failed'
        }
        finally { $worker.Dispose() }
    }

    It 'rejects a mismatched authenticated tenant before any user lookup or mutation' {
        $state = New-LeaverState
        $state.ContextTenant = '55555555-5555-5555-5555-555555555555'
        $worker = New-LifecycleWorker -State $state
        try {
            try { $worker.Invoke() | Out-Null } catch { }
            $worker.HadErrors | Should -Be $true
            (($worker.Streams.Error | Out-String) + $worker.InvocationStateInfo.Reason) | Should -Match 'tenant does not match'
            @($state.Calls | Where-Object { $_ -notlike 'Connect:*' }).Count | Should -Be 0
        }
        finally { $worker.Dispose() }
    }

    It 'rejects an overlapping same-user live leaver or mover before mutation' -TestCases @(
        @{ Mover = $false }; @{ Mover = $true }
    ) {
        param($Mover)
        $firstState = New-LeaverState
        $secondState = New-LeaverState
        $entered = [System.Threading.ManualResetEventSlim]::new($false)
        $release = [System.Threading.ManualResetEventSlim]::new($false)
        $firstState.Entered = $entered
        $firstState.Release = $release
        $first = New-LifecycleWorker -State $firstState
        $second = New-LifecycleWorker -State $secondState -Mover:$Mover
        try {
            $pending = $first.BeginInvoke()
            $entered.Wait(10000) | Should -Be $true
            try { $second.Invoke() | Out-Null } catch { }
            $second.HadErrors | Should -Be $true
            (($second.Streams.Error | Out-String) + $second.InvocationStateInfo.Reason) | Should -Match 'holds the user lock'
            @($secondState.Calls | Where-Object { $_ -match '^(Revoke|Disable|LeaveDate|RemoveLicenses):' }).Count | Should -Be 0
            $release.Set()
            $first.EndInvoke($pending) | Out-Null
            $first.HadErrors | Should -Be $false
        }
        finally { $release.Set(); $first.Dispose(); $second.Dispose(); $entered.Dispose(); $release.Dispose() }
    }

    It 'releases the user lock when a mutation fails so a reconciled retry can run' {
        $state = New-LeaverState
        $state.FailRevoke = $true
        $first = New-LifecycleWorker -State $state
        $retryState = New-LeaverState
        $retry = New-LifecycleWorker -State $retryState
        try {
            try { $first.Invoke() | Out-Null } catch { }
            $first.HadErrors | Should -Be $true
            $retry.Invoke() | Out-Null
            $retry.HadErrors | Should -Be $false
            $retryState.Calls | Should -Contain ('LeaveDate:' + $retryState.UserId)
        }
        finally { $first.Dispose(); $retry.Dispose() }
    }
}
