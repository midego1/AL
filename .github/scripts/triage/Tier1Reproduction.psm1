# Tier 1: server-free reproduction using published, pinned ALTools (altool) NuGet packages.
#
# Restores the pinned package version(s) and runs `al compile` against a minimal fixture built
# entirely from inline, issue-supplied AL. No private source, no private feed, and no GHE/ADO
# credentials are used or referenced anywhere in this script.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-AlToolsVersionConfig {
    param([string] $ConfigPath = (Join-Path $PSScriptRoot 'AlToolsVersions.json'))
    Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
}

function Install-AlToolsPackage {
    <#
        .SYNOPSIS
        Installs a specific pinned version of the public ALTools dotnet tool into an isolated
        per-version tool directory so multiple versions (reported/stable/preview) can coexist.

        .OUTPUTS
        Path to the `al` executable/shim for the installed version, or $null if install failed.
    #>
    param(
        [Parameter(Mandatory)] [string] $PackageId,
        [Parameter(Mandatory)] [string] $Version,
        [Parameter(Mandatory)] [string] $ToolsRoot
    )

    $toolDir = Join-Path $ToolsRoot ("altools-" + ($Version -replace '[^a-zA-Z0-9\.\-]', '_'))
    New-Item -ItemType Directory -Force -Path $toolDir | Out-Null

    Push-Location $toolDir
    try {
        & dotnet new tool-manifest --force 2>&1 | Out-Null
        $installOutput = & dotnet tool install $PackageId --version $Version --local 2>&1
        $installedOk = ($LASTEXITCODE -eq 0)

        if (-not $installedOk) {
            return [pscustomobject]@{ Success = $false; Output = ($installOutput -join "`n"); ToolDir = $toolDir }
        }

        return [pscustomobject]@{ Success = $true; Output = ($installOutput -join "`n"); ToolDir = $toolDir }
    } finally {
        Pop-Location
    }
}

function Invoke-AlCompile {
    <#
        .SYNOPSIS
        Runs `dotnet tool run al compile` (server-free) against a fixture project directory using
        a previously installed ALTools version, capturing exit code and diagnostics without
        publishing or executing the compiled package.
    #>
    param(
        [Parameter(Mandatory)] [string] $ToolDir,
        [Parameter(Mandatory)] [string] $ProjectPath
    )

    Push-Location $ToolDir
    try {
        $output = & dotnet tool run al -- compile --project $ProjectPath 2>&1
        $exitCode = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $exitCode
            Output   = ($output -join "`n")
            Command  = "dotnet tool run al -- compile --project `"$ProjectPath`""
        }
    } finally {
        Pop-Location
    }
}

function Invoke-Tier1Reproduction {
    <#
        .SYNOPSIS
        Orchestrates Tier-1, server-free reproduction: installs the pinned stable (and, when the
        issue discloses a compatible reported version, that version too) ALTools package(s), then
        compiles the extracted fixture with each, recording exact versions/commands/diagnostics.
    #>
    param(
        [Parameter(Mandatory)] [string] $ProjectPath,
        [string] $ReportedVersion,
        [string] $WorkRoot = (Join-Path ([System.IO.Path]::GetTempPath()) ("al-triage-tools-" + [guid]::NewGuid().ToString('N').Substring(0, 8)))
    )

    $config = Get-AlToolsVersionConfig
    New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null

    $versionsToTest = [ordered]@{ stable = $config.stable; preview = $config.preview }
    if ($ReportedVersion) { $versionsToTest['reported'] = $ReportedVersion }

    $results = [ordered]@{}
    foreach ($label in $versionsToTest.Keys) {
        $version = $versionsToTest[$label]
        $install = Install-AlToolsPackage -PackageId $config.packageId -Version $version -ToolsRoot $WorkRoot
        if (-not $install.Success) {
            $results[$label] = [pscustomobject]@{
                Version  = $version
                Restored = $false
                Detail   = $install.Output
            }
            continue
        }

        $compile = Invoke-AlCompile -ToolDir $install.ToolDir -ProjectPath $ProjectPath
        $results[$label] = [pscustomobject]@{
            Version   = $version
            Restored  = $true
            ExitCode  = $compile.ExitCode
            Reproduced = ($compile.ExitCode -ne 0)
            Command   = $compile.Command
            Output    = $compile.Output
        }
    }

    [pscustomobject]$results
}

Export-ModuleMember -Function Get-AlToolsVersionConfig, Install-AlToolsPackage, Invoke-AlCompile, Invoke-Tier1Reproduction
