#!/bin/bash
# Installer for claude-ghostty-notify.
# Copies the hook scripts into ~/.claude/hooks/ and prints the
# settings.json snippet to merge into the user's config.

set -eu

if [[ "$(uname)" != "Darwin" ]]; then
    echo "❌ macOS only (Ghostty AppleScript-based)." >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "❌ Missing dependency: jq"
    echo "   Install:  brew install jq"
    exit 1
fi

if ! command -v terminal-notifier >/dev/null 2>&1; then
    echo "⚠️  Missing fallback dependency: terminal-notifier"
    echo "   Install:  brew install terminal-notifier"
    echo "   (needed only where the native agent cannot deliver; the agent is"
    echo "    what gives you click-to-jump — see the README)"
fi

# Resolve the source hooks dir.
# If the script is run from a local git checkout, use that.
# Otherwise (curl | bash path), download from GitHub.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd 2>/dev/null || echo '')"
LOCAL_HOOKS="$SCRIPT_DIR/hooks"

HOOKS_DIR="$HOME/.claude/hooks"
mkdir -p "$HOOKS_DIR"

install_from_local() {
    # agent-common.sh is sourced, not run, but ghostty-notify.sh and the anchor
    # hook both need it beside them; a manual install that skipped it would
    # silently lose the agent path.
    for f in ghostty-tab-save.sh ghostty-notify.sh ghostty-round-reset.sh ghostty-notify-clear.sh agent-common.sh ghostty-agent-anchor.sh; do
        cp "$LOCAL_HOOKS/$f" "$HOOKS_DIR/$f"
        chmod +x "$HOOKS_DIR/$f"
        echo "  ✓ installed $f (local)"
    done
}

install_from_github() {
    local RAW="https://raw.githubusercontent.com/Davie521/claude-ghostty-notify/main/hooks"
    # agent-common.sh is sourced, not run, but ghostty-notify.sh and the anchor
    # hook both need it beside them; a manual install that skipped it would
    # silently lose the agent path.
    for f in ghostty-tab-save.sh ghostty-notify.sh ghostty-round-reset.sh ghostty-notify-clear.sh agent-common.sh ghostty-agent-anchor.sh; do
        curl -fsSL "$RAW/$f" -o "$HOOKS_DIR/$f"
        chmod +x "$HOOKS_DIR/$f"
        echo "  ✓ installed $f (remote)"
    done
}

if [[ -d "$LOCAL_HOOKS" ]] && [[ -f "$LOCAL_HOOKS/ghostty-tab-save.sh" ]]; then
    echo "Installing hooks (local copy)..."
    install_from_local
else
    echo "Installing hooks (from GitHub)..."
    install_from_github
fi

echo
echo "─────────────────────────────────────────────────────────"
echo "Next steps:"
echo
echo "1. Merge the snippet into ~/.claude/settings.json:"
echo
cat <<'EOF'
    "env": {
      "GHOSTTY_NOTIFY_MIN_ELAPSED": "180",
      "GHOSTTY_NOTIFY_SOUND_ELAPSED": "600",
      "GHOSTTY_NOTIFY_TIMEOUT": "1200"
    },
    "hooks": {
      "PreToolUse": [{
        "matcher": "",
        "hooks": [{"type": "command", "command": "/Users/$USER/.claude/hooks/ghostty-tab-save.sh"}]
      }],
      "UserPromptSubmit": [{
        "hooks": [
          {"type": "command", "command": "/Users/$USER/.claude/hooks/ghostty-round-reset.sh"},
          {"type": "command", "command": "/Users/$USER/.claude/hooks/ghostty-agent-anchor.sh"}
        ]
      }],
      "Notification": [{
        "matcher": "",
        "hooks": [{"type": "command", "command": "/Users/$USER/.claude/hooks/ghostty-notify.sh"}]
      }],
      "Stop": [{
        "matcher": "",
        "hooks": [{"type": "command", "command": "/Users/$USER/.claude/hooks/ghostty-notify.sh"}]
      }]
    }
EOF
echo
echo "   (Replace \$USER with your username — hooks require absolute paths.)"
echo
echo "2. Build and install the native agent. It delivers the notification,"
echo "   answers the click and clears it when you come back:"
echo "     bash scripts/build-agent.sh && bash scripts/install-agent.sh"
echo "   Then set Alert Style to Persistent in System Settings >"
echo "   Notifications > Claude Ghostty Notify."
echo
echo "3. Restart Claude Code so the env vars take effect."
echo "─────────────────────────────────────────────────────────"
