# TUI / tmux 录制为 GIF

只有用户明确要求录制终端演示、制作 README 动图或输出 TUI GIF 时，才使用本工作流。

它适用于运行在 tmux 中的 Codex CLI、Claude Code、vim、htop、k9s、lazygit 等终端界面。它记录的是终端状态和时间轴，不包含操作系统桌面、真实鼠标或窗口像素；需要完整桌面视频时应使用屏幕录制工具。

## 工具链

| 工具 | 用途 |
|---|---|
| `asciinema` | 把终端输出记录为带时间戳的 `.cast` |
| `agg` | 把 cast 渲染为 GIF |
| `gifsicle` | 优化和压缩 GIF |
| Pillow（可选） | 裁剪状态栏、添加窗口外框 |

开始前检查依赖：

```bash
command -v asciinema
command -v agg
command -v gifsicle
python3 -c "from PIL import Image" 2>&1
```

缺少依赖时，列出缺失项和建议安装命令，获得用户同意后再安装。不要静默安装。

常见安装方式：

```bash
brew install asciinema agg gifsicle
```

Linux 可以使用系统包管理器；如果需要单独安装 `agg`，可以使用 Rust 工具链。Pillow 应优先放入临时 uv 项目，不要污染系统 Python。

## 准备 cc-use session

如果录制的是新的内层 Agent，先正常启动并完成 readiness 检查：

```bash
<skill_dir>/scripts/cc-use start \
  --project "$PWD" \
  --agent codex
```

保存返回的 session 名称。录制结束前不要执行 `finish`。

如果启动画面显示可以明确拒绝的更新提示，按主 Skill 的规则选择“不升级”或等价选项，再继续检查。登录、认证、含义不清的权限提示或其他无法安全处理的阻塞仍应停止录制准备并报告。

## 录制方法

推荐用 `asciinema` 以只读方式 attach 到目标 tmux session：

```bash
OUT="$PWD/tmp/recording-$(date +%s)"
mkdir -p "$OUT"

( asciinema rec -y --overwrite \
    -c "timeout 50 tmux attach -r -t SESSION_NAME" \
    --idle-time-limit 2 \
    "$OUT/demo.cast" > "$OUT/asciinema.log" 2>&1 ) &
ASCII_PID=$!

sleep 3

<skill_dir>/scripts/cc-use send "DEMO_TASK" \
  --project "$PWD" \
  --session SESSION_NAME \
  --initial-quiet-seconds 12

wait "$ASCII_PID" 2>/dev/null
```

关键约束：

- 必须使用 `tmux attach -r`，避免录制端意外向内层 TUI 输入内容。
- 为录制设置明确的最长时长，给 Agent 延迟和任务执行留出余量。
- `--idle-time-limit` 用于压缩长时间静默，不会删除真实事件。
- 驱动演示仍使用 cc-use 的 `send`，不要绕过启动检查。

如果录制需要固定窗口大小，只调整目标 session：

```bash
tmux set-option -t SESSION_NAME window-size manual
tmux resize-window -t SESSION_NAME -x 120 -y 36
```

录制结束后恢复：

```bash
tmux set-option -t SESSION_NAME window-size latest
```

不要使用全局 `-g` 修改所有 tmux session。

## 始终保留 cast

`.cast` 是体积很小的原始时间轴，应当作为源文件保留。以后可以从同一 cast：

- 更换主题、字号和速度；
- 重新压缩静默时长；
- 调整剪辑区间；
- 重新生成不同尺寸的 GIF。

不要在清理中自动删除 cast。

## 使用 agg 渲染

终端 GIF 优先追求清晰的纯色文字。关闭字体抗锯齿通常可以显著减少调色板颜色，避免 GIF 量化后出现模糊边缘。

推荐基线：

```bash
agg --theme monokai \
  --font-size 22 \
  --font-antialiasing off \
  --speed 1.5 \
  --idle-time-limit 1.5 \
  --fps-cap 30 \
  "$OUT/demo.cast" \
  "$OUT/demo.raw.gif"
```

原则：

- 默认关闭抗锯齿；
- README 常用字号可以从 22 开始；
- 使用颜色数量较少的深色主题；
- 适当加速并限制最长静默；
- 不要直接把某一组参数写死成唯一标准。

## 使用 gifsicle 优化

先进行无损优化：

```bash
gifsicle -O3 --colors 32 \
  "$OUT/demo.raw.gif" \
  -o "$OUT/demo.opt.gif"
```

终端内容通常是小调色板纯色图形。默认不要使用 `--lossy`；有损量化容易给文字边缘引入噪点。只有无损结果仍明显过大时，才尝试有损参数并进行视觉检查。

## 输出三个候选版本

默认生成少量可比较的版本：

| 版本 | 字号 | 适用场景 |
|---|---:|---|
| compact | 16 | 密集文档中的内嵌动图 |
| standard | 22 | README 或普通博客 |
| hi-dpi | 28 | 演示文稿或高分辨率页面 |

最多生成三个版本，报告每个文件的路径、尺寸和大小，并根据用户目标推荐一个。

## 裁剪底部内容

tmux 录制常包含：

- tmux 状态栏；
- shell 提示符残留；
- Agent TUI 底部帮助文字；
- detach 后产生的空白或清屏帧。

不要写死固定裁剪比例。选择录制中段、内容较丰富的一帧进行判断，不要只看最后一帧。

提取参考帧：

```bash
python3 -c "from PIL import Image; img = Image.open('demo.raw.gif'); img.seek(20); img.convert('RGB').save('frame.png')"
```

判断顺序：

1. 从底部识别颜色高度一致的 tmux 状态栏。
2. 检查状态栏上方是否还有不需要的 shell 或提示文字。
3. 找到用户有意义的最后一行。
4. 保留少量底部 padding。
5. 裁剪后重新查看中段帧，确认没有切掉实际内容。

常见界面：

- Codex CLI、Claude Code：输入框底边通常是自然裁剪边界。
- 普通 REPL：保留提示符所在行。
- vim、htop、k9s 等全屏 TUI：通常只删除 tmux 状态栏。
- 无法判断时宁可多保留，不要裁掉真实内容。

完全无法人工判断时，最保守的回退策略是只删除一行终端文字高度。

## 添加窗口外框

窗口外框属于可选装饰。默认可以添加一个简单的 macOS 风格标题栏：

- 固定高度的标题区域；
- 红、黄、绿三个圆点；
- 标题栏与终端内容之间一条分隔线；
- 不默认添加圆角，避免 GIF 二值透明造成锯齿。

用户要求 Windows、Linux 风格或不需要外框时，按用户选择处理。

## 输出位置

把本次录制的所有文件放在同一目录，例如：

```text
<project>/tmp/recording-<timestamp>/
```

至少保留：

```text
demo.cast
demo.raw.gif
demo.opt.gif
asciinema.log
```

向用户报告所有最终文件和 cast 的绝对路径。

## 清理 session

完成录制、确认文件有效并且不再需要驱动内层 Agent 后，执行：

```bash
<skill_dir>/scripts/cc-use finish \
  --project "$PWD" \
  --session SESSION_NAME
```

清理 cc-use session 不等于删除录制文件。cast 和用户选择保留的 GIF 应继续存在。

## 验收清单

1. 检查依赖，安装前获得用户同意。
2. 启动并检查内层 TUI。
3. 创建单独输出目录。
4. 以只读方式 attach 并开始录制。
5. 使用 `send` 驱动演示。
6. 确认 cast 存在且非空。
7. 生成不超过三个字号版本。
8. 先做无损优化。
9. 查看中段帧并决定裁剪。
10. 按需添加窗口外框。
11. 报告所有产物路径和大小。
12. 保留 cast，最后清理 cc-use session。
