#!/bin/bash
# Clear (dismiss) a session's on-screen notification.
#
#   ghostty-notify-clear.sh <session_id>
#
# "Clear" means: remove the delivered notification from the screen and from
# Notification Center by group ID (terminal-notifier -remove).
#
# This is the FALLBACK path, and only half of the feature. When the resident
# agent delivered the notification it also withdraws it — on a NSWorkspace
# activation event, from inside one process, exactly when the session's tab
# comes forward. ghostty-agent-anchor.sh asks it to do so on the next prompt
# as well. This script exists for machines where the agent could not deliver:
# no Swift toolchain, permission declined, or GHOSTTY_NOTIFY_AGENT_APP=""
# pinning the shell path. There, terminal-notifier has no click and no
# process to observe, so the only honest trigger left is the user typing
# their next prompt, which ghostty-round-reset.sh turns into a call here.
#
# (Earlier versions polled once a second to catch the tab regaining focus,
# and killed the blocking `alerter` process that owned the alert. Both went
# with the alerter backend.)

SESSION_ID="${1:-}"
[[ -z "$SESSION_ID" ]] && exit 0
# Same shape constraint as the sibling hooks: the id becomes part of
# filesystem paths, so anything outside Claude Code's UUID alphabet is out.
[[ "$SESSION_ID" =~ ^[a-fA-F0-9-]+$ ]] || exit 0

SAVE_DIR="${GHOSTTY_NOTIFY_SESSION_DIR:-$HOME/.claude/notifications/ghostty-sessions}"
NOTIFIED_FILE="$SAVE_DIR/${SESSION_ID}.notified"
# Must stay in sync with GROUP_ID in ghostty-notify.sh.
GROUP_ID="${GHOSTTY_NOTIFY_GROUP_PREFIX:-ghostty-notify}-${SESSION_ID}"

# An epoch stamped by the caller. A notification delivered AFTER that instant
# belongs to a newer round and must survive: ghostty-round-reset.sh runs this
# in the background, and a permission prompt under GHOSTTY_NOTIFY_ON_PROMPT=1
# can land inside that window — killing it unseen would stall the session
# silently. No stamp means clear unconditionally.
CLEAR_BEFORE="${GHOSTTY_NOTIFY_CLEAR_BEFORE:-}"
[[ "$CLEAR_BEFORE" =~ ^[0-9]+$ ]] || CLEAR_BEFORE=""
if [[ -n "$CLEAR_BEFORE" && -f "$NOTIFIED_FILE" ]]; then
    DELIVERED=$(cat "$NOTIFIED_FILE" 2>/dev/null)
    [[ "$DELIVERED" =~ ^[0-9]+$ ]] || DELIVERED=0
    (( DELIVERED > CLEAR_BEFORE )) && exit 0
fi

# Removing an absent group is a silent no-op, so this is safe to call even
# when the agent (not terminal-notifier) delivered the alert.
command -v terminal-notifier >/dev/null 2>&1 \
    && terminal-notifier -remove "$GROUP_ID" >/dev/null 2>&1

rm -f "$NOTIFIED_FILE" 2>/dev/null
exit 0
