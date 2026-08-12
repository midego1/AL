# Runtime-safety gate for untrusted, reporter-supplied AL fixtures.
#
# Compilation of a fixture is always considered safe (the AL compiler does not execute the code
# being compiled). Only *runtime execution* (Tier 2 container publish/run) is gated by this module.
# Per the automation's safety boundary, fixtures using DotNet interop, control add-ins, arbitrary
# external HTTP, or file-system/process host integration must never be run - only compiled.

Set-StrictMode -Version Latest

# Each entry: a human-readable reason plus a regex matched against AL source. Kept as an ordered
# list (not a single mega-regex) so a positive match always yields a precise, reportable reason.
$script:UnsafeRuntimePatterns = @(
    @{ Reason = 'Uses DotNet interop, which can call arbitrary .NET Framework/CLR code.'; Pattern = '(?im)^\s*[a-z0-9_]+\s*:\s*DotNet\b' },
    @{ Reason = 'Declares or references a Control Add-in, which loads external host-integration code.'; Pattern = '(?i)\bControlAddIn\b' },
    @{ Reason = 'Uses HttpClient/HttpRequestMessage/HttpContent for arbitrary outbound network calls.'; Pattern = '(?i)\bHttp(Client|RequestMessage|ResponseMessage|Content)\b' },
    @{ Reason = 'Uses the File data type or FileManagement codeunit for host file-system access.'; Pattern = '(?i)\b(FileManagement|File\s*:\s*File\b|"?File"?\s+Management)\b' },
    @{ Reason = 'Uses low-level Automation/OCX/native interop.'; Pattern = '(?i)\bAutomation\b' },
    @{ Reason = 'References a SMTP/mail client that may perform outbound network actions.'; Pattern = '(?i)\bSmtpClient\b' },
    @{ Reason = 'Uses process/shell invocation, which is never permitted in an untrusted fixture.'; Pattern = '(?i)\b(Shell\(|Process\.(Start|Create)|System\.Diagnostics\.Process)\b' }
)

function Test-AlFixtureRuntimeSafety {
    <#
        .SYNOPSIS
        Scans extracted AL fixture source for host-integration/network/file/process constructs
        that must never be executed against an untrusted, reporter-supplied fixture.

        .OUTPUTS
        PSCustomObject with:
          IsRuntimeSafe - bool, true only if no unsafe pattern was found in any file
          Violations    - array of { File, Reason }
    #>
    param(
        [Parameter(Mandatory)] [hashtable] $Files # relative-path -> content
    )

    $violations = [System.Collections.Generic.List[object]]::new()

    foreach ($fileName in $Files.Keys) {
        $content = $Files[$fileName]
        foreach ($rule in $script:UnsafeRuntimePatterns) {
            if ($content -match $rule.Pattern) {
                $violations.Add([pscustomobject]@{ File = $fileName; Reason = $rule.Reason })
            }
        }
    }

    [pscustomobject]@{
        IsRuntimeSafe = ($violations.Count -eq 0)
        Violations    = $violations
    }
}

Export-ModuleMember -Function Test-AlFixtureRuntimeSafety
