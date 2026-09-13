#!/usr/bin/env python3
"""Install the Codex callback locally, preserving unrelated TOML settings."""

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
    "codex-notify.py", "ghostty-tab-save.sh", "ghostty-tab-focus.sh",
    "ghostty-notify.sh", "ghostty-notify-clear.sh", "agent-common.sh",
)
DEFAULTS = {
    "GHOSTTY_NOTIFY_MIN_ELAPSED": "180",
    "GHOSTTY_NOTIFY_SOUND_ELAPSED": "600",
    "GHOSTTY_NOTIFY_TIMEOUT": "1200",
    "GHOSTTY_NOTIFY_CLEAR_ON_FOCUS": "1",
}
COMMENT = "# Codex completion notifications in Ghostty (claude-ghostty-notify)"


def updated_config(original, command):
    parsed = tomllib.loads(original)
    previous = parsed.get("notify")
    if previous and previous != command:
        if not any("code-notify" in str(arg) or "codex-notify.py" in str(arg)
                   for arg in (previous if isinstance(previous, list) else [previous])):
            raise ValueError("An unrelated notify command already exists; merge it explicitly before installing.")
    lines = original.splitlines(keepends=True)
    result = []
    section = ""
    tui_notifications = parsed.get("tui", {}).get("notifications", True)
    if tui_notifications is True:
        tui_notifications = ["approval-requested"]
    elif isinstance(tui_notifications, list):
        tui_notifications = [event for event in tui_notifications if event != "agent-turn-complete"]
    tui_written = False
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if stripped.startswith("["):
            section = stripped.split("#", 1)[0].strip()
            if section == "[tui]":
                result.append(line)
                result.append("notifications = " + json.dumps(tui_notifications) + "\n")
                tui_written = True
                i += 1
                continue
        if stripped in (COMMENT, "# Code-Notify: Desktop notifications"):
            i += 1
            continue
        if re.match(r"^notify\s*=", stripped) and section in ("", "[notice.model_migrations]"):
            # Parse the assignment to consume multiline arrays too. The only
            # nested entry migrated is the old Code-Notify misinstallation.
            assignment = line
            end = i + 1
            while True:
                try:
                    value = tomllib.loads(assignment)["notify"]
                    break
                except tomllib.TOMLDecodeError:
                    if end == len(lines):
                        raise
                    assignment += lines[end]
                    end += 1
            if not section or (isinstance(value, str) and ".code-notify/" in value):
                i = end
                continue
        if section == "[tui]" and re.match(r"^notifications\s*=", stripped):
            assignment = line
            i += 1
            while True:
                try:
                    tomllib.loads(assignment)
                    break
                except tomllib.TOMLDecodeError:
                    if i == len(lines):
                        raise
                    assignment += lines[i]
                    i += 1
            continue
        result.append(line)
        i += 1
    if not tui_written:
        result.append("\n[tui]\nnotifications = " + json.dumps(tui_notifications) + "\n")
    updated = COMMENT + "\nnotify = " + json.dumps(command, ensure_ascii=False) + "\n" + "".join(result)
    after = tomllib.loads(updated)
    expected = dict(parsed)
    expected["notify"] = command
    expected.setdefault("tui", {})["notifications"] = tui_notifications
    migrations = expected.get("notice", {}).get("model_migrations", {})
    if isinstance(migrations.get("notify"), str) and ".code-notify/" in migrations["notify"]:
        del migrations["notify"]
    if after != expected:
        raise ValueError("Config migration changed an unrelated setting")
    return updated


def install(codex_home, claude_settings):
    destination = codex_home / "ghostty-notify"
    config = codex_home / "config.toml"
    command = ["/usr/bin/python3", str(destination / "codex-notify.py")]
    original = config.read_text() if config.exists() else ""
    updated = updated_config(original, command)
    destination.mkdir(parents=True, exist_ok=True)
    for name in FILES:
        target = destination / name
        temporary = destination / (name + ".tmp")
        shutil.copy2(REPO / "hooks" / name, temporary)
        temporary.chmod(0o755)
        temporary.replace(target)
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
    if updated != original:
        if config.exists():
            backup = codex_home / "backups" / ("ghostty-notify-{}.toml".format(time.time_ns()))
            backup.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(config, backup)
            backup.chmod(0o600)
            print("Config backup: {}".format(backup))
        temporary = config.with_name("config.toml.ghostty-notify.tmp")
        temporary.write_text(updated)
        temporary.chmod(config.stat().st_mode & 0o777 if config.exists() else 0o600)
        temporary.replace(config)
    print("Installed: {}".format(destination))
    print("Settings: {}".format(settings_path))
    print("Restart existing Codex CLI sessions to load notify; new sessions use it automatically.")


if __name__ == "__main__":
    if sys.platform != "darwin":
        sys.exit("macOS only")
    codex_root = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))).resolve()
    install(codex_root, Path.home() / ".claude/settings.json")
