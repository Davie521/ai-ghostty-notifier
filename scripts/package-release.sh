#!/usr/bin/env bash
# Package a built (and, for a real release, signed and notarized) bundle into
# the assets a GitHub Release carries:
#
#   ai-ghostty-notifier-macos.zip   the App, the hook launchers and the scripts
#                                   that install them
#   setup.sh                        the one-command installer, which downloads
#                                   the zip above
#   SHA256SUMS                      checksums of both
#
# The asset names carry no version so that
# https://github.com/<repo>/releases/latest/download/<asset> always resolves;
# the version lives in the App's Info.plist and in the release's tag.
#
# Usage: scripts/package-release.sh VERSION [OUT_DIR]
#   VERSION  X.Y.Z; must equal the bundle's CFBundleShortVersionString, so a tag
#            can never publish an App that reports a different version.
#   OUT_DIR  default: dist/

set -euo pipefail

[[ $# -ge 1 && $# -le 2 ]] || { echo "usage: package-release.sh VERSION [OUT_DIR]" >&2; exit 2; }
VERSION=$1
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "FATAL: VERSION must be X.Y.Z, got '$VERSION'" >&2; exit 2; }

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
OUT=${2:-$REPO/dist}
APP="$REPO/build/ClaudeGhosttyNotify.app"
NAME="ai-ghostty-notifier"
ZIP="$NAME-macos.zip"

[[ -x "$APP/Contents/MacOS/ghostty-notify-agent" ]] || {
    echo "FATAL: $APP is missing; run scripts/build-agent.sh first" >&2
    exit 2
}
BUNDLE_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
[[ "$BUNDLE_VERSION" == "$VERSION" ]] || {
    echo "FATAL: the App reports $BUNDLE_VERSION but this release is $VERSION." >&2
    echo "       Bump CFBundleShortVersionString in agent/Resources/Info.plist." >&2
    exit 2
}
codesign --verify --deep --strict "$APP"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
DIST="$STAGE/$NAME"
mkdir -p "$DIST/scripts" "$DIST/hooks"

# ditto, not cp: it keeps the signature, the stapled ticket and extended
# attributes intact.
ditto "$APP" "$DIST/ClaudeGhosttyNotify.app"
cp "$REPO/install.sh" "$REPO/LICENSE" "$DIST/"
cp "$REPO/scripts/install-agent.sh" "$REPO/scripts/install-codex.py" \
    "$REPO/scripts/register-claude-hooks.py" "$DIST/scripts/"
# The launchers only: hooks/bin is local build output, and hooks.json is the
# plugin's registration, which this install path does not use.
for launcher in "$REPO"/hooks/*.sh; do
    cp "$launcher" "$DIST/hooks/"
done
printf '%s\n' "$VERSION" > "$DIST/VERSION"

mkdir -p "$OUT"
rm -f "$OUT/$ZIP" "$OUT/setup.sh" "$OUT/SHA256SUMS"
ditto -c -k --sequesterRsrc --keepParent "$DIST" "$OUT/$ZIP"
cp "$REPO/scripts/setup.sh" "$OUT/setup.sh"
(cd "$OUT" && shasum -a 256 "$ZIP" setup.sh > SHA256SUMS)

echo "==> Packaged $VERSION into $OUT"
(cd "$OUT" && ls -l "$ZIP" setup.sh SHA256SUMS && cat SHA256SUMS)
