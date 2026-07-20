# 05-旧线程不注入 node_repl

## 适用现象

```text
Browser / Chrome / Computer Use 插件已安装启用
node_repl.exe、node.exe、codex.exe 均存在
Chrome Native Host v2 manifest 存在
codex doctor 没有提示运行时文件缺失
但当前线程 tool_search("node_repl js") 仍不返回 mcp__node_repl__js
```

这种情况和前面的 `node-repl-missing` 不同。  
文件已经存在，但当前线程没有拿到工具入口。

---

## 典型根因

```text
线程创建于旧 Codex CLI / 旧插件状态
线程历史模式为 legacy
线程工具表没有热加载或重新注入
```

常见证据：

```text
threads.cli_version 低于当前 codex --version
threads.history_mode=legacy
thread_dynamic_tools 为空
插件和运行时检查均正常
```

---

## 只读检查

确认插件：

```powershell
codex plugin list | Select-String -Pattern 'browser@openai-bundled|chrome@openai-bundled|computer-use@openai-bundled'
```

确认运行时文件：

```powershell
Test-Path "$env:LOCALAPPDATA\OpenAI\Codex\bin\codex.exe"
Test-Path "$env:LOCALAPPDATA\OpenAI\Codex\bin\node.exe"
Test-Path "$env:LOCALAPPDATA\OpenAI\Codex\bin\node_repl.exe"
Test-Path "$env:LOCALAPPDATA\OpenAI\Codex\chrome-native-hosts-v2.json"
```

确认线程状态：

```powershell
sqlite3 "$env:USERPROFILE\.codex\state_5.sqlite" `
  "select id, cli_version, history_mode, source, model from threads order by updated_at desc limit 10;"

sqlite3 "$env:USERPROFILE\.codex\state_5.sqlite" `
  "select count(*) from thread_dynamic_tools;"
```

确认是否存在旧的外部 MCP workaround：

```powershell
codex mcp list
```

---

## 修复步骤

先比较当前 MSIX 与活动 bundled marketplace 的插件版本：

```powershell
$package = Get-AppxPackage OpenAI.Codex | Sort-Object Version -Descending | Select-Object -First 1
$msixPlugin = Join-Path $package.InstallLocation 'app\resources\plugins\openai-bundled\plugins\chrome\.codex-plugin\plugin.json'
$activePlugin = "$env:USERPROFILE\.codex\.tmp\bundled-marketplaces\openai-bundled\plugins\chrome\.codex-plugin\plugin.json"
(Get-Content $msixPlugin -Raw | ConvertFrom-Json).version
(Get-Content $activePlugin -Raw | ConvertFrom-Json).version
```

不要添加显式 `node_repl` MCP server。最新复现证明普通 stdio MCP 会造成“工具可见但可信安全桥缺失”的假成功。

先 dry-run：

```powershell
.\scripts\repair-codex-runtime-skew.ps1
```

完全退出 Codex、Chrome 和 Edge 后执行：

```powershell
.\scripts\repair-codex-runtime-skew.ps1 -Apply
```

应看到：

```text
MSIX 内插件版本 = 活动 marketplace 版本 = 已安装缓存版本
codex mcp get node_repl 返回未配置外部 server
Native Host 指向当前版本缓存
```

---

## 重要限制

```text
当前 turn 的工具表一般不会热加载。
修复后需要新 turn、新线程或完全重启 Codex 后复测。
官方 bundled 插件负责提供可信工具；普通外部 MCP 不应作为长期修复。
```

复测方式：

```text
tool_search("node_repl js")
```

成功时应出现：

```text
mcp__node_repl__js
```

---

## 不要做

```text
不要因为旧线程没注入就删除 .codex
不要删除 Chrome 用户数据
不要反复重装 Chrome 扩展
不要把运行时已存在的问题误判为 node-repl-missing
不要在出现 elicitations unavailable 时伪造审批或自动接受
不要在 public 仓库记录完整 state DB、完整会话日志或真实用户路径
```
