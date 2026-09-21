#!/usr/bin/env python3
"""Register this project's hook launchers in Claude Code's settings.json.

install.sh copies the launchers into <config>/hooks/ and, on its own, only
prints the entries to merge. This does the merge, so that a one-command install
(scripts/setup.sh) needs nobody to edit JSON by hand:

- Everything already in settings.json is kept: other hooks, env, permissions,
  and keys this script has never heard of.
- An event that already runs one of our launchers is left alone, so running
  this twice, or after a manual install, adds nothing.
- A settings file that does not parse is refused rather than rewritten.
- If the plugin is enabled, nothing is written: the plugin registers the same
  hooks through hooks/hooks.json, and both together mean two notifications for
  every event.
- The previous file is copied aside before the new one replaces it, atomically.
  A symlinked settings.json (dotfiles) is written through, not replaced.

Deliberately Python 3.9-compatible: /usr/bin/python3 on macOS is 3.9, and this
runs on a fresh machine before anything else is installed.

Exit status: 0 registered or already registered, 2 usage or unreadable
settings, 3 refused because the plugin is enabled.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import sys
import tempfile
import time

# Mirrors hooks/hooks.json, which the plugin uses; a manual install points at
# the copies install.sh put in <config>/hooks/ instead of the plugin root.
ENTRIES = (
    ("PreToolUse", "", "ghostty-tab-save.sh"),
    ("UserPromptSubmit", None, "ghostty-round-reset.sh"),
    ("Notification", "", "ghostty-notify.sh"),
    ("Stop", "", "ghostty-notify.sh"),
)
TIMEOUT = 15
PLUGIN_NAMES = ("ai-ghostty-notifier", "claude-ghostty-notify")


def config_dir() -> Path:
    configured = os.environ.get("CLAUDE_CONFIG_DIR")
    return Path(configured).expanduser() if configured else Path.home() / ".claude"


def commands_in(event_groups) -> list:
    found = []
    if not isinstance(event_groups, list):
        return found
    for group in event_groups:
        if not isinstance(group, dict):
            continue
        for hook in group.get("hooks") or []:
            if isinstance(hook, dict) and isinstance(hook.get("command"), str):
                found.append(hook["command"])
    return found


def already_runs(event_groups, launcher: str) -> bool:
    # By file name, so an entry written by hand, quoted or not, from an older
    # install location, still counts: adding a second one would notify twice.
    return any(launcher in command for command in commands_in(event_groups))


def enabled_plugin(settings: dict):
    plugins = settings.get("enabledPlugins")
    if not isinstance(plugins, dict):
        return None
    for key, enabled in plugins.items():
        if enabled and key.split("@", 1)[0] in PLUGIN_NAMES:
            return key
    return None


def plan(settings: dict, hooks_dir: Path):
    """Return the updated settings and the events that gained an entry."""
    updated = json.loads(json.dumps(settings))
    hooks = updated.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError('"hooks" in settings.json is not an object')
    added = []
    for event, matcher, launcher in ENTRIES:
        groups = hooks.setdefault(event, [])
        if not isinstance(groups, list):
            raise ValueError(f'"hooks.{event}" in settings.json is not a list')
        if already_runs(groups, launcher):
            continue
        group: dict = {} if matcher is None else {"matcher": matcher}
        group["hooks"] = [{
            "type": "command",
            "command": shlex.quote(str(hooks_dir / launcher)),
            "timeout": TIMEOUT,
        }]
        groups.append(group)
        added.append(event)
    return updated, added


def write_atomically(target: Path, text: str) -> None:
    mode = target.stat().st_mode & 0o777 if target.exists() else 0o600
    fd, temp = tempfile.mkstemp(prefix=".settings.", suffix=".json", dir=str(target.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(temp, mode)
        os.replace(temp, target)
    except BaseException:
        if os.path.exists(temp):
            os.unlink(temp)
        raise


def main(argv=None) -> int:
    base = config_dir()
    parser = argparse.ArgumentParser(description="Register the hook launchers in Claude Code's settings.json.")
    parser.add_argument("--settings", type=Path, default=base / "settings.json")
    parser.add_argument("--hooks-dir", type=Path, default=base / "hooks")
    parser.add_argument("--dry-run", action="store_true", help="report, change nothing")
    args = parser.parse_args(argv)

    settings_path = args.settings.expanduser()
    hooks_dir = args.hooks_dir.expanduser()
    if not hooks_dir.is_absolute():
        print(f"FATAL: --hooks-dir must be absolute: {hooks_dir}", file=sys.stderr)
        return 2
    for _, _, launcher in ENTRIES:
        if not (hooks_dir / launcher).is_file():
            print(f"FATAL: {hooks_dir / launcher} is missing; run install.sh first.", file=sys.stderr)
            return 2

    # Write through a symlink rather than replacing it with a plain file.
    target = Path(os.path.realpath(settings_path))
    if target.exists():
        try:
            settings = json.loads(target.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            print(f"FATAL: cannot read {settings_path}: {error}", file=sys.stderr)
            print("       Nothing was changed. Fix the file, or merge the entries by hand.", file=sys.stderr)
            return 2
        if not isinstance(settings, dict):
            print(f"FATAL: {settings_path} is not a JSON object; nothing was changed.", file=sys.stderr)
            return 2
    else:
        settings = {}

    plugin = enabled_plugin(settings)
    if plugin:
        print(f"Not registering: the plugin {plugin} is enabled and already registers these hooks.")
        print("Two registrations mean two notifications per event. Disable one of them.")
        return 3

    try:
        updated, added = plan(settings, hooks_dir)
    except ValueError as error:
        print(f"FATAL: {error}; nothing was changed.", file=sys.stderr)
        return 2
    if not added:
        print(f"Hooks already registered in {settings_path}")
        return 0
    if args.dry_run:
        print(f"Would register {', '.join(added)} in {settings_path}")
        return 0

    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        backup = target.with_name(f"{target.name}.ghostty-notify-backup-{time.strftime('%Y%m%d-%H%M%S')}")
        shutil.copy2(target, backup)
        os.chmod(backup, 0o600)
        print(f"Backed up {settings_path} to {backup.name}")
    text = json.dumps(updated, indent=2, ensure_ascii=False) + "\n"
    write_atomically(target, text)
    if json.loads(target.read_text(encoding="utf-8")) != updated:
        print(f"FATAL: {settings_path} did not read back as written", file=sys.stderr)
        return 2
    print(f"Registered {', '.join(added)} in {settings_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
