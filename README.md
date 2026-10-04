<p align="center">
  <img src="docs/assets/ghost-bell.png" alt="AI Ghostty Notifier ghost bell logo" width="144" height="144">
</p>

<h1 align="center">ai-ghostty-notifier</h1>

<p align="center">
  <b>Long Claude Code and Codex CLI runs in Ghostty tell you the moment they finish. Short ones never interrupt you. One click brings back the tab.</b>
</p>

<p align="center">
  <a href="https://github.com/Davie521/ai-ghostty-notifier/actions/workflows/ci.yml"><img src="https://github.com/Davie521/ai-ghostty-notifier/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/Davie521/ai-ghostty-notifier/releases/latest"><img src="https://img.shields.io/github/v/release/Davie521/ai-ghostty-notifier" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT%20%2B%20Commons%20Clause-blue" alt="License: MIT + Commons Clause"></a>
  <a href="#install"><img src="https://img.shields.io/badge/macOS-13%2B-lightgrey?logo=apple" alt="macOS 13+"></a>
</p>

<p align="center"><a href="README.md">English</a> · <a href="README.zh-CN.md">中文</a></p>

<p align="center">
  <img src="docs/assets/demo.gif" alt="Demo. Built in: a 20-second task finishes, and a minute later Claude Code still pings, with sound. With ai-ghostty-notifier: another 20-second task, and a minute later nothing. A long task: the moment it ends, 12 minutes in, a notification with sound; Go to tab brings back that session's tab out of three; the menu bar lists a Codex session still waiting." width="800">
</p>

You start a long task, switch to the browser, and forget about it. When it
ends, a notification tells you which session finished and how long it took, and
**Go to tab** brings that session's tab forward, even with several sessions open
in one project.

## Features

- **Only when it is worth it.** Under 3 minutes: nothing. 3–10 minutes: a
  silent notification. 10 minutes or more: with sound. The thresholds are
  [configurable](docs/reference.md#configuration).
- **Back to the exact tab.** Tabs are told apart by session, not by project
  folder, so several sessions in one repository still land in the right place.
- **Claude Code and Codex CLI**, each notification under its session's own title.
- **Gets out of the way.** Return to the tab or send another prompt and the
  notification disappears; one nobody answers expires after 20 minutes.
- **A menu bar list** of the sessions waiting on you.
- **In your language.** Notifications and the menu bar in English or Simplified
  Chinese, following macOS.
- **Nothing extra.** No Node, no telemetry, no network, no Accessibility
  permission. Signed with a Developer ID and notarized by Apple.

## Why not the built-in notifications?

Claude Code already notifies in Ghostty, and clicking that notification brings
back its tab. What differs is when you hear about a run, and how often:

| | Built in | ai-ghostty-notifier |
| --- | --- | --- |
| **When** | About a minute after every reply, if you haven't typed since | The moment a run ends, and only for runs of 3 minutes or more |
| **Sound** | Every time | None under 10 minutes |
| **What it says** | "Claude is waiting for your input" | The session, the project and "Finished after 12m 4s" |
| **Codex CLI** | Its own alerts | The same notifications as Claude Code |
| **Still waiting** | — | A menu bar list of the sessions waiting on you |
| **Goes away** | When you focus that tab | Also when you send the next prompt, or after 20 minutes |

The two run side by side, so out of the box a long run can bring two banners:
one from this app when it ends, and one from Claude Code a minute later if you
haven't typed. For one banner, add `"preferredNotifChannel": "terminal_bell"`
to `~/.claude/settings.json`. Claude Code's own alerts, permission prompts
included, then ring the terminal bell instead, which in Ghostty by default
bounces the Dock icon once and puts 🔔 in the tab title;
`"notifications_disabled"` turns them off altogether. The installer already
turns off Codex CLI's duplicate turn-complete alert.

## Install

One command installs the current release: a signed, notarized build, no clone,
no Swift toolchain. It installs the app, then registers the hooks for whichever
of Claude Code and Codex CLI it finds, without touching anything else in their
settings.

```bash
curl -fsSL https://github.com/Davie521/ai-ghostty-notifier/releases/latest/download/setup.sh | bash
```

Or hand the job to your agent. Paste this into Claude Code or Codex CLI:

```text
Install https://github.com/Davie521/ai-ghostty-notifier on this Mac.
Clone it, then follow docs/agent-install.md exactly, including its checks,
and finish by telling me the steps only I can do.
```

The agent installs from the release, or builds from source when it has to, and
checks every step ([what it follows](docs/agent-install.md)). Either way, two
things stay with you: allowing the notification and Automation permissions, and
restarting the CLI sessions you already have open.

A quick prompt to try it shows nothing, because tasks under 3 minutes never
notify. The installer ends with a test notification instead, and
[one command](docs/reference.md#4-permissions-and-restart) sends another
whenever you want to check.

**Requirements:** macOS 13 or later, [Ghostty](https://ghostty.org) with
AppleScript support, and Claude Code or Codex CLI. A Swift 6 toolchain is
needed only to build from source.

## Docs

[Manual install](docs/reference.md#manual-install) ·
[Behavior in detail](docs/reference.md#behavior) ·
[Configuration](docs/reference.md#configuration) ·
[How it works](docs/reference.md#how-it-works) ·
[Troubleshooting](docs/reference.md#troubleshooting-and-limits) ·
[Uninstall](docs/reference.md#uninstall) ·
[Changelog](CHANGELOG.md) ·
[Contributing](CONTRIBUTING.md)

## Credits and license

Inspired by the Claude Code notification ecosystem, including the TTY-marker
idea discussed in [claude-code-opencode-notifier](https://github.com/kovoor/claude-code-opencode-notifier).

[MIT with the Commons Clause](LICENSE). Use it anywhere, at work included,
change it and share your changes. What you may not do is sell it, or sell a
product or service whose value comes entirely or substantially from it; paid
hosting, consulting and support count as selling. For a commercial license,
write to [daviefan@outlook.com](mailto:daviefan@outlook.com).

Everything released before this condition was added, up to and including
v0.5.1, stays under the plain MIT License.
