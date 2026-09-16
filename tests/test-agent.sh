#!/usr/bin/env bash
# Integration test for the resident notification agent.
#
# Drives the REAL binary through the REAL spool transport, using the same
# hooks/agent-common.sh helpers the hooks use, and asserts against the agent's
# own state file and log.
#
# What this deliberately does NOT assert: that a banner appeared. Notification
# delivery needs an authorization grant that only a human can give, so a test
# that depended on it would be unrunnable in CI. The rules that decide WHICH
# notification to withdraw are covered by the NotifyCore suites
# (`swift test --package-path agent`); what is left for a human is the manual
# smoke test — switch away, switch back, watch the banner go.
#
# Anti-false-green: a missing binary is FATAL, not a skip; the agent must prove
# it started (pidfile + log line) before any other assertion runs; and every
# assertion names the exact string it expects rather than "non-empty".

set -u
IFS=$'\n\t'

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
APP="${GHOSTTY_NOTIFY_AGENT_APP:-$REPO/build/ClaudeGhosttyNotify.app}"
BIN="$APP/Contents/MacOS/ghostty-notify-agent"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }

# A skipped run must never look like a passing one. The agent is an AppKit app;
# without an Aqua session NSApplication cannot come up at all.
if [[ "$(launchctl managername 2>/dev/null)" != "Aqua" ]]; then
    echo "SKIP: no Aqua session — the agent needs a window server."
    echo "      NotifyCore unit tests remain the gate in this environment."
    exit 0
fi

if [[ ! -x "$BIN" ]]; then
    echo "FATAL: $BIN missing. Build it first:" >&2
    echo "  bash scripts/build-agent.sh" >&2
    exit 2
fi

SANDBOX=$(mktemp -d)
AGENT_PID=""
cleanup() {
    # Withdraw what this run posted BEFORE stopping the agent. Notification
    # Center is scoped to the bundle identifier, not to HOME — so a sandboxed
    # HOME does not stop these notifications from landing in the real user's
    # Notification Center and sitting there afterwards. Observed for real: a
    # previous run's synthetic session ids turned up in a later click.
    # Defensive: the trap is installed before the session ids and the helpers
    # exist, and an early failure must not turn into an unbound-variable error
    # inside cleanup.
    if [[ -n "$AGENT_PID" ]] && kill -0 "$AGENT_PID" 2>/dev/null &&
        command -v agent_queue >/dev/null 2>&1; then
        for sid in "${SID:-}" "${OTHER:-}"; do
            [[ -n "$sid" ]] || continue
            agent_queue "$(jq -nc --arg s "$sid" '{type:"dismiss",session_id:$s}')" "$APP" \
                2>/dev/null || true
        done
        # Give the watcher a moment to drain before the process goes away.
        sleep 1
        kill "$AGENT_PID" 2>/dev/null
        # And wait for it to actually exit. SIGTERM is handled: the agent saves
        # state and removes its liveness markers on the way out, which refills
        # the sandbox between readdir and rmdir if we delete it too early —
        # observed as an intermittent "rm: Directory not empty".
        local i=0
        while (( i < 50 )) && kill -0 "$AGENT_PID" 2>/dev/null; do
            sleep 0.1
            i=$((i + 1))
        done
    fi
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

export HOME="$SANDBOX"
ROOT="$HOME/.claude/notifications/ghostty-agent"
STATE="$ROOT/state.json"
LOG="$ROOT/agent.log"

# The helpers under test. They read HOME, so source after exporting it.
# shellcheck source=hooks/agent-common.sh
source "$REPO/hooks/agent-common.sh"

pass=0; fail=0
fail_list=()

check() {
    local label="$1"; shift
    if "$@"; then
        printf '  \033[32mPASS\033[0m  %s\n' "$label"
        pass=$((pass + 1))
    else
        printf '  \033[31mFAIL\033[0m  %s\n' "$label"
        fail=$((fail + 1))
        fail_list+=("$label")
    fi
}

# wait_for <seconds> <command...> — poll until the predicate holds.
wait_for() {
    local limit="$1"; shift
    local i=0
    while (( i < limit * 10 )); do
        "$@" && return 0
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

# Negative assertions go through a predicate function: `check` invokes "$@"
# directly, which cannot carry a `!` or a subshell.
rejects() { ! "$@"; }
stale_app_is_rejected() {
    ( export GHOSTTY_NOTIFY_AGENT_APP="$SANDBOX/gone.app"
      agent_app "$REPO/hooks" >/dev/null )
}

log_has() { grep -qF "$1" "$LOG" 2>/dev/null; }
state_outstanding() {
    # Prints the outstanding notification ids for a session, comma-joined.
    jq -r --arg s "$1" '(.sessions[$s].notificationIDs // []) | join(",")' \
        "$STATE" 2>/dev/null
}
# Predicates, not values. `wait_for 10 test "$(f)" = x` expands f ONCE,
# before wait_for runs, and then spends ten seconds comparing two constants
# — so a state file written a moment later is never seen and the assertion
# fails with no sign of why. Observed on CI as an intermittent failure of
# "the identifier is still stable after a restart".
state_outstanding_is() {  # <session> <expected>
    [[ "$(state_outstanding "$1")" == "$2" ]]
}
pongs_above() {  # <count>
    local now
    now=$(grep -cF pong "$LOG" 2>/dev/null || echo 0)
    (( now > $1 ))
}
spool_drained() {
    local remaining
    remaining=$(find "$ROOT/spool" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
    [[ "$remaining" == "0" ]]
}

echo "== resident agent integration test =="

SID="deadbeef-1111-2222-3333-444455556666"
OTHER="deadbeef-9999"

# ── 1. The agent starts and claims its pidfile ─────────────────────────────
"$BIN" >/dev/null 2>&1 &
AGENT_PID=$!
check "agent starts and writes a pidfile" \
    wait_for 15 test -f "$ROOT/agent.pid"
check "agent logs its bundle identity (proves it is bundled, not a bare binary)" \
    wait_for 15 log_has "bundle=io.github.davie521.cgnotify"

# Everything below is meaningless if the agent is not actually draining, so
# establish that first with a request whose only effect is a log line.
agent_queue '{"type":"ping"}' "$APP"
check "spool transport delivers (ping answered)" wait_for 10 log_has "pong"
check "consumed request files are removed" wait_for 10 spool_drained

# ── 2. Readiness is published, and gates delivery ──────────────────────────
# The severest defect this file guards: a spool write is NOT a delivered
# notification. Unless the agent says it is authorized, agent_deliver has to
# fail so ghostty-notify.sh falls back to terminal-notifier instead of
# silently swallowing the notification.
# Whether the agent gets an ANSWER is environmental, not a property of the code:
# the prompt needs a human, and on a CI runner nobody can click it, so the
# completion handler never fires. Reported, never asserted — a machine that
# cannot answer must not fail the build, and a green tick here would have meant
# nothing anyway.
if wait_for 10 test -s "$ROOT/ready"; then
    printf '  \033[36mINFO\033[0m  agent published its authorization answer: %s\n' \
        "$(cat "$ROOT/ready")"
else
    printf '  \033[36mINFO\033[0m  no authorization answer (nobody here can answer the prompt)\n'
fi

# The contract that IS testable: whatever the answer, the gate governs delivery.
printf 'denied\n' > "$ROOT/ready"
check "agent_deliver refuses when notifications are not authorized" \
    rejects agent_deliver '{"type":"ping"}' "$APP"
printf 'authorized\n' > "$ROOT/ready"
check "agent_deliver accepts once authorized" \
    agent_deliver '{"type":"ping"}' "$APP"
# A stale bundle path must not be trusted either — routing into a spool nothing
# drains is the same silent-drop failure by another route.
check "a non-existent GHOSTTY_NOTIFY_AGENT_APP is rejected" \
    rejects stale_app_is_rejected
# An empty payload means the caller's jq failed; queuing it would look like a
# delivered notification to the caller and an undecodable file to the agent.
check "an empty payload is refused rather than queued" \
    rejects agent_deliver "" "$APP"

# ── 3. notify records a stable identifier ──────────────────────────────────
agent_queue "$(jq -nc --arg s "$SID" \
    '{type:"notify",session_id:$s,title:"Claude ✅",subtitle:"sub",body:"done",sound:"Glass"}')" \
    "$APP"
check "notify posts and records claude-<session>" \
    wait_for 10 log_has "posted claude-$SID"
check "state.json lists the identifier as outstanding" \
    wait_for 10 state_outstanding_is "$SID" "claude-$SID"

# Posting again must reuse the identifier: that is what makes the notification
# center REPLACE the banner instead of stacking a second one, which is the
# behaviour `-group ghostty-notify-<session>` gave both shell backends.
agent_queue "$(jq -nc --arg s "$SID" '{type:"notify",session_id:$s,title:"again"}')" "$APP"
check "a repeat notification replaces rather than stacks" \
    wait_for 10 state_outstanding_is "$SID" "claude-$SID"

# ── 4. A second session's notification is tracked separately ───────────────
agent_queue "$(jq -nc --arg s "$OTHER" '{type:"notify",session_id:$s,title:"other"}')" "$APP"
check "a second session gets its own identifier" \
    wait_for 10 state_outstanding_is "$OTHER" "claude-$OTHER"

# ── 5. dismiss withdraws only the session it names ─────────────────────────
agent_queue "$(jq -nc --arg s "$SID" '{type:"dismiss",session_id:$s}')" "$APP"
check "dismiss withdraws the named session's notification" \
    wait_for 10 log_has "withdrew claude-$SID"
check "dismissed session has nothing outstanding" \
    wait_for 10 state_outstanding_is "$SID" ""
# The bug this guards: a dismiss that clears every session would silently
# destroy a sibling session's still-unread notification.
check "the other session's notification survives" \
    test "$(state_outstanding "$OTHER")" = "claude-$OTHER"

# ── 6. anchor prefers the id the hook supplies ─────────────────────────────
# Sampling the focused tab at drain time anchors a session to whatever tab the
# user happens to be on by then, so a hook-supplied id must win outright.
agent_queue "$(jq -nc --arg s "$SID" \
    '{type:"anchor",session_id:$s,tab_id:"BEEF-TAB"}')" "$APP"
check "a hook-supplied tab id is recorded verbatim" \
    wait_for 10 log_has "anchored $SID -> BEEF-TAB"
check "state.json records the tab" \
    test "$(jq -r --arg s "$SID" '.sessions[$s].tabID // ""' "$STATE")" = "BEEF-TAB"

# ── 7. Garbage does not wedge the drain ────────────────────────────────────
# A poison file is unlinked before it is decoded, so it must be dropped once and
# never retried — and the next good request must still be served.
PONGS_BEFORE=$(grep -cF pong "$LOG")
agent_queue 'not json at all' "$APP"
agent_queue "$(jq -nc --arg s "../escape" '{type:"notify",session_id:$s,title:"evil"}')" "$APP"
agent_queue '{"type":"selfDestruct"}' "$APP"
check "malformed requests are dropped, not retried" wait_for 10 spool_drained
agent_queue '{"type":"ping"}' "$APP"
check "the agent still serves requests after garbage" \
    wait_for 10 pongs_above "$PONGS_BEFORE"
# A rejected session id must not have created a record.
check "an invalid session id creates no state" \
    test "$(jq -r '.sessions | has("../escape")' "$STATE" 2>/dev/null)" = "false"

# ── 8. A queued notify that went stale is not replayed ─────────────────────
# Otherwise an agent that was down all evening posts the whole backlog at once
# on the next login — banners for rounds that finished hours ago. Backdating the
# file is exactly what a long outage looks like to the agent.
#
# Build and backdate it OUTSIDE the spool, then rename it in: creating it in
# place would let the watcher consume it as a fresh request before `touch` ran.
# rename(2) does not alter mtime, which is what the agent sorts and ages on.
STALE="$SANDBOX/stale.json"
jq -nc --arg s "$OTHER" '{type:"notify",session_id:$s,title:"ancient"}' > "$STALE"
touch -t 200001010000 "$STALE"
mv "$STALE" "$ROOT/spool/0000000000000001-stale.json"
check "a stale notify is dropped, not replayed" wait_for 10 log_has "dropped stale notify"

# ── 9. State survives a restart, keeping the identifier stable ──────────────
kill "$AGENT_PID" 2>/dev/null
wait "$AGENT_PID" 2>/dev/null || true
AGENT_PID=""
"$BIN" >/dev/null 2>&1 &
AGENT_PID=$!
check "restarted agent reloads its sessions" wait_for 15 log_has "restored "
# No assertion that readiness is republished: this file was written by hand
# above, so it exists no matter what the restarted agent does — the check that
# used to be here could never fail.
printf 'authorized\n' > "$ROOT/ready"
agent_queue "$(jq -nc --arg s "$SID" '{type:"notify",session_id:$s,title:"after restart"}')" "$APP"
# A changed identifier here would post a SECOND banner beside one that may still
# be on screen from before the restart, instead of replacing it.
check "the identifier is still stable after a restart" \
    wait_for 10 state_outstanding_is "$SID" "claude-$SID"
check "the tab resolved before the restart survived it" \
    test "$(jq -r --arg s "$SID" '.sessions[$s].tabID // ""' "$STATE")" = "BEEF-TAB"

echo
echo "Results: $pass passed, $fail failed"
if (( fail > 0 )); then
    echo "Failed: ${fail_list[*]}"
    # A failure here happens inside a process nobody can see; on a CI runner
    # the sandbox is deleted on exit. Leave the agent's own account behind.
    echo
    echo "── agent.log (last 40 lines) ──"
    tail -n 40 "$LOG" 2>/dev/null
    echo "── spool ──"
    ls -la "$ROOT/spool" 2>/dev/null
    echo "── pidfile / ready ──"
    echo "pid=$(cat "$ROOT/agent.pid" 2>/dev/null) ready=$(cat "$ROOT/ready" 2>/dev/null)"
    echo "── agent processes ──"
    ps -axo pid,ppid,lstart,command | grep '[g]hostty-notify-agent'
    exit 1
fi
exit 0
