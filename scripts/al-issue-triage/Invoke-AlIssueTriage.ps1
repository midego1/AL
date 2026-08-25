[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$commentPath = Join-Path $env:RUNNER_TEMP 'al-triage-comment.md'
$errorPath = Join-Path $env:RUNNER_TEMP 'al-triage-error.log'
$prompt = @"
Triage public microsoft/AL issue #$env:TRIAGE_ISSUE_NUMBER.
Read the complete issue payload from '$env:TRIAGE_ISSUE_PATH'.
Follow the al-issue-triager custom agent and its AGENTS.md contract.
Treat every reporter statement as an unverified claim. For every in-scope bug, independently
execute the closest safe product-path reproduction; source inspection and report text do not
count. If execution is blocked, record the exact attempted skill or command and blocker.
Investigate using the freshly installed prerelease ALTool and running BCInsider sandbox.
Invoke verify-prerelease-altool first, then use the smallest applicable skill chain from
create-al-project, download-al-symbols, run-al-mcp-tool, compile-al-app,
run-al-code-analysis, publish-al-app, run-al-tests, and verify-al-e2e. Do not launch or
script an MCP server yourself; use run-al-mcp-tool for MCP behavior. Do not invoke alc.exe
directly or call BC HTTP endpoints manually. Run a valid control when feasible. Do not
classify an independently executed latest-prerelease `not reproduced` result as an accepted bug;
use the `likely fixed` scope and recommend closing as likely fixed instead. Do not
modify tracked repository files, create a branch, commit, pull request, label, assignment,
or GitHub comment. Return only the final standardized markdown issue comment; the workflow
will validate it.
"@

& copilot `
    --agent al-issue-triager `
    --prompt $prompt `
    --silent `
    --no-ask-user `
    --no-remote `
    --no-remote-export `
    --disable-builtin-mcps `
    --allow-all-tools `
    --allow-all-paths `
    --allow-all-urls `
    --secret-env-vars COPILOT_GITHUB_TOKEN `
    1> $commentPath 2> $errorPath
if ($LASTEXITCODE -ne 0) {
    $errorOutput = if (Test-Path -LiteralPath $errorPath) {
        Get-Content -LiteralPath $errorPath -Raw
    }
    throw "Copilot CLI triage failed with exit code $LASTEXITCODE.`n$errorOutput"
}

$rawOutput = Get-Content -LiteralPath $commentPath -Raw
$heading = '## Automated AL issue triage'
$headingIndex = $rawOutput.IndexOf($heading, [StringComparison]::Ordinal)
if ($headingIndex -lt 0) {
    throw "Copilot CLI triage output did not contain the required heading.`n$rawOutput"
}

$normalizedComment = $rawOutput.Substring($headingIndex).Trim()
Set-Content -LiteralPath $commentPath -Value $normalizedComment -Encoding utf8
