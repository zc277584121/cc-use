# cc-use

cc-use 是一个面向命令行编码 Agent 的监督式执行 Skill。当前外层 Agent 保留用户目标、任务拆解和最终验收，把耗时的调查、实现、测试或真实 TUI 操作交给 tmux 中的内层 Agent。

这里的 Agent 不限定厂商。外层和内层可以是 OpenAI Codex，也可以是 Claude Code；关键要求是内外层使用同一个 Agent 家族。

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

每次 cc-use 任务创建一个唯一 tmux session。这个 session 可以在同一个任务中持续很久，也可以跨越多次外层交互；cc-use 不根据运行时长自动关闭它。

只有在以下情况才结束 session：

- 外层验收成功；
- 验收失败；
- 用户取消或更换任务；
- 内层执行无法继续；
- 登录、更新或启动问题阻塞。

任务结束后，外层 Agent 必须调用 `finish`。session 不会被保留给未来无关任务。

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

遇到登录或更新问题时，外层不能替用户选择，也不能自动升级。它应保存必要证据、清理 session，然后报告阻塞。

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

这个流程只用于已经通过启动检查的内层 TUI。启动阶段不会使用这组提交按键。

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

scrollback 只用于临时补充上下文。cc-use 不默认保存完整长期 transcript。

## 外层验收

内层 Agent 的最终回答不能作为成功证明。外层必须直接检查实际结果，例如：

- 查看代码和 diff；
- 运行相关测试、构建或静态检查；
- 执行真实命令流程；
- 检查 UI 或生成物；
- 对照用户要求确认行为。

验收结束后清理：

```bash
skills/cc-use/scripts/cc-use finish \
  --project "$PWD" \
  --session SESSION_NAME
```

`finish` 会精确关闭目标 session，并删除本次 session 的观察状态。它不会按前缀杀掉其他用户 session。

## shell 环境

cc-use 让 tmux 先启动正常登录 shell，然后通过该 shell 执行：

```text
command codex ...
command claude ...
```

因此 PATH、API Key 和其他设置由用户自己的 shell 初始化规则提供。cc-use 不扫描 export 行，不依次 source 各种 rc 文件，也不维护额外环境文件。

`command` 会绕过 alias 和 shell function，避免用户 wrapper 重复添加启动参数，但仍然使用登录 shell 得到的 PATH。

修改正常 shell 启动文件后，新建 session 会重新读取。已经运行的旧 session 和 Agent 进程不会自动刷新环境。

## CLI

核心命令：

```text
cc-use start
cc-use send
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
