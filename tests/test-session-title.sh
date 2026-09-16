#!/usr/bin/env bash
# Regression test for the session-title subtitle in ghostty-notify.sh.
#
# The notification must say WHICH session finished, not just which folder —
# five tabs in one project all used to render the identical "Task Complete
# — <dir>" subtitle. Title sources, in order:
#   1. session_title field on hook stdin (trialed upstream, may be absent)
#   2. last custom-title record in the transcript (written by /rename)
#   3. last ai-title record in the transcript (auto-generated title)
#   4. none of those → legacy event wording ("Task Complete — <dir>")
#
# Uses the terminal-notifier fallback path because it is synchronous and
# records its argv, so the subtitle can be asserted directly.

set -u
IFS=$'\n\t'

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
HOOK="$REPO/hooks/ghostty-notify.sh"

[[ -x "$HOOK" ]] || { echo "FATAL: $HOOK not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

export HOME="$SANDBOX"
export PATH="$SANDBOX/bin:$PATH"
mkdir -p \
    "$HOME/.claude/notifications/ghostty-sessions" \
    "$SANDBOX/bin"

# The synchronous terminal-notifier path is what this suite reads argv
# from; the resident agent is disabled below so it is the one that fires.

# Fake terminal-notifier: records argv, one arg per line.
TN_LOG="$SANDBOX/tn-args.log"
cat > "$SANDBOX/bin/terminal-notifier" <<SH
#!/bin/bash
printf '%s\n' "\$@" > "$TN_LOG"
SH
chmod +x "$SANDBOX/bin/terminal-notifier"

export TERM_PROGRAM=ghostty
export GHOSTTY_NOTIFY_MIN_ELAPSED=10
export GHOSTTY_NOTIFY_TIMEOUT=1
export GHOSTTY_NOTIFY_BACKEND=auto   # pin against host env overrides
# Clear-on-focus is NOT under test here and its watcher is not stubbed: it
# would poll the developer machine's real lsappinfo/osascript, and a clear
# runs the terminal-notifier stub with -remove, truncating the very TN_LOG
# these assertions read. Leaves no stray pollers behind either.
export GHOSTTY_NOTIFY_CLEAR_ON_FOCUS=0
# The subtitle is asserted from the terminal-notifier stub's recorded argv, so
# the resident agent must not intercept delivery. Empty disables it.
export GHOSTTY_NOTIFY_AGENT_APP=""
unset GHOSTTY_RESOURCES_DIR || true

pass=0; fail=0
fail_list=()

# Extract the value following the -subtitle flag from the recorded argv.
logged_subtitle() {
    awk 'prev == "-subtitle" { print; exit } { prev = $0 }' "$TN_LOG" 2>/dev/null
}

# run_case <label> <expected-subtitle> <extra-stdin-json-fields>
# extra fields is a string like ',"transcript_path":"/x"' appended into the
# stdin JSON object (already comma-prefixed), or "".
run_case() {
    local label="$1"
    local expect="$2"
    local extra="$3"

    # Fresh session id per case avoids the hook's 10s rate-limit bucket.
    local sid
    sid="deadbeef-$(date +%s)-$RANDOM"
    echo $(( $(date +%s) - 60 )) \
        > "$HOME/.claude/notifications/ghostty-sessions/${sid}.start"
    rm -f "$TN_LOG"

    printf '{"session_id":"%s","cwd":"/tmp/webapp","hook_event_name":"Stop"%s}' \
        "$sid" "$extra" | "$HOOK" >/dev/null 2>&1

    local got
    got=$(logged_subtitle)
    if [[ "$got" == "$expect" ]]; then
        printf '  \033[32mPASS\033[0m  %-42s subtitle=%q\n' "$label" "$got"
        pass=$((pass + 1))
    else
        printf '  \033[31mFAIL\033[0m  %-42s expected=%q got=%q\n' \
            "$label" "$expect" "$got"
        fail=$((fail + 1))
        fail_list+=("$label")
    fi
}

echo "== session-title subtitle regression tests =="

# The hook must never mkdir the cwd; /tmp/webapp only needs to exist as a
# basename for PROJECT_NAME, which basename derives from the string alone.

# 1. No title anywhere → legacy wording survives.
run_case "no title: legacy wording" \
    "Task Complete — webapp" \
    ""

# 2. Transcript with several custom-title records → newest one wins, and an
#    ai-title never outranks an explicit rename (matches the resume picker).
T1="$SANDBOX/renamed.jsonl"
{
    printf '{"type":"custom-title","customTitle":"old-title","sessionId":"x"}\n'
    printf '{"type":"user","message":{"content":"hello"}}\n'
    printf '{"type":"custom-title","customTitle":"auth-refactor","sessionId":"x"}\n'
    printf '{"type":"ai-title","aiTitle":"ai-should-lose","sessionId":"x"}\n'
} > "$T1"
run_case "transcript custom-title: latest wins" \
    "auth-refactor — webapp" \
    ",\"transcript_path\":$(printf '%s' "$T1" | jq -Rs .)"

# 2b. Never-renamed session → the auto-generated ai-title is used.
T1B="$SANDBOX/ai-only.jsonl"
{
    printf '{"type":"ai-title","aiTitle":"stale-ai-title","sessionId":"x"}\n'
    printf '{"type":"user","message":{"content":"hello"}}\n'
    printf '{"type":"ai-title","aiTitle":"fixing-notify-bug","sessionId":"x"}\n'
} > "$T1B"
run_case "ai-title fallback: latest wins" \
    "fixing-notify-bug — webapp" \
    ",\"transcript_path\":$(printf '%s' "$T1B" | jq -Rs .)"

# 3. Whitespace-variant record (pretty-printed JSON) is still found.
T2="$SANDBOX/spaced.jsonl"
printf '{"type" : "custom-title", "customTitle": "spaced-title"}\n' > "$T2"
run_case "whitespace-variant record" \
    "spaced-title — webapp" \
    ",\"transcript_path\":$(printf '%s' "$T2" | jq -Rs .)"

# 4. stdin session_title beats the transcript record.
run_case "stdin session_title takes precedence" \
    "stdin-title — webapp" \
    ",\"session_title\":\"stdin-title\",\"transcript_path\":$(printf '%s' "$T1" | jq -Rs .)"

# 5. Missing transcript path degrades to legacy wording, not an error.
run_case "dangling transcript_path degrades" \
    "Task Complete — webapp" \
    ",\"transcript_path\":\"$SANDBOX/does-not-exist.jsonl\""

# 6. A title holding an embedded newline must survive whole. jq decodes the
#    escape into real line breaks, and the "newest record wins" tail would
#    otherwise keep only the last fragment — dropping the rename entirely
#    when the title ends with one.
T3="$SANDBOX/multiline.jsonl"
{
    printf '{"type":"custom-title","customTitle":"release\\nprep"}\n'
} > "$T3"
run_case "multi-line title kept whole" \
    "release prep — webapp" \
    ",\"transcript_path\":$(printf '%s' "$T3" | jq -Rs .)"

# 7. A title starting with '-' must not be parsed as the next flag. Both
#    terminal-notifier reads argv NSUserDefaults-style, so "-wip" in value
#    position used to swallow the flag and drop the notification entirely
#    (usage dump, exit 0).
run_case "dash-leading title does not break argv" \
    "wip auth fix — webapp" \
    ",\"session_title\":\"-wip auth fix\""

echo
echo "Results: $pass passed, $fail failed"
if (( fail > 0 )); then
    echo "Failed: ${fail_list[*]}"
    exit 1
fi
exit 0
