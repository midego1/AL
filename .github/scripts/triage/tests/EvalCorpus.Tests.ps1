BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'ScopePrefilter.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' 'FixtureExtractor.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' 'SafetyGuard.psm1') -Force
}

# Loaded at discovery time (not inside BeforeAll) because Pester evaluates -ForEach collections
# during test discovery, before any BeforeAll block runs.
$script:Corpus = Get-Content -Path (Join-Path $PSScriptRoot 'fixtures' 'eval-corpus.json') -Raw | ConvertFrom-Json

Describe 'Public AL issue triage - labeled eval corpus replay' {

    It 'has at least one fixture for every required corpus category' {
        $corpus = Get-Content -Path (Join-Path $PSScriptRoot 'fixtures' 'eval-corpus.json') -Raw | ConvertFrom-Json
        $requiredCategories = @(
            'in-scope', 'runtime', 'application', 'question', 'suggestion', 'duplicate',
            'missing-repro', 'ui-only', 'unsafe-code', 'prompt-injection'
        )
        foreach ($category in $requiredCategories) {
            ($corpus | Where-Object { $_.category -eq $category }).Count | Should -BeGreaterThan 0 -Because "corpus must cover '$category'"
        }
    }

    It 'classifies scope as expected for every corpus entry: <_.id>' -ForEach $script:Corpus {
        $entry = $_
        $result = Get-IssueScopeClassification -Title $entry.title -Body $entry.body
        $result.Scope | Should -Be $entry.expectedScope -Because $entry.id

        if ($entry.PSObject.Properties.Match('expectedCategory').Count -gt 0) {
            $result.Category | Should -Be $entry.expectedCategory -Because $entry.id
        }
        if ($entry.PSObject.Properties.Match('expectedManualRepro').Count -gt 0) {
            $result.ManualReproductionRequired | Should -Be $entry.expectedManualRepro -Because $entry.id
        }

        # Prompt-injection invariant: no matter what the body asks for, 'accepted' must never appear.
        $result.SuggestedLabels | Should -Not -Contain 'accepted' -Because $entry.id
    }

    It 'correctly flags external repository references without fetching them: <_.id>' -ForEach ($script:Corpus | Where-Object { $_.PSObject.Properties.Match('expectedExternalReference').Count -gt 0 }) {
        $entry = $_
        $fixture = Get-AlCodeFixture -Body $entry.body
        $fixture.ExternalReference | Should -Be $entry.expectedExternalReference -Because $entry.id
    }

    It 'correctly gates runtime safety for unsafe-code corpus entries: <_.id>' -ForEach ($script:Corpus | Where-Object { $_.PSObject.Properties.Match('expectedRuntimeSafe').Count -gt 0 }) {
        $entry = $_
        $fixture = Get-AlCodeFixture -Body $entry.body
        $fixture.Blocked | Should -BeFalse -Because $entry.id
        $safety = Test-AlFixtureRuntimeSafety -Files $fixture.Files
        $safety.IsRuntimeSafe | Should -Be $entry.expectedRuntimeSafe -Because $entry.id
    }
}
