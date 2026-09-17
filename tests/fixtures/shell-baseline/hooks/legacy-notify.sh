#!/bin/bash
# Compatibility notification path for an unavailable or older resident agent.
# Wired to the Stop hook, plus opt-in Notification (permission/idle prompt)
# events. Notification handling is OFF by default — under bypass-permissions
# mode those prompts are rare and the terminal bell covers them — but users
# running the default permission mode can set GHOSTTY_NOTIFY_ON_PROMPT=1 to
# get an immediate Ping alert when Claude blocks on a prompt in a background
# tab (otherwise a stalled task looks exactly like a running one).
#
# Features:
#   - Only notify when the round has been running ≥ MIN_ELAPSED seconds
#   - Click notification → ghostty-tab-focus.sh jumps to the right tab
#   - Focus the session's tab → ghostty-notify-clear.sh auto-dismisses the
#     notification (clear-on-focus watcher, GHOSTTY_NOTIFY_CLEAR_ON_FOCUS)
#   - Subtitle leads with the session title (stdin session_title field, or
#     the transcript's last custom-title / ai-title record) so parallel
#     sessions in the same folder produce distinguishable notifications
#   - System Glass sound for tasks past SOUND_ELAPSED
#   - Simple rate limit to prevent duplicate pings from sub-agents
#
# Backend dependency checks (terminal-notifier / alerter) live inside each
# fire_with_* function; a missing preferred backend degrades to the other
# one VISIBLY instead of silently dropping the notification.

[[ "${TERM_PROGRAM:-}" != "ghostty" ]] && [[ -z "${GHOSTTY_RESOURCES_DIR:-}" ]] && exit 0
command -v jq >/dev/null 2>&1 || { printf '%s\n' 'ghostty-notify: jq is missing.' >&2; exit 0; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=hooks/hook-common.sh
source "$SCRIPT_DIR/hook-common.sh"

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
# The id becomes part of filesystem paths below (start marker, alerter
# pidfile) and is handed to the focus/clear scripts, so hold it to the same
# shape the sibling hooks require before any of that.
[[ "$SESSION_ID" =~ ^[a-fA-F0-9-]+$ ]] || exit 0
hook_current_round || exit 0

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
START="${GHOSTTY_NOTIFY_ROUND_START:-$START}"
[[ "$START" =~ ^[0-9]+$ ]] || START=0
ELAPSED=$(( ${GHOSTTY_NOTIFY_EVENT_AT:-$NOW} - START ))

# On Stop, always clear the start marker so the next round re-arms.
clear_start_on_stop() {
    case "$HOOK_EVENT" in
        Stop|stop) hook_finish_round ;;
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
# Match Swift per Unicode scalar, independent of the caller's locale. BSD tr
# counts characters in UTF-8 locales but bytes in C, splitting the rate bucket.
RATE_KEY=$(jq -nr --arg key "$HOOK_EVENT-$SESSION_ID-$PROJECT_NAME" '$key | gsub("[^A-Za-z0-9._-]"; "_")')
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

take_rate_slot_unlocked() {
    # O_EXCL create (noclobber) is the atomic test-and-set: of N concurrent
    # invocations for the same event, exactly one wins. The old
    # read-check-then-truncate pattern let a concurrent reader observe an
    # empty file, treat it as 0, and fire a duplicate notification.
    ( set -C; printf '%s\n' "$NOW" > "$RATE_FILE" ) 2>/dev/null && return 0
    rate_stamp_fresh && return 1
    rm -f "$RATE_FILE" 2>/dev/null
    ( set -C; printf '%s\n' "$NOW" > "$RATE_FILE" ) 2>/dev/null
}

take_rate_slot() {
    local result
    hook_lock "$RATE_FILE.lock" || return 1
    take_rate_slot_unlocked
    result=$?
    hook_unlock "$RATE_FILE.lock"
    return "$result"
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
# single-dash alerter and terminal-notifier both parse NSUserDefaults-style,
# where "-wip auth fix" in value position is read as the next FLAG: the tool
# prints usage and exits without displaying anything. SUBTITLE now leads
# with the user-controlled session title (/rename or ai-title) and MESSAGE
# carries hook-supplied text, so strip leading dashes rather than silently
# lose the notification.
while [[ "$SUBTITLE" == -* ]]; do SUBTITLE="${SUBTITLE#-}"; done
while [[ "$MESSAGE" == -* ]]; do MESSAGE="${MESSAGE#-}"; done

# ── Fire notification with click-to-focus ──────────────────────────────────
# Prefer `alerter` over terminal-notifier. `alerter` is always alert-style,
# so clicks reliably trigger the focus action on modern macOS (Banner-style
# terminal-notifier notifications silently drop -execute clicks).
#
# alerter blocks until the user clicks or timeout — we fire-and-forget via
# backgrounded subshell + disown so the hook returns immediately.

# The focus script is our sibling: under a plugin install the hooks run from
# the plugin directory and nothing is ever copied to ~/.claude/hooks; under a
# manual install.sh install every script sits side by side there. The legacy
# absolute path is kept only as a last-resort fallback.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
FOCUS_SCRIPT="${GHOSTTY_NOTIFY_FOCUS_SCRIPT:-$SCRIPT_DIR/ghostty-tab-focus.sh}"
[[ -x "$FOCUS_SCRIPT" ]] || FOCUS_SCRIPT="$HOME/.claude/hooks/ghostty-tab-focus.sh"

# alerter lives wherever the user's package manager put it (brew installs to
# /opt/homebrew/bin on Apple silicon, /usr/local/bin on Intel); hooks may run
# with a trimmed PATH, so probe common locations after `command -v`.
find_alerter() {
    command -v alerter 2>/dev/null && return 0
    local p
    for p in /opt/homebrew/bin/alerter /usr/local/bin/alerter "$HOME/.local/bin/alerter"; do
        [[ -x "$p" ]] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}
ALERTER="${GHOSTTY_NOTIFY_ALERTER:-$(find_alerter || true)}"
GROUP_ID="${GHOSTTY_NOTIFY_GROUP_PREFIX:-ghostty-notify}-${SESSION_ID}"

fire_with_alerter() {
    [[ -n "$ALERTER" && -x "$ALERTER" ]] || return 1
    local ACTION_LABEL="Go to tab"
    # alerter 26.2+ (the 2025 Swift rewrite) takes GNU-style --flags; every
    # earlier release (ObjC, single-dash NSUserDefaults parsing: -title,
    # -closeLabel) rejects them and prints usage instead of showing anything.
    # Probe --help to pick the dialect — the legacy help text has no
    # "--close-label" token.
    local args=()
    # </dev/null everywhere alerter runs: it reads a message from stdin when
    # that is not a terminal, and --help is no exception — probed from a
    # pipeline or a caller that never closes stdin, it would block forever.
    if "$ALERTER" --help </dev/null 2>&1 | grep -q -- '--close-label'; then
        args=(
            --title "$TITLE"
            --subtitle "$SUBTITLE"
            --message "$MESSAGE"
            --group "$GROUP_ID"
            --actions "$ACTION_LABEL"
            --timeout "$NOTIFY_TIMEOUT"
            --close-label "Dismiss"
        )
        [[ "$SILENT" != "true" ]] && args+=(--sound "$SOUND")
    else
        args=(
            -title "$TITLE"
            -subtitle "$SUBTITLE"
            -message "$MESSAGE"
            -group "$GROUP_ID"
            -actions "$ACTION_LABEL"
            -timeout "$NOTIFY_TIMEOUT"
            -closeLabel "Dismiss"
        )
        [[ "$SILENT" != "true" ]] && args+=(-sound "$SOUND")
    fi
    # Whitelist jump triggers. alerter 26.5+ returns the close-label text
    # ("Dismiss") instead of @CLOSED when the close button is used, so
    # blacklisting sentinels isn't safe. Fire focus ONLY when the user
    # either clicked the "Go to tab" action button, or clicked the
    # notification body itself (alerter reports @CONTENTCLICKED).
    # Keep ACTION_LABEL and the actions flag in sync.
    #
    # The blocking alerter's PID is exported to a per-session file so
    # ghostty-notify-clear.sh can kill it on clear-on-focus or on the next
    # prompt. Its output has to route through a temp file for that: a
    # command substitution would not reveal the PID until alerter already
    # exited. A killed alerter yields an empty action → whitelist ignores.
    #
    # The stale pidfile is dropped HERE, synchronously, before either
    # background job starts — that is what lets the watcher spawned below
    # treat any PID it later reads as belonging to this round. The subshell
    # deliberately does NOT delete the pidfile when its alerter concludes:
    # a newer round may already have claimed the name, and deleting it
    # would strand that round's alert with no watcher and no way to kill
    # the blocking process.
    local PID_FILE="$SAVE_DIR/${SESSION_ID}.alerter-pid"
    mkdir -p "$SAVE_DIR" 2>/dev/null
    rm -f "$PID_FILE" 2>/dev/null
    (
        out=$(mktemp "${TMPDIR:-/tmp}/ghostty-notify-action.XXXXXX" 2>/dev/null) || out=""
        if [[ -n "$out" ]]; then
            "$ALERTER" "${args[@]}" </dev/null > "$out" 2>/dev/null &
            apid=$!
            printf '%s\n' "$apid" > "$PID_FILE" 2>/dev/null
            wait "$apid"
            action=$(cat "$out" 2>/dev/null)
            rm -f "$out" 2>/dev/null
        else
            action=$("$ALERTER" "${args[@]}" </dev/null 2>/dev/null)
        fi
        case "$action" in
            "$ACTION_LABEL"|@CONTENTCLICKED)
                [[ -x "$FOCUS_SCRIPT" ]] && "$FOCUS_SCRIPT" "$SESSION_ID"
                ;;
        esac
    ) </dev/null >/dev/null 2>&1 &
    disown
    # Tell the watcher a pidfile is coming, so it won't "clear" before the
    # notification has actually been delivered.
    EXPECT_ALERTER=1
    return 0
}

fire_with_terminal_notifier() {
    command -v terminal-notifier >/dev/null 2>&1 || return 1
    # No click-to-focus on this path — terminal-notifier fires -execute on
    # ANY click including dismiss, with no way to tell them apart, which
    # reintroduces the dismiss-steals-focus bug (#1) the alerter whitelist
    # exists to prevent (regression guard: tests/test-fallback-no-focus.sh).
    # Intentional degradation: notification shows, user navigates manually.
    local args=(
        -title "$TITLE"
        -subtitle "$SUBTITLE"
        -message "$MESSAGE"
        -group "$GROUP_ID"
    )
    [[ "$SILENT" != "true" ]] && args+=(-sound "$SOUND")
    # Propagate the real exit status: a terminal-notifier that fails (e.g.
    # its bundle isn't authorized for notifications) must not be reported
    # as "fired", or the caller spawns a clear-on-focus watcher to poll for
    # ~20 minutes after a notification that was never displayed.
    terminal-notifier "${args[@]}" >/dev/null 2>&1
}

# Backend selection. Default: prefer alerter (supports click-to-jump), fall
# back to terminal-notifier. Override with GHOSTTY_NOTIFY_BACKEND:
#   - "terminal-notifier" : force terminal-notifier (use this when the
#                           notification-owning bundle isn't authorized for
#                           notifications in System Settings, since alerter
#                           borrows that bundle and silently fails to display)
#   - "alerter"           : prefer alerter; if its binary is missing or
#                           unusable, degrade to terminal-notifier VISIBLY
#                           rather than dropping the notification silently
#   - unset / "auto"      : prefer alerter, fall back to terminal-notifier
#   - "agent"             : require the resident agent; do not fall back
BACKEND="${GHOSTTY_NOTIFY_BACKEND:-auto}"
hook_current_round || exit 0
FIRED=0
EXPECT_ALERTER=0
USED_AGENT=0

# ── Resident agent (preferred delivery) ────────────────────────────────────
# When the agent app is installed it owns delivery end to end: it posts through
# UNUserNotificationCenter, withdraws the notification the moment this session's
# Ghostty surface comes forward — a NSWorkspace activation subscription, not a
# poll — and answers a click by focusing that surface over an Apple Event.
#
# That subsumes both the alerter click-handler subshell and the per-notification
# clear-on-focus watcher, so neither runs on this path: no second process
# outlives the hook, and nothing wakes up once a second.
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
    # it permission to display anything. Falling through to the shell backends
    # then is the whole point: a spooled request is not a delivered
    # notification, and the invariant at the top of this file is that a missing
    # preferred backend degrades VISIBLY.
    if agent_deliver "$(jq -nc \
        --arg s "$SESSION_ID" --arg t "$TITLE" --arg sub "$SUBTITLE" \
        --arg b "$MESSAGE" --arg snd "$AGENT_SOUND" --arg tab "$AGENT_TAB_ID" \
        --arg to "$NOTIFY_TIMEOUT" --arg clear "$AGENT_CLEAR" \
        --arg source "${GHOSTTY_NOTIFY_PROCESS_NAME:-claude}" \
        '{type:"notify",session_id:$s,title:$t,subtitle:$sub,body:$b,sound:$snd,
          tab_id:$tab,timeout:$to,clear_on_focus:$clear} +
         (if $source == "codex" then {source:$source} else {} end)')" \
        "$AGENT_APP"; then
        FIRED=1
        USED_AGENT=1
    fi
fi

if [[ "$USED_AGENT" -eq 0 ]]; then
    case "$BACKEND" in
        agent)
            # Explicitly requested the agent and it is unavailable. Degrade
            # visibly rather than silently swallowing the notification.
            fire_with_terminal_notifier && FIRED=1
            ;;
        terminal-notifier)
            fire_with_terminal_notifier && FIRED=1
            ;;
        *)
            { fire_with_alerter || fire_with_terminal_notifier; } && FIRED=1
            ;;
    esac
fi

# ── Clear-on-focus watcher ─────────────────────────────────────────────────
# Focusing the session's tab (or Ghostty itself when the tab is unknown)
# dismisses the notification: once you're looking at the session, the alert
# has done its job and would otherwise sit in the corner until clicked or
# timed out. Opt out with GHOSTTY_NOTIFY_CLEAR_ON_FOCUS=0. Sibling
# resolution mirrors FOCUS_SCRIPT above.
#
# Only an explicit off value disables it: an unrecognized setting falls
# back to the documented default (on), matching how the numeric knobs above
# fail back to theirs instead of silently changing behavior. Keep this list
# in sync with ghostty-round-reset.sh, which gates the same feature.
case "${GHOSTTY_NOTIFY_CLEAR_ON_FOCUS:-1}" in
    0|false|no|off|FALSE|NO|OFF) CLEAR_ON_FOCUS=0 ;;
    *) CLEAR_ON_FOCUS=1 ;;
esac
# The agent already withdraws on focus from inside a resident process, so the
# watcher would be a second, worse implementation of the same feature.
if [[ "$FIRED" -eq 1 && "$CLEAR_ON_FOCUS" -eq 1 && "$USED_AGENT" -eq 0 ]]; then
    CLEAR_SCRIPT="${GHOSTTY_NOTIFY_CLEAR_SCRIPT:-$SCRIPT_DIR/ghostty-notify-clear.sh}"
    [[ -x "$CLEAR_SCRIPT" ]] || CLEAR_SCRIPT="$HOME/.claude/hooks/ghostty-notify-clear.sh"
    if [[ -x "$CLEAR_SCRIPT" ]]; then
        GHOSTTY_NOTIFY_EXPECT_ALERTER="$EXPECT_ALERTER" \
            "$CLEAR_SCRIPT" --watch "$SESSION_ID" </dev/null >/dev/null 2>&1 &
        disown
    fi
fi

clear_start_on_stop
exit 0
