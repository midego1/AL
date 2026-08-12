# Builds the public structured triage report (schema) and its rendered Markdown comment, plus the
# hidden idempotency marker used to find/update a prior triage comment instead of duplicating it.
#
# Security note: this module only ever serializes fields we computed ourselves (scope prefilter,
# safety guard, reproduction results). It never echoes raw, unescaped issue body text into the
# comment as instructions, and it never emits the 'accepted' label - acceptance stays human-only.

Set-StrictMode -Version Latest

$script:SchemaVersion = 2

function Get-TriageMarker {
    <#
        .SYNOPSIS
        Builds the hidden HTML-comment marker used to find/update this issue's single triage
        comment idempotently, instead of ever posting a duplicate.
    #>
    param([Parameter(Mandatory)] [int] $IssueNumber)
    "<!-- public-al-issue-triage:v$($script:SchemaVersion):issue-$IssueNumber -->"
}

function New-TriageReport {
    <#
        .SYNOPSIS
        Builds the structured (JSON-serializable) triage report for a single microsoft/AL issue.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure data-construction function; builds an in-memory report object and performs no external state change.')]
    param(
        [Parameter(Mandatory)] [int] $IssueNumber,
        [Parameter(Mandatory)] [string] $Repo, # e.g. "microsoft/AL"
        [Parameter(Mandatory)] [ValidateSet('in_scope', 'out_of_scope', 'needs_human')] [string] $Scope,
        [Parameter(Mandatory)] [string] $Category,
        [Parameter(Mandatory)] [string] $Reason,
        [ValidateSet('reproduced', 'not_reproduced', 'inconclusive', 'blocked', 'not_attempted')] [string] $Reproduction = 'not_attempted',
        [ValidateSet('execution', 'unverified')] [string] $Proof = 'unverified',
        [ValidateSet('high', 'medium', 'low')] [string] $Confidence = 'low',
        [string] $Component = 'other',
        [ValidateSet('1-server-free', '2-container', '3-inconclusive', 'none')] [string] $Tier = 'none',
        [bool] $RequiresContainer = $false,
        [hashtable] $TestedVersions = @{},
        [string] $Observed = '',
        [string] $Expected = '',
        [string[]] $Commands = @(),
        [string[]] $Artifacts = @(),
        [string[]] $Blockers = @(),
        [object[]] $Duplicates = @(),
        [string] $RecommendedNextAction = '',
        [string[]] $LabelsApplied = @()
    )

    [pscustomobject]@{
        schemaVersion          = $script:SchemaVersion
        source                 = 'github'
        repo                   = $Repo
        issue                  = $IssueNumber
        scope                  = $Scope
        category               = $Category
        reason                 = $Reason
        reproduction           = $Reproduction
        proof                  = $Proof
        confidence             = $Confidence
        component              = $Component
        tier                   = $Tier
        requiresContainer      = $RequiresContainer
        testedVersions         = $TestedVersions
        observed               = $Observed
        expected               = $Expected
        commands               = $Commands
        artifacts              = $Artifacts
        blockers               = $Blockers
        duplicates             = $Duplicates
        recommendedNextAction  = $RecommendedNextAction
        labelsApplied          = $LabelsApplied
    }
}

function Format-TriageComment {
    <#
        .SYNOPSIS
        Renders a structured triage report as a public-safe Markdown comment, prefixed with the
        hidden idempotency marker.
    #>
    param(
        [Parameter(Mandatory)] [pscustomobject] $Report
    )

    $marker = Get-TriageMarker -IssueNumber $Report.issue
    $json = $Report | ConvertTo-Json -Depth 6 -Compress

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($marker)
    $lines.Add('')
    $lines.Add('## Automated triage report')
    $lines.Add('')
    $lines.Add('_This is an automated, best-effort triage. It never closes issues and never applies the `accepted` label - a human makes the acceptance decision._')
    $lines.Add('')
    $lines.Add("- **Scope**: ``$($Report.scope)`` ($($Report.category))")
    $lines.Add("- **Reason**: $($Report.reason)")
    $lines.Add("- **Reproduction**: ``$($Report.reproduction)`` (proof: ``$($Report.proof)``, confidence: ``$($Report.confidence)``)")
    $lines.Add("- **Component**: $($Report.component)")
    $lines.Add("- **Reproduction tier**: $($Report.tier)")
    if ($Report.requiresContainer) {
        $lines.Add('- **Requires container**: yes - this fixture needs real Business Central symbols (Application/System) or AL execution that published ALTools alone cannot provide.')
    }

    if ($Report.observed) { $lines.Add("- **Observed**: $($Report.observed)") }
    if ($Report.expected) { $lines.Add("- **Expected**: $($Report.expected)") }

    if ($Report.commands -and $Report.commands.Count -gt 0) {
        $lines.Add('')
        $lines.Add('<details><summary>Commands run</summary>')
        $lines.Add('')
        $lines.Add('```')
        foreach ($c in $Report.commands) { $lines.Add($c) }
        $lines.Add('```')
        $lines.Add('</details>')
    }

    if ($Report.blockers -and $Report.blockers.Count -gt 0) {
        $lines.Add('')
        $lines.Add('**Blockers / limitations:**')
        foreach ($b in $Report.blockers) { $lines.Add("- $b") }
    }

    if ($Report.duplicates -and $Report.duplicates.Count -gt 0) {
        $lines.Add('')
        $lines.Add('**Possible duplicates:**')
        foreach ($d in $Report.duplicates) { $lines.Add("- #$($d.Number): $($d.Title)") }
    }

    if ($Report.recommendedNextAction) {
        $lines.Add('')
        $lines.Add("**Recommended next action**: $($Report.recommendedNextAction)")
    }

    $lines.Add('')
    $lines.Add('<details><summary>Structured report (machine-readable)</summary>')
    $lines.Add('')
    $lines.Add('```json')
    $lines.Add($json)
    $lines.Add('```')
    $lines.Add('</details>')

    ($lines -join "`n")
}

Export-ModuleMember -Function Get-TriageMarker, New-TriageReport, Format-TriageComment
