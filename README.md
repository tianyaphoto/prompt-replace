# Prompt Replace

macOS 菜单栏小工具：在任何 App 里按快捷键弹出浮窗，输入文字，用预设的 prompt 交给本机 `claude -p` 处理，再把结果粘贴回原来的输入框。最初的用途是跟 Claude Code 对话时"中文写、英文发"。

## 安装

```bash
./build.sh --install     # 构建并安装到 ~/Applications，然后启动
```

第一次启动时，macOS 会请求**辅助功能**权限（系统设置 → 隐私与安全性 → 辅助功能）。这个权限用来模拟 ⌘V 粘贴、读取选中的文字。没有权限也能用，只是结果只复制到剪贴板，需要你手动粘贴。

需要本机已安装并登录 Claude Code（`claude` 命令可用）。

## 使用

| 操作 | 快捷键 |
| --- | --- |
| 打开浮窗（沿用上次的预设） | ⌃⌘Space |
| 用指定预设打开 | ⌃⌥E 翻译成英文 · ⌃⌥R 精炼为 agent 指令 · ⌃⌥P 润色英文 · ⌃⌥C 翻译成中文 |
| 开关会话上下文 | ⌘K |
| 执行 / 结果就绪后粘贴 | ⌘↩ |
| 粘贴（输入框没有焦点时） | ↩ |
| 只复制不粘贴 | ⇧⌘C |
| 切换预设 | ⌘1–9 |
| 取消并关闭 | Esc |
| 设置 | ⌘, |

- 典型流程：⌃⌘Space → 写中文 → ⌘↩ → 看一眼结果 → ⌘↩（或 ↩）粘贴回终端。
- 打开浮窗前如果选中了文字，会自动带进浮窗；用某个预设的专属快捷键打开时，还会直接开始执行。
- 执行时用的是中文输入法友好的 ⌘↩，单独的 ↩ 留给输入法确认候选词和换行。
- 点击浮窗外面会关闭浮窗，草稿会保留。

## 会话上下文（精炼为 agent 指令）

目的：节省 Claude Code 的订阅额度。额度大多不是花在你那句话上，而是花在 agent 因为指令含糊而做的搜索、猜测和返工上。「精炼为 agent 指令」预设会读取最近的 Claude Code 会话，把「刚才那个函数」「上面的问题」这类说法换成会话里出现过的具体文件名、函数名、报错信息，让 agent 第一次就做对。

- 自动选用 `~/.claude/projects/` 下最近被写入的会话（默认 120 分钟内）。浮窗右上角会显示用的是哪个项目的会话、预计附带多少 token。
- 只附带你和 Claude 的对话文字，以及一行行工具调用摘要（比如 `(tool: Read src/api.ts)`）。工具输出、思考过程、技能注入的内容都会丢掉，遇到 `/clear` 或 `/compact` 时，之前的内容也会丢掉。默认最多 12,000 字符，约 4k–6k token。
- 这些调用和 Claude Code 共用同一份订阅额度，所以默认用 haiku + effort low。只有勾选了「附带上下文」的预设才会读取会话。
- 改写有可能猜错，所以带上下文执行时一定会先预览，不会自动粘贴。

## 配置

菜单栏图标 → 设置，可以增删预设、编辑 prompt、绑定快捷键、切换模型（默认 `haiku` + effort `low`，追求速度）。
配置文件位于 `~/Library/Application Support/PromptReplace/config.json`。

每个预设的 prompt 作为 `--system-prompt` 传给 `claude -p`，浮窗内容作为用户消息。调用时会关闭工具、MCP 和项目设置（`--tools "" --strict-mcp-config --setting-sources ""`），并在独立的工作目录里运行，所以不会读到任何项目的 CLAUDE.md。

## 调试

```bash
swift test
"build/Prompt Replace.app/Contents/MacOS/PromptReplace" --run "帮我把这个函数改成异步的" [预设序号]
SHOW_CONTEXT=1 "build/Prompt Replace.app/Contents/MacOS/PromptReplace" --run "把刚才那个问题修一下" 1   # 同时打印附带的上下文
```
