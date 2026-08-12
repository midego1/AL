# Public `microsoft/AL` issue triage automation

Native GitHub Actions automation that triages issues opened in this public repository:
deterministic scope/template classification, honest (symptom-matched, never assumed) reproduction
with published tooling, and a public structured comment plus reconciled labels. See
`.github/workflows/al-issue-triage.yml` for the workflow entry points (issue events, a validation
job on PRs that touch this automation, manual dispatch, and a low-frequency stale reconciliation
schedule).

## Hard security boundary

This automation is intentionally isolated from every private Microsoft system:

- It only ever calls the public `https://api.github.com` REST API, authenticated with the
  workflow-scoped `secrets.GITHUB_TOKEN` for **this repository only**, and only ever restores
  packages from the public NuGet.org / PowerShell Gallery feeds.
- It never references a GitHub Enterprise (`*.ghe.com`) host, Azure DevOps, a private NuGet/npm
  feed, or any private credential, secret, or agent. Enforced by
  `tests/SecurityGuard.Tests.ps1`, which statically scans every source file for these patterns,
  and by the `validate` PR job, which runs the same guard on every change to this automation.
- It never closes an issue and never applies the `accepted` label. Acceptance is a human-only
  decision; the existing, separate `accepted`-label automation independently creates any internal
  follow-up work item. If an issue already carries `accepted`, `Invoke-IssueTriage.ps1` is a strict
  no-op (`Test-IsAcceptedNoOp`) - it makes zero API calls that could mutate the issue.
  `ScopePrefilter.psm1`'s `ConvertTo-SafeLabelList` and `OrchestratorLogic.psm1`'s
  `Get-LabelReconciliationPlan` both hard-filter out `accepted` as defense in depth.
- Issue title/body/AL code is **untrusted, potentially prompt-injecting input**. It is only ever
  used as inert data for regex classification and fixture extraction - never executed as
  instructions, and a linked repository/script is never cloned or run
  (`FixtureExtractor.psm1` only extracts inline fenced code and flags external references).

## Pipeline

1. **`ScopePrefilter.psm1`** - deterministic, rule-table-based scope classification
   (`in_scope` / `out_of_scope` / `needs_human`) plus template/repro completeness checks.
   `Get-ManagedLabelSet` exposes the fixed vocabulary of labels this automation is ever allowed to
   touch, used for label reconciliation.
2. **`FixtureExtractor.psm1`** - extracts only inline ```al fenced code blocks into a minimal,
   **dependency-free by default** AL project (no `application` manifest dependency - see
   "Dependency-free Tier 1 fixtures" below) under bounded size/count limits. Flags (but never
   fetches) external repository/script references.
3. **`SafetyGuard.psm1`** - scans the extracted fixture for DotNet interop (including quoted
   identifiers with spaces), control add-ins, HttpClient/WebRequest, the `File` data type / virtual
   `File` table / streams, Automation, SmtpClient, and process/shell invocation. Compilation is
   always allowed; only *runtime execution* (Tier 2) is refused when the fixture is unsafe.
4. **`DiagnosticMatcher.psm1`** - the honesty layer. Parses raw `alc.exe` output into structured
   diagnostics, extracts an explicit AL#### signature (or Expected/Actual text) from the issue,
   and resolves reproduction status - see "Reproduction is never assumed" below.
5. **`Tier1Reproduction.psm1`** - server-free reproduction: restores pinned
   `Microsoft.Dynamics.BusinessCentral.Development.Tools` (ALTools/`altool`) NuGet package
   versions from `AlToolsVersions.json` (stable + preview, plus an issue-cited ALTools *package*
   version only when explicitly identified as such and confirmed to exist on NuGet.org - see
   below) and runs `al compile` against the fixture with each, then resolves reproduction via
   `DiagnosticMatcher`.
6. **`Tier2ContainerReproduction.psm1`** *(opt-in only, `workflow_dispatch`)* - starts a disposable
   stock Business Central sandbox container via the public `BcContainerHelper` module, downloads
   exact symbols, compiles/publishes, and - only when a safe, deterministic `[Test]` procedure is
   present in the fixture - runs exactly that test and symptom-matches its result. Always tears
   the container down, even on failure/timeout. Refuses to run when `SafetyGuard` reports the
   fixture unsafe. **Not verified by execution in this development environment** - see "Tier 2
   verification status" below.
7. **`OrchestratorLogic.psm1`** - pure, side-effect-free orchestration decisions (accepted no-op,
   label reconciliation add/remove plan, exact-duplicate-title check, combining per-version Tier 1
   results into one overall status) extracted so they are unit-testable without any network call.
8. **`ReportBuilder.psm1`** - builds the structured JSON report (schema v2: adds `inconclusive` as
   a valid `reproduction` value and a `requiresContainer` flag) and renders it as a single,
   idempotent Markdown comment (found/updated via a hidden
   `<!-- public-al-issue-triage:v2:issue-N -->` marker) so re-triage never duplicates a comment.
9. **`Invoke-IssueTriage.ps1`** - the thin network-calling orchestrator: fetches the issue, applies
   the accepted no-op check, runs the pipeline above, fetches a bounded list of open issues for
   duplicate suggestion, and posts the comment/reconciled labels through the public GitHub REST
   API only (`$script:GitHubApiBase = 'https://api.github.com'`, enforced by
   `tests/SecurityGuard.Tests.ps1`).

## Reproduction is never assumed

A nonzero exit code, a compile failure, or even a successful container publish is **never**
sufficient evidence of "reproduced" by itself - each looks identical to an unrelated
environment/tooling problem at that level. Concretely, validated by actually running the pinned
ALTools package (`tests/Tier1Reproduction.Tests.ps1`, `tests/DiagnosticMatcher.Tests.ps1`):

- `al compile` is a thin wrapper that forwards its arguments verbatim to `alc.exe` (confirmed via
  `dotnet tool run al -- help compile`). `alc.exe` uses colon-attached single-slash arguments -
  `/project:<path> /out:<appFile> /packagecachepath:<cacheDir>` - **not** `--project`.
- `alc.exe` can exit **0** even when it reported a compiler error (observed for AL1021 "package
  cache path has not been specified"), so exit code is never treated as evidence.
- `DiagnosticMatcher.psm1` parses actual diagnostics out of the output and classifies each as
  environmental (AL1021/AL1022 - missing package cache/symbols, our own fixture/tooling gap) or a
  real AL compiler diagnostic. `Resolve-ReproductionStatus` only returns `reproduced` when a
  non-environmental diagnostic's AL code matches one the issue explicitly cites
  (`Get-ExpectedIssueSignature`); a clean compile or an unrelated diagnostic is `not_reproduced`
  (evidence collected, no match); an issue with no explicit AL#### signature is always
  `inconclusive` - compile success/failure alone can never establish or rule out reproduction
  without something concrete to compare against.
- The same discipline applies to Tier 2: `Resolve-TestExecutionStatus` never reports `reproduced`
  for a passing test, and a successful container start/compile/publish with **no** deterministic
  `[Test]` procedure present in the fixture is reported as `inconclusive`, never `reproduced`.

## Dependency-free Tier 1 fixtures

`New-MinimalAlProject` omits the `application` manifest dependency by default. Validated by
running the pinned package against real fixtures: an `app.json` with no `application` key still
requires the platform's own **System** symbol package to compile (even a bare `Message()` call
needs it), but omitting `application` avoids *also* requiring the much larger
Application/Base Application package. Tier 1 intentionally runs with an **empty** package cache
(no real symbols restored), so:

- A fixture whose only compiler errors are AL1021/AL1022 (missing package cache/System/Application
  symbols) is classified `requiresContainer = true`, `reproduction = inconclusive` - it needs
  Tier 2, and is never misreported as "reproduced" merely because it failed to compile.
- A genuine AL language/syntax diagnostic (e.g. `AL0104` for a missing semicolon) still surfaces
  alongside the environmental AL1022 diagnostic - confirmed by actually compiling such a fixture -
  so Tier 1 remains useful for real compiler/parser bugs without needing any symbols at all.

Call `New-MinimalAlProject -IncludeApplicationDependency` only for a deliberately curated fixture
that needs it; ordinary reporter-supplied fixtures should never set this switch.

## ALTools package versions: pinned, and never the marketplace version

`AlToolsVersions.json` pins exact `stable`/`preview` NuGet package versions rather than floating to
"latest", so reproduction results stay repeatable run-to-run. Bump these fields in a reviewed PR
when a new ALTools package ships.

The standard issue template's "AL Extension Version" field (e.g. `13.2`) is the **VS Code
marketplace extension version**, not an ALTools/altool NuGet package version, and the two numbering
schemes are unrelated - `Get-ReportedAlToolsPackageVersion` never uses that field. It only extracts
a candidate version when the reporter explicitly frames it as an ALTools/AL CLI/NuGet package
version (e.g. "Development.Tools version: 17.0.34.45391"), and `Test-NuGetPackageVersionExist`
confirms that exact version is actually published on NuGet.org before Tier 1 ever attempts to
install/test it - a made-up or mistyped version is never silently substituted with something else.

## Tier 2 verification status

Tier 2 (`Tier2ContainerReproduction.psm1`) requires a Windows container runtime (Docker), which is
**not available in this development environment**. Its pure, deterministic logic - test selection
(`Find-DeterministicTestSelector`) and result symptom-matching (`Resolve-TestExecutionStatus`) - is
fully unit tested. `Invoke-Tier2ContainerReproduction` itself was exercised end-to-end for real
(BcContainerHelper 6.1.6 is installed in this environment) against a fixture with no available
Docker runtime: the container-start step failed inside the job as expected, and the terminating-
error handling correctly surfaced `Status = 'inconclusive'` rather than any claim of reproduction
(see the "real execution" test in `tests/Tier2ContainerReproduction.Tests.ps1`). The actual
container start/compile/publish/test-run sequence against a live Windows container has not been
exercised and should be smoke-tested via `workflow_dispatch` with `allow_container_reproduction:
true` on a curated, safe issue once this PR is on `windows-latest` runners with container support.

## Testing

`tests/` contains Pester unit tests for every decision module (`ScopePrefilter`,
`FixtureExtractor`, `SafetyGuard`, `DiagnosticMatcher`, `OrchestratorLogic`), plus:

- `EvalCorpus.Tests.ps1` - replays a labeled corpus (`tests/fixtures/eval-corpus.json`) covering
  in-scope, runtime, application, question, suggestion, duplicate, missing-repro, UI-only,
  unsafe-code, and prompt-injection issues.
- `Tier1Reproduction.Tests.ps1` - **real, non-mocked** execution: actually installs the pinned
  ALTools NuGet package and runs `al compile` against generated fixtures (requires network access
  to nuget.org; each test takes tens of seconds).
- `Tier2ContainerReproduction.Tests.ps1` - unit tests for the pure logic, plus one real execution
  test of the terminating-error path (see above).
- `SecurityGuard.Tests.ps1` - static enforcement of the hard security boundary (no GHE/ADO/private
  feed references anywhere in this automation's source).

Run from the repo root:

```powershell
Invoke-Pester -Path .github/scripts/triage/tests
```

`Invoke-IssueTriage.ps1` itself talks to the live GitHub REST API and is not covered by these
offline unit tests; its correctness is verified indirectly by testing every decision function it
calls (via `OrchestratorLogic.psm1`), and via `-DryRun` (skips posting the comment/labels, prints
the computed report instead).

## CI validation (`validate` job)

Every pull request that touches `.github/scripts/triage/**` or the workflow file itself runs a
`validate` job: PowerShell parser check, PSScriptAnalyzer (zero findings required), the security
guard grep, and the full Pester suite. This job has **no** `issues` permission and never calls the
GitHub issues API - it cannot comment or label anything. Third-party actions (`actions/checkout`,
`actions/setup-dotnet`) are pinned to an immutable commit SHA with a version comment, not a
mutable tag.
