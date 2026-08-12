# Public AL triage scope

This file operationalizes the repository's `CONTRIBUTING.md`. Use component ownership and the
documented intake channel to determine scope. An issue is not in scope merely because it contains AL
code, occurs in Visual Studio Code, or can be reproduced against Business Central.

## In scope

Reproducible bugs in the latest AL Language extension from the Visual Studio Code Marketplace or AL
Developer Preview, the AL compiler, or accompanying developer tools are in scope, including:

- AL language syntax, parsing, binding, type checking, diagnostics, compilation, metadata, and code
  generation;
- the AL Visual Studio Code extension and language-server features such as IntelliSense, navigation,
  formatting, refactoring, code actions, analyzers, project loading, and workspace behavior;
- AL debugging, including breakpoint handling, stepping, variable inspection, attach/launch behavior,
  and debugger protocol integration;
- AL test tooling, including test discovery, execution, filtering, result reporting, and test-runner
  integration;
- developer build and deployment tooling such as ALTool, package creation, symbol download,
  publish/install commands, authentication performed by those tools, and developer-facing error
  reporting;
- defects in repository-owned behavior or documentation for the preceding developer-tooling
  features.

An interaction with the Business Central server remains in scope when the defect belongs to the
developer tool or protocol used to compile, publish, debug, or run tests.

## Out of scope

The following reports are out of scope even when they mention AL:

- incorrect business logic, calculations, workflows, posting behavior, reports, permissions, or data
  behavior in the Base Application, System Application, or another first-party application;
- requests to add events, hooks, fields, pages, APIs, extension points, or other extensibility to a
  first-party application;
- functional gaps or defects in standard Business Central features and business processes;
- implementation, design, or support questions for a specific customer or partner extension;
- server/runtime defects unrelated to the AL developer experience, even when AL code exposes the
  behavior;
- documentation for application functionality rather than AL developer tooling;
- questions, implementation help, and general support requests;
- feature requests and suggestions, including requests for new AL language, Visual Studio Code, or
  static-analysis capabilities;
- issues in mainstream-support versions of the compiler, developer tools, application, platform, or
  another Business Central component rather than the latest public AL tooling;
- Dynamics NAV 2018 or older tooling issues;
- security vulnerabilities or reports containing sensitive security details.

## Required routing

Follow the destinations defined by `CONTRIBUTING.md`:

| Report | Destination |
|---|---|
| First-party application extensibility | `microsoft/ALAppExtensions` |
| Feature request or suggestion | Business Central Ideas (`https://aka.ms/bcideas`) |
| Question or implementation help | The community resources linked from `CONTRIBUTING.md` |
| Supported-version application, platform, compiler, or developer-tool issue | The Business Central support channel linked from `CONTRIBUTING.md` |
| Dynamics NAV 2018 or older | The support channel |
| Security vulnerability | Follow `SECURITY.md`; do not request public disclosure |

Do not investigate or propose an application change after identifying one of these routes.

## Boundary examples

| Report | Scope |
|---|---|
| The compiler accepts invalid AL or emits an incorrect diagnostic | In scope |
| IntelliSense, navigation, formatting, or a code action behaves incorrectly | In scope |
| A breakpoint cannot bind or the debugger shows an incorrect variable value | In scope |
| The AL test runner fails to discover, execute, filter, or report tests correctly | In scope |
| ALTool cannot download symbols or publish a valid package because of tool behavior | In scope |
| A standard posting routine calculates the wrong amount | Out of scope |
| A first-party page or table needs a new integration event or field | Out of scope |
| A test fails because the application under test contains incorrect business logic | Out of scope |
| A customer extension uses an API incorrectly or needs implementation guidance | Out of scope |
| A new AL language feature or analyzer rule is requested | Out of scope; route to Business Central Ideas |
| A vulnerability in the AL extension is reported | Out of normal triage; follow `SECURITY.md` |

For mixed or unclear reports, identify the component that would need to change. If the available
evidence cannot distinguish developer tooling from application/server ownership, use
`needs human decision`; do not default to in scope.
