[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$commentPath = Join-Path $env:RUNNER_TEMP 'al-triage-comment.md'
$comment = Get-Content -LiteralPath $commentPath -Raw
. (Join-Path $PSScriptRoot 'Assert-AlIssueTriageEvidence.ps1')

$requiredText = @(
    '## Automated AL issue triage',
    '**Classification:**',
    '**Summary:**',
    '### Environment',
    '**AL Development Tools:**',
    '**Business Central artifact:**',
    '### Attempts and results',
    '| Report completeness |',
    '| Duplicate search |',
    '| Repository investigation |',
    '| ALTool reproduction |',
    '| BC runtime reproduction |',
    '### Assessment',
    '### Recommended next step'
)
foreach ($text in $requiredText) {
    if (-not $comment.Contains($text)) {
        throw "Triage output is missing required text '$text'."
    }
}

if (-not $comment.StartsWith('## Automated AL issue triage', [StringComparison]::Ordinal)) {
    throw 'Triage output contains text before the required heading.'
}
if ($comment.Length -gt 12000) {
    throw "Triage output is too long ($($comment.Length) characters)."
}
if ($env:BC_SERVER_PASSWORD -and $comment.Contains($env:BC_SERVER_PASSWORD)) {
    throw 'Triage output contains the ephemeral sandbox password.'
}
Assert-AlIssueTriageEvidence -Comment $comment
if (git status --porcelain) {
    throw 'The triage agent modified tracked or untracked repository files.'
}

"## Triage result for issue #$env:TRIAGE_ISSUE_NUMBER" |
    Add-Content -Path $env:GITHUB_STEP_SUMMARY
if ($env:TRIAGE_DRY_RUN -eq 'true') {
    '> Dry run: validated and archived without posting to GitHub.' |
        Add-Content -Path $env:GITHUB_STEP_SUMMARY
}
$comment | Add-Content -Path $env:GITHUB_STEP_SUMMARY
