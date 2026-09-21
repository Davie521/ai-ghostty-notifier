# Codex hooks verification

> The frozen shell baseline (`tests/fixtures/shell-baseline/`), the suites that drove it
> (`tests/test_codex_hooks.py`, four `tests/test-*.sh` files) and `tests/benchmark-hooks.py`
> were removed on 2026-09-20; the last commit that has them is `0f1ba95`. What follows is a
> record of what was measured at the time.

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

**`codex exec` in a Ghostty tab**: bound the tab the same way; running the
focus script of the day from another tab selected exactly the bound tab
(`id of selected tab of front window` matched), which is what a click on
**Go to tab** does. (That script was retired with the alerter backend; the
agent now performs the same `select tab` itself.)

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

## The resident agent, same day

Why: on a machine running ten-odd Claude sessions, clicks on alerter's
notifications were lost. Every `alerter` posts as `com.apple.Terminal`, and
`usernoted` hands a click to whichever of those connections it likes; the one
that did not post the notification drops it (its uuid guard), and the one that
did is only told "closed". Reproduced twice: a click with no other alerter
activity was never answered until the 90 s timeout, and a click 2 s after an
unrelated `alerter --remove` came back as "Dismiss". Neither ever produced a
`Received response` line in `usernoted`'s log.

What changed: the agent is installed to `~/Library/Application Support/` (the
old LaunchAgent pointed into a checkout that had moved and had been failing
with exit 78), Codex's adapter no longer pins the shell path, and the anchor
hook honours `GHOSTTY_NOTIFY_SESSION_DIR`. Claude's hooks on the same machine
had never used the agent — they predated it.

Verified with Codex CLI 0.154.0 and the agent 0.4.0 (unchanged since
2026-08-16):

- `codex exec` in a Ghostty tab: Stop → tab bound with `ghostty_pid` →
  `posted claude-<session>` in the agent log, `Presenting … as alert` in
  `usernoted`; the notification read `Codex ✅`.
- Three clicks in a row (a live Claude session, the Codex run, a synthetic
  Claude session bound to a `sleep` tab): three `Received response` lines,
  three `jump: focused <tab>, verified selected` lines, the right tab each
  time.
- Submitting a prompt in a session withdrew its notification (`withdrew
  claude-<session>` right after the prompt), through the anchor hook.
- Ghostty had been restarted two days earlier: 18 of the 28 bindings from the
  previous week named tabs that no longer existed. `ghostty-tab-save.sh` now
  records the Ghostty pid, read from LaunchServices by bundle identifier,
  and re-resolves after a restart — the Codex adapter calls it on every
  qualifying Stop and it returns at once while the binding is current.
- A Focus mode ("Work", auto-activated) delivered the agent's alerts straight
  to Notification Center while letting Terminal through: `usernoted` logged
  `interruptionSuppression: delay delivery … resolutionReason: mode
  configuration type` for the agent and `none … mode configuration for
  application` for Terminal. Turning the Focus off made the alerts float; the
  install docs now say to allow the agent in Focus modes
  ([reference.md](reference.md#4-permissions-and-restart)).

`tests/test_codex_hooks.py` grew to 41 tests (agent delivery, the config
pin, the unauthorized fallback, the anchor/dismiss pair, rebinding after a
restart); each new guard was mutated in turn and its test went red.

## Dropping the alerter backend, 2026-09-16

The agent had been the delivery path for a day, on both assistants. `alerter`
stayed only as a fallback that could not be trusted with a click, so it went:
the backend, the click-dispatch subshell, the blocking process and its pidfile,
the per-notification clear-on-focus watcher, `ghostty-tab-focus.sh` (its only
caller was that dispatch) and `tests/test-alerter-dispatch.sh`.

What the fallback is now: `terminal-notifier` posts the alert and nothing else
runs. The next prompt in that session takes it down through
`ghostty-notify-clear.sh`, guarded by a delivery stamp so a notification that
arrives after the clear was requested survives. Clear-on-arrival and
click-to-jump come from the agent alone.

Verified locally before the change landed:

- `tests/test-clear-on-prompt.sh` replaces the 44-assertion watcher suite with
  16 assertions on what is left. Each guard was mutated in turn — the
  clear-before window, the delivery stamp and its removal, the failed-delivery
  path, the opt-out, the session-id shape check — and the matching assertion
  went red every time.
- Both suites assert that nothing outlives the hook. The negative control
  restores a watcher (a background `--watch` invocation that sleeps) and both
  assertions fail, so neither is vacuous.
- `tests/test_codex_hooks.py` (40 tests) covers the Codex side of the fallback:
  its own notification group, the delivery stamp, and the prompt that clears
  it. Mutating the round-reset clear, the group prefix and the stamp each
  turned it red.
- Shell syntax, ShellCheck, the JSON checks, the remaining bash suites and the
  66 Swift tests all pass.
