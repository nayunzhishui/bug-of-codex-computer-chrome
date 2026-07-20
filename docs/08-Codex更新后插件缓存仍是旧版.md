# 08-Codex 更新后插件缓存仍是旧版

## 适用现象

```text
Codex/MSIX 已更新
Chrome / Computer Use 显示 installed, enabled
新任务仍无法控制浏览器
日志出现 Browser security unavailable outside node repl
或普通 node_repl MCP 在重启后消失
或工具在同一任务内先可调用、随后变成 not a function
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

本次继续定位到另一种会产生相同表象的版本错配：修复脚本曾优先把 npm 安装目录中的 `codex.exe` 与 `codex-code-mode-host.exe` 复制到 Desktop bin。即使两边都显示同一个 CLI 版本，二进制 SHA-256 仍不同。结果是插件技能和执行工具一度可见，但 Desktop 专用的可信安全桥没有正确注入。

最后还确认了更深一层：WindowsApps bundled resources 带 EFS 属性，Node 普通复制可能返回 `UNKNOWN errno=-4094`。Desktop 查找的是由当前文件内容计算出的哈希目录，不是 UI 展示版本或 manifest tag 目录；目标目录未预热时会继续出现 `missingHelperPath`、`missingTransportModulePath` 和 Sky runtime unavailable。

## 排查顺序

1. 用 `Get-AppxPackage OpenAI.Codex` 找到当前 MSIX。
2. 读取 MSIX 内 `app\resources\plugins\openai-bundled` 的插件版本。
3. 读取 `%USERPROFILE%\.codex\.tmp\bundled-marketplaces\openai-bundled` 的版本。
4. 读取 `%USERPROFILE%\.codex\plugins\cache\openai-bundled` 的版本。
5. 检查 Native Host manifest 当前指向哪个版本。
6. 执行 `codex mcp get node_repl`，确认是否还存在旧的外部 workaround。
7. 比较当前 MSIX `app\resources` 与 `%LOCALAPPDATA%\OpenAI\Codex\bin` 中 `codex.exe`、`codex-code-mode-host.exe` 的 SHA-256。
8. 最后查对应任务日志，而不是只看 UI 提示。
9. 搜索 `bundled_executable_relocation_failed|errno=-4094|missingHelperPath|missingTransportModulePath`。
10. 检查当前 MSIX 对应的内容哈希 Codex/CUA 目录和解密 bundled mirror 是否存在。

仓库的诊断脚本会输出上述版本：

```powershell
.\scripts\check-codex-runtime.ps1
```

## 修复顺序

1. 完全退出 Codex/ChatGPT，并关闭所有 Chrome / Edge 窗口。脚本会停止没有窗口的启动增强/后台应用进程，防止其继续拉起旧 Native Host。
2. 停止已核实属于 Codex Chrome 插件的旧 `extension-host.exe` 进程树。
3. 停止已核实属于 VS Code OpenAI 扩展、且仍在运行 `app-server` 的遗留 `codex.exe`；不关闭 VS Code 本身。
4. 从当前 MSIX 刷新活动 `openai-bundled` marketplace。
5. 从当前 MSIX（不是 npm CLI）同步 Desktop 的 `codex.exe`、`codex-code-mode-host.exe` 和 helper，并校验 SHA-256。
6. 删除旧的外部 `node_repl` MCP workaround。
7. 重新安装当前版本的 Chrome / Computer Use bundled 插件。
8. 把 Native Host manifest 和 Chrome/Edge 注册表指向新版本插件缓存。
9. 备份 `%LOCALAPPDATA%\OpenAI\Codex\chrome-native-hosts-v2.json`，让新进程重建活跃 app-server 条目。
10. 同步当前 CUA runtime 和 notifier。
11. 重新打开 Codex，新建任务验证。

若命中 EFS/内容哈希错误，优先使用更窄的修复：

```powershell
.\scripts\prewarm-codex-windowsapps-runtime.ps1 -InspectOnly
.\scripts\prewarm-codex-windowsapps-runtime.ps1
.\scripts\prewarm-codex-windowsapps-runtime.ps1 -InspectOnly
```

该脚本只接受与当前 MSIX SHA-256 相同的本地源，并调用 `repair-codex-bundled-marketplace-efs.ps1` 建立当前版本解密镜像。Codex 每次更新后都应重新运行 `-InspectOnly`，不能复用上一版本目录。

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
Desktop core alignment 全部为 MATCH
Native Host path 指向该版本缓存
Chrome app-server registry 有字段完整、PID 存活、协议为 v2 的条目
codex mcp get node_repl 返回未配置外部 server
新任务实际获得官方 node_repl js 工具
Chrome 能打开明确的 https://example.com
Computer Use 需要授权时能显示正常审批界面
Computer Use 官方客户端实际执行 sky.list_apps() 并返回应用
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
