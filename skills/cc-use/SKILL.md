---
name: cc-use
description: >
  把较长的编码、排查、测试或交互式 CLI 工作交给 tmux 中的内层命令行编码 Agent，
  由当前外层 Agent 负责拆解任务、读取稳定屏幕快照、纠正方向、执行最终验收，并在本次
  任务结束后销毁内层 session。适用于用户明确要求使用 cc-use、希望把长时间实现工作
  交给内层 Agent，或需要在真实 Codex CLI 或 Claude Code TUI 中完成受监督工作。
---

# cc-use

把当前 Agent 作为外层监督者，把 tmux 中的 Codex CLI 或 Claude Code 作为内层执行者。

`scripts/cc-use` 只负责创建 session、发送输入、观察屏幕和清理资源。它不理解任务内容，也不判断屏幕表示完成、失败或阻塞。所有语义判断都由外层 Agent 完成。

## 核心分工

- 外层 Agent：保留用户目标、拆解任务、检查风险、阅读快照、纠正方向并完成最终验收。
- 内层 Agent：调查问题、修改代码、运行命令和执行交互式工作。
- cc-use helper：管理 tmux、可靠发送文本、在屏幕稳定时保存快照。

不要把整个长期任务一次性塞给内层 Agent。每次只发送一个边界清楚的调查、实现、测试或验证请求，然后根据真实结果决定下一步。

## 生命周期

一次 cc-use 任务使用一个独立 session。session 可以连续运行很久，也可以跨越多次外层交互；不要因为运行时间长而主动关闭。只有本次任务已经成功、失败、取消或确认无法继续时，才执行 `finish`。

标准流程：

1. 用 `start` 创建 session 并启动同一 Agent 家族的内层 TUI。
2. 读取启动阶段返回的 `screen_path`，确认 TUI 已经可以正常接收任务。
3. 用 `send` 发送一个短而具体的请求。
4. 读取工作阶段快照，决定继续等待、发送修正请求、询问用户或开始验收。
5. 从外层环境检查真实文件、测试结果和用户要求。
6. 无论最终成功、失败、取消还是阻塞，都用 `finish` 销毁本次 session。

## 启动内层 Agent

从目标项目根目录运行：

```bash
<skill_dir>/scripts/cc-use start --project "$PWD" --agent codex
```

在 Claude Code 外层会话中使用：

```bash
<skill_dir>/scripts/cc-use start --project "$PWD" --agent claude
```

始终让内外层使用同一 Agent 家族，不要从 Codex 外层启动 Claude Code，也不要从 Claude Code 外层启动 Codex。

`start` 会生成唯一 session 名称。保存返回 JSON 中的 `session`，后续命令都显式传入它。

只有用户明确要求特定 Codex profile 时，才在启动阶段添加：

```bash
<skill_dir>/scripts/cc-use start \
  --project "$PWD" \
  --agent codex \
  --profile PROFILE_NAME
```

### 启动检查

`start` 只启动 TUI，不发送任务，也不会额外盲按 Enter。返回 `screen_stable` 后，必须读取 `screen_path` 并进行语义检查。

如果画面显示以下情况，停止发送任务：

- 登录、认证或账号选择；
- Agent、CLI、Skill 或其他工具的更新提示；
- 权限、信任或确认问题；
- shell 错误、命令不存在或进程退出；
- 无法确认 TUI 是否已经可用。

遇到登录或更新问题时，不要替用户选择选项，不要自动升级。保存必要证据，执行 `finish`，然后报告阻塞。

## 发送任务

确认启动画面正常后发送一个请求：

```bash
<skill_dir>/scripts/cc-use send "TASK_TEXT" \
  --project "$PWD" \
  --session SESSION_NAME
```

把 `TASK_TEXT` 原样传给 helper。任务拆解在外层完成，不要让 helper 添加角色说明、策略文字或包装提示。

`send` 会使用经过验证的 tmux buffer 和 Enter 提交流程发送文本，然后等待屏幕连续稳定一段时间并返回快照。

## 等待和观察

如果快照显示测试、构建、下载、服务或其他命令可能仍在安静运行，由外层 Agent 根据语义决定等待多久。等待后调用：

```bash
<skill_dir>/scripts/cc-use monitor \
  --project "$PWD" \
  --session SESSION_NAME
```

helper 不提供语义上的“下次检查建议”。外层 Agent 自己选择等待时长。

`status` 中的 `seconds_until_stable` 只是当前观察窗口距离“屏幕连续稳定”还差多少秒，不代表任务进度，也不代表建议多久后再次查看：

```bash
<skill_dir>/scripts/cc-use status \
  --project "$PWD" \
  --session SESSION_NAME \
  --json
```

## 补充屏幕上下文

稳定快照不够时，临时读取 tmux scrollback：

```bash
<skill_dir>/scripts/cc-use scrollback \
  --session SESSION_NAME \
  --lines 2000
```

需要分段查看更早内容时：

```bash
<skill_dir>/scripts/cc-use scrollback \
  --session SESSION_NAME \
  --start -4000 \
  --end -2001
```

负数表示 tmux 历史行，`0` 表示当前可见区域第一行，`-` 表示当前 pane 末尾。

只在快照上下文不足时使用 scrollback。不要把它当作持续日志流，也不要在屏幕仍快速变化时反复读取。

## 理解 observation

典型事件：

```json
{
  "event": "screen_stable",
  "phase": "work",
  "session": "ccu-codex-project-20260804120000-12345",
  "observed_at": 1785816000,
  "silence_seconds": 30,
  "screen_digest": "sha256...",
  "screen_path": "/project/.cc-use/state/.../screens/...txt"
}
```

`screen_stable` 只表示当前屏幕在静默窗口内没有变化，适合外层 Agent 阅读。它不表示：

- 任务已经完成；
- 任务已经失败；
- Agent 正在等待；
- 命令仍在运行；
- 当前需要用户输入。

外层 Agent 必须读取 `screen_path` 后自行判断。

`session_unavailable` 表示 tmux 中已经没有目标 session。检查必要证据后，决定报告失败或重新开始本次任务。

## 外层决策

读取快照后：

- 显示最终回答或已回到输入提示符：从外层运行验收检查。
- 显示仍在运行的命令：等待合适时间，再调用 `monitor`。
- 显示错误：发送一个短的修正请求，或报告阻塞。
- 显示需要普通交互输入：只有在意图明确且授权充分时才发送响应。
- 显示登录、认证或更新提示：停止，不选择选项，清理 session 并报告。
- 内容被截断或不足以理解：使用一次 `scrollback` 获取足够上下文。

内层 Agent 的文字汇报不能作为成功证明。最终验收必须在外层执行，包括检查真实文件、运行相关测试、验证命令行为或检查 UI。

## 结束任务

任务结束时执行：

```bash
<skill_dir>/scripts/cc-use finish \
  --project "$PWD" \
  --session SESSION_NAME
```

以下所有终止路径都必须调用 `finish`：

- 实现和验收成功；
- 验收失败；
- 用户取消或更换任务；
- 内层 Agent 无法继续；
- 登录、更新或启动问题阻塞；
- 外层决定放弃当前执行。

不要设置基于运行时间的自动清理规则。一个合法任务可能持续数小时或跨天；只根据任务生命周期结束 session。

## 环境与启动命令

cc-use 先让 tmux 启动正常登录 shell，再通过 shell 输入：

```text
command codex ...
command claude ...
```

登录 shell 按用户自己的正常规则加载 PATH、凭证和其他环境设置。cc-use 不扫描、不拼装、不注入环境变量，也不依次 source 各种 shell 配置文件。

`command` 会绕过 shell alias 和 function，但仍然使用登录 shell 最终得到的 PATH。如果用户刚修改了正常 shell 启动文件，新建 session 会重新读取；已经运行的旧 session 不会自动刷新环境。

## 诊断命令

立即抓取当前 pane：

```bash
<skill_dir>/scripts/cc-use snapshot SESSION_NAME
```

列出 cc-use 命名的 session：

```bash
<skill_dir>/scripts/cc-use list
```

这些命令用于诊断。正常任务仍应通过 `start`、`send`、`monitor` 和 `finish` 管理。

## TUI 录制

只有用户明确要求录制终端演示或生成 GIF 时，才读取 `references/tui-recording.md`。
