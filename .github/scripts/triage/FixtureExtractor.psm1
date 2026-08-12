# Safe, structured fixture extraction from inline AL in a public issue body.
#
# Security note: issue bodies are UNTRUSTED. This module only ever *extracts text* into files on
# disk for later compilation - it never executes issue text as a script/command, never follows
# links to external repositories, and never shells out based on issue content.

Set-StrictMode -Version Latest

$script:MaxFenceCount = 20
$script:MaxTotalFixtureBytes = 200KB
$script:MaxSingleFenceBytes = 64KB

# Patterns that indicate the reporter is pointing at an external repository/script instead of
# providing an inline sample. We never fetch these - we only note them as a blocker.
$script:ExternalReferencePattern = '(?i)\b(git clone|https?://\S+\.git\b|\bgh repo clone\b|curl\s+-\S*\s*https?://|iwr\s+https?://|invoke-webrequest\s+https?://)\b'

function Get-AlCodeFixture {
    <#
        .SYNOPSIS
        Extracts fenced code blocks that look like AL source from an issue body into an in-memory
        fixture manifest, without executing anything.

        .OUTPUTS
        PSCustomObject with:
          Files            - hashtable of relative-path -> content, ready to write to disk
          Blocked          - bool, true if the body is unsafe/too large/references external code
          BlockReasons     - string[]
          ExternalReference - bool, true if the body points at an external repo/script instead of inline code
    #>
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Body
    )

    $blockReasons = [System.Collections.Generic.List[string]]::new()
    $externalReference = [regex]::IsMatch($Body, $script:ExternalReferencePattern)
    if ($externalReference) {
        # Not fatal by itself - callers may still find inline code fences worth compiling - but it
        # is always surfaced so the report discloses that a linked repo/script was NOT executed.
        $blockReasons.Add('Issue references an external repository or script URL; it was not cloned or executed. Only inline code fences are used.')
    }

    # Match ```al ... ``` (case-insensitive language tag) and generic ``` ... ``` fences.
    $fenceMatches = [regex]::Matches($Body, '(?s)```(?<lang>[a-zA-Z0-9]*)\r?\n(?<code>.*?)```')

    if ($fenceMatches.Count -eq 0) {
        $blockReasons.Add('No fenced code block found in the issue body.')
        return [pscustomobject]@{
            Files              = @{}
            Blocked            = $true
            BlockReasons       = $blockReasons
            ExternalReference  = $externalReference
        }
    }

    if ($fenceMatches.Count -gt $script:MaxFenceCount) {
        $blockReasons.Add("Issue body contains $($fenceMatches.Count) code fences, exceeding the $($script:MaxFenceCount) fixture bound.")
        return [pscustomobject]@{
            Files              = @{}
            Blocked            = $true
            BlockReasons       = $blockReasons
            ExternalReference  = $externalReference
        }
    }

    $files = @{}
    $totalBytes = 0
    $index = 0

    foreach ($match in $fenceMatches) {
        $lang = $match.Groups['lang'].Value
        $code = $match.Groups['code'].Value

        # Only treat fences as AL source when they are untagged, or tagged al/al-code/txt - skip
        # fences the reporter explicitly tagged as another language (e.g. json, yaml, powershell)
        # so we never accidentally try to compile non-AL snippets.
        if ($lang -and ($lang -notmatch '(?i)^(al)$')) { continue }

        $codeBytes = [System.Text.Encoding]::UTF8.GetByteCount($code)
        if ($codeBytes -gt $script:MaxSingleFenceBytes) {
            $blockReasons.Add("A code fence exceeds the $($script:MaxSingleFenceBytes) byte per-fence bound and was skipped.")
            continue
        }

        $totalBytes += $codeBytes
        if ($totalBytes -gt $script:MaxTotalFixtureBytes) {
            $blockReasons.Add("Total extracted fixture size exceeds the $($script:MaxTotalFixtureBytes) byte bound; remaining fences were skipped.")
            break
        }

        $index++
        $objectType = Get-AlObjectTypeHint -Code $code
        $fileName = "Fixture{0:D2}{1}.al" -f $index, $(if ($objectType) { ".$objectType" } else { '' })
        $files[$fileName] = $code
    }

    if ($files.Count -eq 0) {
        $blockReasons.Add('All code fences were skipped (wrong language tag or size bounds).')
        return [pscustomobject]@{
            Files              = @{}
            Blocked            = $true
            BlockReasons       = $blockReasons
            ExternalReference  = $externalReference
        }
    }

    [pscustomobject]@{
        Files              = $files
        Blocked            = $false
        BlockReasons       = $blockReasons
        ExternalReference  = $externalReference
    }
}

function Get-AlObjectTypeHint {
    param([string] $Code)
    if ($Code -match '(?im)^\s*(codeunit|page|pageextension|table|tableextension|report|reportextension|query|xmlport|enum|enumextension|permissionset|controladdin|interface)\b') {
        return $Matches[1].ToLowerInvariant()
    }
    return $null
}

function New-MinimalAlProject {
    <#
        .SYNOPSIS
        Materializes an extracted fixture manifest plus a minimal app.json onto disk in an isolated
        temp directory. Never writes outside of the returned directory.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes only into a freshly created, caller-scoped isolated temp directory; not a user-facing state change requiring -WhatIf/-Confirm.')]
    param(
        [Parameter(Mandatory)] [hashtable] $Files,
        [Parameter(Mandatory)] [string] $DestinationRoot,
        [string] $Id = ([guid]::NewGuid().ToString()),
        [string] $ApplicationVersion = '24.0.0.0',
        [string] $PlatformVersion = '24.0.0.0'
    )

    $projectDir = Join-Path $DestinationRoot "al-triage-fixture-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Force -Path $projectDir | Out-Null

    $appJson = [ordered]@{
        id            = $Id
        name          = 'PublicIssueTriageFixture'
        publisher     = 'al-issue-triage-bot'
        version       = '1.0.0.0'
        application   = $ApplicationVersion
        platform      = $PlatformVersion
        idRanges      = @(@{ from = 50100; to = 50149 })
        target        = 'Cloud'
        runtime       = '13.0'
    }

    $appJson | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $projectDir 'app.json') -Encoding utf8

    foreach ($name in $Files.Keys) {
        Set-Content -Path (Join-Path $projectDir $name) -Value $Files[$name] -Encoding utf8
    }

    return $projectDir
}

Export-ModuleMember -Function Get-AlCodeFixture, Get-AlObjectTypeHint, New-MinimalAlProject
