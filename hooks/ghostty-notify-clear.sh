#!/bin/bash
# Clear (dismiss) a session's on-screen notification.
#
# Two modes:
#   ghostty-notify-clear.sh <session_id>            clear immediately
#   ghostty-notify-clear.sh --watch <session_id>    poll until the user
#                                                   focuses the session's
#                                                   Ghostty tab, then clear
#
# "Clear" means: remove the delivered notification from the screen and
# Notification Center by group ID (alerter --remove / terminal-notifier
# -remove), and kill the blocking alerter process recorded by
# ghostty-notify.sh. A killed alerter produces no action output, which the
# notify hook's dispatch whitelist already treats as "do nothing" — so
# clearing can never fire a phantom tab-jump.
#
# Watch mode is spawned by ghostty-notify.sh right after a notification
# fires. Once you're looking at the session, the alert has done its job:
#   - Cheap frontmost gate first: lsappinfo needs no TCC permission and no
#     scripting; the Ghostty AppleScript query only runs while Ghostty is
#     actually frontmost.
#   - Exact-tab mode when the session's tab_id is known: clears the moment
#     that tab is the selected tab of the frontmost window — including the
#     "already staring at it" case, where the alert is pure noise.
#   - App-level fallback when tab_id is unknown (tmux, unscriptable
#     Ghostty): clears when Ghostty BECOMES frontmost. Rising edge only —
#     if Ghostty was already frontmost when the alert fired, the user may
#     be in a different tab and hasn't seen it yet, so wait for them to
#     leave and come back.
#   - Exits on its own when the alerter concludes (click / timeout), when
#     a newer watcher for the same session takes over, or at
#     NOTIFY_TIMEOUT plus a grace period.
#
# Immediate mode is called (backgrounded) by ghostty-round-reset.sh on
# UserPromptSubmit: a new prompt in the session proves the user is back at
# this tab, so any still-visible notification for it is stale.

MODE="clear"
if [[ "${1:-}" == "--watch" ]]; then
    MODE="watch"
    shift
fi

SESSION_ID="${1:-}"
[[ -z "$SESSION_ID" ]] && exit 0
# Same shape constraint as ghostty-tab-focus.sh: the id becomes part of
# filesystem paths, so anything outside Claude Code's UUID alphabet is out.
[[ "$SESSION_ID" =~ ^[a-fA-F0-9-]+$ ]] || exit 0

SAVE_DIR="${GHOSTTY_NOTIFY_SESSION_DIR:-$HOME/.claude/notifications/ghostty-sessions}"
SAVE_FILE="$SAVE_DIR/${SESSION_ID}.json"
ALERTER_PID_FILE="$SAVE_DIR/${SESSION_ID}.alerter-pid"
WATCH_PID_FILE="$SAVE_DIR/${SESSION_ID}.watch-pid"
AS_SENTINEL="$SAVE_DIR/applescript-unavailable"
# Must stay in sync with GROUP_ID in ghostty-notify.sh.
GROUP_ID="${GHOSTTY_NOTIFY_GROUP_PREFIX:-ghostty-notify}-${SESSION_ID}"

NOTIFY_TIMEOUT="${GHOSTTY_NOTIFY_TIMEOUT:-1200}"
[[ "$NOTIFY_TIMEOUT" =~ ^[0-9]+$ ]] || NOTIFY_TIMEOUT=1200
POLL="${GHOSTTY_NOTIFY_FOCUS_POLL:-1}"
[[ "$POLL" =~ ^[0-9]+([.][0-9]+)?$ ]] || POLL=1
# Zero is syntactically valid but turns the loop into a CPU-pegging spin
# (`sleep 0` returns immediately), so it fails closed to the default like
# every other numeric knob in this project.
[[ "$POLL" =~ ^0+([.]0+)?$ ]] && POLL=1

# Set by ghostty-notify.sh only when the alerter backend actually fired, so
# the watcher knows a pidfile is coming and must not "clear" a notification
# that has not been delivered yet (the alerter runs in a backgrounded
# subshell; under scheduling delay the first poll can beat it).
EXPECT_ALERTER=0
[[ "${GHOSTTY_NOTIFY_EXPECT_ALERTER:-0}" == "1" ]] && EXPECT_ALERTER=1

# Immediate mode only: an epoch stamped by the caller. A notification whose
# alerter registered AFTER that instant belongs to a newer round and must
# survive (see ghostty-round-reset.sh).
CLEAR_BEFORE="${GHOSTTY_NOTIFY_CLEAR_BEFORE:-}"
[[ "$CLEAR_BEFORE" =~ ^[0-9]+$ ]] || CLEAR_BEFORE=""

# Same discovery as ghostty-notify.sh: hooks may run with a trimmed PATH.
find_alerter() {
    command -v alerter 2>/dev/null && return 0
    local p
    for p in /opt/homebrew/bin/alerter /usr/local/bin/alerter "$HOME/.local/bin/alerter"; do
        [[ -x "$p" ]] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}
ALERTER="${GHOSTTY_NOTIFY_ALERTER:-$(find_alerter || true)}"

# Only ever kill a process whose command line still carries THIS session's
# marks — every pattern must appear. A stale pidfile plus PID reuse would
# otherwise take down another session's alerter (any alerter matches
# "alerter") or watcher. The alerter's argv holds `--group <GROUP_ID>` and
# the watcher's holds `--watch <SESSION_ID>`, so both are identifiable.
kill_if_matches() {
    local pid="$1"; shift
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    local cmd
    cmd=$(ps -o command= -p "$pid" 2>/dev/null)
    [[ -n "$cmd" ]] || return 0
    local pat
    for pat in "$@"; do
        case "$cmd" in
            *"$pat"*) ;;
            *) return 0 ;;
        esac
    done
    kill "$pid" 2>/dev/null
    return 0
}

remove_delivered() {
    # Take the notification off the screen / out of Notification Center by
    # group ID. Which binary posted it depends on the backend that fired,
    # and removal only reaches notifications posted under the same sender
    # bundle — so try both; removing an absent group is a silent no-op.
    # Dialect probe mirrors ghostty-notify.sh: alerter 26.2+ (Swift) takes
    # GNU-style --flags, everything earlier is single-dash.
    # </dev/null on every alerter call: with a non-terminal stdin it reads a
    # message from there first, --help included, and blocks until EOF.
    if [[ -n "$ALERTER" && -x "$ALERTER" ]]; then
        if "$ALERTER" --help </dev/null 2>&1 | grep -q -- '--remove'; then
            "$ALERTER" --remove "$GROUP_ID" </dev/null >/dev/null 2>&1
        else
            "$ALERTER" -remove "$GROUP_ID" </dev/null >/dev/null 2>&1
        fi
    fi
    command -v terminal-notifier >/dev/null 2>&1 \
        && terminal-notifier -remove "$GROUP_ID" >/dev/null 2>&1
    return 0
}

kill_blocking_alerter() {
    local pid
    pid=$(cat "$ALERTER_PID_FILE" 2>/dev/null)
    rm -f "$ALERTER_PID_FILE" 2>/dev/null
    kill_if_matches "$pid" alerter "$GROUP_ID"
}

clear_notification() {
    remove_delivered
    kill_blocking_alerter
}

# ── Immediate mode ─────────────────────────────────────────────────────────
if [[ "$MODE" == "clear" ]]; then
    # Never clear a notification that was delivered after the clear was
    # requested. The caller backgrounds this script, so a fresh alert for
    # the round that just started (e.g. a permission prompt under
    # GHOSTTY_NOTIFY_ON_PROMPT=1) can otherwise be killed before the user
    # ever sees it. No pidfile means no alerter to date — proceed.
    if [[ -n "$CLEAR_BEFORE" && -f "$ALERTER_PID_FILE" ]]; then
        PID_MTIME=$(stat -f %m "$ALERTER_PID_FILE" 2>/dev/null || echo 0)
        [[ "$PID_MTIME" =~ ^[0-9]+$ ]] || PID_MTIME=0
        (( PID_MTIME > CLEAR_BEFORE )) && exit 0
    fi
    # Stop the watcher first so it can't race a second clear.
    WATCHER_PID=$(cat "$WATCH_PID_FILE" 2>/dev/null)
    rm -f "$WATCH_PID_FILE" 2>/dev/null
    [[ "$WATCHER_PID" != "$$" ]] \
        && kill_if_matches "$WATCHER_PID" ghostty-notify-clear "$SESSION_ID"
    clear_notification
    exit 0
fi

# ── Watch mode ─────────────────────────────────────────────────────────────
# This loop is now the FALLBACK path. When the resident agent is installed and
# authorized, ghostty-notify.sh routes delivery to it and never spawns this
# watcher — the agent withdraws on a NSWorkspace activation event instead of
# waking once a second, and one process serves every session. This stays for
# machines without the agent: no Swift toolchain, permission declined, or the
# user pinning the shell path with GHOSTTY_NOTIFY_AGENT_APP="".
#
# (An earlier step replaced this loop with a per-notification Swift binary. The
# resident agent subsumed it, so that binary is gone rather than left to rot.)

# Singleton per session: a newer notification round's watcher supersedes a
# live one (the new alert replaced the old on screen — same group ID).
#
# Claim the slot BEFORE killing the predecessor, and never delete the file
# on exit. An exiting watcher that cleaned up after itself had to read the
# file and then remove it non-atomically, and bash runs EXIT traps on
# SIGTERM — so the dying predecessor could delete the successor's freshly
# written PID and leave it running untracked (invisible to both the next
# supersession and the immediate-clear path). A lingering dead PID is
# harmless instead: kill_if_matches ignores it, the next watcher overwrites
# it, and ghostty-tab-save.sh prunes the file with the rest of the
# per-session state.
mkdir -p "$SAVE_DIR" 2>/dev/null
OLD_WATCHER=$(cat "$WATCH_PID_FILE" 2>/dev/null)
printf '%s\n' "$$" > "$WATCH_PID_FILE" 2>/dev/null
[[ "$OLD_WATCHER" != "$$" ]] \
    && kill_if_matches "$OLD_WATCHER" ghostty-notify-clear "$SESSION_ID"

# Tab to watch for. Empty/missing tab_id (tmux, marker never round-tripped)
# or a standing unscriptable-Ghostty sentinel selects the app-level fallback.
TAB_ID=""
if command -v jq >/dev/null 2>&1; then
    TAB_ID=$(jq -r '.tab_id // empty' "$SAVE_FILE" 2>/dev/null)
fi
[[ -f "$AS_SENTINEL" ]] && TAB_ID=""

# Frontmost check, three-valued: 0 = Ghostty is frontmost, 1 = another app
# definitely is, 2 = could not tell. A transient lsappinfo failure must NOT
# read as "the user left Ghostty" — in fallback mode that would arm the
# rising edge and clear an alert the user never saw.
ghostty_front_state() {
    local asn bundle
    asn=$(lsappinfo front 2>/dev/null) || return 2
    [[ -n "$asn" ]] || return 2
    bundle=$(lsappinfo info -only bundleid "$asn" 2>/dev/null) || return 2
    [[ -n "$bundle" ]] || return 2
    case "$bundle" in
        *com.mitchellh.ghostty*) return 0 ;;
        *) return 1 ;;
    esac
}

session_tab_selected() {
    # Frontmost is re-checked inside Ghostty's own scripting suite (no
    # System Events, no accessibility). TAB_ID travels via env + `system
    # attribute`, never source interpolation — same injection guard as
    # ghostty-tab-focus.sh.
    local got
    got=$(TARGET_TAB_ID="$TAB_ID" osascript <<'APPLESCRIPT' 2>/dev/null
set targetId to (system attribute "TARGET_TAB_ID")
tell application "Ghostty"
    if not frontmost then return "no"
    try
        if (id of selected tab of front window as text) is targetId then return "yes"
    end try
    return "no"
end tell
APPLESCRIPT
)
    [[ "$got" == "yes" ]]
}

NOW=$(date +%s)
DEADLINE=$(( NOW + NOTIFY_TIMEOUT + 30 ))
# How long to wait for the alerter subshell to register its PID before
# clearing anyway. Covers the case where it never can (mktemp failure).
ARM_DEADLINE=$(( NOW + 15 ))
SAW_ALERTER_PID=0
SAW_GHOSTTY_AWAY=0

while (( $(date +%s) < DEADLINE )); do
    # Notification lifecycle: once the blocking alerter has been observed
    # and is gone (clicked / timed out / killed), there is nothing left to
    # clear. ghostty-notify.sh clears any previous round's pidfile before
    # firing, so a PID seen here always belongs to this round. The
    # terminal-notifier backend never writes a pidfile, so its watcher just
    # runs to the deadline — its NC entry has no attached process whose
    # exit we could observe.
    if [[ -f "$ALERTER_PID_FILE" ]]; then
        APID=$(cat "$ALERTER_PID_FILE" 2>/dev/null)
        if [[ "$APID" =~ ^[0-9]+$ ]]; then
            SAW_ALERTER_PID=1
            kill -0 "$APID" 2>/dev/null || exit 0
        fi
    elif (( SAW_ALERTER_PID )); then
        exit 0
    fi

    # Not delivered yet — clearing now would remove nothing and then exit,
    # leaving the alert that lands a moment later unwatched.
    if (( EXPECT_ALERTER )) && (( SAW_ALERTER_PID == 0 )) \
        && (( $(date +%s) < ARM_DEADLINE )); then
        sleep "$POLL"
        continue
    fi

    ghostty_front_state
    case $? in
        0)
            if [[ -n "$TAB_ID" ]]; then
                if session_tab_selected; then
                    clear_notification
                    exit 0
                fi
            elif (( SAW_GHOSTTY_AWAY )); then
                clear_notification
                exit 0
            fi
            ;;
        1) SAW_GHOSTTY_AWAY=1 ;;
        *) ;;   # unknown: leave the rising edge untouched
    esac

    sleep "$POLL"
done
exit 0
