#Requires -Version 7.0
<#
    .SYNOPSIS
    Entry point for public microsoft/AL issue triage. Runs the deterministic scope prefilter,
    safe fixture extraction, Tier-1 (and optionally Tier-2) reproduction, and posts an idempotent,
    structured triage comment plus labels via the github.com GITHUB_TOKEN only.

    .DESCRIPTION
    SECURITY BOUNDARY (see repo instructions): this script and everything it calls MUST NOT
    reference GHE/ADO endpoints, private feeds, or private credentials. It only ever talks to the
    public github.com REST API using the workflow-scoped GITHUB_TOKEN, and only ever restores
    packages from the public NuGet.org / PowerShell Gallery feeds. Issue text/AL is untrusted and
    is only used as inert data (regex classification, fixture extraction) - never executed as
    instructions, and never used to clone/execute a linked repository or script.
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
Import-Module (Join-Path $PSScriptRoot 'Tier1Reproduction.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Tier2ContainerReproduction.psm1') -Force

function Invoke-GitHubApi {
    param(
        [Parameter(Mandatory)] [string] $Method,
        [Parameter(Mandatory)] [string] $Path, # relative to https://api.github.com
        [Parameter(Mandatory)] [string] $Token,
        [object] $Body
    )

    $uri = "https://api.github.com$Path"
    $headers = @{
        Authorization = "Bearer $Token"
        Accept        = 'application/vnd.github+json'
        'User-Agent'  = 'al-public-issue-triage'
    }

    $params = @{ Method = $Method; Uri = $uri; Headers = $headers }
    if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 10); $params.ContentType = 'application/json' }

    Invoke-RestMethod @params
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
    param([Parameter(Mandatory)] [int] $IssueNumber, [Parameter(Mandatory)] [string] $Repo, [Parameter(Mandatory)] [string] $Body, [Parameter(Mandatory)] [string] $Token)
    $existing = Get-ExistingTriageComment -IssueNumber $IssueNumber -Repo $Repo -Token $Token
    if ($existing) {
        Invoke-GitHubApi -Method PATCH -Path "/repos/$Repo/issues/comments/$($existing.id)" -Body @{ body = $Body } -Token $Token | Out-Null
    } else {
        Invoke-GitHubApi -Method POST -Path "/repos/$Repo/issues/$IssueNumber/comments" -Body @{ body = $Body } -Token $Token | Out-Null
    }
}

function Add-TriageLabel {
    <#
        .SYNOPSIS
        Applies the deterministically suggested labels to an issue. Never sends 'accepted'.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal orchestration helper invoked non-interactively by the workflow; not a user-facing cmdlet requiring -WhatIf/-Confirm.')]
    param([Parameter(Mandatory)] [int] $IssueNumber, [Parameter(Mandatory)] [string] $Repo, [Parameter(Mandatory)] [string[]] $Labels, [Parameter(Mandatory)] [string] $Token)
    # Defense in depth: never send the 'accepted' label even if some earlier filter regressed.
    $safeLabels = $Labels | Where-Object { $_ -and $_ -ne 'accepted' }
    if ($safeLabels.Count -eq 0) { return }
    Invoke-GitHubApi -Method POST -Path "/repos/$Repo/issues/$IssueNumber/labels" -Body @{ labels = @($safeLabels) } -Token $Token | Out-Null
}

# ---- 1. Fetch the issue (untrusted content) ----
$issue = Invoke-GitHubApi -Method GET -Path "/repos/$Repo/issues/$IssueNumber" -Token $GitHubToken
$title = $issue.title
$body = $issue.body
$existingLabels = @($issue.labels | ForEach-Object { $_.name })

# ---- 2. Deterministic scope/template prefilter ----
$classification = Get-IssueScopeClassification -Title $title -Body $body -Labels $existingLabels

$reportedVersionMatch = [regex]::Match($body, '(?im)^\s*-?\s*(AL (Language|Extension) )?Version\s*:\s*(?<v>\S+)')
$reportedVersion = if ($reportedVersionMatch.Success) { $reportedVersionMatch.Groups['v'].Value } else { $null }

$reproduction = 'not_attempted'
$proof = 'unverified'
$confidence = 'low'
$tier = 'none'
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
            $tier1 = Invoke-Tier1Reproduction -ProjectPath $projectPath -ReportedVersion $reportedVersion
            $tier = '1-server-free'

            foreach ($label in $tier1.PSObject.Properties.Name) {
                $entry = $tier1.$label
                $testedVersions[$label] = $entry.Version
                if ($entry.Command) { $commands += $entry.Command }
                if (-not $entry.Restored) { $blockers += "Could not restore ALTools $($entry.Version) ($label): package restore failed." }
            }

            $reproducedAny = $tier1.PSObject.Properties.Value | Where-Object { $_.Reproduced } | Select-Object -First 1
            if ($reproducedAny) {
                $reproduction = 'reproduced'
                $proof = 'execution'
                $confidence = 'high'
            } elseif (($tier1.PSObject.Properties.Value | Where-Object { $_.Restored }).Count -gt 0) {
                $reproduction = 'not_reproduced'
                $proof = 'execution'
                $confidence = 'medium'
            } else {
                $reproduction = 'blocked'
                $blockers += 'No pinned ALTools package version could be restored; server-free reproduction was not possible.'
            }

            # ---- 5. Optional Tier 2: disposable stock BC container ----
            if ($AllowContainerReproduction -and $reproduction -ne 'reproduced') {
                $safety = Test-AlFixtureRuntimeSafety -Files $fixture.Files
                if (-not $safety.IsRuntimeSafe) {
                    $blockers += ($safety.Violations | ForEach-Object { "Runtime execution refused: $($_.Reason) (file: $($_.File))" })
                } else {
                    $tier2 = Invoke-Tier2ContainerReproduction -ProjectPath $projectPath -SafetyResult $safety -BcVersionHint $reportedVersion
                    if ($tier2.Attempted) {
                        $tier = '2-container'
                        if ($tier2.Reproduced) { $reproduction = 'reproduced'; $proof = 'execution'; $confidence = 'high' }
                        if ($tier2.Blocked) { $blockers += $tier2.Reason }
                    } else {
                        $blockers += $tier2.Reason
                    }
                }
            }
        }

        Remove-Item -Path $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
} elseif ($classification.ManualReproductionRequired) {
    $reproduction = 'blocked'
    $tier = '3-inconclusive'
    $blockers += 'Editor/UI-host behavior cannot be reproduced by a headless workflow; needs manual reproduction on a real editor session.'
}

# ---- 6. Build and post the structured, idempotent public report ----
$recommendedNextAction = switch ($classification.Scope) {
    'out_of_scope' { 'No further automated action. A maintainer may close/redirect per the reason above.' }
    'needs_human'  { 'Reporter should supply the missing information; automated re-triage will run again once the issue is edited.' }
    default        {
        if ($reproduction -eq 'reproduced') { 'Ready for maintainer review; a human can apply `accepted` to trigger internal follow-up.' }
        elseif ($tier -eq '3-inconclusive') { 'Needs manual reproduction by a maintainer or the reporter.' }
        else { 'Needs maintainer triage; automated reproduction was inconclusive or blocked (see blockers).' }
    }
}

$report = New-TriageReport `
    -IssueNumber $IssueNumber -Repo $Repo `
    -Scope $classification.Scope -Category $classification.Category -Reason $classification.Reason `
    -Reproduction $reproduction -Proof $proof -Confidence $confidence -Tier $tier `
    -TestedVersions $testedVersions -Commands $commands -Blockers $blockers `
    -RecommendedNextAction $recommendedNextAction -LabelsApplied $classification.SuggestedLabels

$commentBody = Format-TriageComment -Report $report

if ($DryRun) {
    Write-Output "== DRY RUN: no comment/labels will be posted =="
    Write-Output $commentBody
} else {
    Set-TriageComment -IssueNumber $IssueNumber -Repo $Repo -Body $commentBody -Token $GitHubToken
    if ($classification.SuggestedLabels.Count -gt 0) {
        Add-TriageLabel -IssueNumber $IssueNumber -Repo $Repo -Labels $classification.SuggestedLabels -Token $GitHubToken
    }
}

$report | ConvertTo-Json -Depth 6
