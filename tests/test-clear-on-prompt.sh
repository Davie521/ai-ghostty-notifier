#!/usr/bin/env bash
# Integration test for hooks/ghostty-notify-clear.sh, the fallback clear.
#
# The resident agent withdraws its own notifications; this script is what
# clears a terminal-notifier alert, and the only trigger left there is the
# user submitting the next prompt (ghostty-round-reset.sh calls it).
#
# Covered:
#   - a new prompt removes the delivered notification's group
#   - GHOSTTY_NOTIFY_CLEAR_ON_FOCUS=0 opts out of that
#   - a notification delivered AFTER the clear was requested survives
#     (GHOSTTY_NOTIFY_CLEAR_BEFORE), while an unstamped clear removes it
#   - clears are session-scoped and bogus session ids touch nothing
#   - nothing the notify hook starts outlives it: no watcher, no click
#     handler, no process left behind
#
# External surfaces are stubbed: terminal-notifier records -remove and can
# be made to fail, and the resident agent is pinned off so the shell path
# is the one under test.

set -u
IFS=$'\n\t'

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
HOOK="$REPO/hooks/ghostty-notify.sh"
CLEAR="$REPO/hooks/ghostty-notify-clear.sh"
RESET="$REPO/hooks/ghostty-round-reset.sh"

for f in "$HOOK" "$CLEAR" "$RESET"; do
    [[ -x "$f" ]] || { echo "FATAL: $f not executable" >&2; exit 2; }
done
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

export HOME="$SANDBOX"
export PATH="$SANDBOX/bin:$PATH"
SESS_DIR="$HOME/.claude/notifications/ghostty-sessions"
CONTROL="$SANDBOX/control"
mkdir -p "$HOME/.claude/hooks" "$SESS_DIR" "$SANDBOX/bin" "$CONTROL"

# terminal-notifier stub: records -remove, swallows a post, and can be made
# to fail so "delivered" versus "tried to deliver" stays observable.
cat > "$SANDBOX/bin/terminal-notifier" <<SH
#!/bin/bash
if [[ "\${1:-}" == "-remove" ]]; then
    printf 'tn:%s\n' "\$2" >> "$CONTROL/removed"
    exit 0
fi
[[ -f "$CONTROL/tn-fail" ]] && exit 1
printf 'fired\n' >> "$CONTROL/fired"
exit 0
SH
chmod +x "$SANDBOX/bin/terminal-notifier"

export TERM_PROGRAM=ghostty
export GHOSTTY_NOTIFY_MIN_ELAPSED=10
export GHOSTTY_NOTIFY_SOUND_ELAPSED=9999
export GHOSTTY_NOTIFY_TIMEOUT=20
export GHOSTTY_NOTIFY_BACKEND=auto
# The shell path is the subject: the agent would deliver and withdraw from
# its own process, and none of the stubs below would ever be touched. The
# empty value relies on agent_app using `${VAR-default}`, not `${VAR:-…}`.
export GHOSTTY_NOTIFY_AGENT_APP=""
unset GHOSTTY_RESOURCES_DIR || true
unset GHOSTTY_NOTIFY_CLEAR_ON_FOCUS || true
unset GHOSTTY_NOTIFY_CLEAR_SCRIPT || true

pass=0; fail=0
fail_list=()

ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); fail_list+=("$1"); }

check() {  # $1: 0/1 result, $2: label
    if [[ "$1" == "0" ]]; then ok "$2"; else bad "$2"; fi
}

want() {  # $1: label, $2...: predicate that must succeed
    local label="$1"; shift
    if "$@"; then ok "$label"; else bad "$label"; fi
}

removed_has() { grep -q "ghostty-notify-$1\$" "$CONTROL/removed" 2>/dev/null; }
no_removal_for() { ! removed_has "$1"; }
file_gone() { [[ ! -f "$1" ]]; }
fired_count() { grep -c fired "$CONTROL/fired" 2>/dev/null || true; }

new_sid() { printf 'ab%s-%s' "$(date +%s)" "$RANDOM"; }

fire_notification() {  # $1: sid
    echo $(( $(date +%s) - 60 )) > "$SESS_DIR/$1.start"
    printf '{"session_id":"%s","cwd":"/tmp/proj","hook_event_name":"Stop"}' "$1" \
        | "$HOOK" >/dev/null 2>&1
}

submit_prompt() {  # $1: sid
    printf '{"session_id":"%s","cwd":"/tmp/proj","hook_event_name":"UserPromptSubmit"}' "$1" \
        | "$RESET" >/dev/null 2>&1
}

wait_for() {  # $1: max tries (x100ms), $2...: condition
    local tries="$1"; shift
    local i=0
    while (( i < tries )); do
        "$@" && return 0
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

reset_control() { rm -f "$CONTROL/removed" "$CONTROL/fired" "$CONTROL/tn-fail" 2>/dev/null; }

echo "== clear-on-prompt =="

# ── Case 1: the next prompt clears the delivered notification ──────────────
reset_control
sid=$(new_sid)
fire_notification "$sid"
check "$([[ "$(fired_count)" == "1" ]] && echo 0 || echo 1)" "fallback delivered the notification"
want "delivery is stamped" test -s "$SESS_DIR/$sid.notified"
submit_prompt "$sid"
wait_for 30 removed_has "$sid"
check $? "next prompt removes the notification group"
want "the stamp is cleared with it" wait_for 30 file_gone "$SESS_DIR/$sid.notified"
want "the round timer was re-armed" file_gone "$SESS_DIR/$sid.start"

# ── Case 2: opting out keeps the notification ─────────────────────────────
reset_control
sid=$(new_sid)
fire_notification "$sid"
GHOSTTY_NOTIFY_CLEAR_ON_FOCUS=0 submit_prompt "$sid"
sleep 0.5
want "opt-out: notification survives the next prompt" no_removal_for "$sid"
# An unrecognised value must fall back to the documented default (on),
# like every other knob in this project.
GHOSTTY_NOTIFY_CLEAR_ON_FOCUS=true submit_prompt "$sid"
wait_for 30 removed_has "$sid"
check $? "an unrecognised opt-out value still clears"

# ── Case 3: a notification delivered after the clear was requested ────────
# ghostty-round-reset.sh backgrounds the clear and stamps the moment it was
# requested. A permission prompt under GHOSTTY_NOTIFY_ON_PROMPT=1 can land
# inside that window; killing it unseen would stall the session silently.
reset_control
sid=$(new_sid)
fire_notification "$sid"
date +%s > "$SESS_DIR/$sid.notified"          # delivered "now"
GHOSTTY_NOTIFY_CLEAR_BEFORE=$(( $(date +%s) - 5 )) "$CLEAR" "$sid" >/dev/null 2>&1
want "clear-before: a newer notification survives" no_removal_for "$sid"
# Without a stamp the clear is unconditional — that is the prompt-submit
# path's own behaviour when nothing was delivered this round.
"$CLEAR" "$sid" >/dev/null 2>&1
wait_for 30 removed_has "$sid"
check $? "clear-before: an unstamped clear still removes it"

# ── Case 4: clears are session-scoped ─────────────────────────────────────
reset_control
sid_a=$(new_sid); sid_b=$(new_sid)
fire_notification "$sid_a"
fire_notification "$sid_b"
submit_prompt "$sid_a"
wait_for 30 removed_has "$sid_a"
check $? "session A cleared"
want "session B untouched" no_removal_for "$sid_b"

# ── Case 5: bogus session ids touch nothing ───────────────────────────────
reset_control
"$CLEAR" "../../escape" >/dev/null 2>&1
want "path-traversal id is refused" test ! -f "$CONTROL/removed"
"$CLEAR" "" >/dev/null 2>&1
want "empty id is refused" test ! -f "$CONTROL/removed"

# ── Case 6: a failed delivery leaves no stamp to clear ────────────────────
reset_control
sid=$(new_sid)
touch "$CONTROL/tn-fail"
fire_notification "$sid"
want "failed delivery is not stamped as delivered" file_gone "$SESS_DIR/$sid.notified"
rm -f "$CONTROL/tn-fail"

# ── Case 7: the hook leaves nothing running ───────────────────────────────
# The alerter backend used to leave a blocking process and a polling
# watcher behind for every notification. Nothing on this path may outlive
# the hook.
reset_control
sid=$(new_sid)
fire_notification "$sid"
sleep 0.5
LEFTOVER=$(pgrep -f 'ghostty-notify-clear' 2>/dev/null | wc -l | tr -d ' ')
check "$([[ "$LEFTOVER" == "0" ]] && echo 0 || echo 1)" "no watcher process is left behind"
want "no watcher pidfile is written" file_gone "$SESS_DIR/$sid.watch-pid"

echo
echo "Results: $pass passed, $fail failed"
if (( fail > 0 )); then
    echo "Failed: ${fail_list[*]}"
    exit 1
fi
exit 0
