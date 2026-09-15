# Codex hooks verification

Verified on 2026-09-15 with Codex CLI 0.153.4, Ghostty 1.3.1, alerter 26.5,
macOS 26. Two real Ghostty tabs were opened over AppleScript, driven, and
closed again; nothing else on the machine was touched.

## What was checked

**Interactive TUI in a Ghostty tab** (`codex`, prompt typed with Ghostty's
`input text`, `GHOSTTY_NOTIFY_MIN_ELAPSED=0` so the round qualifies):

| t (s) | tab title                              | state                              |
|------:|----------------------------------------|------------------------------------|
| 7     | `⠋ new-chat`                           | `.start` armed by UserPromptSubmit |
| 8–11  | `⠙ renaming... ⠙ \| new-chat`          | thread-title generation animating  |
| 12–15 | `⠴ Run sleep 3 command \| new-chat`    | turn running, spinner              |
| 16    | `Run sleep 3 command \| new-chat`      | turn ended, title static           |
| 18    | same                                   | `.json` = the tab's id, no `.attempts`, alerter posted |

The alert read `Codex ✅ · Run sleep 3 command — new-chat · Finished after
0m 12s`: the subtitle is the thread name Codex stored in its state database,
the duration is measured from the prompt. Because the tab was frontmost the
clear-on-focus watcher dismissed it right away, as designed.

**`codex exec` in a Ghostty tab**: bound the tab the same way; running
`ghostty-tab-focus.sh <session>` from another tab selected exactly the bound
tab (`id of selected tab of front window` matched), which is what a click on
**Go to tab** does.

**Negative controls on the same machine**: a `codex exec` started from a
process without a terminal left only a `-` owner mark and no alert; a run
through `script(1)` (a pseudo-terminal Ghostty never sees) alerted without a
binding and recorded one attempt.

## Automated checks

- `tests/test_codex_hooks.py`: 36 tests drive the installed adapter through
  the real shared scripts with a fake `ps`, a fake TTY file and stubbed Apple
  Events. Every guard was removed in turn and its test went red (31
  mutations, run with `PYTHONDONTWRITEBYTECODE=1` — a stale `__pycache__` can
  otherwise report a mutation as caught that never ran).
- The four Claude-side bash regression suites, `bash -n`, shellcheck and the
  JSON checks from CI all pass.

## Fixed since the first hooks version

From the 2026-09-14 review of the branch:

- Tab binding never succeeded for Codex: the marker round-trip ran on
  PreToolUse while the TUI rewrote the title every 100 ms. It now runs from
  a detached process after Stop, once the title holds still, with retries.
- Rounds were timed from the first local tool call, so reasoning-only or
  hosted-tool turns never alerted; the clock now starts at the prompt.
- Turn boundaries Codex continues through (`/goal`, queued follow-ups)
  alerted and reset the clock; the rollout's next `task_started` now
  suppresses both.
- Sub-agent `UserPromptSubmit` payloads (root id plus `agent_id`) cleared
  the root round's timer; they are ignored.
- The installer re-appended its entries on every run, which renumbered the
  user's own hooks and broke Codex's position-keyed trust; it now edits in
  place and reports when a removal had to move something.
- `[tui] notifications = true` was narrowed to approvals only, hiding
  plan-mode questions; an unset key (which Codex treats as all alerts) was
  left alone. Both now become `["approval-requested", "plan-mode-prompt"]`.
- The installer wrote scripts and `hooks.json` before finding out whether
  `config.toml` could be migrated; it now computes everything first.
- Symlinked `hooks.json`/`config.toml` were replaced by regular files, and
  temp/backup files were briefly world-readable.
- `config.json` only reached the shared scripts for four keys; every
  `GHOSTTY_NOTIFY_*` knob now passes through, and the installer copies all of
  Claude's preferences.
- A large pasted first prompt could stall the prompt hook past its timeout
  (`gsub` before slicing); an empty first prompt blocked later titles.
- `sqlite3` ran with the user's rc file and without `sqlite_home`; both
  handled. `.codex-owner` / `.title` files were never pruned.
- Several assertions could not fail; the suite was rebuilt with negative
  controls.
- Found while verifying: `alerter --help` reads stdin when it is not a
  terminal and blocks until EOF, so every alerter call in the shared scripts
  now has `</dev/null` (the hooks were safe — their stdin is the drained
  payload — but a manual `ghostty-notify-clear.sh` from a pipeline hung).
