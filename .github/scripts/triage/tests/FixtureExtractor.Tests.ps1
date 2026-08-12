BeforeAll {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'FixtureExtractor.psm1') -Force
}

Describe 'Get-AlCodeFixture' {

    It 'extracts a single al-tagged code fence into a fixture file' {
        $body = "Repro:`n``````al`ncodeunit 50100 Repro { trigger OnRun(); begin end; }`n```````n"
        $result = Get-AlCodeFixture -Body $body
        $result.Blocked | Should -BeFalse
        $result.Files.Count | Should -Be 1
        ($result.Files.Values | Select-Object -First 1) | Should -Match 'codeunit 50100 Repro'
    }

    It 'extracts an untagged fence that looks like AL source' {
        $body = "```````n" + "page 50100 Repro { }" + "`n``````"
        $result = Get-AlCodeFixture -Body $body
        $result.Blocked | Should -BeFalse
        $result.Files.Count | Should -Be 1
    }

    It 'skips fences tagged as a non-AL language' {
        $body = "``````json`n{ ""a"": 1 }`n``````"
        $result = Get-AlCodeFixture -Body $body
        $result.Blocked | Should -BeTrue
    }

    It 'is blocked when there is no code fence at all' {
        $result = Get-AlCodeFixture -Body 'just a description, no code'
        $result.Blocked | Should -BeTrue
        $result.BlockReasons | Should -Contain 'No fenced code block found in the issue body.'
    }

    It 'flags but does not fetch an external repository reference' {
        $body = "See repro: git clone https://example.com/some/repo.git`n``````al`ncodeunit 50100 Repro { trigger OnRun(); begin end; }`n```````n"
        $result = Get-AlCodeFixture -Body $body
        $result.ExternalReference | Should -BeTrue
        $result.Blocked | Should -BeFalse
        $result.Files.Count | Should -Be 1
    }

    It 'blocks a fixture that exceeds the maximum fence count bound' {
        $sb = [System.Text.StringBuilder]::new()
        for ($i = 0; $i -lt 25; $i++) {
            $sb.AppendLine("``````al") | Out-Null
            $sb.AppendLine("codeunit 501$i Repro$i { trigger OnRun(); begin end; }") | Out-Null
            $sb.AppendLine("``````") | Out-Null
        }
        $result = Get-AlCodeFixture -Body $sb.ToString()
        $result.Blocked | Should -BeTrue
        $result.BlockReasons | Where-Object { $_ -match 'exceeding' } | Should -Not -BeNullOrEmpty
    }

    It 'names extracted files using a detected AL object type hint' {
        $body = "``````al`ntable 50100 Repro { fields { } }`n``````"
        $result = Get-AlCodeFixture -Body $body
        ($result.Files.Keys | Select-Object -First 1) | Should -Match '\.table\.al$'
    }
}

Describe 'New-MinimalAlProject' {
    It 'materializes app.json and fixture files into an isolated directory' {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
        try {
            $files = @{ 'Fixture01.al' = 'codeunit 50100 Repro { trigger OnRun(); begin end; }' }
            $projectPath = New-MinimalAlProject -Files $files -DestinationRoot $tempRoot
            Test-Path (Join-Path $projectPath 'app.json') | Should -BeTrue
            Test-Path (Join-Path $projectPath 'Fixture01.al') | Should -BeTrue
            (Get-Content (Join-Path $projectPath 'app.json') -Raw | ConvertFrom-Json).target | Should -Be 'Cloud'
        } finally {
            Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
