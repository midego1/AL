[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$workflow = Get-Content (Join-Path $repositoryRoot '.github\workflows\al-issue-triage.yml') -Raw
$setup = Get-Content (Join-Path $repositoryRoot '.github\workflows\copilot-setup-steps.yml') -Raw
$instructions = Get-Content (
    Join-Path $repositoryRoot '.github\agents\al-issue-triager\AGENTS.md'
) -Raw

function Assert-Contains([string] $Text, [string] $Expected) {
    if (-not $Text.Contains($Expected)) {
        throw "Expected text was not found: $Expected"
    }
}

foreach ($text in @(
    'dry_run:',
    'default: true',
    "TRIAGE_DRY_RUN: `${{ github.event_name == 'issues' || inputs.dry_run }}",
    "if: env.TRIAGE_DRY_RUN != 'true'",
    'Upload triage report',
    '$rawOutput.Substring($headingIndex).Trim()',
    "StartsWith('## Automated AL issue triage'",
    "'al-language' = @{",
    "command = 'al'",
    "@('launchmcpserver', '--transport', 'stdio')",
    '--additional-mcp-config "@$mcpConfigPath"',
    'BC_SERVER_USERNAME=admin',
    'BC_SERVER_PASSWORD=$passwordText'
)) {
    Assert-Contains $workflow $text
}

foreach ($text in @(
    'BC_SERVER_USERNAME=admin',
    'BC_SERVER_PASSWORD=$passwordText'
)) {
    Assert-Contains $setup $text
}

foreach ($text in @(
    'AL language MCP server launched by ALTool',
    '`al_downloadsymbols`',
    'never invoke `alc.exe` directly',
    'never call `/dev/packages` manually',
    'Do not disclose sandbox/container availability',
    'The first output characters must'
)) {
    Assert-Contains $instructions $text
}

if ($instructions.Contains('**Business Central container:**') -or
    $workflow.Contains('**Business Central container:**')) {
    throw 'The public output contract still exposes container availability.'
}

foreach ($obsolete in @(
    '"BC_USERNAME=admin"',
    '"BC_PASSWORD=$passwordText"'
)) {
    if ($workflow.Contains($obsolete) -or $setup.Contains($obsolete)) {
        throw "Obsolete ALTool credential variable remains: $obsolete"
    }
}

Write-Host 'AL issue triage workflow contracts passed.'
