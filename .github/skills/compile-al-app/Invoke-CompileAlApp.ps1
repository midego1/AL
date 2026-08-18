[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ProjectPath,

    [string] $PackageCachePath,

    [string] $OutputPath,

    [string[]] $CompilerArgument = @()
)

$ErrorActionPreference = 'Stop'
$project = (Resolve-Path -LiteralPath $ProjectPath).Path
$manifestPath = Join-Path $project 'app.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "AL project manifest not found: $manifestPath"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$hasSymbolReferences =
    ($manifest.PSObject.Properties['platform'] -and $manifest.platform) -or
    ($manifest.PSObject.Properties['application'] -and $manifest.application) -or
    ($manifest.PSObject.Properties['dependencies'] -and @($manifest.dependencies).Count -gt 0)

$altool = $env:ALTOOL_PATH
if (-not (Test-Path -LiteralPath $altool -PathType Leaf)) {
    throw "Prerelease ALTool not found: $altool"
}
$version = (& $altool --version 2>&1 | Out-String).Trim()
if ($version -ne $env:ALTOOL_VERSION) {
    throw "Expected ALTool '$env:ALTOOL_VERSION', got '$version'."
}

if (-not $PackageCachePath) {
    $PackageCachePath = Join-Path $project '.alpackages'
}
$packageCache = [IO.Path]::GetFullPath($PackageCachePath)
if ($hasSymbolReferences -and
    @(Get-ChildItem -LiteralPath $packageCache -Filter '*.app' -File -ErrorAction SilentlyContinue).Count -eq 0) {
    throw "Project '$project' requires symbols. Invoke download-al-symbols first."
}

if (-not $OutputPath) {
    $safeName = ([string]$manifest.name -replace '[^A-Za-z0-9._-]', '-').Trim('-')
    $temporaryRoot = if ($env:RUNNER_TEMP) {
        $env:RUNNER_TEMP
    } else {
        [IO.Path]::GetTempPath()
    }
    $outputDirectory = Join-Path $temporaryRoot "al-triage-build\$([guid]::NewGuid().ToString('N'))"
    $OutputPath = Join-Path $outputDirectory "$safeName.app"
}
$output = [IO.Path]::GetFullPath($OutputPath)
New-Item -ItemType Directory -Path (Split-Path -Parent $output) -Force | Out-Null
Remove-Item -LiteralPath $output -Force -ErrorAction SilentlyContinue

$arguments = @('compile', "/project:$project", "/out:$output")
if (Test-Path -LiteralPath $packageCache) {
    $arguments += "/packagecachepath:$packageCache"
}
$arguments += $CompilerArgument

$stdout = @(& $altool @arguments 2>&1)
$exitCode = $LASTEXITCODE
$outputText = ($stdout | Out-String).Trim()
if ($exitCode -ne 0) {
    [ordered]@{
        succeeded = $false
        nativeExitCode = $exitCode
        projectPath = $project
        appPath = $output
        output = $outputText
    } | ConvertTo-Json -Depth 5
    exit $exitCode
}
if (-not (Test-Path -LiteralPath $output -PathType Leaf) -or (Get-Item $output).Length -le 0) {
    throw "ALTool exited successfully without emitting a non-empty package at '$output'."
}

$packageManifest = (& $altool GetPackageManifest $output 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $packageManifest) {
    throw "ALTool could not read the emitted package manifest: $packageManifest"
}

[ordered]@{
    succeeded = $true
    nativeExitCode = 0
    altoolVersion = $version
    projectPath = $project
    packageCachePath = $packageCache
    appPath = $output
    appSize = (Get-Item $output).Length
    package = ($packageManifest | ConvertFrom-Json)
    output = $outputText
} | ConvertTo-Json -Depth 6
