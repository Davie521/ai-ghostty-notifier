# Native macOS hook migration

> Update, 2026-09-17: the user authorized deployment. Fresh tests, a live focus
> correction and local installation are recorded in
> [the deployment report](native-hook-deployment-2026-09-17.md). The implementation
> was merged to `main` in PR #13 the same day. The notes below record the earlier
> September 16 verification and its then-outstanding deployment/acceptance work.
>
> Mainline integration preserves the later retirement of alerter: only the
> resident handles clicks/focus/expiry; terminal-notifier is display-only and
> cleared on the next prompt. Native fallback has no long-lived focus monitor.
> Historical descriptions of alerter and its tests below describe the earlier
> snapshot, not the final runtime contract; see [configuration](native-hook-configuration.md).

Objective: minimize shell in the macOS hook runtime, not just hide it behind a
Swift caller. Built in `refactor-hook-agent` (merged in PR #13) on top of the
first-stage work.

## Accepted installation contract

On 2026-09-16 the user accepted requiring the companion app and removing the
complete pure-shell fallback. [ADR-0001](adr/0001-require-native-app-for-hooks.md)
records the choice and alternatives. These worktree changes remain uncommitted
and have not been published or deployed to the installed app.

Installed is different from running: the app bundle provides one executable
that can serve as the resident agent or a temporary hook/worker process. A
stopped resident does not require the old Bash implementation. A missing native
executable prevents notifications: the bootstrap instead drains stdin, reports the missing runtime
and returns success to avoid blocking the CLI, but cannot send a notification.

No production installation, restart, commit or publication has been performed
by this migration work. The English and Chinese READMEs now describe app-first
installation, runtime-only installation, upgrades and the absence of shell
fallback. Installer tests copy a real signed app into private homes only.

## Completion requirements

- One native executable serves resident, hook and fallback-worker modes. Workers
  are bounded by the notification lifetime except an explicit `TIMEOUT=0`;
  cancellation still cleans up their owned child processes in that case.
  No extra per-event Python runtime or executable build is introduced.
- Capture process/TTY identity in the hook process with macOS process APIs.
  Claude's first PreToolUse binding must finish (including title restoration)
  before the hook returns. Cached calls remain cheap.
- Native configuration decoding, synchronous round/start journal capture,
  readiness/capability checks and atomic spool publication replace hook business
  logic in Bash. Sender settings and event time remain authoritative.
- Native binding owns cache invalidation, failure backoff, cross-process locking,
  structured title snapshots, OSC writes, recovery and atomic result publication.
  Cancellation invalidates the result but never skips marker restoration.
- Native legacy-notification adaptation owns process identity checks, removal and
  action dispatch. Do not reintroduce dismiss-to-focus or kill unrelated PIDs.
- SQLite reads execute in-process, read-only and with bounded busy handling.
- Installed/native routes do not spawn bash, jq, ps, osascript, sleep or sqlite3.
  Build/install glue can remain shell. Source-only legacy runtime is retired
  under the accepted installation contract.
- Update hook wiring, installation manifests, documentation and automated tests.
  Verify actual executable modes as well as injected deterministic state tests.
  Build/sign in isolation; do not stop or replace the installed production app.

## Sequence

1. Revalidate toolchain/worktree; replace SQLite subprocess; native process and
   shared journal primitives.
2. Implement and test a native terminal-binding adapter; inject it into the app.
3. Implement native hook intake, transport and fallback-worker modes in the same
   binary, retaining synchronous Claude first-binding semantics.
4. Reduce shell entry points to compatibility launchers, update installers and
   exercise normal/old/absent-agent paths without invoking heavy shell helpers.
5. Run complete unit/integration/static/build gates and audit remaining process
   invocations before declaring the objective achieved.

Status: implementation and automated acceptance complete; not deployed or
published. Manual release acceptance remains separate below. The prior
`hook-migration.md` describes the historical first-stage implementation.

## Current responsibility boundaries

| Work | Native implementation |
| --- | --- |
| Read/validate hook JSON and sender settings, capture CLI ancestry and TTY | `HookIntake`, `ProcessIdentity`, `NativeHookRuntime` |
| Synchronous round/start capture, owner invalidation and shared rate journal | `RoundJournal`, `DirectoryLease` |
| Capability checks and atomic spool publication | `HookTransport`, `AtomicSpool` |
| OSC marker transaction, restoration, cache, backoff and retries | `NativeTerminalBinding`, `MacTerminalAutomation` |
| Notification policy, titles, settling and continuation | `HookEvent`, `HookProcessor`, `SessionContent` (SQLite C API) |
| Optional external backend invocation, clearing, actions and focus monitoring | `ExternalNotifications`, `NativeCommand` |
| Resident notification state, activation events and graceful shutdown | `Agent`, `SessionState` |

`hooks/*.sh` totals 61 lines, including a retired drain-only anchor and the
30-line shared bootstrap. It locates an already-built executable and `exec`s
it. Native production sources have only two `Process()` call sites: spawning the
same binary's worker, and invoking the selected external notification backend
with literal argv. No runtime helper launches Bash, jq, ps, osascript, sleep or
the sqlite3 CLI. Bash remains in compatibility entrypoints and build/install
glue; Python remains in the existing installer and test harness, not per-hook
runtime. Frozen shell fixtures are never installed and are not native coverage.

## Verification on 2026-09-16

Environment: macOS 26.6.2 arm64, Swift 6.4, `/bin/bash` 3.2.57. All commands run
in `claude-ghostty-notify_hook-migration`, not the installed application directory.

| Gate | Observed result |
| --- | --- |
| `swift test --package-path agent --quiet` | 144 tests in 20 suites passed |
| Release build via `bash scripts/build-agent.sh --build-only` | Passed |
| `codesign --verify --deep --strict build/ClaudeGhosttyNotify.app` | Passed |
| `test_native_hooks.py` with `NATIVE_TEST_BINARY` pointing at that release executable | 17 tests passed; real launchers, private PTY ancestry and native recording backends |
| `bash tests/test-agent.sh` against the same release bundle | 47 checks passed; real resident/spool/notifier state, shutdown and restart |
| `test_codex_hooks.py` | 50 passed: 36 frozen shell behavior checks plus 14 current installer config tests; not 50 native-runtime tests |
| `test_native_install.py` | 15 passed: real signed app, first install, upgrade, state/config preservation, missing/old runtime, failed copy/signature/publication, runtime-only resident/service guards and staged hook validation |
| Bash syntax and ShellCheck for hooks/install/build/test scripts; JSON validation; `git diff --check` | Passed |
| `swift-format lint --strict` on changed/new Swift files | Passed; full-tree lint reports existing formatting in unchanged `Ghostty.swift`, `Singleton.swift` and `MenuBarStateTests.swift`, left untouched |

The 17 native-entry tests and 15 installer tests also passed together against the
post-review signed release bundle (32 total). Before the review, worker shutdown
tests passed a further 20 repetitions, covering focus monitoring on/off and
unbounded notification lifetime. A test synchronization race was corrected: the parent can publish a
child PID before the recording child reaches main(), so shutdown testing now
waits for the first recorded delivery before sending SIGTERM. This preserves the
assertion that cancellation creates no extra fallback notification.

CI now builds/verifies the required native bundle and runs native-entry and
isolated-install gates. Frozen shell tests are explicitly labeled historical;
their four standalone suites passed 7 / 4 / 8 / 44 checks respectively. The
GitHub workflow itself has not run for these uncommitted changes. The final
release rebuild succeeded after the external directory rename; Swift emitted
stale-cache path warnings for the old location, not compilation failures.

Shutdown regressions were observed failing before their fixes:

- A real resident hung after SIGTERM. Its sampled main thread was inside
  `NSApplication.terminate` from a main-dispatch signal callback; the pending
  MainActor cleanup could not run. Termination now enters from a common-mode
  run-loop callback. The real-app suite asserts a 10-second exit bound and
  removal of all four liveness markers, instead of waiting indefinitely.
  Apple's [terminateLater contract](https://developer.apple.com/documentation/appkit/nsapplication/terminatereply/terminatelater)
  explains the nested modal loop involved.
- A stopped native worker left its blocking alerter process running. SIGTERM
  now cancels processor and delivery work, and structured child-result waiting
  propagates cancellation. Release integration tests cover focus monitoring
  both enabled and disabled, `TIMEOUT=0`, notice removal and no fallback on cancel.
- A child ignoring SIGTERM survived cancellation with no timeout. The native
  command runner now escalates termination for its directly owned child after
  one second; a real-child regression observes exit and reaping.

Only owned test instances were stopped. Real-app tests withdrew their synthetic
notification IDs. During final verification the workspace was externally renamed
from `ai-ghosty-notifier` to `ai-ghostty-notifier`; the same worktree and uncommitted
changes were preserved. No main-branch changes were made by this migration.

The subsequent local code review found and fixed five in-scope issues: pending
work created after cancellation across an actor hop; admission markers surviving
the start of shutdown; spool payloads temporarily readable before chmod; runtime-only
upgrades overlooking a manually started resident; and hook upgrades publishing
dependent launchers before staging their shared bootstrap. Regression tests cover
each correction. The verification table above reflects the post-review source.

## Hook-return latency

The pre-review release executable was measured after build and test processes had
finished: 5 warmups and 100 samples per case, on the same machine. These results
are a historical snapshot, not a measurement of the five review fixes. The baseline
is the frozen first-stage shell implementation, **not** the original base commit.

| Case | Before median / p95 | Native median / p95 |
| --- | --- | --- |
| Cached `PreToolUse` | 15.11 / 16.12 ms | 11.75 / 12.50 ms |
| `Stop` returning after spool publication | 48.95 / 50.51 ms | 13.12 / 14.02 ms |

These measurements use actual entrypoints, private state and a recording spool;
every Stop must publish one valid request. They do not measure notification
display, first uncached binding, cold AppKit launch, or isolated language startup.
The benchmark skill's machine-readable artifact includes the release binary hash
and fixture details: [native-hook-migration.json](../.ecc/benchmarks/native-hook-migration.json).

## Remaining acceptance work

- Required-app choice, installation/upgrade documentation and isolated installer
  regressions are complete. LaunchAgent registration and the human permission
  flow are documented but were not run against the user's installed service.
- Live Ghostty marker restoration, banner appearance, audible sound and clicking
  an actual notification still need manual acceptance. Injected terminal tests,
  recording backends and notifier bookkeeping do not prove those UI outcomes.
- Private focus/clear script overrides are explicitly retired. The
  [configuration review](native-hook-configuration.md) records retained defaults,
  empty-value behavior, sender-relative paths and the exact recovery limits.

The configuration review and controlled binding-failure tests are now implemented.
They found and fixed empty-backend routing, empty branding/group defaults, direct
clear with an empty directory override, sender-relative backend paths and skipped
single-tab recovery after a partial marker write. Session identifiers now retain
the old ASCII-only alphabet, including for pruning; corrupt nonfinite start
records become zero rather than making the captured event impossible to encode.

Approval of the installation contract is recorded separately from test results.
Passing automated gates does not imply deployment or manual UI acceptance.
