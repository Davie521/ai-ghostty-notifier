# claude-ghostty-notify

**Codex CLI support:** run `python3 scripts/install-codex.py` in this checkout
(Python 3.11+ for installation; the callback supports macOS Python 3.9).
Restart existing Codex CLI sessions to load the new configuration.

The installer backs up `~/.codex/config.toml`, sets its top-level `notify`
command, and copies the shared hooks into `~/.codex/ghostty-notify/`, so moving
the checkout does not break notifications. `CODEX_HOME` is supported. It uses
the same **jq + alerter** dependencies, exact-tab jump and focus dismissal as
Claude, with a **Codex ✅** title and separate state under
`~/.codex/notifications/`. terminal-notifier remains the fallback; the optional
Claude-branded resident agent is not started by this integration.

Initial timing preferences are copied from Claude's `settings.json`, falling
back to 180 / 600 / 1200 seconds. Edit `~/.codex/ghostty-notify/config.json` to
change them (environment variables take precedence). Set
`GHOSTTY_NOTIFY_MIN_ELAPSED` to `"0"` for every completed turn. The installer
removes the built-in TUI completion alert to avoid duplicates while preserving
approval notifications and an existing TUI notification opt-out.

The [official Codex completion callback](https://developers.openai.com/codex/config-advanced/#notifications)
is the completion signal. The local database/rollout is read only for a session
name and duration matching the current **turn-id**, including after resume or
interruption. If timing is unavailable (for example, an ephemeral session or a
changed rollout format), completion still produces a silent “Task complete”
alert without a fabricated duration. A new CLI process rebinds the session to
its current tab; sessions sharing a directory are never matched by cwd.
Headless processes and identifiable subagent completions are excluded. No
lifecycle hooks or shell alias changes are required.

[![CI](https://github.com/Davie521/claude-ghostty-notify/actions/workflows/ci.yml/badge.svg)](https://github.com/Davie521/claude-ghostty-notify/actions/workflows/ci.yml)

**语言 / Language** → [English](README.md) · [中文](README.zh-CN.md)

> **The moment a long Claude Code task finishes, get pulled back to the _exact_ Ghostty tab that ran it — not the app, not the frontmost tab, _that_ tab.**

A long run finishes, macOS shows a notification, you click **Go to tab**, and Ghostty jumps straight to the surface that ran it — even with five other Claude sessions open in the same project folder. A handful of small bash hooks; no daemon, no Node, no telemetry, no accessibility permissions.

```
10:32   you start a 12-min refactor in tab 3 of 8, then switch to your browser
          ...
10:44   ┌──────────────────────────┐
        │ Claude ✅                │   ← macOS notification
        │ auth-refactor — webapp   │   ← session title — project
        │ Finished after 12m 3s    │
        │            [ Go to tab ] │
        └──────────────────────────┘
        click  →  Ghostty jumps straight to tab 3
```

Repo: https://github.com/Davie521/claude-ghostty-notify

---

## Why this exists

Claude Code's own "task done" signal is a terminal bell in whatever tab you happen to be looking at — useless once you've switched apps or have several sessions running. The community notifiers help, but each stops short somewhere:

- most only bring Ghostty to the foreground — you still hunt for the right tab yourself;
- many fire on every two-second command, so you learn to tune them out;
- some switch tabs by simulating keystrokes, which needs Accessibility permission and breaks on macOS updates;
- most can't tell apart two Claude sessions open in the same folder, because they match on the working directory.

`claude-ghostty-notify` is built to close exactly those four gaps. Prior art worth a look: [code-notify](https://github.com/mylee04/code-notify), [claude-code-notifier](https://github.com/kovoor/claude-code-notifier), [claude-notifications-go](https://github.com/777genius/claude-notifications-go).

---

## Highlights

| Elapsed task time | What happens |
|---|---|
| `< 3 min` | **Silent** — no notification at all |
| `3 – 10 min` | **Notification, no sound** — glance over if you wandered off |
| `≥ 10 min` | **Notification with Glass chime** — you've clearly walked away |

- **Lands on the exact tab.** An OSC 2 marker plus an AppleScript lookup pins the precise surface once per session, so two sessions in the same folder never get confused.
- **No short-task spam.** The three tiers above are all environment variables — tune them to your rhythm.
- **Clicks that actually work.** Prefers `alerter`'s alert-style **Go to tab** button (modern macOS silently drops action clicks on banner-style notifications); falls back to `terminal-notifier`.
- **Clears itself when you arrive.** Focus the session's tab — via the notification or on your own — and the alert dismisses itself; submitting a new prompt in the session clears it too. No stale ✅ pile-up in the corner or in Notification Center. The watcher behind it lives only as long as the notification does (it exits on clear, on click, or at the timeout). Opt out with `GHOSTTY_NOTIFY_CLEAR_ON_FOCUS=0`.
- **No accessibility permission, ever.** Uses Ghostty's native AppleScript `select tab`, not simulated keystrokes.
- **Multi-session & resume-proof.** State is keyed by `session_id`, stable across `--resume`.
- **Says which session.** The subtitle leads with the session's title — the `session_title` hook field when present, else the transcript's last `custom-title` record (`/rename`, by hand or via a rename plugin), else its last auto-generated `ai-title` record — so five sessions in one folder produce distinguishable notifications. That's the same precedence the `--resume` picker uses.
- **Hardened for real use.** Interrupt/crash re-arm, unscriptable-Ghostty and tmux degradation, a serialized marker round-trip, fail-closed config, and injection-safe AppleScript — each regression-tested and gated by CI.
- **Yours to keep.** A handful of small bash hooks — no daemon, no Node, no telemetry — immune to Claude Code and plugin updates.

Notifications fire on completion (`Stop`). Permission/input prompts are silent by default; set `GHOSTTY_NOTIFY_ON_PROMPT=1` to also get an immediate ping when Claude blocks on a prompt in a background tab (recommended if you don't run bypass-permissions mode).

---

## Install

### 1. Dependencies

```bash
brew install jq alerter
```

- **jq** — parses the JSON Claude Code passes to hooks
- **alerter** — persistent macOS notifications with action buttons (clicks aren't reliable on stock `terminal-notifier` banners)

### 2. Plugin

Inside Claude Code:

```
/plugin marketplace add Davie521/claude-ghostty-notify
/plugin install claude-ghostty-notify
```

Hooks are auto-registered via the plugin manifest — **no manual `settings.json` edits needed.**

### 3. One macOS setting

**System Settings → Notifications → Alert Style → Persistent**, for **both** the **Script Editor** and **Terminal** entries (whichever exist on your machine). With the [native agent](#5-optional-the-native-agent) installed, the entry to change is **Claude Ghostty Notify** instead — the agent detects the wrong setting and offers to open that pane for you.

> Which bundle delivers the notification depends on your alerter version: legacy alerter (≤1.x, ObjC) borrows the Script Editor bundle, while alerter 26.x (the Swift rewrite) defaults to `com.apple.Terminal` — its `--help` documents `--sender ... (default: com.apple.Terminal)`. Setting both is harmless and covers either version. **Persistent** keeps the notification on screen and shows the **Go to tab** button directly; Banner style auto-hides and tucks the button behind a "Show" chevron, where clicks won't reliably trigger.

### 4. Restart Claude Code

Quit and relaunch so the new hooks load. Default thresholds (3 min / 10 min / 20 min timeout) work out of the box — see [Configuration](#configuration) to tune them.

### 5. Optional: the native agent

Everything above works on its own. The agent replaces the delivery path with a
single resident app, and is worth installing if you keep several sessions going:

```bash
bash scripts/build-agent.sh     # needs a Swift toolchain (xcode-select --install)
bash scripts/install-agent.sh   # builds a LaunchAgent and asks for permission
```

What changes:

- **One process instead of one per notification.** The shell path spawns a
  watcher per alert that wakes once a second until you come back. The agent
  subscribes to app-activation events, so between notifications it does nothing
  at all.
- **Exact withdrawal.** It posts through `UNUserNotificationCenter` and removes
  notifications by identifier, so a repeat notification for a session replaces
  the previous one rather than stacking.
- **A menu bar item** that counts the sessions waiting on you and lists them —
  each row repeating that session's notification verbatim, and jumping to its tab
  when clicked. Under the Temporary alert style, where the notification itself
  slides away before it can be clicked, this is the only way back. It also shows
  whether the agent is authorized and which alert style macOS has it on, because
  a background agent that cannot display anything otherwise looks exactly like
  one that is working.

Install asks for two permissions, both one-time: notifications, and controlling
Ghostty (needed for click-to-jump). Answer both.

> **Say yes to the notification prompt.** Declining is permanent for that build
> — macOS leaves no System Settings entry to undo it, and the only recovery is a
> new bundle identifier.

Remove it with `bash scripts/install-agent.sh --uninstall`; the hooks fall back
to the shell path on their own.

### Manual install (without the plugin system)

```bash
git clone https://github.com/Davie521/claude-ghostty-notify.git
cd claude-ghostty-notify
./install.sh
```

It copies the hooks to `~/.claude/hooks/` and prints a `settings.json` snippet to merge. See [example-settings.json](./example-settings.json) for the exact JSON.

## Configuration

All thresholds are environment variables in your `settings.json` `env` block. Restart Claude Code for changes to take effect.

| Variable | Default | What it means |
|---|---:|---|
| `GHOSTTY_NOTIFY_MIN_ELAPSED`   | `180`  | Below this (3 min): **silent** — no notification at all |
| `GHOSTTY_NOTIFY_SOUND_ELAPSED` | `600`  | Below this (10 min) but above MIN: notification **without** sound |
| `GHOSTTY_NOTIFY_TIMEOUT`       | `1200` | How long the notification stays on screen before auto-dismissing (20 min) |
| `GHOSTTY_NOTIFY_BACKEND`       | `auto` | `auto` (alerter then terminal-notifier) or `terminal-notifier` (force). Set to `terminal-notifier` if alerter notifications never appear — see Troubleshooting. The terminal-notifier backend never wires click-to-jump (its `-execute` fires on dismiss too), and a forced-but-missing alerter degrades to terminal-notifier instead of silently dropping the notification. |
| `GHOSTTY_NOTIFY_ON_PROMPT`     | `0`    | Set to `1` to also alert (immediately, with Ping sound) on `Notification` events — permission / input prompts. Recommended if you do NOT run bypass-permissions mode. |
| `GHOSTTY_NOTIFY_CLEAR_ON_FOCUS` | `1`   | Auto-dismiss the notification once you focus the session's Ghostty tab — and on your next prompt in that session. When the tab is unknown (tmux, unscriptable Ghostty) it degrades to "Ghostty becomes frontmost again". Turn it off with `0`, `false`, `no`, or `off`; any other value leaves it on. |
| `GHOSTTY_NOTIFY_FOCUS_POLL`    | `1`    | Clear-on-focus poll interval in seconds (decimals allowed). `0` would spin the watcher, so it falls back to the default. Ignored when the native agent is delivering — it has no poll. |
| `GHOSTTY_NOTIFY_AGENT_APP`     | *(discovered)* | Path to the agent bundle. Set it **empty** to pin the shell path and ignore an installed agent. Unset means "use it if it is there"; a path that is not an executable bundle is refused rather than trusted. |
| `GHOSTTY_NOTIFY_MENU_BAR`      | `1`    | The agent's menu bar item. `0`, `false`, `no` or `off` hides it — at the cost of losing the waiting-session count, the list that jumps to them, and the only visible sign that the agent is alive and permitted. |

Values must be plain integers (seconds); anything else falls back to the default (`GHOSTTY_NOTIFY_FOCUS_POLL` also accepts decimals).

Example — notify on tasks over 30 seconds, sound past 5 minutes, persist 20 minutes:

```json
"env": {
  "GHOSTTY_NOTIFY_MIN_ELAPSED": "30",
  "GHOSTTY_NOTIFY_SOUND_ELAPSED": "300",
  "GHOSTTY_NOTIFY_TIMEOUT": "1200"
}
```

## Troubleshooting

### I don't see any notifications

1. Did you change Script Editor **and Terminal** to **Persistent** alert style? (Step 3 — which bundle delivers depends on your alerter version.)
2. Did you restart Claude Code after adding the env vars? (Step 4.)
3. Is macOS **Do Not Disturb / Focus** mode on? Turn it off and test again.
4. Check the hooks ran: `ls ~/.claude/notifications/ghostty-sessions/` — you should see a `<session_id>.json` and `.start` file for the current session.
5. **alerter notifications never appear (even though the script ran)** — the delivering bundle was never authorized for notifications in System Settings. `alerter` runs, exits cleanly, and macOS silently drops the visual. Fix by forcing the terminal-notifier backend (its bundle has its own authorization):

   ```json
   "env": {
     "GHOSTTY_NOTIFY_BACKEND": "terminal-notifier"
   }
   ```

### I see two notifications (one with Script Editor icon showing my assistant message text)

That's the `stop:desktop-notify` hook from [everything-claude-code](https://github.com/affaan-m/everything-claude-code) (ECC), which ships its own notifier and fights with this project. Disable just that one ECC hook (the rest of ECC keeps working):

```json
"env": {
  "ECC_DISABLED_HOOKS": "stop:desktop-notify"
}
```

### Click goes to Script Editor's "New Document" dialog, not Ghostty

You clicked the notification body, not the **Go to tab** button. `alerter` routes body clicks to its `--sender` app, and Script Editor's default on activation is the New Document dialog. Either always click **Go to tab** (preferred), or enable Ghostty notification permissions and add `--sender com.mitchellh.ghostty` to the script (Ghostty will then send its own `notify-on-command-finish-after` notifications, which may be noisy).

### It jumps to the wrong tab

1. You resumed the session (`--resume`) in a new tab; the saved tab id is stale. Fix: `rm ~/.claude/notifications/ghostty-sessions/<session_id>.json` and run any tool call to re-capture.
2. The tab that was running Claude was closed. Falls back to just activating Ghostty.

### The alerter process is hanging around after the notification

Mostly historical. `alerter` blocks until you click an action, it times out (`GHOSTTY_NOTIFY_TIMEOUT` seconds), or clear-on-focus reaps it when you focus the session's tab or submit a new prompt. If one still lingers (e.g. `GHOSTTY_NOTIFY_CLEAR_ON_FOCUS=0`): `pkill -f 'alerter.*ghostty-notify'`.

## How it works

```
┌──────────────────────────────────────────────────────────────┐
│ PreToolUse → ghostty-tab-save.sh          (once per session) │
│   OSC 2 marker in the tab title → AppleScript finds the tab  │
│   → saves {tab_id} to a per-session file                     │
└──────────────────────────────────────────────────────────────┘
┌──────────────────────────────────────────────────────────────┐
│ UserPromptSubmit → ghostty-round-reset.sh                    │
│   re-arms the round timer (survives Esc / crash)             │
└──────────────────────────────────────────────────────────────┘
┌──────────────────────────────────────────────────────────────┐
│ Stop → ghostty-notify.sh                                     │
│   elapsed ≥ MIN? → fire alerter with a "Go to tab" button    │
└──────────────────────────────────────────────────────────────┘
                          │  click "Go to tab"
                          ▼
┌──────────────────────────────────────────────────────────────┐
│ ghostty-tab-focus.sh                                         │
│   read {tab_id} → AppleScript select tab → jump to THE tab   │
└──────────────────────────────────────────────────────────────┘
┌──────────────────────────────────────────────────────────────┐
│ you focus the session's tab (or submit a new prompt)         │
│   → ghostty-notify-clear.sh dismisses the alert              │
└──────────────────────────────────────────────────────────────┘
```

**`ghostty-tab-save.sh` (every `PreToolUse`):** reads `session_id` / `cwd` from stdin; records a start timestamp; walks the process tree to find Claude's controlling TTY; verifies Ghostty is scriptable, then writes an OSC 2 escape with a session-unique marker into the tab title; asks Ghostty via AppleScript which tab now carries the marker; restores the original title (via `trap EXIT`); saves `{tab_id, cwd}`. The marker dance runs once per session, serialized under a lock so parallel tool calls can't race. If Ghostty can't be scripted or the marker can't round-trip (e.g. inside tmux), it backs off and the session degrades to activate-only.

**`ghostty-notify.sh` (on `Stop`, and on `Notification` when opted in):** computes elapsed seconds and exits silently below `MIN_ELAPSED`; otherwise resolves the session title (stdin `session_title` if the field exists, else the transcript's last `custom-title` record, else its last `ai-title` record) and fires `alerter` in a backgrounded subshell with an explicit **Go to tab** button (no sound below `SOUND_ELAPSED`). The subshell invokes the focus script only for the button or a body click (`@CONTENTCLICKED`) — dismiss and timeout do nothing. It records the blocking alerter's PID and spawns the clear-on-focus watcher (below). Clears the start file on Stop so the next round re-arms.

**`ghostty-round-reset.sh` (on `UserPromptSubmit`):** clears the round-start timestamp. The Stop hook can't do this when a round ends via interrupt (Esc/Ctrl-C) or a crash — without it, the stale timestamp would inflate the next round's elapsed time and fire a loud false "Finished after 20m" notification for a 10-second task. Also clears any still-visible notification for the session — a new prompt proves you're back at this tab.

**`ghostty-notify-clear.sh` (watcher, spawned per notification):** polls a cheap `lsappinfo` frontmost gate (no TCC permission), and only while Ghostty is frontmost asks Ghostty which tab is selected. The moment the session's tab is the selected tab of the frontmost window, it removes the delivered notification by group ID (`alerter --remove` / `terminal-notifier -remove`) and kills the blocking `alerter` — a killed alerter yields no action output, which the dispatch whitelist already ignores, so clearing can never fire a phantom tab-jump. Unknown tab (tmux, unscriptable Ghostty) degrades to "Ghostty becomes frontmost", rising-edge only so an alert fired while you sat in a different Ghostty tab isn't cleared before you've seen it. The watcher exits when the alerter concludes on its own, when a newer watcher supersedes it, or at `NOTIFY_TIMEOUT` plus grace.

**`ghostty-tab-focus.sh` (on click):** activates Ghostty, reads `tab_id` from the session file, and uses Ghostty's native AppleScript `select tab` command — a real verb in the sdef, not a property write, so no accessibility permission is needed.

**With the [native agent](#5-optional-the-native-agent) installed,** the last three of those collapse into one resident process. `ghostty-notify.sh` still decides *whether* and *what* to notify, then hands the request to the agent through a spool directory (one JSON file per request, published by rename) instead of firing `alerter`. The agent posts through `UNUserNotificationCenter`, withdraws on a `NSWorkspace` activation event rather than a poll, and answers clicks itself — so no watcher is spawned, nothing wakes on a timer, and `ghostty-notify-clear.sh` never runs. The agent refuses the request when macOS has not authorized it, which is what sends the hook back to `alerter` rather than dropping the notification silently.

### Design notes

- **Why `session_id` and not `$PPID`?** Claude Code spawns intermediate shells with non-deterministic PIDs between hook invocations. `session_id` (from hook stdin JSON) is stable across the whole conversation, including `--resume`.
- **Why an OSC 2 marker and not `cwd` matching?** Two sessions in the same folder share a `cwd`. The marker is a unique per-session signal that nails the exact tab regardless.
- **Why `alerter` and not `terminal-notifier`?** On modern macOS, Banner-style notifications silently drop `-execute` clicks. `alerter` is alert-style by design with explicit action buttons, which work reliably.

## Uninstall

**Plugin install:** `/plugin uninstall claude-ghostty-notify` — hooks are automatically deregistered.

**Native agent** (if you installed it): `bash scripts/install-agent.sh --uninstall`, then `rm -rf ~/.claude/notifications/ghostty-agent`. Revoking its notification permission is a separate step in System Settings → Notifications.

**Manual install:**

```bash
rm -f ~/.claude/hooks/ghostty-tab-save.sh \
      ~/.claude/hooks/ghostty-tab-focus.sh \
      ~/.claude/hooks/ghostty-notify.sh \
      ~/.claude/hooks/ghostty-round-reset.sh \
      ~/.claude/hooks/ghostty-notify-clear.sh \
      ~/.claude/hooks/ghostty-agent-anchor.sh \
      ~/.claude/hooks/agent-common.sh
rm -rf ~/.claude/notifications/ghostty-sessions
rm -f ~/.claude/notifications/state/ghostty-notify-*
```

Then remove the `env` and `hooks` entries from `~/.claude/settings.json`.

## Limitations

- **macOS only** — depends on Ghostty's AppleScript dictionary and macOS notification APIs.
- **Ghostty only** — the tab-identification trick is Ghostty-specific.
- **Session must have started in Ghostty** — if Claude's controlling TTY isn't a Ghostty surface, the hooks exit silently.
- **Tab closed after save** — clicking the notification falls back to just activating Ghostty.
- **Ghostty must be scriptable** — needs Ghostty ≥ 1.3 (AppleScript support) and the macOS Automation permission. If either is missing, the hooks detect it once, back off for a day, and degrade to activate-only. Same for `claude` inside tmux (OSC 2 retitles the tmux pane, not the Ghostty tab): after 3 failed attempts the session degrades to activate-only.

## Credits

Inspired by the existing Claude Code notification ecosystem, especially the TTY-marker idea discussed in [kovoor/claude-code-notifier](https://github.com/kovoor/claude-code-notifier).

## License

[MIT](./LICENSE).
