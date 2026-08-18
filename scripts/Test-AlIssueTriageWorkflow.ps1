[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$workflow = Get-Content (Join-Path $repositoryRoot '.github\workflows\al-issue-triage.yml') -Raw
$setup = Get-Content (Join-Path $repositoryRoot '.github\workflows\copilot-setup-steps.yml') -Raw
$instructions = Get-Content (
    Join-Path $repositoryRoot '.github\agents\al-issue-triager\AGENTS.md'
) -Raw
$symbolSkill = Get-Content (
    Join-Path $repositoryRoot '.github\skills\download-al-symbols\SKILL.md'
) -Raw
$symbolScript = Get-Content (
    Join-Path $repositoryRoot '.github\skills\download-al-symbols\Invoke-DownloadAlSymbols.ps1'
) -Raw

function Assert-Contains([string] $Text, [string] $Expected) {
    if (-not $Text.Contains($Expected)) {
        throw "Expected text was not found: $Expected"
    }
}

foreach ($text in @(
    'dry_run:',
    'default: true',
    'Microsoft.Dynamics.BusinessCentral.Development.Tools --prerelease',
    "TRIAGE_DRY_RUN: `${{ github.event_name == 'issues' || inputs.dry_run }}",
    "if: env.TRIAGE_DRY_RUN != 'true'",
    'Upload triage report',
    '$rawOutput.Substring($headingIndex).Trim()',
    "StartsWith('## Automated AL issue triage'",
    'ALTOOL_PATH=$altoolPath',
    'Invoke the download-al-symbols skill',
    'BC_SERVER_USERNAME=admin',
    'BC_SERVER_PASSWORD=$passwordText',
    'BC_SERVER_PORT=7049'
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
    'freshly installed prerelease ALTool',
    '`download-al-symbols`',
    'never invoke `alc.exe` directly',
    'never call `/dev/packages` manually',
    'Do not disclose sandbox/container availability',
    'The first output characters must'
)) {
    Assert-Contains $instructions $text
}

foreach ($text in @(
    '$env:ALTOOL_PATH',
    '& $altoolPath --version',
    "'al_downloadsymbols'",
    'BC_SERVER_USERNAME',
    'BC_SERVER_PASSWORD',
    "contains no symbol packages"
)) {
    Assert-Contains $symbolScript $text
}

foreach ($text in @(
    'prerelease ALTool',
    'Do not invoke `alc.exe`',
    'Do not invoke `alc.exe`, launch or script an MCP server yourself'
)) {
    Assert-Contains $symbolSkill $text
}

foreach ($forbidden in @(
    '--additional-mcp-config',
    "'al-language' = @{"
)) {
    if ($workflow.Contains($forbidden)) {
        throw "The triage agent still receives direct MCP configuration: $forbidden"
    }
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
