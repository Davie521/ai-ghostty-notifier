# Changelog

What changed in each release. The one-command installer always fetches the
latest; the downloads are on [Releases](https://github.com/Davie521/ai-ghostty-notifier/releases).

## Unreleased

### Fixed

- A Claude turn that ends while its own background work is still running (a
  command sent to the background, a background subagent, a workflow, a
  monitor) no longer says the task is complete. Claude wakes the session when
  that work ends; the notification now comes when the session is really done,
  and counts the whole wait. Before, the stop posted "Finished after …" while
  the agent was only queueing, and the report that woke the session reset the
  clock, so the real completion was often too short to notify at all.
  A message sent while the turn runs joins that run. Background work left
  running from earlier rounds, such as a dev server, does not hold a round
  back, nor does Claude's own housekeeping, nor, while a subagent or workflow
  from before the round may have started them, new commands and monitors;
  whenever what already ran at a
  round's start is not on record (after an interrupted turn, in a resumed
  session's first round, after a failed write) the round notifies as before.
  A paused stop never leaves the hook, so an app older than the hook cannot
  announce it. Each round's clock now has an id of its own, so a completion
  delivered late cannot clear the clock of a turn begun after it, even in
  the same second, and a Claude stop goes to the app only if it advertises
  `clock-id-v1`. A report (a `<task-notification>` or a subagent's
  `<agent-message>` hand-back) arriving while a round is held, in the same
  Claude process, keeps that round going; only the awaited work's report is
  crossed off what it waits on.
  `GHOSTTY_NOTIFY_WAIT_BACKGROUND=0` restores the old behavior.

## 0.12.1 — 2026-11-21

### Fixed

- Quitting the app from the menu bar takes any `--no-return` nudge still on
  screen with it. Nothing ran its fifteen-second timer after a Quit, so it
  stayed until the app was next opened. A restart keeps it, as before, and its
  deadline comes back with the app.
- Clicking or closing a banner just as a newer one replaced it no longer takes
  the newer one's timer and bookkeeping with it, which left that one on screen
  with nothing to withdraw it.
- Being on the session's tab when a notification arrives can only bring its
  end forward: with a timeout shorter than three seconds, it used to put it
  back to three.

## 0.12.0 — 2026-11-21

### Added

- `--nudge --no-return` for a step the user does somewhere else, such as a
  captcha on their phone. It has no Go to tab button and does not wait for the
  user to come back: it goes by itself after fifteen seconds, and
  `--nudge-done` takes it back sooner once the step lands. `--nudge-done` takes back
  only a nudge, never the run's completion notification.

## 0.11.3 — 2026-11-15

### Changed

- A nudge is silent by default. It comes while the user is usually still
  nearby, so the sound is kept for long runs they walked away from;
  `GHOSTTY_NOTIFY_NUDGE_SOUND=1` brings it back.

## 0.11.2 — 2026-11-12

### Fixed

- A hook that finds the app stopped starts it again, as the reference always
  said it would. It asked macOS to start the app and exited at once, before the
  request had gone out, so the app was never started; on one day every hook for
  fourteen hours asked and the app stayed down. The hook now waits, up to three
  seconds, for macOS to take the request.

## 0.11.1 — 2026-11-12

### Fixed

- The app no longer stays quit after a logout or restart that does not happen.
  macOS asks every app to quit when one begins; the app took that as a request
  to stop, and launchd, which only restarted it after a crash, left it so until
  the next login, with every notification in between missing. Now only Quit in
  its menu keeps it down; whatever else stops it, launchd starts it again.

## 0.11.0 — 2026-11-12

### Added

- `ghostty-notify-agent --jump-waiting` goes where a click on the newest
  notification would, for a keyboard shortcut or a foot pedal to run. It exits
  1 when nothing is waiting, so a binding can fall back to something else, such
  as Ghostty's next tab. See [Jump to what's waiting](docs/reference.md#jump-to-what-is-waiting).

## 0.10.2 — 2026-11-04

### Fixed

- A click no longer pulls the session's window over when the app cannot tell
  which window it is. With the screen locked, for one, Accessibility reads no
  window at all, and the lists never paired; the jump then focused the tab
  where its window was, which brings a window on another Space to yours. Now
  it goes to the likeliest window out of view instead and looks again there,
  and focuses the tab only once it sees the window in view. If it still cannot
  tell, it brings Ghostty forward and selects nothing (`not placed` in the log).

## 0.10.1 — 2026-11-04

### Fixed

- A click whose session is on another Space goes straight there, in one slide.
  It used to step through every Space in between with your "Move left/right a
  space" shortcut, stopping on each; with Ghostty windows on more than one
  Space, the one passed was often the other window's, so the jump looked as if
  it went to the wrong window first. Now the app brings the session's window
  forward the way window switchers do, and macOS shows its Space. When no
  display switches within a second, it walks as before;
  `GHOSTTY_NOTIFY_SPACE_TRAVEL=walk` always walks.
- A click no longer goes to another Ghostty window's Space before the right one.
  Telling which window holds the tab paired Ghostty's list of windows with the
  window server's by their order, and the two orders can disagree: with
  windows on other Spaces, Ghostty listed the newest last where the window
  server had it first. The jump went to the wrong window, found the tab not
  there, came back and went on to the right one. Now the titles pair them, read
  on every Space, whenever they say which window is which; the order is left
  for windows titled alike.
- Jumps are quicker. Finding the tab's window reads Ghostty's windows and tabs
  in four Apple Events instead of one per tab: with a dozen tabs, the Space now
  starts to slide about half a second after the click instead of up to a second,
  and the whole jump takes about 1.1 seconds instead of 1.5.
- A jump that went to a wrong window first says so in the log: its `jump:` line
  keeps every trip, not only the last.

## 0.10.0 — 2026-11-04

### Changed

- The app has sounds of its own, a soft electric piano: a chord when a long
  run finishes, and a falling two-note call when a session nudges you, so the
  two are told apart by ear. The published app used to play the system default
  sound for both, since a release may not carry Apple's Glass and Ping; these
  are made at build time by `scripts/make-sounds.py`, so every build has them.
  terminal-notifier, used when the app is not running, still plays Glass and
  Ping.

## 0.9.1 — 2026-11-02

### Fixed

- A Codex nudge's Go to tab reaches the session's tab even before the session
  has had a run long enough to notify. Codex sessions get their tab recorded
  only at the end of such a run (while Codex works it rewrites the tab title
  ten times a second), so until then the button only brought Ghostty forward.
  Now the app looks for the one tab titled after the session, which is how
  Codex titles it; with none or several, it behaves as before.

## 0.9.0 — 2026-11-01

### Added

- Codex CLI can nudge you too. `--nudge` finds a Codex session through
  `CODEX_THREAD_ID`, and the Codex installer puts the `ghostty-nudge` skill in
  `$CODEX_HOME/skills/`. Codex's sandbox refuses writes under `~/.claude`, so
  there the nudge goes to a second queue in your own temporary directory,
  which the app reads for notifications only; Codex needs no escalation for
  it. With Codex run from Claude Code, the CLI nearest above the command is
  the one asking.

## 0.8.0 — 2026-11-01

### Added

- Claude Code can call you back part-way through a task.
  `ghostty-notify-agent --nudge "<what it needs>"` posts the session's own
  notification, with sound, whose Go to tab returns to its tab; it clears like
  the others. A new `ghostty-nudge` skill, which the installer copies into
  `<config>/skills/` and the plugin carries, tells Claude to use it only when it
  needs you to act (Face ID, a code, a scan, a decision) and you may not be
  watching. Codex CLI is not supported yet.

### Fixed

- A request the app could not remove from its queue, which happens only when
  the queue's folder has lost its permissions, is no longer acted on again on
  every pass; it waits until it can be removed (#70).

## 0.7.0 — 2026-10-27

### Fixed

- Clicking a notification for a session whose Ghostty window is on another
  Space takes you to that Space, instead of bringing the window to yours. The
  jump presses your own "Move left/right a space" shortcut on that display until
  the window's Space shows, then selects the tab. This needs the Accessibility
  permission, which macOS asks for the first time a click needs it, and both
  shortcuts switched on, as they are by default; without them a click works as
  before, and the menu bar item says when the permission is missing (#63).

### Added

- `ghostty-notify-agent --where <tab-id>` prints what a jump to that tab would
  find — its window, that window's Space, whether it is in view — and changes
  nothing.

## 0.6.2 — 2026-10-06

### Fixed

- Ctrl-C always stops the installer. Pressed just as one of its commands was
  finishing, it could be lost: the install went on and, in the end, killed any
  process of the previous version that had not stopped by itself, such as a
  hook of a busy session (#59).

## 0.6.1 — 2026-10-04

### Added

- The installer's summary says when Claude Code's own notification would come
  on top of this one, and names the setting that turns it into a terminal bell
  (#54).

### Fixed

- Installing unregisters every other copy of the app that macOS knows, such as
  one in the Trash, and lists those still on disk; uninstalling unregisters
  them all. Before, macOS could show an old icon, or start an old copy on a
  click (#50, #54).
- The install summary and the troubleshooting docs say that a notch can hide
  the menu bar icon (#49, #54).

## 0.6.0 — 2026-10-04

### Added

- `ghostty-notify-agent --test` posts one real notification through the running
  app, with a working **Go to tab**. When it cannot, it says why: the app is not
  running, or notifications are not allowed (#51).
- The installer ends with a test notification, and its summary says that tasks
  under 3 minutes never notify (#48, #51).
- A plugin installed without its companion app says so at the first prompt of
  each session, with the command that installs it (#51).
- Notifications and the menu bar in Simplified Chinese, following macOS (#47).

### Fixed

- A click checks that the right tab is selected, re-reads once after it
  settles, and focuses once more before giving up (#46).

## 0.5.2 — 2026-09-22

### Fixed

- Switching to the session's tab inside Ghostty withdraws its notification.
  Before, only coming back from another app did (#42).

### Changed

- From this release the license is MIT with the Commons Clause (#39). v0.5.1
  and earlier stay under the plain MIT License.

## 0.5.1 — 2026-09-22

### Fixed

- The installer's summary lists only what is left to do, and a release install
  is removed with `setup.sh --uninstall` (#37).

## 0.5.0 — 2026-09-22

The first release: a universal app, signed with a Developer ID and notarized,
and a one-command installer (#28, #35).

- A notification when a Claude Code or Codex CLI run ends: silent from 3
  minutes, with sound from 10 (#10).
- **Go to tab** brings back the session's tab, told apart by session rather
  than by folder. The notification goes away when you return to the tab, send
  the next prompt, or after 20 minutes (#5, #6).
- A menu bar list of the sessions waiting on you (#8).
- Tab bindings survive a Ghostty restart (#11).
- Hooks run in a native runtime with bounded waits: every terminal query has a
  deadline, and a hook ends itself after 12 seconds by default (#13, #15).
