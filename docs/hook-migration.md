# Hook / resident-agent migration

> The frozen shell baseline (`tests/fixtures/shell-baseline/`), the suites that drove it
> (`tests/test_codex_hooks.py`, four `tests/test-*.sh` files) and `tests/benchmark-hooks.py`
> were removed on 2026-09-20; the last commit that has them is `0f1ba95`. What follows is a
> record of what was measured at the time.

Historical first-stage snapshot. The [native migration](native-hook-migration.md)
supersedes the runtime layout below. The shell implementations mentioned here
now live only in `tests/fixtures/shell-baseline/`, not in installed hooks. These
earlier test counts and timing results do not establish native-phase completion.

Base: `9a3440b` (`plan-agent-appsupport`). Worktree: `refactor-hook-agent`.

## Contract

- Bash captures stdin, source-process identity/TTY and a synchronous round marker.
  The OSC marker transaction stays together with its lock and title restoration.
- A versioned `hook_event` request carries event time, round identity, start-time
  snapshot, source and the sender's effective settings. The resident process owns
  notification policy, title lookup, deduplication, delayed Codex completion and
  housekeeping. Expensive I/O never blocks the app's main actor.
- Old agents continue accepting `notify`, `anchor` and `dismiss`. Hooks only send
  events after checking a capability belonging to the running process. Missing,
  old, disabled or unauthorized agents use the compatibility scripts.
- The native and compatibility paths share the on-disk round and rate journal.
  A new prompt invalidates pending work from the previous round. Completion may
  remove a start marker only while holding the journal lock and only if its round
  is still current. Backend switching never starts a second deduplication window.
- Claude starts timing on the first tool; Codex starts on the prompt. Event time
  measures work; queue delay, title lookup and Codex settling do not add to it.
- A queued event is best-effort work, not a delivery acknowledgement. Notification
  events expire; old prompts cannot revoke a newer round. Recheck generation and
  expiry after asynchronous operations, before delivering.
- Clear-on-focus opt-out preserves delivered notices. New-round invalidation
  still prevents delayed results from resurrecting an old notice.

## Implementation and verification

1. Shared Bash input/config/context helpers; isolated legacy fallback entry points.
2. Typed event codec/policy, shared journal, bounded title/continuation I/O.
3. Injectable asynchronous event processor; native app integration and capability.
4. Thin Claude/Codex routing, install manifests and documentation.
5. Bash 3.2 + ShellCheck + JSON validation; all existing shell and Python suites;
   Swift policy, storage, concurrency, protocol and integration suites; release
   bundle build and isolated resident-process smoke test.

Critical scenarios: empty/escaped input, missing jq, parallel starts/stops,
permission prompts bypassing elapsed gates, interrupted rounds, newer prompts
overtaking title lookup/settling, agent restarts, stale replay, backend switching,
old/new protocol combinations, Codex owner changes, Ghostty restarts, title
restoration, clear-on-focus opt-out and notification dismissal never focusing.

## Review decisions

- Keep Bash as the entry point; no Python runtime or extra client executable.
  The three routing entry points are now 11 / 11 / 18 lines, with shared input
  and journal helpers. Compatibility code remains deliberately available, so
  this is not a claim that the entire `hooks/` directory became tiny.
- Parse metadata in one jq invocation using NUL-delimited fields. A plain
  `@tsv` plus `read` is not lossless for empty fields, escaped tabs and newlines.
  Missing jq emits a diagnostic to stderr while the hook still exits cleanly.
- Do not split the OSC marker, lock and title-restoration transaction. Swift
  can run the bounded helper using the TTY captured before the hook returns.
- Share one round/rate journal across both backends. Unicode rate keys are
  defined per Unicode scalar, independent of the shell's locale. A real
  cross-backend test caught the initial byte-versus-character mismatch.
- Preserve source identity on compatibility requests too: old agents ignore
  the optional field, while new agents can retire a native Codex notice after
  the user switches to a shell backend.

| Responsibility | Implementation |
| --- | --- |
| Capture input, owner/TTY, event/start time and round; publish atomically | `hooks/hook-common.sh` and the three thin entry points |
| OSC marker transaction and restoration | `hooks/ghostty-tab-save.sh` |
| Typed event, thresholds, content and source-scoped identifiers | `NotifyCore/HookEvent.swift`, `Protocol.swift` |
| Generation checks, shared locks, rate window and pruning | `NotifyCore/RoundJournal.swift` |
| Streamed transcript titles, bounded SQLite lookup and continuation | `NotifyCore/SessionContent.swift` |
| Cancellable settling, stale-result checks and delivery orchestration | `NotifyCore/HookProcessor.swift` |
| Old/missing/unauthorized agent fallback | `hooks/legacy-*.sh` |

The clock, journal, content and terminal binding boundaries are injected through
small protocols. Tests exercise the same processor as the app, including a new
prompt overtaking settling or title resolution, without relying on real sleeps.

## Verified on 2026-09-15

Environment: macOS 26.6.2 arm64, `/bin/bash` 3.2.57, Swift 6.3.3,
jq 1.7.1-apple, ShellCheck 0.11.0.

| Check | Result |
| --- | --- |
| `swift test --package-path agent --quiet` | 96 tests, 16 suites passed |
| `python3 -m unittest discover -s tests -p 'test_*.py'` | 47 tests passed |
| Existing alerter / fallback / title / clear shell suites | 7 + 4 + 8 + 44 checks passed |
| Release bundle build with `--build-only` | Passed |
| `codesign --verify --deep --strict build/ClaudeGhosttyNotify.app` | Passed |
| `bash tests/test-agent.sh` against that real bundle | 41 checks passed; Aqua session, authorization granted |
| Bash syntax, ShellCheck warnings/errors, JSON manifests, `git diff --check` | Passed |

The real-app suite uses isolated state and session IDs. It covers both hook
entry points through the spool, policy, notifier bookkeeping, prompt opt-out,
source isolation, native-to-shell switching, legacy identifier retirement,
stale event replay and restart. The installed production agent was not stopped,
reinstalled or replaced. `scripts/build-agent.sh --build-only` exists to make
that safe verification workflow reproducible.

These automated checks do **not** assert pixels in Notification Center or click
real banners. Visual presentation, sound audibility and a real user click to a
live Ghostty tab remain manual acceptance checks. Existing terminal-transaction
and dismiss-without-focus regressions run against controlled command stubs.

## Hook latency

Measured with `tests/benchmark-hooks.py`, 5 warmups then 60 samples per case.
The baseline is a temporary, read-only snapshot of `9a3440b`; its original
worktree was removed externally after this migration worktree was created.
The benchmark uses real Bash entry points and file transport, stubs process/tab
discovery, and validates each queued request so silent exits cannot look fast.

| Case | Baseline median / p95 | Migration median / p95 |
| --- | --- | --- |
| Cached `PreToolUse` | 13.90 / 14.71 ms | 14.02 / 15.12 ms |
| `Stop` returning after spool publication | 50.27 / 52.93 ms | 45.17 / 47.53 ms |

Cached hot-path latency is effectively unchanged; Stop's median is about 10%
lower in this run. These are hook-return timings, not end-to-end notification
latency. The main gain is tested lifecycle ownership, not a language-startup
speedup. Machine-readable results: [hook-migration.json](../.ecc/benchmarks/hook-migration.json).
