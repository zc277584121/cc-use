# cc-use

cc-use 是一个面向命令行编码 Agent 的监督式执行 Skill。当前外层 Agent 保留用户目标、任务拆解和最终验收，把耗时的调查、实现、测试或真实 TUI 操作交给 tmux 中的内层 Agent。

这里的 Agent 不限定厂商。外层和内层可以是 OpenAI Codex，也可以是 Claude Code。用户没有明确指定跨 Agent 组合或其他特殊要求时，默认让内外层使用同一个 Agent 家族。

```text
用户
  ↓
外层 Agent：计划、监督、纠偏、验收
  ↓
cc-use helper：tmux、输入、抓屏、清理
  ↓
内层 Agent：调查、编码、运行命令
```

cc-use 的重点是监督，不是简单并行。外层 Agent 不把整个长期任务一次性丢给内层，而是不断执行：

```text
启动并检查 TUI
      ↓
发送一个具体请求
      ↓
等待屏幕稳定
      ↓
读取快照并判断
      ├── 继续等待
      ├── 发送修正
      ├── 询问用户
      └── 外层验收
      ↓
任务结束后销毁 session
```

## 适用场景

| 场景 | cc-use 的作用 |
|---|---|
| 多阶段实现或重构 | 外层保留整体目标和验收标准，内层按顺序完成调查、编码和测试 |
| 长时间排查 | 内层运行日志分析、复现和实验，外层在稳定快照出现后判断下一步 |
| 端到端与对抗性测试 | 外层设计真实流程、边界条件和回归场景，内层在项目或 TUI 中执行 |
| 交互式产品验证 | 在真实 Codex CLI、Claude Code、Skill、插件或 MCP 工作流中连续输入和观察 |
| 输出很多或等待很久的任务 | 把构建、测试、下载和命令输出留在内层，避免占满外层上下文 |

任务不一定必须很长。用户明确要求使用 cc-use，或短任务必须在真实内层 TUI 中验证时，也可以只发送一次 prompt，完成外层验收后立即关闭 session。

简单问答、一次文件读取、单条低风险命令或外层可以直接快速完成的修改，通常没有必要启动额外 TUI。需要频繁选择账号、输入凭证或持续依赖用户即时决策的任务，也不适合无人监督地交给内层。

## 安装

使用 [npx skills](https://skills.sh) 安装。

安装到所有支持的 Agent：

```bash
npx skills add zc277584121/cc-use --all -g
```

只安装到指定 Agent：

```bash
npx skills add zc277584121/cc-use -a claude-code -g
npx skills add zc277584121/cc-use -a codex -g
```

更新全局安装：

```bash
npx skills update
```

## 使用方式

在外层 Agent 的正常对话中直接点名 Skill。

Codex 示例：

```text
$cc-use 调查这个仓库里偶发失败的测试，让内层 Agent 修复并运行测试，
最后由外层完成验收。
```

Claude Code 示例：

```text
使用 cc-use 重构数据库模块。把实现交给内层 session，
只有需要我决定或已经可以验收时再回来。
```

用户面对的是 Skill，不需要手动操作 helper 命令。后面的 CLI 主要供 Skill 和开发调试使用。

## 任务级 session

每个完整的用户任务创建一个唯一 tmux session，而不是每个 prompt 创建一个 session。长程任务可以在同一个内层 Agent 对话中连续发送多个短而明确的 prompt，保留它已经获得的项目上下文。这个 session 可以持续很久，也可以跨越多次外层交互；cc-use 不根据运行时长自动关闭它。

一次调查、实现或验收没有达到预期时，只要整体任务仍在继续，就在原 session 中发送修正 prompt，不要先关闭再重新开始。短任务也使用相同粒度，只是可能发送一次 prompt、完成外层验收后就结束。

只有在以下情况才结束 session：

- 整体任务验收成功；
- 用户取消或更换任务；
- 外层确认任务最终失败并停止继续修复；
- 内层执行或启动过程确认无法继续。

任务结束后，外层 Agent 必须调用 `finish`。session 不会被保留给未来无关任务。

## tmux socket 与命名

cc-use 使用固定的专用 tmux socket：

```text
cc-use
```

helper 内部所有 tmux 操作都等价于 `tmux -L cc-use ...`，因此不会与用户默认 tmux server 中的 session 混在一起。

自动生成的 session 名称使用：

```text
ccu-<agent>-<project>-<timestamp>-<pid>
```

每个完整任务仍然拥有独立 session；多个任务可以在同一个专用 socket 中并行。用户显式指定 session 名称时，helper 也会保留该名称，`list` 会列出专用 socket 内的全部 session。

需要直接使用 tmux 诊断或只读 attach 时，必须指定同一个 socket 和精确 target，例如：

```bash
tmux -L cc-use attach -r -t '=SESSION_NAME'
```

## 启动安全

启动和发送任务被拆成两个阶段。

第一阶段只启动内层 TUI：

```bash
skills/cc-use/scripts/cc-use start --project "$PWD" --agent codex
```

`start` 不发送任务，也不会在 TUI 启动后额外盲按 Enter。屏幕稳定后返回启动快照，由外层 Agent 判断：

- 是否已经进入正常输入界面；
- 是否出现登录或认证选择；
- 是否出现升级提示；
- 是否存在权限、信任或 shell 错误。

外层 Agent 可以处理结果明确、低风险并且不会改变环境的启动交互。例如升级提示提供“暂不升级”“跳过”或“继续使用当前版本”时，外层应选择这类选项，再检查新的屏幕快照。不要接受升级、安装或迁移，也不要替用户选择账号、登录方式或凭证。选项含义不清或可能改变环境时，保存必要证据、清理 session，然后报告阻塞。

启动菜单使用独立的按键命令，例如：

```bash
skills/cc-use/scripts/cc-use keys Escape \
  --project "$PWD" \
  --session SESSION_NAME
```

具体发送 `Escape`、方向键、数字还是 `Enter`，必须根据当前快照中明确显示的选项决定。`keys` 只发送外层指定的按键并返回新的稳定快照，不会使用任务文本的多次 Enter 提交流程。

确认启动正常后，第二阶段才发送任务：

```bash
skills/cc-use/scripts/cc-use send "Investigate the failing test." \
  --project "$PWD" \
  --session SESSION_NAME
```

## 输入机制

TUI 对回车键的处理在不同版本和终端状态下并不完全一致。cc-use 保留了已经验证过的发送流程：

1. 用 `C-u` 清理当前输入；
2. 通过 tmux buffer 粘贴完整文本；
3. 发送 `Enter`；
4. 发送 `C-m` 作为回车兼容路径；
5. 再发送一次 `Enter`。

这个流程只用于已经通过启动检查的内层 TUI。启动菜单或普通交互提示使用 `keys`，不会使用这组任务提交按键。

## 屏幕观察

cc-use 不解析某个特定 Agent 的 UI，也不使用关键词猜测任务状态。它只做确定性观察：

1. 抓取当前 tmux pane；
2. 移除 ANSI 转义和行尾空白；
3. 计算屏幕哈希；
4. 屏幕变化时重新开始静默计时；
5. 屏幕连续稳定到阈值后保存一次快照。

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

`screen_stable` 只表示现在适合查看。它不表示任务完成、失败、阻塞或仍在运行。

外层 Agent 读取 `screen_path` 后，根据真实内容决定下一步。测试、构建和下载可能长时间没有输出，外层可以自行决定等待多久，然后调用：

```bash
skills/cc-use/scripts/cc-use monitor \
  --project "$PWD" \
  --session SESSION_NAME
```

helper 不提供语义上的下次检查时间。`status` 中的 `seconds_until_stable` 只是静默观察窗口的机械倒计时。

## scrollback

当前屏幕不足以理解上下文时，可以读取 tmux 历史：

```bash
skills/cc-use/scripts/cc-use scrollback \
  --session SESSION_NAME \
  --lines 2000
```

也可以指定不重叠的范围：

```bash
skills/cc-use/scripts/cc-use scrollback \
  --session SESSION_NAME \
  --start -4000 \
  --end -2001
```

`screen_path` 保存的是 observation 产生时的当前 pane 快照，不一定包含内层 Agent 的完整回答。最终回答较长、终端高度较小，或者关键调查细节出现在更早位置时，需要使用 scrollback 向前查看。

先读取最近一段；信息仍不够时，再使用不重叠的范围继续向前翻。每次读完后，由外层 Agent 根据内容判断证据是否已经足够、是否还要继续向前以及下一次读取多大范围。不要预先规定固定页数，也不要默认一次读取全部历史。

scrollback 只用于这种渐进式上下文补充。cc-use 不默认保存完整长期 transcript，也不在屏幕快速变化时持续读取。

## 外层验收

内层 Agent 的最终回答不能作为成功证明。外层必须直接检查实际结果，例如：

- 查看代码和 diff；
- 运行相关测试、构建或静态检查；
- 执行真实命令流程；
- 检查 UI 或生成物；
- 对照用户要求确认行为。

整个用户任务验收结束后清理。一次中间验收失败但仍准备继续修复时，不要执行 `finish`：

```bash
skills/cc-use/scripts/cc-use finish \
  --project "$PWD" \
  --session SESSION_NAME
```

外层 Agent 只需要决定任务已经整体结束并调用 `finish`，不需要观察后续退出画面。`finish` 会先用独立输入流程粘贴 `/exit` 并只发送一次 `Enter`，然后等待内部 runner 记录内层 TUI 的真实 exit code。

runner 是 Codex 或 Claude Code 进程的直接父进程，通过 shell 的等待机制取得子进程退出状态。exit code 为 `0` 时，`finish` 返回 `shutdown: graceful`；非 `0` 时返回 `shutdown: abnormal`；等待 10 秒仍没有退出记录时，才精确关闭目标 tmux session，并返回 `shutdown: forced`。这个判断不依赖屏幕文字、shell prompt 或外层 Agent 的语义分析。

内层 TUI 退出后，登录 shell 可能仍留在 tmux 中，因此 `finish` 最后仍会关闭 session 并删除观察状态。这一步只是清理资源，不会把已经记录为 `graceful` 或 `abnormal` 的结果改成强制退出。10 秒是显式结束后的退出宽限期，与任务已经运行多久无关；cc-use 仍然不会按运行时长自动清理 session，也不会按前缀杀掉其他 session。

## shell 环境

cc-use 让 tmux 先启动正常登录 shell，再启动一个内部 runner。runner 随后执行：

```text
command codex ...
command claude ...
```

runner 保持为内层 TUI 的父进程，用于在进程结束时记录真实 exit code。因此 PATH、API Key 和其他设置仍由用户自己的 shell 初始化规则提供。cc-use 不扫描 export 行，不依次 source 各种 rc 文件，也不维护额外环境文件。

`command` 会绕过 alias 和 shell function，避免用户 wrapper 重复添加启动参数，但仍然使用登录 shell 得到的 PATH。

修改正常 shell 启动文件后，新建 session 会重新读取。已经运行的旧 session 和 Agent 进程不会自动刷新环境。

## CLI

核心命令：

```text
cc-use start
cc-use send
cc-use keys
cc-use monitor
cc-use status
cc-use scrollback
cc-use finish
```

诊断命令：

```text
cc-use snapshot
cc-use list
```

查看完整用法：

```bash
skills/cc-use/scripts/cc-use
```

## TUI 录制

仓库仍保留把 tmux TUI 录制为 GIF 的工作流。只有用户明确要求录制演示时，才读取：

```text
skills/cc-use/references/tui-recording.md
```

## 定时任务

cc-use 本身不注册 cron、launchd、systemd timer，也不保存定时规则。需要由外部调度器触发 cc-use 时，先阅读[定时任务参考](skills/cc-use/references/scheduled-tasks.md)。

这份文档只说明环境变量、用户 shell、任务重叠、无人值守交互和 session 清理等设计边界。具体使用哪种调度器、如何提供环境和通知，由用户根据机器环境决定。

## 本地开发

运行回归测试：

```bash
bash tests/cc-use-regression.sh
```

测试使用临时目录和 tmux stub，不会启动真实 Codex 或 Claude Code。

Skill 源码位置：

```text
skills/cc-use/SKILL.md
```

通过 `npx skills` 全局安装后，修改源码并推送还不会自动改变已经进入的交互式 Agent 会话。同步新版本后，需要退出当前 Agent、重新加载 shell，再进入新的会话。
