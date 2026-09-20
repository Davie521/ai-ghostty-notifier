#!/usr/bin/env bash
# Install the notification agent where launchd can keep it alive.
#
# The bundle scripts/build-agent.sh assembled under the checkout is copied to
# ~/Library/Application Support/claude-ghostty-notify/ and a LaunchAgent points
# at that copy. The checkout is then free to move or disappear. launchd stores
# absolute paths, and a LaunchAgent aimed into a repository stops working the
# day the repository is renamed — exit 78, penalty box, no dialog — while the
# hooks fall back to display-only terminal-notifier, which is the failure the
# agent exists to fix. hooks/native-hook.sh looks in the same fixed place, so
# a moved checkout does not lose the agent either.
#
# Why launchd rather than "let the first hook start it": launchd restarts the
# agent if it ever crashes, starts it at login without waiting for a hook, and
# gives it a stable place to be stopped from. The hooks can still start it on
# demand (see NativeHookRuntime.swift) so a machine without the LaunchAgent
# installed still works — this just removes the cold-start latency on the first
# notification after login.
#
# Rerun after every scripts/build-agent.sh: the installed copy is what runs,
# not the build under the checkout.
#
# The plist is generated rather than committed because ProgramArguments needs
# the absolute path of the installed copy, which contains the home directory.
#
# Usage:
#   bash scripts/install-agent.sh              install (or update) and start
#   bash scripts/install-agent.sh --no-start   install the required runtime only
#   bash scripts/install-agent.sh --uninstall  stop and remove
#   bash scripts/install-agent.sh --print-launch-agent   print the LaunchAgent, change nothing

set -euo pipefail

START=1
case "${1:-}" in
    --no-start) START=0 ;;
    --uninstall|--print-launch-agent|"") ;;
    *) echo "usage: install-agent.sh [--no-start|--uninstall|--print-launch-agent]" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo "FATAL: too many arguments" >&2; exit 2; }
[[ "$(uname)" == Darwin ]] || { echo "FATAL: macOS only" >&2; exit 2; }
[[ "${HOME:-}" == /* && "$HOME" != / ]] || { echo "FATAL: HOME must be an absolute non-root path" >&2; exit 2; }

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)

LABEL="io.github.davie521.cgnotify"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BUNDLE_NAME="ClaudeGhosttyNotify.app"
BUILT="$REPO/build/$BUNDLE_NAME"
INSTALL_DIR="$HOME/Library/Application Support/claude-ghostty-notify"
APP="$INSTALL_DIR/$BUNDLE_NAME"
BIN="$APP/Contents/MacOS/ghostty-notify-agent"
DOMAIN="gui/$(id -u)"
STATE="$HOME/.claude/notifications/ghostty-agent"
# Overridable so that a test can run the whole install: the real tool would
# register a sandbox copy under the bundle identifier the installed app uses.
LSREGISTER=${GHOSTTY_NOTIFY_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}

# The LaunchAgent as text. The path is XML-escaped: a home directory with & or <
# in its name otherwise yields a plist launchd cannot read.
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
launch_agent_plist() {
cat <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <!-- The binary INSIDE the bundle, not \`open -a\`: launchd needs a process
         that stays alive, and \`open\` exits immediately. Running the bundled
         executable directly still resolves the bundle identity that
         UNUserNotificationCenter requires — verified by tests/test-agent.sh,
         which launches it exactly this way. -->
    <key>ProgramArguments</key>
    <array>
        <string>$(xml_escape "$BIN")</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <!-- Restart on a crash, but NOT on a clean exit. A second agent exits 0 on
         purpose when one is already running (see Singleton.swift); with
         KeepAlive=true launchd would restart it immediately and spin. -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLIST_EOF
}

unload() {
    # bootout fails when nothing is loaded; that is the normal case on a fresh
    # install, so it must not abort the script.
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
}

# Stop every agent instance, wherever it was launched from. A running agent
# keeps executing from the old inode after the bundle is replaced, and
# readiness checks would confirm that stale process as
# healthy — so nothing would ever start the new copy. The liveness markers go
# too: a recycled pid is exactly what the ps check there defends against.
# Processes whose executable is the bundled binary, wherever the bundle lives:
# the resident, and every hook and worker, which run the same file. By
# executable, not by command line: a shell that merely mentions the path is not
# one of them.
agent_pids() {
    ps -axww -o pid=,comm= 2>/dev/null |
        awk -v suffix="/$BUNDLE_NAME/Contents/MacOS/ghostty-notify-agent" '
            { pid = $1; sub(/^[ ]*[0-9]+[ ]+/, "") }
            length($0) >= length(suffix) && substr($0, length($0) - length(suffix) + 1) == suffix { print pid }'
}

stop_agents() {
    unload
    pkill -f "/$BUNDLE_NAME/Contents/MacOS/ghostty-notify-agent" 2>/dev/null || true
    rm -f "$STATE/agent.pid" "$STATE/ready" "$STATE/capabilities" "$STATE/native-hook-ready"
    # Wait for them to be gone, not for a second. After SIGTERM a hook takes up
    # to four seconds to put a tab title back and a worker up to ten to reap its
    # notification backend, and a version may change how processes exclude each
    # other (the locks became flock files in 2026-09): old and new must not
    # work on the same session files side by side. Their own watchdogs end
    # them; whatever is left after that is killed. A hook that starts from the
    # old bundle during this wait lives for milliseconds, which is the overlap
    # that remains.
    local waited=0 pids pid
    while pids=$(agent_pids) && [[ -n "$pids" ]] && ((waited < 60)); do
        sleep 0.25
        waited=$((waited + 1))
    done
    for pid in $(agent_pids); do kill -KILL "$pid" 2>/dev/null || true; done
}

# Read-only: the LaunchAgent a full install would write for this HOME.
if [[ "${1:-}" == "--print-launch-agent" ]]; then
    launch_agent_plist
    exit 0
fi

if [[ "${1:-}" == "--uninstall" ]]; then
    stop_agents
    rm -f "$PLIST"
    if [[ -x "$LSREGISTER" && -d "$APP" ]]; then
        "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
    fi
    rm -rf "$APP"
    rmdir "$INSTALL_DIR" 2>/dev/null || true
    echo "==> Removed $LABEL and $APP"
    echo "    Session bookkeeping under $STATE is kept; remove it by hand if unwanted."
    echo "    Hooks require this App; remove their registrations too. There is no shell fallback."
    exit 0
fi

[[ -f "$BUILT/Contents/Resources/native-hook-v1" \
    && -x "$BUILT/Contents/MacOS/ghostty-notify-agent" ]] || {
    echo "FATAL: $BUILT missing or too old for native hooks. Build it first:" >&2
    echo "  bash scripts/build-agent.sh --build-only" >&2
    exit 2
}
[[ "$("$BUILT/Contents/MacOS/ghostty-notify-agent" --hook-runtime-version)" == native-hook-v1 ]] || {
    echo "FATAL: the built executable does not support native-hook-v1" >&2; exit 2;
}

# Runtime-only installation must not accidentally leave a configured service
# executing an older inode. Use the normal upgrade path for a LaunchAgent.
if [[ "$START" == 0 && -e "$PLIST" ]]; then
    echo "FATAL: a LaunchAgent is already installed; rerun without --no-start to upgrade it." >&2
    exit 2
fi
if [[ "$START" == 0 ]]; then
    # Reuse native executable/argv identity checks; a hand-started resident may
    # have no LaunchAgent plist. Do not signal anything in runtime-only mode.
    LIVE_RESIDENT_PID=$("$BUILT/Contents/MacOS/ghostty-notify-agent" --resident-pid) || {
        echo "FATAL: cannot inspect the resident; rebuild the native App before installing." >&2
        exit 2
    }
    if [[ -n "$LIVE_RESIDENT_PID" ]]; then
        echo "FATAL: resident $LIVE_RESIDENT_PID is running; rerun without --no-start to upgrade it." >&2
        exit 2
    fi
fi

echo "==> Installing $APP"
mkdir -p "$INSTALL_DIR"
# Stage beside the target and rename into place, so a copy that fails halfway
# leaves the previous install intact. ditto keeps the code signature, extended
# attributes and permissions that TCC and LaunchServices key their records on.
STAGING=$(mktemp -d "$INSTALL_DIR/.native-install.XXXXXX")
STAGED="$STAGING/$BUNDLE_NAME"
PREVIOUS="$STAGING/previous.app"
cleanup_stage() {
    # If publication failed after moving the old bundle, put it back.
    if [[ -e "$PREVIOUS" && ! -e "$APP" ]]; then
        mv "$PREVIOUS" "$APP" || return
    fi
    rm -rf "$STAGING"
}
trap cleanup_stage EXIT
ditto "$BUILT" "$STAGED"
# Refuse an incomplete/unsigned copy before stopping any running service or
# replacing the previous installation.
codesign --verify --deep --strict "$STAGED"

# Written and checked here, while the previous service is still running, so
# that a plist launchd cannot read is found out before anything is stopped.
STAGED_PLIST="$STAGING/$LABEL.plist"
if [[ "$START" == 1 ]]; then
    launch_agent_plist > "$STAGED_PLIST"
    plutil -lint "$STAGED_PLIST" >/dev/null || {
        echo "FATAL: could not write a valid LaunchAgent for $BIN; nothing was changed." >&2
        exit 2
    }
fi
if [[ "$START" == 1 ]]; then stop_agents; fi
if [[ -e "$APP" ]]; then mv "$APP" "$PREVIOUS"; fi
mv "$STAGED" "$APP"
# The copy must carry the build's signature: TCC keys the notification and
# Automation grants to it, so a copy that lost it would be asked again — or,
# for notifications, would silently display nothing.
codesign --verify --deep --strict "$APP" 2>/dev/null ||
    echo "  warning: the installed copy failed signature verification; macOS may ask for permissions again" >&2
if [[ "$START" == 0 ]]; then
    echo "==> Installed native runtime: $APP"
    echo "    No LaunchAgent, LaunchServices registration or permission prompt was started."
    echo "    Install hooks next; terminal-notifier is needed for display-only fallback delivery."
    echo "    Set GHOSTTY_NOTIFY_AGENT_APP='' in hook settings to disable automatic resident launch."
    exit 0
fi
if [[ -x "$LSREGISTER" ]]; then
    # One registration per bundle identifier. A click on a notification while
    # the agent is down makes LaunchServices launch the app by identifier, and
    # that must resolve to the installed copy, not to the build in a checkout
    # that may be gone tomorrow.
    "$LSREGISTER" -u "$BUILT" >/dev/null 2>&1 || true
    "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
fi

mkdir -p "$(dirname "$PLIST")"
mv "$STAGED_PLIST" "$PLIST"

# Obtain the notification grant BEFORE handing the agent to launchd.
#
# An agent launchd starts by exec'ing the binary directly does not get served by
# the notification system — every authorization request comes back
# "Notifications are not allowed for this application", and because a refusal is
# permanent per bundle identifier, that one attempt burns the identifier for
# good. Launching through `open` (i.e. through LaunchServices) does prompt
# normally. So: prompt once here, wait for the answer, and only then install the
# LaunchAgent, which from then on merely restarts an already-authorized app.
#
# This runs on every install, not only the first: the answer is read from the
# copy that was just put in place, so a copy that lost its grant is found out
# here rather than by a notification that never appears.
READY="$STATE/ready"

# One prompt round trip: launch through LaunchServices, wait for the agent to
# publish an answer, read it, then stop that instance. Stopping matters twice
# over — leaving it running would make it the incumbent, and the singleton
# guard would then send launchd's instance away, leaving launchd with nothing
# to restart if the agent ever crashes. Read BEFORE stopping: an orderly
# shutdown removes the readiness marker (it must not outlive the process it
# describes), so reading afterwards reports "no answer" for a grant that in
# fact succeeded.
prompt_once() {
    rm -f "$READY"
    open -a "$APP"
    for _ in $(seq 1 120); do
        [[ -s "$READY" ]] && break
        sleep 1
    done
    ANSWER=$(cat "$READY" 2>/dev/null || true)
    pkill -f "/$BUNDLE_NAME/Contents/MacOS/ghostty-notify-agent" 2>/dev/null || true
    sleep 1
}

echo "==> Checking notification permission (a dialog appears the first time)"
echo "    Click Allow. Clicking Don't Allow permanently disables this build's"
echo "    identifier — macOS leaves no System Settings entry to undo it."
prompt_once

# "error" is not the user's answer: the system refused to process the
# request and no dialog ever appeared — seen on a bundle's first contact
# with the notification system, before its registration settles. One
# retry usually lands the dialog; reporting it as DENIED told users their
# identifier was permanently burned when it was nothing of the sort.
if [[ "$ANSWER" == "error" ]]; then
    echo "    macOS did not process the request (no dialog appeared); retrying once"
    sleep 2
    prompt_once
fi

case "$ANSWER" in
    authorized) echo "    granted" ;;
    denied)
        echo "    DENIED — the user declined, so the agent cannot display" >&2
        echo "    notifications. Hooks will keep using the terminal-notifier display fallback." >&2
        ;;
    error)
        echo "    macOS refused the request twice (no dialog was shown)." >&2
        echo "    This is a registration hiccup, not a denial — rerun this script." >&2
        ;;
    *) echo "    no answer yet; the agent will keep running and can be re-asked" >&2 ;;
esac

unload
launchctl bootstrap "$DOMAIN" "$PLIST"

# Installed means running: a LaunchAgent that is loaded but whose process
# never came up looks identical from the outside, and that is how a stale
# path went unnoticed for weeks. Wait for the pidfile launchd's instance
# writes, and name the command that explains a failure.
for _ in $(seq 1 20); do
    [[ -s "$STATE/agent.pid" ]] && break
    sleep 0.5
done
if [[ -s "$STATE/agent.pid" ]] && kill -0 "$(cat "$STATE/agent.pid")" 2>/dev/null; then
    echo "==> Installed $LABEL, running as pid $(cat "$STATE/agent.pid")"
else
    echo "==> Installed $LABEL, but the agent has not started:" >&2
    echo "    launchctl print $DOMAIN/$LABEL" >&2
fi
echo "    app:   $APP"
echo "    plist: $PLIST"
echo "    stop:  bash scripts/install-agent.sh --uninstall"
echo
# The one setting the product needs and no code can set. macOS ignores
# NSUserNotificationAlertStyle for UNUserNotificationCenter apps — verified with a
# fresh bundle identifier carrying the key from first registration — and Apple has
# said the style is not programmatically settable. So: detect it and walk the user
# there, which is what other apps in this position do.
STYLE_FILE="$STATE/alert-style"
for _ in $(seq 1 15); do
    [[ -s "$STYLE_FILE" ]] && break
    sleep 1
done
if [[ "$(cat "$STYLE_FILE" 2>/dev/null)" == "banner" ]]; then
    echo
    echo "==> Notifications are set to Temporary, so they slide away in about five"
    echo "    seconds — and clicking one is how you jump back to the session's tab."
    echo "    Set Alert Style to Persistent in the window that just opened."
    "$BIN" --send '{"type":"style_hint"}' 2>/dev/null || true
fi

echo
echo "On first notification macOS will ask twice:"
echo "  1. permission to send notifications"
echo "  2. permission to control Ghostty (needed for click-to-jump)"
echo "Both are one-time and both must be allowed."
echo
echo "If you use Focus modes, add Claude Ghostty Notify to their allowed apps:"
echo "a Focus that already lets Terminal (an external backend's identity) through"
echo "still sends this app's alerts straight to Notification Center."
