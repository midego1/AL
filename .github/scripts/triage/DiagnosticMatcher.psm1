# Symptom/signature matching between a public issue's stated symptom and observed AL compiler
# diagnostics. This module exists because a nonzero exit code or a compile failure alone is NEVER
# sufficient evidence of "reproduced" - environment/tooling errors (missing package cache, missing
# System/Application symbols, CLI usage errors, restore failures) look identical to a real product
# bug at the exit-code level. Reproduction is only claimed when an issue-cited AL diagnostic code
# (or, failing that, no claim at all) is observed in output that is NOT an environmental diagnostic.

Set-StrictMode -Version Latest

# Diagnostics that indicate a missing package cache/symbol resolution problem in *our own* fixture
# setup, not the AL compiler behavior the reporter described. Matched by code first, then by a
# message-text fallback so unfamiliar future codes with the same shape are still recognized.
$script:EnvironmentalDiagnosticCodes = @('AL1021', 'AL1022')
$script:EnvironmentalMessagePatterns = @(
    'could not be found in the package cache folders',
    'package cache path has not been specified',
    'package cache'
)

# CLI-usage / restore-level problems are not AL compiler diagnostics at all (no ALnnnn code) but
# must equally never be read as "reproduced".
$script:CliUsagePatterns = @(
    'Unrecognized command or argument',
    'Required command was not provided'
)

function Get-ExpectedIssueSignature {
    <#
        .SYNOPSIS
        Extracts an explicit, reportable symptom signature from public issue text: AL diagnostic
        codes (ALnnnn) and/or an Expected/Actual behavior pair. Never treats free-form prose as a
        signature - only these structured, low-ambiguity patterns count as "explicit".
    #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Body)

    $alCodes = @([regex]::Matches($Body, '\bAL\d{4}\b') | ForEach-Object { $_.Value.ToUpperInvariant() } | Select-Object -Unique)

    $expectedMatch = [regex]::Match($Body, '(?im)^\s*-?\s*\**expected\**(?: behaviou?r)?\s*[:\-]\s*(?<v>.+)$')
    $actualMatch = [regex]::Match($Body, '(?im)^\s*-?\s*\**actual\**(?: behaviou?r)?\s*[:\-]\s*(?<v>.+)$')

    [pscustomobject]@{
        AlCodes               = $alCodes
        ExpectedText          = if ($expectedMatch.Success) { $expectedMatch.Groups['v'].Value.Trim() } else { $null }
        ActualText            = if ($actualMatch.Success) { $actualMatch.Groups['v'].Value.Trim() } else { $null }
        HasExplicitSignature  = ($alCodes.Count -gt 0)
    }
}

function Get-CompilerDiagnostic {
    <#
        .SYNOPSIS
        Parses raw alc.exe/altool console output into structured diagnostics: severity, code,
        message. Recognizes both "error ALnnnn: message" and "path(line,col): error ALnnnn: message"
        forms.
    #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Output)

    if (-not $Output) { return @() }

    $regexMatches = [regex]::Matches($Output, '(?im)(?<severity>error|warning)\s+(?<code>[A-Za-z]{2,4}\d{3,5}):\s*(?<message>.+)$')
    @($regexMatches | ForEach-Object {
        [pscustomobject]@{
            Severity = $_.Groups['severity'].Value.ToLowerInvariant()
            Code     = $_.Groups['code'].Value.ToUpperInvariant()
            Message  = $_.Groups['message'].Value.Trim()
        }
    })
}

function Test-EnvironmentalDiagnostic {
    <#
        .SYNOPSIS
        True when a diagnostic reflects our own fixture/tooling environment (missing package
        cache/symbols) rather than the AL language/compiler behavior a reporter described.
    #>
    param([Parameter(Mandatory)] [pscustomobject] $Diagnostic)

    if ($script:EnvironmentalDiagnosticCodes -contains $Diagnostic.Code) { return $true }
    foreach ($pattern in $script:EnvironmentalMessagePatterns) {
        if ($Diagnostic.Message -match [regex]::Escape($pattern)) { return $true }
    }
    return $false
}

function Test-CliUsageFailure {
    <#
        .SYNOPSIS
        True when raw output indicates our own CLI invocation was malformed (wrong arguments/
        command name), which must never be read as a reproduced product defect.
    #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Output)
    foreach ($pattern in $script:CliUsagePatterns) {
        if ($Output -match [regex]::Escape($pattern)) { return $true }
    }
    return $false
}

function Resolve-ReproductionStatus {
    <#
        .SYNOPSIS
        Determines the honest reproduction status for a single Tier-1 compile attempt.

        .OUTPUTS
        PSCustomObject: Status ('reproduced'|'not_reproduced'|'inconclusive'),
        RequiresContainer (bool), Reason (string).

        .DESCRIPTION
        - If the raw output shows a CLI usage failure, status is always 'inconclusive' with
          RequiresContainer=$false (it's an invocation bug, not evidence about anything).
        - If every observed *error* diagnostic is environmental (missing package cache/symbols) and
          none are true AL compiler diagnostics, the fixture needs real symbols/a container -
          RequiresContainer=$true, status 'inconclusive'. This is never 'reproduced'.
        - If the issue provides an explicit AL#### signature, status is 'reproduced' only when a
          non-environmental observed diagnostic's code is in that signature; otherwise
          'not_reproduced' (evidence collected, no match - including a clean compile).
        - Without an explicit signature, status is always 'inconclusive' - a compile
          success/failure alone is never sufficient proof either way.
    #>
    param(
        [Parameter(Mandatory)] [pscustomobject] $ExpectedSignature,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [array] $ObservedDiagnostics,
        [Parameter(Mandatory)] [string] $RawOutput
    )

    if (Test-CliUsageFailure -Output $RawOutput) {
        return [pscustomobject]@{
            Status            = 'inconclusive'
            RequiresContainer = $false
            Reason            = 'Compiler invocation failed at the CLI-usage level; this is a tooling problem, not evidence about the reported behavior.'
        }
    }

    $errorDiagnostics = @($ObservedDiagnostics | Where-Object { $_.Severity -eq 'error' })
    $nonEnvironmental = @($errorDiagnostics | Where-Object { -not (Test-EnvironmentalDiagnostic -Diagnostic $_) })

    if ($errorDiagnostics.Count -gt 0 -and $nonEnvironmental.Count -eq 0) {
        return [pscustomobject]@{
            Status            = 'inconclusive'
            RequiresContainer = $true
            Reason            = 'Only missing package-cache/symbol diagnostics were observed (e.g. AL1021/AL1022); this fixture needs real System/Application symbols, which requires disposable-container reproduction (Tier 2), not just published ALTools.'
        }
    }

    if (-not $ExpectedSignature.HasExplicitSignature) {
        return [pscustomobject]@{
            Status            = 'inconclusive'
            RequiresContainer = $false
            Reason            = 'The issue does not cite an explicit AL#### diagnostic code, so compile success/failure alone cannot establish reproduction.'
        }
    }

    $matched = @($nonEnvironmental | Where-Object { $ExpectedSignature.AlCodes -contains $_.Code })
    if ($matched.Count -gt 0) {
        return [pscustomobject]@{
            Status            = 'reproduced'
            RequiresContainer = $false
            Reason            = "Observed diagnostic(s) $((@($matched | ForEach-Object { $_.Code }) | Select-Object -Unique) -join ', ') match the AL code(s) cited in the issue."
        }
    }

    return [pscustomobject]@{
        Status            = 'not_reproduced'
        RequiresContainer = $false
        Reason            = "The issue cites $($ExpectedSignature.AlCodes -join ', '), but no matching diagnostic was observed (nonEnvironmental diagnostics: $((@($nonEnvironmental | ForEach-Object { $_.Code }) | Select-Object -Unique) -join ', '); compile otherwise clean)."
    }
}

Export-ModuleMember -Function Get-ExpectedIssueSignature, Get-CompilerDiagnostic, Test-EnvironmentalDiagnostic, Test-CliUsageFailure, Resolve-ReproductionStatus
