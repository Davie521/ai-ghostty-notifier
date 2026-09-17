#!/usr/bin/env bash
# Shared helpers for talking to the resident notification agent.
#
# Transport is a spool directory: one JSON request per file, published by
# rename so the agent can never read a half-written request. That keeps every
# hook pure bash — no client binary to build, no socket lifetime to manage —
# and lets the integration test drive the whole agent by dropping files.
#
# Sourced, never executed. Callers must already have HOME set.

AGENT_ROOT="$HOME/.claude/notifications/ghostty-agent"
AGENT_SPOOL="$AGENT_ROOT/spool"
AGENT_PID_FILE="$AGENT_ROOT/agent.pid"
AGENT_READY_FILE="$AGENT_ROOT/ready"
AGENT_BUNDLE_NAME="ClaudeGhosttyNotify.app"
# Where scripts/install-agent.sh puts the copy launchd keeps alive: a fixed
# place outside any checkout, so moving or deleting the repository breaks
# neither the LaunchAgent nor this discovery.
AGENT_INSTALL_DIR="$HOME/Library/Application Support/claude-ghostty-notify"

# agent_app <hooks-dir>
# Prints the agent bundle path, or returns 1 when the agent is unavailable.
#
# An explicitly empty GHOSTTY_NOTIFY_AGENT_APP disables the agent and pins the
# shell delivery path — the `${VAR-default}` (no colon) form is deliberate, so
# "set but empty" is distinguishable from "unset". Tests rely on it.
#
# A non-empty override is still checked for an executable binary. Accepting it
# blindly would let a stale path route every notification into a spool nothing
# is draining.
#
# The installed copy is tried first: it is the one launchd restarts and the one
# a notification click launches when the agent is down. The build under a
# checkout only matters on a machine that never ran the install script.
agent_app() {
    local hooks_dir="${1:-}"
    local candidate
    if [[ -n "${GHOSTTY_NOTIFY_AGENT_APP+isset}" ]]; then
        [[ -n "$GHOSTTY_NOTIFY_AGENT_APP" ]] || return 1
        [[ -x "$GHOSTTY_NOTIFY_AGENT_APP/Contents/MacOS/ghostty-notify-agent" ]] || return 1
        printf '%s' "$GHOSTTY_NOTIFY_AGENT_APP"
        return 0
    fi
    for candidate in \
        "$AGENT_INSTALL_DIR/$AGENT_BUNDLE_NAME" \
        "$hooks_dir/../build/$AGENT_BUNDLE_NAME" \
        "$hooks_dir/$AGENT_BUNDLE_NAME" \
        "$HOME/.claude/hooks/$AGENT_BUNDLE_NAME"; do
        if [[ -x "$candidate/Contents/MacOS/ghostty-notify-agent" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

# agent_running
# True when the resident agent process is alive. The command check guards
# against PID reuse: a recycled pid that is not our agent must not be mistaken
# for one, or requests would queue forever with nothing draining them.
agent_running() {
    local pid
    pid=$(cat "$AGENT_PID_FILE" 2>/dev/null) || return 1
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    ps -o command= -p "$pid" 2>/dev/null | grep -q 'ghostty-notify-agent'
}

# agent_ready
# True when the agent is alive AND macOS has granted it permission to display
# notifications. Both halves matter: a spooled request is not a delivered
# notification, and a user who clicked "Don't Allow" (or never answered the
# prompt) would otherwise get silence instead of the documented fallback.
agent_ready() {
    agent_running || return 1
    [[ "$(cat "$AGENT_READY_FILE" 2>/dev/null)" == "authorized" ]]
}

# agent_launch <app-bundle>
# Start the agent if it is not up. Best-effort by design: the caller has already
# decided what to do when the agent cannot display anything.
agent_launch() {
    agent_running && return 0
    open -a "$1" 2>/dev/null || return 1
}

# agent_queue <json> <app-bundle>
# Write one request and make sure the agent is running to consume it. Use for
# requests that do not need to display anything (dismiss, anchor, ping): they
# are still useful when replayed after a cold start, because the agent drains
# the spool once at startup.
agent_queue() {
    local json="$1" app="$2" name tmp
    # A blank payload means the caller's `jq` failed. Queuing it would make the
    # agent drop an undecodable file while the caller believed the notification
    # was delivered — the same silent-drop failure the readiness gate exists to
    # prevent, arriving by a different route.
    [[ -n "$json" ]] || return 1
    mkdir -p "$AGENT_SPOOL" 2>/dev/null || return 1

    # Uniqueness only. Arrival ORDER comes from the file's mtime, which the agent
    # sorts on — BSD `date` has no sub-second format, so a name built here could
    # never carry a real millisecond and two requests in the same second would
    # sort arbitrarily. The timestamp prefix is kept because it makes a stuck
    # spool readable by eye.
    name=$(printf '%016d-%d-%d.json' "$(( $(date +%s) * 1000 ))" "$$" "$RANDOM")
    tmp="$AGENT_SPOOL/.$name.tmp"

    printf '%s' "$json" > "$tmp" 2>/dev/null || return 1
    # Same directory, so this rename is atomic and cannot cross a filesystem.
    mv -f "$tmp" "$AGENT_SPOOL/$name" 2>/dev/null || { rm -f "$tmp"; return 1; }

    agent_launch "$app" || true
    return 0
}

# agent_deliver <json> <app-bundle>
# Queue a request that MUST result in something visible. Returns non-zero when
# the agent could not display it, so the caller falls back to the shell
# backends instead of silently dropping the notification. The agent is still
# launched on failure, so the next notification can use it.
agent_deliver() {
    if ! agent_ready; then
        agent_launch "$2" || true
        return 1
    fi
    agent_queue "$1" "$2"
}
