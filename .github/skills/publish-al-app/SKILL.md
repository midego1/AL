---
name: publish-al-app
description: Publishes one compiled AL app to the provisioned BCInsider sandbox through the public prerelease ALTool.
argument-hint: "<app-path> [project-folder]"
---

1. Invoke `verify-prerelease-altool`.
2. Compile project inputs with `compile-al-app`; use the emitted `.app` path.
3. Publish non-interactively:
   ```powershell
   & $env:ALTOOL_PATH publishapp $appPath `
       --project $projectPath `
       --server $env:BC_SERVER_URL `
       --serverinstance $env:BC_SERVER_INSTANCE `
       --port $env:BC_SERVER_PORT `
       --authentication $env:BC_AUTHENTICATION `
       --environmenttype OnPrem `
       --schemaupdatemode Synchronize
   ```
4. Use `--forceupgrade`, `ForceSync`, or `Recreate` only when required by the reported scenario.
5. Preserve output and exit code. Do not call `/dev/apps` directly.
