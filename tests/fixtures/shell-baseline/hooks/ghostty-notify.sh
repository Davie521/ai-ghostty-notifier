#!/bin/bash
# The resident agent owns completion and permission-notification policy.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=hooks/hook-common.sh
source "$SCRIPT_DIR/hook-common.sh"
hook_read || exit 0
case "$HOOK_EVENT" in Stop|Notification) ;; *) exit 0 ;; esac
hook_context snapshot || exit 0
if hook_native_available && hook_queue_event; then exit 0; fi
printf '%s' "$HOOK_DATA" | /bin/bash "$SCRIPT_DIR/legacy-notify.sh"
exit 0
