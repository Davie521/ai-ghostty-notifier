#!/usr/bin/env bash
# Historical compatibility fixture; this is NOT native runtime coverage.
# Integration test for hooks/ghostty-notify-clear.sh (clear-on-focus).
#
# Covers the watcher's focus detection plus the shared-state invariants the
# feature depends on:
#   - exact-tab watch clears only when the session's tab is selected in the
#     frontmost window, app-level fallback needs a rising edge
#   - a transient lsappinfo failure must not arm that rising edge
#   - an older round's alerter concluding must not strand a newer round
#     (pidfile ownership), and watcher supersession must leave the
#     successor trackable
#   - the prompt-submit clear honors the opt-out and must not kill a
#     notification delivered after it was requested
#   - kills are session-scoped, config values fail back to their defaults,
#     and a failed notification spawns no watcher
#
# All external surfaces are stubbed: alerter (blocks like the real
# alert-style binary; records --remove), terminal-notifier (records
# -remove), lsappinfo (frontmost bundle from a control file), osascript
# (selected tab from a control file).

set -u
IFS=$'\n\t'

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
HOOK="$REPO/tests/fixtures/shell-baseline/hooks/ghostty-notify.sh"
CLEAR="$REPO/tests/fixtures/shell-baseline/hooks/ghostty-notify-clear.sh"
RESET="$REPO/tests/fixtures/shell-baseline/hooks/ghostty-round-reset.sh"

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
mkdir -p \
    "$HOME/.claude/hooks" \
    "$SESS_DIR" \
    "$HOME/.local/bin" \
    "$SANDBOX/bin" \
    "$CONTROL"

# Control files driving the stubs:
#   front-bundle   : bundle id lsappinfo reports as frontmost
#   selected-tab   : tab id osascript reports as selected in the front window
#   removed        : append-only log of group removals (alerter + tn)
#   fired          : append-only log of alerter invocations
#   alerter-sleep  : how long a fired alerter blocks (default 30s)
#   lsappinfo-fail : if present, lsappinfo exits non-zero
#   tn-fail        : if present, terminal-notifier exits non-zero

# alerter stub: --help advertises the GNU dialect (incl. --remove);
# --remove records the group; fire mode blocks like the real alert-style
# alerter so the pidfile lifecycle is realistic.
cat > "$HOME/.local/bin/alerter" <<SH
#!/bin/bash
if [[ "\${1:-}" == "--help" ]]; then
    echo "usage: --close-label --remove --group"
    exit 0
fi
if [[ "\${1:-}" == "--remove" ]]; then
    printf 'alerter:%s\n' "\$2" >> "$CONTROL/removed"
    exit 0
fi
printf 'fired\n' >> "$CONTROL/fired"
sleep "\$(cat "$CONTROL/alerter-sleep" 2>/dev/null || echo 30)"
SH
chmod +x "$HOME/.local/bin/alerter"
export GHOSTTY_NOTIFY_ALERTER="$HOME/.local/bin/alerter"

# terminal-notifier stub: records -remove, swallows everything else, and
# can be made to fail so the FIRED propagation is observable.
cat > "$SANDBOX/bin/terminal-notifier" <<SH
#!/bin/bash
if [[ "\${1:-}" == "-remove" ]]; then
    printf 'tn:%s\n' "\$2" >> "$CONTROL/removed"
    exit 0
fi
[[ -f "$CONTROL/tn-fail" ]] && exit 1
exit 0
SH
chmod +x "$SANDBOX/bin/terminal-notifier"

# lsappinfo stub: frontmost bundle comes from the control file; can fail.
# Every invocation is logged so the poll RATE is observable — that is what
# distinguishes a paced loop from a spin.
cat > "$SANDBOX/bin/lsappinfo" <<SH
#!/bin/bash
[[ -f "$CONTROL/lsappinfo-fail" ]] && exit 1
if [[ "\${1:-}" == "front" ]]; then
    printf 'x\n' >> "$CONTROL/lsappinfo-calls"
    echo "ASN:stub:"
    exit 0
fi
printf '"CFBundleIdentifier"="%s"\n' "\$(cat "$CONTROL/front-bundle" 2>/dev/null)"
SH
chmod +x "$SANDBOX/bin/lsappinfo"

# osascript stub: emulates the selected-tab query — "yes" iff the watcher's
# TARGET_TAB_ID matches the control file.
cat > "$SANDBOX/bin/osascript" <<SH
#!/bin/bash
sel=\$(cat "$CONTROL/selected-tab" 2>/dev/null)
if [[ -n "\${TARGET_TAB_ID:-}" && "\$TARGET_TAB_ID" == "\$sel" ]]; then
    echo yes
else
    echo no
fi
SH
chmod +x "$SANDBOX/bin/osascript"

# Focus stub, pinned so a stray dispatch can't run the real script.
cat > "$HOME/.claude/hooks/ghostty-tab-focus.sh" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$HOME/.claude/hooks/ghostty-tab-focus.sh"
export GHOSTTY_NOTIFY_FOCUS_SCRIPT="$HOME/.claude/hooks/ghostty-tab-focus.sh"

export TERM_PROGRAM=ghostty
export GHOSTTY_NOTIFY_MIN_ELAPSED=10
export GHOSTTY_NOTIFY_SOUND_ELAPSED=9999
export GHOSTTY_NOTIFY_TIMEOUT=20
export GHOSTTY_NOTIFY_BACKEND=auto
export GHOSTTY_NOTIFY_FOCUS_POLL=0.2
# This file is the regression guard for the SHELL clear-on-focus loop, so the
# resident agent must never intercept: it withdraws notifications from its own
# process and the loop under test here would never run. The empty value relies
# on agent_app using `${VAR-default}`, not `${VAR:-default}`.
export GHOSTTY_NOTIFY_AGENT_APP=""
unset GHOSTTY_RESOURCES_DIR || true
unset GHOSTTY_NOTIFY_CLEAR_ON_FOCUS || true
unset GHOSTTY_NOTIFY_CLEAR_SCRIPT || true

pass=0; fail=0
fail_list=()

ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); fail_list+=("$1"); }

check() {  # $1: 0/1 result, $2: label
    if [[ "$1" -eq 0 ]]; then ok "$2"; else bad "$2"; fi
}

want() {  # $1: label, $2...: predicate command that must succeed
    local label="$1"; shift
    if "$@"; then ok "$label"; else bad "$label"; fi
}

# Predicates (kept as commands so their status is unambiguous).
is_set()      { [[ -n "${1:-}" ]]; }
differs()     { [[ -n "${1:-}" && "$1" != "${2:-}" ]]; }
same()        { [[ "${1:-}" == "${2:-}" ]]; }
file_holds()  { [[ "$(cat "$1" 2>/dev/null)" == "$2" ]]; }
file_gone()   { [[ ! -f "$1" ]]; }
pid_alive()   { [[ "${1:-}" =~ ^[0-9]+$ ]] && kill -0 "$1" 2>/dev/null; }
pid_dead()    { [[ "${1:-}" =~ ^[0-9]+$ ]] && ! kill -0 "$1" 2>/dev/null; }

removed_has()    { grep -qF "alerter:ghostty-notify-$1" "$CONTROL/removed" 2>/dev/null; }
no_removal_for() { ! removed_has "$1"; }
pidfile_differs() { ! file_holds "$SESS_DIR/$1.alerter-pid" "$2"; }
watchfile_differs() { ! file_holds "$SESS_DIR/$1.watch-pid" "$2"; }

# Session ids must match the hooks' ^[a-fA-F0-9-]+$ guard.
new_sid() { printf 'ab%s-%s' "$(date +%s)" "$RANDOM"; }

fire_notification() {  # $1: sid, $2: optional event (default Stop)
    local sid="$1" ev="${2:-Stop}"
    echo $(( $(date +%s) - 60 )) > "$SESS_DIR/$sid.start"
    printf '{"session_id":"%s","cwd":"/tmp","hook_event_name":"%s"}' "$sid" "$ev" \
        | "$HOOK" >/dev/null 2>&1
}

wait_for() {  # $1: max tries (x100ms), $2...: condition command
    local tries="$1"; shift
    local i=0
    while (( i < tries )); do
        "$@" && return 0
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

# Await the alerter pidfile and echo the PID; empty if it never appears.
await_alerter_pid() {  # $1: sid
    wait_for 30 test -s "$SESS_DIR/$1.alerter-pid" || return 1
    cat "$SESS_DIR/$1.alerter-pid" 2>/dev/null
}

fire_count() { grep -c fired "$CONTROL/fired" 2>/dev/null || true; }

tidy_session() {  # kill leftovers without polluting the removal log
    local pid
    for pid in $(cat "$SESS_DIR/$1.watch-pid" "$SESS_DIR/$1.alerter-pid" 2>/dev/null); do
        [[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null
    done
    rm -f "$SESS_DIR/$1".{watch-pid,alerter-pid,json,start} 2>/dev/null
}

reset_control() {
    : > "$CONTROL/removed"
    : > "$CONTROL/fired"
    : > "$CONTROL/lsappinfo-calls"
    rm -f "$CONTROL/lsappinfo-fail" "$CONTROL/tn-fail" 2>/dev/null
    echo 30 > "$CONTROL/alerter-sleep"
}
reset_control

echo "== clear-on-focus tests =="

# ── Case 1: exact-tab watch clears when the session tab gains focus ────────
sid=$(new_sid)
printf '{"tab_id":"tab-42","cwd":"/tmp"}\n' > "$SESS_DIR/$sid.json"
echo "com.other.app" > "$CONTROL/front-bundle"
echo "tab-99"        > "$CONTROL/selected-tab"
fire_notification "$sid"

APID=$(await_alerter_pid "$sid")
want "alerter pidfile written on fire" is_set "$APID"

wait_for 20 test -f "$SESS_DIR/$sid.watch-pid"
check $? "watcher started on fire"
WPID=$(cat "$SESS_DIR/$sid.watch-pid" 2>/dev/null)

sleep 0.6
want "no clear while Ghostty is in background" no_removal_for "$sid"

echo "com.mitchellh.ghostty" > "$CONTROL/front-bundle"
sleep 0.6
want "no clear while a different tab is selected" no_removal_for "$sid"

echo "tab-42" > "$CONTROL/selected-tab"
wait_for 30 removed_has "$sid"
check $? "clears when the session tab becomes selected"
wait_for 20 pid_dead "$APID"
check $? "blocking alerter killed on clear"
wait_for 20 pid_dead "$WPID"
check $? "watcher exits after clearing"
tidy_session "$sid"
reset_control

# ── Case 2: app-level fallback needs a rising edge ─────────────────────────
sid=$(new_sid)   # no .json → tab unknown → fallback mode
echo "com.mitchellh.ghostty" > "$CONTROL/front-bundle"
echo ""                      > "$CONTROL/selected-tab"
fire_notification "$sid"
want "fallback: notification fired" is_set "$(await_alerter_pid "$sid")"
wait_for 20 test -f "$SESS_DIR/$sid.watch-pid"
check $? "fallback: watcher started"

sleep 0.8
want "fallback: already-frontmost Ghostty does not clear" no_removal_for "$sid"

# A transient lsappinfo failure is 'unknown', not 'the user left Ghostty'.
touch "$CONTROL/lsappinfo-fail"
sleep 0.8
rm -f "$CONTROL/lsappinfo-fail"
sleep 0.8
want "fallback: lsappinfo failure does not arm the edge" no_removal_for "$sid"

echo "com.other.app" > "$CONTROL/front-bundle"
sleep 0.6
echo "com.mitchellh.ghostty" > "$CONTROL/front-bundle"
wait_for 30 removed_has "$sid"
check $? "fallback: clears when Ghostty becomes frontmost again"
tidy_session "$sid"
reset_control

# ── Case 3: UserPromptSubmit clears immediately ────────────────────────────
sid=$(new_sid)
printf '{"tab_id":"tab-77","cwd":"/tmp"}\n' > "$SESS_DIR/$sid.json"
echo "com.other.app" > "$CONTROL/front-bundle"
echo "tab-1"         > "$CONTROL/selected-tab"
fire_notification "$sid"
APID=$(await_alerter_pid "$sid")
want "prompt submit: notification fired first" is_set "$APID"
wait_for 20 test -f "$SESS_DIR/$sid.watch-pid"
check $? "prompt submit: watcher running before submit"
WPID=$(cat "$SESS_DIR/$sid.watch-pid" 2>/dev/null)

printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit"}' "$sid" \
    | "$RESET" >/dev/null 2>&1

wait_for 30 removed_has "$sid"
check $? "prompt submit: notification group removed"
wait_for 20 pid_dead "$APID"
check $? "prompt submit: blocking alerter killed"
wait_for 20 pid_dead "$WPID"
check $? "prompt submit: watcher killed"
tidy_session "$sid"
reset_control

# ── Case 4: opt-out ────────────────────────────────────────────────────────
sid=$(new_sid)
export GHOSTTY_NOTIFY_CLEAR_ON_FOCUS=0
fire_notification "$sid"
APID=$(await_alerter_pid "$sid")
want "opt-out: notification still fires" is_set "$APID"
sleep 0.6
want "opt-out: no watcher spawned" file_gone "$SESS_DIR/$sid.watch-pid"

# The prompt-submit path is the same feature and must honor the same switch.
printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit"}' "$sid" \
    | "$RESET" >/dev/null 2>&1
sleep 0.6
want "opt-out: prompt submit does not clear" no_removal_for "$sid"
want "opt-out: blocking alerter survives" pid_alive "$APID"
unset GHOSTTY_NOTIFY_CLEAR_ON_FOCUS
tidy_session "$sid"
reset_control

# An unrecognized value must fall back to the documented default (enabled),
# not silently disable the feature.
sid=$(new_sid)
export GHOSTTY_NOTIFY_CLEAR_ON_FOCUS=true
fire_notification "$sid"
await_alerter_pid "$sid" >/dev/null
wait_for 20 test -f "$SESS_DIR/$sid.watch-pid"
check $? "CLEAR_ON_FOCUS=true still enables the watcher"
unset GHOSTTY_NOTIFY_CLEAR_ON_FOCUS
tidy_session "$sid"
reset_control

# ── Case 5: pidfile ownership across overlapping rounds ────────────────────
# An older alerter concluding must not delete the pidfile a newer round
# wrote, or the newer alert loses its watcher and can never be cleared.
sid=$(new_sid)
printf '{"tab_id":"tab-55","cwd":"/tmp"}\n' > "$SESS_DIR/$sid.json"
echo "com.other.app" > "$CONTROL/front-bundle"
echo "tab-1"         > "$CONTROL/selected-tab"
echo 2 > "$CONTROL/alerter-sleep"          # round 1 alerter concludes fast
export GHOSTTY_NOTIFY_ON_PROMPT=1
fire_notification "$sid" "Notification"
APID_A=$(await_alerter_pid "$sid")
want "overlap: first round fired" is_set "$APID_A"

echo 30 > "$CONTROL/alerter-sleep"         # round 2 alerter keeps blocking
fire_notification "$sid" "Stop"
wait_for 40 pidfile_differs "$sid" "$APID_A"
APID_B=$(cat "$SESS_DIR/$sid.alerter-pid" 2>/dev/null)
want "overlap: second round claimed the pidfile" differs "$APID_B" "$APID_A"

wait_for 40 pid_dead "$APID_A"
check $? "overlap: first alerter concluded"
sleep 0.5
want "overlap: concluded alerter left the newer pidfile intact" \
    file_holds "$SESS_DIR/$sid.alerter-pid" "$APID_B"

# The newer round's watcher is still live and still able to clear.
echo "com.mitchellh.ghostty" > "$CONTROL/front-bundle"
echo "tab-55"                > "$CONTROL/selected-tab"
wait_for 40 removed_has "$sid"
check $? "overlap: newer round still clears on focus"
unset GHOSTTY_NOTIFY_ON_PROMPT
tidy_session "$sid"
reset_control

# ── Case 6: watcher supersession leaves the successor trackable ────────────
sid=$(new_sid)
printf '{"tab_id":"tab-66","cwd":"/tmp"}\n' > "$SESS_DIR/$sid.json"
echo "com.other.app" > "$CONTROL/front-bundle"
echo "tab-1"         > "$CONTROL/selected-tab"
export GHOSTTY_NOTIFY_ON_PROMPT=1
fire_notification "$sid" "Notification"
await_alerter_pid "$sid" >/dev/null
wait_for 20 test -f "$SESS_DIR/$sid.watch-pid"
W1=$(cat "$SESS_DIR/$sid.watch-pid" 2>/dev/null)
want "supersession: first watcher running" pid_alive "$W1"

fire_notification "$sid" "Stop"
wait_for 40 watchfile_differs "$sid" "$W1"
W2=$(cat "$SESS_DIR/$sid.watch-pid" 2>/dev/null)
want "supersession: successor claimed the slot" differs "$W2" "$W1"
wait_for 30 pid_dead "$W1"
check $? "supersession: predecessor killed"
sleep 0.5
want "supersession: successor still tracked after predecessor exits" \
    file_holds "$SESS_DIR/$sid.watch-pid" "$W2"
unset GHOSTTY_NOTIFY_ON_PROMPT
tidy_session "$sid"
reset_control

# Repeated hand-offs, driven straight at the watcher so the hook's rate
# limit doesn't cap the sample. A predecessor that cleans up its own pidfile
# on the way out races the successor that already claimed it, and the loser
# runs untracked — one lost round out of several is enough to catch it.
sid=$(new_sid)
printf '{"tab_id":"tab-never","cwd":"/tmp"}\n' > "$SESS_DIR/$sid.json"
echo "com.other.app" > "$CONTROL/front-bundle"
echo "tab-1"         > "$CONTROL/selected-tab"
race_lost=0
LAST=""
for _ in 1 2 3 4 5 6 7 8; do
    "$CLEAR" --watch "$sid" </dev/null >/dev/null 2>&1 &
    LAST=$!
    sleep 0.25
    file_holds "$SESS_DIR/$sid.watch-pid" "$LAST" || { race_lost=1; break; }
done
want "rapid supersession always leaves the survivor tracked" \
    same "$race_lost" 0
want "rapid supersession: survivor still alive" pid_alive "$LAST"
[[ "$LAST" =~ ^[0-9]+$ ]] && kill "$LAST" 2>/dev/null
tidy_session "$sid"
reset_control

# ── Case 7: prompt-submit clear must not kill a newer notification ─────────
sid=$(new_sid)
fire_notification "$sid"
APID=$(await_alerter_pid "$sid")
want "clear-before: notification fired" is_set "$APID"
GHOSTTY_NOTIFY_CLEAR_BEFORE=$(( $(date +%s) - 60 )) "$CLEAR" "$sid" >/dev/null 2>&1
sleep 0.4
want "clear-before: alert newer than the request survives" no_removal_for "$sid"
want "clear-before: its alerter survives" pid_alive "$APID"
"$CLEAR" "$sid" >/dev/null 2>&1          # unbounded clear still works
wait_for 20 removed_has "$sid"
check $? "clear-before: unbounded clear still removes it"
tidy_session "$sid"
reset_control

# ── Case 8: kills are session-scoped ───────────────────────────────────────
# A stale pidfile pointing at another session's alerter must not kill it.
sid_a=$(new_sid)
sid_b=$(new_sid)
fire_notification "$sid_b"
APID_B=$(await_alerter_pid "$sid_b")
want "cross-session: victim session fired" is_set "$APID_B"
printf '%s\n' "$APID_B" > "$SESS_DIR/$sid_a.alerter-pid"   # stale/reused PID
"$CLEAR" "$sid_a" >/dev/null 2>&1
sleep 0.4
want "cross-session: other session's alerter not killed" pid_alive "$APID_B"
tidy_session "$sid_a"
tidy_session "$sid_b"
reset_control

# ── Case 9: a failed notification spawns no watcher ────────────────────────
sid=$(new_sid)
touch "$CONTROL/tn-fail"
GHOSTTY_NOTIFY_BACKEND=terminal-notifier fire_notification "$sid"
sleep 0.5
want "failed notification: no watcher spawned" file_gone "$SESS_DIR/$sid.watch-pid"
rm -f "$CONTROL/tn-fail"
tidy_session "$sid"
reset_control

# ── Case 10: FOCUS_POLL=0 must not become a busy loop ──────────────────────
sid=$(new_sid)
printf '{"tab_id":"tab-88","cwd":"/tmp"}\n' > "$SESS_DIR/$sid.json"
echo "com.other.app" > "$CONTROL/front-bundle"
echo "tab-1"         > "$CONTROL/selected-tab"
GHOSTTY_NOTIFY_FOCUS_POLL=0 fire_notification "$sid"
await_alerter_pid "$sid" >/dev/null
wait_for 20 test -f "$SESS_DIR/$sid.watch-pid"
check $? "FOCUS_POLL=0: watcher started"
# Count polls over a fixed window rather than reading %cpu: the loop spends
# most of its time blocked in fork/wait, so a spin barely registers as CPU
# on the parent while still hammering the system dozens of times a second.
: > "$CONTROL/lsappinfo-calls"
sleep 1.5
POLLS=$(grep -c x "$CONTROL/lsappinfo-calls" 2>/dev/null || true)
[[ "$POLLS" =~ ^[0-9]+$ ]] || POLLS=0
check "$(( POLLS > 0 && POLLS < 40 ? 0 : 1 ))" \
    "FOCUS_POLL=0 falls back to a paced poll (${POLLS} polls/1.5s)"
tidy_session "$sid"
reset_control

# ── Case 11: bogus session ids are rejected before touching state ──────────
# "../../evil" escapes SESS_DIR to $HOME/.claude/evil.*. The elapsed gate
# must not be what stops it: plant the start marker the hook would read, so
# a hook without the shape guard really would fire and write a pidfile
# outside the session directory.
BOGUS_START="$HOME/.claude/evil.start"
BOGUS_PID="$HOME/.claude/evil.alerter-pid"
rm -f "$BOGUS_PID"
echo $(( $(date +%s) - 60 )) > "$BOGUS_START"
BEFORE=$(fire_count)
printf '{"session_id":"../../evil","cwd":"/tmp","hook_event_name":"Stop"}' \
    | "$HOOK" >/dev/null 2>&1
sleep 0.3
AFTER=$(fire_count)
want "path-traversal session id fires nothing" same "$BEFORE" "$AFTER"
want "path-traversal session id writes no pidfile" file_gone "$BOGUS_PID"
rm -f "$BOGUS_START"

echo
echo "Results: $pass passed, $fail failed"
if (( fail > 0 )); then
    echo "Failed cases: ${fail_list[*]}"
    exit 1
fi
exit 0
