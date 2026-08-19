[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$issuePath = Join-Path $env:RUNNER_TEMP 'al-triage-issue.json'
gh api "repos/$env:GITHUB_REPOSITORY/issues/$env:ISSUE_NUMBER" |
    Set-Content -LiteralPath $issuePath -Encoding utf8

"TRIAGE_ISSUE_NUMBER=$env:ISSUE_NUMBER" | Add-Content -Path $env:GITHUB_ENV
"TRIAGE_ISSUE_PATH=$issuePath" | Add-Content -Path $env:GITHUB_ENV
