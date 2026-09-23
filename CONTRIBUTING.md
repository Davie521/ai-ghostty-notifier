# Contributing

## Layout

| Path | What lives there |
| --- | --- |
| `agent/` | The Swift package. `NotifyCore` holds policy, session state and terminal binding, and is testable without AppKit; `Sources/ghostty-notify-agent/` is the resident menu bar app and the `--hook` / `--worker` entry points. Tests are under `agent/Tests/`. |
| `hooks/` | The launchers Claude Code and Codex CLI run. They only locate the installed app and `exec` it; every decision is made in Swift. `hooks.json` registers them for the plugin. |
| `scripts/` | Build, install, package and release glue. Shell stays here and in `install.sh`; nothing on the hook path depends on it. |
| `tests/` | Python and shell suites that drive the real executable. `test-live-*` need a running Ghostty and are run by hand, not by CI. |
| `docs/` | What a user or contributor needs now: the reference in both languages, the agent-driven install guide, releasing, and the incident record the code comments point at. Screenshots and the logo are under `docs/assets/`. |
| `.claude-plugin/` | Plugin and marketplace manifests. |

`README.md` and `README.zh-CN.md` are the front door; `docs/reference.md` and
`docs/reference.zh-CN.md` are everything else. Keep the two languages in step:
a change to one is a change to both.

The same goes for text the app shows. It goes through `UIText` in NotifyCore,
with the English as the key, and every key has a row in both
`agent/Resources/en.lproj/Localizable.strings` and
`agent/Resources/zh-Hans.lproj/Localizable.strings`; `UITextTests` fails when
the tables or the code drift apart.

## What stays out of the repository

Process records: verification runs, deployment reports, review transcripts,
benchmark dumps. They belong in the pull request description or an issue. The
one exception is a postmortem that explains a constraint the code still
carries; name it `docs/incident-<date>-<slug>.md` and point at it from the code
it explains. A design decision worth keeping goes into the reference, under
"How it works", together with its reason.

## Before opening a pull request

CI checks every shell file with `bash -n` and shellcheck, validates the JSON
manifests, runs the Swift tests, builds the app and runs the Python and shell
suites. The same sequence, plus the opt-in live checks that need a Ghostty
window, is under [Verification](docs/reference.md#verification).

A hook must never hold the CLI: it exits 0 on every failure and within
`GHOSTTY_NOTIFY_HOOK_DEADLINE`. The incident record in `docs/` is what happens
otherwise.

## Versions and releases

The version lives in two places that must agree: `CFBundleShortVersionString`
in `agent/Resources/Info.plist` and `version` in `.claude-plugin/plugin.json`.
The release workflow refuses a tag that does not match the plist. The steps are
in [docs/releasing.md](docs/releasing.md).

## Licensing your contribution

The project is under the MIT License with the Commons Clause (see
[LICENSE](LICENSE)), and its author also grants commercial licenses. By opening
a pull request you agree that your contribution is released under the same
terms, and you also grant Yifan Jiang a perpetual, worldwide, royalty-free,
irrevocable license to use, modify, sublicense and relicense it under any
terms, commercial ones included. You confirm that the contribution is your own
work, or that you have the right to submit it on these terms.
