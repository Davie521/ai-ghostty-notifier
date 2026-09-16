# claude-ghostty-notify

[![CI](https://github.com/Davie521/claude-ghostty-notify/actions/workflows/ci.yml/badge.svg)](https://github.com/Davie521/claude-ghostty-notify/actions/workflows/ci.yml)

**语言 / Language** → [English](README.md) · [中文](README.zh-CN.md)

> **长任务一跑完,就把你精准拉回运行它的那个 Ghostty tab —— 不是把 app 拉到前台、不是最前面那个 tab,是_那一个_ tab。**

长任务跑完,macOS 弹出通知,点 **Go to tab**,Ghostty 直接跳到运行它的那个 surface —— 哪怕同一个项目目录下还开着另外五个 Claude 会话。就是几个依赖极少的小 bash hook;没有常驻进程、没有 Node、没有遥测、不需要任何辅助功能权限。

```
10:32   你在 8 个 tab 里的第 3 个开始一次 12 分钟的重构,然后切去浏览器
          ...
10:44   ┌──────────────────────────┐
        │ Claude ✅                │   ← macOS 通知
        │ auth-refactor — webapp   │   ← 会话标题 — 项目名
        │ Finished after 12m 3s    │
        │            [ Go to tab ] │
        └──────────────────────────┘
        点一下  →  Ghostty 直接跳到第 3 个 tab
```

Repo: https://github.com/Davie521/claude-ghostty-notify

---

## Codex 也可以用

Ghostty 里跑的 Codex CLI 也能得到同样的通知、**Go to tab** 跳转和回到标签页后自动清除，标题显示 **Codex ✅**。Codex CLI 0.153 起自带 lifecycle hooks，传入的 JSON 与 Claude Code 一致，所以经一个小适配脚本直接复用同一套脚本。在本仓库运行（仅安装器需要 Python 3.11+）：

```bash
python3 scripts/install-codex.py
```

然后在 Ghostty 里启动 `codex`，运行一次 **`/hooks`**，信任两条 `ghostty-notify` 条目（`UserPromptSubmit`、`Stop`）——Codex 对没见过的 hook 条目都要先审核才会执行。已经开着的会话重启后生效。

安装器把脚本复制到 `~/.codex/ghostty-notify/`（挪动仓库不影响），在 `~/.codex/hooks.json` 里追加这两条，不动你已有的 hook；改动的每个文件都先备份到 `~/.codex/backups/`。支持 `CODEX_HOME`。状态与 Claude 分开，存在 `~/.codex/notifications/`。

- **计时从提问开始。** Codex 一轮可能先推理或跑托管工具好几分钟才碰本地命令，所以和 Claude 那套不同，这里从 `UserPromptSubmit` 起计时，而不是第一次工具调用。Codex 直接接着跑的回合边界——`/goal` 自动续跑、排队的后续提问——会从会话 rollout 里识别出来，既不弹也不清零。
- **回合结束后才绑定标签页。** Codex TUI 干活时会不停刷新标签页标题，Claude 那种回合中途的标记探测在这里注定失败；所以 Stop 钩子交给一个后台进程，等约 1.5 秒标题静止后再绑定（会重试穿过 Codex 生成线程标题的动画），然后才投递。通知比回合结束晚一两秒，「Finished after」的时长是准的。
- **设置**在 `~/.codex/ghostty-notify/config.json`：首次安装把 Claude `settings.json` 里所有 `GHOSTTY_NOTIFY_*` 偏好复制过来（没有则 180 / 600 / 1200 秒）；脚本认的任何开关——阈值、`GHOSTTY_NOTIFY_BACKEND`、`GHOSTTY_NOTIFY_AGENT_APP`……——都可以写在这个文件里，环境变量优先。
- **会话标题**：优先用 Codex 自己存的线程名，否则用会话第一句提问。
- **只有终端会话会弹。** 同一个 `hooks.json` 也会被 Codex 桌面端的线程、以及其他 agent 拉起的 `codex mcp-server` 触发；它们没有可跳回的 tab，一律跳过。
- **原生 agent 也管 Codex。** 装了 [agent](#5-原生-agent) 之后，Codex 的通知同样由它发：点击必达、精确撤回、菜单栏列表，和 Claude 的一样；新提问也同样经它撤回。想让 Codex 留在 shell 路径，在 `config.json` 里把 `GHOSTTY_NOTIFY_AGENT_APP` 设成空字符串。
- **Codex 自带的回合完成提醒**会被关掉以免重复：`[tui] notifications` 改成 `["approval-requested", "plan-mode-prompt"]`，审批和 plan 模式的提问照常提醒。因此短于阈值的回合不会有任何提醒。
- **重跑安装器不会丢掉信任。** Codex 按条目在 `hooks.json` 里的位置和定义记信任；安装器原地更新自己的条目，更新脚本本身也不需要重新信任。如果删除旧条目不得不挪动了你自己的 hook，它会说明。
- **从旧版 `notify` 回调升级**：安装器会删掉旧版写入的 `notify`——包括被 Codex 桌面端 Computer Use 用 `--previous-notify` 包过一层的情况（那层包装让每条通知晚两分钟），并保留包装器自己的部分；同时删掉 `PreToolUse` 那条。

---

## 为什么要有它

Claude Code 自带的「任务完成」信号,是在你当前正看着的那个 tab 里响一声终端铃 —— 一旦你切了 app、或者同时开着好几个会话,它就没用了。社区里的通知工具有帮助,但每个都在某处止步:

- 大多数只把 Ghostty 拉到前台 —— 正确的 tab 还得你自己找;
- 很多每次 2 秒的命令都弹,弹到你学会无视;
- 有些靠模拟按键切 tab,既要辅助功能权限、又会在 macOS 升级后失效;
- 大多数分不清同一目录下开着的两个 Claude 会话,因为它们靠工作目录匹配。

`claude-ghostty-notify` 就是奔着补上这四个缺口去的。同类项目值得一看:[code-notify](https://github.com/mylee04/code-notify)、[claude-code-notifier](https://github.com/kovoor/claude-code-notifier)、[claude-notifications-go](https://github.com/777genius/claude-notifications-go)。

---

## 亮点

| 任务耗时 | 行为 |
|---|---|
| `< 3 分钟` | **完全静默** —— 不弹通知 |
| `3 – 10 分钟` | **弹通知,无声** —— 走神回来扫一眼就行 |
| `≥ 10 分钟` | **弹通知 + Glass 提示音** —— 你肯定走远了 |

- **落在精确的那个 tab。** 一个 OSC 2 marker + 一次 AppleScript 查询,每个 session 只做一次就锁定精确的 surface,同一目录的两个会话永不混淆。
- **短任务不刷屏。** 上面三档全是环境变量 —— 按你自己的节奏调。
- **点击是真能用的。** 一个常驻小程序以自己的身份发出每条通知、自己接住点击,所以点击一定送到知道这个会话在哪个 tab 的那个进程。
- **你一回来,通知自己消失。** 聚焦到会话所在的 tab —— 不管是点通知跳回来还是自己切回来 —— 右上角的提醒立即自动清除;在会话里提交新 prompt 也会清除。角落和通知中心都不会越积越多。用 `GHOSTTY_NOTIFY_CLEAR_ON_FOCUS=0` 关闭。
- **永远不需要辅助功能权限。** 用 Ghostty 原生 AppleScript `select tab`,不是模拟按键。
- **多会话、resume 无碍。** 状态按 `session_id` 做 key,`--resume` 之后依然稳定。
- **报得出是哪个会话。** 副标题以会话标题开头 —— 优先读 hook 的 `session_title` 字段,否则取 transcript 里最后一条 `custom-title` 记录(`/rename` 手动或改名插件写入),再否则取最后一条自动生成的 `ai-title` 记录 —— 同一目录下开五个会话也能一眼分清。优先级和 `--resume` 选择器完全一致。
- **为真实使用做了加固。** 中断/崩溃重新计时、Ghostty 不可脚本化及 tmux 降级、marker 往返串行化、配置 fail-closed、AppleScript 防注入 —— 每条都有回归测试、都受 CI 把关。
- **完全归你掌控。** 几个小 bash hook,加一个你自己编译的、平时什么都不做的常驻小程序 —— 没有 Node、没有遥测 —— 不受 Claude Code 和插件升级影响。

通知在任务完成(`Stop`)时弹。权限/输入提示默认静默;设 `GHOSTTY_NOTIFY_ON_PROMPT=1` 可在 Claude 卡在后台 tab 的提示上时立刻收到提醒(不跑 bypass-permissions 模式的话推荐打开)。

---

## 安装

### 1. 依赖

```bash
brew install jq
xcode-select --install     # Swift 工具链,用来编译通知程序
```

- **jq** —— 解析 Claude Code 喂给 hook 的 JSON
- **Swift 工具链** —— 编译[第 5 步](#5-原生-agent)的通知程序,通知由它发出、点击由它接
- **terminal-notifier**(可选,`brew install terminal-notifier`)—— 编译不了通知程序的机器上的兜底,只能看见通知、点了不跳转(它的 action 连 dismiss 都会触发,分不出来)

### 2. 插件

在 Claude Code 里:

```
/plugin marketplace add Davie521/claude-ghostty-notify
/plugin install claude-ghostty-notify
```

hook 通过插件 manifest 自动注册 —— **不需要手动改 `settings.json`。**

### 3. 一个 macOS 系统设置

**系统设置 → 通知 → Claude Ghostty Notify → 提醒样式 → 提醒 (Persistent)。**

这个条目在第 5 步 agent 申请过权限之后才会出现;agent 自己也会检测到设错并弹窗带你去那一页。

> **提醒 (Persistent)** 样式会让通知留在屏幕上直到你处理它,并直接显示 **Go to tab** 按钮;**横幅 (Banner)** 样式几秒就滑走,按钮藏在 "Show" 折叠菜单里,只能从通知中心或菜单栏图标回去。

### 4. 重启 Claude Code

退出再打开,新 hook 才会被加载。默认阈值(3 分钟 / 10 分钟 / 20 分钟超时)开箱即用,想调见 [配置](#配置)。

### 5. 原生 agent

它才是把「一条通知」变成「跳回那个 tab」的东西。编译一次即可:

```bash
bash scripts/build-agent.sh     # 需要 Swift 工具链(xcode-select --install)
bash scripts/install-agent.sh   # 把 app 拷到固定位置、装 LaunchAgent、申请权限
```

安装会把 bundle 拷到 `~/Library/Application Support/claude-ghostty-notify/`,LaunchAgent 指向那份拷贝,所以仓库随便挪、随便删 —— 直接指向仓库目录的 LaunchAgent 会在仓库改名那天静默失效。每次重新 build 之后要再跑一次安装。Codex 会话用的是同一个 agent(见[上文](#codex-也可以用))。

它带来什么:

- **点击落得到实处。** 它有自己的 bundle 身份,macOS 会把点击交给知道这个会话在哪个 tab 的那个进程。(它取代的 `alerter` 后端是以 `com.apple.Terminal` 身份发通知的,机器上每个 alerter 进程共用这个身份,macOS 把点击随便派给其中一个,而那个进程不认识这条通知就丢掉。同时开好几个会话时,丢掉的点击不在少数 —— 这也是 shell 路径干脆不再提供跳转的原因。)
- **一个闲着的进程。** 它订阅 app 激活事件,两条通知之间什么都不做 —— 不轮询,也不会为每条通知派进程。
- **精确撤回。** 它经 `UNUserNotificationCenter` 发送、按 identifier 撤回,所以同一 session 的新通知会**替换**旧的而不是堆叠。
- **菜单栏图标**,图标上就带着「几个 session 在等你」的计数,菜单里逐条列出 —— 每一行原样重复那条通知的内容,点一下跳到它的 tab。在 Temporary 提醒样式下通知没等你点就滑走了,这是唯一的回去的路。它同时显示是否已授权、macOS 给它的提醒样式是哪种 —— 否则一个显示不出任何东西的后台进程,和一个正常工作的长得一模一样。

安装时会要两个权限,都是一次性的:通知、以及控制 Ghostty(点击跳转要用)。两个都要允许。用专注模式的话,把 **Claude Ghostty Notify** 也加进它的允许列表,否则它的通知会直接进通知中心,不弹也不响。

> **通知权限那个一定要点「允许」。** 点「不允许」对该构建是**永久**的 —— macOS 不会在系统设置里留下开关可以撤销,唯一的出路是换一个 bundle identifier。

卸载:`bash scripts/install-agent.sh --uninstall`(删 LaunchAgent 和那份拷贝)。之后 hook 回落到 `terminal-notifier`,能看见通知但点了不跳。

### 手动安装(不用插件系统)

```bash
git clone https://github.com/Davie521/claude-ghostty-notify.git
cd claude-ghostty-notify
./install.sh
```

它会把 hook 拷到 `~/.claude/hooks/`,并打印需要合并进 `settings.json` 的片段。完整示例见 [example-settings.json](./example-settings.json)。

## 配置

所有阈值都是 `settings.json` `env` 块里的环境变量。**改完要重启 Claude Code 才生效。**

| 变量 | 默认值 | 含义 |
|---|---:|---|
| `GHOSTTY_NOTIFY_MIN_ELAPSED`   | `180`  | 低于这个秒数(3 分钟):**静默** —— 完全不弹通知 |
| `GHOSTTY_NOTIFY_SOUND_ELAPSED` | `600`  | 低于这个(10 分钟)但高于 MIN:**弹通知但无声** |
| `GHOSTTY_NOTIFY_TIMEOUT`       | `1200` | 通知在屏幕上保留多久(20 分钟),到时自动消失 |
| `GHOSTTY_NOTIFY_BACKEND`       | `auto` | `auto` / `agent`(走 agent,它发不出来时回落到 `terminal-notifier`)或 `terminal-notifier`(直接跳过 agent)。兜底路径不接点击跳转:它的 action 连 dismiss 都会触发,分不出来 |
| `GHOSTTY_NOTIFY_ON_PROMPT`     | `0`    | 设成 `1` 后,`Notification` 事件(权限/输入提示)也会立即弹通知 + Ping 音。不跑 bypass-permissions 模式的话推荐打开 |
| `GHOSTTY_NOTIFY_CLEAR_ON_FOCUS` | `1`   | 聚焦到会话所在 tab 时自动清除通知,在该会话提交新 prompt 时同样清除。tab 未知时(tmux、Ghostty 不可脚本化)降级为「Ghostty 重新回到前台时清除」。走 `terminal-notifier` 兜底时只有「提交新 prompt」这一个触发。用 `0`/`false`/`no`/`off` 关闭;其他值一律视为开启 |
| `GHOSTTY_NOTIFY_AGENT_APP`     | *(自动发现)* | agent bundle 的路径。设成**空字符串**可以钉住 shell 路径、无视已安装的 agent;不设则「有就用」—— 先找 `~/Library/Application Support/claude-ghostty-notify/` 下装好的那份;指向一个不是可执行 bundle 的路径会被拒绝而不是盲信。Codex 从 `~/.codex/ghostty-notify/config.json` 读它 |
| `GHOSTTY_NOTIFY_MENU_BAR`      | `1`    | agent 的菜单栏图标。`0`/`false`/`no`/`off` 隐藏 —— 代价是失去待处理计数、逐条跳转的列表,以及「agent 还活着且有权限」的唯一可见凭据 |

值必须是纯整数(秒),否则回落到默认值。

**例子** —— 超过 30 秒的任务就弹通知,但只有超过 5 分钟的才响铃,通知挂 20 分钟才消失:

```json
"env": {
  "GHOSTTY_NOTIFY_MIN_ELAPSED": "30",
  "GHOSTTY_NOTIFY_SOUND_ELAPSED": "300",
  "GHOSTTY_NOTIFY_TIMEOUT": "1200"
}
```

## 常见问题排查

### 完全看不到通知

1. **Claude Ghostty Notify** 的提醒样式改成**提醒 (Persistent)** 了吗?(第 3 步)agent 在跑吗?`launchctl print gui/$(id -u)/io.github.davie521.cgnotify`
2. 改完 env 有没有**重启** Claude Code?(第 4 步)
3. macOS 的**勿扰 / 专注模式**开了吗?专注模式会把它没明确放行的 app 的通知**静默**送进通知中心 —— agent 日志照样写「posted」,`usernoted` 照样写「Presenting」。关掉它,或者把 **Claude Ghostty Notify** 加进该专注模式的「允许的 app」。
4. 检查 hook 跑过没:`ls ~/.claude/notifications/ghostty-sessions/`,应能看到当前 session 的 `<session_id>.json` 和 `.start` 文件。
5. 看 agent 自己的记录:`~/.claude/notifications/ghostty-agent/agent.log` 会写它有没有起来、macOS 有没有授权、发了什么。菜单栏图标一眼能看到同样的信息。

### 同时弹两条通知,另一条重复我的 assistant 回复文字

那是 [everything-claude-code](https://github.com/affaan-m/everything-claude-code)(ECC)plugin 自带的 `stop:desktop-notify` hook,每次 Stop 都发它自己的通知,跟本项目撞了。只关掉它这一个 hook(ECC 其他功能保留):

```json
"env": {
  "ECC_DISABLED_HOOKS": "stop:desktop-notify"
}
```

### 点了通知没反应

只有原生 agent 能路由点击。没装它时 hook 回落到 `terminal-notifier`,而它的 action 连 dismiss 都会触发,所以本项目在那条路径上干脆不接任何点击。装上 agent([第 5 步](#5-原生-agent))。

### 跳错 tab 了

1. 你用 `--resume` 在**新 tab** 里恢复了旧 session,保存的 tab ID 失效。解决:`rm ~/.claude/notifications/ghostty-sessions/<session_id>.json`,随便跑一条命令让它重新识别。
2. 跑 Claude 的原 tab 被关了。点通知只会 activate Ghostty,跳不过去。
3. 会话还开着、Ghostty 却重启过(tab id 只在一个 Ghostty 进程里有意义)。绑定会在该会话下一次工具调用时重新识别 —— Codex 是下一个回合结束时 —— 只有在那之前点的通知会落到「只激活 Ghostty」。

## 原理

```
┌─────────────────────────────────────────────────────────┐
│ PreToolUse → ghostty-tab-save.sh          (每会话一次)  │
│   往 tab 标题写 OSC 2 marker → AppleScript 找到这个 tab │
│   → 把 {tab_id, ghostty_pid} 存到 per-session 文件      │
└─────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────┐
│ UserPromptSubmit → ghostty-round-reset.sh               │
│   重新武装本轮计时器(扛得住 Esc / 崩溃)                 │
│                  → ghostty-agent-anchor.sh              │
│   告诉 agent 这个会话在哪个 tab,并让它撤回旧通知        │
└─────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────┐
│ Stop → ghostty-notify.sh                                │
│   耗时 ≥ MIN?→ 往 agent 的队列目录丢一个 JSON 文件      │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│ ClaudeGhosttyNotify.app(常驻)                           │
│   发出通知 · 点击时选中 {tab_id} · 你回到那个 tab 时撤回 │
└─────────────────────────────────────────────────────────┘
```

**`ghostty-tab-save.sh`(每次 `PreToolUse`):** 从 stdin 读 `session_id` / `cwd`;记录开始时间戳;沿进程树找到 Claude 的 controlling TTY;先确认 Ghostty 可脚本化,再往 tab 标题写一个含 session ID 的独特 OSC 2 marker;通过 AppleScript 查现在哪个 tab 带着这个 marker;恢复原标题(`trap EXIT` 保底);保存 `{tab_id, cwd, ghostty_pid}`。这套 marker 舞每 session 只跑一次,并在锁的保护下串行执行,并发工具调用没法互相抢;Ghostty 重启之后会再跑一次 —— tab id 只在一个 Ghostty 进程里有意义。Ghostty 没法被脚本化、或 marker 无法往返(比如在 tmux 里)时,它会退避,该 session 降级为只 activate。

**`ghostty-notify.sh`(`Stop` 触发;开启后也在 `Notification` 触发):** 算出耗时,低于 `MIN_ELAPSED` 直接静默退出;否则先解析会话标题(stdin 有 `session_title` 字段就用它,否则取 transcript 里最后一条 `custom-title` 记录,再否则取最后一条 `ai-title` 记录),然后把标题、副标题、正文、声音、超时和已解析的 `tab_id` 打包成一个 JSON 文件丢进 agent 的队列目录(靠 rename 发布)。Stop 时清时间戳,下一轮重新计时。agent 没装、没起、或没授权时,它会**可见地**降级到 `terminal-notifier`,而不是把通知吞掉。

**`ghostty-round-reset.sh`(`UserPromptSubmit` 触发):** 清除本轮开始时间戳。用户中断(Esc/Ctrl-C)或崩溃时 Stop 不触发,没有它的话,残留的旧时间戳会把下一轮耗时算得离谱 —— 10 秒的小任务弹出带响铃的「Finished after 20m」假通知。同时让 `ghostty-notify-clear.sh` 去清掉兜底路径还挂在屏幕上的旧通知 —— 你都提交新 prompt 了,说明人已经回到这个 tab 了。

**`ghostty-agent-anchor.sh`(`UserPromptSubmit` 触发):** 告诉 agent 这个会话住在哪个 tab,再让它撤回该会话还在屏幕上的通知。用 marker 往返写下的那个文件来锚定,比 agent 自己在处理请求那一刻采样「当前选中哪个 tab」准得多。

**`ghostty-notify-clear.sh`:** 兜底路径那一半的「回来就清除」。按 group ID 调 `terminal-notifier -remove`,并且带一道保护:在清除请求发出之后才投递的通知不会被误清。不轮询,也不派任何进程。

**agent(`ClaudeGhosttyNotify.app`):** 一个由 LaunchAgent 拉起的常驻 accessory app,负责消费队列。它经 `UNUserNotificationCenter` 发送,每个会话用一个稳定的 identifier —— 所以同一会话的新通知是**替换**旧的而不是堆叠;点击时用 Ghostty 原生 AppleScript `select tab` 选中该会话的 tab(这是 sdef 里真实的 command,不是属性写入,所以**不需要辅助功能权限**);Ghostty 回到前台且选中的正是那个 tab 时撤回通知,靠的是 `NSWorkspace` 激活事件而不是轮询;并且带一个菜单栏图标,列出正在等你的会话。

### 设计决策说明

- **为什么用 `session_id` 而不是 `$PPID`?** Claude Code 每次 hook 触发会 fork 中间 shell,PID 不固定。`session_id`(从 hook stdin JSON 读)在整个会话(含 `--resume` 后)都稳定。
- **为什么用 OSC 2 marker 而不是按 `cwd` 匹配?** 同一目录下开两个 session 时 `cwd` 一样,分不清。marker 给每个 session 独特信号,无论多少 tab 在同一目录都能精确命中。
- **为什么用常驻程序而不是 `alerter`?** 每个 `alerter` 进程都以 `com.apple.Terminal` 身份发通知,机器上所有 alerter 共用这个身份;macOS 把点击随便派给其中一个,不是它发的就丢掉,真正发通知的那个只被告知「通知没了」。会话一多,跳转就成了碰运气,所以 alerter 后端已经删除。agent 用自己的 bundle 身份发通知,也自己接点击。
- **为什么还留着 `terminal-notifier`?** 它不需要任何工具链,所以编译不了 agent 的机器至少还能**看见**任务结束了。它没法路由点击(action 连 dismiss 都会触发),所以本项目在那条路径上不接点击。

## 卸载

**插件方式:** `/plugin uninstall claude-ghostty-notify` —— hook 自动注销。

**原生 agent**(如果装了):`bash scripts/install-agent.sh --uninstall` 会删掉 LaunchAgent 和 `~/Library/Application Support/claude-ghostty-notify/` 下的拷贝,然后 `rm -rf ~/.claude/notifications/ghostty-agent`。撤销它的通知权限是另一件事,要去系统设置 → 通知里做。

**手动安装:**

```bash
rm -f ~/.claude/hooks/ghostty-tab-save.sh \
      ~/.claude/hooks/ghostty-notify.sh \
      ~/.claude/hooks/ghostty-round-reset.sh \
      ~/.claude/hooks/ghostty-notify-clear.sh \
      ~/.claude/hooks/ghostty-agent-anchor.sh \
      ~/.claude/hooks/agent-common.sh
rm -rf ~/.claude/notifications/ghostty-sessions
rm -f ~/.claude/notifications/state/ghostty-notify-*
```

然后把 `~/.claude/settings.json` 里相关的 `env` 和 `hooks` 条目删掉。

**Codex CLI**(设了 `CODEX_HOME` 的话下面的 `~/.codex` 换成它):

1. 从 `~/.codex/hooks.json` 删掉命令里含 `ghostty-notify/codex-hook.sh` 的条目,然后**重启所有开着的 Codex 会话**——运行中的会话仍拿着旧的 hook 列表,脚本一删,每次提问和回合结束都会报一条 hook 失败。
2. `rm -rf ~/.codex/ghostty-notify ~/.codex/notifications`。
3. 可选的清理,在 `~/.codex/config.toml` 里:`[hooks.state."…hooks.json:user_prompt_submit:0:0"]` / `…stop:0:0` 两条信任记录;想要回 Codex 自带的回合完成提醒就把 `[tui] notifications` 改回 `true`。安装器改过的文件都有备份在 `~/.codex/backups/`。

## 局限

- **仅 macOS** —— 依赖 Ghostty 的 AppleScript 字典 + macOS 通知 API。
- **仅 Ghostty** —— tab 识别技巧是 Ghostty 独有的。
- **Session 必须在 Ghostty 里启动** —— Claude 的 controlling TTY 不是 Ghostty surface 时,hook 静默退出。
- **关 tab 后跳不过去** —— 点通知只 activate Ghostty,无法跳转。
- **Ghostty 必须可被 AppleScript 控制** —— 需要 Ghostty ≥ 1.3(AppleScript 支持)+ macOS 自动化权限。缺任一个时 hook 探测一次、退避一天、降级为只 activate。`claude` 跑在 tmux 里同理(OSC 2 改的是 tmux pane 标题,不是 Ghostty tab):失败 3 次后该 session 降级为只 activate。

## 致谢

灵感来自现有的 Claude Code 通知生态,尤其是 [kovoor/claude-code-notifier](https://github.com/kovoor/claude-code-notifier) 讨论过的 TTY marker 技巧。

## 许可证

[MIT](./LICENSE)。
