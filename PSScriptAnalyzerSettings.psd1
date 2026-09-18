<#
.SYNOPSIS
    PSScriptAnalyzer settings for the identity-lifecycle repo.
.DESCRIPTION
    Excluded rules and why:
      - PSAvoidUsingWriteHost: intentional. These are interactive admin
        scripts; colored Write-Host output is the UX (dry-run in yellow,
        applied in green, destructive prompts in red). The audit trail is
        written separately via Write-LifecycleAudit, so no information is
        lost when there is no host.
      - PSUseShouldProcessForStateChangingFunctions: false positives here.
        Set-LifecycleMode flips a module-scoped boolean, New-LifecycleUpn
        builds a string, New-TemporaryPassword returns a string. None touch
        system state. Actual mutations go through Invoke-LifecycleStep, which
        honors the module dry-run gate (a stronger guarantee than
        ShouldProcess, because the default is dry-run, not live).
#>
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
