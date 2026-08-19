[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$commentPath = Join-Path $env:RUNNER_TEMP 'al-triage-comment.md'
$existingComment = gh api `
    "repos/$env:GITHUB_REPOSITORY/issues/$env:TRIAGE_ISSUE_NUMBER/comments" `
    --paginate `
    --jq '.[] | select(.body | startswith("## Automated AL issue triage")) | .id' |
    Select-Object -First 1
if ($existingComment) {
    Write-Host "Issue #$env:TRIAGE_ISSUE_NUMBER already has an automated triage comment."
    exit 0
}

gh issue comment $env:TRIAGE_ISSUE_NUMBER `
    --repo $env:GITHUB_REPOSITORY `
    --body-file $commentPath
