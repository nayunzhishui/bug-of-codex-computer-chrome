# 06-新线程仍不注入 node_repl

## 适用现象

```text
已经新建线程
Browser / Chrome / Computer Use 插件显示 installed, enabled
Chrome Native Host v2 manifest 存在
Chrome 扩展侧不再提示 manifest missing
但 @chrome 仍回复：无法连接 Chrome 控制组件
```

这类问题比“旧线程不热加载”更深一层：不是旧 turn 没刷新，而是新线程启动时仍由旧桌面运行时创建，导致 `node_repl` 没有进入该线程工具表。

---

## 关键证据

在对应 session 日志中查错误文本：

```powershell
rg -n "无法连接 Chrome 控制组件|@chrome|node_repl|mcp__node_repl" `
  "$env:USERPROFILE\.codex\sessions"
```

找到最新失败线程后，检查 `session_meta`：

```text
cli_version = 0.144.0
tools = null
source = vscode
```

再检查同一日志里是否出现：

```text
mcp: node_repl/js started
```

如果没有出现，说明 Chrome skill 只读到了技能说明，但没有实际 JavaScript 控制入口。

典型失败链：

```text
@chrome 被触发
Chrome skill 尝试寻找 node_repl js
ALL_TOOLS 中没有 mcp__node_repl__js
没有 tool_search 可补充发现
最终返回“无法连接 Chrome 控制组件”
```

---

## 根因判断

优先检查两个版本：

```powershell
& "$env:LOCALAPPDATA\OpenAI\Codex\bin\codex.exe" --version
codex --version
```

如果看到类似：

```text
本地桌面内置：codex-cli 0.144.0
全局 npm CLI：codex-cli 0.144.5
```

则说明 Codex Desktop 仍在使用旧内置运行时。即使 `codex plugin list` 显示插件 enabled，新线程仍可能用旧工具注入逻辑启动。

---

## 修复方向

### 1. 恢复显式 node_repl MCP

```powershell
$codexCli = "$env:APPDATA\npm\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe"
$nodeRepl = "$env:LOCALAPPDATA\OpenAI\Codex\bin\node_repl.exe"
$mods = "$env:LOCALAPPDATA\OpenAI\Codex\runtimes\cua_node\<CuaFingerprint>\bin\node_modules"

codex mcp remove node_repl
codex mcp add node_repl `
  --env CODEX_CLI_PATH=$codexCli `
  --env CODEX_HOME="$env:USERPROFILE\.codex" `
  --env NODE_REPL_NODE_MODULE_DIRS=$mods `
  -- $nodeRepl

codex mcp get node_repl
```

`<CuaFingerprint>` 必须从本机最新 runtime 目录读取，不要复用旧值。

---

### 2. 确保 Desktop 本地运行时不是旧版

检查：

```powershell
& "$env:LOCALAPPDATA\OpenAI\Codex\bin\codex.exe" --version
codex --version
```

如果桌面内置版本低于全局 CLI，可在完全退出 Codex 后，把全局 CLI vendor bin 中的同名文件复制到：

```text
%LOCALAPPDATA%\OpenAI\Codex\bin
```

至少包括：

```text
codex.exe
codex-code-mode-host.exe
codex-command-runner.exe
codex-windows-sandbox-setup.exe
```

注意：

```text
不要在 Codex 正在运行时覆盖这些 exe。
必须完全退出 ChatGPT.exe、codex.exe、codex-code-mode-host.exe 后再复制。
```

---

## 复验

重启 Codex 后，新建线程运行：

```text
@chrome 打开 https://example.com
```

再查新 session 日志：

```powershell
rg -n "cli_version|mcp: node_repl/js started|无法连接 Chrome 控制组件" `
  "$env:USERPROFILE\.codex\sessions"
```

预期：

```text
cli_version 不再是旧版
出现 mcp: node_repl/js started
不再出现“无法连接 Chrome 控制组件”
```

---

## 不要做

```text
不要继续反复卸载 / 安装 Chrome 插件
不要删除 Chrome 用户数据
不要清空 .codex
不要只看插件 UI 的 installed/enabled
不要把 Chrome Native Host 正常的问题误判为扩展安装失败
```

---

## 公开记录时的脱敏要求

```text
不要提交完整 session jsonl
不要提交截图
不要提交真实用户名、完整用户目录、账号信息、token
只记录关键字段：cli_version、tools/null、是否出现 mcp: node_repl/js started、错误文案
```
