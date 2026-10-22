<!-- BEGIN builda (auto-managed) -->
## BuildaGame publishing tools (project-scoped)

This project has the project-scoped BuildaGame toolchain installed (publishes Godot Web / HTML5 / Unity WebGL games to Builda). The CLI and the base Skill share one version; the SDK version is pinned per project:

1. Full guide (read first): `.builda-agent/SKILL.md` at the project root
SDK tasks must read .builda-agent/sdk-guidance/<sdk-version>/SKILL.md; restore missing dependencies per the base Skill, and reread it after upgrading.
2. At the start of every task run `./.builda-agent/builda check` (aligns the toolchain version automatically and reports whether the SDK needs syncing)

If these files are missing (e.g. right after cloning this repo), reinstall from the project root:

```bash
curl -fsSL https://ai.builda.game/agent/install.sh | bash
```

Windows (download to a file; never `iwr | iex`):

```powershell
$p = Join-Path $env:TEMP "builda-install.ps1"; iwr https://ai.builda.game/agent/install.ps1 -UseBasicParsing -OutFile $p; & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $p; Remove-Item -Force $p -ErrorAction SilentlyContinue
```
<!-- END builda -->

- Both the web route and Builda entry render ChatApp directly, without an authentication provider, to keep local access independent of accounts.
- Personal data uses the local-data adapter: IndexedDB on the web and the official privateKV provider in Builda, so the game does not rely on blocked browser storage or remote database login; attachments remain data URLs.
- Builda saved tables use stable orion_local_<table>_v1 keys, validate SDK results, and reject oversized writes without truncation to respect the platform save contract.
- AI transport remains separate from persistence: the web keeps its existing AI endpoints and Builda keeps its bundled local model.
- Builda packaging must include the validated GGUF model and local Wllama compatibility WASM/worker assets; Safari cannot depend on Wllama's default CDN fallback inside the sandbox.
- Builda model selection and inference settings live in its browser-safe model configuration; its CDN asset pointer is consumed only during packaging so inference remains offline.
- Public editorial guides use SSR leaf routes with self-referencing metadata and source links; web-only navigation is passed into ChatApp through its optional header action so the standalone Builda entry remains independent of the router.
