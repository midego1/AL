# Deterministic scope/template prefilter for public microsoft/AL issue triage.
#
# Security note: issue title/body text is UNTRUSTED input from the public internet. This module
# never executes, evaluates, or follows instructions found in that text - it only pattern-matches
# against a fixed, code-reviewed rule table. Nothing in issue text can change which rule fires or
# widen the set of labels this module is capable of returning.

Set-StrictMode -Version Latest

# Labels this automation is allowed to suggest. Deliberately excludes 'accepted' and any
# close/merge-adjacent label: acceptance is a human-only decision (see repo instructions).
$script:AllowedSuggestedLabels = @(
    'runtime - Out of Scope', 'out-of-scope', 'application', 'event-request', 'function-expose',
    'suggestion', 'idea', 'question', 'customer-support', 'not-following-template', 'input-needed',
    'need-repro', 'requires-triage', 'investigate', 'duplicate'
)

$script:DenylistedLabels = @('accepted')

function ConvertTo-SafeLabelList {
    <#
        .SYNOPSIS
        Filters a candidate label list down to the fixed allow-list and strips any denylisted label,
        so prompt-injected text can never cause an out-of-band label (e.g. 'accepted') to be applied.
    #>
    param([string[]] $Candidates)

    $Candidates |
        Where-Object { $_ -and ($script:DenylistedLabels -notcontains $_) -and ($script:AllowedSuggestedLabels -contains $_) } |
        Select-Object -Unique
}

function Test-HasCodeFence {
    param([string] $Text)
    if (-not $Text) { return $false }
    return [regex]::IsMatch($Text, '```')
}

function Test-HasVersionInfo {
    param([string] $Text)
    if (-not $Text) { return $false }
    # Matches the repo issue template's "AL Extension Version:"/"Server Version:" fields, or a
    # loose "vX.Y" / "version 1.2.3" style mention.
    return [regex]::IsMatch($Text, '(?im)^\s*-?\s*(AL (Language|Extension) )?(Version|Server Version)\s*:\s*\S') -or
           [regex]::IsMatch($Text, '(?i)\bv?\d+\.\d+(\.\d+)?(\.\d+)?\b')
}

# Ordered rule table. First matching rule wins. Keep in priority order: unambiguous out-of-scope
# signals first, then completeness checks, then the in-scope default.
$script:Rules = @(
    @{
        Category = 'runtime'
        Scope    = 'out_of_scope'
        Pattern  = '(?i)\b(web ?client|service tier|NST|Business Central Server|session times? ?out|OData (query|error)|API (call|request) (fails|failed|error)|runtime error in (production|the server)|server crash(ed)?)\b'
        Exclude  = '(?i)\b(compiler|analyzer|al language|intellisense|debugger|al tool|altool|vs ?code extension)\b'
        Labels   = @('runtime - Out of Scope', 'out-of-scope')
        Reason   = 'Mentions runtime/server/web-client execution behavior rather than the AL compiler or developer tooling.'
    },
    @{
        Category = 'application'
        Scope    = 'out_of_scope'
        Pattern  = '(?i)\b(base application|system application|standard (app|application) object|posting routine|business logic (bug|error))\b'
        Exclude  = '(?i)\b(al compiler|analyzer|al tool|altool|language server|vs ?code)\b'
        Labels   = @('application', 'out-of-scope')
        Reason   = 'Describes application/business-logic behavior, not the AL compiler or developer tooling.'
    },
    @{
        Category = 'event-function-request'
        Scope    = 'out_of_scope'
        Pattern  = '(?i)\b(please expose|add (an? )?event|new (integration|business) event|expose (this|the) (field|method|procedure)|make this a function|publish(er)? event request)\b'
        Exclude  = $null
        Labels   = @('event-request', 'function-expose')
        Reason   = 'Requests a new exposed event/function rather than reporting a defect.'
    },
    @{
        Category = 'suggestion'
        Scope    = 'out_of_scope'
        Pattern  = '(?i)\b(feature request|it would be (nice|great) if|suggestion\s*:|idea\s*:|new analyzer rule (idea|suggestion)|please add support for)\b'
        Exclude  = $null
        Labels   = @('suggestion', 'idea')
        Reason   = 'Proposes a new feature/capability rather than reporting a defect.'
    },
    @{
        Category = 'support-question'
        Scope    = 'out_of_scope'
        Pattern  = '(?i)\b(how do i|how to\b|is it possible to|question\s*:|what is the (best|recommended) way)\b'
        Exclude  = '(?i)\b(compiler (crash|error)|reproduc(e|ible)|unexpected error)\b'
        Labels   = @('question', 'customer-support')
        Reason   = 'Reads as a usage question rather than a reproducible defect report.'
    }
)

function Get-IssueScopeClassification {
    <#
        .SYNOPSIS
        Deterministically classifies a public microsoft/AL issue's scope from its title/body/labels.

        .DESCRIPTION
        Returns a structured, side-effect-free classification. Callers are responsible for actually
        applying labels/comments. The function never inspects existing labels for anything other than
        short-circuiting already-triaged issues, and never derives behavior from free-text
        "instructions" embedded in the issue - only from the fixed rule table above.
    #>
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Title,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Body,
        [string[]] $Labels = @()
    )

    $combined = "$Title`n$Body"

    foreach ($rule in $script:Rules) {
        if ($combined -notmatch $rule.Pattern) { continue }
        if ($rule.Exclude -and ($combined -match $rule.Exclude)) { continue }

        return [pscustomobject]@{
            Scope                     = $rule.Scope
            Category                  = $rule.Category
            Reason                    = $rule.Reason
            # Idempotency: never re-suggest a label the issue already carries.
            SuggestedLabels           = (ConvertTo-SafeLabelList -Candidates $rule.Labels) | Where-Object { $Labels -notcontains $_ }
            ManualReproductionRequired = $false
        }
    }

    # Completeness checks: these apply regardless of subject matter, because we cannot classify
    # in/out of scope reliably without a code sample and version context.
    $hasCode = Test-HasCodeFence -Text $Body
    $hasVersion = Test-HasVersionInfo -Text $Body

    if (-not $hasCode -and -not $hasVersion) {
        return [pscustomobject]@{
            Scope                     = 'needs_human'
            Category                  = 'missing-template'
            Reason                    = 'Issue is missing both a code sample and version information required by the issue template.'
            SuggestedLabels           = (ConvertTo-SafeLabelList -Candidates @('not-following-template', 'input-needed')) | Where-Object { $Labels -notcontains $_ }
            ManualReproductionRequired = $false
        }
    }

    if (-not $hasCode) {
        return [pscustomobject]@{
            Scope                     = 'needs_human'
            Category                  = 'missing-repro'
            Reason                    = 'Issue has version information but no repro code sample.'
            SuggestedLabels           = (ConvertTo-SafeLabelList -Candidates @('need-repro')) | Where-Object { $Labels -notcontains $_ }
            ManualReproductionRequired = $false
        }
    }

    # UI-only / editor-host issues are in-scope (AL tooling) but cannot be reproduced by a headless
    # workflow - they require a human on a real editor session.
    $isUiOnly = [regex]::IsMatch($combined, '(?i)\b(intellisense popup|hover tooltip|syntax highlighting (looks|displays)|icon (looks|is) wrong|editor (font|color|theme)|code ?lens (icon|position))\b')

    return [pscustomobject]@{
        Scope                     = 'in_scope'
        Category                  = if ($isUiOnly) { 'ui-only' } else { 'tooling' }
        Reason                    = if ($isUiOnly) {
            'Editor/UI-host behavior in AL tooling; in scope but requires manual reproduction.'
        } else {
            'Describes AL compiler/developer-tooling behavior with a code sample and version info.'
        }
        SuggestedLabels           = (ConvertTo-SafeLabelList -Candidates @('requires-triage')) | Where-Object { $Labels -notcontains $_ }
        ManualReproductionRequired = $isUiOnly
    }
}

function Find-PossibleDuplicateIssue {
    <#
        .SYNOPSIS
        Best-effort, purely informational duplicate suggestion based on simple title-token overlap
        against a caller-supplied candidate list. Never blocks or changes scope classification.
    #>
    param(
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [array] $CandidateIssues, # objects with .number and .title
        [int] $MinTokenOverlap = 3
    )

    $stopWords = @('the', 'a', 'an', 'to', 'in', 'of', 'is', 'and', 'for', 'on', 'with', 'this', 'that')
    $titleTokens = ($Title -split '\W+') | Where-Object { $_.Length -gt 2 } | ForEach-Object { $_.ToLowerInvariant() } | Where-Object { $stopWords -notcontains $_ }

    $results = foreach ($candidate in $CandidateIssues) {
        $candidateTokens = ($candidate.title -split '\W+') | Where-Object { $_.Length -gt 2 } | ForEach-Object { $_.ToLowerInvariant() } | Where-Object { $stopWords -notcontains $_ }
        $overlap = @(Compare-Object @($titleTokens) @($candidateTokens) -IncludeEqual -ExcludeDifferent).Count
        if ($overlap -ge $MinTokenOverlap) {
            [pscustomobject]@{ Number = $candidate.number; Title = $candidate.title; Overlap = $overlap }
        }
    }

    $results | Sort-Object -Property Overlap -Descending
}

Export-ModuleMember -Function Get-IssueScopeClassification, Find-PossibleDuplicateIssue, ConvertTo-SafeLabelList
