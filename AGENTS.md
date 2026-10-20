<!-- BEGIN builda (auto-managed) -->
## BuildaGame 发布工具（项目级）

本项目已安装项目级 BuildaGame 工具链（发布 Godot Web / HTML5 / Unity WebGL 游戏到 Builda）。CLI 与基础说明书同版；SDK 随项目独立锁定版本：

1. 完整说明书（先读）：项目根的 `.builda-agent/SKILL.md`
SDK 任务必须读取 .builda-agent/sdk-guidance/<sdk-version>/SKILL.md；缺依赖按基础 Skill 恢复，升级后重新读取。
2. 每次任务开始先跑：`./.builda-agent/builda check`（自动对齐工具链版本，并提示 SDK 是否需要同步）

若上述文件缺失（例如刚 clone 本仓库），在项目根目录重装：

```bash
curl -fsSL https://ai.builda.game/agent/install.sh | bash
```

Windows（下载为文件，禁止 `iwr | iex`）：

```powershell
$p = Join-Path $env:TEMP "builda-install.ps1"; iwr https://ai.builda.game/agent/install.ps1 -UseBasicParsing -OutFile $p; & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $p; Remove-Item -Force $p -ErrorAction SilentlyContinue
```
<!-- END builda -->

- Both the web route and Builda entry render ChatApp directly, without an authentication provider, to keep local access independent of accounts.
- Personal data uses the local-data adapter: IndexedDB on the web and the official privateKV provider in Builda, so the game does not rely on blocked browser storage or remote database login; attachments remain data URLs.
- Builda saved tables use stable orion_local_<table>_v1 keys, validate SDK results, and reject oversized writes without truncation to respect the platform save contract.
- AI transport remains separate from persistence: the web keeps its existing AI endpoints and Builda keeps its bundled local model.
- Public editorial guides use SSR leaf routes with self-referencing metadata and source links; web-only navigation is passed into ChatApp through its optional header action so the standalone Builda entry remains independent of the router.
