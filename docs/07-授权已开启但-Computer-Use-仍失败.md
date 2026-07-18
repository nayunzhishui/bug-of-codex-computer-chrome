# 07-授权已开启但 Computer Use 仍失败

## 现象

设置页已经开启“任意应用”，Chrome 也显示已连接，但 Computer Use 仍返回：

```text
Computer Use requires app approval but elicitations are unavailable
```

或者界面显示：

```text
电脑插件需要应用授权，但当前授权窗口不可用
```

这不等于用户没有授权。设置页开关是持久权限层；实际控制某个应用时，任务还要获得逐应用批准，或者携带已经持久批准的应用元数据。

---

## 已确认的故障链

本案例同时存在两组版本错配：

```text
Desktop 本地 codex.exe：0.144.0
已安装 npm CLI：0.144.5

本地 node_repl.exe：2026-06-23 旧文件
当前 MSIX manifest：node_repl 20260713.2
```

为了恢复工具入口而显式注册的 `node_repl` stdio MCP 可以让 `mcp__node_repl__js` 再次出现，但旧 `node_repl`、旧 CLI 或不匹配的 `node_modules` 仍可能缺少受信任桌面桥：

```text
nodeRepl.config
nodeRepl.createElicitation
nodeRepl.nativePipe
```

Computer Use helper 收到应用审批请求后找不到 `createElicitation`，于是准确报出 `elicitations are unavailable`。

---

## 排查顺序

### 1. 先确认是否真的调用到了 Computer Use

在最新 session 日志中搜索：

```powershell
rg -n "Computer Use requires app approval|elicitations are unavailable|mcp: node_repl/js started" `
  "$env:USERPROFILE\.codex\sessions"
```

如果已有 `mcp: node_repl/js started`，说明工具入口存在，不要再回头重装 Chrome 扩展。

### 2. 检查失败任务使用的 CLI

读取对应 session 的 `session_meta.cli_version`，再比较：

```powershell
& "$env:LOCALAPPDATA\OpenAI\Codex\bin\codex.exe" --version
codex --version
```

三者必须结合判断。只看终端里的 `codex --version` 不足以证明 Desktop 已经使用新版。

### 3. 检查当前 MSIX 中的 CUA manifest

```powershell
$pkg = Get-AppxPackage -Name OpenAI.Codex |
  Sort-Object Version -Descending |
  Select-Object -First 1
$cua = Join-Path $pkg.InstallLocation 'app\resources\cua_node'
Get-Content (Join-Path $cua 'manifest.json')
```

重点读取：

```text
node_repl_archive_path
runtime_archive_version
node_repl_path
node_modules
```

不要照抄本文中的 `20260713.2`。

### 4. 比较实际 node_repl

```powershell
$bundled = Join-Path $cua 'bin\node_repl.exe'
$local = "$env:LOCALAPPDATA\OpenAI\Codex\bin\node_repl.exe"
Get-Item $bundled, $local | Select-Object FullName, Length, LastWriteTime
Get-FileHash $bundled, $local -Algorithm SHA256
```

若大小或 SHA-256 不同，说明顶层 `node_repl` 仍是旧副本。

### 5. 检查 MCP 是否指向匹配的模块目录

```powershell
codex mcp get node_repl
```

`CODEX_CLI_PATH`、`node_repl.exe`、`NODE_REPL_NODE_MODULE_DIRS` 应来自同一套已验证运行时，不要混用旧 fingerprint 与新 CLI。

---

## 解决办法

仓库脚本默认只输出计划：

```powershell
.\scripts\repair-codex-runtime-skew.ps1
```

确认路径后，完全退出 Codex/ChatGPT，再执行：

```powershell
.\scripts\repair-codex-runtime-skew.ps1 -Apply
```

脚本会：

1. 从当前 `OpenAI.Codex` MSIX manifest 动态读取 CUA 版本。
2. 用 `robocopy /COPY:DT /DCOPY:T` 复制文件内容，避免继承 WindowsApps 加密属性导致错误 6000。
3. 同步匹配的 `node_repl.exe` 与 `node_modules`。
4. 同步 Desktop CLI helper，并重新注册带完整环境变量的 `node_repl` MCP。
5. 保留覆盖前备份并要求重启后新建任务复测。

---

## Chrome Connected 但导航被拦截

如果 Chrome 已连接且能读取标签页，但提示“页面导航被浏览器安全层拦截”，这不是上述授权桥故障。使用用户明确给出的完整 URL 复测：

```text
@Chrome 打开 https://mp.weixin.qq.com/
@Chrome 打开 https://www.cnki.net/
```

不要修改插件以绕过浏览器安全层，也不要把模型推断出的站点地址当作用户明确授权的 URL。

---

## 安全边界

```text
不要自动接受 createElicitation
不要把任意应用写入伪造白名单
不要修改 Computer Use helper 跳过审批
不要删除 Chrome 用户数据或整个 .codex
不要把完整 session、截图、token、用户名提交到 public 仓库
```

修复的目标是恢复授权界面和可信运行时，而不是取消授权。
