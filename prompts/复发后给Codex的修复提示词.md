# 复发后给 Codex 的修复提示词

```markdown
当前任务：修复 Windows 版 Codex 中 Browser / Chrome / Computer Use 不能调用的问题。

已知此类问题的主要根因可能是：
Codex Windows Store/MSIX 包中的本地运行时文件迁移到用户目录失败，导致 node_repl、cua_node、codex.exe、rg.exe、sandbox helper、command runner 或 CODEX_CLI_PATH 缺失。

## 禁止事项

不要先修 Chrome 扩展。
不要先修 Native Host。
不要先改注册表。
不要先清空 .codex。
不要删除 Chrome 用户数据。
不要直接修改文件；先 dry-run。

## 只读诊断

请读取最新日志，搜索：

- bundled_executable_relocation_failed
- node-repl-missing
- missingHelperPath
- browser_use_setup_failed
- mcp__node_repl__js
- codex-windows-sandbox-setup.exe
- codex-command-runner.exe
- CODEX_CLI_PATH
- nodeRepl.config
- CodexFingerprint
- RgFingerprint
- CuaFingerprint
- RuntimePaths
- threads.cli_version
- threads.history_mode
- thread_dynamic_tools
- codex mcp list
- session_meta.tools
- mcp: node_repl/js started
- 无法连接 Chrome 控制组件
- 桌面内置 codex.exe 版本
- 全局 codex --version
- Computer Use requires app approval but elicitations are unavailable
- Computer Use app approval UI is unavailable outside trusted node_repl
- node_repl_archive_path
- runtime_archive_version
- 页面导航被浏览器安全层拦截

## 输出要求

先只输出：

1. 最新日志证据
2. 当前真正缺失的组件
3. 源路径
4. 目标路径
5. 是否需要文件流复制
6. 备份路径
7. dry-run 修复计划

如果 Chrome 扩展已经 Connected，不要再处理 Chrome 扩展或 Native Host。

如果 Browser / Chrome / Computer Use 插件已安装启用，node_repl.exe 也存在，但当前线程仍没有 mcp__node_repl__js：

1. 检查当前线程是否创建于旧 CLI 或 legacy history。
2. 检查 thread_dynamic_tools 是否为空。
3. 必要时备份 config.toml。
4. 添加显式 MCP server：

```powershell
$codexCli = "$env:LOCALAPPDATA\OpenAI\Codex\bin\codex.exe"
$nodeRepl = "$env:LOCALAPPDATA\OpenAI\Codex\bin\node_repl.exe"
$mods = "$env:LOCALAPPDATA\OpenAI\Codex\runtimes\cua_node\<当前manifest版本>\bin\node_modules"
codex mcp add node_repl `
  --env CODEX_CLI_PATH=$codexCli `
  --env CODEX_HOME="$env:USERPROFILE\.codex" `
  --env NODE_REPL_NODE_MODULE_DIRS=$mods `
  -- $nodeRepl
```

5. 说明当前 turn 可能不会热加载，需要新 turn、新线程或重启 Codex 后复测。

如果已经新建线程仍提示“无法连接 Chrome 控制组件”：

1. 搜索对应 session 日志中的错误文本。
2. 读取该线程 `session_meta`。
3. 如果 `cli_version` 仍是旧版、`tools = null`，或日志没有 `mcp: node_repl/js started`，判断为新线程启动时仍未注入 node_repl。
4. 对比：

```powershell
& "$env:LOCALAPPDATA\OpenAI\Codex\bin\codex.exe" --version
codex --version
codex mcp get node_repl
```

5. 若 Desktop 本地运行时低于全局 CLI，必须完全退出 ChatGPT.exe、codex.exe、codex-code-mode-host.exe 后再替换本地运行时；不要反复卸载 Chrome 插件。

如果 `mcp: node_repl/js started` 已出现，但 Computer Use 报 `elicitations are unavailable`：

1. 不要再判断为“用户没有允许”，也不要反复切换设置页权限。
2. 从 `Get-AppxPackage OpenAI.Codex` 找到当前安装包。
3. 读取 `app\resources\cua_node\manifest.json`。
4. 比较 MSIX 内与本地顶层 `node_repl.exe` 的大小和 SHA-256。
5. 检查 MCP 的 `CODEX_CLI_PATH` 与 `NODE_REPL_NODE_MODULE_DIRS` 是否属于同一版本链。
6. 先运行 `scripts/repair-codex-runtime-skew.ps1` dry-run；确认后完全退出应用并用 `-Apply` 修复。
7. 不得修改 helper 自动接受审批，不得伪造应用白名单。

如果 Chrome 已 Connected 且能读取标签页，但导航被浏览器安全层拦截：

1. 判断连接链路已经成功。
2. 用用户明确给出的完整 URL 复测，例如 `@Chrome 打开 https://example.com`。
3. 不得修改插件绕过浏览器安全层。

确认后再执行实际修复。
```
