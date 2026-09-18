# Native hook configuration contract

The required-app installation contract was accepted on 2026-09-16; see
[ADR-0001](adr/0001-require-native-app-for-hooks.md). This worktree is not a
published release. Native code keeps the sender's settings in each event instead
of reading the resident process's ambient environment during delivery.

## Settings retained by the native runtime

| Setting | Native behavior and empty-value semantics |
| --- | --- |
| `MIN_ELAPSED`, `SOUND_ELAPSED`, `TIMEOUT` | `GHOSTTY_NOTIFY_` names; ASCII nonnegative integers, defaults 180 / 600 / 1200 for missing, empty or invalid input. Resident timeout 0 means no automatic expiry. Display-only terminal-notifier has no expiry timer; the next prompt clears it. Cancellation still stops owned processes. |
| `GHOSTTY_NOTIFY_ON_PROMPT` | Only string `1` opts into Notification events; JSON boolean `true` becomes `true`, as in the old jq loader, and does not opt in. |
| `GHOSTTY_NOTIFY_CLEAR_ON_FOCUS` | Defaults on; 0 / false / no / off disable it, case-insensitively. Other and empty values keep the default. |
| `GHOSTTY_NOTIFY_BACKEND` | Missing or empty means `auto`. `auto` / `agent` try the ready resident; `terminal-notifier` selects display-only fallback. Retired `alerter` and unknown values also fall through to terminal-notifier, matching main's shell dispatch. Unavailable `agent` falls back to terminal-notifier, matching the old implementation (its old comment incorrectly said otherwise). |
| `GHOSTTY_NOTIFY_AGENT_APP` | Explicit empty disables resident routing, not the native hook executable. Nonempty relative paths are resolved in the hook's working directory before handoff; `~/` uses the sender's HOME. |
| `GHOSTTY_NOTIFY_ALERTER` | Legacy cleanup only; never selects a delivery backend. Empty uses discovery; nonempty paths locate the retired executable when removing old notifications. |
| `GHOSTTY_NOTIFY_APP_NAME`, `GHOSTTY_NOTIFY_GROUP_PREFIX` | Empty values keep the source's defaults. Codex branding remains Codex. External delivery and removal use the same group-prefix rule. |
| `GHOSTTY_NOTIFY_SESSION_DIR`, `GHOSTTY_NOTIFY_RATE_DIR` | Empty uses source-specific defaults. Paths are captured as absolute paths in the originating hook. Direct native clear/focus also interpret empty session-directory overrides as the default. |
| `CODEX_HOME`, `CODEX_SQLITE_HOME` | Captured from the sender for native Codex title/state lookup; empty values fall back to the appropriate home. SQLite is opened read-only with a bound session-id parameter. |
| `GHOSTTY_NOTIFY_TTY` | Empty falls back to native process inspection. A Codex session still needs a real terminal CLI ancestor even with an override. OSC writes only target a validated character device under `/dev/`. |
| `GHOSTTY_NOTIFY_CODEX_SETTLE` | Decimal seconds, default 1.5 for empty/invalid input; work is bounded by event expiry and invalidated by a newer prompt. |
| `GHOSTTY_NOTIFY_MARKER_RETRY_DELAYS` | Whitespace-separated finite nonnegative delays; explicit empty disables retries. Native binding caps the number of extra attempts and rejects a delay that exceeds its retry budget. |
| `GHOSTTY_NOTIFY_HOOK_DEADLINE` | Decimal seconds, default 12 for missing, empty or invalid input, clamped to 1–120. Read from the hook process's own environment before stdin. When it passes, the hook logs the reason and exits with status 0 without waiting for anything. Workers use the event lifetime plus 30 seconds; focus and clear use 15. SIGTERM allows 4 seconds of cleanup for a hook and 10 for a worker; a terminal query still in flight when its caller is cancelled is given up after 1 second, so restoration fits inside that. |
| `GHOSTTY_NOTIFY_FOCUS_POLL` | Retired and ignored. External delivery leaves no focus watcher; the resident uses activation events. |

Codex `config.json` only contributes `GHOSTTY_NOTIFY_[A-Z0-9_]+` keys. An existing
environment entry wins even when empty. Null and NUL-containing config values
are ignored; malformed config is reported and the hook fails open without
blocking the CLI. Empty has **per-setting** meaning, not one global rule.

## Native bootstrap and retired internal helper controls

`GHOSTTY_NOTIFY_NATIVE_APP` is an environment-only executable locator used by
the tiny Bash bootstrap, before Codex config can be decoded. It is different
from `GHOSTTY_NOTIFY_AGENT_APP`: explicitly empty or missing/old selected runtime
produces a diagnostic and no notification. Every hook does not build the app.

The native runtime does not execute `GHOSTTY_NOTIFY_FOCUS_SCRIPT` or
`GHOSTTY_NOTIFY_CLEAR_SCRIPT`. Those old helper substitutions are replaced by
native focus/clear behavior, not a supported native extension point. Users of
those private substitutions must remove them when upgrading. No complete shell
fallback is installed under the accepted native-app contract.

The old `BIND_ONLY`, `CONTEXT_CAPTURED`, `EVENT_AT`, `ROUND_ID`, `ROUND_START`,
`CLEAR_BEFORE` and `EXPECT_ALERTER` helper controls are implementation details,
replaced by typed event context, generation checks and owned-process records.
The CLI source is selected by the native entry mode rather than an untrusted
`PROCESS_NAME` override. The explicit clear/focus compatibility utilities still
accept `GHOSTTY_NOTIFY_PROCESS_NAME=codex` to select Codex state.

## Evidence and limits

Swift tests cover settings, sender paths, ASCII session IDs, safe pruning and
invalid/nonfinite start records. Real executable tests prove empty backend
selection, empty branding/group defaults and direct clear with an empty session
directory. Historical shell fixtures establish the compared behavior; their
passing tests are not counted as native runtime validation.

Native terminal tests cover transient query failures, permission backoff expiry,
empty snapshots, TUI redraws, retry snapshots, negative-cache invalidation,
cancelled/partial writes and failed or ambiguous recovery. A partial write with
one known original title now attempts recovery even when the complete marker
cannot be queried. With multiple tabs and no recoverable marker, the code logs
failure and does not guess another tab's original title or publish a successful
binding. These tests do not establish successful restoration during arbitrary
terminal/Automation outages; live UI acceptance remains separate.
