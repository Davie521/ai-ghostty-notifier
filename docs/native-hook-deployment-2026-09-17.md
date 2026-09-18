# Local deployment verification — 2026-09-17

The user requested a fresh test pass, deployment and live runtime testing.
The `refactor-hook-agent` worktree was built and deployed locally. Changes remain
uncommitted and have not been published to GitHub or the marketplace.

## Installed state

- App: `~/Library/Application Support/claude-ghostty-notify/ClaudeGhosttyNotify.app`.
- LaunchAgent: `io.github.davie521.cgnotify`; final observed PID `4412`.
- Runtime reports `native-hook-v1`; both capability markers name the live PID.
- Notification authorization: `authorized`; alert style: `alert` (persistent).
- Built and installed executable SHA-256:
  `7acccc4b35017d6c851c25ecdad3a8d8ad4707f96b3b558d53e6d52d495b59a1`.
- Claude and Codex launchers were upgraded with their existing installers.
  Byte comparisons confirmed the existing Claude settings, Codex hook
  registrations, Codex config.toml and notification settings were preserved.
- Pre-deployment app, LaunchAgent, hooks and configuration backup:
  `~/Library/Application Support/claude-ghostty-notify/backups/pre-native-20260917.lHIy8W/`.
  The old app's signature was verified before replacement.

## Verification

| Gate | Result |
| --- | --- |
| Swift tests, final source | 144 tests in 20 suites passed |
| Release build and strict code-signature verification | Passed |
| Native entrypoint/worker tests, final release | 17 passed |
| Isolated installation/upgrade tests, final release | 15 passed |
| Resident integration, final release | 47 checks passed |
| Codex historical fixtures and installer config checks | 50 passed before focus-only changes |
| Historical standalone shell suites | 7 / 4 / 8 / 44 checks passed |
| Shell syntax, ShellCheck, JSON, diff whitespace | Passed |
| Strict Swift formatting of changed/new source | Passed; unchanged historical formatting remains outside this check |
| Live cross-window focus regression | Original installed runtime failed; final build passed three consecutive runs; installed final copy passed |
| Final installed focus/clear smoke | Correct frontmost tab verified; notification withdrawn immediately on Ghostty activation, before its 120-second expiry |

`tests/test-live-focus.sh SOURCE_TAB TARGET_TAB` is explicitly opt-in: it requires
two existing Ghostty windows and switches focus. It uses private binding state,
the real native `--focus` entrypoint and an assertion against the **front window**,
with a 15-second process bound. It is not an unattended CI test.

## Issues found by live testing

The original focus script could select a tab in a background window while
reporting success from that window's own selection. The regression caught this
even though the ordinary suites passed. The final implementation focuses the
target terminal in one operation, checks the front window's selected tab and
avoids a second app-wide activation after a successful jump. Selecting a tab
before focusing its terminal also produced incorrect live selection results.

A native focus process additionally hit a WindowServer main-queue assertion
while NSAppleScript pumped events from its background queue. Focus now executes
on the main queue with a three-second Apple Event timeout; read-only queries
remain on their background queue. Native modes maintain the main CFRunLoop,
including signal-driven cancellation. Worker cancellation and resident shutdown
regressions passed again on the final executable.

> **Correction, 2026-09-18.** Leaving read-only queries on a background queue
> was the defect behind the PreToolUse hang that began with this deployment:
> native modes have no `NSApplication`, and a background `NSAppleScript` send in
> such a process never sees its reply. The checks above did not reach that path.
> See [the incident record](incident-2026-09-17-pretooluse-hang.md).

The first live binding attempt, started approximately 300 ms after creating a
new window, did not produce a binding. A second window allowed to settle for two
seconds bound successfully and restored the exact title `Swift migration smoke
— 中文`. This observation is not proof that every cold-window timing is covered.

## Notification evidence and remaining manual acceptance

Installed Claude launchers processed prompt, PreToolUse and Stop events; the
successful live Stop returned in 17.23 ms and reached the resident notification
pipeline. Real Codex prompt events also appeared in the deployed resident log.

The user clicked the first test notification at 16:50:26 local time. macOS
recorded a notification-content response and the agent invoked the target-tab
jump. This preceded the stronger cross-window fix, so it establishes the click
callback path, not final foreground-window correctness. The final native focus
regression and focus/clear smoke established the latter separately.

The system notification log marked test notices with
`interruptionSuppression: delay delivery` under the active Focus configuration.
Screenshots did not establish an immediate test banner, and audible sound was
not confirmed by the user. No Focus preferences were changed. Test notices were
withdrawn; a final explicitly labeled retry notification is bounded to 180 seconds.

The backup is local rollback material, not a published release. Manual sound and
immediate-banner acceptance under the user's desired Focus settings remains open.

### Final notification-click acceptance

At 17:24:19 local time, the user clicked a notification posted by the final
installed build and confirmed it returned to the current Codex conversation.
The resident log recorded identical requested and selected tab IDs, followed by
`jump: focused ..., verified selected`. A second notification jump at 17:24:24
also logged a matching selection. This verifies the installed notification-click
path, in addition to the separate native focus regression above.

The earlier report that notification clicks did nothing was traced to two
notifications posted before the app upgrade. macOS received those clicks at
17:18:40 and 17:18:41, but logged `Failed to find appropriate application to
launch` for their old notification source identity; neither response reached the
resident. The current installed app resolved correctly through LaunchServices,
and fresh notifications worked without another code change or reinstall. Old
pre-upgrade notices should be dismissed; they are not evidence that a newly
posted notification's tab binding failed. Sound remains unconfirmed.
