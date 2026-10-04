# Security

Please report a vulnerability privately rather than in a public issue: use
**Report a vulnerability** on the
[Security tab](https://github.com/Davie521/ai-ghostty-notifier/security), or
write to [daviefan@outlook.com](mailto:daviefan@outlook.com).

What the project can reach, for weighing a report:

- The hooks run inside your Claude Code and Codex CLI sessions, as you.
- The app asks for notification permission and for Automation control of
  Ghostty, nothing else. It makes no network connections.
- Releases are signed with a Developer ID and notarized. `setup.sh` checks the
  download against `SHA256SUMS` and refuses an app that is not a notarized
  Developer ID build.

Fixes go into the next release; there are no backports to older versions.
