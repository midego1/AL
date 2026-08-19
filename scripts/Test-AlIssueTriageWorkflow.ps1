[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$workflow = Get-Content (Join-Path $repositoryRoot '.github\workflows\al-issue-triage.yml') -Raw

function Assert-Contains([string] $Text, [string] $Expected) {
    if (-not $Text.Contains($Expected)) {
        throw "Expected text was not found: $Expected"
    }
}

$workflowScriptsRoot = Join-Path $repositoryRoot 'scripts\al-issue-triage'
$workflowScripts = @{}
foreach ($scriptName in @(
    'Install-TriageTools.ps1',
    'Start-TriageSandbox.ps1',
    'Test-AlToolSandboxAccess.ps1',
    'Get-TriggeringIssue.ps1',
    'Invoke-AlIssueTriage.ps1',
    'Test-AlIssueTriageOutput.ps1',
    'Publish-AlIssueTriageComment.ps1',
    'Stop-TriageSandbox.ps1'
)) {
    $scriptPath = Join-Path $workflowScriptsRoot $scriptName
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Required workflow script is missing: $scriptName"
    }
    $workflowScripts[$scriptName] = Get-Content -LiteralPath $scriptPath -Raw
    Assert-Contains $workflow ".\scripts\al-issue-triage\$scriptName"
}
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
$compileScript = Get-Content (
    Join-Path $repositoryRoot '.github\skills\compile-al-app\Invoke-CompileAlApp.ps1'
) -Raw
$agentRegistration = Get-Content (
    Join-Path $repositoryRoot '.github\agents\al-issue-triager.agent.md'
) -Raw

foreach ($text in @(
    'dry_run:',
    'default: true',
    "TRIAGE_DRY_RUN: `${{ github.event_name == 'issues' || inputs.dry_run }}",
    "if: env.TRIAGE_DRY_RUN != 'true'",
    'Upload triage report',
    'Verify prerelease ALTool sandbox access',
    '${{ github.token }}',
    'if: always()',
    'actions/upload-artifact@'
)) {
    Assert-Contains $workflow $text
}

foreach ($assertion in @(
    @{ Script = 'Install-TriageTools.ps1'; Text = 'Microsoft.Dynamics.BusinessCentral.Development.Tools --prerelease' },
    @{ Script = 'Install-TriageTools.ps1'; Text = 'ALTOOL_PATH=$altoolPath' },
    @{ Script = 'Start-TriageSandbox.ps1'; Text = 'BC_SERVER_USERNAME=admin' },
    @{ Script = 'Start-TriageSandbox.ps1'; Text = 'BC_SERVER_PASSWORD=$passwordText' },
    @{ Script = 'Start-TriageSandbox.ps1'; Text = 'BC_SERVER_PORT=7049' },
    @{ Script = 'Start-TriageSandbox.ps1'; Text = 'BC_TENANT=default' },
    @{ Script = 'Invoke-AlIssueTriage.ps1'; Text = '$rawOutput.Substring($headingIndex).Trim()' },
    @{ Script = 'Invoke-AlIssueTriage.ps1'; Text = 'Invoke verify-prerelease-altool first' },
    @{ Script = 'Invoke-AlIssueTriage.ps1'; Text = 'run-al-code-analysis, publish-al-app, run-al-tests, and verify-al-e2e' },
    @{ Script = 'Test-AlIssueTriageOutput.ps1'; Text = "StartsWith('## Automated AL issue triage'" }
)) {
    Assert-Contains $workflowScripts[$assertion.Script] $assertion.Text
}

if ([regex]::Matches($workflow, '(?m)^\s+run:\s+\|').Count -ne 0) {
    throw 'The triage workflow contains inline PowerShell instead of checked-in scripts.'
}

foreach ($text in @(
    'BC_SERVER_USERNAME=admin',
    'BC_SERVER_PASSWORD=$passwordText',
    'BC_TENANT=default'
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
    'BC_TENANT',
    "contains no symbol packages"
)) {
    Assert-Contains $symbolScript $text
}
if ($symbolScript.Contains('Get-Command al')) {
    throw 'The symbol wrapper can escape the workflow-installed prerelease ALTool.'
}

foreach ($text in @(
    '$env:ALTOOL_PATH',
    '$env:ALTOOL_VERSION',
    '"/project:$project"',
    'Invoke download-al-symbols first',
    'GetPackageManifest'
)) {
    Assert-Contains $compileScript $text
}
if ($compileScript.Contains('alc.exe')) {
    throw 'The compile wrapper invokes the compiler directly.'
}

foreach ($text in @(
    'prerelease ALTool',
    'Do not invoke `alc.exe`',
    'Do not invoke `alc.exe`, launch or script an MCP server yourself'
)) {
    Assert-Contains $symbolSkill $text
}

$requiredSkills = @(
    'verify-prerelease-altool',
    'create-al-project',
    'download-al-symbols',
    'compile-al-app',
    'run-al-code-analysis',
    'publish-al-app',
    'run-al-tests',
    'verify-al-e2e'
)
foreach ($skill in $requiredSkills) {
    $skillPath = Join-Path $repositoryRoot ".github\skills\$skill\SKILL.md"
    if (-not (Test-Path -LiteralPath $skillPath -PathType Leaf)) {
        throw "Required triage skill is missing: $skill"
    }
    Assert-Contains $agentRegistration "- ``$skill``"
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
    $workflow.Contains('**Business Central container:**') -or
    ($workflowScripts.Values -match [regex]::Escape('**Business Central container:**'))) {
    throw 'The public output contract still exposes container availability.'
}

foreach ($obsolete in @(
    '"BC_USERNAME=admin"',
    '"BC_PASSWORD=$passwordText"'
)) {
    if ($workflow.Contains($obsolete) -or $setup.Contains($obsolete) -or
        ($workflowScripts.Values -match [regex]::Escape($obsolete))) {
        throw "Obsolete ALTool credential variable remains: $obsolete"
    }
}

Write-Host 'AL issue triage workflow contracts passed.'
