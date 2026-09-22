# Reference

Everything the [README](../README.md) leaves out: the manual install, the exact
behavior, every setting, how it works, troubleshooting, the test suites and uninstall.
The quickest install is to hand [agent-install.md](agent-install.md) to a coding
agent; this file is the same ground, written for a person.

## Manual install


The companion **ClaudeGhosttyNotify.app is required**. Its Swift executable
handles hook input, terminal binding, notification policy and fallback delivery.
The shell files are only stable launchers; hooks need neither jq nor Python.
The resident process does not have to stay running, but the app must remain
installed.

One command does steps 1–3 below from the current [release](releasing.md), a
signed and notarized build, with no clone and no Swift toolchain. It is the
path [agent-install.md](agent-install.md) tries first:

```bash
curl -fsSL https://github.com/Davie521/ai-ghostty-notifier/releases/latest/download/setup.sh | bash
```

With more than one Claude configuration directory, run it once more for each
of the others, with `CLAUDE_CONFIG_DIR=<dir>` in front of `bash` and
`--claude --no-codex` after `bash -s --`.

### 1. Build and install the required app

Use macOS with Ghostty's AppleScript support and a Swift 6 toolchain. Build from
a checkout containing the native hooks:

```bash
bash scripts/build-agent.sh --build-only
bash scripts/install-agent.sh
```

The first command only builds and signs the checkout's app. The second
**installs or replaces the app and restarts its service**, registers a LaunchAgent
and opens the notification-permission flow. Do not use the install command when
you only want to test a build.

Upgrading while sessions are in use is fine. Before it stops the previous
version, the installer takes the execute bit off the installed binary and leaves
a marker beside it, so that a hook firing in those seconds cannot start a process
of the old version that would outlive the replacement. Hooks registered from a
checkout or a plugin honour the marker too, rather than starting the build beside
them. Until the new copy is in place, usually a second or two and at most about a minute, hooks do nothing:
a notification due in that window is not shown. The previous version is replaced
only once none of its processes is left. If that cannot be confirmed, or the
install fails or is interrupted, the bit goes back on, its LaunchAgent is loaded
again and the previous version keeps working. Only `kill -9` on the installer
can leave the way in shut; rerun the installer to put that right.

The app is copied to
`~/Library/Application Support/claude-ghostty-notify/ClaudeGhosttyNotify.app`.
Both hook entrypoints and launchd use this durable location, so moving the source
checkout does not break them. Building alone does not update that installed copy.

### 2. Register Claude Code hooks

For this checkout, run:

```bash
bash install.sh --register-settings
```

It verifies that the native app is installed, copies the small launchers to
`<config>/hooks/` and merges their entries into `<config>/settings.json`, where
`<config>` is `$CLAUDE_CONFIG_DIR` when set and `~/.claude` otherwise. The
merge keeps everything else in the file, copies it aside first as
`settings.json.ghostty-notify-backup-<time>`, adds nothing to an event that
already runs one of these launchers, and writes nothing when the file does not
parse or when the plugin is enabled. With more than one configuration
directory, run it once per directory with `CLAUDE_CONFIG_DIR` set. Without
`--register-settings` it only prints the snippet to merge by hand;
[example-settings.json](../example-settings.json) contains the complete example.

Alternatively, a plugin containing this same native-hook revision auto-registers
the hooks through [hooks/hooks.json](../hooks/hooks.json). Install the app first,
then register the plugin in Claude Code:

```text
/plugin marketplace add Davie521/ai-ghostty-notifier
/plugin install ai-ghostty-notifier@ai-ghostty-notifier
```

Choose manual or plugin registration, not both. During worktree testing use the
local manual install, since the published marketplace may still contain older
hooks.

### 3. Register Codex CLI hooks, if used

For a Codex CLI with lifecycle hooks, run from the same checkout:

```bash
python3 scripts/install-codex.py
```

Python 3.11+ is needed **only for this installer**. It copies launchers into
`~/.codex/ghostty-notify/`, adds `UserPromptSubmit` and `Stop` entries to
`~/.codex/hooks.json`, and preserves unrelated settings/hooks. `CODEX_HOME`
is supported. Start Codex in Ghostty and use `/hooks` to trust new entries.

Re-running the installer preserves existing hook definitions and positions where
possible. If retiring an old entry moves another hook's trust position, the
installer reports it. It also removes this project's old `notify` callback,
including a recognized `--previous-notify` wrapper, while keeping the wrapper's
own callback. Changed existing config files receive private backups under
`~/.codex/backups/`.

The installer narrows Codex's built-in TUI notifications to
`["approval-requested", "plan-mode-prompt"]` when needed, avoiding duplicate
turn-complete alerts while keeping those prompts.

### 4. Permissions and restart

Allow notifications and, when requested, Automation control of Ghostty.
In **System Settings → Notifications → AI Ghostty Notifier**, choose
**Persistent** if you want the alert and its action to remain visible.
Allow the app in any Focus modes you use. External notification backends require
their own notification authorization.

Restart open Claude/Codex sessions to load their hook registrations and settings.
The app's menu bar item shows authorization and alert-style status — a problem
System Settings can fix links straight to it — and lists the sessions waiting
on you; click one to jump to its tab.

### Runtime-only installation (no resident service)

The app is required; keeping its resident process running is optional:

```bash
bash scripts/build-agent.sh --build-only
bash scripts/install-agent.sh --no-start
```

This copies and verifies the app without starting a LaunchAgent, registering
with LaunchServices or opening permission prompts. It refuses an existing
LaunchAgent installation or a live resident (including a manually started app);
use the normal installer to upgrade either safely.

Install `terminal-notifier` for display-only fallback when the resident is not
ready or authorized: `brew install terminal-notifier`. It has no click-to-jump,
focus watcher or expiry timer; a new prompt clears its notification. Set
`GHOSTTY_NOTIFY_AGENT_APP` to an empty string in hook settings to prevent
automatic resident routing/launch. Hook processing and the temporary worker are
still **Swift**, not a shell fallback. With neither an available resident nor an
external notification backend, the hook cannot display notifications.

### Upgrade from the shell-based version

Build and install the new app **before** updating hook registrations/files.
Then rerun the appropriate hook installer (or update a matching plugin) and
restart open CLI sessions. Stable launcher filenames preserve hook trust;
round/rate records and older agent state remain readable.

Missing or old app bundles cause hook installers to fail before copying hooks.
At runtime a missing app produces a diagnostic, drains stdin and exits
successfully to avoid blocking the CLI, but sends no notification.
Uninstalling the app no longer activates a complete shell implementation.

Private `GHOSTTY_NOTIFY_FOCUS_SCRIPT` and `GHOSTTY_NOTIFY_CLEAR_SCRIPT`
overrides are retired; focus and clearing are native operations. Old helper
files may remain in upgraded directories but are not invoked or reinstalled.

## Behavior

| Task duration | Notification |
| --- | --- |
| Under 3 minutes | None |
| 3–10 minutes | Silent notification |
| 10 minutes or more | Notification with Glass sound |

Defaults are configurable ([every setting](#configuration)).
Resident notifications expire after 20 minutes unless cleared
earlier. Focusing the session's tab or submitting another prompt withdraws its
notification. Permission/input prompts are silent unless
`GHOSTTY_NOTIFY_ON_PROMPT=1`.

## Configuration

Claude reads environment variables from its `settings.json` `env` block.
Codex reads `~/.codex/ghostty-notify/config.json`; environment entries win,
**even when explicitly empty**. On first Codex installation, public notification
preferences are copied from Claude's settings when present. Source-specific
paths and private helper controls are not copied.

| Variable | Default | Meaning |
| --- | --- | --- |
| `GHOSTTY_NOTIFY_MIN_ELAPSED` | `180` | Minimum duration for a completion alert, seconds |
| `GHOSTTY_NOTIFY_SOUND_ELAPSED` | `600` | Minimum duration for Glass sound |
| `GHOSTTY_NOTIFY_TIMEOUT` | `1200` | Expiry in seconds; `0` disables automatic expiry |
| `GHOSTTY_NOTIFY_BACKEND` | `auto` | Ready resident first, then display-only terminal-notifier; explicit `terminal-notifier` skips resident delivery. `agent` behaves like `auto`; the retired `alerter` and unknown values behave like `terminal-notifier` |
| `GHOSTTY_NOTIFY_ON_PROMPT` | `0` | Only `1` enables immediate Claude permission/input alerts |
| `GHOSTTY_NOTIFY_CLEAR_ON_FOCUS` | `1` | `0`, `false`, `no`, `off` disable focus clearing |
| `GHOSTTY_NOTIFY_AGENT_APP` | discovered | Resident bundle path; empty disables resident use, not the required native runtime |
| `GHOSTTY_NOTIFY_NATIVE_APP` | installed app | Environment-only bootstrap override for the native executable's app; not read from Codex config |
| `GHOSTTY_NOTIFY_MENU_BAR` | `1` | Resident-process setting; false-like values hide its menu bar item |
| `GHOSTTY_NOTIFY_HOOK_DEADLINE` | `12` | Seconds before a hook process gives up and exits successfully; clamped to 1–120 |
| `GHOSTTY_NOTIFY_APP_NAME` | `Claude` | App name in Claude notifications; Codex is always `Codex` |
| `GHOSTTY_NOTIFY_GROUP_PREFIX` | `ghostty-notify` | Group prefix for external-backend delivery and removal; Codex defaults to `codex-ghostty-notify` |
| `GHOSTTY_NOTIFY_SESSION_DIR` | `<notifications>/ghostty-sessions` | Per-session state; `<notifications>` is `~/.claude/notifications` or `$CODEX_HOME/notifications` |
| `GHOSTTY_NOTIFY_RATE_DIR` | `<notifications>/state` | Rate-limit state, same base directory |
| `GHOSTTY_NOTIFY_TTY` | inspected | Terminal device override, a character device under `/dev/`. A Claude session with no terminal at all (a headless `claude -p`) is ignored unless this names one; a Codex session still needs a terminal CLI ancestor |
| `GHOSTTY_NOTIFY_CODEX_SETTLE` | `1.5` | Seconds Codex waits after Stop for its TUI title to settle before binding |
| `GHOSTTY_NOTIFY_MARKER_RETRY_DELAYS` | Codex `0.5 1 2 3`, Claude none | Whitespace-separated delays between tab-lookup retries, at most 8; explicit empty disables retries |
| `CODEX_HOME`, `CODEX_SQLITE_HOME` | `~/.codex`, `$CODEX_HOME` | Where Codex title and state lookup reads; SQLite is opened read-only |

A hook never holds the CLI for long: each terminal query is bounded, the hook
process ends itself at `GHOSTTY_NOTIFY_HOOK_DEADLINE`, and the shipped hook
entries set `"timeout": 15`. Keep that field if you write the entries by hand.
Without it Claude Code waits up to 600 seconds for a command hook, which is how
a stuck hook once looked like a hung session
([incident](incident-2026-09-17-pretooluse-hang.md)).

Elapsed/timeout settings accept nonnegative integers; missing, empty or invalid
values use their defaults. Empty means something different per setting: the
path and prefix settings fall back to their defaults, `GHOSTTY_NOTIFY_AGENT_APP`
disables resident delivery, and `GHOSTTY_NOTIFY_MARKER_RETRY_DELAYS` disables
retries. Relative paths resolve against the hook's working directory and `~/`
against the sender's HOME. Codex `config.json` only contributes
`GHOSTTY_NOTIFY_*` keys; null values are ignored, and a malformed file is
reported while the hook still exits successfully.

Settings from before the native runtime are ignored: `GHOSTTY_NOTIFY_ALERTER`,
`GHOSTTY_NOTIFY_FOCUS_POLL`, and the `GHOSTTY_NOTIFY_FOCUS_SCRIPT` /
`GHOSTTY_NOTIFY_CLEAR_SCRIPT` helper substitutions, which have no native
replacement and should be removed when upgrading.

For example, in Claude's settings:

```json
"env": {
  "GHOSTTY_NOTIFY_MIN_ELAPSED": "30",
  "GHOSTTY_NOTIFY_SOUND_ELAPSED": "300",
  "GHOSTTY_NOTIFY_TIMEOUT": "1200"
}
```

## How it works

What the notification is able to say, and how it finds the tab:

- Session identity, not the project folder, distinguishes tabs. An OSC 2 marker
  and an in-process AppleScript query capture the tab; binding is cached and
  invalidated when the owning CLI or Ghostty process changes.
- Claude titles prefer the hook's `session_title`, then the transcript's latest
  custom title, then its latest AI title. Codex prefers its stored thread name,
  then the session's first prompt.
- Claude timing starts at the first tool call after a prompt. Codex timing starts
  at the prompt, including reasoning and hosted-tool time. Recognized Codex
  rollout continuations do not notify or reset the timer.
- Codex binds after Stop, normally allowing 1.5 seconds for its animated TUI title
  to settle. Desktop and MCP-server processes without a terminal CLI owner are
  skipped.
- A Claude session with no terminal at all — a headless `claude -p` started by
  a server or a script — is skipped too, even when it inherited `TERM_PROGRAM`
  from something launched in Ghostty: it has no tab to notify about or jump to.
  `GHOSTTY_NOTIFY_TTY` names a terminal for a session that has none of its own.
- The resident app uses its own notification identity, exact per-session
  withdrawal, activation events and a menu bar list of waiting sessions.
  External backends are optional alternatives; their limitations are under
  [Troubleshooting and limits](#troubleshooting-and-limits).

```text
CLI hook → thin shell launcher → same Swift executable, --hook
                                  ├─ capture JSON / process / TTY / round
                                  ├─ ready resident: atomic event spool
                                  └─ otherwise: same executable, --worker
```

The hook process performs the ancestry-sensitive work. Claude's first tab binding
and title-restoration attempt finish before it returns. Typed native code owns
locking, retries, title parsing, rate limits, stale-event rejection and cleanup.
A newer prompt invalidates pending work for an older round.

The resident posts through `UNUserNotificationCenter`. A temporary native worker
can instead invoke an external backend with literal arguments. No runtime
business helper launches Bash, jq, ps, osascript, sleep or the sqlite3 CLI.
SQLite lookup uses its read-only C API. Build/install scripts can remain shell.

## Troubleshooting and limits

- **No notification:** check the required app exists, the minimum duration, hook
  registration/trust, notification permission and Focus settings. Native runtime
  diagnostics go to hook stderr; resident state/logs live under
  `~/.claude/notifications/ghostty-agent/`. Claude session records are under
  `~/.claude/notifications/ghostty-sessions/`; Codex uses its own
  `notifications/` directory.
- **Resident stopped:** normally the hook attempts an app launch and handles the
  current event in a native worker. External delivery still needs an installed,
  authorized backend. Explicit empty `AGENT_APP` disables the launch attempt.
- **Click only dismisses:** use resident delivery. alerter is retired, and
  terminal-notifier deliberately has no click-to-jump
  action, since its execute action can also run on dismissal.
- **Duplicate alerts:** check that manual and plugin hooks are not both
  registered, and disable other completion notifiers. For ECC's desktop notifier
  the existing opt-out is `ECC_DISABLED_HOOKS=stop:desktop-notify`.
- **No precise tab:** Ghostty must expose its AppleScript interface and permit
  Automation. tmux/title redraws can defeat the marker. Failed or ambiguous
  binding degrades to activation only, with retry/backoff; a closed tab cannot
  be reopened by clicking. Title restoration is best effort during terminal or
  Automation failures, not an unconditional guarantee.
- **Old notifications after an upgrade:** dismiss stale pre-upgrade notices and
  test a freshly posted one; macOS may no longer route the old sender identity.
- macOS/Ghostty only. Terminal CLI ownership is required for Codex notifications,
  and a terminal for Claude's.
  Tests do not replace manual checks of visible banners, sound and real tab jumps.

## Verification

Run in the checkout, without installing over a working app:

```bash
swift test --package-path agent --quiet
bash scripts/build-agent.sh --build-only
codesign --verify --deep --strict build/ClaudeGhosttyNotify.app
NATIVE_TEST_BINARY="$PWD/build/ClaudeGhosttyNotify.app/Contents/MacOS/ghostty-notify-agent" python3 -m unittest discover -s tests -p 'test_native_hooks.py'
python3 -m unittest discover -s tests -p 'test_native_install.py'
bash tests/test-agent.sh
```

### Builds and notification clicks

macOS resolves a click on a notification by bundle identifier, and
LaunchServices may pick any copy of the app it knows, not the installed one. It
gets to know a copy in two ways, both measured here: starting the agent from a
bundle registers it, and the registration outlives the process; and a bundle
that merely sits in a directory Spotlight indexes, a checkout on the Desktop
for instance, is registered within a minute without ever having run.
`lsregister -u` removes it for about that long. A copy inside a directory
named `*.noindex` was not picked up.

What a wrongly chosen copy does depends on the installed agent. Once the
installed agent has the single-instance lock, the copy finds the lock taken and
exits, and that click goes nowhere. An installed agent from before the lock
holds none: on 2026-09-20 a click started a build next to it, and two residents
drained one spool until the stray was stopped.

So do not keep a build around on a machine you use: delete `build/` when you
are done, or take the execute bit off its binary. `tests/test-agent.sh`
unregisters the build it ran, which helps only until the bundle is found
again.

The resident integration suite requires Aqua and test-only jq; it explicitly
reports SKIP without Aqua. Installation tests use private homes, the real signed
bundle and service-command tripwires. They do not install a LaunchAgent or test
the human permission flow. jq is not a production hook dependency.

Two further checks are opt-in, because they need a running Ghostty and CI has
none. Run them before deploying a build that touches Apple Events or native
process setup:

```bash
bash tests/test-live-binding.sh
python3 tests/test-live-worker.py
```

Open a new Ghostty tab for them, a plain shell with nothing drawing in it, and
run them there. From elsewhere, name that tab's terminal device, which `tty`
prints inside it: `GHOSTTY_NOTIFY_TTY=/dev/ttys012`. The first check sends
unbound `PreToolUse` hooks through the real tab lookup. The second does the same
from a `--worker` process, with a recording notification backend, so nothing is
posted.

Both test the installed app unless a build is selected, and both take the same
two settings, so one setting cannot leave them testing different things.
`GHOSTTY_NOTIFY_NATIVE_APP` names an app bundle, such as
`"$PWD/build/ClaudeGhosttyNotify.app"`, and `NATIVE_TEST_BINARY` an executable;
the executable wins when both are set. Each script starts by printing the binary
it tests.

The tab is the fixture. Each check writes markers into its title, expects every
lookup to find them, and leaves the tab with Ghostty's default title, whatever
it said before. That is why the tab has to be idle: a program that sets the
title while a check runs, as Claude Code does twice a second while it works,
overwrites the markers, fails the runs and loses its own title. Why these checks
exist is in `docs/incident-2026-09-17-pretooluse-hang.md`.

## Uninstall

Remove hook registrations first and restart open CLI sessions. For plugin
installs, use `/plugin uninstall ai-ghostty-notifier@ai-ghostty-notifier`. For manual Claude
installs remove this project's entries from `settings.json`; for Codex remove
entries containing `ghostty-notify/codex-hook.sh` from `hooks.json`.

After unregistering hooks for **both** CLIs, remove the shared app: the first
command from a checkout, the second after an install from a release.

```bash
bash scripts/install-agent.sh --uninstall
curl -fsSL https://github.com/Davie521/ai-ghostty-notifier/releases/latest/download/setup.sh | bash -s -- --uninstall
```

This removes its LaunchAgent and installed bundle, but keeps session state.
There is no complete shell fallback. You can then remove this project's unused
launcher files and state; preserve unrelated hooks and Codex configuration.
Codex configuration backups remain under `~/.codex/backups/`.

