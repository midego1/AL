# Static guard test: proves (by scanning actual committed source, not by trusting a comment) that
# nothing in the triage automation ever references a private GHE/ADO host, private NuGet/npm feed,
# or private credential/environment-variable name. This is the automated enforcement of the
# repository's hard security boundary for this feature.

BeforeAll {
    $script:TriageRoot = Split-Path -Parent $PSScriptRoot
    $script:SourceFiles = Get-ChildItem -Path $script:TriageRoot -Recurse -Include *.ps1, *.psm1 | Where-Object { $_.FullName -notmatch '\\tests\\' }
}

Describe 'Public-only credential/endpoint guard' {

    It 'has at least one source file to scan (sanity check the test itself is not vacuous)' {
        $script:SourceFiles.Count | Should -BeGreaterThan 0
    }

    It 'never references a GitHub Enterprise host' {
        foreach ($file in $script:SourceFiles) {
            (Get-Content -Path $file.FullName -Raw) | Should -Not -Match '(?i)\bghe\.com\b' -Because $file.Name
        }
    }

    It 'never references Azure DevOps hosts or ADO-specific environment variables' {
        foreach ($file in $script:SourceFiles) {
            $content = Get-Content -Path $file.FullName -Raw
            $content | Should -Not -Match '(?i)dev\.azure\.com' -Because $file.Name
            $content | Should -Not -Match '(?i)visualstudio\.com' -Because $file.Name
            $content | Should -Not -Match '(?i)\bSYSTEM_ACCESSTOKEN\b' -Because $file.Name
            $content | Should -Not -Match '(?i)\bADO_PAT\b' -Because $file.Name
        }
    }

    It 'never references a private/internal NuGet feed host' {
        foreach ($file in $script:SourceFiles) {
            $content = Get-Content -Path $file.FullName -Raw
            $content | Should -Not -Match '(?i)pkgs\.visualstudio\.com' -Because $file.Name
            $content | Should -Not -Match '(?i)pkgs\.dev\.azure\.com' -Because $file.Name
        }
    }

    It 'the orchestrator only ever builds GitHub API URIs from the public api.github.com base' {
        $orchestrator = Get-Content -Path (Join-Path $script:TriageRoot 'Invoke-IssueTriage.ps1') -Raw
        $orchestrator | Should -Match "GitHubApiBase\s*=\s*'https://api\.github\.com'"
        # Every "$script:GitHubApiBase$Path"-style URI construction must be anchored to that one
        # base variable - there must be no second, hardcoded API host string anywhere else.
        $otherApiHosts = [regex]::Matches($orchestrator, '(?i)https?://[a-z0-9.\-]*\.(com|net|org)') |
            ForEach-Object { $_.Value } |
            Where-Object { $_ -notmatch '(?i)api\.github\.com' -and $_ -notmatch '(?i)api\.nuget\.org' }
        $otherApiHosts | Should -BeNullOrEmpty
    }

    It 'Tier1Reproduction only ever restores packages from the public NuGet.org feed' {
        $content = Get-Content -Path (Join-Path $script:TriageRoot 'Tier1Reproduction.psm1') -Raw
        $content | Should -Match '(?i)api\.nuget\.org'
        $content | Should -Not -Match '(?i)\bpkgs\.'
    }

    It 'never hardcodes a token/secret value (only ever references a $Token/$GitHubToken parameter)' {
        foreach ($file in $script:SourceFiles) {
            $content = Get-Content -Path $file.FullName -Raw
            # A real secret would not be expressed as "$Token"/"$GitHubToken" interpolation - flag
            # any Authorization header that is not built from one of those parameter names.
            $authLines = [regex]::Matches($content, '(?im)^.*Authorization\s*=.*$') | ForEach-Object { $_.Value }
            foreach ($line in $authLines) {
                $line | Should -Match '\$(GitHubToken|Token)\b' -Because "$($file.Name): $line"
            }
        }
    }
}
