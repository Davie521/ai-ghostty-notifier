#!/usr/bin/env bash
# Build the resident notification agent and assemble it into an .app bundle.
#
# The bundle is not optional packaging: UNUserNotificationCenter refuses to
# serve a process with no bundle identity, and macOS refuses to grant
# notification authorization at all to a bundle living in a temporary directory
# (verified — a bundle under /private/tmp gets an immediate
# "Notifications are not allowed for this application"). So the bundle is
# assembled under the repo, which is a stable, user-owned location.
#
# Nothing here is committed: see .gitignore.

set -euo pipefail

# Building only builds. It never stops the installed service, removes its
# readiness markers or changes LaunchServices registration: a build that did
# left the machine without its notifier until someone ran the installer.
# Deploying is scripts/install-agent.sh, which stops, replaces, registers and
# restarts. --build-only is still accepted, since it is what the docs and CI say.
case "${1:-}" in
    --build-only | "") ;;
    *) echo "usage: build-agent.sh [--build-only]" >&2; exit 2 ;;
esac

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)

APP="$REPO/build/ClaudeGhosttyNotify.app"
CONTENTS="$APP/Contents"
BINARY_NAME="ghostty-notify-agent"

command -v swift >/dev/null 2>&1 || {
    echo "FATAL: swift not found. Install Xcode or the Command Line Tools:" >&2
    echo "  xcode-select --install" >&2
    exit 2
}

echo "==> Building $BINARY_NAME (release)"
swift build -c release --package-path "$REPO/agent"
BUILT=$(swift build -c release --package-path "$REPO/agent" --show-bin-path)/"$BINARY_NAME"
[[ -x "$BUILT" ]] || { echo "FATAL: $BUILT missing after build" >&2; exit 2; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
install -m 755 "$BUILT" "$CONTENTS/MacOS/$BINARY_NAME"
install -m 644 "$REPO/agent/Resources/Info.plist" "$CONTENTS/Info.plist"
install -m 644 "$REPO/agent/Resources/native-hook-v1" "$CONTENTS/Resources/native-hook-v1"

# The icon this notification carries. It used to be Claude's own icon, copied
# out of /Applications/Claude.app — which stopped being honest once the agent
# started serving Codex CLI too, and was never there on a machine with only the
# CLI installed. It is now this project's ghost bell, converted from
# agent/Resources/AppIcon.png (1024x1024, transparent background) at build time:
# a readable PNG in the repo beats a committed binary .icns, and both sips and
# iconutil ship with macOS. Purely cosmetic — a failure here is not an error.
ICON_SRC="$REPO/agent/Resources/AppIcon.png"
if [[ -f "$ICON_SRC" ]]; then
    ICONSET=$(mktemp -d)/AppIcon.iconset
    mkdir -p "$ICONSET"
    icon_ok=1
    for size in 16 32 128 256 512; do
        # Every size twice: macOS picks @2x on Retina, and an .icns missing them
        # gets upscaled from the 1x slice and looks soft in the notification.
        sips -z "$size" "$size" "$ICON_SRC" \
            --out "$ICONSET/icon_${size}x${size}.png" >/dev/null 2>&1 || icon_ok=0
        sips -z $((size * 2)) $((size * 2)) "$ICON_SRC" \
            --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null 2>&1 || icon_ok=0
    done
    if [[ $icon_ok -eq 1 ]] &&
        iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns" 2>/dev/null; then
        :
    else
        echo "  warning: could not build AppIcon.icns; the agent will show a generic icon" >&2
    fi
    rm -rf "$(dirname "$ICONSET")"
else
    echo "  warning: $ICON_SRC missing; the agent will show a generic icon" >&2
fi

# UNNotificationSound resolves a named sound against the app bundle, not against
# /System/Library/Sounds — unlike terminal-notifier, whose vocabulary
# the hooks speak ("Glass", "Ping"). Copy those in so the time-tiered sounds
# actually play; the agent falls back to the system default for anything missing.
for sound in /System/Library/Sounds/*.aiff; do
    [[ -f "$sound" ]] && install -m 644 "$sound" "$CONTENTS/Resources/"
done

# TCC keys its notification and Automation grants to the code signature, so sign
# explicitly rather than relying on the linker's implicit ad-hoc signature.
# Re-signing an unchanged binary keeps the same identity; changing the binary
# does not, which is why a rebuild can re-prompt for permission.
echo "==> Signing (ad-hoc)"
codesign --sign - --force --timestamp=none "$APP" >/dev/null 2>&1 ||
    echo "  warning: codesign failed; the linker's implicit signature will have to do" >&2

echo "==> Built $APP"
