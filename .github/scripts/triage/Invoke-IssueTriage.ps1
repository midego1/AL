#Requires -Version 7.0
<#
    .SYNOPSIS
    Entry point for public microsoft/AL issue triage. Runs the deterministic scope prefilter,
    safe fixture extraction, Tier-1 (and optionally Tier-2) reproduction, and posts an idempotent,
    structured triage comment plus reconciled labels via the github.com GITHUB_TOKEN only.

    .DESCRIPTION
    SECURITY BOUNDARY (see repo instructions): this script and everything it calls MUST NOT
    reference GHE/ADO endpoints, private feeds, or private credentials. It only ever talks to the
    public github.com REST API (https://api.github.com) using the workflow-scoped GITHUB_TOKEN,
    and only ever restores packages from the public NuGet.org / PowerShell Gallery feeds. Issue
    text/AL is untrusted and is only used as inert data (regex classification, fixture extraction)
    - never executed as instructions, and never used to clone/execute a linked repository/script.

    If the issue already carries the human-only 'accepted' label, this script is a strict no-op:
    it makes no API calls that mutate the issue at all (no comment, no label changes), because
    acceptance is a terminal, human decision this automation must never revisit. All decision
    logic that does not require live network access lives in OrchestratorLogic.psm1 and is unit
    tested there (tests/OrchestratorLogic.Tests.ps1); this script is the thin network-calling glue.
#>
param(
    [Parameter(Mandatory)] [int] $IssueNumber,
    [Parameter(Mandatory)] [string] $Repo, # "owner/repo", e.g. "microsoft/AL"
    [Parameter(Mandatory)] [string] $GitHubToken,
    [switch] $AllowContainerReproduction,
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ScopePrefilter.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'FixtureExtractor.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SafetyGuard.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ReportBuilder.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DiagnosticMatcher.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Tier1Reproduction.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Tier2ContainerReproduction.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'OrchestratorLogic.psm1') -Force

# The one and only base URI this script (or anything it calls) is permitted to reach: the public
# github.com REST API for this repository. Never GHE, ADO, or a private feed/host.
$script:GitHubApiBase = 'https://api.github.com'

function Invoke-GitHubApi {
    param(
        [Parameter(Mandatory)] [string] $Method,
        [Parameter(Mandatory)] [string] $Path, # relative to $script:GitHubApiBase
        [Parameter(Mandatory)] [string] $Token,
        [object] $Body,
        [switch] $IgnoreNotFound
    )

    $uri = "$script:GitHubApiBase$Path"
    $headers = @{
        Authorization = "Bearer $Token"
        Accept        = 'application/vnd.github+json'
        'User-Agent'  = 'al-public-issue-triage'
    }

    $params = @{ Method = $Method; Uri = $uri; Headers = $headers }
    if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 10); $params.ContentType = 'application/json' }

    try {
        Invoke-RestMethod @params
    } catch {
        if ($IgnoreNotFound -and $_.Exception.Response -and $_.Exception.Response.StatusCode -eq 404) { return $null }
        throw
    }
}

function Get-ExistingTriageComment {
    param([Parameter(Mandatory)] [int] $IssueNumber, [Parameter(Mandatory)] [string] $Repo, [Parameter(Mandatory)] [string] $Token)
    $marker = Get-TriageMarker -IssueNumber $IssueNumber
    $comments = Invoke-GitHubApi -Method GET -Path "/repos/$Repo/issues/$IssueNumber/comments?per_page=100" -Token $Token
    $comments | Where-Object { $_.body -like "$marker*" } | Select-Object -First 1
}

function Set-TriageComment {
    <#
        .SYNOPSIS
        Idempotently creates or updates the single triage comment on an issue (never duplicates it).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal orchestration helper invoked non-interactively by the workflow; not a user-facing cmdlet requiring -WhatIf/-Confirm.')]
    param([Parameter(Mandatory)] [int] $IssueNumber, [Parameter(Mandatory)] [string] $Repo, [Parameter(Mandatory)] [string] $Body, [Parameter(Mandatory)] [string] $Token, [object] $ExistingComment)
    if ($ExistingComment) {
        Invoke-GitHubApi -Method PATCH -Path "/repos/$Repo/issues/comments/$($ExistingComment.id)" -Body @{ body = $Body } -Token $Token | Out-Null
    } else {
        Invoke-GitHubApi -Method POST -Path "/repos/$Repo/issues/$IssueNumber/comments" -Body @{ body = $Body } -Token $Token | Out-Null
    }
}

function Sync-TriageLabel {
    <#
        .SYNOPSIS
        Applies the add/remove plan computed by OrchestratorLogic's Get-LabelReconciliationPlan.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal orchestration helper invoked non-interactively by the workflow; not a user-facing cmdlet requiring -WhatIf/-Confirm.')]
    param([Parameter(Mandatory)] [int] $IssueNumber, [Parameter(Mandatory)] [string] $Repo, [Parameter(Mandatory)] [pscustomobject] $Plan, [Parameter(Mandatory)] [string] $Token)

    if ($Plan.ToAdd.Count -gt 0) {
        Invoke-GitHubApi -Method POST -Path "/repos/$Repo/issues/$IssueNumber/labels" -Body @{ labels = @($Plan.ToAdd) } -Token $Token | Out-Null
    }
    foreach ($label in $Plan.ToRemove) {
        $encoded = [uri]::EscapeDataString($label)
        Invoke-GitHubApi -Method DELETE -Path "/repos/$Repo/issues/$IssueNumber/labels/$encoded" -Token $Token -IgnoreNotFound | Out-Null
    }
}

function Get-DuplicateCandidateIssue {
    <#
        .SYNOPSIS
        Fetches a small, bounded list of recent open issues (excluding the current one) to use as
        duplicate-suggestion candidates. Purely informational input to Find-PossibleDuplicateIssue.
    #>
    param([Parameter(Mandatory)] [int] $IssueNumber, [Parameter(Mandatory)] [string] $Repo, [Parameter(Mandatory)] [string] $Token, [int] $MaxCandidates = 30)

    $issues = Invoke-GitHubApi -Method GET -Path "/repos/$Repo/issues?state=open&per_page=$MaxCandidates&sort=created&direction=desc" -Token $Token
    @($issues | Where-Object { -not $_.pull_request -and $_.number -ne $IssueNumber } | ForEach-Object { [pscustomobject]@{ number = $_.number; title = $_.title } })
}

# ---- 1. Fetch the issue (untrusted content) ----
$issue = Invoke-GitHubApi -Method GET -Path "/repos/$Repo/issues/$IssueNumber" -Token $GitHubToken
$title = $issue.title
$body = $issue.body
$existingLabels = @($issue.labels | ForEach-Object { $_.name })

# ---- 1a. Accepted is a terminal, human-only decision: no-op immediately, no API mutations. ----
if (Test-IsAcceptedNoOp -Labels $existingLabels) {
    Write-Output "Issue #$IssueNumber already has 'accepted' - no-op (no comment/label changes, no reproduction attempted)."
    return
}

# ---- 2. Deterministic scope/template prefilter ----
$classification = Get-IssueScopeClassification -Title $title -Body $body -Labels $existingLabels

$reproduction = 'not_attempted'
$proof = 'unverified'
$confidence = 'low'
$tier = 'none'
$requiresContainer = $false
$commands = @()
$blockers = @()
$testedVersions = @{}

if ($classification.Scope -eq 'in_scope' -and -not $classification.ManualReproductionRequired) {
    # ---- 3. Safe, structured fixture extraction from inline AL only ----
    $fixture = Get-AlCodeFixture -Body $body

    if ($fixture.Blocked) {
        $reproduction = 'blocked'
        $blockers += $fixture.BlockReasons
    } else {
        if ($fixture.ExternalReference) { $blockers += $fixture.BlockReasons }

        $workRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("al-triage-$IssueNumber-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $workRoot | Out-Null
        $projectPath = New-MinimalAlProject -Files $fixture.Files -DestinationRoot $workRoot

        # ---- 4. Tier 1: server-free reproduction with pinned published ALTools packages ----
        if (-not $DryRun) {
            $tier1 = Invoke-Tier1Reproduction -ProjectPath $projectPath -IssueBody $body
            $tier = '1-server-free'

            foreach ($label in $tier1.Results.PSObject.Properties.Name) {
                $entry = $tier1.Results.$label
                $testedVersions[$label] = $entry.Version
                if ($entry.Command) { $commands += $entry.Command }
                if (-not $entry.Restored) { $blockers += "Could not restore ALTools $($entry.Version) ($label): package restore failed." }
                elseif ($entry.Reason) { $blockers += "[$label $($entry.Version)] $($entry.Reason)" }
            }

            $restoredStatuses = @($tier1.Results.PSObject.Properties.Value | Where-Object { $_.Restored } | ForEach-Object { $_.Status })
            $requiresContainer = [bool]($tier1.Results.PSObject.Properties.Value | Where-Object { $_.RequiresContainer } | Select-Object -First 1)

            $overall = Resolve-OverallTier1Status -RestoredStatuses $restoredStatuses
            $reproduction = $overall.Reproduction
            $proof = $overall.Proof
            $confidence = $overall.Confidence
            if ($reproduction -eq 'blocked') {
                $blockers += 'No pinned ALTools package version could be restored; server-free reproduction was not possible.'
            }

            # ---- 5. Optional Tier 2: disposable stock BC container ----
            if ($AllowContainerReproduction -and $reproduction -ne 'reproduced') {
                $safety = Test-AlFixtureRuntimeSafety -Files $fixture.Files
                if (-not $safety.IsRuntimeSafe) {
                    $blockers += ($safety.Violations | ForEach-Object { "Runtime execution refused: $($_.Reason) (file: $($_.File))" })
                } else {
                    $tier2 = Invoke-Tier2ContainerReproduction -ProjectPath $projectPath -Files $fixture.Files -SafetyResult $safety -IssueBody $body
                    if ($tier2.Attempted) {
                        $tier = '2-container'
                        $reproduction = $tier2.Status
                        if ($tier2.Status -eq 'reproduced') { $proof = 'execution'; $confidence = 'high' }
                        elseif ($tier2.Status -in @('not_reproduced', 'inconclusive')) { $proof = 'execution'; $confidence = 'medium' }
                        $blockers += $tier2.Reason
                    } else {
                        $blockers += $tier2.Reason
                    }
                }
            }
        }

        Remove-Item -Path $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
} elseif ($classification.ManualReproductionRequired) {
    $reproduction = 'inconclusive'
    $tier = '3-inconclusive'
    $blockers += 'Editor/UI-host behavior cannot be reproduced by a headless workflow; needs manual reproduction on a real editor session.'
}

# ---- 6. Duplicate detection (informational; never auto-applies 'duplicate' unless an exact,
#          deterministic title match is found) ----
$duplicates = @()
$exactDuplicateFound = $false
if (-not $DryRun) {
    try {
        $candidates = Get-DuplicateCandidateIssue -IssueNumber $IssueNumber -Repo $Repo -Token $GitHubToken
        $duplicateMatches = Find-PossibleDuplicateIssue -Title $title -CandidateIssues $candidates
        $duplicates = @($duplicateMatches | ForEach-Object { [pscustomobject]@{ Number = $_.Number; Title = $_.Title } })
        $exactMatch = $duplicateMatches | Where-Object { Test-ExactDuplicateTitle -TitleA $_.Title -TitleB $title } | Select-Object -First 1
        $exactDuplicateFound = [bool]$exactMatch
    } catch {
        # Duplicate search is best-effort and purely informational; never fail triage over it.
        $blockers += "Duplicate search could not be completed: $($_.Exception.Message)"
    }
}

$suggestedLabels = @($classification.SuggestedLabels)
if ($exactDuplicateFound) { $suggestedLabels = @($suggestedLabels + 'duplicate' | Select-Object -Unique) }

# ---- 7. Build and post the structured, idempotent public report ----
$recommendedNextAction = switch ($classification.Scope) {
    'out_of_scope' { 'No further automated action. A maintainer may close/redirect per the reason above.' }
    'needs_human'  { 'Reporter should supply the missing information; automated re-triage will run again once the issue is edited.' }
    default        {
        if ($reproduction -eq 'reproduced') { 'Ready for maintainer review; a human can apply `accepted` to trigger internal follow-up.' }
        elseif ($requiresContainer -and -not $AllowContainerReproduction) { 'Requires disposable-container (Tier 2) reproduction with real Business Central symbols; re-run with container reproduction enabled or reproduce manually.' }
        elseif ($tier -eq '3-inconclusive') { 'Needs manual reproduction by a maintainer or the reporter.' }
        else { 'Needs maintainer triage; automated reproduction was inconclusive or blocked (see blockers).' }
    }
}

$report = New-TriageReport `
    -IssueNumber $IssueNumber -Repo $Repo `
    -Scope $classification.Scope -Category $classification.Category -Reason $classification.Reason `
    -Reproduction $reproduction -Proof $proof -Confidence $confidence -Tier $tier -RequiresContainer $requiresContainer `
    -TestedVersions $testedVersions -Commands $commands -Blockers $blockers -Duplicates $duplicates `
    -RecommendedNextAction $recommendedNextAction -LabelsApplied $suggestedLabels

$commentBody = Format-TriageComment -Report $report

if ($DryRun) {
    Write-Output "== DRY RUN: no comment/labels will be posted =="
    Write-Output $commentBody
} else {
    $existingComment = Get-ExistingTriageComment -IssueNumber $IssueNumber -Repo $Repo -Token $GitHubToken
    Set-TriageComment -IssueNumber $IssueNumber -Repo $Repo -Body $commentBody -Token $GitHubToken -ExistingComment $existingComment

    $managed = Get-ManagedLabelSet
    $plan = Get-LabelReconciliationPlan -DesiredLabels $suggestedLabels -CurrentLabels $existingLabels -ManagedLabels $managed
    Sync-TriageLabel -IssueNumber $IssueNumber -Repo $Repo -Plan $plan -Token $GitHubToken
}

$report | ConvertTo-Json -Depth 6
