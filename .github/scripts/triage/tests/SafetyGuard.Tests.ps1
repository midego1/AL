BeforeAll {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'SafetyGuard.psm1') -Force
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

    It 'rejects a fixture using a quoted identifier with spaces for a DotNet variable ("My Var": DotNet)' {
        $files = @{ 'Fixture01.al' = "codeunit 50100 Repro`n{`n    var`n        `"My Var`": DotNet MyDotNetObject;`n    trigger OnRun();`n    begin`n    end;`n}" }
        $result = Test-AlFixtureRuntimeSafety -Files $files
        $result.IsRuntimeSafe | Should -BeFalse
        $result.Violations.Reason | Should -Match 'DotNet interop'
    }

    It 'rejects a fixture that uses WebClient/WebRequest for outbound network calls' {
        $files = @{ 'Fixture01.al' = 'codeunit 50100 Repro { var Req: WebRequest; trigger OnRun(); begin end; }' }
        $result = Test-AlFixtureRuntimeSafety -Files $files
        $result.IsRuntimeSafe | Should -BeFalse
        $result.Violations.Reason | Should -Match 'WebClient/WebRequest'
    }

    It 'rejects a fixture that declares a File-typed variable' {
        $files = @{ 'Fixture01.al' = 'codeunit 50100 Repro { var MyFile: File; trigger OnRun(); begin end; }' }
        $result = Test-AlFixtureRuntimeSafety -Files $files
        $result.IsRuntimeSafe | Should -BeFalse
        $result.Violations.Reason | Should -Match 'File data type'
    }

    It 'does not false-positive on a Text field merely named "FileName"' {
        $files = @{ 'Fixture01.al' = 'codeunit 50100 Repro { var FileName: Text; trigger OnRun(); begin end; }' }
        $result = Test-AlFixtureRuntimeSafety -Files $files
        $result.IsRuntimeSafe | Should -BeTrue
    }

    It 'rejects a fixture that opens the virtual "File" system table' {
        $files = @{ 'Fixture01.al' = 'codeunit 50100 Repro { var Rec: Record "File"; trigger OnRun(); begin end; }' }
        $result = Test-AlFixtureRuntimeSafety -Files $files
        $result.IsRuntimeSafe | Should -BeFalse
        $result.Violations.Reason | Should -Match 'virtual "File" system table'
    }

    It 'rejects a fixture that uses InStream/OutStream file/blob streams' {
        $files = @{ 'Fixture01.al' = 'codeunit 50100 Repro { var Ins: InStream; trigger OnRun(); begin end; }' }
        $result = Test-AlFixtureRuntimeSafety -Files $files
        $result.IsRuntimeSafe | Should -BeFalse
        $result.Violations.Reason | Should -Match 'stream'
    }

    It 'rejects a fixture that invokes Shell(...) process/shell execution' {
        $files = @{ 'Fixture01.al' = "codeunit 50100 Repro { trigger OnRun(); begin Shell('cmd.exe'); end; }" }
        $result = Test-AlFixtureRuntimeSafety -Files $files
        $result.IsRuntimeSafe | Should -BeFalse
        $result.Violations.Reason | Should -Match 'process/shell'
    }

    It 'rejects a fixture that uses Automation (OCX/native interop)' {
        $files = @{ 'Fixture01.al' = "codeunit 50100 Repro`n{`n    var`n        Auto: Automation `"{00000000-0000-0000-0000-000000000000} 1.0:Foo:Foo`";`n    trigger OnRun();`n    begin`n    end;`n}" }
        $result = Test-AlFixtureRuntimeSafety -Files $files
        $result.IsRuntimeSafe | Should -BeFalse
        $result.Violations.Reason | Should -Match 'Automation'
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
