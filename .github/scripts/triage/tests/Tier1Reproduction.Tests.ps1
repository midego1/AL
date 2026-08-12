# Real, execution-first integration tests for Tier 1 (server-free) reproduction. These tests
# actually install the pinned ALTools NuGet package and run `al compile` against generated
# fixtures - no mocking of the compiler - to validate the exact command syntax and reproduction
# classification against real tool output. They require outbound network access to nuget.org and
# are slower than the rest of the suite (each version install + compile takes tens of seconds).

BeforeAll {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Tier1Reproduction.psm1') -Force
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'FixtureExtractor.psm1') -Force
    $script:Config = Get-AlToolsVersionConfig
}

Describe 'Test-NuGetPackageVersionExist (real NuGet.org lookup)' {
    It 'confirms the pinned stable ALTools version really exists on NuGet.org' {
        Test-NuGetPackageVersionExist -PackageId $script:Config.packageId -Version $script:Config.stable | Should -BeTrue
    }

    It 'reports a made-up version as not existing' {
        Test-NuGetPackageVersionExist -PackageId $script:Config.packageId -Version '999.999.999.99999' | Should -BeFalse
    }
}

Describe 'Get-ReportedAlToolsPackageVersion' {
    It 'does NOT extract the VS Code marketplace "AL Extension Version" as an ALTools package version' {
        $body = "- AL Extension Version: 13.2`n- Server Version: 24.0"
        Get-ReportedAlToolsPackageVersion -Body $body | Should -BeNullOrEmpty
    }

    It 'extracts a version only when explicitly framed as an ALTools/CLI package version' {
        $body = "Repro fails with Microsoft.Dynamics.BusinessCentral.Development.Tools version: 17.0.34.45391"
        Get-ReportedAlToolsPackageVersion -Body $body | Should -Be '17.0.34.45391'
    }
}

Describe 'Invoke-Tier1Reproduction (real pinned-package execution)' {

    It 'uses /project:, /out:, and /packagecachepath: (not --project) in the actual compile command' {
        $work = Join-Path ([System.IO.Path]::GetTempPath()) ("t1-cmd-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        try {
            $files = @{ 'Fixture01.al' = "codeunit 50100 Repro`n{`n    trigger OnRun()`n    begin`n        Message('repro');`n    end;`n}" }
            $projectPath = New-MinimalAlProject -Files $files -DestinationRoot $work

            $result = Invoke-Tier1Reproduction -ProjectPath $projectPath -IssueBody '' -WorkRoot (Join-Path $work 'tools')

            $result.Results.stable.Restored | Should -BeTrue
            $result.Results.stable.Command | Should -Match '/project:"'
            $result.Results.stable.Command | Should -Match '/out:"'
            $result.Results.stable.Command | Should -Match '/packagecachepath:"'
            $result.Results.stable.Command | Should -Not -Match '--project'
        } finally {
            Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'classifies a dependency-free, symbol-only-blocked fixture as RequiresContainer/inconclusive, never reproduced' {
        $work = Join-Path ([System.IO.Path]::GetTempPath()) ("t1-al1022-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        try {
            $files = @{ 'Fixture01.al' = "codeunit 50100 Repro`n{`n    trigger OnRun()`n    begin`n        Message('repro');`n    end;`n}" }
            $projectPath = New-MinimalAlProject -Files $files -DestinationRoot $work

            $result = Invoke-Tier1Reproduction -ProjectPath $projectPath -IssueBody 'The compiler behaves strangely (no diagnostic code known).' -WorkRoot (Join-Path $work 'tools')

            $result.Results.stable.Restored | Should -BeTrue
            $result.Results.stable.Status | Should -Be 'inconclusive'
            $result.Results.stable.RequiresContainer | Should -BeTrue
            $result.Results.stable.Status | Should -Not -Be 'reproduced'
            ($result.Results.stable.Diagnostics | Where-Object Code -eq 'AL1022').Count | Should -BeGreaterThan 0
        } finally {
            Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reproduces a real cited AL#### diagnostic (AL0104 missing semicolon) via real compilation' {
        $work = Join-Path ([System.IO.Path]::GetTempPath()) ("t1-al0104-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        try {
            # Deliberately missing semicolon after Message(...) - triggers a real AL0104 syntax
            # diagnostic regardless of missing System symbols (validated manually beforehand).
            $files = @{ 'Fixture01.al' = "codeunit 50100 Repro`n{`n    trigger OnRun()`n    begin`n        Message('repro')`n    end`n}" }
            $projectPath = New-MinimalAlProject -Files $files -DestinationRoot $work

            $result = Invoke-Tier1Reproduction -ProjectPath $projectPath -IssueBody 'The compiler reports error AL0104 on code that should be a simple (if incomplete) statement.' -WorkRoot (Join-Path $work 'tools')

            $result.Results.stable.Restored | Should -BeTrue
            ($result.Results.stable.Diagnostics | Where-Object Code -eq 'AL0104').Count | Should -BeGreaterThan 0
            $result.Results.stable.Status | Should -Be 'reproduced'
        } finally {
            Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'does not claim reproduced for an unrelated cited AL code that never appears' {
        $work = Join-Path ([System.IO.Path]::GetTempPath()) ("t1-nomatch-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        try {
            $files = @{ 'Fixture01.al' = "codeunit 50100 Repro`n{`n    trigger OnRun()`n    begin`n        Message('repro')`n    end`n}" }
            $projectPath = New-MinimalAlProject -Files $files -DestinationRoot $work

            $result = Invoke-Tier1Reproduction -ProjectPath $projectPath -IssueBody 'The compiler reports error AL9999 which is not a real code and should never match.' -WorkRoot (Join-Path $work 'tools')

            $result.Results.stable.Status | Should -Be 'not_reproduced'
        } finally {
            Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
