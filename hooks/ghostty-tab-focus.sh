#!/bin/bash
# Focus the Ghostty tab associated with a Claude session.
# Invoked by the alerter click-handler subshell in ghostty-notify.sh when
# the user clicks "Go to tab".
# Arg $1: Claude session_id

SESSION_ID="${1:-}"

# Always bring Ghostty to front (degraded behavior if we can't find the tab)
osascript -e 'tell application "Ghostty" to activate' 2>/dev/null

[[ -z "$SESSION_ID" ]] && exit 0

# The session id arrives via a notification callback; constrain it to the
# UUID-ish shape Claude Code emits BEFORE building a path from it — anything
# else (slashes, dots) could traverse to a .json outside SAVE_DIR.
[[ "$SESSION_ID" =~ ^[a-fA-F0-9-]+$ ]] || exit 0

SAVE_DIR="${GHOSTTY_NOTIFY_SESSION_DIR:-$HOME/.claude/notifications/ghostty-sessions}"
SAVE_FILE="$SAVE_DIR/${SESSION_ID}.json"
[[ -f "$SAVE_FILE" ]] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

TAB_ID=$(jq -r '.tab_id // empty' "$SAVE_FILE" 2>/dev/null)
[[ -z "$TAB_ID" ]] && exit 0

# Find the tab across all windows, raise its parent window, then select it.
# `activate window` is required for multi-window setups: without it, the tab
# gets selected silently inside a background window and the user sees nothing
# change. `select tab` alone does NOT raise the parent window.
#
# TAB_ID is data from a state file — pass it via env + `system attribute`
# (the same pattern ghostty-tab-save.sh uses for MARKER) instead of
# interpolating it into the AppleScript source, where a crafted value could
# inject arbitrary script (e.g. `do shell script`).
TARGET_TAB_ID="$TAB_ID" osascript <<'APPLESCRIPT' 2>/dev/null
set targetId to (system attribute "TARGET_TAB_ID")
tell application "Ghostty"
    repeat with w in every window
        repeat with t in every tab of w
            if (id of t as text) is targetId then
                activate window w
                select tab t
                return
            end if
        end repeat
    end repeat
end tell
APPLESCRIPT

exit 0
