---
name: run-al-code-analysis
description: Runs CodeCop, PerTenantExtensionCop, UICop, or AppSourceCop against a temporary project through the public prerelease ALTool.
argument-hint: "<project-folder> <analyzer>"
---

1. Invoke `verify-prerelease-altool`.
2. Invoke `download-al-symbols` when the project has symbol references.
3. Create a temporary `.code-workspace` through:
   ```powershell
   & $env:ALTOOL_PATH workspace create $workspaceFile $projectPath
   ```
4. Run the requested analyzer with ALTool workspace compile:
   ```powershell
   & $env:ALTOOL_PATH workspace compile $workspaceFile `
       --packagecachepath (Join-Path $projectPath '.alpackages') `
       --analyzers PTECop `
       --outfolder $outputFolder `
       --errorlogdirectory $errorLogFolder
   ```
   Select only the reported analyzer from `AppSourceCop`, `CodeCop`, `PTECop`, or `UICop`. Use
   `--ruleset` when the issue supplies one. Never invoke `alc.exe`.
5. Preserve the exact diagnostics and exit code. A missing analyzer, ruleset, or symbol package is an
   inconclusive setup failure, not evidence that no diagnostic exists.
6. Exercise both the reported case and the nearest valid control case when feasible.
