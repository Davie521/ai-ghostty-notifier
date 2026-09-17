#!/bin/bash
# Bootstrap only. JSON, process/TTY inspection and all policy live in Swift.
# Sourced by the stable entry filenames so existing hook trust stays valid.

GHOSTTY_NOTIFY_HOOKS_DIR="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)"
export GHOSTTY_NOTIFY_HOOKS_DIR
native_app=""
native_candidates=(
    "${GHOSTTY_NOTIFY_AGENT_APP:-}" \
    "$HOME/Library/Application Support/claude-ghostty-notify/ClaudeGhosttyNotify.app" \
    "$GHOSTTY_NOTIFY_HOOKS_DIR/../build/ClaudeGhosttyNotify.app" \
    "$GHOSTTY_NOTIFY_HOOKS_DIR/ClaudeGhosttyNotify.app")
if [[ -n "${GHOSTTY_NOTIFY_NATIVE_APP+set}" ]]; then
    native_candidates=("$GHOSTTY_NOTIFY_NATIVE_APP")
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
printf '%s\n' 'ghostty-notify: native runtime missing or too old; build and install ClaudeGhosttyNotify.app.' >&2
exit 0
