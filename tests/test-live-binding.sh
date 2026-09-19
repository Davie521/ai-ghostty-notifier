#!/usr/bin/env bash
# Opt-in regression against a running Ghostty: a PreToolUse hook for a session
# with no cached binding must bind its tab quickly, every time.
#
# This is the path that blocked Claude Code for 600 seconds per tool call on
# 2026-09-17 (docs/incident-2026-09-17-pretooluse-hang.md). No unattended suite
# reaches it: it needs a real Ghostty answering real Apple Events, from a
# short-lived process. It briefly retitles one tab, as every real hook does.
#
# Usage: run inside the Ghostty tab to test, or name its terminal:
#   bash tests/test-live-binding.sh
#   GHOSTTY_NOTIFY_TTY=/dev/ttys012 bash tests/test-live-binding.sh
# RUNS (20), MAX_SECONDS per hook (3) and LIMIT_SECONDS before a hook is
# declared hung (8) are overridable. GHOSTTY_NOTIFY_NATIVE_APP may select a
# built bundle before deployment.
set -euo pipefail

RUNS=${RUNS:-20}
MAX_SECONDS=${MAX_SECONDS:-3}
LIMIT_SECONDS=${LIMIT_SECONDS:-8}
APP="${GHOSTTY_NOTIFY_NATIVE_APP:-$HOME/Library/Application Support/claude-ghostty-notify/ClaudeGhosttyNotify.app}"
BIN="$APP/Contents/MacOS/ghostty-notify-agent"
[[ -x "$BIN" ]] || { echo "native runtime missing: $BIN" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq is required by this test" >&2; exit 2; }

TTY_PATH=${GHOSTTY_NOTIFY_TTY:-$(tty 2>/dev/null || true)}
[[ "$TTY_PATH" == /dev/* && -c "$TTY_PATH" ]] || {
    echo "Run inside a Ghostty tab, or set GHOSTTY_NOTIFY_TTY to its terminal device" >&2
    exit 2
}
osascript -e 'tell application "System Events" to return exists (application process "Ghostty")' \
    2>/dev/null | grep -qx true || { echo "Ghostty is not running" >&2; exit 2; }

now() { /usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }

FIXTURE=$(mktemp -d /tmp/ghostty-live-binding.XXXXXX)
# Hex and dashes only: intake silently ignores any other session id. Unique per
# invocation, so the cleanup below only ever acts on markers this run wrote: two
# overlapping runs would otherwise restore each other's tabs into their own.
SESSION_PREFIX=$(uuidgen | tr 'A-F' 'a-f' | cut -c1-13)
[[ "$SESSION_PREFIX" =~ ^[0-9a-f]{8}-[0-9a-f]{4}$ ]] || { echo "uuidgen gave no usable prefix" >&2; exit 2; }
HOOK_PID=""

payload_for() {
    jq -nc --arg id "$1" --arg cwd "$PWD" '{session_id:$id,hook_event_name:"PreToolUse",cwd:$cwd}'
}

outstanding_records() {
    local record
    for record in "$FIXTURE"/*.marker.json; do
        [[ -e "$record" ]] && printf '%s\n' "$record"
    done
    return 0
}

# Ids of the tabs still titled with a marker from this run. Fails when Ghostty
# cannot be asked, which is not the same as "none".
marked_tabs() {
    osascript <<APPLESCRIPT 2>/dev/null
with timeout of 5 seconds
    tell application "Ghostty"
        set found to ""
        repeat with w in windows
            repeat with t in tabs of w
                if (name of t as text) contains "_TAB_MARKER_${SESSION_PREFIX}-" then
                    set found to found & (id of t as text) & linefeed
                end if
            end repeat
        end repeat
        return found
    end tell
end timeout
APPLESCRIPT
}

# Every marker of this run went to TTY_PATH, so a tab showing one is that
# terminal's tab and its title can be written back there.
restore_titles() {
    local tab record title
    while IFS= read -r tab; do
        [[ -n "$tab" ]] || continue
        title=""
        # Runs share a tab, so a later record may hold an earlier run's marker
        # as the "title". The earliest record that knew the tab has the real one.
        while IFS= read -r record; do
            title=$(jq -r --arg id "$tab" \
                '[.tabs[] | select(.id == $id) | .title | select(test("_TAB_MARKER_") | not)][0] // ""' \
                "$record" 2>/dev/null || true)
            if [[ -n "$title" ]]; then break; fi
        done < <(outstanding_records)
        [[ -n "$title" ]] || continue
        # The runtime's packet: no control characters inside the OSC sequence.
        title=$(printf '%s' "$title" | /usr/bin/perl -CSD -pe 's/[\x{00}-\x{1f}\x{7f}\x{9c}]//g')
        printf '\033]2;%s\033\\' "$title" >"$TTY_PATH"
    done
}

cleanup() {
    local marked
    if [[ -n "$HOOK_PID" ]]; then
        kill -KILL "$HOOK_PID" 2>/dev/null || true
        wait "$HOOK_PID" 2>/dev/null || true
    fi
    # A hook that was killed or gave up mid-lookup can leave its marker on a
    # real tab, and the only copy of that tab's title is a record in this
    # fixture. Put the title back before anything is deleted. Asking the runtime
    # to recover would not do: it honours a killed hook's lease for two minutes,
    # and a record taken while an earlier marker was showing names that marker.
    if [[ -n "$(outstanding_records)" ]]; then
        marked=$(marked_tabs) || marked="unknown"
        if [[ -n "$marked" && "$marked" != "unknown" ]]; then
            restore_titles <<<"$marked"
            sleep 0.3
            marked=$(marked_tabs) || marked="unknown"
        fi
        if [[ -n "$marked" ]]; then
            echo "A tab may still show a binding marker as its title." >&2
            echo "The records holding its real title were kept in $FIXTURE" >&2
            return
        fi
    fi
    rm -rf "$FIXTURE"
}
trap cleanup EXIT

# A private session directory: never the user's bindings, and no stall stamp or
# permission sentinel left behind by this run can affect real sessions.
export GHOSTTY_NOTIFY_SESSION_DIR="$FIXTURE" GHOSTTY_NOTIFY_TTY="$TTY_PATH"
export GHOSTTY_NOTIFY_AGENT_APP="" TERM_PROGRAM=ghostty

failures=0
slowest=0
bound_tab=""
for ((run = 1; run <= RUNS; run++)); do
    session=$(printf '%s-%04d' "$SESSION_PREFIX" "$run")
    payload=$(payload_for "$session")
    started=$(now)
    "$BIN" --hook claude PreToolUse <<<"$payload" >/dev/null 2>"$FIXTURE/stderr" &
    HOOK_PID=$!
    hung=1
    for ((tick = 0; tick < LIMIT_SECONDS * 20; tick++)); do
        if ! kill -0 "$HOOK_PID" 2>/dev/null; then hung=0; break; fi
        sleep 0.05
    done
    if [[ "$hung" == 1 ]]; then
        echo "FAIL run $run: hook still running after ${LIMIT_SECONDS}s" >&2
        kill -KILL "$HOOK_PID" 2>/dev/null || true
        wait "$HOOK_PID" 2>/dev/null || true
        HOOK_PID=""
        failures=$((failures + 1))
        continue
    fi
    status=0
    wait "$HOOK_PID" || status=$?
    HOOK_PID=""
    elapsed=$(/usr/bin/perl -e 'printf "%.3f", $ARGV[1] - $ARGV[0]' "$started" "$(now)")
    tab=$(jq -r '.tab_id // ""' "$FIXTURE/$session.json" 2>/dev/null || true)
    slowest=$(/usr/bin/perl -e 'printf "%.3f", $ARGV[0] > $ARGV[1] ? $ARGV[0] : $ARGV[1]' "$elapsed" "$slowest")
    problem=""
    [[ "$status" == 0 ]] || problem="exit status $status"
    /usr/bin/perl -e 'exit($ARGV[0] <= $ARGV[1] ? 0 : 1)' "$elapsed" "$MAX_SECONDS" ||
        problem="${problem:+$problem, }took ${elapsed}s (limit ${MAX_SECONDS}s)"
    [[ -n "$tab" ]] || problem="${problem:+$problem, }no tab was bound: $(tr '\n' ' ' <"$FIXTURE/stderr")"
    if [[ -n "$problem" ]]; then
        echo "FAIL run $run: $problem" >&2
        failures=$((failures + 1))
    else
        bound_tab=$tab
        echo "  ok  run $run: ${elapsed}s -> $tab"
    fi
done

if [[ -n "$bound_tab" ]]; then
    title=$(osascript <<APPLESCRIPT
tell application "Ghostty"
    repeat with w in windows
        repeat with t in tabs of w
            if (id of t as text) is "$bound_tab" then return name of t as text
        end repeat
    end repeat
    return ""
end tell
APPLESCRIPT
    )
    if [[ "$title" == *TAB_MARKER* ]]; then
        echo "FAIL: the tab title was left as a marker: $title" >&2
        failures=$((failures + 1))
    fi
fi

if [[ "$failures" != 0 ]]; then
    echo "FAIL: $failures of $RUNS hooks hung, were slow or did not bind" >&2
    exit 1
fi
echo "PASS: $RUNS unbound PreToolUse hooks bound $bound_tab, slowest ${slowest}s"
