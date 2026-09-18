<#
.SYNOPSIS
    Pester tests for the identity lifecycle pure functions.
.DESCRIPTION
    These tests exercise logic that requires NO Entra tenant: membership
    diffing, UPN building, config validation, and audit log formatting.
    Graph-touching code paths are intentionally excluded; they are validated
    by dry-run review, not by unit tests against a live directory.
#>

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'src' 'modules' 'IdentityLifecycle.Common.psm1'
    Import-Module $modulePath -Force
    $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("lifecycle-tests-{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
}

AfterAll {
    Remove-Item -Path $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Compare-MembershipPlan' {
    It 'computes adds for target items missing from current' {
        $plan = Compare-MembershipPlan -Current @('sg-a') -Target @('sg-a', 'sg-b') -ManagedUniverse @('sg-a', 'sg-b', 'sg-c')
        $plan.Add | Should -Be @('sg-b')
        $plan.Remove | Should -BeNullOrEmpty
        $plan.Keep | Should -Be @('sg-a')
    }

    It 'removes only managed-universe items missing from target' {
        $plan = Compare-MembershipPlan -Current @('sg-a', 'sg-old', 'sg-manual') -Target @('sg-a') -ManagedUniverse @('sg-a', 'sg-old')
        $plan.Remove | Should -Be @('sg-old')
        # sg-manual is outside the managed universe: never touched.
        $plan.Remove | Should -Not -Contain 'sg-manual'
    }

    It 'is case-insensitive' {
        $plan = Compare-MembershipPlan -Current @('SG-A') -Target @('sg-a') -ManagedUniverse @('sg-a')
        $plan.Add | Should -BeNullOrEmpty
        $plan.Remove | Should -BeNullOrEmpty
        $plan.Keep | Should -Be @('SG-A')
    }

    It 'returns an empty plan when nothing changes' {
        $plan = Compare-MembershipPlan -Current @('sg-a') -Target @('sg-a') -ManagedUniverse @('sg-a')
        $plan.Add | Should -BeNullOrEmpty
        $plan.Remove | Should -BeNullOrEmpty
    }

    It 'handles empty current state (new hire with no access yet)' {
        $plan = Compare-MembershipPlan -Current @() -Target @('sg-a', 'sg-b') -ManagedUniverse @('sg-a', 'sg-b')
        $plan.Add.Count | Should -Be 2
    }
}

Describe 'New-LifecycleUpn' {
    It 'builds a UPN from the pattern' {
        New-LifecycleUpn -FirstName 'Ada' -LastName 'Lovelace' -Pattern '{first}.{last}' -Domain 'contoso.com' |
            Should -Be 'ada.lovelace@contoso.com'
    }

    It 'sanitizes illegal characters' {
        New-LifecycleUpn -FirstName "O'Brien" -LastName 'Smith-Jones' -Pattern '{first}.{last}' -Domain 'contoso.com' |
            Should -Be 'obrien.smith-jones@contoso.com'
    }

    It 'throws when the local part sanitizes to empty' {
        { New-LifecycleUpn -FirstName '!!!' -LastName '???' -Pattern '{first}.{last}' -Domain 'contoso.com' } |
            Should -Throw
    }
}

Describe 'Get-LifecycleConfig' {
    It 'loads a valid config' {
        $path = Join-Path $testRoot 'config.json'
        '{"domain":"contoso.com","upnPattern":"{first}.{last}","usageLocation":"US"}' | Set-Content -Path $path -Encoding utf8
        $config = Get-LifecycleConfig -Path $path
        $config.domain | Should -Be 'contoso.com'
    }

    It 'fails closed when a required field is missing' {
        $path = Join-Path $testRoot 'bad-config.json'
        '{"domain":"contoso.com","upnPattern":"{first}.{last}"}' | Set-Content -Path $path -Encoding utf8
        { Get-LifecycleConfig -Path $path } | Should -Throw '*usageLocation*'
    }

    It 'fails closed when the file does not exist' {
        { Get-LifecycleConfig -Path (Join-Path $testRoot 'nope.json') } | Should -Throw '*not found*'
    }
}

Describe 'Get-RoleMapping' {
    BeforeAll {
        $mapPath = Join-Path $testRoot 'roles.json'
        '{"IT":{"groups":["sg-it"],"licenses":["SPB"]},"Sales":{"groups":[],"licenses":[]}}' |
            Set-Content -Path $mapPath -Encoding utf8
    }

    It 'returns the mapping for a known department' {
        $mapping = Get-RoleMapping -Path $mapPath -Department 'IT'
        $mapping['groups'] | Should -Be @('sg-it')
    }

    It 'fails closed on an unknown department and lists valid ones' {
        { Get-RoleMapping -Path $mapPath -Department 'Narnia' } | Should -Throw '*Valid departments*'
    }
}

Describe 'Get-ManagedGroupUniverse' {
    It 'unions groups across all departments' {
        $mapPath = Join-Path $testRoot 'roles.json'
        $universe = Get-ManagedGroupUniverse -Path $mapPath
        $universe | Should -Contain 'sg-it'
        $universe.Count | Should -Be 1
    }
}

Describe 'Write-LifecycleAudit' {
    It 'writes valid JSONL with the expected fields' {
        $logDir = Join-Path $testRoot 'logs'
        $run = Initialize-LifecycleRun -ScriptName 'Test' -LogDirectory $logDir
        Set-LifecycleMode -Apply $false
        Write-LifecycleAudit -Action 'Test.Action' -Target 'test-target' -Result 'Planned' -Detail 'x' | Out-Null

        $lines = Get-Content -Path $run.AuditLogPath -Encoding utf8
        $lines.Count | Should -BeGreaterThan 1
        $entry = $lines[-1] | ConvertFrom-Json
        $entry.action | Should -Be 'Test.Action'
        $entry.result | Should -Be 'Planned'
        $entry.dryRun | Should -Be $true
        $entry.runId | Should -Be $run.RunId
    }
}

Describe 'New-TemporaryPassword' {
    It 'generates passwords of the requested length that differ each call' {
        $a = New-TemporaryPassword -Length 20
        $b = New-TemporaryPassword -Length 20
        $a.Length | Should -Be 20
        $a | Should -Not -Be $b
    }
}
