# Support and diagnostics

This repository accepts reproducible defects in the latest AL Language extension, compiler,
static analyzers, debugger, test tooling, and other AL developer tools.

For the complete intake guidance, see [Contributing](CONTRIBUTING.md#reporting-issues).

## Choose the right channel

- Report a reproducible defect in the latest AL developer tools in this repository.
- Report supported-product runtime, application, or platform issues through
  [Business Central support](https://learn.microsoft.com/dynamics365/business-central/product-help-and-support).
- Request first-party application extensibility through the
  [BCApps issue intake](https://github.com/microsoft/BCApps/issues/new/choose).
- Submit feature requests and static-analysis rule suggestions through
  [Business Central Ideas](https://aka.ms/bcideas).
- Report security vulnerabilities according to the [security policy](SECURITY.MD).

## Report a tooling bug effectively

Before opening an issue:

1. Use the latest AL Language extension and search existing issues.
2. Disable other Visual Studio Code extensions.
3. Provide a minimal, copyable AL sample or a small repository that reproduces the problem.
4. Include the expected and actual behavior, AL Language, Visual Studio Code, Business Central,
   and operating-system versions.

Use the [Developer Experience bug template](.github/ISSUE_TEMPLATE/al-developer-experience-bug.md)
for the complete checklist.

## Understand analyzer diagnostics

| Prefix | Analyzer | Purpose |
| --- | --- | --- |
| `AA` | CodeCop | Code quality, readability, and localizability |
| `AS` | AppSourceCop | AppSource compliance and upgrade compatibility |
| `PTE` | PerTenantExtensionCop | Per-tenant extension requirements |
| `AW` | UICop | Web client UI compatibility |

Use the diagnostic ID to find the relevant [AL code analysis documentation](https://learn.microsoft.com/dynamics365/business-central/dev-itpro/developer/devenv-using-code-analysis-tool).
Configure rule severity with a [ruleset](https://learn.microsoft.com/dynamics365/business-central/dev-itpro/developer/devenv-using-code-analysis-tool-with-rule-set).
AppSourceCop and PerTenantExtensionCop must not be enabled together.

## AI-assisted AL development

The AL Language extension and the
[AL Development Tools package](https://www.nuget.org/packages/Microsoft.Dynamics.BusinessCentral.Development.Tools/)
support AI-assisted AL development:

- Visual Studio Code Language Model Tools for interactive use with GitHub Copilot.
- AL MCP Server (`altool launchmcpserver`) for MCP-compatible agents, headless automation, and
  CI/CD scenarios.
- AL LSP Server (`altool launchlspserver`) for semantic navigation such as definitions,
  references, completions, rename, and type hierarchy.

See [AI agent tools for AL development](https://learn.microsoft.com/dynamics365/business-central/dev-itpro/developer/al-agent-tools/al-agent-tools-overview)
and the [AL Development Tools package](https://learn.microsoft.com/dynamics365/business-central/dev-itpro/developer/devenv-al-tool-package).

When reporting a problem, include the Development Tools or AL Language version, agent host, command
or transport, minimal workspace, and sanitized diagnostic log. Never include authentication tokens or
customer data.

## Investigate performance

For a slow AL development environment, start with
[Optimizing Visual Studio Code for AL development](https://learn.microsoft.com/dynamics365/business-central/dev-itpro/developer/devenv-optimize-visual-studio-code).

For Business Central application performance, use the
[developer performance guidance](https://learn.microsoft.com/dynamics365/business-central/dev-itpro/performance/performance-developer),
Page Inspection, the AL Profiler, and telemetry to gather evidence before reporting a tooling defect.
