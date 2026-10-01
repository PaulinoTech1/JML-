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

    It 'defaults maxTenantUsers to 1000 when absent' {
        $path = Join-Path $testRoot 'config-notenant.json'
        '{"domain":"contoso.com","upnPattern":"{first}.{last}","usageLocation":"US"}' | Set-Content -Path $path -Encoding utf8
        $config = Get-LifecycleConfig -Path $path
        $config.maxTenantUsers | Should -Be 1000
    }

    It 'rejects a non-positive maxTenantUsers' {
        $path = Join-Path $testRoot 'config-badtenant.json'
        '{"domain":"contoso.com","upnPattern":"{first}.{last}","usageLocation":"US","maxTenantUsers":0}' | Set-Content -Path $path -Encoding utf8
        { Get-LifecycleConfig -Path $path } | Should -Throw '*maxTenantUsers*'
    }
}

Describe 'Get-RoleMapping' {
    BeforeAll {
        $mapPath = Join-Path $testRoot 'roles.json'
        '{"IT":{"groups":[{"id":"11111111-1111-1111-1111-111111111111","name":"sg-it"}],"licenses":["SPB"]},"Sales":{"groups":[],"licenses":[]}}' |
            Set-Content -Path $mapPath -Encoding utf8
    }

    It 'returns the mapping for a known department' {
        $mapping = Get-RoleMapping -Path $mapPath -Department 'IT'
        $mapping['groups'][0]['id'] | Should -Be '11111111-1111-1111-1111-111111111111'
        $mapping['groups'][0]['name'] | Should -Be 'sg-it'
    }

    It 'fails closed on an unknown department and lists valid ones' {
        { Get-RoleMapping -Path $mapPath -Department 'Narnia' } | Should -Throw '*Valid departments*'
    }

    It 'fails closed on legacy display-name group entries with migration guidance' {
        $legacyPath = Join-Path $testRoot 'roles-legacy.json'
        '{"IT":{"groups":["sg-it"],"licenses":[]}}' | Set-Content -Path $legacyPath -Encoding utf8
        { Get-RoleMapping -Path $legacyPath -Department 'IT' } | Should -Throw '*object ID*'
    }

    It 'fails closed when a group entry is missing the id' {
        $badPath = Join-Path $testRoot 'roles-noid.json'
        '{"IT":{"groups":[{"name":"sg-it"}],"licenses":[]}}' | Set-Content -Path $badPath -Encoding utf8
        { Get-RoleMapping -Path $badPath -Department 'IT' } | Should -Throw '*id*'
    }
}

Describe 'Get-ManagedGroupUniverse' {
    It 'unions group IDs across all departments' {
        $mapPath = Join-Path $testRoot 'roles.json'
        $universe = Get-ManagedGroupUniverse -Path $mapPath
        $universe | Should -Contain '11111111-1111-1111-1111-111111111111'
        $universe.Count | Should -Be 1
    }

    It 'ignores underscore-prefixed metadata keys' {
        $metaPath = Join-Path $testRoot 'roles-meta.json'
        '{"_comment":"example","IT":{"groups":[{"id":"22222222-2222-2222-2222-222222222222","name":"sg-it"}],"licenses":[]}}' |
            Set-Content -Path $metaPath -Encoding utf8
        $universe = Get-ManagedGroupUniverse -Path $metaPath
        $universe | Should -Contain '22222222-2222-2222-2222-222222222222'
        $universe.Count | Should -Be 1
    }
}

Describe 'Assert-LeaverForceAuthorization' {
    It 'throws when -Force is used without a change ticket' {
        { Assert-LeaverForceAuthorization -Force $true -ChangeTicket '' } | Should -Throw '*ChangeTicket*'
    }

    It 'passes when -Force is paired with a change ticket' {
        { Assert-LeaverForceAuthorization -Force $true -ChangeTicket 'CHG-1234' } | Should -Not -Throw
    }

    It 'passes when -Force is not used' {
        { Assert-LeaverForceAuthorization -Force $false -ChangeTicket '' } | Should -Not -Throw
    }
}

Describe 'Assert-TenantSize' {
    It 'throws when the tenant exceeds the designed limit' {
        { Assert-TenantSize -UserCount 1001 -MaxUsers 1000 } | Should -Throw '*designed limit*'
    }

    It 'passes at exactly the limit' {
        { Assert-TenantSize -UserCount 1000 -MaxUsers 1000 } | Should -Not -Throw
    }

    It 'passes below the limit' {
        { Assert-TenantSize -UserCount 42 -MaxUsers 1000 } | Should -Not -Throw
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

Describe 'ConvertTo-GraphFilterLiteral' {
    It 'doubles single quotes for OData filter embedding' {
        ConvertTo-GraphFilterLiteral "o'brien@contoso.com" | Should -Be "o''brien@contoso.com"
    }

    It 'passes through strings without quotes unchanged' {
        ConvertTo-GraphFilterLiteral 'ada.lovelace@contoso.com' | Should -Be 'ada.lovelace@contoso.com'
    }

    It 'escapes multiple quotes' {
        ConvertTo-GraphFilterLiteral "it's a 'test'" | Should -Be "it''s a ''test''"
    }
}

Describe 'Assert-ChangeTicket' {
    It 'throws when the ticket is missing' {
        { Assert-ChangeTicket -ChangeTicket '' -Context 'Device wipe (-IncludeDevices)' } | Should -Throw '*ChangeTicket*'
    }

    It 'passes with any non-empty ticket when no pattern is configured' {
        { Assert-ChangeTicket -ChangeTicket 'literally-anything' } | Should -Not -Throw
    }

    It 'enforces the configured pattern' {
        { Assert-ChangeTicket -ChangeTicket 'CHG-1234' -TicketPattern '^CHG-[0-9]+$' } | Should -Not -Throw
    }

    It 'throws when the ticket does not match the configured pattern' {
        { Assert-ChangeTicket -ChangeTicket 'oops' -TicketPattern '^CHG-[0-9]+$' } | Should -Throw '*changeTicketPattern*'
    }
}

Describe 'Assert-LeaverForceAuthorization ticket pattern' {
    It 'enforces the pattern when one is supplied' {
        { Assert-LeaverForceAuthorization -Force $true -ChangeTicket 'nope' -TicketPattern '^CHG-[0-9]+$' } | Should -Throw '*changeTicketPattern*'
    }

    It 'accepts a matching ticket with a pattern supplied' {
        { Assert-LeaverForceAuthorization -Force $true -ChangeTicket 'CHG-42' -TicketPattern '^CHG-[0-9]+$' } | Should -Not -Throw
    }
}

Describe 'Get-LifecycleConfig changeTicketPattern' {
    It 'defaults changeTicketPattern to empty when absent' {
        $path = Join-Path $testRoot 'config-nopattern.json'
        '{"domain":"contoso.com","upnPattern":"{first}.{last}","usageLocation":"US"}' | Set-Content -Path $path -Encoding utf8
        $config = Get-LifecycleConfig -Path $path
        $config.changeTicketPattern | Should -Be ''
    }

    It 'accepts a valid changeTicketPattern regex' {
        $path = Join-Path $testRoot 'config-pattern.json'
        '{"domain":"contoso.com","upnPattern":"{first}.{last}","usageLocation":"US","changeTicketPattern":"^CHG-[0-9]+$"}' | Set-Content -Path $path -Encoding utf8
        $config = Get-LifecycleConfig -Path $path
        $config.changeTicketPattern | Should -Be '^CHG-[0-9]+$'
    }

    It 'rejects an invalid changeTicketPattern regex at load time' {
        $path = Join-Path $testRoot 'config-badpattern.json'
        '{"domain":"contoso.com","upnPattern":"{first}.{last}","usageLocation":"US","changeTicketPattern":"([unclosed"}' | Set-Content -Path $path -Encoding utf8
        { Get-LifecycleConfig -Path $path } | Should -Throw '*changeTicketPattern*'
    }
}

Describe 'Failed step tracking' {
    It 'starts at zero for a new run and counts registered failures' {
        $logDir = Join-Path $testRoot 'logs-failcount'
        Initialize-LifecycleRun -ScriptName 'Test' -LogDirectory $logDir | Out-Null
        Get-LifecycleFailedStepCount | Should -Be 0
        Register-LifecycleStepFailure -Action 'Test.Step' -Target 'test-target' -Detail 'boom' | Out-Null
        Get-LifecycleFailedStepCount | Should -Be 1
    }
}
