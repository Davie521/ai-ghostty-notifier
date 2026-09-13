# Codex notification verification

Verified locally on 2026-09-07 with Codex CLI 0.153.4 and Ghostty 1.3.1.

- 25 Codex adapter/installer/integration tests passed, plus 63 existing Claude
  notification regression checks. ShellCheck, Bash syntax checks, Python 3.9
  callback compilation and `git diff --check` passed.
- A real Codex CLI process ran in a real Ghostty tab against a local deterministic
  Responses fixture. The native `agent-turn-complete` callback reached the
  adapter and an actual macOS **Codex ✅** notification was visually confirmed.
  The test alone lowered the minimum elapsed time to zero. No paid model call
  was needed to exercise the native completion callback.
- The OSC-2 round-trip saved `tab-ca06cca00`, exactly the ID returned by Ghostty
  when creating that test tab. Same-directory routing does not depend on cwd.
- Codex-specific tests exercise the real focus and clear shell scripts with
  stubbed Apple Events and notification delivery: both body clicks and **Go to
  tab** route to the Codex binding; dismiss never focuses; another selected tab
  retains the alert; returning to the target clears it. Physical clicking was
  not part of the desktop smoke test.
- `codex app-server --strict-config` plus `config/read` confirmed the installed
  top-level notify array and `tui.notifications = ["approval-requested"]`.
  All six installed scripts were compared byte-for-byte with repository source.
- Installed settings preserve the user's Claude thresholds: minimum 120 seconds,
  sound at 600 seconds, timeout 1200 seconds, clear-on-focus enabled.

Runtime code is copied to `~/.codex/ghostty-notify/`; moving the repository does
not affect it. Pre-change configs are backed up under `~/.codex/backups/`.
Existing Codex CLI processes must restart to load the new `notify` setting.
Test processes, temporary test tabs and the local response server were stopped.
