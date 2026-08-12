# Pure, side-effect-free orchestration decision logic for public issue triage - extracted from
# Invoke-IssueTriage.ps1 so it can be unit tested without any network/GitHub API access. Nothing
# in this module makes an HTTP call, executes issue text, or reads/writes files.

Set-StrictMode -Version Latest

function Test-IsAcceptedNoOp {
    <#
        .SYNOPSIS
        True when an issue already carries the human-only 'accepted' label, in which case the
        orchestrator must make zero API calls that mutate the issue (no comment, no labels).
    #>
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Labels)
    return [bool]($Labels -contains 'accepted')
}

function Get-PreviousLabelsApplied {
    <#
        .SYNOPSIS
        Recovers the set of managed labels this automation applied on a prior run, by parsing the
        `labelsApplied` field out of the existing triage comment's embedded structured JSON (if
        any). Used purely to reconcile labels; never trusted for anything security-relevant.
    #>
    param([Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $ExistingCommentBody)

    if (-not $ExistingCommentBody) { return @() }
    $jsonMatch = [regex]::Match($ExistingCommentBody, '(?s)```json\s*(?<json>\{.*?\})\s*```')
    if (-not $jsonMatch.Success) { return @() }
    try {
        $parsed = $jsonMatch.Groups['json'].Value | ConvertFrom-Json
        return @($parsed.labelsApplied)
    } catch {
        return @()
    }
}

function Get-LabelReconciliationPlan {
    <#
        .SYNOPSIS
        Computes which managed labels to add and remove so the issue's labels match what is
        currently desired, without ever touching 'accepted' or any label outside the managed set
        (component/human labels are always preserved untouched).
    #>
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $DesiredLabels,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $CurrentLabels,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $ManagedLabels
    )

    $desiredSafe = @($DesiredLabels | Where-Object { $_ -ne 'accepted' } | Select-Object -Unique)
    $currentManaged = @($CurrentLabels | Where-Object { $ManagedLabels -contains $_ })

    $toAdd = @($desiredSafe | Where-Object { $currentManaged -notcontains $_ })
    $toRemove = @($currentManaged | Where-Object { ($desiredSafe -notcontains $_) -and ($_ -ne 'accepted') })

    [pscustomobject]@{ ToAdd = $toAdd; ToRemove = $toRemove }
}

function Test-ExactDuplicateTitle {
    <#
        .SYNOPSIS
        True only when two titles are identical after normalizing whitespace/punctuation/case -
        the sole condition under which the automation is permitted to auto-apply the 'duplicate'
        label; anything less exact stays informational-only in the report.
    #>
    param([Parameter(Mandatory)] [string] $TitleA, [Parameter(Mandatory)] [string] $TitleB)
    $normalize = { param($s) ($s -replace '\W+', ' ').Trim().ToLowerInvariant() }
    return ((& $normalize $TitleA) -eq (& $normalize $TitleB))
}

function Resolve-OverallTier1Status {
    <#
        .SYNOPSIS
        Combines the per-ALTools-version Tier 1 results (each already resolved to
        reproduced/not_reproduced/inconclusive by DiagnosticMatcher) into one overall reproduction
        status, proof, and confidence for the report. "Reproduced" wins if any version reproduced
        the cited symptom; otherwise "not_reproduced" wins over "inconclusive" (evidence that ruled
        something out is stronger than no evidence at all); with nothing restored, the result is
        "blocked".
    #>
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [array] $RestoredStatuses)

    if ($RestoredStatuses.Count -eq 0) {
        return [pscustomobject]@{ Reproduction = 'blocked'; Proof = 'unverified'; Confidence = 'low' }
    }
    if ($RestoredStatuses -contains 'reproduced') {
        return [pscustomobject]@{ Reproduction = 'reproduced'; Proof = 'execution'; Confidence = 'high' }
    }
    if ($RestoredStatuses -contains 'not_reproduced') {
        return [pscustomobject]@{ Reproduction = 'not_reproduced'; Proof = 'execution'; Confidence = 'medium' }
    }
    return [pscustomobject]@{ Reproduction = 'inconclusive'; Proof = 'execution'; Confidence = 'low' }
}

Export-ModuleMember -Function Test-IsAcceptedNoOp, Get-PreviousLabelsApplied, Get-LabelReconciliationPlan, Test-ExactDuplicateTitle, Resolve-OverallTier1Status
