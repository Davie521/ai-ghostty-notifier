#!/bin/bash
# Bootstrap only. JSON, process/TTY inspection and all policy live in Swift.
# Sourced by the stable entry filenames so existing hook trust stays valid.

GHOSTTY_NOTIFY_HOOKS_DIR="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)"
export GHOSTTY_NOTIFY_HOOKS_DIR
native_app=""
native_problem=""
native_installed="$HOME/Library/Application Support/claude-ghostty-notify/ClaudeGhosttyNotify.app"
native_candidates=(
    "${GHOSTTY_NOTIFY_AGENT_APP:-}" \
    "$native_installed" \
    "$GHOSTTY_NOTIFY_HOOKS_DIR/../build/ClaudeGhosttyNotify.app" \
    "$GHOSTTY_NOTIFY_HOOKS_DIR/ClaudeGhosttyNotify.app")
if [[ -n "${GHOSTTY_NOTIFY_NATIVE_APP+set}" ]]; then
    native_candidates=("$GHOSTTY_NOTIFY_NATIVE_APP")
fi
# An installed app whose binary is not executable is being replaced:
# scripts/install-agent.sh takes the bit off while it stops the previous
# version, and waits only for what runs the installed binary. That closes the
# way in for this HOME, not for one copy — falling through to a build beside
# these hooks would start a process nobody waits for.
if [[ -f "$native_installed/Contents/MacOS/ghostty-notify-agent" \
    && ! -x "$native_installed/Contents/MacOS/ghostty-notify-agent" ]]; then
    native_candidates=("")
    native_problem="the app is being reinstalled; this hook does nothing until it is back"
fi
for candidate in "${native_candidates[@]}"; do
    [[ -n "$candidate" && -f "$candidate/Contents/Resources/native-hook-v1" \
        && -x "$candidate/Contents/MacOS/ghostty-notify-agent" ]] || continue
    native_app="$candidate"
    break
done
if [[ -n "$native_app" ]]; then
    exec "$native_app/Contents/MacOS/ghostty-notify-agent" "$@"
fi
# Drain even on failure so the CLI never gets EPIPE. No jq or quiet fallback.
if [[ ! -t 0 ]]; then
    while IFS= read -r native_line || [[ -n "$native_line" ]]; do :; done
fi
printf 'ghostty-notify: %s.\n' "${native_problem:-native runtime missing or too old; build and install ClaudeGhosttyNotify.app}" >&2
exit 0
