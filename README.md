# Codex 中 Chrome 和 Computer Use 插件不能使用：全流程处理复盘

## 1. 文档用途

本文记录 Windows 版 Codex 中 **Browser / Chrome / Computer Use** 插件不可用的一次完整修复过程。目标是保留复发后有用的判断顺序、关键日志、修复边界和可复用提示词。

适用情况：

```text
Chrome 扩展已安装，但 Codex 无法调用 Chrome
Chrome 扩展显示 Connected，但网页仍打不开
Browser / Chrome / Computer Use 工具入口不可用
Computer Use 无法控制本机
所有网站被提示 Codex 策略阻止
日志出现 node-repl-missing、missingHelperPath、bundled_executable_relocation_failed
```

不适用情况：

```text
Chrome 手动也无法联网
单个网站本身禁止访问
Zotero 插件不可用
OpenAI 账号或订阅权限问题
普通项目代码问题
```

---

## 2. 最终结论

复盘后确认，这不是一个单点故障，而是可能连续出现的十层故障链：

```text
1. openai-bundled / Chrome Native Host 没有加载或注册
2. 当前线程没有注入 mcp__node_repl__js
3. Desktop 本地 codex.exe 低于已安装 CLI，旧进程继续创建新线程
4. 浏览器遗留的 extension-host/app-server 跨重启存活并覆盖 config.toml
5. node_repl.exe 与 cua_node/node_modules 不属于同一运行时版本
6. Google Chrome 实际未运行，仅 Edge 在运行，导致 extension 后端不可用
7. Computer Use 需要逐应用授权，但 createElicitation/nativePipe 授权桥没有注入
8. Codex 已更新，但 openai-bundled marketplace 和插件缓存仍停留在旧版本
9. 修复脚本把 npm CLI 的 codex.exe / code-mode-host 写入 Desktop bin，导致可信安全桥缺失
10. chrome-native-hosts-v2.json 留有死亡 PID 和旧字段，当前 Native Host 找不到兼容 app-server
```

早期故障确实来自 MSIX 本地运行时迁移失败，导致多个 helper 缺失或路径错误：

```text
node_repl.exe
cua_node
codex.exe
rg.exe
codex-windows-sandbox-setup.exe
codex-command-runner.exe
```

后续又发现：只把 `node_repl` 注册成普通 stdio MCP 会产生假成功——虽然能恢复工具入口，却不能恢复受信任浏览器/桌面桥。典型错误是：

```text
Computer Use requires app approval but elicitations are unavailable
Browser security unavailable outside node repl
```

它表示设置页权限可能已经开启，但当前任务缺少官方可信上下文。修复时应删除这个旧的外部 MCP workaround，刷新当前 MSIX 自带的 `openai-bundled` marketplace，并重新安装同版本 Chrome / Computer Use 插件；不能通过自动接受审批来绕过。

本次复发还确认了一个明确版本错配：Codex 包已经更新到 `26.707.9981.0`，包内 Chrome / Computer Use 插件为 `26.707.72221`，但活动 marketplace、插件缓存和 Native Host 仍停留在 `26.616.71553`。插件 UI 的 `installed, enabled` 不能证明插件版本与当前 Codex 一致。

进一步复测发现，即使 npm CLI 与 Desktop CLI 都显示 `0.144.5`，二者的 `codex.exe` 和 `codex-code-mode-host.exe` 仍可能具有不同 SHA-256。Desktop 若误用 npm 版核心文件，`mcp__node_repl__js` 可能先出现，但导航时因缺少 `nodeRepl.config.createElicitation` 报 `Browser security unavailable outside node repl`，之后工具入口从同一任务中消失。Desktop 核心文件必须优先来自当前 MSIX；npm 只能作为 MSIX 缺文件时的兜底。

如果浏览器侧边栏直接显示 `No compatible Codex app-server entry was found`，应检查 `%LOCALAPPDATA%\OpenAI\Codex\chrome-native-hosts-v2.json`。该文件记录的是活跃 app-server presence，不是永久配置；旧文件可能仍指向已退出的 PID，并缺少当前版本要求的 `appVersion`、`cliVersion`、`entryId`、`installId`、`proxyHost` 等字段。完全退出 Codex 和浏览器后备份该文件，再启动当前 Codex 让它重新发布，不能手工伪造 PID 或协议字段。

这类 app-server 发现失败发生在 Chrome Native Host 握手阶段，早于 shell sandbox。只有日志明确出现 sandbox helper 缺失或权限拒绝时才按沙箱故障处理；本案例中 `sandbox_mode = danger-full-access`，且 `codex-windows-sandbox-setup.exe` 与当前 MSIX 的 SHA-256 一致，因此不是沙箱 bug。

Chrome 显示 `Connected`、能够读取标签页，但导航被安全层拦截，是另一类问题。先用用户明确给出的完整 URL 复测，不要把安全策略误判为扩展断连，也不要修改代码绕过浏览器安全层。

路由边界：`@chrome` 只控制 Google Chrome；Edge 可由 Computer Use 控制，通用网页也可使用内置 Browser。用户只要求“能控制浏览器”时，可在这三条路径中选择可用的一条，但不能把 Edge 的 Native Host 进程误判成 Chrome 后端已就绪。

最终成功标志应分开验证：

```text
新线程 session_meta.cli_version 与本地 CLI 一致
mcp__node_repl__js 实际启动
Google Chrome 已运行，Native Host 使用当前插件缓存路径
Chrome app-server registry 至少有一个字段完整、PID 存活、协议为 v2 的兼容条目
Chrome 能打开用户明确提供的 https://example.com 并读取标题
Computer Use 能正常显示授权弹窗，或使用已经持久批准的应用
不再出现 elicitations are unavailable
```

---

## 3. 本次案例环境

以下是两个阶段的案例版本，只作为证据。复发后必须读取最新日志和当前 MSIX manifest，不要照抄旧 hash 或版本号。

> 隐私处理：本仓库为 public，已将真实 Windows 用户目录脱敏为 `%USERPROFILE%` 或 `<Windows用户名>`；不上传截图、完整日志、邮箱、token、会话文件或 Chrome 用户数据。

```text
用户目录：%USERPROFILE%
Codex 包版本：26.616.9593.0
工作空间依赖版本：26.622.11653
CodexFingerprint：38dff8711e296435
RgFingerprint：ada252862d154cdd
CuaFingerprint：1b23c930bdf84ed6

后续复发阶段：
Desktop 本地 CLI：0.144.0
已安装 npm CLI：0.144.5
旧 node_repl：2026-06-23 文件
当前 MSIX node_repl：20260713.2
```

早期迁移故障阶段的有效运行时路径：

```text
%LOCALAPPDATA%\OpenAI\Codex\bin\38dff8711e296435\codex.exe
%LOCALAPPDATA%\OpenAI\Codex\bin\ada252862d154cdd\rg.exe
%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node\1b23c930bdf84ed6\bin\node.exe
%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node\1b23c930bdf84ed6\bin\node_repl.exe
```

额外补齐：

```text
codex-windows-sandbox-setup.exe
codex-command-runner.exe
CODEX_CLI_PATH
nodeRepl.config 权限桥
```

---

## 4. 仓库结构

```text
.
├── README.md
├── docs/
│   ├── 01-故障顺序与判断.md
│   ├── 02-关键修复流程.md
│   ├── 03-复发快速处理.md
│   ├── 04-日志关键词表.md
│   ├── 05-旧线程不注入-node-repl.md
│   ├── 06-新线程仍不注入-node-repl.md
│   ├── 07-授权已开启但-Computer-Use-仍失败.md
│   └── 08-Codex更新后插件缓存仍是旧版.md
├── prompts/
│   └── 复发后给Codex的修复提示词.md
├── scripts/
│   ├── check-codex-runtime.ps1
│   ├── copy-plain-file-template.ps1
│   └── repair-codex-runtime-skew.ps1
└── logs-examples/
    └── README.md
```

---

## 5. 复发后优先阅读

1. 先看 `docs/03-复发快速处理.md`。
2. 再运行 `scripts/check-codex-runtime.ps1`。
3. 把 `prompts/复发后给Codex的修复提示词.md` 复制给 Codex。
4. 如果运行时都存在但旧线程仍没有 `mcp__node_repl__js`，看 `docs/05-旧线程不注入-node-repl.md`。
5. 如果新建线程仍没有 `mcp__node_repl__js`，看 `docs/06-新线程仍不注入-node-repl.md`。
6. 如果报错包含 `elicitations are unavailable`，看 `docs/07-授权已开启但-Computer-Use-仍失败.md`。
7. 如果 Codex 已更新但插件仍旧，或出现 `outside node repl`，看 `docs/08-Codex更新后插件缓存仍是旧版.md`。
8. 检查诊断报告中的 `Desktop core alignment`，任何 `MISMATCH` 都必须先修复。
9. 检查 `Chrome app-server registry`；出现 `No compatible Codex app-server entry was found` 时先修复该层。
10. 路径确认后先 dry-run，再执行实际修复。

---

## 6. 修复边界

```text
不删除 %USERPROFILE%\.codex
不删除项目文件
不删除 Chrome / Edge 用户数据
不保存完整日志或截图到 public 仓库
所有覆盖前先备份
先 dry-run，确认路径后再执行
复发后重新读取最新 RuntimePaths，不复用旧 hash
```

---

## 7. 最终验证命令

修复后完全退出并重新打开官方 Codex，新建线程测试：

```text
@Chrome 打开 https://example.com 并告诉我页面标题
@Browser 打开 https://example.com 并告诉我页面标题
使用电脑操控打开记事本，并告诉我是否成功
```

Chrome 测试必须包含用户明确给出的完整 URL，以区分连接故障和浏览器安全导航策略。Computer Use 若要求授权，应出现正常授权界面；不得通过修改 helper 自动批准。
