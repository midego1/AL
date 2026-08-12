BeforeAll {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Tier2ContainerReproduction.psm1') -Force
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'DiagnosticMatcher.psm1') -Force
}

Describe 'Find-DeterministicTestSelector' {

    It 'finds a [Test] procedure inside a Subtype=Test codeunit' {
        $files = @{
            'Fixture01.al' = @'
codeunit 50100 "Repro Tests"
{
    Subtype = Test;

    [Test]
    procedure TestSomethingFails()
    begin
        Message('repro');
    end;
}
'@
        }
        $result = Find-DeterministicTestSelector -Files $files
        $result.Found | Should -BeTrue
        $result.CodeunitId | Should -Be '50100'
        $result.CodeunitName | Should -Be 'Repro Tests'
        $result.ProcedureName | Should -Be 'TestSomethingFails'
    }

    It 'does not select a procedure from a codeunit that is not Subtype=Test' {
        $files = @{
            'Fixture01.al' = @'
codeunit 50100 Repro
{
    [Test]
    procedure NotActuallyATest()
    begin
    end;
}
'@
        }
        $result = Find-DeterministicTestSelector -Files $files
        $result.Found | Should -BeFalse
    }

    It 'returns Found=$false when there is no [Test] attribute at all' {
        $files = @{ 'Fixture01.al' = 'codeunit 50100 Repro { trigger OnRun(); begin Message(''ok''); end; }' }
        $result = Find-DeterministicTestSelector -Files $files
        $result.Found | Should -BeFalse
    }

    It 'is deterministic: picks the same file/test across repeated calls with multiple candidates' {
        $files = @{
            'Fixture02.al' = @'
codeunit 50101 "Second Tests"
{
    Subtype = Test;
    [Test]
    procedure SecondTest()
    begin
    end;
}
'@
            'Fixture01.al' = @'
codeunit 50100 "First Tests"
{
    Subtype = Test;
    [Test]
    procedure FirstTest()
    begin
    end;
}
'@
        }
        $first = Find-DeterministicTestSelector -Files $files
        $second = Find-DeterministicTestSelector -Files $files
        $first.ProcedureName | Should -Be $second.ProcedureName
        # File-name sort order means Fixture01.al is chosen over Fixture02.al.
        $first.ProcedureName | Should -Be 'FirstTest'
    }
}

Describe 'Resolve-TestExecutionStatus' {

    It 'never reports reproduced for a passing test' {
        $expected = Get-ExpectedIssueSignature -Body 'Expected: Message call should throw AL0104.'
        $result = Resolve-TestExecutionStatus -ExpectedSignature $expected -TestPassed $true -TestErrorMessage ''
        $result.Status | Should -Be 'not_reproduced'
    }

    It 'reports reproduced when a failing test error message contains the cited AL#### code' {
        $expected = Get-ExpectedIssueSignature -Body 'The test should fail with error AL0104.'
        $result = Resolve-TestExecutionStatus -ExpectedSignature $expected -TestPassed $false -TestErrorMessage "Test failed: error AL0104: Syntax error, ';' expected"
        $result.Status | Should -Be 'reproduced'
    }

    It 'reports not_reproduced when a failing test error message does not match the cited AL#### code' {
        $expected = Get-ExpectedIssueSignature -Body 'The test should fail with error AL9999.'
        $result = Resolve-TestExecutionStatus -ExpectedSignature $expected -TestPassed $false -TestErrorMessage 'Test failed: error AL0104: unrelated'
        $result.Status | Should -Be 'not_reproduced'
    }

    It 'reports reproduced when the failure message contains the explicit Actual text and no AL code is cited' {
        $expected = Get-ExpectedIssueSignature -Body "Expected: no error`nActual: Cannot insert record"
        $result = Resolve-TestExecutionStatus -ExpectedSignature $expected -TestPassed $false -TestErrorMessage 'Test failed: Cannot insert record into table.'
        $result.Status | Should -Be 'reproduced'
    }

    It 'reports inconclusive for a failing test with no explicit signature to match at all' {
        $expected = Get-ExpectedIssueSignature -Body 'Something is broken, not sure exactly what.'
        $result = Resolve-TestExecutionStatus -ExpectedSignature $expected -TestPassed $false -TestErrorMessage 'Test failed: some unrelated error.'
        $result.Status | Should -Be 'inconclusive'
    }
}

Describe 'Invoke-Tier2ContainerReproduction (pure, non-container-executing paths)' {

    It 'refuses to attempt reproduction when the safety gate failed' {
        $safety = [pscustomobject]@{ IsRuntimeSafe = $false; Violations = @([pscustomobject]@{ File = 'Fixture01.al'; Reason = 'Uses DotNet interop.' }) }
        $result = Invoke-Tier2ContainerReproduction -ProjectPath 'C:\doesnotmatter' -Files @{} -SafetyResult $safety -IssueBody ''
        $result.Attempted | Should -BeFalse
        $result.Status | Should -Be 'blocked'
    }

    It 'reports blocked (not reproduced) when BcContainerHelper is unavailable, without touching Docker/containers' {
        # BcContainerHelper is intentionally not installed in this environment (no Windows
        # container runtime available here); this exercises the honest "cannot attempt" path
        # rather than mocking container execution.
        if (Get-Module -ListAvailable -Name BcContainerHelper) {
            Set-ItResult -Skipped -Because 'BcContainerHelper happens to be installed in this environment; the not-available path cannot be exercised.'
            return
        }
        $safety = [pscustomobject]@{ IsRuntimeSafe = $true; Violations = @() }
        $result = Invoke-Tier2ContainerReproduction -ProjectPath 'C:\doesnotmatter' -Files @{} -SafetyResult $safety -IssueBody ''
        $result.Attempted | Should -BeFalse
        $result.Status | Should -Be 'blocked'
        $result.Reason | Should -Match 'BcContainerHelper'
    }

    It 'real execution: a container-start failure (no Docker/Windows-container runtime) surfaces as inconclusive, never reproduced' {
        # This is a genuine, non-mocked execution: BcContainerHelper IS installed in this
        # environment, so this actually imports it and calls into Invoke-Tier2ContainerReproduction
        # end-to-end. Since no Docker/Windows-container runtime is available here, New-BcContainer
        # fails inside the job - proving the terminating-error handling path (correction #5) for
        # real rather than by mock. Bounded to a short timeout since the docker/container failure
        # happens almost immediately (missing `docker` command), not after a long hang.
        if (-not (Get-Module -ListAvailable -Name BcContainerHelper)) {
            Set-ItResult -Skipped -Because 'BcContainerHelper is not installed in this environment; cannot exercise the real container-start failure path.'
            return
        }
        $safety = [pscustomobject]@{ IsRuntimeSafe = $true; Violations = @() }
        $files = @{ 'Fixture01.al' = 'codeunit 50100 Repro { trigger OnRun(); begin Message(''ok''); end; }' }
        $result = Invoke-Tier2ContainerReproduction -ProjectPath (Join-Path ([System.IO.Path]::GetTempPath()) 'al-triage-t2-real-test') -Files $files -SafetyResult $safety -IssueBody '' -TimeoutMinutes 2
        $result.Attempted | Should -BeTrue
        $result.Status | Should -Be 'inconclusive'
        $result.Status | Should -Not -Be 'reproduced'
        $result.Reason | Should -Match 'terminated with an error'
    }
}
