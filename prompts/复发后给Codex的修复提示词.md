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
codex mcp add node_repl -- "$env:LOCALAPPDATA\OpenAI\Codex\bin\node_repl.exe"
```

5. 说明当前 turn 可能不会热加载，需要新 turn、新线程或重启 Codex 后复测。

确认后再执行实际修复。
```
