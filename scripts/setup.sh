#!/bin/bash
# One-command installer for ai-ghostty-notifier, published with every release:
#
#   curl -fsSL https://github.com/Davie521/ai-ghostty-notifier/releases/latest/download/setup.sh | bash
#
# Downloads the release archive, checks it against the release's SHA256SUMS,
# checks the App's signature and that Gatekeeper accepts it (Developer ID,
# notarized), then installs:
#   1. the App, into ~/Library/Application Support/claude-ghostty-notify/, with
#      its LaunchAgent (scripts/install-agent.sh);
#   2. the Claude Code hooks, merged into settings.json (install.sh
#      --register-settings), when Claude Code is present;
#   3. the Codex CLI hooks (scripts/install-codex.py), when Codex is present and
#      a Python 3.11+ is available.
# Nothing is compiled; no Swift toolchain is needed.
#
# Options (pass them after `bash -s --` when piping):
#   --version X.Y.Z       install that release instead of the latest
#   --no-start            install the App without its LaunchAgent or prompts
#   --claude / --no-claude, --codex / --no-codex
#                         force either set of hooks on or off (default: detect)
#   --uninstall           remove the App and its LaunchAgent; hooks stay
#                         registered and are listed so they can be removed
#   --allow-unnotarized   accept a bundle Gatekeeper rejects (testing a local
#                         or dry-run build only; never for a real install)
#
# Written for /bin/bash 3.2, the one macOS ships, and for `curl | bash`: the
# whole script is a function, so bash has read all of it before any command
# runs, and every child gets /dev/null as stdin, so none can swallow the rest
# of the script from the pipe.

main() {
    set -euo pipefail

    local repo_slug="Davie521/ai-ghostty-notifier"
    local asset="ai-ghostty-notifier-macos.zip"
    local base="${GHOSTTY_NOTIFY_RELEASE_URL:-https://github.com/$repo_slug/releases}"
    local version="" start_flag="" claude="auto" codex="auto" uninstall=0 require_notarized=1

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version)
                [[ $# -ge 2 ]] || die "--version needs X.Y.Z"
                version=${2#v}
                shift
                ;;
            --no-start) start_flag="--no-start" ;;
            --claude) claude="yes" ;;
            --no-claude) claude="no" ;;
            --codex) codex="yes" ;;
            --no-codex) codex="no" ;;
            --uninstall) uninstall=1 ;;
            --allow-unnotarized) require_notarized=0 ;;
            *) die "unknown option: $1" ;;
        esac
        shift
    done

    [[ "$(uname)" == Darwin ]] || die "macOS only."
    local macos_major
    macos_major=$(sw_vers -productVersion | cut -d. -f1)
    [[ "$macos_major" -ge 13 ]] || die "macOS 13 or later is required."
    if [[ ! -d /Applications/Ghostty.app && ! -d "$HOME/Applications/Ghostty.app" ]]; then
        echo "Note: Ghostty was not found in /Applications. Notifications need it to jump back to a tab."
    fi

    local tmp
    tmp=$(mktemp -d)
    # shellcheck disable=SC2064  # expand now: $tmp is local and gone by EXIT
    trap "rm -rf '$tmp'" EXIT

    local url_prefix
    if [[ -n "$version" ]]; then
        url_prefix="$base/download/v$version"
    else
        url_prefix="$base/latest/download"
    fi

    step "Downloading ${version:+v$version }from $url_prefix"
    fetch "$url_prefix/$asset" "$tmp/$asset"
    fetch "$url_prefix/SHA256SUMS" "$tmp/SHA256SUMS"

    step "Checking the archive against SHA256SUMS"
    local expected
    expected=$(awk -v name="$asset" '$2 == name || $2 == "*" name { print $1 }' "$tmp/SHA256SUMS")
    [[ -n "$expected" ]] || die "SHA256SUMS has no entry for $asset."
    local actual
    actual=$(shasum -a 256 "$tmp/$asset" | awk '{ print $1 }')
    [[ "$actual" == "$expected" ]] || die "checksum mismatch for $asset (expected $expected, got $actual). Nothing was installed."

    ditto -x -k "$tmp/$asset" "$tmp/unpacked" </dev/null
    local dist="$tmp/unpacked/ai-ghostty-notifier"
    local app="$dist/ClaudeGhosttyNotify.app"
    [[ -d "$app" && -f "$dist/install.sh" ]] || die "the archive does not contain the expected files."
    echo "    release $(cat "$dist/VERSION" 2>/dev/null || echo "(unknown version)")"

    step "Checking the App's signature"
    codesign --verify --deep --strict "$app" </dev/null || die "the App's signature does not verify. Nothing was installed."
    # Two separate facts. Who signed it comes from the signature itself; whether
    # Apple notarized it only Gatekeeper can say (codesign does not report it),
    # and a Mac with assessments disabled cannot say at all.
    local authority assessment
    authority=$(codesign -dvv "$app" 2>&1 </dev/null | awk -F= '/^Authority=/ { print $2; exit }')
    assessment=$(spctl --assess --type execute --verbose=2 "$app" 2>&1 </dev/null || true)
    if [[ "$authority" == "Developer ID Application:"* && "$assessment" == *"source=Notarized Developer ID"* ]]; then
        echo "    $authority, notarized"
    elif [[ "$authority" == "Developer ID Application:"* ]] &&
        spctl --status 2>/dev/null </dev/null | grep -q "assessments disabled"; then
        echo "    $authority"
        echo "    Gatekeeper is disabled on this Mac, so notarization could not be checked."
    elif [[ $require_notarized -eq 1 ]]; then
        die "this App is not a notarized Developer ID build (signed by: ${authority:-ad-hoc}). Nothing was installed."
    else
        echo "    WARNING: not a notarized Developer ID build (signed by: ${authority:-ad-hoc});"
        echo "    installing anyway because of --allow-unnotarized"
    fi

    if [[ $uninstall -eq 1 ]]; then
        step "Removing the App and its LaunchAgent"
        bash "$dist/scripts/install-agent.sh" --uninstall </dev/null
        echo
        echo "Hooks are still registered. Remove this project's entries from"
        echo "  ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json (commands ending in ghostty-*.sh)"
        echo "  ${CODEX_HOME:-$HOME/.codex}/hooks.json (commands containing ghostty-notify/codex-hook.sh)"
        echo "then restart open Claude Code / Codex sessions."
        return 0
    fi

    step "Installing the App"
    # shellcheck disable=SC2086  # start_flag is empty or one word
    GHOSTTY_NOTIFY_INSTALL_FROM="$app" bash "$dist/scripts/install-agent.sh" $start_flag </dev/null

    local claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    if [[ "$claude" == "yes" || ( "$claude" == "auto" && ( -d "$claude_dir" || -n "$(command -v claude || true)" ) ) ]]; then
        step "Registering the Claude Code hooks in $claude_dir"
        GHOSTTY_NOTIFY_FROM_SETUP=1 bash "$dist/install.sh" --register-settings </dev/null
    else
        echo "Claude Code not found; skipping its hooks (rerun with --claude to force)."
    fi

    local codex_dir="${CODEX_HOME:-$HOME/.codex}"
    local codex_registered=0
    if [[ "$codex" == "yes" || ( "$codex" == "auto" && ( -d "$codex_dir" || -n "$(command -v codex || true)" ) ) ]]; then
        step "Registering the Codex CLI hooks in $codex_dir"
        local python
        python=$(python311)
        if [[ -n "$python" ]]; then
            "$python" "$dist/scripts/install-codex.py" </dev/null
            codex_registered=1
        else
            echo "    Skipped: the Codex installer needs Python 3.11+ and none was found."
            echo "    Install one (brew install python) and rerun this command with --codex."
        fi
    else
        echo "Codex CLI not found; skipping its hooks (rerun with --codex to force)."
    fi

    echo
    echo "─────────────────────────────────────────────────────────"
    echo "Installed. What only you can do:"
    echo "  1. Allow notifications for Claude Ghostty Notify when macOS asks, and"
    echo "     choose Persistent under System Settings → Notifications to keep the"
    echo "     alert and its Go to tab button on screen."
    echo "  2. Allow it to control Ghostty the first time you click a notification."
    echo "  3. Allow it in any Focus mode you use, or alerts go straight to"
    echo "     Notification Center."
    if [[ $codex_registered -eq 1 ]]; then
        echo "  4. Start Codex in Ghostty, run /hooks and trust the new entries."
    fi
    echo "  Then restart the Claude Code / Codex sessions you already have open."
    echo "─────────────────────────────────────────────────────────"
}

die() {
    echo "setup.sh: $*" >&2
    exit 1
}

step() {
    echo
    echo "==> $*"
}

fetch() {
    curl -fsSL --retry 3 --retry-delay 2 -o "$2" "$1" </dev/null || die "download failed: $1"
}

# The first Python 3.11+ on PATH: install-codex.py needs tomllib, and the
# /usr/bin/python3 macOS ships is 3.9.
python311() {
    local candidate
    for candidate in python3.14 python3.13 python3.12 python3.11 python3; do
        if command -v "$candidate" >/dev/null 2>&1 &&
            "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' </dev/null 2>/dev/null; then
            command -v "$candidate"
            return 0
        fi
    done
    return 0
}

main "$@"
