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
#
# Release builds take these options; a local build needs none of them:
#   --universal         arm64 and x86_64 in one binary, for Intel Macs too.
#   --sign IDENTITY     sign with a real identity (Developer ID Application for a
#                       release) under the hardened runtime, which notarization
#                       requires. Implies --hardened.
#   --hardened          hardened runtime plus the Apple Events entitlement, even
#                       for an ad-hoc signature: the release configuration, tested
#                       locally without a Developer ID.
#   --no-system-sounds  leave Apple's /System/Library/Sounds out of the bundle. A
#                       published archive must not redistribute them; the agent
#                       falls back to the default notification sound instead.
usage() {
    echo "usage: build-agent.sh [--build-only] [--universal] [--sign IDENTITY] [--hardened] [--no-system-sounds]" >&2
    exit 2
}
UNIVERSAL=0
IDENTITY="-"
HARDENED=0
SYSTEM_SOUNDS=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-only) ;;
        --universal) UNIVERSAL=1 ;;
        --sign)
            [[ $# -ge 2 && -n "$2" ]] || usage
            IDENTITY=$2
            shift
            ;;
        --hardened) HARDENED=1 ;;
        --no-system-sounds) SYSTEM_SOUNDS=0 ;;
        *) usage ;;
    esac
    shift
done
[[ "$IDENTITY" == "-" ]] || HARDENED=1

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

SWIFT_ARGS=(-c release --package-path "$REPO/agent")
if [[ $UNIVERSAL -eq 1 ]]; then
    SWIFT_ARGS+=(--arch arm64 --arch x86_64)
    echo "==> Building $BINARY_NAME (release, universal)"
else
    echo "==> Building $BINARY_NAME (release)"
fi
swift build "${SWIFT_ARGS[@]}"
BUILT=$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)/"$BINARY_NAME"
[[ -x "$BUILT" ]] || { echo "FATAL: $BUILT missing after build" >&2; exit 2; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
install -m 755 "$BUILT" "$CONTENTS/MacOS/$BINARY_NAME"
install -m 644 "$REPO/agent/Resources/Info.plist" "$CONTENTS/Info.plist"
install -m 644 "$REPO/agent/Resources/native-hook-v1" "$CONTENTS/Resources/native-hook-v1"

# The translations. macOS chooses among the bundle's .lproj directories from
# the user's language list, so en.lproj must be there too or a Chinese-only
# bundle would speak Chinese to everyone. UIText in NotifyCore reads them.
for lproj in "$REPO"/agent/Resources/*.lproj; do
    [[ -d "$lproj" ]] || continue
    mkdir -p "$CONTENTS/Resources/$(basename "$lproj")"
    for strings in "$lproj"/*.strings; do
        [[ -f "$strings" ]] || continue
        plutil -lint "$strings" >/dev/null || { echo "FATAL: $strings does not parse" >&2; exit 2; }
        install -m 644 "$strings" "$CONTENTS/Resources/$(basename "$lproj")/"
    done
done

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
if [[ $SYSTEM_SOUNDS -eq 1 ]]; then
    for sound in /System/Library/Sounds/*.aiff; do
        [[ -f "$sound" ]] && install -m 644 "$sound" "$CONTENTS/Resources/"
    done
else
    echo "==> Leaving Apple's system sounds out (--no-system-sounds)"
fi

# TCC keys its notification and Automation grants to the code signature, so sign
# explicitly rather than relying on the linker's implicit ad-hoc signature.
# Re-signing an unchanged binary keeps the same identity; changing the binary
# does not, which is why a rebuild can re-prompt for permission.
if [[ $HARDENED -eq 0 ]]; then
    echo "==> Signing (ad-hoc)"
    codesign --sign - --force --timestamp=none "$APP" >/dev/null 2>&1 ||
        echo "  warning: codesign failed; the linker's implicit signature will have to do" >&2
else
    # A release signature is not optional: an unsigned or half-signed bundle
    # would fail notarization later, or worse, be published. Fail here instead.
    # Under the hardened runtime a process may not send Apple Events at all
    # without com.apple.security.automation.apple-events; lacking it, the
    # in-process AppleScript that binds and focuses Ghostty tabs fails and a
    # click only activates Ghostty. (The entitlements file cannot carry this
    # note itself: AMFI rejects an XML comment before <plist>.)
    ENTITLEMENTS="$REPO/agent/Resources/ClaudeGhosttyNotify.entitlements"
    if [[ "$IDENTITY" == "-" ]]; then
        echo "==> Signing (ad-hoc, hardened runtime)"
        TIMESTAMP=(--timestamp=none)
    else
        echo "==> Signing as \"$IDENTITY\" (hardened runtime)"
        TIMESTAMP=(--timestamp)
    fi
    codesign --sign "$IDENTITY" --force "${TIMESTAMP[@]}" --options runtime \
        --entitlements "$ENTITLEMENTS" "$APP"
    codesign --verify --deep --strict "$APP"
    # grep without -q reads to the end: -q quits at the match, and under
    # pipefail codesign's SIGPIPE would then read as a missing entitlement.
    codesign --display --entitlements - "$APP" 2>/dev/null |
        grep "com.apple.security.automation.apple-events" >/dev/null || {
        echo "FATAL: the signed bundle lacks the Apple Events entitlement" >&2
        exit 2
    }
fi

echo "==> Built $APP"
