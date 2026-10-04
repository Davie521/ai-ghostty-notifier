# Changelog

What changed in each release. The one-command installer always fetches the
latest; the downloads are on [Releases](https://github.com/Davie521/ai-ghostty-notifier/releases).

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
