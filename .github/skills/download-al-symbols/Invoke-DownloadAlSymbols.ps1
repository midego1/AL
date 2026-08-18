[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ProjectPath,

    [string] $PackageCachePath,

    [switch] $Force,

    [int] $TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
$project = (Resolve-Path -LiteralPath $ProjectPath).Path
$manifestPath = Join-Path $project 'app.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "AL project manifest not found: $manifestPath"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$referenceCount = 0
foreach ($property in @('platform', 'application')) {
    if ($manifest.PSObject.Properties[$property] -and $manifest.$property) {
        $referenceCount++
    }
}
if ($manifest.PSObject.Properties['dependencies'] -and $manifest.dependencies) {
    $referenceCount += @($manifest.dependencies).Count
}
if ($referenceCount -eq 0) {
    throw "Project '$project' has no platform, application, or dependency symbols to download."
}

$altoolPath = $env:ALTOOL_PATH
if ([string]::IsNullOrWhiteSpace($altoolPath)) {
    $altoolPath = (Get-Command al -ErrorAction Stop).Source
}
if (-not (Test-Path -LiteralPath $altoolPath -PathType Leaf)) {
    throw "Prerelease ALTool not found: $altoolPath"
}

$version = (& $altoolPath --version 2>&1 | Out-String).Trim()
if (-not $version) {
    throw 'Prerelease ALTool did not report a version.'
}
if ($env:ALTOOL_VERSION -and $version -ne $env:ALTOOL_VERSION) {
    throw "ALTool version changed after setup. Expected '$env:ALTOOL_VERSION', got '$version'."
}

foreach ($name in @(
    'BC_SERVER_URL',
    'BC_SERVER_INSTANCE',
    'BC_SERVER_PORT',
    'BC_AUTHENTICATION',
    'BC_SERVER_USERNAME',
    'BC_SERVER_PASSWORD'
)) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        throw "Required ALTool connection variable '$name' is unavailable."
    }
}

if (-not $PackageCachePath) {
    $PackageCachePath = Join-Path $project '.alpackages'
}
New-Item -ItemType Directory -Path $PackageCachePath -Force | Out-Null
$packageCache = (Resolve-Path -LiteralPath $PackageCachePath).Path

$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $altoolPath
$startInfo.UseShellExecute = $false
$startInfo.RedirectStandardInput = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$startInfo.CreateNoWindow = $true
$startInfo.ArgumentList.Add('launchmcpserver')
$startInfo.ArgumentList.Add($project)
$startInfo.ArgumentList.Add('--transport')
$startInfo.ArgumentList.Add('stdio')
$startInfo.ArgumentList.Add('--packagecachepath')
$startInfo.ArgumentList.Add($packageCache)

$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo
$requestId = 0

function Send-Request {
    param(
        [Parameter(Mandatory)]
        [string] $Method,
        [hashtable] $Parameters,
        [int] $Timeout = 120
    )

    $script:requestId++
    $id = $script:requestId
    $message = @{
        jsonrpc = '2.0'
        id = $id
        method = $Method
    }
    if ($null -ne $Parameters) {
        $message.params = $Parameters
    }
    $process.StandardInput.WriteLine(($message | ConvertTo-Json -Depth 20 -Compress))
    $process.StandardInput.Flush()

    $deadline = [DateTime]::UtcNow.AddSeconds($Timeout)
    $pendingRead = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($process.HasExited) {
            throw "ALTool symbol-download process exited unexpectedly with code $($process.ExitCode)."
        }
        if ($null -eq $pendingRead) {
            $pendingRead = $process.StandardOutput.ReadLineAsync()
        }
        if (-not $pendingRead.Wait(1000)) {
            continue
        }
        $line = $pendingRead.Result
        $pendingRead = $null
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        try {
            $response = $line | ConvertFrom-Json
        }
        catch {
            continue
        }
        if ($response.PSObject.Properties['id'] -and $response.id -eq $id) {
            return $response
        }
    }
    throw "Timed out waiting for ALTool response to '$Method'."
}

try {
    $process.Start() | Out-Null

    $ready = $false
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    $pendingError = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($process.HasExited) {
            throw "ALTool exited during symbol-download startup with code $($process.ExitCode)."
        }
        if ($null -eq $pendingError) {
            $pendingError = $process.StandardError.ReadLineAsync()
        }
        if (-not $pendingError.Wait(500)) {
            continue
        }
        $line = $pendingError.Result
        $pendingError = $null
        if ($line -match 'Server Ready') {
            $ready = $true
            break
        }
    }
    if (-not $ready) {
        throw 'ALTool symbol-download service did not become ready within 30 seconds.'
    }
    $stderrDrain = $process.StandardError.ReadToEndAsync()

    $initialize = Send-Request -Method 'initialize' -Parameters @{
        protocolVersion = '2024-11-05'
        capabilities = @{}
        clientInfo = @{ name = 'public-al-triage'; version = '1.0.0' }
    }
    if ($initialize.PSObject.Properties['error']) {
        throw "ALTool initialization failed: $($initialize.error | ConvertTo-Json -Compress)"
    }
    $process.StandardInput.WriteLine((@{
        jsonrpc = '2.0'
        method = 'notifications/initialized'
    } | ConvertTo-Json -Compress))
    $process.StandardInput.Flush()

    $response = Send-Request -Method 'tools/call' -Timeout $TimeoutSeconds -Parameters @{
        name = 'al_downloadsymbols'
        arguments = @{
            projectPath = $project
            serverUrl = $env:BC_SERVER_URL
            serverInstance = $env:BC_SERVER_INSTANCE
            port = [int]$env:BC_SERVER_PORT
            environmentType = 'OnPrem'
            authentication = $env:BC_AUTHENTICATION
            force = [bool]$Force
            useInteractiveLogin = $false
        }
    }
    if ($response.PSObject.Properties['error']) {
        throw "ALTool symbol download failed: $($response.error | ConvertTo-Json -Depth 10 -Compress)"
    }

    $text = @($response.result.content |
        Where-Object { $_.type -eq 'text' } |
        Select-Object -First 1).text
    if (-not $text) {
        throw 'ALTool symbol download returned no result.'
    }
    $result = $text | ConvertFrom-Json
    if (-not $result.succeeded) {
        throw "ALTool symbol download was unsuccessful: $($result | ConvertTo-Json -Depth 10 -Compress)"
    }

    $packages = @(Get-ChildItem -LiteralPath $packageCache -Filter '*.app' -File)
    if ($packages.Count -eq 0) {
        throw "ALTool reported success but '$packageCache' contains no symbol packages."
    }

    [ordered]@{
        succeeded = $true
        altoolVersion = $version
        projectPath = $project
        packageCachePath = $packageCache
        packageCount = $packages.Count
        packages = @($packages.FullName)
    } | ConvertTo-Json -Depth 5
}
finally {
    try {
        $process.StandardInput.Close()
    }
    catch {
    }
    if (-not $process.HasExited) {
        $process.Kill()
        $process.WaitForExit(3000) | Out-Null
    }
    $process.Dispose()
}
