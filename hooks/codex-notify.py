#!/usr/bin/env python3
"""Adapt Codex's agent-turn-complete callback to the shared Ghostty hooks.

Only stdlib is required (including macOS's Python 3.9). The callback is the
completion signal; the optional, read-only Codex database/rollout supplies a
display name and per-turn duration, never decides whether a turn completed.
"""

import datetime
import fcntl
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import time


HOOKS = Path(__file__).resolve().parent
SAFE_ID = re.compile(r"[a-fA-F0-9-]{1,80}\Z")
SETTINGS = (
    "GHOSTTY_NOTIFY_MIN_ELAPSED", "GHOSTTY_NOTIFY_SOUND_ELAPSED",
    "GHOSTTY_NOTIFY_TIMEOUT", "GHOSTTY_NOTIFY_CLEAR_ON_FOCUS",
)


def read_json(path):
    try:
        value = json.loads(path.read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def codex_terminal():
    """Return the native CLI's identity, excluding desktop/headless servers."""
    pid = os.getppid()
    for _ in range(16):
        if pid <= 1:
            break
        result = subprocess.run(
            ["ps", "-o", "ppid=,tty=,comm=", "-p", str(pid)],
            capture_output=True, text=True, timeout=2,
        )
        parts = result.stdout.strip().split(None, 2)
        if len(parts) != 3:
            break
        parent, tty, command = parts
        if Path(command).name == "codex":
            if tty in ("??", "?", "-"):
                return None
            started = subprocess.run(
                ["ps", "-o", "lstart=", "-p", str(pid)],
                capture_output=True, text=True, timeout=2,
            ).stdout.strip()
            return "{}:{}:{}".format(pid, tty, started)
        pid = int(parent)
    return None


def thread_info(codex_home, session_id):
    """Use the indexed path when available; tolerate database/schema changes."""
    databases = sorted(codex_home.glob("state_*.sqlite"), reverse=True)
    for database in databases:
        try:
            connection = sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=0.2)
            try:
                connection.row_factory = sqlite3.Row
                row = connection.execute(
                    "SELECT * FROM threads WHERE id = ?", (session_id,)
                ).fetchone()
                if row:
                    info = dict(row)
                    info["title"] = info.get("name") or info.get("title") or ""
                    return info
            finally:
                connection.close()
        except (sqlite3.Error, OSError):
            continue
    for folder in ("sessions", "archived_sessions"):
        for path in (codex_home / folder).glob("**/rollout-*-{}.jsonl".format(session_id)):
            info = {"rollout_path": str(path)}
            try:
                with path.open() as stream:
                    record = json.loads(stream.readline())
                if record.get("type") == "session_meta":
                    info["source"] = record["payload"].get("source")
            except (OSError, ValueError, AttributeError, KeyError):
                pass
            return info
    return {}


def reverse_lines(path):
    """Read a rollout backwards in chunks, without loading a long chat."""
    with path.open("rb") as stream:
        stream.seek(0, os.SEEK_END)
        position = stream.tell()
        remainder = b""
        while position:
            size = min(position, 65536)
            position -= size
            stream.seek(position)
            lines = (stream.read(size) + remainder).split(b"\n")
            remainder = lines[0]
            yield from reversed(lines[1:])
        if remainder:
            yield remainder


def seconds(value):
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if math.isfinite(value) and 0 <= value < 1_000_000_000:
            return int(value)
    return None


def turn_elapsed(path, turn_id, now):
    """Match THIS turn, including after resume, interruption and compaction."""
    if not path or not turn_id:
        return None
    try:
        for line in reverse_lines(Path(path)):
            # Most lines contain tool output or message text, not timing.
            if b'"task_complete"' not in line and b'"task_started"' not in line:
                continue
            try:
                record = json.loads(line)
            except (ValueError, UnicodeError):
                continue
            if not isinstance(record, dict) or record.get("type") != "event_msg":
                continue
            event = record.get("payload")
            if not isinstance(event, dict) or event.get("turn_id") != turn_id:
                continue
            if event.get("type") not in ("task_complete", "task_started"):
                continue
            duration = event.get("duration_ms")
            if isinstance(duration, (int, float)) and not isinstance(duration, bool):
                elapsed = seconds(duration / 1000)
                if elapsed is not None:
                    return elapsed
            started = event.get("started_at")
            if not isinstance(started, (int, float)) or isinstance(started, bool):
                # Older CLI versions have an ISO timestamp on task_started.
                if event["type"] != "task_started":
                    continue
                try:
                    started = datetime.datetime.fromisoformat(
                        record["timestamp"].replace("Z", "+00:00")
                    ).timestamp()
                except (KeyError, TypeError, ValueError, AttributeError):
                    continue
            completed = event.get("completed_at", now)
            if isinstance(completed, (int, float)) and not isinstance(completed, bool):
                return seconds(completed - started)
    except OSError:
        pass
    return None


def environment(codex_home):
    env = os.environ.copy()
    settings = read_json(HOOKS / "config.json")
    for name in SETTINGS:
        value = settings.get(name)
        if name not in env and isinstance(value, (str, int)):
            env[name] = str(value)
    env.update({
        "GHOSTTY_NOTIFY_PROCESS_NAME": "codex",
        "GHOSTTY_NOTIFY_APP_NAME": "Codex",
        "GHOSTTY_NOTIFY_SESSION_DIR": str(codex_home / "notifications/ghostty-sessions"),
        "GHOSTTY_NOTIFY_RATE_DIR": str(codex_home / "notifications/state"),
        "GHOSTTY_NOTIFY_GROUP_PREFIX": "codex-ghostty-notify",
        # Use the same shell delivery as a manual Claude install. A resident
        # Claude-branded app is not implicitly launched by a Codex callback.
        "GHOSTTY_NOTIFY_AGENT_APP": "",
    })
    return env


def dispatch(notification, codex_home, owner):
    session_id = notification.get("thread-id")
    turn_id = notification.get("turn-id")
    if not isinstance(session_id, str) or not SAFE_ID.fullmatch(session_id):
        return
    if not isinstance(turn_id, str) or not SAFE_ID.fullmatch(turn_id):
        return
    info = thread_info(codex_home, session_id)
    # A child agent can inherit its parent's Ghostty environment and TTY.
    # Its own completion must never look like the user's main task finished.
    source = info.get("source")
    if source and source not in ("cli", "exec"):
        return
    env = environment(codex_home)
    state_dir = Path(env["GHOSTTY_NOTIFY_SESSION_DIR"])
    state_dir.mkdir(parents=True, exist_ok=True)
    with (state_dir / (session_id + ".callback-lock")).open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        receipt = state_dir / (session_id + ".codex.json")
        previous = read_json(receipt)
        if previous.get("turn_id") == turn_id:
            return
        if previous.get("owner") != owner:
            # Resume in a different tab/process must rebind, even when the old
            # Ghostty tab is still open. Never locate a session by cwd.
            for suffix in (".json", ".attempts"):
                try:
                    (state_dir / (session_id + suffix)).unlink()
                except FileNotFoundError:
                    pass
        elapsed = turn_elapsed(info.get("rollout_path"), turn_id, time.time())
        messages = notification.get("input-messages", [])
        title = info.get("title")
        if not title and isinstance(messages, list):
            title = next((m for m in messages if isinstance(m, str) and m.strip()), None)
        title = title or "Task Complete"
        title = " ".join(str(title).split())[:120]
        cwd = notification.get("cwd")
        payload = json.dumps({
            "session_id": session_id,
            "cwd": cwd if isinstance(cwd, str) else os.getcwd(),
            "session_title": title,
            "hook_event_name": "Stop",
            "elapsed_seconds": elapsed,
        })
        # All suppressed rounds can skip the Apple Events round-trip.
        minimum = env.get("GHOSTTY_NOTIFY_MIN_ELAPSED", "180")
        minimum = int(minimum) if re.fullmatch(r"[0-9]{1,9}", minimum) else 180
        suppressed = elapsed is not None and elapsed < minimum
        if not suppressed:
            subprocess.run(
                ["/bin/bash", str(HOOKS / "ghostty-tab-save.sh")],
                input=payload, text=True, env=env, check=True, timeout=15,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
        subprocess.run(
            ["/bin/bash", str(HOOKS / "ghostty-notify.sh")],
            input=payload, text=True, env=env, check=True, timeout=15,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        receipt.write_text(json.dumps({
            "turn_id": turn_id, "owner": owner, "elapsed_seconds": elapsed,
            "status": "below_threshold" if suppressed else "dispatched",
            "at": int(time.time()),
        }) + "\n")


def main():
    if os.environ.get("TERM_PROGRAM") != "ghostty" and not os.environ.get("GHOSTTY_RESOURCES_DIR"):
        return
    if len(sys.argv) != 2:
        return
    try:
        notification = json.loads(sys.argv[1])
        if not isinstance(notification, dict) or notification.get("type") != "agent-turn-complete":
            return
        owner = codex_terminal()
        if owner:
            codex_home = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))).resolve()
            dispatch(notification, codex_home, owner)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        # A desktop notifier must never break Codex's completed turn.
        print("codex-ghostty-notify: {}".format(error), file=sys.stderr)


if __name__ == "__main__":
    main()
