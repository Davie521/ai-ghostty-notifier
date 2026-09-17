#!/usr/bin/env bash
# Historical compatibility fixture; this is NOT native runtime coverage.
# Regression test for fire_with_terminal_notifier fallback path.
#
# When alerter is missing, the hook falls back to terminal-notifier. This
# path must NOT wire click-to-focus (-execute / -activate), because
# terminal-notifier fires the command on any click with no way to filter
# dismiss — the same bug the alerter whitelist fixes. We intentionally
# degrade: notification shows, click does nothing automatic, user
# navigates manually.

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

# Deliberately point the hook at a nonexistent alerter so it falls back.
# (The env override keeps the test hermetic — without it, a real alerter on
# the developer machine's PATH would be picked up by the hook's discovery.)
export GHOSTTY_NOTIFY_ALERTER="$SANDBOX/no-such-alerter"

# Fake terminal-notifier: records all args the hook passes.
TN_LOG="$SANDBOX/tn-args.log"
cat > "$SANDBOX/bin/terminal-notifier" <<SH
#!/bin/bash
printf '%s\n' "\$@" > "$TN_LOG"
SH
chmod +x "$SANDBOX/bin/terminal-notifier"

# Stub focus script: should never be invoked on this path.
FOCUS_MARKER="$SANDBOX/focus-fired"
cat > "$HOME/.claude/hooks/ghostty-tab-focus.sh" <<SH
#!/bin/bash
echo fired > "$FOCUS_MARKER"
SH
chmod +x "$HOME/.claude/hooks/ghostty-tab-focus.sh"
export GHOSTTY_NOTIFY_FOCUS_SCRIPT="$HOME/.claude/hooks/ghostty-tab-focus.sh"

export TERM_PROGRAM=ghostty
export GHOSTTY_NOTIFY_MIN_ELAPSED=10
export GHOSTTY_NOTIFY_TIMEOUT=1
export GHOSTTY_NOTIFY_BACKEND=auto   # pin against host env overrides
# Not under test, and its watcher would poll the real lsappinfo/osascript
# and outlive the run (see tests/test-clear-on-focus.sh for its coverage).
export GHOSTTY_NOTIFY_CLEAR_ON_FOCUS=0
# The terminal-notifier fallback is the whole subject here; the resident agent
# would deliver instead and never touch the stub. Empty disables it.
export GHOSTTY_NOTIFY_AGENT_APP=""
unset GHOSTTY_RESOURCES_DIR || true

# The sid MUST be UUID-shaped (hex + dashes, matching ^[a-fA-F0-9-]+$).
# A previous regression re-added -execute behind exactly that session-id
# guard, and a non-hex sid like "fallback-..." sailed past it — making
# every check below pass vacuously while real sessions got -execute wired.
sid="deadbeef-$(date +%s)-$RANDOM"
echo $(( $(date +%s) - 60 )) > "$HOME/.claude/notifications/ghostty-sessions/${sid}.start"

printf '{"session_id":"%s","cwd":"/tmp","hook_event_name":"Stop"}' "$sid" | \
    "$HOOK" >/dev/null 2>&1

# terminal-notifier call is synchronous in fire_with_terminal_notifier
# (no `&`), so the log should already exist when the hook returns.
sleep 0.1

pass=0; fail=0
fail_list=()

# 1. Confirm terminal-notifier was actually called (fallback entered).
if [[ ! -f "$TN_LOG" ]]; then
    printf '  \033[31mFAIL\033[0m  fallback not entered — tn-args.log missing\n'
    fail=$((fail + 1))
    fail_list+=("fallback not entered")
fi

# 2. No -execute wiring (the old bug vector).
if [[ -f "$TN_LOG" ]] && grep -q -- "-execute" "$TN_LOG"; then
    printf '  \033[31mFAIL\033[0m  -execute still wired into terminal-notifier fallback\n'
    fail=$((fail + 1))
    fail_list+=("-execute present")
else
    printf '  \033[32mPASS\033[0m  no -execute wiring in fallback args\n'
    pass=$((pass + 1))
fi

# 3. No -activate wiring (the other auto-focus vector).
if [[ -f "$TN_LOG" ]] && grep -q -- "-activate" "$TN_LOG"; then
    printf '  \033[31mFAIL\033[0m  -activate still wired into terminal-notifier fallback\n'
    fail=$((fail + 1))
    fail_list+=("-activate present")
else
    printf '  \033[32mPASS\033[0m  no -activate wiring in fallback args\n'
    pass=$((pass + 1))
fi

# 4. Focus script was not invoked.
if [[ -f "$FOCUS_MARKER" ]]; then
    printf '  \033[31mFAIL\033[0m  focus script ran during fallback flow\n'
    fail=$((fail + 1))
    fail_list+=("focus script fired")
else
    printf '  \033[32mPASS\033[0m  focus script did NOT run\n'
    pass=$((pass + 1))
fi

# 5. Basic notification content is still present (fallback still notifies).
if [[ -f "$TN_LOG" ]] && grep -q -- "-title" "$TN_LOG" && grep -q -- "-message" "$TN_LOG"; then
    printf '  \033[32mPASS\033[0m  fallback still issues notification content\n'
    pass=$((pass + 1))
else
    printf '  \033[31mFAIL\033[0m  fallback did not issue a proper notification\n'
    fail=$((fail + 1))
    fail_list+=("missing notification content")
fi

echo
echo "Results: $pass passed, $fail failed"
if (( fail > 0 )); then
    echo "Failed: ${fail_list[*]}"
    exit 1
fi
exit 0
