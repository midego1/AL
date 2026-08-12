# Public `microsoft/AL` issue triage automation

Native GitHub Actions automation that triages issues opened in this public repository:
deterministic scope/template classification, safe reproduction with published tooling, and a
public structured comment plus labels. See `.github/workflows/al-issue-triage.yml` for the
workflow entry points (issue events, manual dispatch, and a low-frequency stale reconciliation
schedule).

## Hard security boundary

This automation is intentionally isolated from every private Microsoft system:

- It only ever calls the public `https://api.github.com` REST API, authenticated with the
  workflow-scoped `secrets.GITHUB_TOKEN` for **this repository only**.
- It never references a GitHub Enterprise (`*.ghe.com`) host, Azure DevOps, a private NuGet/npm
  feed, or any private credential, secret, or agent.
- It never closes an issue and never applies the `accepted` label. Acceptance is a human-only
  decision; the existing, separate `accepted`-label automation independently creates any internal
  follow-up work item. `ScopePrefilter.psm1`'s `ConvertTo-SafeLabelList` and
  `Invoke-IssueTriage.ps1`'s `Add-TriageLabel` both hard-filter out `accepted` as defense in depth.
- Issue title/body/AL code is **untrusted, potentially prompt-injecting input**. It is only ever
  used as inert data for regex classification and fixture extraction - never executed as
  instructions, and a linked repository/script is never cloned or run
  (`FixtureExtractor.psm1` only extracts inline fenced code and flags external references).

## Pipeline

1. **`ScopePrefilter.psm1`** - deterministic, rule-table-based scope classification
   (`in_scope` / `out_of_scope` / `needs_human`) plus template/repro completeness checks and a
   best-effort, purely informational duplicate-title suggestion.
2. **`FixtureExtractor.psm1`** - extracts only inline ```al fenced code blocks into a minimal AL
   project (`app.json` + `.al` files) under bounded size/count limits. Flags (but never fetches)
   external repository/script references.
3. **`SafetyGuard.psm1`** - scans the extracted fixture for DotNet interop, control add-ins,
   HttpClient/network, file-system, and process-integration constructs. Compilation is always
   allowed; only *runtime execution* (Tier 2) is refused when the fixture is unsafe.
4. **`Tier1Reproduction.psm1`** - server-free reproduction: restores pinned
   `Microsoft.Dynamics.BusinessCentral.Development.Tools` (ALTools/`altool`) NuGet package
   versions from `AlToolsVersions.json` (stable + preview, plus the issue's reported version when
   disclosed) and runs `al compile` against the fixture with each.
5. **`Tier2ContainerReproduction.psm1`** *(opt-in only, `workflow_dispatch`)* - starts a disposable
   stock Business Central sandbox container via the public `BcContainerHelper` module, downloads
   exact symbols, compiles/publishes, and always tears the container down - even on failure or
   timeout. Refuses to run when `SafetyGuard` reports the fixture unsafe.
6. **`ReportBuilder.psm1`** - builds the structured JSON report and renders it as a single,
   idempotent Markdown comment (found/updated via a hidden `<!-- public-al-issue-triage:v1:issue-N
   -->` marker) so re-triage never duplicates a comment.
7. **`Invoke-IssueTriage.ps1`** - orchestrates the above and posts the comment/labels through the
   public GitHub REST API only.

## Updating pinned ALTools versions

`AlToolsVersions.json` intentionally pins exact `stable`/`preview` package versions rather than
floating to "latest", so reproduction results stay repeatable run-to-run. Bump these fields in a
reviewed PR when a new ALTools package ships; do not change the workflow to resolve an unpinned
latest version at runtime.

## Testing

`tests/` contains Pester unit tests for `ScopePrefilter`, `FixtureExtractor`, and `SafetyGuard`,
plus `EvalCorpus.Tests.ps1`, which replays a labeled corpus
(`tests/fixtures/eval-corpus.json`) covering in-scope, runtime, application, question, suggestion,
duplicate, missing-repro, UI-only, unsafe-code, and prompt-injection issues. Run from the repo
root:

```powershell
Invoke-Pester -Path .github/scripts/triage/tests
```

`Invoke-IssueTriage.ps1` itself talks to the live GitHub REST API and is not covered by these
offline unit tests; its correctness is verified indirectly by testing every decision function it
calls, and via `-DryRun` (skips posting the comment/labels, prints the computed report instead).
