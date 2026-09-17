#!/bin/bash
# Capture CLI identity here; defer completion inside the resident agent.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=hooks/hook-common.sh
source "$SCRIPT_DIR/hook-common.sh"
hook_read || exit 0
EVENT="${1:-}"
case "$EVENT" in UserPromptSubmit|Stop) ;; *) exit 0 ;; esac
[[ -z "$HOOK_EVENT" || "$HOOK_EVENT" == "$EVENT" ]] || exit 0
HOOK_EVENT="$EVENT"
hook_codex_settings
if hook_native_available; then
    hook_owner || exit 0
    case "$EVENT" in UserPromptSubmit) hook_context prompt ;; *) hook_context snapshot ;; esac || exit 0
    if hook_queue_event; then exit 0; fi
fi
printf '%s' "$HOOK_DATA" | /bin/bash "$SCRIPT_DIR/legacy-codex-hook.sh" "$EVENT"
exit 0
