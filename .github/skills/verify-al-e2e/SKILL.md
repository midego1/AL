---
name: verify-al-e2e
description: Orchestrates the smallest production-path AL reproduction through the workflow-installed public prerelease ALTool and BCInsider sandbox.
argument-hint: "<scenario>"
---

1. Invoke `verify-prerelease-altool`.
2. Create the smallest fixture with `create-al-project`.
3. Select the required path:
   - compiler or diagnostic: `compile-al-app`;
   - analyzer: `run-al-code-analysis`;
   - platform/application dependencies: `download-al-symbols`, then `compile-al-app`;
   - publish/install: `publish-al-app`;
   - runtime behavior: `publish-al-app`, then `run-al-tests`.
4. Run the reported case and a valid control case when feasible.
5. Preserve ALTool version, BC artifact version, commands/skill calls, diagnostics, exit codes, and
   test results.
6. Keep all fixtures and output under `$env:RUNNER_TEMP` and remove them after evidence is captured.

Do not replace execution with source reading when the scenario can run.
