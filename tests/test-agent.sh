#!/usr/bin/env bash
# Integration test for the resident notification agent.
#
# Drives the REAL binary through the REAL spool transport and native hook
# launchers, asserting against the agent's own state file and log.
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

# `check`, `wait_for` and the EXIT trap invoke their function arguments.
# shellcheck disable=SC2329
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
    echo "  bash scripts/build-agent.sh --build-only" >&2
    exit 2
fi

SANDBOX=$(mktemp -d)
AGENT_PID=""
stop_agent() {
    [[ -n "$AGENT_PID" ]] || return 0
    local pid="$AGENT_PID" i=0 result=0
    kill "$pid" 2>/dev/null || true
    while (( i < 100 )) && kill -0 "$pid" 2>/dev/null; do
        sleep 0.1
        i=$((i + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        echo "Agent failed to exit within 10 seconds; stopping owned test PID $pid" >&2
        kill -KILL "$pid" 2>/dev/null || true
        result=1
    fi
    wait "$pid" 2>/dev/null || result=1
    AGENT_PID=""
    return "$result"
}

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
        for sid in "${SID:-}" "${OTHER:-}" "${NATIVE_SID:-}"; do
            [[ -n "$sid" ]] || continue
            agent_queue "$(jq -nc --arg s "$sid" '{type:"dismiss",session_id:$s}')" \
                2>/dev/null || true
        done
        if [[ -n "${NATIVE_SID:-}" ]]; then
            agent_queue "$(jq -nc --arg s "$NATIVE_SID" '{type:"dismiss",session_id:$s,source:"codex"}')" \
                2>/dev/null || true
        fi
        # Give the watcher a moment to drain before the process goes away.
        sleep 1
    fi
    # Reap even a hung test app before deleting its private state directory.
    stop_agent || echo "Test cleanup required a forced agent exit" >&2
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

export HOME="$SANDBOX"
ROOT="$HOME/.claude/notifications/ghostty-agent"
STATE="$ROOT/state.json"
LOG="$ROOT/agent.log"
mkdir -p "$ROOT"
printf 'shown\n' > "$ROOT/style-hint-shown"
export GHOSTTY_NOTIFY_MENU_BAR=0

# One request into the spool, through the binary's own sender. It reads HOME,
# so this works on the sandbox and never on the user's agent.
agent_queue() { "$BIN" --send "$1"; }

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


log_has() { grep -qF "$1" "$LOG" 2>/dev/null; }
state_outstanding() {
    # Prints the outstanding notification ids for a session, comma-joined.
    jq -r --arg s "$1" '(.sessions[$s].notificationIDs // []) | join(",")' \
        "$STATE" 2>/dev/null
}
state_is() { [[ "$(state_outstanding "$1")" == "$2" ]]; }
pongs_increased() { [[ "$(grep -cF pong "$LOG")" -gt "$1" ]]; }
spool_drained() {
    local remaining
    remaining=$(find "$ROOT/spool" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
    [[ "$remaining" == "0" ]]
}

echo "== resident agent integration test =="

SID="deadbeef-1111-2222-3333-444455556666"
OTHER="deadbeef-9999"
NATIVE_SID="deadbeef-2222-3333"

# ── 1. The agent starts and claims its pidfile ─────────────────────────────
"$BIN" >/dev/null 2>&1 &
AGENT_PID=$!
check "agent starts and writes a pidfile" \
    wait_for 15 test -f "$ROOT/agent.pid"
check "agent logs its bundle identity (proves it is bundled, not a bare binary)" \
    wait_for 15 log_has "bundle=io.github.davie521.cgnotify"

# Everything below is meaningless if the agent is not actually draining, so
# establish that first with a request whose only effect is a log line.
agent_queue '{"type":"ping"}'
check "spool transport delivers (ping answered)" wait_for 10 log_has "pong"
check "consumed request files are removed" wait_for 10 spool_drained

# ── 2. Readiness is published ───────────────────────────────────────────────
# Whether the agent gets an ANSWER is environmental, not a property of the code:
# the prompt needs a human, and on a CI runner nobody can click it, so the
# completion handler never fires. Reported, never asserted. That the answer
# gates delivery is a NotifyCore test (HookTransport), where the hooks decide.
if wait_for 10 test -s "$ROOT/ready"; then
    printf '  \033[36mINFO\033[0m  agent published its authorization answer: %s\n' \
        "$(cat "$ROOT/ready")"
else
    printf '  \033[36mINFO\033[0m  no authorization answer (nobody here can answer the prompt)\n'
fi
printf 'authorized\n' > "$ROOT/ready"

# ── 3. notify records a stable identifier ──────────────────────────────────
agent_queue "$(jq -nc --arg s "$SID" \
    '{type:"notify",session_id:$s,title:"Claude ✅",subtitle:"sub",body:"done",sound:"Glass"}')"
check "notify posts and records claude-<session>" \
    wait_for 10 log_has "posted claude-$SID"
check "state.json lists the identifier as outstanding" \
    wait_for 10 state_is "$SID" "claude-$SID"

# Posting again must reuse the identifier: that is what makes the notification
# center REPLACE the banner instead of stacking a second one, which is the
# behaviour `-group ghostty-notify-<session>` gave both shell backends.
agent_queue "$(jq -nc --arg s "$SID" '{type:"notify",session_id:$s,title:"again"}')"
check "a repeat notification replaces rather than stacks" \
    wait_for 10 state_is "$SID" "claude-$SID"

# ── 4. A second session's notification is tracked separately ───────────────
agent_queue "$(jq -nc --arg s "$OTHER" '{type:"notify",session_id:$s,title:"other"}')"
check "a second session gets its own identifier" \
    wait_for 10 state_is "$OTHER" "claude-$OTHER"

# ── 5. dismiss withdraws only the session it names ─────────────────────────
agent_queue "$(jq -nc --arg s "$SID" '{type:"dismiss",session_id:$s}')"
check "dismiss withdraws the named session's notification" \
    wait_for 10 log_has "withdrew claude-$SID"
check "dismissed session has nothing outstanding" \
    wait_for 10 state_is "$SID" ""
# The bug this guards: a dismiss that clears every session would silently
# destroy a sibling session's still-unread notification.
check "the other session's notification survives" \
    test "$(state_outstanding "$OTHER")" = "claude-$OTHER"

# ── 6. anchor prefers the id the hook supplies ─────────────────────────────
# Sampling the focused tab at drain time anchors a session to whatever tab the
# user happens to be on by then, so a hook-supplied id must win outright.
agent_queue "$(jq -nc --arg s "$SID" \
    '{type:"anchor",session_id:$s,tab_id:"BEEF-TAB"}')"
check "a hook-supplied tab id is recorded verbatim" \
    wait_for 10 log_has "anchored $SID -> BEEF-TAB"
check "state.json records the tab" \
    test "$(jq -r --arg s "$SID" '.sessions[$s].tabID // ""' "$STATE")" = "BEEF-TAB"

# ── 7. Garbage does not wedge the drain ────────────────────────────────────
# A poison file is unlinked before it is decoded, so it must be dropped once and
# never retried — and the next good request must still be served.
PONGS_BEFORE=$(grep -cF pong "$LOG")
agent_queue 'not json at all'
agent_queue "$(jq -nc --arg s "../escape" '{type:"notify",session_id:$s,title:"evil"}')"
agent_queue '{"type":"selfDestruct"}'
check "malformed requests are dropped, not retried" wait_for 10 spool_drained
agent_queue '{"type":"ping"}'
check "the agent still serves requests after garbage" \
    wait_for 10 pongs_increased "$PONGS_BEFORE"
# A rejected session id must not have created a record.
check "an invalid session id creates no state" \
    test "$(jq -r '.sessions | has("../escape")' "$STATE" 2>/dev/null)" = "false"

# ── 8. Native hook policy and lifecycle ───────────────────────────────────
native_notice_is() {
    [[ "$(jq -r --arg s "$NATIVE_SID" '.sessions[$s].subtitle // ""' "$STATE" 2>/dev/null)" == "$1" ]]
}
native_clear() { [[ -z "$(state_outstanding "$NATIVE_SID")" ]]; }
native_policy() {
    TERM_PROGRAM=ghostty GHOSTTY_NOTIFY_AGENT_APP="$APP" \
        GHOSTTY_NOTIFY_TTY=/not-a-live-terminal-fixture \
        GHOSTTY_NOTIFY_BACKEND=auto GHOSTTY_NOTIFY_CLEAR_ON_FOCUS="$1" \
        GHOSTTY_NOTIFY_MIN_ELAPSED=10 GHOSTTY_NOTIFY_SOUND_ELAPSED=999999 \
        /bin/bash "$REPO/hooks/$2"
}
SESSIONS="$HOME/.claude/notifications/ghostty-sessions"
mkdir -p "$SESSIONS"
printf '%s\n' "$(( $(date +%s) - 30 ))" > "$SESSIONS/$NATIVE_SID.start"
jq -nc --arg s "$NATIVE_SID" \
    '{session_id:$s,hook_event_name:"Stop",cwd:"/work/migration",session_title:"native pipeline"}' \
    | native_policy 0 ghostty-notify.sh
check "real hook event passes through Swift policy and delivery" \
    wait_for 10 native_notice_is "native pipeline — migration"
check "native completion consumes its start marker" \
    wait_for 10 test ! -f "$SESSIONS/$NATIVE_SID.start"
check "native delivery spawns no shell watcher" test ! -f "$SESSIONS/$NATIVE_SID.watch-pid"

jq -nc --arg s "$NATIVE_SID" '{session_id:$s,hook_event_name:"UserPromptSubmit"}' \
    | native_policy 0 ghostty-round-reset.sh
check "prompt opt-out is processed by the native lifecycle" \
    wait_for 10 log_has "handled UserPromptSubmit $NATIVE_SID round=$(cat "$SESSIONS/$NATIVE_SID.round")"
check "opt-out retained notification text" native_notice_is "native pipeline — migration"
jq -nc --arg s "$NATIVE_SID" '{session_id:$s,hook_event_name:"UserPromptSubmit"}' \
    | native_policy 1 ghostty-round-reset.sh
check "next prompt withdraws through the new native event" wait_for 10 native_clear

# Drive the Codex entry with a real native CLI parent and a private PTY. Each
# invocation deliberately uses a new owner, exercising resume invalidation.
# The TTY override prevents Apple Events or OSC writes to any live tab.
mkdir -p "$SANDBOX/bin" "$SANDBOX/codex-sessions"
/usr/bin/clang "$REPO/tests/fixtures/native-host.c" -o "$SANDBOX/codex" || exit 2
GHOSTTY_PID=$(lsappinfo info -only pid com.mitchellh.ghostty 2>/dev/null | tr -dc '0-9')
jq -nc --arg pid "$GHOSTTY_PID" '{tab_id:"native-codex-tab",ghostty_pid:$pid}' \
    > "$SANDBOX/codex-sessions/$NATIVE_SID.json"
codex_policy() {
    PATH="$SANDBOX/bin:$PATH" TERM_PROGRAM=ghostty GHOSTTY_NOTIFY_AGENT_APP="$APP" \
        GHOSTTY_NOTIFY_BACKEND="${2:-auto}" GHOSTTY_NOTIFY_CLEAR_ON_FOCUS="${3:-0}" \
        GHOSTTY_NOTIFY_MIN_ELAPSED=10 GHOSTTY_NOTIFY_SOUND_ELAPSED=999999 \
        GHOSTTY_NOTIFY_CODEX_SETTLE=0 GHOSTTY_NOTIFY_SESSION_DIR="$SANDBOX/codex-sessions" \
        GHOSTTY_NOTIFY_TTY=/not-a-live-terminal-fixture \
        GHOSTTY_NOTIFY_RATE_DIR="$SANDBOX/codex-rates" CODEX_HOME="$SANDBOX/codex-home" \
        "$SANDBOX/codex" /bin/bash "$REPO/hooks/codex-hook.sh" "$1"
}
codex_title_ready() { [[ "$(cat "$SANDBOX/codex-sessions/$NATIVE_SID.title" 2>/dev/null)" == "Codex native title" ]]; }
codex_notice_ready() {
    [[ "$(jq -r --arg s "codex-$NATIVE_SID" '.sessions[$s].subtitle // ""' "$STATE" 2>/dev/null)" == "Codex native title — codex-fixture" ]]
}
jq -nc --arg s "$NATIVE_SID" '{session_id:$s,hook_event_name:"UserPromptSubmit",prompt:"Codex native title",cwd:"/work/codex-fixture"}' \
    | codex_policy UserPromptSubmit
check "Codex prompt title is stored by the real Swift processor" wait_for 10 codex_title_ready
printf '%s\n' "$(( $(date +%s) - 30 ))" > "$SANDBOX/codex-sessions/$NATIVE_SID.start"
jq -nc --arg s "$NATIVE_SID" '{session_id:$s,hook_event_name:"Stop",cwd:"/work/codex-fixture"}' \
    | codex_policy Stop
check "Codex native completion reaches the resident notifier" wait_for 10 codex_notice_ready
check "Codex and Claude with the same UUID have separate records" \
    test "$(state_outstanding "codex-$NATIVE_SID")" = "codex-$NATIVE_SID"
check "Codex completion did not revive the Claude notification" native_clear
check "Codex native completion removes the shared timer" \
    wait_for 10 test ! -f "$SANDBOX/codex-sessions/$NATIVE_SID.start"
check "Codex owner change invalidates both disk and resident cached tab" \
    test "$(jq -r --arg s "codex-$NATIVE_SID" '.sessions[$s].tabID' "$STATE")" = null
jq -nc --arg s "$NATIVE_SID" '{session_id:$s,hook_event_name:"UserPromptSubmit",prompt:"switch backend"}' \
    | codex_policy UserPromptSubmit terminal-notifier 1
check "switching Codex to the external backend still clears its native notice" \
    wait_for 10 state_is "codex-$NATIVE_SID" ""
# Simulate state produced by an older agent, before source-scoped identifiers.
agent_queue "$(jq -nc --arg s "$NATIVE_SID" \
    '{type:"notify",session_id:$s,title:"Codex ✅",subtitle:"legacy Codex fixture",clear_on_focus:false}')"
check "legacy Codex state can coexist with the new protocol" \
    wait_for 10 native_notice_is "legacy Codex fixture"
jq -nc --arg s "$NATIVE_SID" '{session_id:$s,hook_event_name:"UserPromptSubmit",prompt:"retire legacy"}' \
    | codex_policy UserPromptSubmit terminal-notifier 1
check "compatibility prompt also retires a pre-migration Codex identifier" \
    wait_for 10 native_clear

# ── 9. Stale replay is dropped, even when a hook file was just renamed ────
# The native protocol carries event time; a fresh file must not refresh an
# event that spent too long in an old queue. The v1 notify format still ages
# by file mtime, so test both contracts.
agent_queue "$(jq -nc --arg s "$NATIVE_SID" --arg sessions "$SESSIONS" \
    --arg rates "$SANDBOX/stale-rates" --arg hooks "$REPO/hooks" \
    --arg round "$(cat "$SESSIONS/$NATIVE_SID.round")" \
    --argjson at "$(( $(date +%s) - 600 ))" \
    '{type:"hook_event",version:1,source:"claude",round_id:$round,occurred_at:$at,
      started_at:($at - 1000),session_dir:$sessions,rate_dir:$rates,hooks_dir:$hooks,
      settings:{},payload:{session_id:$s,hook_event_name:"Stop",cwd:"/work/stale"}}')"
check "fresh spool file cannot resurrect an expired hook event" \
    wait_for 10 log_has "dropped stale hook event"
check "stale native replay leaves the notification withdrawn" native_clear

# Build and backdate outside the spool; rename does not alter mtime.
STALE="$SANDBOX/stale.json"
jq -nc --arg s "$OTHER" '{type:"notify",session_id:$s,title:"ancient"}' > "$STALE"
touch -t 200001010000 "$STALE"
mv "$STALE" "$ROOT/spool/0000000000000001-stale.json"
check "a stale notify is dropped, not replayed" wait_for 10 log_has "dropped stale notify"

# ── 10. Shutdown completes, then state survives a restart ─────────────────
check "SIGTERM completes asynchronous shutdown within 10 seconds" stop_agent
check "shutdown calls the lifecycle cleanup" log_has "agent down"
for marker in agent.pid ready capabilities native-hook-ready; do
    check "shutdown removes $marker" test ! -f "$ROOT/$marker"
done
"$BIN" >/dev/null 2>&1 &
AGENT_PID=$!
check "restarted agent reloads its sessions" wait_for 15 log_has "restored "
# No assertion that readiness is republished: this file was written by hand
# above, so it exists no matter what the restarted agent does — the check that
# used to be here could never fail.
printf 'authorized\n' > "$ROOT/ready"
agent_queue "$(jq -nc --arg s "$SID" '{type:"notify",session_id:$s,title:"after restart"}')"
# A changed identifier here would post a SECOND banner beside one that may still
# be on screen from before the restart, instead of replacing it.
check "the identifier is still stable after a restart" \
    wait_for 10 state_is "$SID" "claude-$SID"
check "the tab resolved before the restart survived it" \
    test "$(jq -r --arg s "$SID" '.sessions[$s].tabID // ""' "$STATE")" = "BEEF-TAB"

echo
echo "Results: $pass passed, $fail failed"
if (( fail > 0 )); then
    echo "Failed: ${fail_list[*]}"
    # Preserve diagnostics before the private sandbox is cleaned on exit.
    echo "── agent.log (last 40 lines) ──"
    tail -n 40 "$LOG" 2>/dev/null
    echo "── spool ──"
    ls -la "$ROOT/spool" 2>/dev/null
    echo "pid=$(cat "$ROOT/agent.pid" 2>/dev/null) ready=$(cat "$ROOT/ready" 2>/dev/null)"
    ps -axo pid,ppid,lstart,command | grep '[g]hostty-notify-agent'
    exit 1
fi
exit 0
