#!/usr/bin/env bash
# Historical compatibility fixture; this is NOT native runtime coverage.
# Integration test for hooks/ghostty-notify.sh alerter-action dispatch.
#
# Regression guard for the bug where alerter 26.5 returns the close-label
# text ("Dismiss") instead of @CLOSED when the close button is clicked,
# which was accidentally matched by the old blacklist and fired the focus
# script → phantom Ghostty auto-activate.
#
# Only "Go to tab" may fire FOCUS_SCRIPT. Everything else must be silent.

set -u
IFS=$'\n\t'

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
HOOK="$REPO/tests/fixtures/shell-baseline/hooks/ghostty-notify.sh"

[[ -x "$HOOK" ]] || { echo "FATAL: $HOOK not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

export HOME="$SANDBOX"
export PATH="$SANDBOX/bin:$PATH"
mkdir -p \
    "$HOME/.claude/hooks" \
    "$HOME/.claude/notifications/ghostty-sessions" \
    "$HOME/.local/bin" \
    "$SANDBOX/bin"

# Stub alerter: echo whatever TEST_ACTION env var holds.
# Pinned via GHOSTTY_NOTIFY_ALERTER so the hook's PATH/common-location
# discovery can't pick up a real alerter on the developer machine.
cat > "$HOME/.local/bin/alerter" <<'SH'
#!/bin/bash
printf '%s\n' "${TEST_ACTION:-}"
SH
chmod +x "$HOME/.local/bin/alerter"
export GHOSTTY_NOTIFY_ALERTER="$HOME/.local/bin/alerter"

# Satisfy `command -v terminal-notifier` check in hook (line 12).
ln -sf "$HOME/.local/bin/alerter" "$SANDBOX/bin/terminal-notifier"

# Stub FOCUS_SCRIPT: writes marker file when invoked. Pinned via env so the
# hook's sibling-script resolution doesn't find the real repo focus script.
FOCUS_MARKER="$SANDBOX/focus-fired"
cat > "$HOME/.claude/hooks/ghostty-tab-focus.sh" <<SH
#!/bin/bash
printf 'session=%s\n' "\$1" > "$FOCUS_MARKER"
SH
chmod +x "$HOME/.claude/hooks/ghostty-tab-focus.sh"
export GHOSTTY_NOTIFY_FOCUS_SCRIPT="$HOME/.claude/hooks/ghostty-tab-focus.sh"

export TERM_PROGRAM=ghostty
export GHOSTTY_NOTIFY_MIN_ELAPSED=10
export GHOSTTY_NOTIFY_SOUND_ELAPSED=9999   # force SILENT=true branch too
export GHOSTTY_NOTIFY_TIMEOUT=1
export GHOSTTY_NOTIFY_BACKEND=auto         # pin: a host env override (e.g.
                                           # =terminal-notifier) would route
                                           # around the alerter path under test
# Only the click dispatch is under test; the clear-on-focus watcher is not
# stubbed here and would poll the real lsappinfo/osascript for 30s past the
# run. Covered by tests/test-clear-on-focus.sh instead.
export GHOSTTY_NOTIFY_CLEAR_ON_FOCUS=0
# The resident agent delivers through UNUserNotificationCenter, so
# the stubbed alerter under test here would never be called. Empty (not unset)
# is what disables it — see agent_app in hooks/agent-common.sh.
export GHOSTTY_NOTIFY_AGENT_APP=""
unset GHOSTTY_RESOURCES_DIR || true

pass=0; fail=0
fail_list=()

run_case() {
    local action="$1"
    local expect="$2"   # "fire" | "nofire"
    local label="$3"

    # Fresh session id per case avoids the hook's 10s rate-limit bucket.
    # Must be UUID-shaped (^[a-fA-F0-9-]+$): every hook rejects other ids
    # before touching the filesystem, so a non-hex sid would make each case
    # pass vacuously against a hook that exited early.
    local sid
    sid="dabbad00-$(date +%s)-$RANDOM"

    # Simulate a round that started 60s ago (well past MIN_ELAPSED).
    echo $(( $(date +%s) - 60 )) \
        > "$HOME/.claude/notifications/ghostty-sessions/${sid}.start"
    rm -f "$FOCUS_MARKER"

    local input
    input=$(printf '{"session_id":"%s","cwd":"/tmp","hook_event_name":"Stop"}' "$sid")

    # TEST_ACTION is inherited into the hook's subshell that runs alerter.
    printf '%s' "$input" | TEST_ACTION="$action" "$HOOK" >/dev/null 2>&1

    # fire_with_alerter runs (...) & + disown. Give the subshell time to
    # capture alerter output and (possibly) invoke the focus stub. Our
    # stubs are instant, so 200ms is generous; if fire is expected, poll
    # up to 1s just in case the scheduler is slow.
    sleep 0.2
    if [[ "$expect" == "fire" ]]; then
        local i=0
        while (( i < 10 )) && [[ ! -f "$FOCUS_MARKER" ]]; do
            sleep 0.1
            i=$((i + 1))
        done
    fi

    local got="nofire"
    [[ -f "$FOCUS_MARKER" ]] && got="fire"

    if [[ "$got" == "$expect" ]]; then
        printf '  \033[32mPASS\033[0m  %-40s action=%q\n' "$label" "$action"
        pass=$((pass + 1))
    else
        printf '  \033[31mFAIL\033[0m  %-40s action=%q expected=%s got=%s\n' \
            "$label" "$action" "$expect" "$got"
        fail=$((fail + 1))
        fail_list+=("$label")
    fi
}

echo "== alerter dispatch regression tests =="

# Explicit action-button click.
run_case "Go to tab"         "fire"   "action button click"

# User clicked the notification body — treated as intent to jump.
run_case "@CONTENTCLICKED"   "fire"   "body click sentinel"

# Regression: alerter 26.5 close-button returns the --close-label text.
# Dismiss MUST NOT jump (this was the original user-reported bug).
run_case "Dismiss"           "nofire" "close-button click (alerter 26.5+)"

# Legacy sentinel (still emitted on older alerter / some edge paths).
run_case "@CLOSED"           "nofire" "@CLOSED sentinel"

# Notification timed out without interaction.
run_case "@TIMEOUT"          "nofire" "timeout sentinel"

# alerter produced no output (e.g. killed/replaced).
run_case ""                  "nofire" "empty action string"

# Unexpected value — must not default to fire.
run_case "random-garbage"    "nofire" "unknown string"

echo
echo "Results: $pass passed, $fail failed"
if (( fail > 0 )); then
    echo "Failed cases: ${fail_list[*]}"
    exit 1
fi
exit 0
