---
name: ghostty-nudge
description: Call the user back to this session with a macOS notification whose Go to tab button returns to this Ghostty tab, or, for a step they do somewhere else (a captcha, Face ID or a tap on their phone), one without the button that goes away once the step is done. Use when you need them to do something before you can go on and they may not be watching — Face ID, a verification code, a QR scan, a tap to confirm on their phone, a decision that blocks you. Not for progress, and not for the end of a task; long runs already notify when they end.
---

# Nudge the user

Run this once, with one line saying what you need from them:

```bash
"$HOME/Library/Application Support/claude-ghostty-notify/ClaudeGhosttyNotify.app/Contents/MacOS/ghostty-notify-agent" --nudge "Pick which of the two migrations to run first"
```

- **Lead with the action**, in the user's language, under about 100
  characters: what to do and where ("Pick which database to migrate first"),
  not "I need you".
- **Then carry on** with whatever you were doing, polling the screen or the
  state for the user's step to land. Do not end your turn to wait, and do not
  send it again while you wait: one nudge per thing you need.
- It is silent (unless the user set `GHOSTTY_NOTIFY_NUDGE_SOUND=1`), appears under this session's title, and clears itself when
  the user returns to this tab or sends a prompt. A newer nudge, or this run's
  own completion notification, replaces it.
- **Exit 0** prints where Go to tab leads. **Any other exit** means it was not
  delivered, and stderr says why (the app is not running or older than this
  command, notifications are off, the app did not take it in time). Nothing will appear later unless
  stderr says it may. Either way, say what you need in your reply instead, and
  do not retry in a loop.
- Works in Claude Code and Codex CLI sessions in Ghostty: the command finds
  its session through `CLAUDE_CODE_SESSION_ID` or `CODEX_THREAD_ID`, which they
  set for the commands they run. Run it as it is, inside Codex's sandbox too;
  it needs no escalation.

## When they need not come back: `--no-return`

Some steps the user does somewhere else and is done: slide a captcha, Face ID
or a tap to confirm on their phone, scan a code with it. They never come back
to the tab for those, so a Go to tab button is no use and the nudge would sit
on screen.

First check that the app is new enough; a plugin update can bring this skill
without it:

```bash
test -f "$HOME/Library/Application Support/claude-ghostty-notify/ClaudeGhosttyNotify.app/Contents/Resources/nudge-v2"
```

If that fails, nudge as above, without `--no-return`, and skip `--nudge-done`.
Otherwise add `--no-return` in front of the message:

```bash
"$HOME/Library/Application Support/claude-ghostty-notify/ClaudeGhosttyNotify.app/Contents/MacOS/ghostty-notify-agent" --nudge --no-return "Slide the captcha in Taobao on the iPhone"
```

Once your polling sees the step land, take it back:

```bash
"$HOME/Library/Application Support/claude-ghostty-notify/ClaudeGhosttyNotify.app/Contents/MacOS/ghostty-notify-agent" --nudge-done
```

- It has no Go to tab button, and goes by itself after fifteen seconds: the
  user takes it in as it comes up. Run `--nudge-done` anyway once the step
  lands; it takes the nudge back sooner if it is still there.
- `--nudge-done` takes back only a nudge: if this run's completion
  notification has replaced it, that stays. A newer nudge is a nudge too, so
  run `--nudge-done` for one step before you nudge for the next.
- Leave out `--no-return` when the user has to come back: a decision, a
  question, a code to type here, anything done in this terminal.
