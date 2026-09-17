#!/bin/bash
# Save Ghostty tab info for this Claude session.
# Runs on PreToolUse — captures (once per session) the exact tab that hosts
# this Claude process using an OSC 2 marker round-trip:
#   1. Find Claude's TTY via process tree
#   2. Snapshot all Ghostty tab titles
#   3. Write a unique marker via OSC 2 to Claude's TTY
#   4. Query Ghostty for the tab whose title is the marker — that's us
#   5. Write the original title back via OSC 2 to clean up
#
# The Codex adapter runs it after a turn instead, from the agent's bounded
# child helper (or a detached worker on the legacy fallback path):
# GHOSTTY_NOTIFY_TTY names the terminal (the CLI is no longer an ancestor)
# and GHOSTTY_NOTIFY_MARKER_RETRY_DELAYS spaces out extra round-trips while
# the Codex TUI is still animating its title.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=hooks/hook-common.sh
source "$SCRIPT_DIR/hook-common.sh"
hook_read || exit 0
hook_current_round || exit 0

SAVE_DIR="${GHOSTTY_NOTIFY_SESSION_DIR:-$HOME/.claude/notifications/ghostty-sessions}"
SAVE_FILE="$SAVE_DIR/${SESSION_ID}.json"
START_FILE="$SAVE_DIR/${SESSION_ID}.start"
ATTEMPTS_FILE="$SAVE_DIR/${SESSION_ID}.attempts"
AS_SENTINEL="$SAVE_DIR/applescript-unavailable"
mkdir -p "$SAVE_DIR"

# Record task start time only if not already set. Cleared by the Stop hook
# and by ghostty-round-reset.sh on UserPromptSubmit (the latter covers
# interrupted rounds, where Stop never fires and a stale timestamp would
# corrupt the next round's elapsed time).
if [[ "${GHOSTTY_NOTIFY_BIND_ONLY:-0}" != 1 && "${GHOSTTY_NOTIFY_PROCESS_NAME:-claude}" != codex && ! -f "$START_FILE" ]]; then
    hook_context tool || exit 0
fi

# Skip tab-id resolution if already saved for this session — unless Ghostty
# has been restarted since. Tab ids are object identifiers inside the Ghostty
# process, so a restart invalidates every binding while the sessions in its
# tabs live on; a click then finds no tab and only raises Ghostty. The
# process id is the cheapest witness: one LaunchServices lookup per tool
# call, no Apple Events. A binding with no recorded pid predates this check
# and is resolved once more. (Asked of LaunchServices rather than pgrep:
# pgrep cannot see Ghostty's process at all on macOS 26 — neither by name
# nor by full command line — while ps lists it.)
GHOSTTY_PID=$(lsappinfo info -only pid com.mitchellh.ghostty 2>/dev/null | tr -dc '0-9')
binding_current() {
    [[ -f "$SAVE_FILE" ]] || return 1
    [[ -n "$GHOSTTY_PID" ]] || return 0
    [[ "$(jq -r '.ghostty_pid // empty' "$SAVE_FILE" 2>/dev/null)" == "$GHOSTTY_PID" ]]
}
binding_current && exit 0
CWD=$(printf '%s' "$HOOK_DATA" | jq -r '.cwd // empty' 2>/dev/null)

# The Ghostty pid rides along so a later run can tell this binding from one
# issued by an earlier Ghostty; left out when no Ghostty process was found.
write_binding() {
    local result=0 tmp="$SAVE_FILE.$$"
    hook_lock "$SAVE_DIR/${SESSION_ID}.round-lock" || return 1
    if ! hook_current_round; then
        hook_unlock "$SAVE_DIR/${SESSION_ID}.round-lock"
        return 1
    fi
    jq -nc --arg tab "$1" --arg cwd "$CWD" --arg pid "$GHOSTTY_PID" \
        '{tab_id: $tab, cwd: $cwd} + (if $pid == "" then {} else {ghostty_pid: $pid} end)' \
        > "$tmp" && mv -f "$tmp" "$SAVE_FILE" || result=$?
    rm -f "$tmp"
    hook_unlock "$SAVE_DIR/${SESSION_ID}.round-lock"
    return "$result"
}

# Negative cache: if a previous attempt showed Ghostty isn't scriptable
# (AppleScript support shipped in Ghostty 1.3; the macOS Automation
# permission can be denied), skip the whole dance instead of paying
# sleep + two osascript spawns on every tool call. Retry daily in case the
# user upgraded Ghostty or granted the permission.
if [[ -f "$AS_SENTINEL" ]]; then
    SENTINEL_AGE=$(( $(date +%s) - $(stat -f %m "$AS_SENTINEL" 2>/dev/null || echo 0) ))
    (( SENTINEL_AGE < 86400 )) && exit 0
    rm -f "$AS_SENTINEL"
fi

# Bounded retries: in environments where the marker can never round-trip
# (e.g. claude inside tmux, where OSC 2 retitles the tmux pane rather than
# the Ghostty tab), give up after 3 attempts and record an empty tab_id so
# the focus script degrades to just activating Ghostty.
ATTEMPTS=$(cat "$ATTEMPTS_FILE" 2>/dev/null || echo 0)
[[ "$ATTEMPTS" =~ ^[0-9]+$ ]] || ATTEMPTS=0

# Prune stale per-session state. Runs here (at most a few times per
# session) rather than on every PreToolUse. Includes *.start: a round that
# ended via interrupt/crash never clears its own start file. The notify
# pidfiles are the same story — watchers deliberately leave theirs behind
# rather than race a successor for the filename.
find "$SAVE_DIR" -type f \( -name '*.json' -o -name '*.start' -o -name '*.attempts' \
    -o -name '*.alerter-pid' -o -name '*.watch-pid' -o -name '*.callback-lock' \
    -o -name '*.codex-owner' -o -name '*.title' \) -mtime +7 -delete 2>/dev/null

# ── Locate Claude's controlling TTY ────────────────────────────────────────
find_claude_tty() {
    local pid=$$
    local depth=10
    local process_name="${GHOSTTY_NOTIFY_PROCESS_NAME:-claude}"
    case "$process_name" in claude|codex) ;; *) return 1 ;; esac
    while (( depth-- > 0 )) && [[ "$pid" -gt 1 ]]; do
        local parent
        parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [[ -z "$parent" || "$parent" -le 1 ]] && break
        local cmd
        cmd=$(ps -o command= -p "$parent" 2>/dev/null)
        case "$cmd" in
            "$process_name"|"$process_name "*|*/"$process_name"|*/"$process_name "*)
                local tty
                tty=$(ps -o tty= -p "$parent" 2>/dev/null | tr -d ' ')
                [[ -n "$tty" && "$tty" != "??" ]] && printf '/dev/%s\n' "$tty"
                return
                ;;
        esac
        pid="$parent"
    done
    return 1
}

TTY_PATH="${GHOSTTY_NOTIFY_TTY:-}"
[[ -n "$TTY_PATH" ]] || TTY_PATH=$(find_claude_tty)
[[ -z "$TTY_PATH" ]] && exit 0
[[ -w "$TTY_PATH" ]] || exit 0

# Extra marker round-trips, as seconds to wait before each. Only the Codex
# adapter sets this; an unparsable value means the single default pass.
RETRY_DELAYS=()
if [[ "${GHOSTTY_NOTIFY_MARKER_RETRY_DELAYS:-}" =~ ^[0-9.[:space:]]+$ ]]; then
    read -ra RETRY_DELAYS <<< "$GHOSTTY_NOTIFY_MARKER_RETRY_DELAYS"
fi

MARKER="__${GHOSTTY_NOTIFY_PROCESS_NAME:-CLAUDE}_TAB_MARKER_${SESSION_ID}__"
TAB_ID=""
MARKER_WRITTEN=0

# ── Serialize the marker round-trip ────────────────────────────────────────
# Claude Code batches parallel tool calls, so two PreToolUse instances can
# both pass the SAVE_FILE check on a session's first round. Unserialized,
# instance B can snapshot instance A's marker as the tab's "original" title
# and restore it on exit — permanently renaming the tab to the marker
# string. One dance at a time; losers just exit (the winner writes
# SAVE_FILE for everyone).
LOCK_DIR="$SAVE_DIR/${SESSION_ID}.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    # A crashed holder leaves the lock behind; break it after 120s.
    LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0) ))
    (( LOCK_AGE < 120 )) && exit 0
    rm -rf "$LOCK_DIR" 2>/dev/null
    mkdir "$LOCK_DIR" 2>/dev/null || exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

# Another instance may have completed the dance while we raced for the lock.
binding_current && exit 0

# ── Snapshot all tab titles BEFORE marker ──────────────────────────────────
SNAPSHOT=""
snapshot_titles() {
    SNAPSHOT=$(osascript <<'APPLESCRIPT' 2>/dev/null
tell application "Ghostty"
    set out to ""
    repeat with w in every window
        repeat with t in every tab of w
            try
                set out to out & (id of t) & "\t" & (name of t) & linefeed
            end try
        end repeat
    end repeat
    return out
end tell
APPLESCRIPT
    )
}

# Verify Ghostty is actually scriptable BEFORE touching the tab title. If
# osascript can't control Ghostty (no AppleScript support, or the user
# denied the Automation prompt), writing the marker would leave the title
# stuck as the marker string with no way to query or restore it — and the
# failed round-trip would repeat on every single tool call.
if ! snapshot_titles; then
    date +%s > "$AS_SENTINEL" 2>/dev/null
    exit 0
fi

# Always attempt restore on exit, even on error. Re-queries Ghostty for any
# tab still showing the marker (covers the case where our primary resolve
# failed but the title is stuck). This makes M1+M2 bulletproof.
restore_marker_title() {
    [[ $MARKER_WRITTEN -eq 0 ]] && return 0
    local target="$TAB_ID"
    if [[ -z "$target" ]]; then
        target=$(MARKER="$MARKER" osascript <<'APPLESCRIPT' 2>/dev/null
set targetMarker to (system attribute "MARKER")
tell application "Ghostty"
    repeat with w in every window
        repeat with t in every tab of w
            try
                if (name of t as text) is targetMarker then
                    return id of t
                end if
            end try
        end repeat
    end repeat
    return ""
end tell
APPLESCRIPT
        )
    fi
    [[ -z "$target" ]] && return 0
    local orig
    orig=$(printf '%s' "$SNAPSHOT" | awk -F'\t' -v id="$target" '$1 == id { print $2; exit }')
    [[ -z "$orig" ]] && orig="${GHOSTTY_NOTIFY_APP_NAME:-Claude Code}"
    printf '\033]2;%s\033\\' "$orig" > "$TTY_PATH" 2>/dev/null
}
trap 'restore_marker_title; rmdir "$LOCK_DIR" 2>/dev/null' EXIT

# ── Find the tab whose title is now our marker ──────────────────────────────
# Pass marker via env; AppleScript reads it via `system attribute` which IS
# inherited when osascript itself runs under the env.
query_marker_tab() {
    MARKER="$MARKER" osascript <<'APPLESCRIPT' 2>/dev/null
set targetMarker to (system attribute "MARKER")
tell application "Ghostty"
    repeat with w in every window
        repeat with t in every tab of w
            try
                if (name of t as text) is targetMarker then
                    return id of t
                end if
            end try
        end repeat
    end repeat
    return ""
end tell
APPLESCRIPT
}

# ── Marker round-trip ───────────────────────────────────────────────────────
# One pass is the default and all Claude needs: its tab title is static, so
# the marker survives the 0.15 s Ghostty takes to expose it. Each requested
# retry re-snapshots first — the title to restore may have changed meanwhile
# — then writes the marker again. The title is put back after every pass so
# no attempt leaves the marker on screen.
for delay in "" "${RETRY_DELAYS[@]}"; do
    if [[ -n "$delay" ]]; then
        sleep "$delay"
        snapshot_titles || break
    fi
    printf '\033]2;%s\033\\' "$MARKER" > "$TTY_PATH" 2>/dev/null
    MARKER_WRITTEN=1
    # Small delay so Ghostty processes the escape and updates AppleScript state
    sleep 0.15
    TAB_ID=$(query_marker_tab)
    restore_marker_title
    MARKER_WRITTEN=0
    [[ -n "$TAB_ID" ]] && break
done

if [[ -z "$TAB_ID" ]]; then
    hook_current_round || exit 0
    ATTEMPTS=$((ATTEMPTS + 1))
    printf '%s\n' "$ATTEMPTS" > "$ATTEMPTS_FILE" 2>/dev/null
    if (( ATTEMPTS >= 3 )); then
        write_binding ""
        rm -f "$ATTEMPTS_FILE"
    fi
    exit 0
fi
rm -f "$ATTEMPTS_FILE"

write_binding "$TAB_ID"

exit 0
