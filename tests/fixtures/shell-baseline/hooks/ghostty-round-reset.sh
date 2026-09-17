#!/bin/bash
# Capture a new generation before the CLI starts work on this prompt.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=hooks/hook-common.sh
source "$SCRIPT_DIR/hook-common.sh"
hook_read || exit 0
HOOK_EVENT=UserPromptSubmit
hook_context prompt || exit 0
if hook_native_available && hook_queue_event; then exit 0; fi
printf '%s' "$HOOK_DATA" | /bin/bash "$SCRIPT_DIR/legacy-round-reset.sh"
exit 0
