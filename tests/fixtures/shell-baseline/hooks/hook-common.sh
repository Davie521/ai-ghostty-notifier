#!/bin/bash
# Sourced Bash 3.2 helpers: source context, shared journal and spool transport.

hook_read() {
    HOOK_DATA=""
    [[ -t 0 ]] || HOOK_DATA=$(cat 2>/dev/null)
    [[ "${TERM_PROGRAM:-}" == ghostty || -n "${GHOSTTY_RESOURCES_DIR:-}" ]] || return 1
    if ! command -v jq >/dev/null 2>&1; then
        printf '%s\n' 'ghostty-notify: jq is missing; install it with brew install jq.' >&2
        return 1
    fi
    [[ -n "$HOOK_DATA" ]] || return 1
    # NUL preserves empty fields, backslashes and newlines. Validate everything
    # before emitting; the final marker also detects a failed jq subprocess.
    local end=""
    {
        # shellcheck disable=SC2034
        IFS= read -r -d '' SESSION_ID && IFS= read -r -d '' HOOK_EVENT &&
        IFS= read -r -d '' HOOK_AGENT_ID && IFS= read -r -d '' end
    } < <(printf '%s' "$HOOK_DATA" | jq -je '
        if type != "object" then error("expected an object") else . end
        | [.session_id, (.hook_event_name // ""), (.agent_id // "")]
        | if all(.[]; type == "string" and (contains("\u0000") | not))
          then . + ["OK"] | .[] | . + "\u0000"
          else error("invalid hook fields") end' 2>/dev/null)
    if [[ "$end" != OK ]]; then
        printf '%s\n' 'ghostty-notify: invalid hook JSON; event ignored.' >&2
        return 1
    fi
    [[ "$SESSION_ID" =~ ^[a-fA-F0-9-]+$ && -z "$HOOK_AGENT_ID" ]] || return 1
    # PreToolUse's cached binding path needs no clock or journal transaction.
    if [[ "$HOOK_EVENT" != PreToolUse ]]; then
        HOOK_OCCURRED_AT=$(date +%s)
        export GHOSTTY_NOTIFY_EVENT_AT="$HOOK_OCCURRED_AT"
    fi
}

hook_codex_settings() {
    local name value
    if [[ -f "$SCRIPT_DIR/config.json" ]]; then
        while IFS= read -r -d '' name && IFS= read -r -d '' value; do
            [[ "$name" =~ ^GHOSTTY_NOTIFY_[A-Z0-9_]+$ ]] || continue
            # Set-but-empty is meaningful for AGENT_APP. Preserve it too.
            declare -p "$name" >/dev/null 2>&1 && continue
            export "$name=$value"
        done < <(jq -j 'to_entries[] | select(.key | test("^GHOSTTY_NOTIFY_[A-Z0-9_]+$"))
            | select(.value != null) | .value |= tostring
            | select((.value | contains("\u0000")) | not)
            | .key + "\u0000" + .value + "\u0000"' "$SCRIPT_DIR/config.json" 2>/dev/null)
    fi
    export GHOSTTY_NOTIFY_PROCESS_NAME=codex GHOSTTY_NOTIFY_APP_NAME=Codex
    export GHOSTTY_NOTIFY_SESSION_DIR="${GHOSTTY_NOTIFY_SESSION_DIR:-${CODEX_HOME:-$HOME/.codex}/notifications/ghostty-sessions}"
    export GHOSTTY_NOTIFY_RATE_DIR="${GHOSTTY_NOTIFY_RATE_DIR:-${CODEX_HOME:-$HOME/.codex}/notifications/state}"
    export GHOSTTY_NOTIFY_GROUP_PREFIX="${GHOSTTY_NOTIFY_GROUP_PREFIX:-codex-ghostty-notify}"
}

hook_owner() {
    local pid=$$ parent cmd tty depth=16
    HOOK_OWNER="" HOOK_TTY="${GHOSTTY_NOTIFY_TTY:-}"
    while (( depth-- > 0 )); do
        parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [[ "$parent" =~ ^[0-9]+$ ]] && (( parent > 1 )) || return 1
        cmd=$(ps -o command= -p "$parent" 2>/dev/null)
        case "$cmd" in
            codex|codex\ *|*/codex|*/codex\ *)
                tty=$(ps -o tty= -p "$parent" 2>/dev/null | tr -d ' ')
                [[ "$tty" =~ ^[A-Za-z0-9]+$ ]] && [[ "$tty" != "??" ]] || return 1
                HOOK_OWNER="$parent:$tty:$(ps -o lstart= -p "$parent" 2>/dev/null)"
                [[ -n "$HOOK_TTY" ]] || HOOK_TTY="/dev/$tty"
                return 0 ;;
        esac
        pid="$parent"
    done
    return 1
}

hook_lock() {
    local directory="$1" n=0 owner age
    while ! mkdir "$directory" 2>/dev/null; do
        owner=$(cat "$directory/pid" 2>/dev/null)
        age=$(( $(date +%s) - $(stat -f %m "$directory" 2>/dev/null || date +%s) ))
        if (( age > 30 )) && { [[ ! "$owner" =~ ^[0-9]+$ ]] || ! kill -0 "$owner" 2>/dev/null; }; then
            rm -f "$directory/pid" 2>/dev/null
            rmdir "$directory" 2>/dev/null || true
        fi
        (( n++ < 100 )) || { printf '%s\n' 'ghostty-notify: journal lock timed out.' >&2; return 1; }
        sleep 0.01
    done
    printf '%s\n' "$$" > "$directory/pid"
}

hook_unlock() { rm -f "$1/pid"; rmdir "$1" 2>/dev/null; }

hook_context() {
    local action="$1" directory lock round tmp
    directory="${GHOSTTY_NOTIFY_SESSION_DIR:-$HOME/.claude/notifications/ghostty-sessions}"
    mkdir -p "$directory" || return 1
    lock="$directory/${SESSION_ID}.round-lock"
    hook_lock "$lock" || return 1
    round="$directory/${SESSION_ID}.round"
    HOOK_ROUND_ID=$(cat "$round" 2>/dev/null)
    if [[ "$action" == prompt || ! "$HOOK_ROUND_ID" =~ ^[A-Za-z0-9-]{1,160}$ ]]; then
        HOOK_ROUND_ID="${HOOK_OCCURRED_AT:-$(date +%s)}-$$-$RANDOM"
        tmp="$round.$$"
        printf '%s\n' "$HOOK_ROUND_ID" > "$tmp" && mv -f "$tmp" "$round"
    fi
    case "$action" in
        prompt)
            rm -f "$directory/${SESSION_ID}.start"
            if [[ "${GHOSTTY_NOTIFY_PROCESS_NAME:-claude}" == codex ]]; then
                printf '%s\n' "$HOOK_OCCURRED_AT" > "$directory/${SESSION_ID}.start"
            fi ;;
        tool)
            [[ -f "$directory/${SESSION_ID}.start" ]] || date +%s > "$directory/${SESSION_ID}.start" ;;
    esac
    HOOK_STARTED_AT=$(cat "$directory/${SESSION_ID}.start" 2>/dev/null || true)
    [[ "$HOOK_STARTED_AT" =~ ^[0-9]+$ ]] || HOOK_STARTED_AT=0
    hook_unlock "$lock"
    export GHOSTTY_NOTIFY_ROUND_ID="$HOOK_ROUND_ID" GHOSTTY_NOTIFY_ROUND_START="$HOOK_STARTED_AT"
    export GHOSTTY_NOTIFY_CONTEXT_CAPTURED=1
}

hook_finish_round() {
    local directory="${GHOSTTY_NOTIFY_SESSION_DIR:-$HOME/.claude/notifications/ghostty-sessions}" lock current
    lock="$directory/${SESSION_ID}.round-lock"
    hook_lock "$lock" || return 1
    current=$(cat "$directory/${SESSION_ID}.round" 2>/dev/null)
    if [[ -z "${GHOSTTY_NOTIFY_ROUND_ID:-}" || "$current" == "$GHOSTTY_NOTIFY_ROUND_ID" ]]; then
        rm -f "$directory/${SESSION_ID}.start"
    fi
    hook_unlock "$lock"
}

hook_current_round() {
    [[ -z "${GHOSTTY_NOTIFY_ROUND_ID:-}" ]] ||
        [[ "$(cat "${GHOSTTY_NOTIFY_SESSION_DIR:-$HOME/.claude/notifications/ghostty-sessions}/${SESSION_ID}.round" 2>/dev/null)" == "$GHOSTTY_NOTIFY_ROUND_ID" ]]
}

hook_native_available() {
    case "${GHOSTTY_NOTIFY_BACKEND:-auto}" in auto|agent) ;; *) return 1 ;; esac
    # shellcheck source=hooks/agent-common.sh
    source "$SCRIPT_DIR/agent-common.sh" || return 1
    HOOK_AGENT_APP=$(agent_app "$SCRIPT_DIR") || return 1
    agent_ready || return 1
    # Capabilities belong to the running PID, including after a downgrade.
    [[ "$(cat "$AGENT_ROOT/capabilities" 2>/dev/null)" == "hook-event-v1:$(cat "$AGENT_PID_FILE" 2>/dev/null)" ]]
}

hook_queue_event() {
    local json
    json=$(printf '%s' "$HOOK_DATA" | jq -c \
        --arg source "${GHOSTTY_NOTIFY_PROCESS_NAME:-claude}" \
        --arg round "$HOOK_ROUND_ID" --arg at "$HOOK_OCCURRED_AT" --arg start "$HOOK_STARTED_AT" \
        --arg sessions "${GHOSTTY_NOTIFY_SESSION_DIR:-$HOME/.claude/notifications/ghostty-sessions}" \
        --arg rates "${GHOSTTY_NOTIFY_RATE_DIR:-$HOME/.claude/notifications/state}" \
        --arg hooks "$SCRIPT_DIR" --arg owner "${HOOK_OWNER:-}" --arg tty "${HOOK_TTY:-}" \
        --arg event "$HOOK_EVENT" --arg cwd "$PWD" \
        --arg codex "${CODEX_HOME:-$HOME/.codex}" --arg sqlite "${CODEX_SQLITE_HOME:-}" \
        '{type:"hook_event",version:1,source:$source,round_id:$round,
          occurred_at:($at|tonumber),started_at:($start|tonumber),session_dir:$sessions,
          rate_dir:$rates,hooks_dir:$hooks,owner:$owner,tty:$tty,codex_home:$codex,
          codex_sqlite_home:$sqlite,
          settings:(env | with_entries(select(.key | startswith("GHOSTTY_NOTIFY_")))),
          payload:({session_id, transcript_path, session_title, message, turn_id, agent_id,
                    prompt:(if (.prompt|type) == "string" then .prompt[0:200] else null end)}
                   + {hook_event_name:$event, cwd:(if (.cwd // "") == "" then $cwd else .cwd end)})}' 2>/dev/null) || return 1
    agent_deliver "$json" "$HOOK_AGENT_APP"
}
