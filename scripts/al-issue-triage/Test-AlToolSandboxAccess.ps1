[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectPath = Join-Path $env:RUNNER_TEMP 'altool-sandbox-preflight'
New-Item -ItemType Directory -Path $projectPath -Force | Out-Null

$artifactVersion = [regex]::Match(
    $env:BC_ARTIFACT_URL,
    '/(?<version>\d+\.\d+\.\d+\.\d+)/'
).Groups['version'].Value
if (-not $artifactVersion) {
    throw "Could not determine the BC artifact version from '$env:BC_ARTIFACT_URL'."
}

$versionParts = $artifactVersion.Split('.')
$applicationVersion = "$($versionParts[0]).$($versionParts[1]).0.0"
[ordered]@{
    id = [guid]::NewGuid().ToString()
    name = 'Public AL Triage Preflight'
    publisher = 'Microsoft'
    version = '1.0.0.0'
    platform = $applicationVersion
    application = $applicationVersion
    target = 'OnPrem'
    idRanges = @([ordered]@{ from = 50100; to = 50100 })
} | ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath (Join-Path $projectPath 'app.json') -Encoding utf8

try {
    & .\.github\skills\download-al-symbols\Invoke-DownloadAlSymbols.ps1 `
        -ProjectPath $projectPath
}
finally {
    Remove-Item -LiteralPath $projectPath -Recurse -Force -ErrorAction SilentlyContinue
}
