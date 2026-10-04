#!/bin/bash
# Bootstrap only. JSON, process/TTY inspection and all policy live in Swift,
# except telling the user when that Swift is missing.
# Sourced by the stable entry filenames so existing hook trust stays valid.

GHOSTTY_NOTIFY_HOOKS_DIR="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)"
export GHOSTTY_NOTIFY_HOOKS_DIR
native_app=""
native_problem=""
native_install_dir="$HOME/Library/Application Support/claude-ghostty-notify"
native_installed="$native_install_dir/ClaudeGhosttyNotify.app"
native_candidates=(
    "${GHOSTTY_NOTIFY_AGENT_APP:-}" \
    "$native_installed" \
    "$GHOSTTY_NOTIFY_HOOKS_DIR/../build/ClaudeGhosttyNotify.app" \
    "$GHOSTTY_NOTIFY_HOOKS_DIR/ClaudeGhosttyNotify.app")
if [[ -n "${GHOSTTY_NOTIFY_NATIVE_APP+set}" ]]; then
    native_candidates=("$GHOSTTY_NOTIFY_NATIVE_APP")
fi
# The installed app is being replaced. scripts/install-agent.sh leaves this
# marker beside it, takes the execute bit off its binary, and waits only for
# what runs that binary. The bit alone would close only that copy: these hooks
# would fall through to a build beside them, starting a process nobody waits
# for — and between the two moves of the bundle there is no installed binary
# to have a bit at all. The marker closes the way in for this HOME.
if [[ -e "$native_install_dir/.admission-closed" ]]; then
    native_candidates=("")
    native_problem="the app is being reinstalled; this hook does nothing until it is back"
fi
for candidate in "${native_candidates[@]}"; do
    [[ -n "$candidate" && -f "$candidate/Contents/Resources/native-hook-v1" \
        && -x "$candidate/Contents/MacOS/ghostty-notify-agent" ]] || continue
    native_app="$candidate"
    break
done
if [[ -n "$native_app" ]]; then
    exec "$native_app/Contents/MacOS/ghostty-notify-agent" "$@"
fi
# A hook's stderr reaches only Claude Code's debug log when it exits 0, so on
# its own this failure is silent: a plugin installed without the app does
# nothing and says nothing. Claude's first prompt in each session says it
# instead, through the systemMessage the CLI shows to the user. Not while the
# app is being reinstalled: that ends by itself.
native_warn=""
if [[ -z "$native_problem" && "${2:-}" == claude && "${3:-}" == UserPromptSubmit ]]; then
    native_warn=1
fi
native_session=""
# Drain even on failure so the CLI never gets EPIPE. No jq or quiet fallback.
if [[ ! -t 0 ]]; then
    while IFS= read -r native_line || [[ -n "$native_line" ]]; do
        if [[ -n "$native_warn" && -z "$native_session" &&
            "$native_line" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([0-9A-Fa-f-]+)\" ]]; then
            native_session="${BASH_REMATCH[1]}"
        fi
    done
fi
printf 'ghostty-notify: %s.\n' "${native_problem:-native runtime missing or too old; build and install ClaudeGhosttyNotify.app}" >&2
if [[ -n "$native_warn" && -n "$native_session" ]]; then
    # Once per session: an empty directory per session id, made atomically,
    # under a private directory the system clears by itself.
    native_seen="${TMPDIR:-/tmp}/ai-ghostty-notifier-$UID"
    if { /bin/mkdir -m 700 "$native_seen" 2>/dev/null || [[ -d "$native_seen" ]]; } &&
        [[ -O "$native_seen" && ! -L "$native_seen" ]] &&
        /bin/mkdir "$native_seen/$native_session" 2>/dev/null; then
        native_state="is not installed"
        [[ -d "$native_installed" ]] && native_state="is too old for this plugin"
        printf '{"systemMessage": "ai-ghostty-notifier: its companion app %s, so no notifications will appear. Install it with: curl -fsSL https://github.com/Davie521/ai-ghostty-notifier/releases/latest/download/setup.sh | bash"}\n' "$native_state"
    fi
fi
exit 0
