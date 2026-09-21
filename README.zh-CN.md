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

<p align="center"><a href="README.md">English</a> · <a href="README.zh-CN.md">中文</a></p>

丢一个长任务给它跑，切去浏览器，然后就忘了。任务结束时弹一条通知，告诉你是哪个
会话跑完的、跑了多久；点 **Go to tab** 就回到那个会话的标签页——同一个项目里开着
好几个会话也不会认错。

## 功能

- **只在值得打断你的时候才响。** 少于 3 分钟不通知，3–10 分钟静音通知，10 分钟及以上
  带提示音。阈值[可以改](docs/reference.zh-CN.md#配置)。
- **回到那个标签页，而不只是那个项目。** 按会话区分标签页，不靠项目目录去猜，同一个
  仓库开几个会话也跳得准。
- **Claude Code 和 Codex CLI 都支持**，通知上显示各自的会话标题。
- **不赖着。** 回到那个标签页、或者再提一个问题，通知就自己撤掉；没人理的 20 分钟后
  过期。
- **菜单栏列表**：哪些会话在等你。
- **不多装东西。** 不需要 Node，没有遥测，不要辅助功能权限。

## 安装

把这段贴进 Claude Code 或 Codex CLI：

```text
把 https://github.com/Davie521/ai-ghostty-notifier 装到这台 Mac 上。
先 clone，然后严格按 docs/agent-install.md 执行，包括里面的检查，
最后告诉我哪些步骤只能我自己做。
```

agent 会构建并安装配套 App、把 hook 合并进你的设置而不碰其他配置，并且每一步都实际
检查。[docs/agent-install.md](docs/agent-install.md) 是写给它执行的英文说明，你不用读。
有两件事留给你：在系统设置里允许通知和自动化权限，以及重启已经开着的 CLI 会话。

**需要：** macOS、支持 AppleScript 的 [Ghostty](https://ghostty.org)、Swift 6 工具链
（App 从源码构建，暂时没有现成的下载包），以及 Claude Code 或 Codex CLI。

## 文档

[手动安装](docs/reference.zh-CN.md#手动安装) ·
[行为细节](docs/reference.zh-CN.md#行为) ·
[配置](docs/reference.zh-CN.md#配置) ·
[原理](docs/reference.zh-CN.md#原理) ·
[排查与局限](docs/reference.zh-CN.md#排查与局限) ·
[卸载](docs/reference.zh-CN.md#卸载)

## 致谢与许可证

灵感来自 Claude Code 通知生态，包括
[claude-code-notifier](https://github.com/kovoor/claude-code-notifier) 中讨论的 TTY 标记思路。

[MIT](LICENSE)。
