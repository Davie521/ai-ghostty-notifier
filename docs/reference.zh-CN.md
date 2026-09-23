# 参考

[README](../README.zh-CN.md) 里没写的都在这儿：手动安装、行为细节、全部配置项、原理、
排查、测试套件和卸载。最省事的安装方式是把 [agent-install.md](agent-install.md)
交给一个编码 agent；这份文件是同样的内容，写给人看。

## 手动安装


**配套 ClaudeGhosttyNotify.app 必须安装。** 它里面的 Swift 程序负责读取 hook、
查找终端、判断通知和回退投递。shell 文件只是保留原名称的启动入口；
每次 hook 不再依赖 jq 或 Python。App 的常驻进程可以不一直运行，但 App 文件必须保留。

一条命令就能完成下面第 1–3 步：装的是当前 [release](releasing.md) 里签名并公证过的
构建，不用 clone、不用 Swift 工具链。[agent-install.md](agent-install.md) 也是先走这条路：

```bash
curl -fsSL https://github.com/Davie521/ai-ghostty-notifier/releases/latest/download/setup.sh | bash
```

有多个 Claude 配置目录的话，对其余每个目录再跑一次：在 `bash` 前面加
`CLAUDE_CONFIG_DIR=<目录>`，在 `bash -s --` 后面加 `--claude --no-codex`。

### 1. 先构建并安装必需的 App

需要 macOS、支持 AppleScript 的 Ghostty，以及 Swift 6 工具链。
在包含本次原生 hook 的仓库版本中运行：

```bash
bash scripts/build-agent.sh --build-only
bash scripts/install-agent.sh
```

第一条只构建、签名仓库中的 App。第二条会**安装或替换 App 并重启服务**、
注册 LaunchAgent、打开通知授权流程。只想测试构建时，不要运行安装命令。

有会话在用的时候也可以升级。安装器在停掉旧版之前，先去掉已安装主程序的可执行位，
并在旁边留一个标记，这样那几秒里触发的 hook 就无法再拉起一个会活过换包的旧版进程；
从 checkout 或插件目录注册的 hook 也认这个标记，不会改用旁边的构建。新副本就位之前（通常一两秒，最多
约一分钟），hook 什么都不做：这段时间里该出的通知不会显示。只有确认旧版进程都已
退出才会换包；确认不了、安装失败或被中断时，可执行位会还回去、LaunchAgent 重新
加载，旧版照常工作。只有对安装器 `kill -9` 才可能让它停在关闭状态，重跑安装器即可恢复。

App 会复制到：

```text
~/Library/Application Support/claude-ghostty-notify/ClaudeGhosttyNotify.app
```

hook 和 launchd 都使用这个固定位置，所以移动源码仓库不会导致它们失效。
只重新 build 不会更新已经安装的那份 App。

### 2. 注册 Claude Code hook

针对当前 checkout 运行：

```bash
bash install.sh --register-settings
```

安装器先检查原生 App，再把薄入口复制到 `<config>/hooks/`，并把它们的条目合并进
`<config>/settings.json`；`<config>` 是 `$CLAUDE_CONFIG_DIR`（设了的话），否则是 `~/.claude`。
合并会保留文件里其他所有内容，先备份为 `settings.json.ghostty-notify-backup-<时间>`，
已经跑着这些入口的事件不会重复添加；文件解析不了或插件已启用时不写入，并说明原因。
有多个配置目录的话，设置 `CLAUDE_CONFIG_DIR` 逐个运行一次。
不带 `--register-settings` 只打印片段，需要手动合并；完整示例见
[example-settings.json](../example-settings.json)。

也可以使用包含**同一原生 hook 版本**的插件，通过
[hooks/hooks.json](../hooks/hooks.json) 自动注册。先安装 App，再在 Claude Code 中运行：

```text
/plugin marketplace add Davie521/ai-ghostty-notifier
/plugin install ai-ghostty-notifier@ai-ghostty-notifier
```

手动安装和插件注册二选一，避免重复通知。要测试本地 checkout 就用手动安装：
marketplace 提供的是最近发布的版本，不是你的工作副本。

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

## 行为

| 任务耗时 | 通知 |
| --- | --- |
| 少于 3 分钟 | 不通知 |
| 3–10 分钟 | 无声通知 |
| 10 分钟及以上 | 通知 + Glass 提示音 |

阈值可以修改（[全部配置项](#配置)）。默认 20 分钟后通知过期；回到会话标签页或提交新提问时会提前清除。
权限/输入提示默认静默，只有设置 `GHOSTTY_NOTIFY_ON_PROMPT=1` 才开启。

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
| `GHOSTTY_NOTIFY_BACKEND` | `auto` | 先用就绪的常驻进程，否则用只显示的 terminal-notifier；明确选择 terminal-notifier 可跳过常驻投递。`agent` 等同 `auto`；退役的 `alerter` 和其他未知值按 `terminal-notifier` 处理 |
| `GHOSTTY_NOTIFY_ON_PROMPT` | `0` | 只有 `1` 开启 Claude 权限/输入提示通知 |
| `GHOSTTY_NOTIFY_CLEAR_ON_FOCUS` | `1` | `0`、`false`、`no`、`off` 关闭聚焦清理 |
| `GHOSTTY_NOTIFY_AGENT_APP` | 自动发现 | 常驻 App 路径；空值禁用常驻路径，不会取消必需的原生运行时 |
| `GHOSTTY_NOTIFY_NATIVE_APP` | 已安装的 App | 仅环境变量可覆盖入口查找的原生 App，不读取 Codex config 中的此项 |
| `GHOSTTY_NOTIFY_MENU_BAR` | `1` | 常驻进程自身的设置；false 类值隐藏菜单栏 |
| `GHOSTTY_NOTIFY_HOOK_DEADLINE` | `12` | hook 进程放弃并以成功状态退出前的秒数；限制在 1–120 |
| `GHOSTTY_NOTIFY_APP_NAME` | `Claude` | Claude 通知里显示的应用名；Codex 固定为 `Codex` |
| `GHOSTTY_NOTIFY_GROUP_PREFIX` | `ghostty-notify` | 外部后端投递与撤回用的分组前缀；Codex 默认 `codex-ghostty-notify` |
| `GHOSTTY_NOTIFY_SESSION_DIR` | `<notifications>/ghostty-sessions` | 每个会话的状态目录；`<notifications>` 是 `~/.claude/notifications` 或 `$CODEX_HOME/notifications` |
| `GHOSTTY_NOTIFY_RATE_DIR` | `<notifications>/state` | 限频状态目录，同一个基目录 |
| `GHOSTTY_NOTIFY_TTY` | 自动探测 | 终端设备覆盖，必须是 `/dev/` 下的字符设备。完全没有终端的 Claude 会话（headless `claude -p`）会被忽略，除非用它指明一个；Codex 会话仍需有终端 CLI 祖先进程 |
| `GHOSTTY_NOTIFY_CODEX_SETTLE` | `1.5` | Codex 在 Stop 之后等 TUI 标题稳定再绑定的秒数 |
| `GHOSTTY_NOTIFY_MARKER_RETRY_DELAYS` | Codex `0.5 1 2 3`，Claude 无 | 标签页查找重试间隔，空白分隔，最多 8 个；明确设为空则不重试 |
| `CODEX_HOME`、`CODEX_SQLITE_HOME` | `~/.codex`、`$CODEX_HOME` | 原生 Codex 标题和状态查询的读取位置；SQLite 只读打开 |

hook 不会长时间挡住 CLI：每次终端查询都有上限，hook 进程到
`GHOSTTY_NOTIFY_HOOK_DEADLINE` 会自行退出，随附的 hook 条目也写了 `"timeout": 15`。
手写条目时请保留这个字段，否则 Claude Code 对 command hook 默认最多等 600 秒，
hook 一旦卡住，看起来就像会话卡死
（[事故记录](incident-2026-09-17-pretooluse-hang.md)）。

耗时、超时接受非负整数，缺失、空或非法值使用默认值。
空值在不同设置里含义不同：路径和前缀类设置回落到默认值，
`GHOSTTY_NOTIFY_AGENT_APP` 为空表示不走常驻投递，
`GHOSTTY_NOTIFY_MARKER_RETRY_DELAYS` 为空表示不重试。
相对路径按 hook 的工作目录解析，`~/` 按发送方的 HOME 解析。
Codex 的 `config.json` 只贡献 `GHOSTTY_NOTIFY_*` 键；null 值忽略，
文件格式错误会报告但 hook 仍以成功状态退出。

原生运行时之前的这些设置已被忽略：`GHOSTTY_NOTIFY_ALERTER`、`GHOSTTY_NOTIFY_FOCUS_POLL`，
以及 `GHOSTTY_NOTIFY_FOCUS_SCRIPT` / `GHOSTTY_NOTIFY_CLEAR_SCRIPT` 这两个 helper 替换项；
它们没有原生替代，升级时请删掉。

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
- 完全没有终端的 Claude 会话同样跳过，比如由服务或脚本拉起的 headless `claude -p`；
  即使它从 Ghostty 里启动的程序那里继承了 `TERM_PROGRAM` 也一样：它没有标签页可通知、可跳转。
  自身没有终端的会话，可以用 `GHOSTTY_NOTIFY_TTY` 指明一个。
- 常驻 App 使用独立通知身份、按会话精确撤回、应用激活事件和菜单栏待处理列表。
- 点击后的跳转是核对过的，不是假定的：聚焦标签页之后，常驻进程会回读当前选中的是哪个标签页。
  回读赶在 Ghostty 切换完成之前到达的，会等一小会儿再读一次；选中项确实没动的，会再发一次聚焦命令；
  日志里记着这次跳转走了哪一步。
  在 Ghostty 里切换标签页不会激活任何 App，所以当 Ghostty 在前台、且有通知
  挂在已知标签页上时，App 还会每秒读一次当前选中的标签页；任一条件不再成立就停止。
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

为什么必须装 App、而且没有 shell 兜底：改成原生运行时之前，shell hook 里已经堆了
JSON 解析、状态文件、锁、进程看守和终端恢复逻辑。只把常驻那条路径迁到 Swift，
就得同时维护、测试第二套完整实现。App 的可执行文件本来就在，所以让它同时充当
短命的 hook 进程和临时 worker。代价是安装、升级都要先有构建好的 App，hook 才能工作；
卸掉 App 通知就停，启动入口会报告运行时缺失并以 0 退出。也考虑过用 Python 写 hook 客户端，
否决的原因是每次 hook 多一个解释器，而 macOS 相关的集成一点没少。

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
- 仅支持 macOS/Ghostty；Codex 通知要求存在终端 CLI 归属，Claude 通知要求存在终端。
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

**构建副本与通知点击。**
macOS 按 bundle id 解析通知点击，LaunchServices 可能选中它知道的任何一份副本，不一定是已安装的那份。
它认识一份副本有两条途径，都在本机实测过：从某个包里启动过常驻进程，这个包就会被登记，进程退出后登记仍在；
包只要放在 Spotlight 会索引的目录里，例如桌面上的 checkout，哪怕从没运行过，一分钟内也会被登记。
`lsregister -u` 只能管这么久。放在名字以 `.noindex` 结尾的目录里的副本没有被发现。

被错误选中的副本会怎样，取决于已安装的常驻进程。它带单实例锁时，副本发现锁被占就退出，那次点击落空。
加锁之前的旧版常驻不持锁：一次点击就可能拉起它旁边的一份构建，两个常驻进程同时处理一个队列，直到多出来的那个被停掉。

所以日常使用的机器上不要留着构建：用完删掉 `build/`，或者去掉其中二进制的可执行位。
`tests/test-agent.sh` 会注销它用过的构建，但这只在包被重新发现之前有效。

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
第三项 `bash tests/test-live-focus.sh <源标签页 id> <目标标签页 id>` 需要两个已经打开的 Ghostty 窗口：
先聚焦源标签页，再让运行时去聚焦目标标签页，然后断言目标窗口真的到了最前面，
因为 Ghostty 自己的 selected-tab 属性在窗口仍被挡在后面时也会报告成功。它只认 `GHOSTTY_NOTIFY_NATIVE_APP`。
这个标签页就是测试夹具：检查会反复把标记写进它的标题，要求每次查找都找到，结束时把标题重置为 Ghostty 的默认标题，不管原来是什么。
所以它必须空闲：检查期间有程序设置标题的话，例如 Claude Code 工作时每秒两次，标记会被覆盖，检查失败，那个程序自己的标题也会丢。
来龙去脉见 `docs/incident-2026-09-17-pretooluse-hang.md`。

## 卸载

先移除 hook 注册并重启已打开的 CLI 会话。
插件方式使用 `/plugin uninstall ai-ghostty-notifier@ai-ghostty-notifier`；
手动 Claude 安装删除 `settings.json` 中本项目的条目；
Codex 删除 `hooks.json` 中命令包含 `ghostty-notify/codex-hook.sh` 的条目。

**两个 CLI** 都取消使用后，再卸载共用 App：从 checkout 装的用第一条，从 release 装的用第二条。

```bash
bash scripts/install-agent.sh --uninstall
curl -fsSL https://github.com/Davie521/ai-ghostty-notifier/releases/latest/download/setup.sh | bash -s -- --uninstall
```

这会删除 LaunchAgent 和已安装的 App，保留会话状态；不会启用完整 shell 兜底。
之后可以清理本项目不再使用的入口文件和状态，但保留其他 hook 和 Codex 配置。
Codex 配置备份仍在 `~/.codex/backups/`。

