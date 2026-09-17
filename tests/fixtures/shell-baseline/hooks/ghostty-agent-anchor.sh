#!/usr/bin/env bash
# UserPromptSubmit hook: tell the agent where this session lives, and withdraw
# anything still on screen for it.
#
# Submitting a prompt is the cheapest possible proof that the user is back at
# their terminal — free, exact, and it needs no polling.
#
# The tab id is read from the file ghostty-tab-save.sh already wrote, NOT
# sampled from whatever is focused when the agent gets around to the request:
# the agent may drain a second or more later, by which point the user can be
# looking at a different tab, and anchoring a session to the wrong tab both
# withdraws its notification early and sends click-to-jump to someone else's
# session.
#
# Anchor before dismiss so the agent knows this session's tab before it decides
# what to withdraw.

set -u
IFS=$'\n\t'

# Same gate every sibling hook applies. Without it this hook would start a
# resident accessory app — and raise a notification-permission prompt — for
# users running Claude Code in Terminal.app, iTerm or VS Code, who can never
# receive a notification from this plugin because ghostty-notify.sh exits early
# on those terminals.
if [[ "${TERM_PROGRAM:-}" != "ghostty" ]] && [[ -z "${GHOSTTY_RESOURCES_DIR:-}" ]]; then
    exit 0
fi

HOOK_DATA=""
if [[ ! -t 0 ]]; then
    HOOK_DATA=$(cat 2>/dev/null || true)
fi

command -v jq >/dev/null 2>&1 || { printf '%s\n' 'ghostty-notify: jq is missing.' >&2; exit 0; }
SESSION_ID=$(printf '%s' "$HOOK_DATA" | jq -r '.session_id // empty' 2>/dev/null)

# Same shape guard every hook applies before a session id reaches a path or a
# dictionary key.
[[ "$SESSION_ID" =~ ^[a-fA-F0-9-]+$ ]] || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
# The new prompt entry sends a single generation-scoped event. Installed
# configurations with this second legacy entry remain valid without double clear.
# shellcheck source=hooks/hook-common.sh
source "$SCRIPT_DIR/hook-common.sh"
hook_native_available && exit 0
# shellcheck source=hooks/agent-common.sh
source "$SCRIPT_DIR/agent-common.sh" 2>/dev/null || exit 0

APP=$(agent_app "$SCRIPT_DIR") || exit 0

# The Codex adapter keeps its bindings apart from Claude's and says where;
# Claude's own hooks leave the override unset.
SAVE_DIR="${GHOSTTY_NOTIFY_SESSION_DIR:-$HOME/.claude/notifications/ghostty-sessions}"
SAVE_FILE="$SAVE_DIR/${SESSION_ID}.json"
TAB_ID=""
[[ -f "$SAVE_FILE" ]] && TAB_ID=$(jq -r '.tab_id // empty' "$SAVE_FILE" 2>/dev/null)

# An empty tab_id is sent as an absent field, which tells the agent to fill the
# gap by sampling — a guess, but better than nothing for tmux sessions.
if [[ -n "$TAB_ID" ]]; then
    agent_queue "$(jq -nc --arg s "$SESSION_ID" --arg t "$TAB_ID" \
        --arg source "${GHOSTTY_NOTIFY_PROCESS_NAME:-claude}" \
        '{type:"anchor",session_id:$s,tab_id:$t} +
         (if $source == "codex" then {source:$source} else {} end)')" "$APP"
else
    agent_queue "$(jq -nc --arg s "$SESSION_ID" --arg source "${GHOSTTY_NOTIFY_PROCESS_NAME:-claude}" \
        '{type:"anchor",session_id:$s} +
         (if $source == "codex" then {source:$source} else {} end)')" "$APP"
fi

# Honour the same opt-out as the shell watcher: someone who keeps completion
# notifications in Notification Center as a to-do list must not have them
# withdrawn by typing the next prompt. Keep this list in sync with
# ghostty-notify.sh and ghostty-round-reset.sh.
case "${GHOSTTY_NOTIFY_CLEAR_ON_FOCUS:-1}" in
    0|false|no|off|FALSE|NO|OFF) exit 0 ;;
esac

# Old agents ignore the extra field; new agents need it even when the user
# switches to the shell backend, to retire a previously native Codex notice.
agent_queue "$(jq -nc --arg s "$SESSION_ID" --arg source "${GHOSTTY_NOTIFY_PROCESS_NAME:-claude}" \
    '{type:"dismiss",session_id:$s} +
     (if $source == "codex" then {source:$source} else {} end)')" "$APP"

exit 0
