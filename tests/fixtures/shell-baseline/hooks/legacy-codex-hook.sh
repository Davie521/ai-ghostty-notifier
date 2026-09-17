#!/bin/bash
# Compatibility Codex adapter for an unavailable or older resident agent.
#
# Codex CLI (0.153+) ships native lifecycle hooks (~/.codex/hooks.json) whose
# events and stdin payload match Claude Code's: session_id, cwd,
# hook_event_name, transcript_path, turn_id. hooks.json routes
# UserPromptSubmit and Stop to this script, which
#   1. accepts only a native `codex` CLI that owns a terminal (the same
#      hooks.json also fires for Codex Desktop threads and for the
#      `codex mcp-server` children other agents spawn — none of those has a
#      Ghostty tab to jump back to);
#   2. keeps Codex state, rate stamps and notification groups apart from
#      Claude's via the GHOSTTY_NOTIFY_* overrides the shared scripts honour;
#   3. times the round from the prompt — a Codex turn can spend minutes on
#      reasoning or hosted tools before (or without) any local tool call, so
#      Claude's PreToolUse start signal would miss it — and ignores
#      sub-agent traffic, which reports the root session's id;
#   4. on Stop, hands over to a detached process that lets the turn end,
#      skips turn boundaries Codex continues straight through, resolves the
#      tab, and only then delivers through the shared scripts — to the
#      resident agent when it is installed, else alerter.
#
# Why the tab is resolved at Stop: ghostty-tab-save.sh identifies the tab by
# writing a marker title and asking Ghostty who shows it. The Codex TUI
# rewrites the title every 100 ms while a turn runs, so a marker written
# mid-turn is gone before Ghostty can be asked; once the turn ends the title
# holds still.
#
# It is deliberately NOT a `notify` callback. `notify` is a single public slot
# in config.toml that other tools rewrite: Codex Desktop's Computer Use wraps
# whatever is there and forwards it only after its own IPC times out (120 s
# measured). hooks.json entries are per-file, so nothing can queue in front.
#
# Usage from hooks.json:  codex-hook.sh <UserPromptSubmit|Stop>
# A PreToolUse entry left by an earlier install is accepted and does nothing.

[[ "${TERM_PROGRAM:-}" != "ghostty" ]] && [[ -z "${GHOSTTY_RESOURCES_DIR:-}" ]] && exit 0
command -v jq >/dev/null 2>&1 || { printf '%s\n' 'ghostty-notify: jq is missing.' >&2; exit 0; }

EVENT="${1:-}"
# Drain stdin before deciding anything: exiting with the payload unread
# would hand Codex an EPIPE for a hook that merely had nothing to do.
HOOK_DATA=""
if [[ ! -t 0 ]]; then
    HOOK_DATA=$(cat 2>/dev/null || true)
fi
case "$EVENT" in
    UserPromptSubmit|Stop) ;;
    *) exit 0 ;;
esac
[[ -z "$HOOK_DATA" ]] && exit 0

SESSION_ID=$(printf '%s' "$HOOK_DATA" | jq -r '.session_id // empty' 2>/dev/null)
# The id becomes part of filesystem paths and of a SQL literal below, and the
# shared scripts require the same shape.
[[ "$SESSION_ID" =~ ^[a-fA-F0-9-]+$ ]] || exit 0
# The payload names its own event; a hooks.json entry wired to the wrong
# argument must not, say, treat a Stop as a prompt and re-arm the timer.
PAYLOAD_EVENT=$(printf '%s' "$HOOK_DATA" | jq -r '.hook_event_name // empty' 2>/dev/null)
[[ -n "$PAYLOAD_EVENT" && "$PAYLOAD_EVENT" != "$EVENT" ]] && exit 0
# Sub-agent threads report the root session_id plus an agent_id. Their
# prompts are not the user's round boundary and must not touch its timer.
AGENT_ID=$(printf '%s' "$HOOK_DATA" | jq -r '.agent_id // empty' 2>/dev/null)
[[ -n "$AGENT_ID" ]] && exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
# shellcheck source=hooks/hook-common.sh
source "$SCRIPT_DIR/hook-common.sh"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"

# ── Settings ───────────────────────────────────────────────────────────────
# config.json beside this script (written by install-codex.py) carries any
# GHOSTTY_NOTIFY_* knob the shared scripts read — thresholds, backend,
# alerter path, focus poll … — and the environment wins over it. Claude gets
# the same knobs from settings.json's "env"; Codex has no per-hook env block,
# hence the file.
CONFIG_FILE="$SCRIPT_DIR/config.json"
if [[ -f "$CONFIG_FILE" ]]; then
    while IFS= read -r line; do
        name="${line%%=*}"
        value="${line#*=}"
        [[ "$name" =~ ^GHOSTTY_NOTIFY_[A-Z0-9_]+$ ]] || continue
        [[ -n "${!name:-}" ]] && continue
        export "$name=$value"
    done < <(jq -r 'to_entries[]
        | select(.key | startswith("GHOSTTY_NOTIFY_"))
        | select(.value != null)
        | "\(.key)=\(.value | tostring)"' "$CONFIG_FILE" 2>/dev/null)
fi
# Identity is not configurable: it keeps Codex's state, rate stamps and
# notification groups apart from Claude's. The resident agent is shared. The
# shared scripts discover it exactly as Claude's hooks do, and a
# GHOSTTY_NOTIFY_AGENT_APP in config.json or the environment still names a
# specific bundle — or, set empty, pins the shell delivery path.
export GHOSTTY_NOTIFY_PROCESS_NAME="codex"
export GHOSTTY_NOTIFY_APP_NAME="Codex"
export GHOSTTY_NOTIFY_SESSION_DIR="${GHOSTTY_NOTIFY_SESSION_DIR:-$CODEX_HOME/notifications/ghostty-sessions}"
export GHOSTTY_NOTIFY_RATE_DIR="${GHOSTTY_NOTIFY_RATE_DIR:-$CODEX_HOME/notifications/state}"
export GHOSTTY_NOTIFY_GROUP_PREFIX="${GHOSTTY_NOTIFY_GROUP_PREFIX:-codex-ghostty-notify}"
STATE_DIR="$GHOSTTY_NOTIFY_SESSION_DIR"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

MIN_ELAPSED="${GHOSTTY_NOTIFY_MIN_ELAPSED:-180}"
[[ "$MIN_ELAPSED" =~ ^[0-9]+$ ]] || MIN_ELAPSED=180

OWNER_FILE="$STATE_DIR/${SESSION_ID}.codex-owner"
TITLE_FILE="$STATE_DIR/${SESSION_ID}.title"
START_FILE="$STATE_DIR/${SESSION_ID}.start"
SAVE_FILE="$STATE_DIR/${SESSION_ID}.json"

if [[ "$EVENT" == "UserPromptSubmit" ]]; then
    # Per-session files nothing else deletes. ghostty-tab-save.sh prunes the
    # same set, but only runs for terminal sessions; Desktop and MCP threads
    # leave their "-" owner marks here and never reach it.
    find "$STATE_DIR" -type f \( -name '*.codex-owner' -o -name '*.title' -o -name '*.start' \
        -o -name '*.json' -o -name '*.attempts' -o -name '*.alerter-pid' -o -name '*.watch-pid' \) \
        -mtime +7 -delete 2>/dev/null
fi

# ── Native CLI gate ────────────────────────────────────────────────────────
# Walk up to the nearest codex process and require a controlling TTY. The
# identity (pid:tty:start time) doubles as the session's owner: `codex
# resume` in another tab is the same session_id in a new process, and the
# tab binding saved for the old process would send "Go to tab" to the wrong
# tab. The gate runs on every prompt (cheap: a few ps calls once per round)
# and the result is cached for the Stop that follows.
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

if [[ "$EVENT" == "UserPromptSubmit" || ! -f "$OWNER_FILE" ]]; then
    OWNER=$(native_codex_owner || true)
    PREVIOUS=$(cat "$OWNER_FILE" 2>/dev/null || true)
    # "-" records a session that is not a native CLI, so its later events
    # cost one file read instead of a ps walk.
    printf '%s\n' "${OWNER:--}" > "$OWNER_FILE" 2>/dev/null
    if [[ -n "$PREVIOUS" && "$PREVIOUS" != "${OWNER:--}" ]]; then
        # Owner changed: drop the tab binding so the next Stop resolves the
        # tab this process actually runs in. Never match a tab by cwd.
        rm -f "$SAVE_FILE" "$STATE_DIR/${SESSION_ID}.attempts" 2>/dev/null
    fi
else
    OWNER=$(cat "$OWNER_FILE" 2>/dev/null || true)
    [[ "$OWNER" == "-" ]] && OWNER=""
fi
[[ -z "$OWNER" ]] && exit 0
if [[ "${GHOSTTY_NOTIFY_CONTEXT_CAPTURED:-0}" != 1 ]]; then
    HOOK_OCCURRED_AT="${GHOSTTY_NOTIFY_EVENT_AT:-$(date +%s)}"
    case "$EVENT" in UserPromptSubmit) hook_context prompt ;; *) hook_context snapshot ;; esac || exit 0
fi
OWNER_TTY="${OWNER#*:}"
OWNER_TTY="${OWNER_TTY%%:*}"

# ── Session title ──────────────────────────────────────────────────────────
# The first prompt of a session is the closest thing to Claude's ai-title
# and is only ever visible here, on UserPromptSubmit. A thread name Codex
# itself stores (its state database) outranks it at Stop time. The slice
# comes first: gsub over a pasted log would take seconds.
if [[ "$EVENT" == "UserPromptSubmit" && ! -s "$TITLE_FILE" ]]; then
    TITLE=$(printf '%s' "$HOOK_DATA" \
        | jq -r '.prompt // "" | .[0:200] | gsub("[\\n\\r\\t]"; " ") | gsub("^ +| +$"; "") | .[0:120]' 2>/dev/null \
        | tr -d '\000-\037\177')
    [[ -n "$TITLE" ]] && printf '%s\n' "$TITLE" > "$TITLE_FILE" 2>/dev/null
fi

codex_thread_name() {
    command -v sqlite3 >/dev/null 2>&1 || return 0
    # Codex keeps its state database under config.toml's sqlite_home, else
    # $CODEX_SQLITE_HOME, else $CODEX_HOME — in that order of precedence.
    local dir
    dir=$(sed -n 's/^[[:space:]]*sqlite_home[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$CODEX_HOME/config.toml" 2>/dev/null | head -n 1)
    [[ -z "$dir" ]] && dir="${CODEX_SQLITE_HOME:-}"
    [[ "$dir" =~ ^~/ ]] && dir="$HOME/${dir:2}"
    [[ -z "$dir" ]] && dir="$CODEX_HOME"
    # state_<N>.sqlite, highest N = current schema; backups and other names
    # beside it are not consulted.
    local db best="" best_version=-1 version
    for db in "$dir"/state_*.sqlite; do
        [[ -f "$db" ]] || continue
        version="${db##*/state_}"
        version="${version%.sqlite}"
        [[ "$version" =~ ^[0-9]+$ ]] || continue
        (( version > best_version )) && { best_version=$version; best="$db"; }
    done
    [[ -n "$best" ]] || return 0
    # Read-only, short busy timeout: the live CLI holds the write lock and
    # the notification must not wait on it. -init /dev/null keeps the
    # user's ~/.sqliterc (headers, box mode …) out of the output. A missing
    # column or a schema change simply yields no name.
    sqlite3 -readonly -noheader -init /dev/null -cmd '.timeout 200' "$best" \
        "SELECT name FROM threads WHERE id = '$SESSION_ID' LIMIT 1" 2>/dev/null | head -n 1
    return 0
}

# A task_started for another turn after ours means Codex is still working:
# /goal auto-continuation, a Tab-queued follow-up, another Stop hook asking
# it to go on. The TUI suppresses its own completion alert there; so do we,
# and the round keeps its start time. The rollout is the witness.
continuing() {
    [[ -n "$TURN_ID" && -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]] || return 1
    local last turn started
    last=$(tail -c 262144 "$TRANSCRIPT_PATH" 2>/dev/null \
        | grep -a '"task_started"' \
        | jq -Rr 'fromjson? | select(.type == "event_msg" and .payload.type == "task_started")
                  | "\(.payload.turn_id // "") \(.payload.started_at // "")"' 2>/dev/null \
        | tail -n 1)
    turn="${last%% *}"
    started="${last#* }"
    [[ -n "$turn" && "$turn" != "$TURN_ID" ]] || return 1
    # A start stamp must be from around this Stop; the tail may reach back
    # to a turn that ended long ago when ours produced a lot of output.
    if [[ "$started" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        (( ${started%%.*} + 5 >= STOP_AT )) || return 1
    fi
    return 0
}

# ── Dispatch ───────────────────────────────────────────────────────────────
case "$EVENT" in
    UserPromptSubmit)
        # Clears a still-visible alert for this session (the user is back)
        # and the previous timer; then the round is timed from this prompt.
        printf '%s' "$HOOK_DATA" | /bin/bash "$SCRIPT_DIR/legacy-round-reset.sh"
        # The same proof of presence for the resident agent, when it is the
        # one holding the alert: anchor the session's tab, then withdraw.
        # Returns at once when no agent is installed.
        [[ -x "$SCRIPT_DIR/ghostty-agent-anchor.sh" ]] &&
            printf '%s' "$HOOK_DATA" | "$SCRIPT_DIR/ghostty-agent-anchor.sh"
        ;;
    Stop)
        TRANSCRIPT_PATH=$(printf '%s' "$HOOK_DATA" | jq -r '.transcript_path // empty' 2>/dev/null)
        TURN_ID=$(printf '%s' "$HOOK_DATA" | jq -r '.turn_id // empty' 2>/dev/null)
        STOP_AT=$(date +%s)
        # Codex waits for the hook; the turn ends when it returns. Settling
        # lets the TUI go idle (title static) and a continuation announce
        # itself before anything is decided.
        SETTLE="${GHOSTTY_NOTIFY_CODEX_SETTLE:-1.5}"
        [[ "$SETTLE" =~ ^[0-9]+([.][0-9]+)?$ ]] || SETTLE=1.5
        # Thread-title generation can keep the title animated for a few
        # seconds after the first turn; the retries outlast it.
        RETRY_DELAYS="${GHOSTTY_NOTIFY_MARKER_RETRY_DELAYS-0.5 1 2 3}"
        TTY_PATH="${GHOSTTY_NOTIFY_TTY:-}"
        if [[ -z "$TTY_PATH" && "$OWNER_TTY" =~ ^[A-Za-z0-9]+$ ]]; then
            TTY_PATH="/dev/$OWNER_TTY"
        fi
        (
            sleep "$SETTLE"
            hook_current_round || exit 0
            continuing && exit 0
            START=$(cat "$START_FILE" 2>/dev/null || echo 0)
            START="${GHOSTTY_NOTIFY_ROUND_START:-$START}"
            [[ "$START" =~ ^[0-9]+$ ]] || START=0
            # The marker round-trip costs Apple Events; rounds the shared
            # script will suppress anyway skip it. ghostty-tab-save.sh itself
            # returns at once while the binding is current, and re-resolves
            # the tab after a Ghostty restart.
            if (( START > 0 && $(date +%s) - START >= MIN_ELAPSED )) \
                && [[ -n "$TTY_PATH" ]]; then
                printf '%s' "$HOOK_DATA" | GHOSTTY_NOTIFY_TTY="$TTY_PATH" \
                    GHOSTTY_NOTIFY_MARKER_RETRY_DELAYS="$RETRY_DELAYS" \
                    "$SCRIPT_DIR/ghostty-tab-save.sh"
            fi
            TITLE=$(codex_thread_name)
            [[ -z "$TITLE" ]] && TITLE=$(head -n 1 "$TITLE_FILE" 2>/dev/null || true)
            # ghostty-notify.sh prefers a session_title field on stdin over
            # any transcript lookup; an empty title keeps its generic wording.
            printf '%s' "$HOOK_DATA" \
                | jq -c --arg t "$TITLE" 'if $t == "" then . else . + {session_title: $t} end' 2>/dev/null \
                | /bin/bash "$SCRIPT_DIR/legacy-notify.sh"
        ) </dev/null >/dev/null 2>&1 &
        disown
        ;;
esac
exit 0
