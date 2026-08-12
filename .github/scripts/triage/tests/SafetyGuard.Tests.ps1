BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'SafetyGuard.psm1') -Force
}

Describe 'Test-AlFixtureRuntimeSafety' {

    It 'considers a plain codeunit safe for runtime execution' {
        $files = @{ 'Fixture01.al' = 'codeunit 50100 Repro { trigger OnRun(); begin Message(''ok''); end; }' }
        $result = Test-AlFixtureRuntimeSafety -Files $files
        $result.IsRuntimeSafe | Should -BeTrue
        $result.Violations.Count | Should -Be 0
    }

    It 'rejects a fixture that declares a DotNet variable' {
        $files = @{ 'Fixture01.al' = "codeunit 50100 Repro`n{`n    var`n        MyObj: DotNet MyDotNetObject;`n    trigger OnRun();`n    begin`n    end;`n}" }
        $result = Test-AlFixtureRuntimeSafety -Files $files
        $result.IsRuntimeSafe | Should -BeFalse
        $result.Violations.Reason | Should -Match 'DotNet interop'
    }

    It 'rejects a fixture that references a ControlAddIn' {
        $files = @{ 'Fixture01.page.al' = 'page 50100 Repro { usercontrol(MyAddin; ControlAddIn) { } }' }
        $result = Test-AlFixtureRuntimeSafety -Files $files
        $result.IsRuntimeSafe | Should -BeFalse
        $result.Violations.Reason | Should -Match 'Control Add-in'
    }

    It 'rejects a fixture that uses HttpClient for outbound network calls' {
        $files = @{ 'Fixture01.al' = 'codeunit 50100 Repro { var Client: HttpClient; trigger OnRun(); begin end; }' }
        $result = Test-AlFixtureRuntimeSafety -Files $files
        $result.IsRuntimeSafe | Should -BeFalse
        $result.Violations.Reason | Should -Match 'HttpClient'
    }

    It 'rejects a fixture that uses FileManagement for host file-system access' {
        $files = @{ 'Fixture01.al' = 'codeunit 50100 Repro { var FM: Codeunit FileManagement; trigger OnRun(); begin end; }' }
        $result = Test-AlFixtureRuntimeSafety -Files $files
        $result.IsRuntimeSafe | Should -BeFalse
    }

    It 'reports one violation entry per offending file, preserving file names' {
        $files = @{
            'Fixture01.al' = "codeunit 50100 Repro`n{`n    var`n        MyObj: DotNet MyDotNetObject;`n    trigger OnRun();`n    begin`n    end;`n}"
            'Fixture02.al' = 'codeunit 50101 Repro2 { trigger OnRun(); begin Message(''ok''); end; }'
        }
        $result = Test-AlFixtureRuntimeSafety -Files $files
        $result.IsRuntimeSafe | Should -BeFalse
        ($result.Violations | Where-Object { $_.File -eq 'Fixture01.al' }).Count | Should -Be 1
        ($result.Violations | Where-Object { $_.File -eq 'Fixture02.al' }).Count | Should -Be 0
    }
}
