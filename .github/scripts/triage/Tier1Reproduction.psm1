# Tier 1: server-free reproduction using published, pinned ALTools (altool) NuGet packages.
#
# Restores the pinned package version(s) and runs `al compile` against a minimal fixture built
# entirely from inline, issue-supplied AL. No private source, no private feed, and no GHE/ADO
# credentials are used or referenced anywhere in this script.
#
# CORRECTNESS NOTES (validated by actually running the pinned package - see
# tests/DiagnosticMatcher.Tests.ps1 and tests/Tier1Reproduction.Tests.ps1):
# - `al compile` is a thin wrapper that forwards its arguments verbatim to alc.exe (confirmed via
#   `dotnet tool run al -- help compile`: "Compiles a package by invoking alc.exe with the
#   specified arguments."). alc.exe uses colon-attached single-slash arguments, NOT `--project`:
#   `/project:<path> /out:<appFile> /packagecachepath:<cacheDir>`.
# - alc.exe can exit 0 even when it reported a compiler error (observed for AL1021), so exit code
#   is NEVER used as reproduction evidence here - only parsed diagnostics are (see
#   DiagnosticMatcher.psm1).
# - Tier 1 fixtures are dependency-free by default (no `application` manifest dependency), which
#   avoids requiring Base Application/System symbols for anything beyond what the AL language
#   itself needs. Fixtures that still trigger only environment/symbol-cache diagnostics (AL1021/
#   AL1022) are classified by DiagnosticMatcher as requiring Tier 2 container reproduction - never
#   as "reproduced".

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'DiagnosticMatcher.psm1') -Force

function Get-AlToolsVersionConfig {
    <#
        .SYNOPSIS
        Loads the pinned ALTools/altool NuGet package id and stable/preview versions from
        AlToolsVersions.json, so Tier 1 always tests a deliberately-chosen, reviewed version set
        rather than an unpinned "latest".
    #>
    param([string] $ConfigPath = (Join-Path $PSScriptRoot 'AlToolsVersions.json'))
    Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
}

function Test-NuGetPackageVersionExist {
    <#
        .SYNOPSIS
        Confirms a specific version string is actually published for a package on the public
        NuGet.org flat-container index before we ever attempt to install/test it. Never assumes
        existence; any network/parse failure is treated as "does not exist" (fail closed).
    #>
    param(
        [Parameter(Mandatory)] [string] $PackageId,
        [Parameter(Mandatory)] [string] $Version
    )

    try {
        $uri = "https://api.nuget.org/v3-flatcontainer/$($PackageId.ToLowerInvariant())/index.json"
        $index = Invoke-RestMethod -Uri $uri -Method GET -TimeoutSec 30
        return [bool]($index.versions -contains $Version)
    } catch {
        return $false
    }
}

function Get-ReportedAlToolsPackageVersion {
    <#
        .SYNOPSIS
        Extracts a candidate ALTools/altool NuGet package version from issue text - but ONLY when
        the reporter explicitly frames the number as an ALTools/AL CLI/NuGet package version, not
        the unrelated VS Code marketplace "AL Extension Version" (e.g. "13.2") that the standard
        issue template collects. Existence on NuGet.org is verified separately by the caller via
        Test-NuGetPackageVersionExist before this is ever used.
    #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Body)

    $match = [regex]::Match($Body, '(?im)\b(?:ALTools?|AL CLI|Development\.Tools|altool)\b[^\n]{0,40}?\bversion\s*[:=]?\s*(?<v>\d+\.\d+\.\d+(?:\.\d+)?(?:-[0-9A-Za-z.]+)?)')
    if ($match.Success) { return $match.Groups['v'].Value }
    return $null
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
        Runs `al compile` (which forwards straight to alc.exe) against a fixture project
        directory using a previously installed ALTools version, with an explicit output path and
        an isolated (intentionally empty, by default) package cache directory. Captures raw output
        for diagnostic parsing without publishing or executing the compiled package.
    #>
    param(
        [Parameter(Mandatory)] [string] $ToolDir,
        [Parameter(Mandatory)] [string] $ProjectPath,
        [Parameter(Mandatory)] [string] $OutputAppPath,
        [Parameter(Mandatory)] [string] $PackageCachePath
    )

    New-Item -ItemType Directory -Force -Path $PackageCachePath | Out-Null
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputAppPath) | Out-Null

    Push-Location $ToolDir
    try {
        $command = "dotnet tool run al -- compile /project:`"$ProjectPath`" /out:`"$OutputAppPath`" /packagecachepath:`"$PackageCachePath`""
        $output = & dotnet tool run al -- compile "/project:$ProjectPath" "/out:$OutputAppPath" "/packagecachepath:$PackageCachePath" 2>&1
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = ($output -join "`n")
            Command  = $command
        }
    } finally {
        Pop-Location
    }
}

function Invoke-Tier1Reproduction {
    <#
        .SYNOPSIS
        Orchestrates Tier-1, server-free reproduction: installs the pinned stable/preview ALTools
        package versions (plus an issue-cited ALTools package version, only when explicitly
        identified as such and confirmed to exist on public NuGet), compiles the extracted fixture
        with each, and resolves an honest reproduction status per version via DiagnosticMatcher.

        .PARAMETER IssueBody
        Raw issue body text, used only to (a) look for an explicit ALTools/CLI package version
        mention and (b) extract the expected AL#### diagnostic signature for symptom matching.
        Never executed - only pattern-matched.
    #>
    param(
        [Parameter(Mandatory)] [string] $ProjectPath,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $IssueBody,
        [string] $WorkRoot = (Join-Path ([System.IO.Path]::GetTempPath()) ("al-triage-tools-" + [guid]::NewGuid().ToString('N').Substring(0, 8)))
    )

    $config = Get-AlToolsVersionConfig
    New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null

    $versionsToTest = [ordered]@{ stable = $config.stable; preview = $config.preview }

    $reportedCandidate = Get-ReportedAlToolsPackageVersion -Body $IssueBody
    if ($reportedCandidate -and (Test-NuGetPackageVersionExist -PackageId $config.packageId -Version $reportedCandidate)) {
        $versionsToTest['reportedAlToolsPackage'] = $reportedCandidate
    }

    $expectedSignature = Get-ExpectedIssueSignature -Body $IssueBody

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

        $outputAppPath = Join-Path $WorkRoot "out-$label\Fixture.app"
        $packageCachePath = Join-Path $WorkRoot "cache-$label"
        $compile = Invoke-AlCompile -ToolDir $install.ToolDir -ProjectPath $ProjectPath -OutputAppPath $outputAppPath -PackageCachePath $packageCachePath

        $diagnostics = Get-CompilerDiagnostic -Output $compile.Output
        $resolution = Resolve-ReproductionStatus -ExpectedSignature $expectedSignature -ObservedDiagnostics $diagnostics -RawOutput $compile.Output

        $results[$label] = [pscustomobject]@{
            Version           = $version
            Restored          = $true
            ExitCode          = $compile.ExitCode
            Command           = $compile.Command
            Output            = $compile.Output
            Diagnostics       = $diagnostics
            Status            = $resolution.Status
            RequiresContainer = $resolution.RequiresContainer
            Reason            = $resolution.Reason
        }
    }

    [pscustomobject]@{
        Results           = [pscustomobject]$results
        ExpectedSignature = $expectedSignature
    }
}

Export-ModuleMember -Function Get-AlToolsVersionConfig, Test-NuGetPackageVersionExist, Get-ReportedAlToolsPackageVersion, Install-AlToolsPackage, Invoke-AlCompile, Invoke-Tier1Reproduction
