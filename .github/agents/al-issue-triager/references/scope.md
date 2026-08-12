# Public AL triage scope

Use component ownership to determine scope. An issue is not in scope merely because it contains AL
code, occurs in Visual Studio Code, or can be reproduced against Business Central.

## In scope

Issues owned by the AL developer-tooling stack are in scope, including:

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
- documentation for the preceding developer-tooling features.

An interaction with the Business Central server remains in scope when the defect belongs to the
developer tool or protocol used to compile, publish, debug, or run tests.

## Out of scope

Issues owned by application or business functionality are out of scope, including:

- incorrect business logic, calculations, workflows, posting behavior, reports, permissions, or data
  behavior in the Base Application, System Application, or another first-party application;
- requests to add events, hooks, fields, pages, APIs, extension points, or other extensibility to a
  first-party application;
- functional gaps or defects in standard Business Central features and business processes;
- implementation, design, or support questions for a specific customer or partner extension;
- server/runtime defects unrelated to the AL developer experience, even when AL code exposes the
  behavior;
- documentation for application functionality rather than AL developer tooling.

Route application and first-party extensibility issues to the repository or support channel that owns
the affected application or Business Central feature. Do not investigate or propose the application
change here.

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

For mixed or unclear reports, identify the component that would need to change. If the available
evidence cannot distinguish developer tooling from application/server ownership, use
`needs human decision`; do not default to in scope.
