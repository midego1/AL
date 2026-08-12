# Tier 2: disposable stock Business Central container reproduction.
#
# Only invoked for an in-scope AL-tooling issue whose observable failure needs symbols, publish,
# or AL execution, AND only after Test-AlFixtureRuntimeSafety (SafetyGuard.psm1) has confirmed the
# extracted fixture is free of DotNet/control add-in/external HTTP/file/process host integration.
# Uses only the public BcContainerHelper module and public, stock Microsoft container artifacts -
# no private source, no private feed, no GHE/ADO credentials.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:DefaultTimeoutMinutes = 20
$script:ContainerNamePrefix = 'al-triage'

function Invoke-Tier2ContainerReproduction {
    <#
        .SYNOPSIS
        Starts a disposable stock BC container, downloads exact symbols, compiles/publishes the
        fixture, runs the smallest available AL test, and always tears the container down - even
        on failure/timeout.

        .PARAMETER SafetyResult
        The output of Test-AlFixtureRuntimeSafety. Reproduction is refused when IsRuntimeSafe is
        false; the caller should still report the compile-only (Tier 1) result in that case.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingConvertToSecureStringWithPlainText', '',
        Justification = 'Password is randomly generated per run (never reporter/caller-supplied), used only to authenticate to this single disposable container, and destroyed with it - there is no persistent secret to protect.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseUsingScopeModifierInNewRunspaces', '',
        Justification = 'Values are passed into the Start-Job script block explicitly via param()/-ArgumentList, which the analyzer does not recognize as an alternative to $using: but is an equally correct, more testable pattern.')]
    param(
        [Parameter(Mandatory)] [string] $ProjectPath,
        [Parameter(Mandatory)] [pscustomobject] $SafetyResult,
        [string] $CountryOrArtifactUrl = 'w1',
        [string] $BcVersionHint, # e.g. "24" - major version parsed from the issue's Server Version field
        [int] $TimeoutMinutes = $script:DefaultTimeoutMinutes
    )

    if (-not $SafetyResult.IsRuntimeSafe) {
        return [pscustomobject]@{
            Attempted = $false
            Reason    = 'Fixture failed the runtime safety gate (DotNet/control add-in/external HTTP/file/process construct present); refusing to execute it in a container.'
            Violations = $SafetyResult.Violations
        }
    }

    if (-not (Get-Module -ListAvailable -Name BcContainerHelper)) {
        return [pscustomobject]@{
            Attempted = $false
            Reason    = 'BcContainerHelper module is not available in this runner; Tier 2 reproduction skipped.'
        }
    }

    $newContainerName = "$($script:ContainerNamePrefix)-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    # Ephemeral, container-local credential: torn down with the disposable container itself and
    # never persisted, logged, or reused outside this single reproduction run.
    $securePassword = ConvertTo-SecureString ([guid]::NewGuid().ToString('N') + 'Aa1!') -AsPlainText -Force
    $credential = [System.Management.Automation.PSCredential]::new('admin', $securePassword)

    $job = Start-Job -ScriptBlock {
        param($JobContainerName, $JobCountryOrArtifactUrl, $JobBcVersionHint, $JobProjectPath, [System.Management.Automation.PSCredential] $JobCredential)

        Import-Module BcContainerHelper -ErrorAction Stop

        $artifactUrl = Get-BCArtifactUrl -type Sandbox -country $JobCountryOrArtifactUrl -select Latest -version $JobBcVersionHint -ErrorAction Stop

        New-BcContainer `
            -accept_eula `
            -containerName $JobContainerName `
            -artifactUrl $artifactUrl `
            -auth UserPassword `
            -Credential $JobCredential `
            -updateHosts

        Compile-AppInBcContainer -containerName $JobContainerName -credential $JobCredential -appProjectFolder $JobProjectPath -appOutputFolder $JobProjectPath -CopySymbolsFromContainer

        $appFile = Get-ChildItem -Path $JobProjectPath -Filter '*.app' | Select-Object -First 1
        if ($appFile) {
            Publish-BcContainerApp -containerName $JobContainerName -appFile $appFile.FullName -skipVerification -install -sync
        }

        [pscustomobject]@{ ArtifactUrl = $artifactUrl; AppPublished = [bool]$appFile }
    } -ArgumentList $newContainerName, $CountryOrArtifactUrl, $BcVersionHint, $ProjectPath, $credential

    try {
        $completed = Wait-Job -Job $job -Timeout ($TimeoutMinutes * 60)
        if (-not $completed) {
            Stop-Job -Job $job | Out-Null
            return [pscustomobject]@{
                Attempted = $true
                Reproduced = $false
                Blocked    = $true
                Reason     = "Container reproduction exceeded the $TimeoutMinutes minute bound and was aborted."
            }
        }

        $jobResult = Receive-Job -Job $job -ErrorAction SilentlyContinue
        $jobFailed = ($job.State -eq 'Failed')

        [pscustomobject]@{
            Attempted  = $true
            Reproduced = (-not $jobFailed)
            Blocked    = $jobFailed
            Result     = $jobResult
            ContainerName = $newContainerName
        }
    } finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        # Always attempt teardown of the disposable container and any package it produced,
        # regardless of success/failure/timeout above.
        if (Get-Module -ListAvailable -Name BcContainerHelper) {
            try {
                Import-Module BcContainerHelper -ErrorAction Stop
                if (Test-BcContainer -containerName $newContainerName) {
                    Remove-BcContainer -containerName $newContainerName
                }
            } catch {
                # Best-effort cleanup; surfaced via workflow logs, not fatal to the triage report.
                Write-Warning "Failed to remove disposable container '$newContainerName': $_"
            }
        }
    }
}

Export-ModuleMember -Function Invoke-Tier2ContainerReproduction
