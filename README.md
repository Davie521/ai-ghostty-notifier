# claude-ghostty-notify

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

## Codex CLI too

Codex CLI running in Ghostty gets the same notification, **Go to tab** jump and
clear-on-return, titled **Codex ✅**. Codex CLI 0.153+ has native lifecycle
hooks whose payload matches Claude Code's, so it runs the very same scripts
through a small adapter. From this checkout (Python 3.11+ for the installer
only):

```bash
python3 scripts/install-codex.py
```

Then start `codex` in Ghostty and run **`/hooks`** once to trust the two
`ghostty-notify` entries (`UserPromptSubmit`, `Stop`) — Codex reviews every
hook entry it has not seen before. Sessions that were already open pick the
hooks up after a restart.

The installer copies the scripts to `~/.codex/ghostty-notify/` (moving the
checkout breaks nothing), adds the two entries to `~/.codex/hooks.json` next
to any hooks you already have, and backs up every file it changes under
`~/.codex/backups/`. `CODEX_HOME` is honoured. State lives apart from
Claude's, in `~/.codex/notifications/`.

- **Timing starts at the prompt.** Codex can spend minutes on reasoning or
  hosted tools before any local command, so unlike Claude's hooks the round
  is timed from `UserPromptSubmit`, not from the first tool call. Turn
  boundaries Codex runs straight through — `/goal` continuations, a queued
  follow-up — are recognised from the session's rollout and neither alert
  nor reset the clock.
- **The tab is bound right after the turn ends.** The Codex TUI animates the
  tab title while it works, so the marker round-trip Claude does mid-round
  cannot succeed there; the Stop hook hands off to a detached process that
  waits about 1.5 s for the title to hold still, binds the tab (retrying
  through Codex's thread-title animation), then delivers. Alerts arrive one
  to two seconds after the turn ends; the "Finished after" figure is exact.
- **Settings** live in `~/.codex/ghostty-notify/config.json`: on first
  install every `GHOSTTY_NOTIFY_*` preference from Claude's `settings.json`
  is copied there (else 180 / 600 / 1200 s), and any knob the scripts read —
  thresholds, `GHOSTTY_NOTIFY_BACKEND`, `GHOSTTY_NOTIFY_AGENT_APP`, … — can be
  set in that file. Environment variables win over it.
- **Session title:** the thread name Codex stores, otherwise the first prompt
  of the session.
- **Only terminal sessions notify.** The same `hooks.json` also fires for Codex
  Desktop threads and for `codex mcp-server` processes other agents spawn;
  none of those has a tab to return to, so they are skipped.
- **The native agent serves Codex too.** With the
  [agent](#5-the-native-agent) installed, Codex alerts are posted by
  it as well — the same click that always reaches the right process, exact
  withdrawal and menu bar list as Claude's — and a new prompt withdraws through
  it just as Claude's does. Set `GHOSTTY_NOTIFY_AGENT_APP` to an empty string
  in `config.json` to keep Codex on the shell path.
- **Codex's own TUI alert** for a finished turn is turned off so it does not
  double ours: `[tui] notifications` becomes `["approval-requested",
  "plan-mode-prompt"]`, so approval and plan-mode questions still surface.
  Turns shorter than the threshold therefore produce no alert at all.
- **Re-running the installer keeps your trust.** Codex ties trust to each
  entry's position and definition in `hooks.json`; the installer updates its
  entries in place, and script updates never need re-trusting. If removing a
  retired entry had to move one of your own hooks, it says so.
- **Upgrading from the `notify` callback** of earlier versions: the installer
  removes that `notify` entry — including when Codex Desktop's Computer Use has
  wrapped it with `--previous-notify`, which delayed every alert by two minutes
  — and keeps the wrapper's own part, and drops the `PreToolUse` entry.

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
- **Clicks that actually work.** A small resident app posts every notification under its own identity and answers the click itself, so the click reaches the one process that knows which tab this session lives in.
- **Clears itself when you arrive.** Focus the session's tab — via the notification or on your own — and the alert dismisses itself; submitting a new prompt in the session clears it too. No stale ✅ pile-up in the corner or in Notification Center. Opt out with `GHOSTTY_NOTIFY_CLEAR_ON_FOCUS=0`.
- **No accessibility permission, ever.** Uses Ghostty's native AppleScript `select tab`, not simulated keystrokes.
- **Multi-session & resume-proof.** State is keyed by `session_id`, stable across `--resume`.
- **Says which session.** The subtitle leads with the session's title — the `session_title` hook field when present, else the transcript's last `custom-title` record (`/rename`, by hand or via a rename plugin), else its last auto-generated `ai-title` record — so five sessions in one folder produce distinguishable notifications. That's the same precedence the `--resume` picker uses.
- **Hardened for real use.** Interrupt/crash re-arm, unscriptable-Ghostty and tmux degradation, a serialized marker round-trip, fail-closed config, and injection-safe AppleScript — each regression-tested and gated by CI.
- **Yours to keep.** A handful of small bash hooks plus one idle accessory app you build yourself — no Node, no telemetry — immune to Claude Code and plugin updates.

Notifications fire on completion (`Stop`). Permission/input prompts are silent by default; set `GHOSTTY_NOTIFY_ON_PROMPT=1` to also get an immediate ping when Claude blocks on a prompt in a background tab (recommended if you don't run bypass-permissions mode).

---

## Install

### 1. Dependencies

```bash
brew install jq
xcode-select --install     # Swift toolchain, for the notification agent
```

- **jq** — parses the JSON Claude Code passes to hooks
- **a Swift toolchain** — builds the notification agent in [step 5](#5-the-native-agent), which is what delivers the notification and answers the click
- **terminal-notifier** (optional, `brew install terminal-notifier`) — a fallback that shows the alert on machines where the agent cannot run. It has no click-to-jump: it fires its action on a dismiss too, with no way to tell the two apart.

### 2. Plugin

Inside Claude Code:

```
/plugin marketplace add Davie521/claude-ghostty-notify
/plugin install claude-ghostty-notify
```

Hooks are auto-registered via the plugin manifest — **no manual `settings.json` edits needed.**

### 3. One macOS setting

**System Settings → Notifications → Claude Ghostty Notify → Alert Style → Persistent.**

The entry appears once the agent has asked for permission in step 5, and the
agent itself detects the wrong setting and offers to open that pane for you.

> **Persistent** keeps the notification on screen until you deal with it, and
> shows the **Go to tab** button directly. Banner style auto-hides after a few
> seconds and tucks the button behind a "Show" chevron, so the jump is only
> reachable from Notification Center or the menu bar item.

### 4. Restart Claude Code

Quit and relaunch so the new hooks load. Default thresholds (3 min / 10 min / 20 min timeout) work out of the box — see [Configuration](#configuration) to tune them.

### 5. The native agent

This is what turns a notification into a jump back to the tab. Build it once:

```bash
bash scripts/build-agent.sh     # needs a Swift toolchain (xcode-select --install)
bash scripts/install-agent.sh   # copies the app into place, installs a LaunchAgent, asks for permission
```

The install copies the bundle to `~/Library/Application Support/claude-ghostty-notify/`
and points the LaunchAgent at that copy, so the checkout can move or go — a
LaunchAgent aimed into a repository stops silently the day the repository is
renamed. Rerun the install after every rebuild. Codex sessions use the same
agent (see [above](#codex-cli-too)).

What it gives you:

- **Clicks that land.** It owns its bundle identity, so macOS delivers the
  click to the process that knows this session's tab. (The `alerter` backend
  this replaced posted as `com.apple.Terminal`, shared by every alerter
  process on the machine; macOS handed a click to an arbitrary one, which
  dropped it. With several sessions running that was a good share of all
  clicks, which is why the shell path no longer offers a jump at all.)
- **One idle process.** It subscribes to app-activation events, so between
  notifications it does nothing — no polling, and nothing spawned per alert.
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
Ghostty (needed for click-to-jump). Answer both. If you use Focus modes, allow
**Claude Ghostty Notify** in them as well, or its alerts go straight to
Notification Center without a sound or a banner.

> **Say yes to the notification prompt.** Declining is permanent for that build
> — macOS leaves no System Settings entry to undo it, and the only recovery is a
> new bundle identifier.

Remove it with `bash scripts/install-agent.sh --uninstall` (LaunchAgent and the
installed copy). The hooks then fall back to `terminal-notifier`, which shows
the alert but cannot jump.

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
| `GHOSTTY_NOTIFY_BACKEND`       | `auto` | `auto` / `agent` (the agent, falling back to `terminal-notifier` when it cannot display) or `terminal-notifier` (skip the agent). The fallback never wires click-to-jump: its action fires on a dismiss too, with no way to tell them apart. |
| `GHOSTTY_NOTIFY_ON_PROMPT`     | `0`    | Set to `1` to also alert (immediately, with Ping sound) on `Notification` events — permission / input prompts. Recommended if you do NOT run bypass-permissions mode. |
| `GHOSTTY_NOTIFY_CLEAR_ON_FOCUS` | `1`   | Auto-dismiss the notification once you focus the session's Ghostty tab — and on your next prompt in that session. When the tab is unknown (tmux, unscriptable Ghostty) it degrades to "Ghostty becomes frontmost again". On the `terminal-notifier` fallback only the next prompt clears it. Turn it off with `0`, `false`, `no`, or `off`; any other value leaves it on. |
| `GHOSTTY_NOTIFY_AGENT_APP`     | *(discovered)* | Path to the agent bundle. Set it **empty** to pin the shell path and ignore an installed agent. Unset means "use it if it is there" — the installed copy under `~/Library/Application Support/claude-ghostty-notify/` first; a path that is not an executable bundle is refused rather than trusted. Codex reads it from `~/.codex/ghostty-notify/config.json`. |
| `GHOSTTY_NOTIFY_MENU_BAR`      | `1`    | The agent's menu bar item. `0`, `false`, `no` or `off` hides it — at the cost of losing the waiting-session count, the list that jumps to them, and the only visible sign that the agent is alive and permitted. |

Values must be plain integers (seconds); anything else falls back to the default.

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

1. Did you set **Claude Ghostty Notify** to **Persistent** alert style? (Step 3.) Is the agent running — `launchctl print gui/$(id -u)/io.github.davie521.cgnotify`?
2. Did you restart Claude Code after adding the env vars? (Step 4.)
3. Is macOS **Do Not Disturb / Focus** mode on? A Focus delivers everything it does not explicitly allow straight to Notification Center, silently — the agent's log still says "posted" and `usernoted` still says "Presenting". Turn it off, or add **Claude Ghostty Notify** to that Focus's allowed apps.
4. Check the hooks ran: `ls ~/.claude/notifications/ghostty-sessions/` — you should see a `<session_id>.json` and `.start` file for the current session.
5. Check the agent's own account of itself: `~/.claude/notifications/ghostty-agent/agent.log` says whether it started, whether macOS authorized it, and what it posted. The menu bar item shows the same thing at a glance.

### I see two notifications (the second one repeating my assistant message)

That's the `stop:desktop-notify` hook from [everything-claude-code](https://github.com/affaan-m/everything-claude-code) (ECC), which ships its own notifier and fights with this project. Disable just that one ECC hook (the rest of ECC keeps working):

```json
"env": {
  "ECC_DISABLED_HOOKS": "stop:desktop-notify"
}
```

### Clicking the notification does nothing

Only the native agent can route a click. Without it the hooks fall back to
`terminal-notifier`, which fires its action on a dismiss too — so the project
deliberately wires no click there at all. Install the agent ([step 5](#5-the-native-agent)).

### It jumps to the wrong tab

1. You resumed the session (`--resume`) in a new tab; the saved tab id is stale. Fix: `rm ~/.claude/notifications/ghostty-sessions/<session_id>.json` and run any tool call to re-capture.
2. The tab that was running Claude was closed. Falls back to just activating Ghostty.
3. Ghostty was restarted while the session kept running (tab ids only mean something inside one Ghostty process). The binding is re-resolved on the session's next tool call — for Codex, at the end of its next turn — so only a click before that lands on "activate Ghostty".

## How it works

```
┌──────────────────────────────────────────────────────────────┐
│ PreToolUse → ghostty-tab-save.sh          (once per session) │
│   OSC 2 marker in the tab title → AppleScript finds the tab  │
│   → saves {tab_id, ghostty_pid} to a per-session file        │
└──────────────────────────────────────────────────────────────┘
┌──────────────────────────────────────────────────────────────┐
│ UserPromptSubmit → ghostty-round-reset.sh                    │
│   re-arms the round timer (survives Esc / crash)             │
│                  → ghostty-agent-anchor.sh                   │
│   tells the agent this session's tab, and to withdraw        │
└──────────────────────────────────────────────────────────────┘
┌──────────────────────────────────────────────────────────────┐
│ Stop → ghostty-notify.sh                                     │
│   elapsed ≥ MIN? → one JSON file into the agent's spool      │
└──────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────────────┐
│ ClaudeGhosttyNotify.app (resident)                           │
│   posts it · answers the click by selecting {tab_id}         │
│   · withdraws it when that tab comes forward                 │
└──────────────────────────────────────────────────────────────┘
```

**`ghostty-tab-save.sh` (every `PreToolUse`):** reads `session_id` / `cwd` from stdin; records a start timestamp; walks the process tree to find Claude's controlling TTY; verifies Ghostty is scriptable, then writes an OSC 2 escape with a session-unique marker into the tab title; asks Ghostty via AppleScript which tab now carries the marker; restores the original title (via `trap EXIT`); saves `{tab_id, cwd, ghostty_pid}`. The marker dance runs once per session, serialized under a lock so parallel tool calls can't race, and once more after Ghostty restarts — tab ids only mean something inside one Ghostty process. If Ghostty can't be scripted or the marker can't round-trip (e.g. inside tmux), it backs off and the session degrades to activate-only.

**`ghostty-notify.sh` (on `Stop`, and on `Notification` when opted in):** computes elapsed seconds and exits silently below `MIN_ELAPSED`; otherwise resolves the session title (stdin `session_title` if the field exists, else the transcript's last `custom-title` record, else its last `ai-title` record) and hands title, subtitle, body, sound, timeout and the resolved `tab_id` to the agent as one JSON file in its spool directory, published by rename. Clears the start file on Stop so the next round re-arms. If the agent is not installed, not running or not authorized, it degrades visibly to `terminal-notifier` instead of dropping the notification.

**`ghostty-round-reset.sh` (on `UserPromptSubmit`):** clears the round-start timestamp. The Stop hook can't do this when a round ends via interrupt (Esc/Ctrl-C) or a crash — without it, the stale timestamp would inflate the next round's elapsed time and fire a loud false "Finished after 20m" notification for a 10-second task. It also asks `ghostty-notify-clear.sh` to take down a still-visible fallback notification, since a new prompt proves you're back at this tab.

**`ghostty-agent-anchor.sh` (on `UserPromptSubmit`):** tells the agent which tab the session lives in, then asks it to withdraw anything still on screen for that session. Anchoring from the file the marker round-trip wrote beats the agent sampling whatever is focused when it drains the request.

**`ghostty-notify-clear.sh`:** the fallback's half of clear-on-arrival. `terminal-notifier -remove` on the session's group, guarded so a notification delivered after the clear was requested survives. Nothing polls and nothing is spawned.

**The agent (`ClaudeGhosttyNotify.app`):** a resident accessory app, started by a LaunchAgent, that drains the spool. It posts through `UNUserNotificationCenter` with one stable identifier per session, so a repeat notification replaces rather than stacks; answers a click by selecting the session's tab through Ghostty's native AppleScript `select tab` (a real verb in the sdef, not a property write, so no accessibility permission); withdraws a session's notification when Ghostty comes forward with that tab selected, on an `NSWorkspace` activation event rather than a poll; and carries a menu bar item listing the sessions waiting on you.

### Design notes

- **Why `session_id` and not `$PPID`?** Claude Code spawns intermediate shells with non-deterministic PIDs between hook invocations. `session_id` (from hook stdin JSON) is stable across the whole conversation, including `--resume`.
- **Why an OSC 2 marker and not `cwd` matching?** Two sessions in the same folder share a `cwd`. The marker is a unique per-session signal that nails the exact tab regardless.
- **Why a resident app and not `alerter`?** Every `alerter` process posts as `com.apple.Terminal`, an identity shared by every other alerter on the machine, and macOS hands a click to an arbitrary one of them; the process that did not post it drops the click, and the one that did is only told the notification went away. With several sessions the jump became a coin flip, so the alerter backend is gone. The agent posts under its own bundle identity and answers its own clicks.
- **Why `terminal-notifier` is still there.** It needs no toolchain, so a machine that cannot build the agent still SEES that the round finished. It cannot route a click — its action fires on a dismiss too — so the project wires none.

## Uninstall

**Plugin install:** `/plugin uninstall claude-ghostty-notify` — hooks are automatically deregistered.

**Native agent** (if you installed it): `bash scripts/install-agent.sh --uninstall` removes the LaunchAgent and the copy under `~/Library/Application Support/claude-ghostty-notify/`; then `rm -rf ~/.claude/notifications/ghostty-agent`. Revoking its notification permission is a separate step in System Settings → Notifications.

**Manual install:**

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

Then remove the `env` and `hooks` entries from `~/.claude/settings.json`.

**Codex CLI** (`~/.codex` below is `$CODEX_HOME` if you set one):

1. Delete the entries whose command contains `ghostty-notify/codex-hook.sh`
   from `~/.codex/hooks.json`, then **restart every open Codex session** —
   a running session keeps its hook list and would report a failed hook on
   each prompt and turn once the script is gone.
2. `rm -rf ~/.codex/ghostty-notify ~/.codex/notifications`.
3. Optional tidy-up in `~/.codex/config.toml`: the `[hooks.state."…hooks.json:
   user_prompt_submit:0:0"]` / `…stop:0:0` trust records, and `[tui]
   notifications` back to `true` if you want Codex's own turn-complete alert
   again. Backups of the files the installer changed are in
   `~/.codex/backups/`.

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
