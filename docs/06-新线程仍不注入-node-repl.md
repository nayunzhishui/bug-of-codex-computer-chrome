# 06-新线程仍不注入 node_repl

## 适用现象

```text
已经新建线程
Browser / Chrome / Computer Use 插件显示 installed, enabled
Chrome Native Host v2 manifest 存在
Chrome 扩展侧不再提示 manifest missing
但 @chrome 仍回复：无法连接 Chrome 控制组件
```

这类问题比“旧线程不热加载”更深一层：不是旧 turn 没刷新，而是新线程启动时仍由旧桌面运行时创建，或 `config.toml` 在重启后被旧进程快照覆盖，导致 `node_repl` 没有进入该线程工具表。

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

另一个已复现链路是：

```text
Codex Desktop 已重启，cli_version 也已更新
但浏览器留下了数日前启动的 extension-host.exe
该宿主继续持有旧 codex app-server 子进程和旧 .tmp 插件路径
config.toml 随后被旧快照重写，显式 node_repl MCP 消失
新任务调用 tools.mcp__node_repl__js 时得到 TypeError: ... is not a function
```

应用重启不等于浏览器 Native Messaging Host 重启。Chrome 或 Edge 仍在运行时，旧 `extension-host.exe` 可以跨越多次 Codex 重启继续存活。

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

还要继续检查当前 MSIX 的 `cua_node\manifest.json`。即使 CLI 已更新，顶层 `node_repl.exe` 仍可能是旧文件，而 `NODE_REPL_NODE_MODULE_DIRS` 指向另一套旧 runtime。这会形成“工具已出现但授权桥仍失败”的下一层问题。

---

## 修复方向

### 0. 先排除旧 Native Host 和配置回写

先完全退出 Codex/ChatGPT。随后检查 Native Host 的启动时间、父进程和路径：

```powershell
Get-CimInstance Win32_Process |
  Where-Object { $_.Name -in @('extension-host.exe', 'codex.exe') } |
  Select-Object ProcessId, ParentProcessId, CreationDate, ExecutablePath, CommandLine
```

如果 `extension-host.exe` 明显早于本次应用启动，或路径仍指向 `.codex\.tmp\bundled-marketplaces`，先停止已核实的旧宿主进程链，再写入 MCP 配置。不要先写配置再退出旧进程，否则旧进程仍可能把 `config.toml` 覆盖回去。

仓库脚本的 `-Apply` 流程会在确认 ChatGPT 已退出后：

1. 把 Native Host 清单切到当前插件缓存的稳定路径；
2. 停止已核实属于 Codex Chrome 插件的旧宿主及其子进程；
3. 同步当前 MSIX 的 CLI、`node_repl` 和 CUA runtime；
4. 最后写入 `node_repl` MCP 和当前版本的 Computer Use notifier。

### 1. 恢复显式 node_repl MCP

```powershell
$codexCli = "$env:LOCALAPPDATA\OpenAI\Codex\bin\codex.exe"
$nodeRepl = "$env:LOCALAPPDATA\OpenAI\Codex\bin\node_repl.exe"
$mods = "$env:LOCALAPPDATA\OpenAI\Codex\runtimes\cua_node\<当前manifest版本>\bin\node_modules"

codex mcp remove node_repl
codex mcp add node_repl `
  --env CODEX_CLI_PATH=$codexCli `
  --env CODEX_HOME="$env:USERPROFILE\.codex" `
  --env NODE_REPL_NODE_MODULE_DIRS=$mods `
  -- $nodeRepl

codex mcp get node_repl
```

`<当前manifest版本>` 必须从当前 `OpenAI.Codex` MSIX 的 `app\resources\cua_node\manifest.json` 读取，不要复用旧值。

注意：显式 MCP 只证明工具入口可以被发现。如果后续出现 `elicitations are unavailable`，转到 `07-授权已开启但-Computer-Use-仍失败.md`，不要把它误判为设置页没有允许。

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

推荐先 dry-run，再使用仓库脚本同步 CLI 和匹配的 CUA 运行时：

```powershell
.\scripts\repair-codex-runtime-skew.ps1
.\scripts\repair-codex-runtime-skew.ps1 -Apply
```

WindowsApps 源文件带特殊属性时，普通复制可能出现错误 6000。脚本只复制数据和时间戳，不继承加密属性。

---

## 复验

重启 Codex 并启动 Google Chrome 后，新建任务运行：

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

必须使用全新任务。旧任务的工具表不会在重试按钮或新 turn 中热注入。

如果 `mcp: node_repl/js started` 已出现，但报错变成：

```text
Browser is not available: extension
```

说明工具注入已经恢复，下一层是 Chrome 后端未注册。若继续使用 `@chrome`，必须检查 Google Chrome 是否实际运行；只运行 Edge 不会注册 Chrome 插件所需的 `extension` 后端。若用户接受 Edge，则改走 Computer Use 或内置 Browser，不要让 `@chrome` 假装已经控制 Edge。

如果 `node_repl/js` 已启动，但 Computer Use 仍报授权弹窗不可用，说明工具注入已修复、授权桥尚未修复，应继续检查 `node_repl` 与 CUA runtime 是否同版本。

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
