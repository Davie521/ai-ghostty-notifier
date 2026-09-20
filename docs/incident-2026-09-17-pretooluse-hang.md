# Incident: PreToolUse hooks blocked Claude Code for 600 seconds

**Dates**: began 2026-09-17 17:05 with the native hook deployment; diagnosed the
same evening; fixed 2026-09-18. All times are local (UTC+8).

## What the user saw

Several Claude Code sessions sat on `Running PreToolUse hook · 6m 22s` before
every tool call. Other sessions on the same machine were unaffected.

## Cause

`NSAppleScript` waits for an Apple Event reply by pumping a Carbon event loop on
the calling thread. That works on a background thread only once AppKit has
claimed the main thread. The resident app has an `NSApplication`; the `--hook`,
`--worker`, `--focus` and `--clear` modes introduced by the native migration did
not. In those modes the first Carbon call claimed the background thread instead
(the system log shows `Main thread potentially initialized incorrectly`), the
reply was never serviced there, and neither was the script's own
`with timeout of 3 seconds`.

Nothing in the process could end the wait. Task cancellation does not reach a
blocked `executeAndReturnError`, and the hook ignored SIGTERM except to cancel
that task. Claude Code's default timeout for a command hook is 600 seconds, and
the shipped hook entries set none, so each affected tool call cost ten minutes.
When the timeout's SIGTERM finally arrived it happened to wake the blocked
thread, which then returned the correct answer: the reply had been there all
along.

Only sessions without a cached `<session>.json` binding query the terminal, so
only new sessions were affected, which is why it looked intermittent. Workers
take the same path for Stop and Notification events and have no harness timeout
at all; several stayed hung for one to two hours.

## Evidence

- `sample` of a stuck hook: main thread in `CFRunLoopRun`, the
  `ghostty.native-binding.applescript` queue in `UASRemoteSend` →
  `AEDefaultActiveProc` → `WNEInternal` → `mach_msg`.
- Unified log, 18:46–21:10 on 2026-09-17: 42 hook processes, every one alive for
  exactly 600.0 seconds.
- Ghostty was healthy: the same query through `osascript` returned in 90 ms. The
  Automation grant existed and tccd showed no pending consent request.
- The 16:58 crash report from the same deployment is the same defect with a
  different ending: a background Apple Event wait tripping WindowServer's
  main-queue assertion.
- Controlled reproduction with the production tab query, twenty runs per arm,
  six-second limit:

| Script runs on | NSApplication created | Returned | Median |
| --- | --- | --- | --- |
| background queue (the defect) | no | 0 / 20 | — |
| main thread | no | 20 / 20 | 0.29 s |
| background queue | yes | 20 / 20 | 0.28 s |
| main thread | yes | 20 / 20 | 0.31 s |

## Fix

1. **Cause.** `AppleEventHost.prepare()` creates `NSApplication` on the main
   thread before any script leaves it. Native modes now run queries in the same
   configuration the resident app has used all along. The main thread stays
   free, so an abandoned query still lets the hook exit and the worker deliver.
   Running scripts on the main thread was the other working arm; it was rejected
   because an unanswered Automation prompt would then block the whole process,
   including a worker's delivery.
2. **Every script is bounded.** Read-only resident queries previously had no
   `with timeout` and inherited AppleScript's 120-second default.
3. **The wait is bounded where it can be tested.** `NativeTerminalBinding` races
   each query against `QueryDeadline` (5 s) and abandons a call that does not
   return. It then fails fast in-process, leaves an `applescript-stalled` stamp
   that keeps other hook processes away for 60 seconds, still restores a title
   it can identify, and does not count the stall as a missed marker.
   Cancelling the caller shortens that wait to 1 s instead of ending it:
   restoration runs in cancelled tasks and still needs its answer, but a
   shutdown grace period cannot sit behind a query that will never return. A
   wait given up for that reason is not treated as a stall.
4. **A marker is a recorded transaction.** Before the marker is written, the
   snapshot it was taken against goes to `<session>.marker.json`; the record is
   removed once the title is back. With several tabs open, an abandoned lookup
   (or a process ended mid-transaction) cannot tell which title was its own, so
   the next attempt undoes the marker from that record before it captures a new
   baseline, and only for the same Ghostty process and marker. The title goes
   back to the terminal the record names, which is not the current one when the
   session was resumed in another tab. A marker that is already showing with no
   usable record proves nothing about the current terminal: that tab is neither
   bound nor accepted as the lookup's answer, and the marker is never written
   back as though it had been a title. That holds for any session's marker: one
   captured as a baseline is replaced by the empty title, for which Ghostty
   shows its default until the program in that tab sets its own.
   Recovery gives the terminal 0.15 s to show the restored title and removes
   the record only once the marker is seen to be gone. Without that wait it
   took the next baseline too early, set its own leftover aside, wrote the
   identical marker onto the same tab and deleted the record with the marker
   still up. That path was unreachable for two minutes after a hook was killed,
   while the dead hook's directory lock was honoured, and became reachable at
   once when the lock became a `flock`, which the kernel releases with its
   holder. Killing hooks with the marker showing on a real tab then stranded it
   3 times out of 3, and 0 times out of 9 with the wait.
5. **The process is bounded unconditionally.** `NativeLifecycle` arms a deadline
   on its own queue before stdin is read and ends the process with `_exit(0)`:
   12 s for a hook (`GHOSTTY_NOTIFY_HOOK_DEADLINE`), the event lifetime plus 30 s
   for a worker, 15 s otherwise. Its diagnostics are written from another queue
   and waited on for a quarter of a second at most, so a full stderr pipe or a
   stalled log cannot hold the exit. SIGTERM is handled off the main queue and
   gets 4 s (hook) or 10 s (worker) for cleanup before the same exit. Only the
   first SIGTERM counts and no deadline is ever withdrawn, so a supervisor that
   repeats its signal cannot renew the grace period.
6. **The harness is told too.** Shipped Claude hook entries now set
   `"timeout": 15`, matching what the Codex installer already wrote.

## Why the tests missed it, and what covers it now

The real-process suite uses a fixture TTY, so PreToolUse returned before any
query. The unit fixture always answered at once. CI has no Ghostty.

- `NativeTerminalBindingTests`: a query that never returns, before and after the
  marker; cancellation during such a lookup; a marker left behind with several
  tabs open and undone by the next attempt; a record about another Ghostty
  process; a session resumed in another tab, whose old tab gets its title back
  while the new one is bound; a leftover marker, or another session's, which is
  neither bound nor written back as a title; a terminal that shows a restored
  title late. Each fails with its part of the fix removed.
- `QueryDeadlineTests`: work that ignores cancellation is abandoned, not
  awaited; a cancelled caller waits only the shorter limit, and still receives
  an answer that arrives inside it.
- `test_native_hooks.py`: a hook whose stdin never closes exits 0 at its
  deadline, also when nobody drains its stderr; SIGTERM ends a hook whose work
  cannot be cancelled, and repeating it cannot postpone the exit. Each fails
  against the 2026-09-17 binary or against the intermediate build that had the
  defect. The exit waits a quarter of a second at most for its report, so the
  tests accept its absence and one retries until a report gets through. The
  suite finds what a test started by the executable living under the fixture:
  a worker leaves its process group with `setsid()`, and a cleanup that watched
  the group leaked half its runs under load while passing when idle. It now
  leaks nothing at a load average above 30 and leaves alone a bystander that
  merely names a fixture file.
- `tests/test-live-binding.sh`: opt-in, needs a running Ghostty. Twenty unbound
  PreToolUse hooks must each bind the tab within seconds and leave its title as
  it was. The 2026-09-17 binary hangs on every run; this build binds 20 of 20,
  typically in 0.63 s.
- `tests/test-live-worker.py`: opt-in, needs a running Ghostty. A worker gets a
  real terminal device but the recording notification backend of
  `test_native_hooks.py`, so its tab lookup, marker and restoration are real
  and nothing reaches Notification Center. Five workers must each bind the tab,
  deliver once and exit 0 within seconds. The 2026-09-17 binary is still
  running when the script gives up on it.

Run both live checks before deploying a build that touches Apple Events or
native process setup, in a new Ghostty tab with nothing but a shell in it. That
tab is the fixture: the checks expect every lookup to find its marker and reset
the title to Ghostty's default when they end. Two things measured along the way
are why. Claude Code animates its tab title twice a second while it works, and
a frame that lands in the 0.15 s between marker and lookup overwrites the
marker: 5 of 30 cold bindings missed that way, and all 5 bound on the retry the
runtime makes at the next tool call. That is designed behaviour, covered by the
unit tests, and only noise in a live check. And Ctrl-C never reaches a worker,
which has left the process group; what strands a marker on a tab is killing a
worker mid-lookup, so the worker check asks an overstaying worker to stop
before it kills it.

Six independent reviews of the fix and its follow-ups found most of the defects
these tests now pin down. A seventh asked whether the result was over-built.
After it the live checks stopped preserving the title of whatever tab they were
pointed at and require an idle one instead, the watchdog schedules its two
deadlines rather than keeping one replaceable timer, and another session's
marker is no longer traced to that session's record for a title. The
round-by-round account is in the history of this file.

On 2026-09-19 the production path was also exercised end to end: a real
`claude -p` session with one tool call, started with `GHOSTTY_NOTIFY_TTY` set
because a headless process owns no terminal, ran the shipped `PreToolUse` entry
from `settings.json` against the installed app and bound its tab with no stall
stamp and no marker record left behind.

## If it happens again

`ps -eo pid,ppid,etime,args | grep 'ghostty-notify-agent --hook'` shows stuck
hooks; `sample <pid>` shows where. To stop the bleeding without a rebuild:

    touch ~/.claude/notifications/ghostty-sessions/applescript-unavailable

That is the existing 24-hour negative capability cache. New sessions lose
click-to-tab until the file is removed; nothing else changes.
