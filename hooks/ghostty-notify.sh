#!/bin/bash
# Ghostty-native notification for Claude Code.
# Wired to the Stop hook, plus opt-in Notification (permission/idle prompt)
# events. Notification handling is OFF by default — under bypass-permissions
# mode those prompts are rare and the terminal bell covers them — but users
# running the default permission mode can set GHOSTTY_NOTIFY_ON_PROMPT=1 to
# get an immediate Ping alert when Claude blocks on a prompt in a background
# tab (otherwise a stalled task looks exactly like a running one).
#
# Features:
#   - Only notify when the round has been running ≥ MIN_ELAPSED seconds
#   - Delivery goes to the resident agent, which owns the notification: it
#     answers a click by jumping to the session's tab and withdraws the
#     alert when you arrive (GHOSTTY_NOTIFY_CLEAR_ON_FOCUS)
#   - Without the agent, terminal-notifier shows the alert and nothing else;
#     a new prompt in the session clears it (ghostty-notify-clear.sh)
#   - Subtitle leads with the session title (stdin session_title field, or
#     the transcript's last custom-title / ai-title record) so parallel
#     sessions in the same folder produce distinguishable notifications
#   - System Glass sound for tasks past SOUND_ELAPSED
#   - Simple rate limit to prevent duplicate pings from sub-agents
#
# The fallback's dependency check lives inside fire_with_terminal_notifier;
# an agent that cannot display degrades to it VISIBLY instead of silently
# dropping the notification.

[[ "${TERM_PROGRAM:-}" != "ghostty" ]] && [[ -z "${GHOSTTY_RESOURCES_DIR:-}" ]] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

HOOK_DATA=""
if [[ ! -t 0 ]]; then
    HOOK_DATA=$(cat 2>/dev/null || true)
fi
[[ -z "$HOOK_DATA" ]] && exit 0

SESSION_ID=$(printf '%s' "$HOOK_DATA" | jq -r '.session_id // empty' 2>/dev/null)
CWD=$(printf '%s' "$HOOK_DATA" | jq -r '.cwd // empty' 2>/dev/null)
HOOK_EVENT=$(printf '%s' "$HOOK_DATA" | jq -r '.hook_event_name // empty' 2>/dev/null)
TRANSCRIPT_PATH=$(printf '%s' "$HOOK_DATA" | jq -r '.transcript_path // empty' 2>/dev/null)
[[ -z "$SESSION_ID" ]] && exit 0
# The id becomes part of filesystem paths below and of the notification
# group handed to the clear script, so hold it to the same shape the sibling
# hooks require before any of that.
[[ "$SESSION_ID" =~ ^[a-fA-F0-9-]+$ ]] || exit 0

SAVE_DIR="${GHOSTTY_NOTIFY_SESSION_DIR:-$HOME/.claude/notifications/ghostty-sessions}"
START_FILE="$SAVE_DIR/${SESSION_ID}.start"

# ── Elapsed-time gates ────────────────────────────────────────────────────
# Two tiers:
#   MIN_ELAPSED   — below this: completely silent (no notification)
#   SOUND_ELAPSED — below this but above MIN: notification WITHOUT sound
#                   at/above: notification WITH sound
MIN_ELAPSED="${GHOSTTY_NOTIFY_MIN_ELAPSED:-180}"
SOUND_ELAPSED="${GHOSTTY_NOTIFY_SOUND_ELAPSED:-600}"
NOTIFY_TIMEOUT="${GHOSTTY_NOTIFY_TIMEOUT:-1200}"

# Non-integer values (e.g. "3m") must fail CLOSED, back to the default: an
# arithmetic error inside (( ... )) evaluates as false, which would disable
# the below-threshold gate entirely and notify on every round.
[[ "$MIN_ELAPSED" =~ ^[0-9]+$ ]] || MIN_ELAPSED=180
[[ "$SOUND_ELAPSED" =~ ^[0-9]+$ ]] || SOUND_ELAPSED=600
[[ "$NOTIFY_TIMEOUT" =~ ^[0-9]+$ ]] || NOTIFY_TIMEOUT=1200

NOW=$(date +%s)
START=0
[[ -f "$START_FILE" ]] && START=$(cat "$START_FILE" 2>/dev/null || echo 0)
[[ "$START" =~ ^[0-9]+$ ]] || START=0
ELAPSED=$((NOW - START))

# On Stop, always clear the start marker so the next round re-arms.
clear_start_on_stop() {
    case "$HOOK_EVENT" in
        Stop|stop) rm -f "$START_FILE" ;;
    esac
}

# Event dispatch. Stop applies the elapsed gates; Notification (opt-in via
# GHOSTTY_NOTIFY_ON_PROMPT=1) fires immediately — a blocking permission or
# idle prompt is urgent no matter how little time has elapsed, and no Stop
# will fire while Claude is blocked on it.
case "$HOOK_EVENT" in
    Stop|stop)
        if [[ "$START" -le 0 ]] || (( ELAPSED < MIN_ELAPSED )); then
            clear_start_on_stop
            exit 0
        fi
        SILENT=false
        (( ELAPSED < SOUND_ELAPSED )) && SILENT=true
        ;;
    Notification|notification)
        [[ "${GHOSTTY_NOTIFY_ON_PROMPT:-0}" = "1" ]] || exit 0
        SILENT=false
        ;;
    *)
        clear_start_on_stop
        exit 0
        ;;
esac

# ── Rate limit (avoid spam from parallel sub-agents) ──────────────────────
RATE_DIR="${GHOSTTY_NOTIFY_RATE_DIR:-$HOME/.claude/notifications/state}"
mkdir -p "$RATE_DIR"
PROJECT_NAME=$(basename "${CWD:-$PWD}")
RATE_KEY=$(printf '%s-%s-%s' "$HOOK_EVENT" "$SESSION_ID" "$PROJECT_NAME" | tr -c 'A-Za-z0-9._-' '_')
RATE_FILE="$RATE_DIR/ghostty-notify-$RATE_KEY"
RATE_WINDOW=10  # seconds

rate_stamp_fresh() {
    local last
    last=$(cat "$RATE_FILE" 2>/dev/null)
    if ! [[ "$last" =~ ^[0-9]+$ ]]; then
        # Unreadable/corrupt stamp: dedupe this event but drop the file so
        # the next one isn't blocked forever.
        rm -f "$RATE_FILE" 2>/dev/null
        return 0
    fi
    (( NOW - last < RATE_WINDOW ))
}

take_rate_slot() {
    # O_EXCL create (noclobber) is the atomic test-and-set: of N concurrent
    # invocations for the same event, exactly one wins. The old
    # read-check-then-truncate pattern let a concurrent reader observe an
    # empty file, treat it as 0, and fire a duplicate notification.
    ( set -C; printf '%s\n' "$NOW" > "$RATE_FILE" ) 2>/dev/null && return 0
    rate_stamp_fresh && return 1
    rm -f "$RATE_FILE" 2>/dev/null
    ( set -C; printf '%s\n' "$NOW" > "$RATE_FILE" ) 2>/dev/null
}

take_rate_slot || { clear_start_on_stop; exit 0; }

# Stamps are one file per event×session×project and nothing else deletes
# them — prune old ones so the state dir doesn't grow forever.
find "$RATE_DIR" -type f -name 'ghostty-notify-*' -mtime +7 -delete 2>/dev/null

# ── Session title (tells apart sessions in the same folder) ────────────────
# Preferred source: the session_title stdin field (still being trialed
# upstream — absent from current public builds, so this is future-proofing).
# Fallback: title records in the transcript, in the same precedence Claude
# Code's own resume picker uses — the last custom-title (appended on every
# /rename, by hand or via a rename plugin) outranks the last ai-title (the
# auto-generated title Claude Code keeps refreshing for every session). A
# brand-new session may briefly have neither; the subtitle then keeps its
# generic event wording. Runs after the rate-limit gate so suppressed
# events never pay the transcript scan.
last_title_record() {
    # $1: record type, $2: field holding the title. grep narrows the file to
    # candidate lines cheaply; jq then keeps only real records of that type
    # (fromjson? drops unparseable lines, select() drops look-alike text
    # embedded in message content) and the newest one wins.
    #
    # gsub runs inside jq, before `tail -n 1`: a title holding an escaped
    # newline decodes to several output lines, and tail would keep only the
    # last fragment (a trailing newline would yield nothing at all).
    grep -E '"type"[[:space:]]*:[[:space:]]*"'"$1"'"' "$TRANSCRIPT_PATH" 2>/dev/null \
        | jq -Rr --arg t "$1" --arg f "$2" \
            'fromjson? | select(.type == $t) | (.[$f] // empty) | gsub("[\\n\\r]"; " ")' 2>/dev/null \
        | tail -n 1
}
SESSION_TITLE=$(printf '%s' "$HOOK_DATA" | jq -r '.session_title // empty' 2>/dev/null)
if [[ -z "$SESSION_TITLE" && -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]]; then
    SESSION_TITLE=$(last_title_record "custom-title" "customTitle")
    [[ -z "$SESSION_TITLE" ]] && SESSION_TITLE=$(last_title_record "ai-title" "aiTitle")
fi
# The title lands in notification argv: force it one-line and control-free.
SESSION_TITLE=$(printf '%s' "$SESSION_TITLE" | tr -d '\000-\037\177')

# ── Build title/subtitle/sound per event ───────────────────────────────────
# The session title leads the subtitle (macOS ellipsizes the tail, and the
# title is the part that varies between sessions); the event wording it
# displaces is already carried by the ✅/🔔 in TITLE.
case "$HOOK_EVENT" in
    Stop|stop)
        TITLE="${GHOSTTY_NOTIFY_APP_NAME:-Claude} ✅"
        SUBTITLE="${SESSION_TITLE:-Task Complete} — $PROJECT_NAME"
        MESSAGE=$(printf 'Finished after %dm %ds' $((ELAPSED / 60)) $((ELAPSED % 60)))
        SOUND="Glass"
        ;;
    Notification|notification)
        TITLE="Claude 🔔"
        SUBTITLE="${SESSION_TITLE:-Input Required} — $PROJECT_NAME"
        MESSAGE=$(printf '%s' "$HOOK_DATA" | jq -r '.message // "Claude is waiting for you"' 2>/dev/null)
        SOUND="Ping"
        ;;
esac

# A value leading an argv slot must not start with '-'. The legacy
# terminal-notifier parses argv NSUserDefaults-style, where "-wip auth fix"
# in value position is read as the next FLAG: it prints usage and exits
# without displaying anything. SUBTITLE now leads
# with the user-controlled session title (/rename or ai-title) and MESSAGE
# carries hook-supplied text, so strip leading dashes rather than silently
# lose the notification.
while [[ "$SUBTITLE" == -* ]]; do SUBTITLE="${SUBTITLE#-}"; done
while [[ "$MESSAGE" == -* ]]; do MESSAGE="${MESSAGE#-}"; done

# ── Fire notification ──────────────────────────────────────────────────────
# The resident agent is the delivery path: it posts through
# UNUserNotificationCenter under its own bundle identity, so a click reaches
# the process that knows which tab this session lives in. terminal-notifier
# remains only so a machine without the agent still SEES that the round
# finished.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
GROUP_ID="${GHOSTTY_NOTIFY_GROUP_PREFIX:-ghostty-notify}-${SESSION_ID}"
# Stamped whenever the fallback delivers, so a clear requested before that
# instant cannot take down a notification the user has not seen yet.
NOTIFIED_FILE="$SAVE_DIR/${SESSION_ID}.notified"

fire_with_terminal_notifier() {
    command -v terminal-notifier >/dev/null 2>&1 || return 1
    # No click-to-focus on this path — terminal-notifier fires -execute on
    # ANY click including dismiss, with no way to tell them apart, so wiring
    # it would make dismissing an alert steal focus (bug #1; regression
    # guard: tests/test-fallback-no-focus.sh). Intentional degradation: the
    # notification shows, the user navigates manually.
    local args=(
        -title "$TITLE"
        -subtitle "$SUBTITLE"
        -message "$MESSAGE"
        -group "$GROUP_ID"
    )
    [[ "$SILENT" != "true" ]] && args+=(-sound "$SOUND")
    # Propagate the real exit status: a terminal-notifier that fails (e.g.
    # its bundle isn't authorized for notifications) must not be reported as
    # "fired", or the next prompt would try to clear an alert that was never
    # displayed.
    terminal-notifier "${args[@]}" >/dev/null 2>&1 || return 1
    mkdir -p "$SAVE_DIR" 2>/dev/null
    date +%s > "$NOTIFIED_FILE" 2>/dev/null
    return 0
}

# Backend selection. Default: the resident agent, falling back to
# terminal-notifier when it cannot display. Override with
# GHOSTTY_NOTIFY_BACKEND:
#   - unset / "auto" / "agent" : the agent, else terminal-notifier
#   - "terminal-notifier"      : skip the agent entirely
BACKEND="${GHOSTTY_NOTIFY_BACKEND:-auto}"
USED_AGENT=0

# ── Resident agent (preferred delivery) ────────────────────────────────────
# When the agent app is installed it owns delivery end to end: it posts through
# UNUserNotificationCenter, withdraws the notification the moment this session's
# Ghostty surface comes forward — a NSWorkspace activation subscription, not a
# poll — and answers a click by focusing that surface over an Apple Event.
#
# Nothing this hook starts outlives it on that path, and nothing polls.
AGENT_APP=""
if [[ "$BACKEND" == "auto" || "$BACKEND" == "agent" ]]; then
    # shellcheck source=hooks/agent-common.sh
    if source "$SCRIPT_DIR/agent-common.sh" 2>/dev/null; then
        AGENT_APP=$(agent_app "$SCRIPT_DIR" 2>/dev/null || true)
    fi
fi
if [[ -n "$AGENT_APP" ]]; then
    AGENT_SOUND=""
    [[ "$SILENT" != "true" ]] && AGENT_SOUND="$SOUND"
    # Hand over the tab id the marker round-trip already resolved, so the very
    # first notification of a session is localizable without waiting for an
    # anchor — and so the agent never has to guess by sampling what is focused.
    AGENT_TAB_ID=""
    [[ -f "$SAVE_DIR/${SESSION_ID}.json" ]] &&
        AGENT_TAB_ID=$(jq -r '.tab_id // empty' "$SAVE_DIR/${SESSION_ID}.json" 2>/dev/null)
    # NOTIFY_TIMEOUT and CLEAR_ON_FOCUS are documented knobs; they have to reach
    # the agent or they silently stop working on the preferred path. Both go over
    # as strings (--arg, not --argjson): the agent parses either form, and a
    # value that passes the shell's ^[0-9]+$ check can still be invalid JSON
    # ("007"), which would make jq fail and hand agent_deliver an empty payload.
    case "${GHOSTTY_NOTIFY_CLEAR_ON_FOCUS:-1}" in
        0|false|no|off|FALSE|NO|OFF) AGENT_CLEAR=false ;;
        *) AGENT_CLEAR=true ;;
    esac
    # agent_deliver fails when the agent is not running or macOS has not granted
    # it permission to display anything. Falling through to terminal-notifier
    # then is the whole point: a spooled request is not a delivered
    # notification, and the invariant at the top of this file is that a missing
    # preferred backend degrades VISIBLY.
    if agent_deliver "$(jq -nc \
        --arg s "$SESSION_ID" --arg t "$TITLE" --arg sub "$SUBTITLE" \
        --arg b "$MESSAGE" --arg snd "$AGENT_SOUND" --arg tab "$AGENT_TAB_ID" \
        --arg to "$NOTIFY_TIMEOUT" --arg clear "$AGENT_CLEAR" \
        '{type:"notify",session_id:$s,title:$t,subtitle:$sub,body:$b,sound:$snd,
          tab_id:$tab,timeout:$to,clear_on_focus:$clear}')" \
        "$AGENT_APP"; then
        USED_AGENT=1
    fi
fi

if [[ "$USED_AGENT" -eq 0 ]]; then
    fire_with_terminal_notifier
fi

# Clearing when you arrive is the agent's job — it subscribes to activation
# events from inside one resident process. The fallback keeps only the
# cheapest half of that feature: ghostty-round-reset.sh clears this
# session's notification when you submit the next prompt, which is proof
# enough that you are back, and costs no polling.

clear_start_on_stop
exit 0
