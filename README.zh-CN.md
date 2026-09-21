<p align="center">
  <img src="docs/assets/ghost-bell.png" alt="AI Ghostty Notifier 幽灵铃铛图标" width="144" height="144">
</p>

<h1 align="center">ai-ghostty-notifier</h1>

<p align="center">
  <b>Claude Code 或 Codex CLI 的长任务跑完了 —— macOS 弹一条通知，点一下就回到跑它的那个 Ghostty 标签页。</b>
</p>

<p align="center">
  <a href="https://github.com/Davie521/ai-ghostty-notifier/actions/workflows/ci.yml"><img src="https://github.com/Davie521/ai-ghostty-notifier/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
</p>

**语言 / Language** → [English](README.md) · [中文](README.zh-CN.md)

丢一个长任务给它跑，切去浏览器，然后就忘了。任务结束时，macOS 弹出通知，
告诉你是哪个会话跑完的、跑了多久。点 **Go to tab**，Ghostty 直接把那个标签页
切到前面——即使同一个项目目录里同时开着好几个会话也不会认错。

- **只在值得打断你的时候才响。** 少于 3 分钟不通知，3–10 分钟静音通知，
  10 分钟及以上带提示音。
- **一次点击回到会话**：按会话自己的身份定位标签页，不靠项目目录去猜。
- **Claude Code 和 Codex CLI 都支持**，各自显示自己的会话标题。
- **安静。** 不需要 Node，没有遥测，不要辅助功能权限。

**需要：** macOS、支持 AppleScript 的 [Ghostty](https://ghostty.org)、Swift 6
工具链，以及 Claude Code 或 Codex CLI。

[安装](#安装) · [配置](docs/reference.zh-CN.md#配置) · [原理](docs/reference.zh-CN.md#原理) · [排查与局限](docs/reference.zh-CN.md#排查与局限)

## 行为

| 任务耗时 | 通知 |
| --- | --- |
| 少于 3 分钟 | 不通知 |
| 3–10 分钟 | 无声通知 |
| 10 分钟及以上 | 通知 + Glass 提示音 |

阈值可以修改（[全部配置项](docs/reference.zh-CN.md#配置)）。默认 20 分钟后通知过期；回到会话标签页或提交新提问时会提前清除。
权限/输入提示默认静默，只有设置 `GHOSTTY_NOTIFY_ON_PROMPT=1` 才开启。

## 安装

交给编码 agent 装。把下面这段贴进 Claude Code 或 Codex CLI：

```text
把 https://github.com/Davie521/ai-ghostty-notifier 装到这台 Mac 上。
先 clone，然后严格按 docs/agent-install.md 执行，包括里面的检查，
最后告诉我哪些步骤只能我自己做。
```

[docs/agent-install.md](docs/agent-install.md) 是写给 agent 执行的英文说明，你不用读它，贴上面那段话就行。它会：构建并安装配套
App、把 hook 条目合并进你的设置而不碰你已有的其他配置、每一步都实际验证过再
往下走，而不是默认它成功了。

有两件事留给你自己，因为 agent 点不了：在系统设置里授予通知和自动化权限，
以及重启你已经开着的 CLI 会话。

想手动装？同样的步骤在
[docs/reference.zh-CN.md](docs/reference.zh-CN.md#手动安装)。

## 致谢与许可证

灵感来自 Claude Code 通知生态，包括
[claude-code-notifier](https://github.com/kovoor/claude-code-notifier) 中讨论的 TTY 标记思路。

[MIT](LICENSE)。
