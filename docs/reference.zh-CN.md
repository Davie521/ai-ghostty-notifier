# 参考

[README](../README.zh-CN.md) 里没写的都在这儿：手动安装、全部配置项、原理、
排查、测试套件和卸载。最省事的安装方式是把 [agent-install.md](agent-install.md)
交给一个编码 agent；这份文件是同样的内容，写给人看。

## 手动安装


**配套 ClaudeGhosttyNotify.app 必须安装。** 它里面的 Swift 程序负责读取 hook、
查找终端、判断通知和回退投递。shell 文件只是保留原名称的启动入口；
每次 hook 不再依赖 jq 或 Python。App 的常驻进程可以不一直运行，但 App 文件必须保留。

> 当前 worktree 是原生 hook 迁移版本，尚未发布。“配套 App 必装”的安装方案已经确认。
> App 和 hook 应来自同一版本；已发布的旧插件不等于这里的实现。
> 测试证据和待人工验收项见[迁移状态](native-hook-migration.md)。

### 1. 先构建并安装必需的 App

需要 macOS、支持 AppleScript 的 Ghostty，以及 Swift 6 工具链。
在包含本次原生 hook 的仓库版本中运行：

```bash
bash scripts/build-agent.sh --build-only
bash scripts/install-agent.sh
```

第一条只构建、签名仓库中的 App。第二条会**安装或替换 App 并重启服务**、
注册 LaunchAgent、打开通知授权流程。只想测试构建时，不要运行安装命令。

App 会复制到：

```text
~/Library/Application Support/claude-ghostty-notify/ClaudeGhosttyNotify.app
```

hook 和 launchd 都使用这个固定位置，所以移动源码仓库不会导致它们失效。
只重新 build 不会更新已经安装的那份 App。

### 2. 注册 Claude Code hook

针对当前 checkout 运行：

```bash
bash install.sh
```

安装器先检查原生 App，再把薄入口复制到 `~/.claude/hooks/`，
打印需要合并进 `~/.claude/settings.json` 的片段；不会直接重写你的设置。
完整示例见 [example-settings.json](../example-settings.json)。

也可以使用包含**同一原生 hook 版本**的插件，通过
[hooks/hooks.json](../hooks/hooks.json) 自动注册。先安装 App，再在 Claude Code 中运行：

```text
/plugin marketplace add Davie521/ai-ghostty-notifier
/plugin install claude-ghostty-notify
```

手动安装和插件注册二选一，避免重复通知。测试本 worktree 时用本地手动安装，
因为 marketplace 上发布的可能仍是旧版 hook。

### 3. 注册 Codex CLI hook（需要时）

对于支持 lifecycle hook 的 Codex CLI，在同一 checkout 运行：

```bash
python3 scripts/install-codex.py
```

**只有这个安装器需要 Python 3.11+。** 它把入口复制到
`~/.codex/ghostty-notify/`，在 `~/.codex/hooks.json` 中注册
`UserPromptSubmit` 和 `Stop`，保留其他 hook 和设置；支持 `CODEX_HOME`。
之后在 Ghostty 里启动 Codex，通过 `/hooks` 信任新增条目。

重复安装尽量保留已有条目的定义、位置和信任。如果移除旧条目不得不改变其他 hook
的信任位置，安装器会说明。它还会移除本项目旧的 `notify` 回调，包括能识别的
`--previous-notify` 包装形式，同时保留包装器自己的回调。
修改已有配置前会在 `~/.codex/backups/` 创建私有权限的备份。

为避免重复的回合完成通知，安装器会在需要时把 Codex 自带的 TUI 通知缩为
`["approval-requested", "plan-mode-prompt"]`，保留审批和 plan 模式提问提醒。

### 4. 授权并重启 CLI

允许发送通知，并在系统询问控制 Ghostty 时允许自动化。
需要通知持续显示时，在**系统设置 → 通知 → AI Ghostty Notifier** 中选择
**提醒 / Persistent**。使用专注模式时也要放行这个 App。
使用外部后端时，其发送通知的应用身份也需要单独授权。

重启已经打开的 Claude/Codex 会话，让 hook 注册和设置生效。
菜单栏可以查看 App 的授权状态和提醒样式（能在系统设置里修的问题点一下直接跳过去），
并列出等你处理的会话，点一条就跳到对应标签页。

### 只安装原生程序，不启动常驻服务

App 必装，不等于常驻进程必须一直开着：

```bash
bash scripts/build-agent.sh --build-only
bash scripts/install-agent.sh --no-start
```

这只复制、校验 App，不启动 LaunchAgent、不注册 LaunchServices、不弹权限窗口。
如果已经安装 LaunchAgent，或仍有常驻进程运行（包括手动启动的 App），它会拒绝
这个选项；请运行普通安装命令完成升级。

希望常驻进程不可用时仍能显示通知，可安装 `terminal-notifier`：
`brew install terminal-notifier`。它没有点击跳转、聚焦监视或自动过期，下一次提问清除通知。
在 hook 设置中把 `GHOSTTY_NOTIFY_AGENT_APP`
设为空字符串，可以禁用自动使用/启动常驻进程。

此时 hook 处理和临时后台进程仍是 **Swift**，不是 shell 兜底。
如果既没有可用且已授权的常驻进程，也没有外部通知后端，就无法显示通知。

### 从旧版 shell 实现升级

顺序是：**先构建、安装新 App，再更新 hook 文件或匹配版本的插件，最后重启 CLI 会话。**
保留原有入口文件名有助于保持 hook 信任；轮次、限流记录和旧 agent 状态仍可读取。

App 缺失或过旧时，hook 安装器在复制前报错。运行过程中如果 App 被删除，
hook 会读取完 stdin、写明诊断并返回成功，避免阻塞 CLI，但不会发通知。
卸载 App 不再自动启用一整套 shell 实现。

私有的 `GHOSTTY_NOTIFY_FOCUS_SCRIPT` 和 `GHOSTTY_NOTIFY_CLEAR_SCRIPT`
覆盖项已经退役，聚焦与清理改为原生操作。升级目录里可能仍有旧 helper 文件，
但新入口不会调用，也不会重新安装它们。

## 配置

Claude 使用 `settings.json` 的 `env` 环境变量。
Codex 使用 `~/.codex/ghostty-notify/config.json`；
环境变量优先，**明确设置为空字符串也算覆盖**。
Codex 首次安装会从 Claude 设置中复制公开通知偏好，不复制来源专用路径和私有 helper 控制项。

| 变量 | 默认值 | 含义 |
| --- | --- | --- |
| `GHOSTTY_NOTIFY_MIN_ELAPSED` | `180` | 完成通知的最低耗时，秒 |
| `GHOSTTY_NOTIFY_SOUND_ELAPSED` | `600` | 响 Glass 提示音的最低耗时 |
| `GHOSTTY_NOTIFY_TIMEOUT` | `1200` | 自动过期秒数；`0` 表示不自动过期 |
| `GHOSTTY_NOTIFY_BACKEND` | `auto` | 先用就绪的常驻进程，否则用只显示的 terminal-notifier；明确选择 terminal-notifier 可跳过常驻投递 |
| `GHOSTTY_NOTIFY_ON_PROMPT` | `0` | 只有 `1` 开启 Claude 权限/输入提示通知 |
| `GHOSTTY_NOTIFY_CLEAR_ON_FOCUS` | `1` | `0`、`false`、`no`、`off` 关闭聚焦清理 |
| `GHOSTTY_NOTIFY_AGENT_APP` | 自动发现 | 常驻 App 路径；空值禁用常驻路径，不会取消必需的原生运行时 |
| `GHOSTTY_NOTIFY_NATIVE_APP` | 已安装的 App | 仅环境变量可覆盖入口查找的原生 App，不读取 Codex config 中的此项 |
| `GHOSTTY_NOTIFY_MENU_BAR` | `1` | 常驻进程自身的设置；false 类值隐藏菜单栏 |
| `GHOSTTY_NOTIFY_HOOK_DEADLINE` | `12` | hook 进程放弃并以成功状态退出前的秒数；限制在 1–120 |

hook 不会长时间挡住 CLI：每次终端查询都有上限，hook 进程到
`GHOSTTY_NOTIFY_HOOK_DEADLINE` 会自行退出，随附的 hook 条目也写了 `"timeout": 15`。
手写条目时请保留这个字段，否则 Claude Code 对 command hook 默认最多等 600 秒，
hook 一旦卡住，看起来就像会话卡死
（[事故记录](incident-2026-09-17-pretooluse-hang.md)）。

耗时、超时接受非负整数，缺失、空或非法值使用默认值。
其他设置的空值有各自的含义。所有路径、默认值、后端回退和退役项详见
[配置契约](native-hook-configuration.md)。

例如 Claude 的设置：

```json
"env": {
  "GHOSTTY_NOTIFY_MIN_ELAPSED": "30",
  "GHOSTTY_NOTIFY_SOUND_ELAPSED": "300",
  "GHOSTTY_NOTIFY_TIMEOUT": "1200"
}
```

## 原理

通知里能说出哪些信息、标签页是怎么找到的：

- 按会话身份区分标签页，不按项目目录猜测。通过 OSC 2 标记和进程内 AppleScript
  查询绑定标签页；绑定会缓存，并在所属 CLI 或 Ghostty 进程变化后失效。
- Claude 标题优先使用 hook 的 `session_title`，其次是 transcript 中最后一个
  自定义标题，再其次是 AI 标题。Codex 优先用线程名称，否则用第一句提问。
- Claude 从提问后的第一次工具调用计时；Codex 从提问开始计时，包含推理和托管工具
  的耗时。识别出的 Codex 自动续跑边界不通知，也不清零计时。
- Codex 在 Stop 后绑定标签页，通常先等 1.5 秒，让 TUI 标题动画稳定。
  没有终端 CLI 归属的桌面端和 MCP-server 会话会跳过。
- 常驻 App 使用独立通知身份、按会话精确撤回、应用激活事件和菜单栏待处理列表。
  外部通知后端是可选的替代路径，其限制见[排查与局限](#排查与局限)。

```text
CLI hook → 薄 shell 入口 → 同一个 Swift 程序的 --hook 模式
                            ├─ 读取 JSON / 查进程与 TTY / 捕获轮次
                            ├─ 常驻进程就绪：原子写入事件 spool
                            └─ 否则：同一个程序的 --worker 模式
```

依赖调用方进程树的信息由 hook 进程自己捕获。
Claude 首次绑定标签页以及恢复标题的尝试，会在 hook 返回前完成。
锁、重试、标题解析、限流、过期事件判断和清理都由有类型的原生代码负责；
新提问会让上一轮尚未完成的工作失效。

常驻 App 使用 `UNUserNotificationCenter` 投递；
临时 Swift worker 可以用独立参数直接调用外部通知后端。
运行时业务 helper 不再启动 Bash、jq、ps、osascript、sleep 或 sqlite3 CLI；
SQLite 通过只读 C API 查询。构建和安装脚本仍可使用 shell。

职责和证据见[原生迁移文档](native-hook-migration.md)。
[第一阶段迁移](hook-migration.md)是历史记录。其中描述的 shell 实现不是安装后可用的兜底；
它和与之对照的测试套件已在迁移完成后删除，保留在 git 历史里。

## 排查与局限

- **没有通知：** 检查必需 App 是否存在、耗时阈值、hook 注册/信任、通知授权和专注模式。
  运行时诊断写到 hook stderr；常驻状态与日志在
  `~/.claude/notifications/ghostty-agent/`。Claude 会话记录在
  `~/.claude/notifications/ghostty-sessions/`，Codex 使用自己的 `notifications/` 目录。
- **常驻进程停了：** 默认会尝试启动 App，并由临时 Swift worker 处理当前事件。
  外部投递仍需要已安装、已授权的后端；空的 `AGENT_APP` 会禁用启动尝试。
- **点击只消失、不跳转：** 使用常驻投递。alerter 已退役；terminal-notifier 不接点击跳转，
  因为它的 execute 动作也可能在关闭通知时触发。
- **重复通知：** 检查是否同时注册了手动和插件 hook，并停用其他完成提醒。
  ECC 桌面通知已有的关闭项是 `ECC_DISABLED_HOOKS=stop:desktop-notify`。
- **无法精确定位标签页：** Ghostty 需要 AppleScript 接口和自动化授权；
  tmux、标题动画可能使标记无法往返。失败或歧义绑定会退避/重试并降级为只激活应用；
  已关闭的标签页无法靠点击重新打开。终端或自动化异常时，标题恢复是尽力而为，
  不是无条件保证。
- **升级前的旧通知：** macOS 可能无法再路由旧发送身份；清掉旧通知，用新发出的通知复测。
- 仅支持 macOS/Ghostty；Codex 通知要求存在终端 CLI 归属。
  自动化测试不能替代对真实横幅、声音、点击跳转的人工验收。

## 验证

在 checkout 中运行，不要覆盖正在使用的 App：

```bash
swift test --package-path agent --quiet
bash scripts/build-agent.sh --build-only
codesign --verify --deep --strict build/ClaudeGhosttyNotify.app
NATIVE_TEST_BINARY="$PWD/build/ClaudeGhosttyNotify.app/Contents/MacOS/ghostty-notify-agent" python3 -m unittest discover -s tests -p 'test_native_hooks.py'
python3 -m unittest discover -s tests -p 'test_native_install.py'
bash tests/test-agent.sh
```

常驻集成测试需要 Aqua 和仅供测试使用的 jq；没有 Aqua 时会明确输出 SKIP。
安装测试使用私有 HOME、真实签名 App 和拦截服务命令的保护桩；
不注册 LaunchAgent，也不测试需要人工应答的权限流程。
生产 hook 不依赖 jq。

另有两项检查需要手动运行：它们依赖正在运行的 Ghostty，而 CI 里没有。
部署任何改动了 Apple Events 或原生进程启动流程的构建之前，先跑一遍：

```bash
bash tests/test-live-binding.sh
python3 tests/test-live-worker.py
```

为它们新开一个 Ghostty 标签页，里面只有普通 shell、没有任何程序在画界面，就在那里运行。
要从别处运行，就用 `GHOSTTY_NOTIFY_TTY=/dev/ttys012` 指明那个标签页的终端设备，在标签页里运行 `tty` 即可得到。
第一项让尚未绑定的 `PreToolUse` hook 走一遍真实的标签页查找。
第二项在 `--worker` 进程里做同样的事，通知后端换成只记录调用的替身，不会弹出通知。
两者默认测试已安装的 App。要测某个构建时，两个脚本认的是同一组设置，所以不会出现只设了一个、另一个脚本却还在测已安装版本的情况：
`GHOSTTY_NOTIFY_NATIVE_APP` 指向 App 包，例如 `"$PWD/build/ClaudeGhosttyNotify.app"`；`NATIVE_TEST_BINARY` 指向可执行文件；两个都设时以可执行文件为准。
每个脚本一开始都会打印它实际测试的二进制。
这个标签页就是测试夹具：检查会反复把标记写进它的标题，要求每次查找都找到，结束时把标题重置为 Ghostty 的默认标题，不管原来是什么。
所以它必须空闲：检查期间有程序设置标题的话，例如 Claude Code 工作时每秒两次，标记会被覆盖，检查失败，那个程序自己的标题也会丢。
来龙去脉见 `docs/incident-2026-09-17-pretooluse-hang.md`。

## 卸载

先移除 hook 注册并重启已打开的 CLI 会话。
插件方式使用 `/plugin uninstall claude-ghostty-notify`；
手动 Claude 安装删除 `settings.json` 中本项目的条目；
Codex 删除 `hooks.json` 中命令包含 `ghostty-notify/codex-hook.sh` 的条目。

**两个 CLI** 都取消使用后，再卸载共用 App：

```bash
bash scripts/install-agent.sh --uninstall
```

这会删除 LaunchAgent 和已安装的 App，保留会话状态；不会启用完整 shell 兜底。
之后可以清理本项目不再使用的入口文件和状态，但保留其他 hook 和 Codex 配置。
Codex 配置备份仍在 `~/.codex/backups/`。

