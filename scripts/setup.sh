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
#   --uninstall           remove the App and its LaunchAgent, downloading
#                         nothing; hooks stay registered and are listed so they
#                         can be removed
#   --allow-unnotarized   install although Gatekeeper did not confirm a
#                         notarized Developer ID build: a local or dry-run build
#                         under test, or a Mac with Gatekeeper switched off
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

    if [[ $uninstall -eq 1 ]]; then
        uninstall_app
        return 0
    fi
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
    # Apple notarized it only Gatekeeper can say (codesign does not report it).
    # A Mac with Gatekeeper switched off may not say either; the way past that
    # is --allow-unnotarized, on purpose, not a quiet exception.
    local authority assessment
    # awk reads to the end rather than exiting at the first match: under
    # pipefail, codesign still writing into a closed pipe dies of SIGPIPE, and
    # set -e would end this script there, silently and before installing.
    authority=$(codesign -dvv "$app" 2>&1 </dev/null | awk -F= '/^Authority=/ && !seen { print $2; seen = 1 }')
    assessment=$(spctl --assess --type execute --verbose=2 "$app" 2>&1 </dev/null || true)
    if [[ "$authority" == "Developer ID Application:"* && "$assessment" == *"source=Notarized Developer ID"* ]]; then
        echo "    $authority, notarized"
    elif [[ $require_notarized -eq 1 ]]; then
        die "this App is not a notarized Developer ID build, as far as Gatekeeper can tell (signed by: ${authority:-ad-hoc}). Nothing was installed. On a Mac with Gatekeeper switched off, rerun with --allow-unnotarized."
    else
        echo "    WARNING: Gatekeeper did not confirm a notarized Developer ID build (signed by: ${authority:-ad-hoc});"
        echo "    installing anyway because of --allow-unnotarized"
    fi

    step "Installing the App"
    # shellcheck disable=SC2086  # start_flag is empty or one word
    # GHOSTTY_NOTIFY_FROM_SETUP: the installers leave their own next-steps out;
    # this script prints one list at the end, from what they actually found.
    GHOSTTY_NOTIFY_FROM_SETUP=1 GHOSTTY_NOTIFY_INSTALL_FROM="$app" \
        bash "$dist/scripts/install-agent.sh" $start_flag </dev/null

    local claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" claude_doubled=0
    if [[ "$claude" == "yes" || ( "$claude" == "auto" && ( -d "$claude_dir" || -n "$(command -v claude || true)" ) ) ]]; then
        step "Registering the Claude Code hooks in $claude_dir"
        GHOSTTY_NOTIFY_FROM_SETUP=1 bash "$dist/install.sh" --register-settings </dev/null
        # Claude Code's own desktop notification runs alongside these hooks,
        # about a minute after every reply, unless its channel says otherwise.
        case "$(claude_channel "$claude_dir" "${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json")" in
            terminal_bell | notifications_disabled) ;;
            *) claude_doubled=1 ;;
        esac
    else
        echo "Claude Code not found; skipping its hooks (rerun with --claude to force)."
    fi

    local codex_dir="${CODEX_HOME:-$HOME/.codex}"
    local codex_hooks_changed=0
    if [[ "$codex" == "yes" || ( "$codex" == "auto" && ( -d "$codex_dir" || -n "$(command -v codex || true)" ) ) ]]; then
        step "Registering the Codex CLI hooks in $codex_dir"
        local python before after
        python=$(python311)
        if [[ -n "$python" ]]; then
            # Codex asks the user to trust a hook entry only when its definition
            # in hooks.json is new or changed; an unchanged file needs nothing.
            before=$(shasum -a 256 "$codex_dir/hooks.json" 2>/dev/null || true)
            "$python" "$dist/scripts/install-codex.py" </dev/null
            after=$(shasum -a 256 "$codex_dir/hooks.json" 2>/dev/null || true)
            [[ "$before" == "$after" ]] || codex_hooks_changed=1
        else
            echo "    Skipped: the Codex installer needs Python 3.11+ and none was found."
            echo "    Install one (brew install python) and rerun this command with --codex."
        fi
    else
        echo "Codex CLI not found; skipping its hooks (rerun with --codex to force)."
    fi

    # What is left is what the installer could not settle. install-agent.sh
    # asked for notification permission and recorded the answer; the agent
    # recorded the alert style it found. Both are per user, not per config dir.
    local state="$HOME/.claude/notifications/ghostty-agent" answer style n=1
    local agent_bin="$HOME/Library/Application Support/claude-ghostty-notify/ClaudeGhosttyNotify.app/Contents/MacOS/ghostty-notify-agent"
    answer=$(cat "$state/ready" 2>/dev/null || true)
    style=$(cat "$state/alert-style" 2>/dev/null || true)
    # Proof that delivery works, while the user is still at the screen: a task
    # under the minimum duration never notifies, so the quick prompt people
    # send to try an install would otherwise get nothing and look broken.
    if [[ -z "$start_flag" && "$answer" == authorized ]]; then
        step "Sending a test notification"
        "$agent_bin" --test </dev/null 2>&1 | sed 's/^/    /' || true
    fi
    echo
    echo "─────────────────────────────────────────────────────────"
    echo "Installed. What only you can do:"
    if [[ "$answer" != authorized ]]; then
        echo "  $n. Allow notifications for AI Ghostty Notifier when macOS asks."
        n=$((n + 1))
    fi
    if [[ "$style" != alert ]]; then
        echo "  $n. Choose Persistent under System Settings → Notifications → AI Ghostty"
        echo "     Notifier, so the alert and its Go to tab button stay on screen."
        n=$((n + 1))
    fi
    echo "  $n. Allow it to control Ghostty if macOS asks the first time you click a"
    echo "     notification."
    n=$((n + 1))
    echo "  $n. Allow it in any Focus mode you use, or alerts go straight to"
    echo "     Notification Center."
    n=$((n + 1))
    if [[ $codex_hooks_changed -eq 1 ]]; then
        echo "  $n. Start Codex in Ghostty, run /hooks and trust the new entries."
    fi
    echo "  Then restart the Claude Code / Codex sessions you already have open."
    echo
    if [[ $claude_doubled -eq 1 ]]; then
        echo "Claude Code also shows its own banner about a minute after a reply you"
        echo "have not typed after, so a long run can bring two. For one, add"
        echo "  \"preferredNotifChannel\": \"terminal_bell\""
        echo "to $claude_dir/settings.json: its own alerts then ring the terminal bell."
        echo
    fi
    echo "The ghost in the menu bar lists the sessions waiting on you. On a Mac with a"
    echo "notch, macOS hides menu bar icons that do not fit, without saying so."
    echo
    echo "Only tasks that run 3 minutes or longer notify you, so a quick prompt to"
    echo "try it gets nothing. To check the install at any time:"
    echo "  \"$agent_bin\" --test"
    echo
    echo "To remove the App later, run the same command with --uninstall:"
    echo "  curl -fsSL https://github.com/$repo_slug/releases/latest/download/setup.sh | bash -s -- --uninstall"
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

# What scripts/install-agent.sh --uninstall does, without the download that
# only an install needs. The label and the directory are the installer's;
# tests/test_release_setup.py installs with one and uninstalls with the other,
# so they cannot drift apart unnoticed.
uninstall_app() {
    local label="io.github.davie521.cgnotify"
    local plist="$HOME/Library/LaunchAgents/$label.plist"
    local install_dir="$HOME/Library/Application Support/claude-ghostty-notify"
    step "Removing the App and its LaunchAgent"
    local lsregister=${GHOSTTY_NOTIFY_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null </dev/null || true
    pkill -f "/ClaudeGhosttyNotify.app/Contents/MacOS/ghostty-notify-agent" 2>/dev/null </dev/null || true
    rm -f "$plist"
    # Every registered copy, as install-agent.sh --uninstall does: with the app
    # gone, a registration left anywhere is what a click on an old
    # notification would start. Read to the end, or pipefail sees SIGPIPE.
    if [[ -x "$lsregister" ]]; then
        local copy
        while IFS= read -r copy; do
            "$lsregister" -u "$copy" >/dev/null 2>&1 </dev/null || true
        done < <("$lsregister" -dump 2>/dev/null </dev/null | awk -v id="$label" '
            /^-+$/ { path = "" }
            /^path:/ { path = $0; sub(/^path:[ \t]*/, "", path); sub(/ \(0x[0-9a-fA-F]+\)$/, "", path) }
            $1 == "identifier:" && $2 == id && path != "" { print path; path = "" }')
    fi
    rm -rf "$install_dir"
    echo "    removed $install_dir"
    echo
    echo "Hooks are still registered. Remove this project's entries from"
    echo "  ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json (commands ending in ghostty-*.sh)"
    echo "  ${CODEX_HOME:-$HOME/.codex}/hooks.json (commands containing ghostty-notify/codex-hook.sh)"
    echo "then restart open Claude Code / Codex sessions."
}

# The channel Claude Code alerts through: from <config dir>/settings.json, then
# the global config ($2), which is ~/.claude.json, or .claude.json inside
# CLAUDE_CONFIG_DIR when that is set. Empty when neither sets one. plutil reads
# JSON as it is, so this needs no Python, and an unreadable file only means
# "not set".
claude_channel() {
    local file value
    for file in "$1/settings.json" "$2"; do
        value=$(plutil -extract preferredNotifChannel raw -o - "$file" 2>/dev/null </dev/null) || continue
        printf '%s\n' "$value"
        return 0
    done
    return 0
}

# The python3 on PATH, when it is 3.11 or newer: install-codex.py needs
# tomllib, and the /usr/bin/python3 macOS ships is 3.9. Empty otherwise.
python311() {
    if command -v python3 >/dev/null 2>&1 &&
        python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' </dev/null 2>/dev/null; then
        command -v python3
    fi
    return 0
}

main "$@"
