#!/bin/bash
# Codex CLI adapter for the Ghostty notification hooks.
#
# Codex CLI (0.153+) ships native lifecycle hooks (~/.codex/hooks.json) whose
# events and stdin payload match Claude Code's: session_id, cwd,
# hook_event_name, transcript_path, turn_id. hooks.json routes PreToolUse,
# UserPromptSubmit and Stop to this script, which
#   1. accepts only a native `codex` CLI that owns a terminal (the same
#      hooks.json also fires for Codex Desktop threads and for the
#      `codex mcp-server` children other agents spawn — none of those has a
#      Ghostty tab to jump back to);
#   2. keeps Codex state, rate stamps and notification groups apart from
#      Claude's via the GHOSTTY_NOTIFY_* overrides the shared scripts honour;
#   3. supplies a session title (the thread name Codex stores, else the first
#      prompt of the session) — Codex rollouts carry no custom-title records
#      for ghostty-notify.sh to read;
#   4. hands the untouched payload to the shared script for that event.
#
# It is deliberately NOT a `notify` callback. `notify` is a single public slot
# in config.toml that other tools rewrite: Codex Desktop's Computer Use wraps
# whatever is there and forwards it only after its own IPC times out (120 s
# measured). hooks.json entries are per-file, so nothing can queue in front.
#
# Usage from hooks.json:  codex-hook.sh <PreToolUse|UserPromptSubmit|Stop>

[[ "${TERM_PROGRAM:-}" != "ghostty" ]] && [[ -z "${GHOSTTY_RESOURCES_DIR:-}" ]] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

EVENT="${1:-}"
case "$EVENT" in
    PreToolUse|UserPromptSubmit|Stop) ;;
    *) exit 0 ;;
esac

HOOK_DATA=""
if [[ ! -t 0 ]]; then
    HOOK_DATA=$(cat 2>/dev/null || true)
fi
[[ -z "$HOOK_DATA" ]] && exit 0

SESSION_ID=$(printf '%s' "$HOOK_DATA" | jq -r '.session_id // empty' 2>/dev/null)
# The id becomes part of filesystem paths and of a SQL literal below, and the
# shared scripts require the same shape.
[[ "$SESSION_ID" =~ ^[a-fA-F0-9-]+$ ]] || exit 0
# The payload names its own event; a hooks.json entry wired to the wrong
# argument must not, say, treat a PreToolUse as a Stop and fire an alert.
PAYLOAD_EVENT=$(printf '%s' "$HOOK_DATA" | jq -r '.hook_event_name // empty' 2>/dev/null)
[[ -n "$PAYLOAD_EVENT" && "$PAYLOAD_EVENT" != "$EVENT" ]] && exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"

# ── Overrides for the shared scripts ───────────────────────────────────────
# Set-but-empty GHOSTTY_NOTIFY_AGENT_APP pins the shell delivery path: the
# resident agent is Claude-branded and lives in Claude's hooks dir.
export GHOSTTY_NOTIFY_PROCESS_NAME="codex"
export GHOSTTY_NOTIFY_APP_NAME="Codex"
export GHOSTTY_NOTIFY_SESSION_DIR="${GHOSTTY_NOTIFY_SESSION_DIR:-$CODEX_HOME/notifications/ghostty-sessions}"
export GHOSTTY_NOTIFY_RATE_DIR="${GHOSTTY_NOTIFY_RATE_DIR:-$CODEX_HOME/notifications/state}"
export GHOSTTY_NOTIFY_GROUP_PREFIX="${GHOSTTY_NOTIFY_GROUP_PREFIX:-codex-ghostty-notify}"
export GHOSTTY_NOTIFY_AGENT_APP=""
STATE_DIR="$GHOSTTY_NOTIFY_SESSION_DIR"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

# Thresholds: config.json beside this script (written by install-codex.py),
# environment wins. Claude gets the same knobs from settings.json's "env";
# Codex has no per-hook env block, hence the file.
CONFIG_FILE="$SCRIPT_DIR/config.json"
if [[ -f "$CONFIG_FILE" ]]; then
    for name in GHOSTTY_NOTIFY_MIN_ELAPSED GHOSTTY_NOTIFY_SOUND_ELAPSED \
                GHOSTTY_NOTIFY_TIMEOUT GHOSTTY_NOTIFY_CLEAR_ON_FOCUS; do
        [[ -n "${!name:-}" ]] && continue
        value=$(jq -r --arg k "$name" \
            'if .[$k] == null then empty else (.[$k] | tostring) end' \
            "$CONFIG_FILE" 2>/dev/null)
        [[ -n "$value" ]] && export "$name=$value"
    done
fi

# ── Native CLI gate ────────────────────────────────────────────────────────
# Walk up to the nearest codex process and require a controlling TTY. The
# identity (pid:tty:start time) doubles as the session's owner: `codex
# resume` in another tab is the same session_id in a new process, and the
# tab binding saved for the old process would send "Go to tab" to the wrong
# tab. The gate runs on every prompt (cheap: a few ps calls once per round)
# and the result is cached for the tool calls and the Stop that follow.
native_codex_owner() {
    local pid=$$ depth=16 parent cmd tty
    while (( depth-- > 0 )) && [[ "$pid" -gt 1 ]]; do
        parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [[ "$parent" =~ ^[0-9]+$ ]] && (( parent > 1 )) || return 1
        cmd=$(ps -o command= -p "$parent" 2>/dev/null)
        case "$cmd" in
            codex|codex\ *|*/codex|*/codex\ *)
                tty=$(ps -o tty= -p "$parent" 2>/dev/null | tr -d ' ')
                [[ -n "$tty" && "$tty" != "??" ]] || return 1
                printf '%s:%s:%s\n' "$parent" "$tty" \
                    "$(ps -o lstart= -p "$parent" 2>/dev/null)"
                return 0
                ;;
        esac
        pid="$parent"
    done
    return 1
}

OWNER_FILE="$STATE_DIR/${SESSION_ID}.codex-owner"
if [[ "$EVENT" == "UserPromptSubmit" || ! -f "$OWNER_FILE" ]]; then
    OWNER=$(native_codex_owner || true)
    PREVIOUS=$(cat "$OWNER_FILE" 2>/dev/null || true)
    # "-" records a session that is not a native CLI, so the tool calls of a
    # Desktop or MCP thread cost one file read each instead of a ps walk.
    printf '%s\n' "${OWNER:--}" > "$OWNER_FILE" 2>/dev/null
    if [[ -n "$PREVIOUS" && "$PREVIOUS" != "${OWNER:--}" ]]; then
        # Owner changed: drop the tab binding so the next PreToolUse resolves
        # the tab this process actually runs in. Never match a tab by cwd.
        rm -f "$STATE_DIR/${SESSION_ID}.json" "$STATE_DIR/${SESSION_ID}.attempts" 2>/dev/null
    fi
else
    OWNER=$(cat "$OWNER_FILE" 2>/dev/null || true)
    [[ "$OWNER" == "-" ]] && OWNER=""
fi
[[ -z "$OWNER" ]] && exit 0

# ── Session title ──────────────────────────────────────────────────────────
# The first prompt of a session is the closest thing to Claude's ai-title
# and is only ever visible here, on UserPromptSubmit. A thread name Codex
# itself stores (its state database) outranks it at Stop time.
TITLE_FILE="$STATE_DIR/${SESSION_ID}.title"
if [[ "$EVENT" == "UserPromptSubmit" && ! -f "$TITLE_FILE" ]]; then
    printf '%s' "$HOOK_DATA" \
        | jq -r '.prompt // empty | gsub("[\\n\\r\\t]"; " ") | .[0:120]' 2>/dev/null \
        | tr -d '\000-\037\177' > "$TITLE_FILE" 2>/dev/null
fi

codex_thread_name() {
    command -v sqlite3 >/dev/null 2>&1 || return 0
    local db name
    for db in "$CODEX_HOME"/state_*.sqlite; do
        [[ -f "$db" ]] || continue
        # Read-only, short busy timeout: the live CLI holds the write lock and
        # the notification must not wait on it. A missing column or a schema
        # change simply yields no name.
        name=$(sqlite3 -readonly -cmd '.timeout 200' "$db" \
            "SELECT name FROM threads WHERE id = '$SESSION_ID' LIMIT 1" 2>/dev/null | head -n 1)
        if [[ -n "$name" ]]; then
            printf '%s\n' "$name"
            return 0
        fi
    done
    return 0
}

# ── Dispatch ───────────────────────────────────────────────────────────────
case "$EVENT" in
    PreToolUse)
        printf '%s' "$HOOK_DATA" | "$SCRIPT_DIR/ghostty-tab-save.sh"
        ;;
    UserPromptSubmit)
        printf '%s' "$HOOK_DATA" | "$SCRIPT_DIR/ghostty-round-reset.sh"
        ;;
    Stop)
        TITLE=$(codex_thread_name)
        [[ -z "$TITLE" ]] && TITLE=$(head -n 1 "$TITLE_FILE" 2>/dev/null || true)
        # ghostty-notify.sh prefers a session_title field on stdin over any
        # transcript lookup; an empty title keeps its generic wording.
        printf '%s' "$HOOK_DATA" \
            | jq -c --arg t "$TITLE" 'if $t == "" then . else . + {session_title: $t} end' 2>/dev/null \
            | "$SCRIPT_DIR/ghostty-notify.sh"
        ;;
esac
exit 0
