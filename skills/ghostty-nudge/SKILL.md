---
name: ghostty-nudge
description: Call the user back to this session with a macOS notification whose Go to tab button returns to this Ghostty tab. Use when you need them to do something before you can go on and they may not be watching — Face ID, a verification code, a QR scan, a tap to confirm on their phone, a decision that blocks you. Not for progress, and not for the end of a task: long runs already notify when they end.
---

# Nudge the user

Run this once, with one line saying what you need from them:

```bash
"$HOME/Library/Application Support/claude-ghostty-notify/ClaudeGhosttyNotify.app/Contents/MacOS/ghostty-notify-agent" --nudge "Face ID on your iPhone to finish the bank login"
```

- **Lead with the action**, in the user's language, under about 100
  characters: what to do and where ("Scan the QR code on screen with your
  phone"), not "I need you".
- **Then carry on** with whatever you were doing, polling the screen or the
  state for the user's step to land. Do not end your turn to wait, and do not
  send it again while you wait: one nudge per thing you need.
- It plays a sound, appears under this session's title, and clears itself when
  the user returns to this tab or sends a prompt. A newer nudge, or this run's
  own completion notification, replaces it.
- **Exit 0** prints where Go to tab leads. **Any other exit** means it was not
  delivered, and stderr says why (the app is not running, notifications are
  off, the app did not take it in time). Nothing will appear later unless
  stderr says it may. Either way, say what you need in your reply instead, and
  do not retry in a loop.
- Works in Claude Code and Codex CLI sessions in Ghostty: the command finds
  its session through `CLAUDE_CODE_SESSION_ID` or `CODEX_THREAD_ID`, which they
  set for the commands they run. Run it as it is, inside Codex's sandbox too;
  it needs no escalation.
