#!/usr/bin/env python3
"""Install the Codex CLI hooks locally, preserving unrelated settings.

Copies the shared scripts plus the Codex adapter to ~/.codex/ghostty-notify/,
adds three command hooks to ~/.codex/hooks.json (PreToolUse, UserPromptSubmit,
Stop) and retires the `notify` callback earlier versions of this project
installed — also when another tool has wrapped that callback since. Needs
Python 3.11+ (tomllib) to run; the installed scripts need only bash + jq.
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
    "agent-common.sh",
)
EVENTS = ("PreToolUse", "UserPromptSubmit", "Stop")
DEFAULTS = {
    "GHOSTTY_NOTIFY_MIN_ELAPSED": "180",
    "GHOSTTY_NOTIFY_SOUND_ELAPSED": "600",
    "GHOSTTY_NOTIFY_TIMEOUT": "1200",
    "GHOSTTY_NOTIFY_CLEAR_ON_FOCUS": "1",
}
ADAPTER = "ghostty-notify/codex-hook.sh"
LEGACY_CALLBACK = "ghostty-notify/codex-notify.py"
LEGACY_COMMENT = "# Codex completion notifications in Ghostty (claude-ghostty-notify)"


def hook_command(destination, event):
    return '"{}" {}'.format(destination / "codex-hook.sh", event)


def is_ours(entry):
    return isinstance(entry, dict) and ADAPTER in str(entry.get("command", ""))


def mentions_legacy_callback(arg):
    # A wrapper that embeds our command as a JSON string (Codex Desktop's
    # Computer Use does) escapes every slash, so compare the unescaped form.
    text = str(arg)
    return LEGACY_CALLBACK in text or LEGACY_CALLBACK in text.replace("\\/", "/")


def merged_hooks(existing, destination):
    """hooks.json content with exactly one entry of ours per event; all other
    hooks untouched. Re-running yields the same document."""
    config = dict(existing) if isinstance(existing, dict) else {}
    hooks = config.get("hooks")
    hooks = dict(hooks) if isinstance(hooks, dict) else {}
    for event, groups in list(hooks.items()):
        if not isinstance(groups, list):
            continue
        kept = []
        for group in groups:
            if isinstance(group, dict) and isinstance(group.get("hooks"), list):
                inner = [hook for hook in group["hooks"] if not is_ours(hook)]
                if not inner:
                    continue
                group = {**group, "hooks": inner}
            kept.append(group)
        if kept or event in EVENTS:
            hooks[event] = kept
        else:
            del hooks[event]
    for event in EVENTS:
        hooks.setdefault(event, []).append({"hooks": [{
            "type": "command",
            "command": hook_command(destination, event),
            "timeout": 15,
        }]})
    config["hooks"] = hooks
    return config


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
                             "edit ~/.codex/config.toml by hand")
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
    """Keep Codex's own TUI desktop alert from doubling ours.

    `[tui] notifications = true` covers agent-turn-complete, which is what
    this project delivers; narrow it to approval prompts. An explicit list
    loses just that event. Unset or false is left as it is.
    """
    parsed = tomllib.loads(original)
    tui = parsed.get("tui")
    tui = tui if isinstance(tui, dict) else {}
    value = tui.get("notifications")
    if value is True:
        narrowed = ["approval-requested"]
    elif isinstance(value, list) and "agent-turn-complete" in value:
        narrowed = [event for event in value if event != "agent-turn-complete"]
    else:
        return original
    lines = original.splitlines(keepends=True)
    result = []
    section = ""
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if stripped.startswith("["):
            section = stripped.split("#", 1)[0].strip()
        if section == "[tui]" and re.match(r"^notifications\s*=", stripped):
            end = _assignment_end(lines, i)
            result.append("notifications = " + json.dumps(narrowed) + "\n")
            i = end
            continue
        result.append(line)
        i += 1
    updated = "".join(result)
    expected = dict(parsed)
    expected["tui"] = {**tui, "notifications": narrowed}
    if tomllib.loads(updated) != expected:
        raise ValueError("config migration changed an unrelated setting")
    return updated


def _backup(codex_home, path):
    backup = codex_home / "backups" / "ghostty-notify-{}{}".format(time.time_ns(), path.suffix)
    backup.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, backup)
    backup.chmod(0o600)
    print("Backup: {}".format(backup))


def _replace(path, text, mode):
    temporary = path.with_name(path.name + ".ghostty-notify.tmp")
    temporary.write_text(text)
    temporary.chmod(mode)
    temporary.replace(path)


def install(codex_home, claude_settings):
    destination = codex_home / "ghostty-notify"
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
        settings = DEFAULTS.copy()
        try:
            source = json.loads(claude_settings.read_text()).get("env", {})
            for key in settings:
                if isinstance(source.get(key), (str, int)):
                    settings[key] = str(source[key])
        except (OSError, ValueError, AttributeError):
            pass
        settings_path.write_text(json.dumps(settings, indent=2) + "\n")

    hooks_path = codex_home / "hooks.json"
    existing = {}
    if hooks_path.exists():
        existing = json.loads(hooks_path.read_text())
    updated = merged_hooks(existing, destination)
    if updated != existing:
        if hooks_path.exists():
            _backup(codex_home, hooks_path)
        _replace(hooks_path, json.dumps(updated, indent=2, ensure_ascii=False) + "\n",
                 hooks_path.stat().st_mode & 0o777 if hooks_path.exists() else 0o644)

    config_path = codex_home / "config.toml"
    if config_path.exists():
        original = config_path.read_text()
        migrated = without_tui_turn_alert(without_legacy_notify(original))
        if migrated != original:
            _backup(codex_home, config_path)
            _replace(config_path, migrated, config_path.stat().st_mode & 0o777)

    print("Installed: {}".format(destination))
    print("Hooks:     {}".format(hooks_path))
    print("Settings:  {}".format(settings_path))
    print()
    print("Next: start `codex` in Ghostty and run /hooks to trust the three")
    print("ghostty-notify entries (Codex reviews new or changed hooks once).")
    print("Sessions already running pick the hooks up after a restart.")
    return destination


if __name__ == "__main__":
    if sys.platform != "darwin":
        sys.exit("macOS only")
    codex_root = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))).resolve()
    install(codex_root, Path.home() / ".claude/settings.json")
