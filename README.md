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

复盘后确认，这不是一个单点故障，而是可能连续出现的五层故障链：

```text
1. openai-bundled / Chrome Native Host 没有加载或注册
2. 当前线程没有注入 mcp__node_repl__js
3. Desktop 本地 codex.exe 低于已安装 CLI，旧进程继续创建新线程
4. node_repl.exe 与 cua_node/node_modules 不属于同一运行时版本
5. Computer Use 需要逐应用授权，但 createElicitation/nativePipe 授权桥没有注入
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

后续又发现：只把 `node_repl` 注册成普通 stdio MCP，虽然能恢复工具入口，却不保证恢复受信任桌面桥。典型错误是：

```text
Computer Use requires app approval but elicitations are unavailable
```

它表示设置页权限可能已经开启，但当前任务无法弹出或传递逐应用授权；不能通过自动接受审批来绕过。

Chrome 显示 `Connected`、能够读取标签页，但导航被安全层拦截，是另一类问题。先用用户明确给出的完整 URL 复测，不要把安全策略误判为扩展断连，也不要修改代码绕过浏览器安全层。

最终成功标志应分开验证：

```text
新线程 session_meta.cli_version 与本地 CLI 一致
mcp__node_repl__js 实际启动
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
│   └── 07-授权已开启但-Computer-Use-仍失败.md
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
7. 路径确认后先 dry-run，再执行实际修复。

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
