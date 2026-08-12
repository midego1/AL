# Tier 2: disposable stock Business Central container reproduction.
#
# Only invoked for an in-scope AL-tooling issue whose observable failure needs symbols, publish,
# or AL execution, AND only after Test-AlFixtureRuntimeSafety (SafetyGuard.psm1) has confirmed the
# extracted fixture is free of DotNet/control add-in/external HTTP/file/process host integration.
# Uses only the public BcContainerHelper module and public, stock Microsoft container artifacts -
# no private source, no private feed, no GHE/ADO credentials.
#
# HONESTY NOTE: a successful container start / compile / publish is NEVER treated as "reproduced"
# by itself - that only proves the fixture is well-formed AL, not that it demonstrates the
# reporter's symptom. Runtime verification (actually executing something and checking its result)
# only happens when a safe inline `[Test]` codeunit/procedure can be deterministically selected
# from the fixture. Without one, the outcome is reported as executed-but-inconclusive, never
# reproduced. This module could not be executed against a real container in this development
# environment (no Windows container runtime available here - see repo docs); it is validated by
# unit tests for its deterministic, pure logic (test selection, symptom matching) and by full
# syntax/lint checks, not by a live container run. See tests/Tier2ContainerReproduction.Tests.ps1.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'DiagnosticMatcher.psm1') -Force

$script:DefaultTimeoutMinutes = 20
$script:ContainerNamePrefix = 'al-triage'

function Find-DeterministicTestSelector {
    <#
        .SYNOPSIS
        Deterministically selects a single `[Test]`-attributed procedure inside a Subtype=Test
        codeunit from the fixture, if one exists. Runtime verification only ever runs this one,
        specific, reporter-supplied test - never arbitrary/generated code.

        .OUTPUTS
        PSCustomObject: Found (bool), CodeunitId, CodeunitName, ProcedureName. When multiple
        candidates exist, the first in file-name then in-file order is chosen, so results are
        reproducible across runs of the same fixture.
    #>
    param([Parameter(Mandatory)] [hashtable] $Files)

    foreach ($fileName in ($Files.Keys | Sort-Object)) {
        $content = $Files[$fileName]

        if ($content -notmatch '(?is)Subtype\s*=\s*Test\s*;') { continue }

        $codeunitMatch = [regex]::Match($content, '(?im)^\s*codeunit\s+(?<id>\d+)\s+(?<name>"[^"]+"|\S+)')
        if (-not $codeunitMatch.Success) { continue }

        $testProcedureMatch = [regex]::Match($content, '(?is)\[Test\]\s*(?:\r?\n\s*)*procedure\s+(?<proc>"[^"]+"|\w+)\s*\(')
        if (-not $testProcedureMatch.Success) { continue }

        return [pscustomobject]@{
            Found         = $true
            File          = $fileName
            CodeunitId    = $codeunitMatch.Groups['id'].Value
            CodeunitName  = $codeunitMatch.Groups['name'].Value.Trim('"')
            ProcedureName = $testProcedureMatch.Groups['proc'].Value.Trim('"')
        }
    }

    [pscustomobject]@{ Found = $false; File = $null; CodeunitId = $null; CodeunitName = $null; ProcedureName = $null }
}

function Resolve-TestExecutionStatus {
    <#
        .SYNOPSIS
        Symptom-matches an executed test's actual result (pass/fail plus any error message/AL
        code) against the issue's expected/actual text and any cited AL#### code. A passing test
        run alone is never "reproduced" (the reporter is describing a *failure*); a failing test
        is only "reproduced" when its error text/code corresponds to what the issue describes, or
        when the issue supplies no explicit signature at all it is reported as inconclusive rather
        than assumed to match.
    #>
    param(
        [Parameter(Mandatory)] [pscustomobject] $ExpectedSignature,
        [Parameter(Mandatory)] [bool] $TestPassed,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $TestErrorMessage
    )

    if ($TestPassed) {
        return [pscustomobject]@{
            Status = 'not_reproduced'
            Reason = 'The deterministically selected [Test] procedure ran and passed; the reported symptom did not occur.'
        }
    }

    $observedCodes = @([regex]::Matches($TestErrorMessage, '\bAL\d{4}\b') | ForEach-Object { $_.Value.ToUpperInvariant() })

    if ($ExpectedSignature.HasExplicitSignature) {
        $matched = @($observedCodes | Where-Object { $ExpectedSignature.AlCodes -contains $_ })
        if ($matched.Count -gt 0) {
            return [pscustomobject]@{
                Status = 'reproduced'
                Reason = "Test failure diagnostic(s) $((@($matched) | Select-Object -Unique) -join ', ') match the AL code(s) cited in the issue."
            }
        }
        return [pscustomobject]@{
            Status = 'not_reproduced'
            Reason = "Test failed, but its diagnostic(s) do not match the AL code(s) the issue cites ($($ExpectedSignature.AlCodes -join ', '))."
        }
    }

    if ($ExpectedSignature.ExpectedText -or $ExpectedSignature.ActualText) {
        if ($ExpectedSignature.ActualText -and $TestErrorMessage -like "*$($ExpectedSignature.ActualText)*") {
            return [pscustomobject]@{
                Status = 'reproduced'
                Reason = "Test failure message contains the issue's stated 'Actual' text."
            }
        }
        return [pscustomobject]@{
            Status = 'inconclusive'
            Reason = 'Test failed, but its message could not be confidently matched to the free-text Expected/Actual description; a human should confirm the failure matches the reported symptom.'
        }
    }

    return [pscustomobject]@{
        Status = 'inconclusive'
        Reason = 'Test failed and no explicit AL#### code or Expected/Actual text was available to confirm the failure matches the reported symptom.'
    }
}

function Invoke-Tier2ContainerReproduction {
    <#
        .SYNOPSIS
        Starts a disposable stock BC container, downloads exact symbols, compiles/publishes the
        fixture, and - only when a safe, deterministic `[Test]` procedure is present in the
        fixture - runs exactly that test and symptom-matches its result. A successful
        container/compile/publish alone is reported as executed/inconclusive, never reproduced.

        .PARAMETER SafetyResult
        The output of Test-AlFixtureRuntimeSafety. Reproduction is refused when IsRuntimeSafe is
        false; the caller should still report the compile-only (Tier 1) result in that case.

        .PARAMETER IssueBody
        Raw issue text, used only for symptom matching (Resolve-TestExecutionStatus) - never
        executed or treated as instructions.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingConvertToSecureStringWithPlainText', '',
        Justification = 'Password is randomly generated per run (never reporter/caller-supplied), used only to authenticate to this single disposable container, and destroyed with it - there is no persistent secret to protect.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseUsingScopeModifierInNewRunspaces', '',
        Justification = 'Values are passed into the Start-Job script block explicitly via param()/-ArgumentList, which the analyzer does not recognize as an alternative to $using: but is an equally correct, more testable pattern.')]
    param(
        [Parameter(Mandatory)] [string] $ProjectPath,
        [Parameter(Mandatory)] [hashtable] $Files,
        [Parameter(Mandatory)] [pscustomobject] $SafetyResult,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $IssueBody,
        [string] $CountryOrArtifactUrl = 'w1',
        [string] $BcVersionHint, # e.g. "24" - major version parsed from the issue's Server Version field
        [int] $TimeoutMinutes = $script:DefaultTimeoutMinutes
    )

    if (-not $SafetyResult.IsRuntimeSafe) {
        return [pscustomobject]@{
            Attempted  = $false
            Status     = 'blocked'
            Reason     = 'Fixture failed the runtime safety gate (DotNet/control add-in/external HTTP/file/process construct present); refusing to execute it in a container.'
            Violations = $SafetyResult.Violations
        }
    }

    if (-not (Get-Module -ListAvailable -Name BcContainerHelper)) {
        return [pscustomobject]@{
            Attempted = $false
            Status    = 'blocked'
            Reason    = 'BcContainerHelper module is not available in this runner; Tier 2 reproduction skipped.'
        }
    }

    $testSelector = Find-DeterministicTestSelector -Files $Files
    $expectedSignature = Get-ExpectedIssueSignature -Body $IssueBody

    $newContainerName = "$($script:ContainerNamePrefix)-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    # Ephemeral, container-local credential: torn down with the disposable container itself and
    # never persisted, logged, or reused outside this single reproduction run.
    $securePassword = ConvertTo-SecureString ([guid]::NewGuid().ToString('N') + 'Aa1!') -AsPlainText -Force
    $credential = [System.Management.Automation.PSCredential]::new('admin', $securePassword)

    $job = Start-Job -ScriptBlock {
        param($JobContainerName, $JobCountryOrArtifactUrl, $JobBcVersionHint, $JobProjectPath, [System.Management.Automation.PSCredential] $JobCredential, $JobTestSelector)

        # Terminating errors inside the job: any cmdlet failure (container start, compile,
        # publish, test run) must stop the job immediately and be captured as a job failure -
        # never silently continue and be misread as a successful reproduction attempt.
        $ErrorActionPreference = 'Stop'
        Set-StrictMode -Version Latest

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

        $appFile = Get-ChildItem -Path $JobProjectPath -Filter '*.app' -ErrorAction Stop | Select-Object -First 1
        if (-not $appFile) { throw "Compilation did not produce a .app package in '$JobProjectPath'." }

        # This is a disposable, ephemeral, single-use sandbox container with a freshly generated
        # self-signed certificate; there is no external CA to verify against and no persistent
        # trust relationship to protect, so -skipVerification is justified here and only here.
        Publish-BcContainerApp -containerName $JobContainerName -appFile $appFile.FullName -skipVerification -install -sync

        $testRun = $null
        if ($JobTestSelector.Found) {
            $testRun = Run-TestsInBcContainer `
                -containerName $JobContainerName `
                -credential $JobCredential `
                -testCodeunit $JobTestSelector.CodeunitId `
                -testFunction $JobTestSelector.ProcedureName `
                -detailed `
                -ErrorAction Stop
        }

        [pscustomobject]@{
            ArtifactUrl  = $artifactUrl
            AppPublished = $true
            TestRun      = $testRun
        }
    } -ArgumentList $newContainerName, $CountryOrArtifactUrl, $BcVersionHint, $ProjectPath, $credential, $testSelector

    try {
        $completed = Wait-Job -Job $job -Timeout ($TimeoutMinutes * 60)
        if (-not $completed) {
            Stop-Job -Job $job | Out-Null
            return [pscustomobject]@{
                Attempted = $true
                Status    = 'blocked'
                Reason    = "Container reproduction exceeded the $TimeoutMinutes minute bound and was aborted."
            }
        }

        if ($job.State -eq 'Failed') {
            $jobError = ($job.ChildJobs | ForEach-Object { $_.JobStateInfo.Reason } | Where-Object { $_ }) -join '; '
            return [pscustomobject]@{
                Attempted = $true
                Status    = 'inconclusive'
                Reason    = "Container/compile/publish/test job terminated with an error before completing: $jobError"
            }
        }

        $jobResult = Receive-Job -Job $job -ErrorAction Stop

        if (-not $testSelector.Found) {
            return [pscustomobject]@{
                Attempted    = $true
                Status       = 'inconclusive'
                Reason       = 'Container started, the fixture compiled, and the app published successfully, but no safe, deterministic [Test] procedure was present in the fixture, so no runtime symptom could be verified. A successful publish alone is never reported as reproduced.'
                TestSelector = $testSelector
            }
        }

        $testRun = $jobResult.TestRun
        $testPassed = [bool]($testRun -and $testRun.result -eq 'Success')
        $testErrorMessage = if ($testRun -and $testRun.PSObject.Properties.Match('error').Count -gt 0) { [string]$testRun.error } else { '' }

        $resolution = Resolve-TestExecutionStatus -ExpectedSignature $expectedSignature -TestPassed $testPassed -TestErrorMessage $testErrorMessage

        [pscustomobject]@{
            Attempted     = $true
            Status        = $resolution.Status
            Reason        = $resolution.Reason
            TestSelector  = $testSelector
            TestPassed    = $testPassed
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

Export-ModuleMember -Function Find-DeterministicTestSelector, Resolve-TestExecutionStatus, Invoke-Tier2ContainerReproduction
