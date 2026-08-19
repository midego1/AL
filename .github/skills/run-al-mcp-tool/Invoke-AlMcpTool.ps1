[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ProjectPath,

    [Parameter(Mandatory)]
    [string] $ToolName,

    [Parameter(Mandatory)]
    [string] $ArgumentsJson,

    [string] $PackageCachePath,

    [int] $TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
$project = (Resolve-Path -LiteralPath $ProjectPath).Path
if (-not (Test-Path -LiteralPath (Join-Path $project 'app.json') -PathType Leaf)) {
    throw "AL project manifest not found under '$project'."
}
if ($ToolName -notmatch '^al_[a-zA-Z0-9_]+$') {
    throw "Only AL MCP tools may be invoked. Invalid tool name '$ToolName'."
}
if ($ToolName -match '^al_(publish|install|run|test|downloadsymbols)') {
    throw "MCP tool '$ToolName' is not safe for this wrapper. Use the dedicated sandbox skill."
}

try {
    $arguments = $ArgumentsJson | ConvertFrom-Json -Depth 30
}
catch {
    throw "ArgumentsJson is not valid JSON: $($_.Exception.Message)"
}
if ($null -eq $arguments -or $arguments -isnot [pscustomobject]) {
    throw 'ArgumentsJson must contain a JSON object.'
}

$altoolPath = $env:ALTOOL_PATH
if ([string]::IsNullOrWhiteSpace($altoolPath) -or
    -not (Test-Path -LiteralPath $altoolPath -PathType Leaf)) {
    throw 'The workflow-installed prerelease ALTool is unavailable.'
}
$version = (& $altoolPath --version 2>&1 | Out-String).Trim()
if (-not $version) {
    throw 'Prerelease ALTool did not report a version.'
}
if ($env:ALTOOL_VERSION -and $version -ne $env:ALTOOL_VERSION) {
    throw "ALTool version changed after setup. Expected '$env:ALTOOL_VERSION', got '$version'."
}

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
if ($PackageCachePath) {
    $packageCache = [IO.Path]::GetFullPath($PackageCachePath)
    New-Item -ItemType Directory -Path $packageCache -Force | Out-Null
    $startInfo.ArgumentList.Add('--packagecachepath')
    $startInfo.ArgumentList.Add($packageCache)
}

$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo
$requestId = 0
$processStarted = $false

function Send-AlMcpRequest {
    param(
        [Parameter(Mandatory)]
        [string] $Method,
        [object] $Parameters,
        [int] $Timeout = 120
    )

    $script:requestId++
    $id = $script:requestId
    $message = [ordered]@{
        jsonrpc = '2.0'
        id = $id
        method = $Method
    }
    if ($null -ne $Parameters) {
        $message.params = $Parameters
    }
    $process.StandardInput.WriteLine(($message | ConvertTo-Json -Depth 30 -Compress))
    $process.StandardInput.Flush()

    $deadline = [DateTime]::UtcNow.AddSeconds($Timeout)
    $pendingRead = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($process.HasExited) {
            throw "ALTool MCP process exited unexpectedly with code $($process.ExitCode)."
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
            $response = $line | ConvertFrom-Json -Depth 30
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
    $processStarted = $true

    $ready = $false
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    $pendingError = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($process.HasExited) {
            throw "ALTool exited during MCP startup with code $($process.ExitCode)."
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
        throw 'ALTool MCP server did not become ready within 30 seconds.'
    }
    $stderrDrain = $process.StandardError.ReadToEndAsync()

    $initialize = Send-AlMcpRequest -Method 'initialize' -Parameters @{
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

    $tools = Send-AlMcpRequest -Method 'tools/list' -Parameters @{}
    if ($tools.PSObject.Properties['error']) {
        throw "ALTool tool discovery failed: $($tools.error | ConvertTo-Json -Compress)"
    }
    if ($ToolName -notin @($tools.result.tools.name)) {
        throw "ALTool did not advertise MCP tool '$ToolName'."
    }

    $response = Send-AlMcpRequest -Method 'tools/call' -Timeout $TimeoutSeconds -Parameters @{
        name = $ToolName
        arguments = $arguments
    }

    [ordered]@{
        altoolVersion = $version
        projectPath = $project
        toolName = $ToolName
        response = $response
    } | ConvertTo-Json -Depth 30
}
finally {
    if ($processStarted -and -not $process.HasExited) {
        $process.StandardInput.Close()
        $process.Kill()
        $process.WaitForExit(3000) | Out-Null
    }
    $process.Dispose()
}
