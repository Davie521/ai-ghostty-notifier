#!/bin/bash
# Clear the round-start timestamp when the user submits a new prompt.
# Runs on UserPromptSubmit.
#
# The Stop hook clears the .start file at the end of a round, but Stop does
# NOT fire when the user interrupts a round (Esc/Ctrl-C) or the process
# dies. The stale timestamp would then survive into the next round and make
# its elapsed time — and therefore the notification tier and the "Finished
# after Xm Ys" text — wildly wrong. A new user prompt is always a round
# boundary, so clearing here re-arms the timer no matter how the previous
# round ended.

[[ "${TERM_PROGRAM:-}" != "ghostty" ]] && [[ -z "${GHOSTTY_RESOURCES_DIR:-}" ]] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

HOOK_DATA=""
if [[ ! -t 0 ]]; then
    HOOK_DATA=$(cat 2>/dev/null || true)
fi
[[ -z "$HOOK_DATA" ]] && exit 0

SESSION_ID=$(printf '%s' "$HOOK_DATA" | jq -r '.session_id // empty' 2>/dev/null)
[[ -z "$SESSION_ID" ]] && exit 0
[[ "$SESSION_ID" =~ ^[a-fA-F0-9-]+$ ]] || exit 0

SAVE_DIR="${GHOSTTY_NOTIFY_SESSION_DIR:-$HOME/.claude/notifications/ghostty-sessions}"
rm -f "$SAVE_DIR/${SESSION_ID}.start"

# A new prompt in this session proves the user is back at this tab — any
# still-visible completion notification for it is stale. Clear it (and its
# focus watcher) in the background so prompt submission isn't delayed.
# Sibling resolution mirrors ghostty-notify.sh's FOCUS_SCRIPT lookup.
#
# This is the same feature as the clear-on-focus watcher and honors the
# same switch; keep the accepted off values in sync with ghostty-notify.sh.
case "${GHOSTTY_NOTIFY_CLEAR_ON_FOCUS:-1}" in
    0|false|no|off|FALSE|NO|OFF) exit 0 ;;
esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
CLEAR_SCRIPT="${GHOSTTY_NOTIFY_CLEAR_SCRIPT:-$SCRIPT_DIR/ghostty-notify-clear.sh}"
[[ -x "$CLEAR_SCRIPT" ]] || CLEAR_SCRIPT="$HOME/.claude/hooks/ghostty-notify-clear.sh"
if [[ -x "$CLEAR_SCRIPT" ]]; then
    # Stamp the request time: the clear runs in the background and must not
    # take down a notification delivered for the round that starts now — a
    # permission prompt under GHOSTTY_NOTIFY_ON_PROMPT=1 can fire within
    # that window, and killing it unseen would stall the session silently.
    GHOSTTY_NOTIFY_CLEAR_BEFORE="$(date +%s)" \
        "$CLEAR_SCRIPT" "$SESSION_ID" </dev/null >/dev/null 2>&1 &
    disown
fi
exit 0
