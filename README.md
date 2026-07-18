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

本次真正根因不是 Chrome 扩展、Zotero、账号、Plus 权限，也不是单个网站被封，而是：

```text
Windows 版 Codex / Microsoft Store / MSIX 包中的本地运行时文件迁移失败。
```

进一步导致多个 helper 缺失或路径错误：

```text
node_repl.exe
cua_node
codex.exe
rg.exe
codex-windows-sandbox-setup.exe
codex-command-runner.exe
```

进一步表现为：

```text
mcp__node_repl__js 缺失
nodeRepl.config 权限桥失败
Browser / Chrome / Computer Use 工具无法注入当前线程
网站访问被误判为策略阻止
```

最终成功标志：

```text
Chrome 成功打开 openai.com
页面标题读取正常：OpenAI | Research & Deployment
Browser / Chrome / Computer Use 工具链恢复
```

---

## 3. 本次案例环境

以下是本机案例路径和版本，只作为证据。复发后必须读取最新日志，不要直接照抄旧 hash。

> 隐私处理：本仓库为 public，已将真实 Windows 用户目录脱敏为 `%USERPROFILE%` 或 `<Windows用户名>`；不上传截图、完整日志、邮箱、token、会话文件或 Chrome 用户数据。

```text
用户目录：%USERPROFILE%
Codex 包版本：26.616.9593.0
工作空间依赖版本：26.622.11653
CodexFingerprint：38dff8711e296435
RgFingerprint：ada252862d154cdd
CuaFingerprint：1b23c930bdf84ed6
```

最终有效运行时路径：

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
│   └── 06-新线程仍不注入-node-repl.md
├── prompts/
│   └── 复发后给Codex的修复提示词.md
├── scripts/
│   ├── check-codex-runtime.ps1
│   └── copy-plain-file-template.ps1
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
6. 路径确认后再执行实际修复。

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

修复后重启电脑，只打开官方 Codex，新建线程测试：

```text
@Chrome 打开 https://example.com 并告诉我页面标题
@Browser 打开 https://example.com 并告诉我页面标题
使用电脑操控打开记事本，并告诉我是否成功
```

如果成功，不要再点击“重新安装工作空间依赖项”。
