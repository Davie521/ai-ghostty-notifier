# Install instructions for an agent

This file is written for a coding agent — Claude Code, Codex CLI or similar —
running on the user's own Mac. Follow it top to bottom and actually run the
checks. The user pasted a one-line request; the work is here.

**What you are installing:** hooks plus a small companion app, so that a long
Claude Code or Codex CLI run in Ghostty ends with a macOS notification whose
**Go to tab** button brings that session's tab forward.

## Rules

- **Merge, never rewrite.** `~/.claude/settings.json`, `~/.codex/hooks.json` and
  `~/.codex/config.toml` belong to the user. Copy a file before you edit it and
  keep every unrelated entry.
- **Manual hooks or the plugin, never both.** Two registrations mean two
  notifications for one event.
- **`scripts/install-agent.sh` is the half that changes the system.**
  `scripts/build-agent.sh --build-only` only builds. Do not install when the
  user asked for a build.
- **Some steps need a human at System Settings.** You cannot click them. Do not
  report success before they are done; collect them for step 4.
- **Stop at the first failed check** and say which one failed. Undo steps are at
  the end of this file.

## 0. Preconditions

```bash
sw_vers -productVersion                  # macOS only; this project has no other platform
ls -d /Applications/Ghostty.app 2>/dev/null || ls -d ~/Applications/Ghostty.app   # Ghostty
swift --version                          # Swift 6 toolchain; only when building from source
python3 --version                        # 3.11+, needed only by the Codex installer
```

Which CLIs to wire up: `~/.claude` existing means Claude Code, `~/.codex` means
Codex CLI. If both exist, do both. If neither does, ask before continuing.

Work inside a clone of this repository, and stay on one revision: the app and
the hooks have to come from the same one.

## Fast path: a published release

Check whether the repository has a release:

```bash
curl -fsSIL -o /dev/null https://github.com/Davie521/ai-ghostty-notifier/releases/latest/download/setup.sh \
  && echo release-exists
```

If it prints `release-exists`, install from the release instead of building:

```bash
curl -fsSL https://github.com/Davie521/ai-ghostty-notifier/releases/latest/download/setup.sh | bash
```

No clone and no Swift toolchain are needed. The script checks the download
against the release's `SHA256SUMS` and refuses an App that is not a notarized
Developer ID build. It then does steps 1–3 below by itself:
- installs the App and its LaunchAgent;
- merges the Claude Code hooks into `settings.json`. It keeps every other
  entry, backs the file up first, and refuses when the plugin is enabled;
- registers the Codex hooks, when Codex and a Python 3.11+ are both present.

Read its output, then go to step 4. If it stops on an error, report the error:
do not retry with `--allow-unnotarized`, which exists only for testing.

Without a release, build from source: steps 1–3.

## 1. Build and install the companion app

The app is required. Its Swift executable does hook processing, terminal
binding, notification policy and delivery; the shell files in `hooks/` are only
launchers, and at runtime nothing needs Node, jq or Python.

```bash
bash scripts/build-agent.sh --build-only
bash scripts/install-agent.sh
```

The second command installs or replaces the app, restarts its service,
registers a LaunchAgent and opens the notification-permission flow.

Check the **installed** copy, not the build output:

```bash
APP=~/Library/Application\ Support/claude-ghostty-notify/ClaudeGhosttyNotify.app
ls -d "$APP"
codesign --verify --deep --strict "$APP"
```

Hooks and launchd both point at that durable path, so the user may move or
delete the clone afterwards. Building alone never updates that copy: after any
change to the source, run both commands again.

If the user does not want a resident process, use
`bash scripts/install-agent.sh --no-start` instead: it installs and verifies the
app without a LaunchAgent, without LaunchServices registration and without
permission prompts. It refuses to run over an existing LaunchAgent install or a
live resident, and the normal installer is the way to upgrade either.

## 2. Register the Claude Code hooks

```bash
bash install.sh --register-settings
```

It verifies the app is installed, copies the launchers into `<config>/hooks/`,
and merges their entries into `<config>/settings.json`. `<config>` is
`$CLAUDE_CONFIG_DIR` when set, otherwise `~/.claude`. The merge
(`scripts/register-claude-hooks.py`):

- keeps every other entry, and first copies the file aside as
  `settings.json.ghostty-notify-backup-<time>`;
- adds nothing to an event that already runs one of these launchers, so running
  it again is harmless;
- gives each entry `"timeout": 15`. Without it Claude Code waits up to 600
  seconds for a command hook, which is how a stuck hook once looked like a hung
  session ([incident](incident-2026-09-17-pretooluse-hang.md));
- writes nothing, and says why, when `settings.json` does not parse or when the
  plugin is enabled. The plugin registers the same hooks itself, and both
  together mean two notifications for every event.

Read its output. `Registered …` or `Hooks already registered …` means done. If
it reports the plugin, stop and ask the user which of the two to keep. Only if
it fell back to printing a snippet (no Python 3.9+, or an unreadable
`settings.json`) merge by hand: back the file up, add the printed entries to
the existing `hooks` object without touching the rest, keep the timeouts;
[`example-settings.json`](../example-settings.json) is the complete example.

If the user has more than one Claude configuration directory, run it once for
each: `CLAUDE_CONFIG_DIR=<dir> bash install.sh --register-settings`.

Then prove the file still parses:

```bash
python3 -m json.tool "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" > /dev/null && echo "settings.json parses"
```

The plugin is the alternative, not an addition: the user — not you, these are
slash commands — runs `/plugin marketplace add Davie521/ai-ghostty-notifier`
and `/plugin install ai-ghostty-notifier@ai-ghostty-notifier` inside Claude
Code. The published marketplace can lag the clone you are installing from;
prefer `install.sh` unless the user asks for the plugin.

## 3. Register the Codex CLI hooks

Skip this if the user has no Codex CLI.

```bash
python3 scripts/install-codex.py
```

It copies launchers to `~/.codex/ghostty-notify/`, adds `UserPromptSubmit` and
`Stop` entries to `~/.codex/hooks.json`, keeps unrelated hooks and settings,
honours `CODEX_HOME`, and puts backups of changed files under
`~/.codex/backups/`. Re-running it is safe. It also narrows Codex's built-in TUI
notifications to `["approval-requested", "plan-mode-prompt"]` when needed, so
turn-complete alerts are not announced twice.

Trusting the new entries is the user's step: start Codex in Ghostty, run
`/hooks`, trust the two entries.

## 4. Hand back the steps only the user can do

Report these as a short checklist, in the user's language, and say plainly that
the install is not finished until they are done:

1. Allow notifications for **AI Ghostty Notifier** when macOS asks. In
   **System Settings → Notifications → AI Ghostty Notifier**, choose
   **Persistent** if the alert and its button should stay on screen.
2. Allow **Automation** control of Ghostty when macOS asks. Without it the
   notification can only activate Ghostty, not jump to the exact tab.
3. Allow the app in any Focus modes they use, or the notification is held back.
4. In Codex, run `/hooks` and trust the new entries (step 3).
5. Restart every Claude Code / Codex session that is already open, including the
   one you are running in. Hook registrations load at session start.

## 5. Verify

What you can check yourself:

```bash
ls ~/.claude/hooks/                                   # launchers are in place
python3 -m json.tool ~/.claude/settings.json > /dev/null
python3 -m json.tool ~/.codex/hooks.json > /dev/null   # only if Codex was wired up
launchctl list | grep io.github.davie521.cgnotify || true   # the resident service, when started
```

What proves it actually works, and only the user can see: after restarting a
session, run something that takes more than three minutes, switch away from
Ghostty, and wait for the banner. Clicking **Go to tab** has to land on that
session's own tab. Ask them to tell you what happened.

Do **not** run `tests/test-live-binding.sh` or `tests/test-live-worker.py` in
your own tab. They use a tab's title as their fixture, and a working CLI rewrites
its title constantly; run from your own session they fail and take the title with
them. They need an idle Ghostty tab, and the rest of the suites are in
[reference.md](reference.md#verification).

## If you need to undo this

Unregister the hooks for both CLIs first, then remove the shared app: the
first command from a checkout, the second after an install from a release.

```bash
bash scripts/install-agent.sh --uninstall
curl -fsSL https://github.com/Davie521/ai-ghostty-notifier/releases/latest/download/setup.sh | bash -s -- --uninstall
```

For Claude, remove this project's entries from `~/.claude/settings.json` (or
`/plugin uninstall ai-ghostty-notifier@ai-ghostty-notifier` for a plugin install). For Codex,
remove the entries containing `ghostty-notify/codex-hook.sh` from
`~/.codex/hooks.json`; its backups are under `~/.codex/backups/`. Session state
survives an uninstall, and there is no shell fallback once the app is gone.
