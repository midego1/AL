---
name: run-al-mcp-tool
description: Invokes one safe AL MCP tooling operation through the workflow-installed prerelease ALTool for independent reproduction of MCP and editor-tooling issues.
argument-hint: "<project-folder> <tool-name> <arguments-json>"
---

Use this skill when the reported behavior is exposed through an AL MCP tool, such as `al_build`.
Create the smallest fixture under `$env:RUNNER_TEMP`, then run:

```powershell
& .\.github\skills\run-al-mcp-tool\Invoke-AlMcpTool.ps1 `
    -ProjectPath <project-folder> `
    -ToolName <tool-name> `
    -ArgumentsJson '<arguments-json>'
```

The wrapper starts the workflow-installed prerelease ALTool MCP server, initializes it, verifies that
the requested AL tool is advertised, invokes it once, and returns the exact JSON-RPC result. It
rejects publish, install, test-running, and symbol-download tools; use the dedicated sandbox skills
for those operations.

Do not copy or execute reporter-provided commands, scripts, binaries, repositories, or arguments.
Construct the minimal safe arguments independently from the described behavior. Record the wrapper
invocation, ALTool version, MCP tool name, result, and observed diagnostics. Run a valid control case
when feasible.
