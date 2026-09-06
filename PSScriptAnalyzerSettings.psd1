<#
    PSScriptAnalyzer settings for the AFK AI Windows starter.

    tests/Invoke-Checks.ps1 looks for this file and SKIPS its static-analysis
    gate when it is absent - so without it the check was reported as passing
    while never running. It enforces two things:

      * zero Error-severity findings;
      * zero PSAvoidAssignmentToAutomaticVariable findings.

    The second is not stylistic. Assigning to an automatic variable once broke
    every button in the dashboard: a `param($args)` shadowed the automatic
    `$args`, and the argument line silently rendered empty. The baseline in
    Invoke-Checks.ps1 is 0, so any reintroduction fails the build.

    Warnings are collected but do not fail the gate; the rules below are excluded
    because this codebase violates them on purpose, and leaving them in only
    buries the findings that matter.
#>
@{
    IncludeDefaultRules = $true

    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # This is a guided console installer. Its user-facing output is the
        # product, and it is deliberately written with Write-Host so that
        # colour and ordering survive; Write-Output would land in the pipeline.
        'PSAvoidUsingWriteHost',

        # Positional arguments are the house style throughout the scripts and
        # the checks, e.g. Add-Result 'Gate name' $ok 'detail'.
        'PSAvoidUsingPositionalParameters',

        # The scripts return plain [pscustomobject] evidence rather than
        # declaring [OutputType] on every helper.
        'PSUseOutputTypeCorrectly'
    )
}
