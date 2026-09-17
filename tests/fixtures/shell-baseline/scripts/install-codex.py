#!/usr/bin/env python3
"""Install the Codex CLI hooks locally, preserving unrelated settings.

Copies the shared scripts plus the Codex adapter to ~/.codex/ghostty-notify/,
adds two command hooks to ~/.codex/hooks.json (UserPromptSubmit, Stop) and
retires what earlier versions installed: the PreToolUse entry and the
`notify` callback — also when another tool has wrapped that callback since.
Every change is computed before anything is written, so a config the
migration cannot handle aborts with nothing touched. Needs Python 3.11+
(tomllib) to run; the installed scripts need only bash + jq.
"""

import json
import os
from pathlib import Path
import re
import shutil
import sys
import time
import tomllib


REPO = Path(__file__).resolve().parent.parent
FILES = (
    "codex-hook.sh", "ghostty-tab-save.sh", "ghostty-tab-focus.sh",
    "ghostty-notify.sh", "ghostty-notify-clear.sh", "ghostty-round-reset.sh",
    "agent-common.sh", "ghostty-agent-anchor.sh",
    "hook-common.sh", "legacy-notify.sh", "legacy-codex-hook.sh", "legacy-round-reset.sh",
)
EVENTS = ("UserPromptSubmit", "Stop")
DEFAULTS = {
    "GHOSTTY_NOTIFY_MIN_ELAPSED": "180",
    "GHOSTTY_NOTIFY_SOUND_ELAPSED": "600",
    "GHOSTTY_NOTIFY_TIMEOUT": "1200",
    "GHOSTTY_NOTIFY_CLEAR_ON_FOCUS": "1",
}
# Knobs that describe Claude's own install rather than a preference; never
# copied from settings.json (the adapter sets the identity ones itself).
PRIVATE_KEYS = {
    "GHOSTTY_NOTIFY_PROCESS_NAME", "GHOSTTY_NOTIFY_APP_NAME", "GHOSTTY_NOTIFY_AGENT_APP",
    "GHOSTTY_NOTIFY_SESSION_DIR", "GHOSTTY_NOTIFY_RATE_DIR", "GHOSTTY_NOTIFY_GROUP_PREFIX",
    "GHOSTTY_NOTIFY_FOCUS_SCRIPT", "GHOSTTY_NOTIFY_CLEAR_SCRIPT", "GHOSTTY_NOTIFY_TTY",
    "GHOSTTY_NOTIFY_MARKER_RETRY_DELAYS", "GHOSTTY_NOTIFY_CODEX_SETTLE",
}
ADAPTER = "ghostty-notify/codex-hook.sh"
LEGACY_CALLBACK = "ghostty-notify/codex-notify.py"
LEGACY_COMMENT = "# Codex completion notifications in Ghostty (claude-ghostty-notify)"
# Codex's own TUI desktop alerts, minus agent-turn-complete (that is what
# this project delivers, on its own threshold).
TUI_ALERTS_KEPT = ["approval-requested", "plan-mode-prompt"]
ALERTER_PATHS = ("/opt/homebrew/bin/alerter", "/usr/local/bin/alerter",
                 str(Path.home() / ".local/bin/alerter"))


def hook_command(destination, event):
    return '"{}" {}'.format(destination / "codex-hook.sh", event)


def our_handler(destination, event):
    # Codex hashes this definition into the hook's trust record: change it
    # and every user has to trust the entry again in /hooks.
    return {"type": "command", "command": hook_command(destination, event), "timeout": 15}


def is_ours(entry):
    return isinstance(entry, dict) and ADAPTER in str(entry.get("command", ""))


def mentions_legacy_callback(arg):
    # A wrapper that embeds our command as a JSON string (Codex Desktop's
    # Computer Use does) escapes every slash, so compare the unescaped form.
    text = str(arg)
    return LEGACY_CALLBACK in text or LEGACY_CALLBACK in text.replace("\\/", "/")


def _foreign_positions(groups):
    positions = {}
    for group_index, group in enumerate(groups):
        if isinstance(group, dict) and isinstance(group.get("hooks"), list):
            for handler_index, handler in enumerate(group["hooks"]):
                if not is_ours(handler):
                    positions[id(handler)] = (group_index, handler_index)
    return positions


def merged_hooks(existing, destination):
    """Return (hooks.json content, events whose other hooks moved).

    Codex keys a hook's trust by its position (event:group:handler) plus a
    hash of the definition it finds there, so entries are updated in place:
    ours are rewritten where they already are and appended only when absent,
    and everything else keeps its slot. Removing a retired entry of ours can
    still shift what followed it; those events are reported so the caller
    can say which hooks need another look in /hooks.
    """
    config = dict(existing) if isinstance(existing, dict) else {}
    hooks = config.get("hooks")
    hooks = dict(hooks) if isinstance(hooks, dict) else {}
    renumbered = []
    placed = set()
    for event in list(hooks):
        groups = hooks[event]
        if not isinstance(groups, list):
            continue
        before = _foreign_positions(groups)
        kept = []
        for group in groups:
            if not (isinstance(group, dict) and isinstance(group.get("hooks"), list)):
                kept.append(group)
                continue
            handlers = []
            for handler in group["hooks"]:
                if not is_ours(handler):
                    handlers.append(handler)
                elif event in EVENTS and event not in placed:
                    placed.add(event)
                    handlers.append(our_handler(destination, event))
            if handlers:
                kept.append({**group, "hooks": handlers})
        if any(_foreign_positions(kept).get(key) != position for key, position in before.items()):
            renumbered.append(event)
        if kept or event in EVENTS:
            hooks[event] = kept
        else:
            del hooks[event]
    for event in EVENTS:
        if event not in placed:
            hooks.setdefault(event, []).append({"hooks": [our_handler(destination, event)]})
    config["hooks"] = hooks
    return config, renumbered


def _assignment_end(lines, start):
    """Index one past the (possibly multi-line) TOML assignment at lines[start]."""
    assignment = lines[start]
    end = start + 1
    while True:
        try:
            tomllib.loads(assignment)
            return end
        except tomllib.TOMLDecodeError:
            if end == len(lines):
                raise
            assignment += lines[end]
            end += 1


def without_legacy_notify(original):
    """Drop the notify callback earlier versions installed.

    Bare `notify = [python3, .../codex-notify.py]` is deleted. When another
    tool has since wrapped it (`--previous-notify '[...codex-notify.py]'`),
    only that pair is removed so the other tool keeps its own callback. Any
    notify command that never mentions our callback is left alone.
    """
    parsed = tomllib.loads(original)
    notify = parsed.get("notify")
    if notify is None:
        return original
    args = notify if isinstance(notify, list) else [notify]
    if not any(mentions_legacy_callback(arg) for arg in args):
        return original
    replacement = None
    if isinstance(notify, list) and not (len(notify) == 2 and mentions_legacy_callback(notify[1])):
        remaining = []
        skip = False
        for index, arg in enumerate(notify):
            if skip:
                skip = False
                continue
            if arg == "--previous-notify" and index + 1 < len(notify) \
                    and mentions_legacy_callback(notify[index + 1]):
                skip = True
                continue
            remaining.append(arg)
        if any(mentions_legacy_callback(arg) for arg in remaining):
            raise ValueError("cannot separate the legacy callback from `notify`; "
                             "edit config.toml by hand")
        replacement = remaining
    lines = original.splitlines(keepends=True)
    result = []
    section = ""
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if stripped.startswith("["):
            section = stripped.split("#", 1)[0].strip()
        if stripped == LEGACY_COMMENT:
            i += 1
            continue
        if not section and re.match(r"^notify\s*=", stripped):
            end = _assignment_end(lines, i)
            if replacement is not None:
                result.append("notify = " + json.dumps(replacement, ensure_ascii=False) + "\n")
            i = end
            continue
        result.append(line)
        i += 1
    updated = "".join(result)
    expected = dict(parsed)
    if replacement is None:
        expected.pop("notify", None)
    else:
        expected["notify"] = replacement
    if tomllib.loads(updated) != expected:
        raise ValueError("config migration changed an unrelated setting")
    return updated


def without_tui_turn_alert(original):
    """Keep Codex's own TUI completion alert from doubling ours.

    `[tui] notifications` unset or `true` means every alert kind, including
    agent-turn-complete; it becomes the explicit list of the other kinds, so
    approval and plan-mode prompts still surface. An explicit list loses just
    that one event. `false` and lists without it are left as they are.
    """
    parsed = tomllib.loads(original)
    tui = parsed.get("tui")
    tui = tui if isinstance(tui, dict) else {}
    value = tui.get("notifications")
    if value is None or value is True:
        narrowed = list(TUI_ALERTS_KEPT)
    elif isinstance(value, list) and "agent-turn-complete" in value:
        narrowed = [event for event in value if event != "agent-turn-complete"]
    else:
        return original
    assignment = "notifications = " + json.dumps(narrowed) + "\n"
    lines = original.splitlines(keepends=True)
    result = []
    section = ""
    written = False
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if stripped.startswith("["):
            section = stripped.split("#", 1)[0].strip()
            result.append(line)
            i += 1
            if section == "[tui]" and value is None and not written:
                result.append(assignment)
                written = True
            continue
        if section == "[tui]" and not written and re.match(r"^notifications\s*=", stripped):
            end = _assignment_end(lines, i)
            result.append(assignment)
            written = True
            i = end
            continue
        result.append(line)
        i += 1
    if not written:
        if result and not result[-1].endswith("\n"):
            result.append("\n")
        result.append("\n[tui]\n" + assignment)
    updated = "".join(result)
    expected = dict(parsed)
    expected["tui"] = {**tui, "notifications": narrowed}
    if tomllib.loads(updated) != expected:
        raise ValueError("config migration changed an unrelated setting")
    return updated


def _backup(codex_home, path):
    backup = codex_home / "backups" / "ghostty-notify-{}{}".format(time.time_ns(), path.suffix)
    backup.parent.mkdir(parents=True, exist_ok=True)
    # Created private from the start: config.toml can carry MCP secrets.
    descriptor = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(path.read_bytes())
    print("Backup: {}".format(backup))


def _replace(path, text, default_mode):
    """Atomically replace the file's content, following a symlink to its
    target (a dotfiles link must keep pointing at the dotfiles copy) and
    never exposing the content at a wider mode than the file already has."""
    target = path.resolve() if path.is_symlink() else path
    mode = target.stat().st_mode & 0o777 if target.exists() else default_mode
    temporary = target.with_name(target.name + ".ghostty-notify.tmp")
    temporary.unlink(missing_ok=True)
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write(text)
        os.chmod(temporary, mode)
        os.replace(temporary, target)
    finally:
        temporary.unlink(missing_ok=True)


def _initial_settings(claude_settings):
    settings = DEFAULTS.copy()
    try:
        source = json.loads(claude_settings.read_text()).get("env", {})
    except (OSError, ValueError, AttributeError):
        return settings
    if not isinstance(source, dict):
        return settings
    for key, value in source.items():
        if key.startswith("GHOSTTY_NOTIFY_") and key not in PRIVATE_KEYS \
                and isinstance(value, (str, int)) and not isinstance(value, bool):
            settings[key] = str(value)
    return settings


def install(codex_home, claude_settings):
    if shutil.which("jq") is None:
        raise SystemExit("jq is required by the hooks (brew install jq); nothing was installed.")
    if shutil.which("alerter") is None and not any(os.access(p, os.X_OK) for p in ALERTER_PATHS):
        if shutil.which("terminal-notifier") is None:
            print("Warning: neither alerter nor terminal-notifier is installed; "
                  "no notification can be shown until one is (brew install alerter).")
        else:
            print("Note: alerter is not installed; terminal-notifier will show the "
                  "alerts but cannot offer the Go to tab button (brew install alerter).")

    destination = codex_home / "ghostty-notify"
    hooks_path = codex_home / "hooks.json"
    config_path = codex_home / "config.toml"

    # ── Compute everything first; nothing below this block may raise. ──
    existing = {}
    if hooks_path.exists():
        try:
            existing = json.loads(hooks_path.read_text())
        except ValueError as error:
            raise SystemExit("{} is not valid JSON ({}); nothing was changed.".format(hooks_path, error))
    merged, renumbered = merged_hooks(existing, destination)
    original = config_path.read_text() if config_path.exists() else None
    migrated = original
    if original is not None:
        try:
            migrated = without_tui_turn_alert(without_legacy_notify(original))
        except (tomllib.TOMLDecodeError, ValueError) as error:
            raise SystemExit(
                "{} could not be migrated ({}); nothing was changed. Remove the old "
                "`notify` callback and narrow `[tui] notifications` by hand, then rerun."
                .format(config_path, error))

    destination.mkdir(parents=True, exist_ok=True)
    for name in FILES:
        target = destination / name
        temporary = destination / (name + ".tmp")
        shutil.copy2(REPO / "hooks" / name, temporary)
        temporary.chmod(0o755)
        temporary.replace(target)
    # The notify-callback adapter of earlier versions; a leftover copy would
    # only mislead anyone reading the directory.
    (destination / "codex-notify.py").unlink(missing_ok=True)

    settings_path = destination / "config.json"
    if not settings_path.exists():
        settings_path.write_text(json.dumps(_initial_settings(claude_settings), indent=2) + "\n")

    if merged != existing:
        if hooks_path.exists():
            _backup(codex_home, hooks_path)
        _replace(hooks_path, json.dumps(merged, indent=2, ensure_ascii=False) + "\n", 0o644)
    if migrated != original:
        _backup(codex_home, config_path)
        _replace(config_path, migrated, 0o600)

    print("Installed: {}".format(destination))
    print("Hooks:     {}".format(hooks_path))
    print("Settings:  {}".format(settings_path))
    if renumbered:
        print()
        print("Removing a retired entry moved other hooks under {}. Codex keys hook trust "
              "by position, so those now need another look in /hooks.".format(", ".join(renumbered)))
    print()
    print("Next: start `codex` in Ghostty and run /hooks to trust the ghostty-notify")
    print("entries Codex has not seen before (only new or changed ones ask).")
    print("Sessions already running pick the hooks up after a restart.")
    return destination


if __name__ == "__main__":
    if sys.platform != "darwin":
        sys.exit("macOS only")
    codex_root = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))).resolve()
    install(codex_root, Path.home() / ".claude/settings.json")
