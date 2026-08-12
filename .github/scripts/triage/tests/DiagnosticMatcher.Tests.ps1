BeforeAll {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'DiagnosticMatcher.psm1') -Force
}

Describe 'Get-ExpectedIssueSignature' {
    It 'extracts explicit AL#### codes cited in the issue body' {
        $result = Get-ExpectedIssueSignature -Body "The compiler reports error AL0118 unexpectedly on valid code."
        $result.HasExplicitSignature | Should -BeTrue
        $result.AlCodes | Should -Contain 'AL0118'
    }

    It 'has no explicit signature when the body cites no AL#### code' {
        $result = Get-ExpectedIssueSignature -Body "The compiler crashes with a NullReferenceException, no diagnostic code shown."
        $result.HasExplicitSignature | Should -BeFalse
        $result.AlCodes.Count | Should -Be 0
    }

    It 'extracts Expected/Actual free-text sections when present' {
        $result = Get-ExpectedIssueSignature -Body "Expected: compiles cleanly`nActual: throws AL0118"
        $result.ExpectedText | Should -Be 'compiles cleanly'
        $result.ActualText | Should -Match 'AL0118'
    }
}

Describe 'Get-CompilerDiagnostic (against real captured alc.exe output)' {
    # These fixtures are verbatim console output captured by actually running the pinned ALTools
    # package (Microsoft.Dynamics.BusinessCentral.Development.Tools 17.0.34.45391) via
    # `dotnet tool run al -- compile /project:... /out:... /packagecachepath:...` against minimal
    # local fixtures - not synthetic strings - so the parser is validated against real tool output.

    It 'parses the real AL1021 "package cache path not specified" output with no code fence errors' {
        $output = @'
Microsoft (R) AL Compiler version 17.0.34.45391
Copyright (C) Microsoft Corporation. All rights reserved

Compilation started for project 'Fixture' containing '1' files at '17:10:27.855'.

error AL1021: The package cache path has not been specified.

Compilation ended at '17:10:28.675'.
'@
        $diags = Get-CompilerDiagnostic -Output $output
        $diags.Count | Should -Be 1
        $diags[0].Code | Should -Be 'AL1021'
        $diags[0].Severity | Should -Be 'error'
    }

    It 'parses the real AL1022 "missing System/Application symbol" output (two diagnostics)' {
        $output = @'
Microsoft (R) AL Compiler version 17.0.34.45391
Copyright (C) Microsoft Corporation. All rights reserved

Compilation started for project 'Fixture2' containing '1' files at '17:10:59.370'.

error AL1022: A package with publisher 'Microsoft', name 'Application', and a version compatible with '24.0.0.0' could not be found in the package cache folders: C:\empty
error AL1022: A package with publisher 'Microsoft', name 'System', and a version compatible with '24.0.0.0' could not be found in the package cache folders: C:\empty

Compilation ended at '17:10:59.701'.
'@
        $diags = Get-CompilerDiagnostic -Output $output
        $diags.Count | Should -Be 2
        ($diags | Where-Object Code -eq 'AL1022').Count | Should -Be 2
    }

    It 'parses a real file-scoped syntax diagnostic alongside AL1022 (the AL0104 semicolon case)' {
        $output = @'
Microsoft (R) AL Compiler version 17.0.34.45391
Copyright (C) Microsoft Corporation. All rights reserved

Compilation started for project 'Fixture4' containing '1' files at '17:14:47.624'.

error AL1022: A package with publisher 'Microsoft', name 'System', and a version compatible with '24.0.0.0' could not be found in the package cache folders: C:\empty
proj4\Fixture01.al(7,1): error AL0104: Syntax error, ';' expected

Compilation ended at '17:14:47.963'.
'@
        $diags = Get-CompilerDiagnostic -Output $output
        $diags.Count | Should -Be 2
        ($diags | Where-Object Code -eq 'AL0104').Message | Should -Match "Syntax error, ';' expected"
    }
}

Describe 'Test-EnvironmentalDiagnostic' {
    It 'flags AL1021/AL1022 as environmental' {
        Test-EnvironmentalDiagnostic -Diagnostic ([pscustomobject]@{ Code = 'AL1021'; Message = 'The package cache path has not been specified.' }) | Should -BeTrue
        Test-EnvironmentalDiagnostic -Diagnostic ([pscustomobject]@{ Code = 'AL1022'; Message = "A package ... could not be found in the package cache folders: X" }) | Should -BeTrue
    }

    It 'does not flag an unrelated AL diagnostic as environmental' {
        Test-EnvironmentalDiagnostic -Diagnostic ([pscustomobject]@{ Code = 'AL0104'; Message = "Syntax error, ';' expected" }) | Should -BeFalse
    }
}

Describe 'Resolve-ReproductionStatus' {

    It 'marks a fixture requiring only environmental diagnostics as inconclusive/RequiresContainer, never reproduced' {
        $expected = Get-ExpectedIssueSignature -Body 'Base Application table extension throws AL0118 unexpectedly.'
        $observed = @([pscustomobject]@{ Severity = 'error'; Code = 'AL1022'; Message = 'could not be found in the package cache folders: X' })
        $result = Resolve-ReproductionStatus -ExpectedSignature $expected -ObservedDiagnostics $observed -RawOutput 'error AL1022: could not be found in the package cache folders: X'
        $result.Status | Should -Be 'inconclusive'
        $result.RequiresContainer | Should -BeTrue
        $result.Status | Should -Not -Be 'reproduced'
    }

    It 'marks a matching AL code as reproduced when the issue cites it explicitly' {
        $expected = Get-ExpectedIssueSignature -Body 'The compiler reports error AL0104 on valid code with a trailing statement.'
        $observed = @(
            [pscustomobject]@{ Severity = 'error'; Code = 'AL1022'; Message = 'could not be found in the package cache folders: X' }
            [pscustomobject]@{ Severity = 'error'; Code = 'AL0104'; Message = "Syntax error, ';' expected" }
        )
        $result = Resolve-ReproductionStatus -ExpectedSignature $expected -ObservedDiagnostics $observed -RawOutput 'error AL0104: ...'
        $result.Status | Should -Be 'reproduced'
        $result.RequiresContainer | Should -BeFalse
    }

    It 'marks a non-matching AL code as not_reproduced (evidence collected, no match)' {
        $expected = Get-ExpectedIssueSignature -Body 'The compiler reports error AL9999 which should not happen.'
        $observed = @([pscustomobject]@{ Severity = 'error'; Code = 'AL0104'; Message = "Syntax error, ';' expected" })
        $result = Resolve-ReproductionStatus -ExpectedSignature $expected -ObservedDiagnostics $observed -RawOutput 'error AL0104: ...'
        $result.Status | Should -Be 'not_reproduced'
    }

    It 'marks a clean compile with no explicit issue signature as inconclusive, never reproduced' {
        $expected = Get-ExpectedIssueSignature -Body 'Something is wrong but I cannot pin down a diagnostic code.'
        $result = Resolve-ReproductionStatus -ExpectedSignature $expected -ObservedDiagnostics @() -RawOutput 'Compilation ended.'
        $result.Status | Should -Be 'inconclusive'
        $result.Status | Should -Not -Be 'reproduced'
    }

    It 'marks a clean compile with an explicit issue signature as not_reproduced' {
        $expected = Get-ExpectedIssueSignature -Body 'Expected AL0104 to fire but it does not.'
        $result = Resolve-ReproductionStatus -ExpectedSignature $expected -ObservedDiagnostics @() -RawOutput 'Compilation ended.'
        $result.Status | Should -Be 'not_reproduced'
    }

    It 'never reports reproduced for a CLI usage/invocation failure' {
        $expected = Get-ExpectedIssueSignature -Body 'error AL0104 expected.'
        $result = Resolve-ReproductionStatus -ExpectedSignature $expected -ObservedDiagnostics @() -RawOutput "Unrecognized command or argument 'help'."
        $result.Status | Should -Be 'inconclusive'
        $result.RequiresContainer | Should -BeFalse
    }
}
