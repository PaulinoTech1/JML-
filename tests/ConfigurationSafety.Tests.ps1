BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '../src/modules/IdentityLifecycle.Common.psm1') -Force
}

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '../src/modules/IdentityLifecycle.Common.psm1'
    Import-Module $modulePath
    # Offline command signatures let Pester mock auth without installing Graph.
    & (Get-Module IdentityLifecycle.Common) {
        function script:Connect-MgGraph {
            param($TenantId, $Scopes, $ContextScope, $ClientId, $CertificateThumbprint, $ClientSecretCredential, [switch]$NoWelcome)
        }
        function script:Get-MgContext { }
        function script:Disconnect-MgGraph { [CmdletBinding()]param() }
    }
}

Describe 'Required tenant configuration' {
    It 'rejects missing, null, malformed and placeholder tenant IDs' -TestCases @(
        @{ Tenant = $null }; @{ Tenant = '' }; @{ Tenant = 'not-a-tenant' }
        @{ Tenant = '00000000-0000-0000-0000-000000000000' }
        @{ Tenant = @('11111111-1111-1111-1111-111111111111') }
    ) {
        param($Tenant)
        $config = @{ domain = 'example.com'; upnPattern = '{first}.{last}'; usageLocation = 'US' }
        if ($null -ne $Tenant) { $config.tenantId = $Tenant }
        $path = Join-Path $TestDrive 'tenant.json'
        $config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path
        { Get-LifecycleConfig -Path $path } | Should -Throw '*tenantId*'
    }

    It 'normalizes a valid GUID without accepting an alternate identifier form' {
        $path = Join-Path $TestDrive 'tenant-valid.json'
        '{"tenantId":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","domain":"example.com","upnPattern":"{first}.{last}","usageLocation":"US"}' | Set-Content -LiteralPath $path
        (Get-LifecycleConfig -Path $path).tenantId | Should -BeExactly 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    }
}

Describe 'Role mapping fail-closed schema' {
    It 'rejects omitted, null and scalar policy fields instead of interpreting them as empty targets' -TestCases @(
        @{ Json = '{"IT":{"licenses":[]}}' }
        @{ Json = '{"IT":{"groups":[],"license":[]}}' }
        @{ Json = '{"IT":{"groups":null,"licenses":[]}}' }
        @{ Json = '{"IT":{"groups":[],"licenses":null}}' }
        @{ Json = '{"IT":{"groups":{},"licenses":[]}}' }
        @{ Json = '{"IT":{"groups":[],"licenses":"SPB"}}' }
        @{ Json = '{"IT":null}' }
        @{ Json = '[]' }
    ) {
        param($Json)
        $path = Join-Path $TestDrive 'roles-invalid.json'
        $Json | Set-Content -LiteralPath $path
        { Get-RoleMapping -Path $path -Department IT } | Should -Throw '*validation*'
    }

    It 'rejects malformed group IDs and license entries' -TestCases @(
        @{ Json = '{"IT":{"groups":[{"id":"not-a-guid","name":"IT"}],"licenses":[]}}' }
        @{ Json = '{"IT":{"groups":[{"id":"00000000-0000-0000-0000-000000000000","name":"IT"}],"licenses":[]}}' }
        @{ Json = '{"IT":{"groups":[null],"licenses":[]}}' }
        @{ Json = '{"IT":{"groups":[],"licenses":[null]}}' }
        @{ Json = '{"IT":{"groups":[],"licenses":[123]}}' }
    ) {
        param($Json)
        $path = Join-Path $TestDrive 'roles-malformed.json'
        $Json | Set-Content -LiteralPath $path
        { Get-RoleMapping -Path $path -Department IT } | Should -Throw '*validation*'
    }

    It 'preserves explicitly empty roles' {
        $path = Join-Path $TestDrive 'roles-empty.json'
        '{"IT":{"groups":[],"licenses":[]}}' | Set-Content -LiteralPath $path
        $mapping = Get-RoleMapping -Path $path -Department IT
        $mapping['groups'].Count | Should -Be 0
        $mapping['licenses'].Count | Should -Be 0
    }

    It 'validates other departments before constructing the managed removal universe' {
        $path = Join-Path $TestDrive 'roles-other-invalid.json'
        '{"IT":{"groups":[],"licenses":[]},"Sales":{"groups":null,"licenses":[]}}' | Set-Content -LiteralPath $path
        { Get-ManagedGroupUniverse -Path $path } | Should -Throw '*explicit*array*'
    }

    It 'excludes metadata from both managed removal universes' {
        $path = Join-Path $TestDrive 'roles-metadata.json'
        '{"_comment":"example","_meta":{"licenses":"SPB"},"IT":{"groups":[],"licenses":[]}}' | Set-Content -LiteralPath $path
        $access = Get-ManagedAccessUniverse -Path $path
        $access.GroupIds.Count | Should -Be 0
        $access.Licenses.Count | Should -Be 0
        $access.RoleMappings.Keys | Should -Not -Contain '_meta'
        $plan = Compare-MembershipPlan -Current @('SPB') -Target $access.RoleMappings['IT']['licenses'] -ManagedUniverse $access.Licenses
        $plan.Remove.Count | Should -Be 0
    }

    It 'uses the validated snapshot even if the policy file changes afterward' {
        $path = Join-Path $TestDrive 'roles-snapshot.json'
        '{"IT":{"groups":[],"licenses":["SPB"]}}' | Set-Content -LiteralPath $path
        $access = Get-ManagedAccessUniverse -Path $path
        '{"IT":{"groups":[],"licenses":null}}' | Set-Content -LiteralPath $path
        $mapping = Get-RoleMapping -Path $path -Department IT -Mappings $access.RoleMappings
        $mapping['licenses'] | Should -Contain 'SPB'
        $access.Licenses | Should -Contain 'SPB'
    }
}

Describe 'Authenticated tenant binding' {
    InModuleScope IdentityLifecycle.Common {
        BeforeEach {
            $script:PreviousTenant = $env:LIFECYCLE_TENANT_ID
            $env:LIFECYCLE_TENANT_ID = $null
            Mock Import-Module { }
            Mock Connect-MgGraph { }
            Mock Disconnect-MgGraph { }
            Mock Get-MgContext { [pscustomobject]@{ TenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; AuthType = 'Mock'; Scopes = @() } }
            Mock Write-LifecycleAudit { }
        }
        AfterEach { $env:LIFECYCLE_TENANT_ID = $script:PreviousTenant }

        It 'binds interactive, certificate and secret authentication to the expected tenant and process' -TestCases @(
            @{ Mode = 'Interactive' }; @{ Mode = 'Certificate' }; @{ Mode = 'Secret' }
        ) {
            param($Mode)
            $arguments = @{ TenantId = 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA'; ClientId = 'client-id' }
            switch ($Mode) {
                Interactive { $arguments.Interactive = $true }
                Certificate { $arguments.CertificateThumbprint = 'test-thumbprint' }
                Secret { $arguments.ClientSecret = ConvertTo-SecureString 'test-only' -AsPlainText -Force }
            }
            Connect-LifecycleGraph @arguments
            Should -Invoke Connect-MgGraph -Times 1 -Exactly -ParameterFilter { $TenantId -ceq 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' -and $ContextScope -eq 'Process' }
            Should -Invoke Write-LifecycleAudit -Times 1 -Exactly -ParameterFilter { $Action -eq 'Graph.Connect' }
        }

        It 'rejects a conflicting or malformed tenant environment before connecting' -TestCases @(
            @{ Value = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' }; @{ Value = 'not-a-guid' }
        ) {
            param($Value)
            $env:LIFECYCLE_TENANT_ID = $Value
            { Connect-LifecycleGraph -TenantId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' -Interactive } | Should -Throw '*does not match*'
            Should -Invoke Connect-MgGraph -Times 0 -Exactly
        }

        It 'accepts the same environment tenant despite GUID letter case' {
            $env:LIFECYCLE_TENANT_ID = 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA'
            { Connect-LifecycleGraph -TenantId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' -Interactive } | Should -Not -Throw
        }

        It 'disconnects and refuses missing, null or mismatched authenticated context' -TestCases @(
            @{ Context = $null }
            @{ Context = [pscustomobject]@{ TenantId = $null } }
            @{ Context = [pscustomobject]@{ AuthType = 'Mock' } }
            @{ Context = [pscustomobject]@{ TenantId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' } }
        ) {
            param($Context)
            $script:MockContext = $Context
            Mock Get-MgContext { $script:MockContext }
            { Connect-LifecycleGraph -TenantId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' -Interactive } | Should -Throw '*tenant does not match*'
            Should -Invoke Disconnect-MgGraph -Times 1 -Exactly
            Should -Invoke Write-LifecycleAudit -Times 0 -Exactly
        }
    }
}

Describe 'User lock across processes' {
    BeforeAll {
        $lockProbe = Join-Path $TestDrive 'lock-probe.ps1'
        @'
param($ModulePath, $TenantId, $UserId)
Import-Module $ModulePath -Force
try { $lock = Enter-LifecycleUserLock -TenantId $TenantId -UserId $UserId }
catch { exit 7 }
try { exit 0 }
finally { Exit-LifecycleUserLock -Lock $lock }
'@ | Set-Content -LiteralPath $lockProbe
        function Invoke-LockProbe {
            param($Tenant, $User)
            $start = [System.Diagnostics.ProcessStartInfo]::new()
            $start.FileName = (Get-Process -Id $PID).Path
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $lockProbe, '-ModulePath', $modulePath, '-TenantId', $Tenant, '-UserId', $User)) {
                $start.ArgumentList.Add($argument)
            }
            $process = [System.Diagnostics.Process]::Start($start)
            try {
                if (-not $process.WaitForExit(10000)) { $process.Kill(); throw 'Lock probe timed out' }
                return $process.ExitCode
            }
            finally { $process.Dispose() }
        }
    }

    It 'rejects the same normalized tenant/user in another process and allows other keys' {
        $tenant = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $user = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        $lock = Enter-LifecycleUserLock -TenantId $tenant -UserId $user
        try {
            Invoke-LockProbe -Tenant $tenant.ToUpperInvariant() -User $user.ToUpperInvariant() | Should -Be 7
            Invoke-LockProbe -Tenant $tenant -User 'cccccccc-cccc-cccc-cccc-cccccccccccc' | Should -Be 0
            Invoke-LockProbe -Tenant 'dddddddd-dddd-dddd-dddd-dddddddddddd' -User $user | Should -Be 0
        }
        finally { Exit-LifecycleUserLock -Lock $lock }
        Invoke-LockProbe -Tenant $tenant -User $user | Should -Be 0
    }

    It 'rejects abandoned ownership instead of continuing an interrupted lifecycle run' {
        if (-not ('JmlAbandonedLockProbe' -as [type])) {
            Add-Type @'
using System;
using System.Threading;
public static class JmlAbandonedLockProbe {
    public static void Abandon(string name) {
        var thread = new Thread(() => {
            using (var mutex = Mutex.OpenExisting(name)) { mutex.WaitOne(); }
        });
        thread.Start();
        if (!thread.Join(10000)) { throw new Exception("Abandonment probe timed out"); }
    }
}
'@
        }
        $tenant = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
        $user = 'ffffffff-ffff-ffff-ffff-ffffffffffff'
        $name = 'JML-{0}-{1}' -f $tenant, $user
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $name = 'Global\' + $name }
        # Keep the named object alive while the owning thread exits.
        $anchor = [System.Threading.Mutex]::new($false, $name)
        try {
            [JmlAbandonedLockProbe]::Abandon($name)
            { Enter-LifecycleUserLock -TenantId $tenant -UserId $user } | Should -Throw '*abandoned*'
            $reconciled = Enter-LifecycleUserLock -TenantId $tenant -UserId $user
            Exit-LifecycleUserLock -Lock $reconciled
        }
        finally { $anchor.Dispose() }
    }
}
