BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '../src/modules/IdentityLifecycle.Common.psm1'
    Import-Module $modulePath -Force
}

Describe 'Mutation gate boundary cases' {
    BeforeEach {
        Set-LifecycleMode -Apply $false
        Initialize-LifecycleRun -ScriptName 'EdgeCases' -LogDirectory $TestDrive | Out-Null
    }

    It 'never evaluates a destructive block in dry-run mode' {
        Invoke-LifecycleStep -Action 'User.Disable' -Target 'user@example.com' -ScriptBlock { throw 'MUTATION EXECUTED' } |
            Should -BeNullOrEmpty
        Get-LifecycleFailedStepCount | Should -Be 0
    }

    It 'returns mutation output only after explicit apply' {
        Set-LifecycleMode -Apply $true
        Invoke-LifecycleStep -Action 'User.Disable' -Target 'user@example.com' -ScriptBlock { 'result' } |
            Should -Be 'result'
    }

    It 'records a failed mutation and propagates its terminating error' {
        Set-LifecycleMode -Apply $true
        { Invoke-LifecycleStep -Action 'User.Disable' -Target 'user@example.com' -ScriptBlock { throw 'denied' } } |
            Should -Throw '*denied*'
        Get-LifecycleFailedStepCount | Should -Be 1
    }

    It 'can return to dry-run after an applied step' {
        Set-LifecycleMode -Apply $true
        Invoke-LifecycleStep -Action 'Test' -Target 'user' -ScriptBlock { 'applied' } | Out-Null
        Set-LifecycleMode -Apply $false
        { Invoke-LifecycleStep -Action 'Test' -Target 'user' -ScriptBlock { throw 'unsafe' } } | Should -Not -Throw
    }
}

Describe 'Empty membership boundaries' {
    It 'returns three empty arrays for an empty directory state' {
        $plan = Compare-MembershipPlan -Current @() -Target @() -ManagedUniverse @()
        $plan.Add.Count | Should -Be 0
        $plan.Remove.Count | Should -Be 0
        $plan.Keep.Count | Should -Be 0
    }

    It 'removes managed memberships for an explicitly empty target while preserving manual access' {
        $plan = Compare-MembershipPlan -Current @('managed', 'manual') -Target @() -ManagedUniverse @('managed')
        $plan.Remove | Should -Be @('managed')
        $plan.Remove | Should -Not -Contain 'manual'
    }

    It 'deduplicates current and target memberships' {
        $plan = Compare-MembershipPlan -Current @('A', 'a') -Target @('a', 'B', 'b') -ManagedUniverse @('a', 'b')
        $plan.Add.Count | Should -Be 1
        $plan.Keep.Count | Should -Be 1
        $plan.Remove.Count | Should -Be 0
    }

    It 'returns an empty managed universe when every department has explicit empty groups' {
        $path = Join-Path $TestDrive 'empty-roles.json'
        '{"IT":{"groups":[],"licenses":[]}}' | Set-Content -LiteralPath $path
        $universe = Get-ManagedGroupUniverse -Path $path
        $universe.Count | Should -Be 0
    }
}

Describe 'Malformed identity inputs' {
    It 'rejects names with no ASCII letters or digits after sanitization' -TestCases @(
        @{ First = '!!!'; Last = '???' }
        @{ First = '   '; Last = '   ' }
        @{ First = '___'; Last = '---' }
    ) {
        param($First, $Last)
        { New-LifecycleUpn -FirstName $First -LastName $Last -Pattern '{first}.{last}' -Domain 'example.com' } |
            Should -Throw
    }

    It 'keeps an injected OData predicate inside its string literal' {
        ConvertTo-GraphFilterLiteral "x' or accountEnabled eq true or userPrincipalName eq 'x" |
            Should -Be "x'' or accountEnabled eq true or userPrincipalName eq ''x"
    }

    It 'rejects whitespace-only tickets in forced mode' {
        { Assert-LeaverForceAuthorization -Force $true -ChangeTicket " `t`r`n" } | Should -Throw '*ChangeTicket*'
    }
}

Describe 'Malformed configuration boundaries' {
    It 'rejects missing role keys before computing access removals' {
        $path = Join-Path $TestDrive 'omitted-role-keys.json'
        '{"IT":{}}' | Set-Content -LiteralPath $path
        { Get-RoleMapping -Path $path -Department 'IT' } | Should -Throw '*explicit*array*'
    }

    It 'exposes malformed domains being accepted by the UPN builder' {
        # No syntax validation exists at this boundary; this is not a safety assertion.
        New-LifecycleUpn -FirstName 'Ada' -LastName 'Lovelace' -Pattern '{first}.{last}' -Domain 'bad@domain' |
            Should -Be 'ada.lovelace@bad@domain'
    }

    It 'rejects each missing required key' -TestCases @(
        @{ Json = '{"tenantId":"11111111-1111-1111-1111-111111111111","upnPattern":"{first}.{last}","usageLocation":"US"}' }
        @{ Json = '{"tenantId":"11111111-1111-1111-1111-111111111111","domain":"example.com","usageLocation":"US"}' }
        @{ Json = '{"tenantId":"11111111-1111-1111-1111-111111111111","domain":"example.com","upnPattern":"{first}.{last}"}' }
    ) {
        param($Json)
        $path = Join-Path $TestDrive 'missing-key.json'
        $Json | Set-Content -LiteralPath $path
        { Get-LifecycleConfig -Path $path } | Should -Throw
    }

    It 'rejects syntactically invalid JSON' {
        $path = Join-Path $TestDrive 'invalid.json'
        '{"tenantId":"11111111-1111-1111-1111-111111111111","domain":' | Set-Content -LiteralPath $path
        { Get-LifecycleConfig -Path $path } | Should -Throw
    }

    It 'rejects explicit null and whitespace required values' -TestCases @(
        @{ Value = 'null' }
        @{ Value = '"   "' }
    ) {
        param($Value)
        $path = Join-Path $TestDrive 'empty-value.json'
        ('{"tenantId":"11111111-1111-1111-1111-111111111111","domain":' + $Value + ',"upnPattern":"{first}.{last}","usageLocation":"US"}') | Set-Content -LiteralPath $path
        { Get-LifecycleConfig -Path $path } | Should -Throw
    }
}

Describe 'Concurrent same-target gate characterization' {
    It 'isolates apply mode and audit logs across overlapping runspaces' {
        # This tests the actual gate with leaver actions, not Graph or complete offboarding.
        # Separate runspaces isolate module state; there is no per-user lock.
        $barrier = [System.Threading.Barrier]::new(2)
        $workers = @()
        $pending = @()
        try {
            foreach ($applyMode in @($true, $false)) {
                $worker = [powershell]::Create()
                $workers += $worker
                [void]$worker.AddScript({
                    param($Path, $Logs, $ApplyMode, $Barrier)
                    Import-Module $Path -Force
                    Set-LifecycleMode -Apply $ApplyMode
                    $run = Initialize-LifecycleRun -ScriptName 'Leaver-Test' -LogDirectory $Logs
                    if (-not $Barrier.SignalAndWait(10000)) { throw 'Workers did not overlap' }
                    $value = Invoke-LifecycleStep -Action 'User.Disable' -Target 'same-user@example.com' -ScriptBlock { 'executed' }
                    [pscustomobject]@{ Applied = $ApplyMode; Value = $value; Log = $run.AuditLogPath; RunId = $run.RunId }
                }).AddArgument($modulePath).AddArgument($TestDrive).AddArgument($applyMode).AddArgument($barrier)
                $pending += $worker.BeginInvoke()
            }
            $results = for ($i = 0; $i -lt $workers.Count; $i++) {
                $workers[$i].EndInvoke($pending[$i])
                $workers[$i].HadErrors | Should -Be $false
            }
            $live = $results | Where-Object Applied
            $dry = $results | Where-Object { -not $_.Applied }
            $live.Value | Should -Be 'executed'
            $dry.Value | Should -BeNullOrEmpty
            $live.Log | Should -Not -Be $dry.Log
            $liveEntry = (Get-Content -LiteralPath $live.Log | Select-Object -Last 1) | ConvertFrom-Json
            $dryEntry = (Get-Content -LiteralPath $dry.Log | Select-Object -Last 1) | ConvertFrom-Json
            $liveEntry.result | Should -Be 'Executed'
            $dryEntry.result | Should -Be 'Planned'
            $liveEntry.runId | Should -Be $live.RunId
            $dryEntry.runId | Should -Be $dry.RunId
        }
        finally {
            foreach ($worker in $workers) { $worker.Dispose() }
            $barrier.Dispose()
        }
    }
}
