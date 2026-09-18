#!/bin/bash
# Installer for ai-ghostty-notifier.
# Copies the hook scripts into ~/.claude/hooks/ and prints the
# settings.json snippet to merge into the user's config.

set -eu

if [[ "$(uname)" != "Darwin" ]]; then
    echo "❌ macOS only (Ghostty AppleScript-based)." >&2
    exit 1
fi

NATIVE_APP="${GHOSTTY_NOTIFY_NATIVE_APP-$HOME/Library/Application Support/claude-ghostty-notify/ClaudeGhosttyNotify.app}"
if [[ -z "$NATIVE_APP" || ! -f "$NATIVE_APP/Contents/Resources/native-hook-v1" \
    || ! -x "$NATIVE_APP/Contents/MacOS/ghostty-notify-agent" ]]; then
    echo "❌ Required native hook runtime missing or too old. Nothing was installed." >&2
    echo "   Run: bash scripts/build-agent.sh --build-only && bash scripts/install-agent.sh" >&2
    exit 1
fi

if ! command -v terminal-notifier >/dev/null 2>&1; then
    echo "Note: terminal-notifier is not installed (optional display-only fallback)."
    echo "      The resident App must be running and authorized to deliver notifications."
fi

# Resolve the source hooks dir.
# If the script is run from a local git checkout, use that.
# Otherwise (curl | bash path), download from GitHub.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd 2>/dev/null || echo '')"
LOCAL_HOOKS="$SCRIPT_DIR/hooks"

HOOKS_DIR="$HOME/.claude/hooks"
mkdir -p "$HOOKS_DIR"
STAGING=$(mktemp -d "$HOOKS_DIR/.native-install.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
# The shared bootstrap must exist before any newly published launcher uses it.
HOOK_FILES=(native-hook.sh ghostty-tab-save.sh ghostty-tab-focus.sh ghostty-notify.sh ghostty-round-reset.sh ghostty-notify-clear.sh ghostty-agent-anchor.sh)

install_from_local() {
    # Stable launchers and their shared native-runtime bootstrap.
    for f in "${HOOK_FILES[@]}"; do
        cp "$LOCAL_HOOKS/$f" "$STAGING/$f"
    done
}

install_from_github() {
    local RAW="https://raw.githubusercontent.com/Davie521/ai-ghostty-notifier/main/hooks"
    # Stable launchers and their shared native-runtime bootstrap.
    for f in "${HOOK_FILES[@]}"; do
        curl -fsSL "$RAW/$f" -o "$STAGING/$f"
    done
}

if [[ -d "$LOCAL_HOOKS" ]] && [[ -f "$LOCAL_HOOKS/ghostty-tab-save.sh" ]]; then
    echo "Installing hooks (local copy)..."
    install_from_local
else
    echo "Installing hooks (from GitHub)..."
    install_from_github
fi

# Validate every staged file before replacing any registered hook. Per-file
# rename avoids exposing partially copied scripts during an upgrade.
for f in "${HOOK_FILES[@]}"; do
    /bin/bash -n "$STAGING/$f"
    chmod +x "$STAGING/$f"
done
for f in "${HOOK_FILES[@]}"; do
    mv -f "$STAGING/$f" "$HOOKS_DIR/$f"
    echo "  ✓ installed $f"
done

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
        "hooks": [{"type": "command", "command": "/Users/$USER/.claude/hooks/ghostty-tab-save.sh", "timeout": 15}]
      }],
      "UserPromptSubmit": [{
        "hooks": [
          {"type": "command", "command": "/Users/$USER/.claude/hooks/ghostty-round-reset.sh", "timeout": 15}
        ]
      }],
      "Notification": [{
        "matcher": "",
        "hooks": [{"type": "command", "command": "/Users/$USER/.claude/hooks/ghostty-notify.sh", "timeout": 15}]
      }],
      "Stop": [{
        "matcher": "",
        "hooks": [{"type": "command", "command": "/Users/$USER/.claude/hooks/ghostty-notify.sh", "timeout": 15}]
      }]
    }
EOF
echo
echo "   (Replace \$USER with your username — hooks require absolute paths.)"
echo
echo "2. Allow notifications and Ghostty Automation for Claude Ghostty Notify."
echo "   System Settings → Notifications → Claude Ghostty Notify → Persistent."
echo "   External backends, if used, need their own notification permissions."
echo
echo "3. Restart Claude Code so the env vars take effect."
echo "─────────────────────────────────────────────────────────"
