---
name: run-al-tests
description: Runs a published AL test codeunit against the provisioned BCInsider sandbox through the public prerelease ALTool.
argument-hint: "<codeunit-id> [project-folder] [test-methods]"
---

1. Invoke `verify-prerelease-altool`.
2. Publish the test app with `publish-al-app`.
3. Run structured tests:
   ```powershell
   & $env:ALTOOL_PATH runtests $codeunitId `
       --project $projectPath `
       --server $env:BC_SERVER_URL `
       --serverinstance $env:BC_SERVER_INSTANCE `
       --port $env:BC_SERVER_PORT `
       --tenant $env:BC_TENANT `
       --authentication $env:BC_AUTHENTICATION `
       --environmenttype OnPrem
   ```
4. Add `--testmethods` only when specific procedures are requested.
5. Preserve the JSON response and native exit code; report passed, failed, and skipped counts.
