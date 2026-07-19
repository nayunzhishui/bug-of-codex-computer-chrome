# 08-Codex 更新后插件缓存仍是旧版

## 适用现象

```text
Codex/MSIX 已更新
Chrome / Computer Use 显示 installed, enabled
新任务仍无法控制浏览器
日志出现 Browser security unavailable outside node repl
或普通 node_repl MCP 在重启后消失
```

## 已复现根因

Codex 包、活动 marketplace、插件缓存和 Native Host 可以处于四个不同版本。一次复现中：

```text
Codex MSIX：26.707.9981.0
MSIX 内 Chrome / Computer Use：26.707.72221
活动 openai-bundled marketplace：26.616.71553
已安装插件缓存 / Native Host：26.616.71553
```

因此 `codex plugin list` 的 `installed, enabled` 不是完整成功证据。旧插件仍可连接扩展、列出标签页，随后在导航或应用授权阶段失败。

另一个误区是显式执行：

```powershell
codex mcp add node_repl ...
```

这只能注册普通 stdio MCP。它可能让 `mcp__node_repl__js` 出现，但缺少官方可信浏览器/审批上下文，典型错误是：

```text
Browser security unavailable outside node repl
Computer Use requires app approval but elicitations are unavailable
```

## 排查顺序

1. 用 `Get-AppxPackage OpenAI.Codex` 找到当前 MSIX。
2. 读取 MSIX 内 `app\resources\plugins\openai-bundled` 的插件版本。
3. 读取 `%USERPROFILE%\.codex\.tmp\bundled-marketplaces\openai-bundled` 的版本。
4. 读取 `%USERPROFILE%\.codex\plugins\cache\openai-bundled` 的版本。
5. 检查 Native Host manifest 当前指向哪个版本。
6. 执行 `codex mcp get node_repl`，确认是否还存在旧的外部 workaround。
7. 最后查对应任务日志，而不是只看 UI 提示。

仓库的诊断脚本会输出上述版本：

```powershell
.\scripts\check-codex-runtime.ps1
```

## 修复顺序

1. 完全退出 Codex/ChatGPT，并关闭所有 Chrome / Edge 窗口。脚本会停止没有窗口的启动增强/后台应用进程，防止其继续拉起旧 Native Host。
2. 停止已核实属于 Codex Chrome 插件的旧 `extension-host.exe` 进程树。
3. 停止已核实属于 VS Code OpenAI 扩展、且仍在运行 `app-server` 的遗留 `codex.exe`；不关闭 VS Code 本身。
4. 从当前 MSIX 刷新活动 `openai-bundled` marketplace。
5. 删除旧的外部 `node_repl` MCP workaround。
6. 重新安装当前版本的 Chrome / Computer Use bundled 插件。
7. 把 Native Host manifest 和 Chrome/Edge 注册表指向新版本插件缓存。
8. 同步当前 CUA runtime 和 notifier。
9. 重新打开 Codex，新建任务验证。

先 dry-run：

```powershell
.\scripts\repair-codex-runtime-skew.ps1
```

退出 Codex并关闭浏览器窗口后执行：

```powershell
.\scripts\repair-codex-runtime-skew.ps1 -Apply
```

## 成功标准

```text
MSIX 内插件版本 = 活动 marketplace 版本 = 已安装缓存版本
Native Host path 指向该版本缓存
codex mcp get node_repl 返回未配置外部 server
新任务实际获得官方 node_repl js 工具
Chrome 能打开明确的 https://example.com
Computer Use 需要授权时能显示正常审批界面
不再出现 outside node repl / elicitations are unavailable
```

## 边界

```text
不修改浏览器安全代码
不伪造应用审批
不删除 Chrome/Edge 用户数据
不在 Codex 或浏览器仍运行时替换插件
不把普通外部 MCP 的“工具可见”当作修复成功
```
