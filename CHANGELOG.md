# Changelog

What changed in each release. The one-command installer always fetches the
latest; the downloads are on [Releases](https://github.com/Davie521/ai-ghostty-notifier/releases).

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
