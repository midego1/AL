---
name: verify-prerelease-altool
description: Verifies that the workflow-installed public prerelease ALTool is the executable used for every reproduction command.
---

Resolve ALTool only from `ALTOOL_PATH`, then verify it matches `ALTOOL_VERSION`:

```powershell
$altool = $env:ALTOOL_PATH
if (-not (Test-Path -LiteralPath $altool -PathType Leaf)) {
    throw "Prerelease ALTool not found: $altool"
}
$actualVersion = (& $altool --version 2>&1 | Out-String).Trim()
if ($actualVersion -ne $env:ALTOOL_VERSION) {
    throw "Expected ALTool '$env:ALTOOL_VERSION', got '$actualVersion'."
}
```

Do not use a repository-built, globally cached, or separately downloaded executable.
