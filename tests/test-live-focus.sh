#!/usr/bin/env bash
# Opt-in regression against two existing Ghostty windows. This switches focus.
# Usage: bash tests/test-live-focus.sh <source-tab-id> <target-tab-id>
# GHOSTTY_NOTIFY_NATIVE_APP may select a built bundle before deployment.
# The target's own selected-tab property is deliberately NOT the assertion:
# it reported success while the target window stayed behind the source window.
set -euo pipefail

[[ $# == 2 ]] || { echo "usage: test-live-focus.sh <source-tab-id> <target-tab-id>" >&2; exit 2; }
SOURCE_TAB=$1
TARGET_TAB=$2
for tab in "$SOURCE_TAB" "$TARGET_TAB"; do
    [[ "$tab" =~ ^[A-Za-z0-9_-]+$ && ${#tab} -le 128 ]] || exit 2
done
[[ "$SOURCE_TAB" != "$TARGET_TAB" ]] || exit 2
APP="${GHOSTTY_NOTIFY_NATIVE_APP:-$HOME/Library/Application Support/claude-ghostty-notify/ClaudeGhosttyNotify.app}"
BIN="$APP/Contents/MacOS/ghostty-notify-agent"
[[ -x "$BIN" ]] || { echo "native runtime missing: $BIN" >&2; exit 2; }

focus_source() {
    osascript <<APPLESCRIPT
tell application "Ghostty"
    repeat with w in windows
        repeat with t in tabs of w
            if id of t is "$SOURCE_TAB" then
                set originalWindowID to id of w
                focus (focused terminal of t)
                return originalWindowID
            end if
        end repeat
    end repeat
    error "Source tab is no longer open"
end tell
APPLESCRIPT
}

SOURCE_WINDOW=$(focus_source)
TARGET_WINDOW=$(osascript <<APPLESCRIPT
tell application "Ghostty"
    repeat with w in windows
        repeat with t in tabs of w
            if id of t is "$TARGET_TAB" then return id of w
        end repeat
    end repeat
    error "Target tab is no longer open"
end tell
APPLESCRIPT
)
[[ "$SOURCE_WINDOW" != "$TARGET_WINDOW" ]] || {
    echo "Two different windows are required for this regression" >&2; exit 2;
}
GHOSTTY_PID=$(osascript -e 'tell application "System Events" to return unix id of every application process whose bundle identifier is "com.mitchellh.ghostty"')
[[ "$GHOSTTY_PID" =~ ^[0-9]+$ ]] || { echo "Expected one running Ghostty process" >&2; exit 2; }

FIXTURE=$(mktemp -d /tmp/ghostty-live-focus.XXXXXX)
FOCUS_PID=""
cleanup() {
    if [[ -n "$FOCUS_PID" ]]; then
        kill -TERM "$FOCUS_PID" 2>/dev/null || true
        wait "$FOCUS_PID" 2>/dev/null || true
    fi
    focus_source >/dev/null 2>&1 || true
    rm -rf "$FIXTURE"
}
trap cleanup EXIT
SESSION=deadbeef-20260917-f0c0
jq -nc --arg tab "$TARGET_TAB" --arg pid "$GHOSTTY_PID" \
    '{tab_id:$tab,ghostty_pid:$pid}' > "$FIXTURE/$SESSION.json"

GHOSTTY_NOTIFY_SESSION_DIR="$FIXTURE" "$BIN" --focus "$SESSION" &
FOCUS_PID=$!
for ((attempt = 0; attempt < 150; attempt++)); do
    kill -0 "$FOCUS_PID" 2>/dev/null || break
    sleep 0.1
done
if kill -0 "$FOCUS_PID" 2>/dev/null; then
    echo "FAIL: native focus did not exit within 15 seconds" >&2
    exit 1
fi
wait "$FOCUS_PID"
FOCUS_PID=""
ACTUAL=$(osascript -e 'tell application "Ghostty" to return id of selected tab of front window')
if [[ "$ACTUAL" != "$TARGET_TAB" ]]; then
    echo "FAIL: native focus requested $TARGET_TAB, but front window selected $ACTUAL" >&2
    exit 1
fi
echo "PASS: native focus raised $TARGET_WINDOW and selected $TARGET_TAB in the front window"
