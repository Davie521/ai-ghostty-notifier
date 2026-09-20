<p align="center">
  <img src="docs/assets/ghost-bell.png" alt="AI Ghostty Notifier ghost bell logo" width="144" height="144">
</p>

<h1 align="center">ai-ghostty-notifier</h1>

<p align="center">
  <b>A long Claude Code or Codex CLI task just finished — macOS tells you, and one click takes you back to that exact Ghostty tab.</b>
</p>

<p align="center">
  <a href="https://github.com/Davie521/ai-ghostty-notifier/actions/workflows/ci.yml"><img src="https://github.com/Davie521/ai-ghostty-notifier/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
</p>

**Language / 语言** → [English](README.md) · [中文](README.zh-CN.md)

You start a long task, switch to the browser, and forget about it. When the task
ends, a macOS notification tells you which session finished and how long it took.
Click **Go to tab** and Ghostty brings that tab forward — even when several
sessions are running in the same project directory.

- **It interrupts you only when that is worth it.** Under 3 minutes: nothing.
  3–10 minutes: silent. 10 minutes or more: with sound.
- **One click returns to the session**, found by the session's own identity
  rather than by guessing from the project folder.
- **Claude Code and Codex CLI**, each shown under its own session title.
- **Quiet by design.** No Node, no telemetry, no Accessibility permission.

**What you need:** macOS, [Ghostty](https://ghostty.org) with AppleScript
support, a Swift 6 toolchain, and Claude Code or Codex CLI.

[Install](#install) · [Configuration](docs/reference.md#configuration) · [How it works](docs/reference.md#how-it-works) · [Troubleshooting](docs/reference.md#troubleshooting-and-limits)

## Behavior

| Task duration | Notification |
| --- | --- |
| Under 3 minutes | None |
| 3–10 minutes | Silent notification |
| 10 minutes or more | Notification with Glass sound |

Defaults are configurable ([every setting](docs/reference.md#configuration)).
Resident notifications expire after 20 minutes unless cleared
earlier. Focusing the session's tab or submitting another prompt withdraws its
notification. Permission/input prompts are silent unless
`GHOSTTY_NOTIFY_ON_PROMPT=1`.

## Install

Let a coding agent do it. Paste this into Claude Code or Codex CLI:

```text
Install https://github.com/Davie521/ai-ghostty-notifier on this Mac.
Clone it, then follow docs/agent-install.md exactly, including its checks,
and finish by telling me the steps only I can do.
```

[docs/agent-install.md](docs/agent-install.md) is written to be executed: it
builds and installs the companion app, merges the hook entries into your
settings without touching anything else you have there, and verifies each step
instead of assuming it worked.

Two things stay with you, because no agent can click them: granting the
notification and Automation permissions, and restarting the CLI sessions you
already have open.

Rather do it by hand? The same steps are in
[docs/reference.md](docs/reference.md#manual-install).

## Credits and license

Inspired by the Claude Code notification ecosystem, including the TTY-marker
idea discussed in [claude-code-notifier](https://github.com/kovoor/claude-code-notifier).

[MIT](LICENSE).
