---
name: download-al-symbols
description: Downloads exact Business Central symbol packages for a temporary AL reproduction project through the installed prerelease ALTool. Use before compiling any project whose app.json references platform, application, or dependency packages.
argument-hint: "<project-folder>"
---

Run the deterministic wrapper:

```powershell
& .\.github\skills\download-al-symbols\Invoke-DownloadAlSymbols.ps1 `
    -ProjectPath <project-folder>
```

The wrapper uses only the prerelease ALTool installed by the workflow at `ALTOOL_PATH`. It invokes
ALTool's symbol-download capability non-interactively with the sandbox connection, tenant, and
credentials provided by the workflow, writes packages to `<project>\.alpackages`, and fails unless
at least one package is present.

Do not invoke `alc.exe`, launch or script an MCP server yourself, or call `/dev/packages` directly.
After the wrapper succeeds, compile through ALTool and pass the populated `.alpackages` path.
