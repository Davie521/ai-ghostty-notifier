"""Drive the installed Codex adapter through the real shared shell scripts.

Every test installs into a throwaway CODEX_HOME with the real installer, then
runs `codex-hook.sh <event>` exactly as ~/.codex/hooks.json would, against a
recording notification backend and a fake `ps` that stands in for the codex
process tree. Nothing touches the developer's own tabs, terminals or
notifications: the fake TTY is a file inside the sandbox, and Apple Events
are stubbed wherever they would be sent.

Stop hands its work to a detached process, so those tests wait for the
observable outcome (a recorded notification, a deleted timer) instead of
asserting right after the hook returns.
"""

from contextlib import closing
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch


REPO = Path(__file__).resolve().parent.parent


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


installer = module("install_codex", REPO / "scripts/install-codex.py")
legacy_installer = module("legacy_install_codex", REPO / "tests/fixtures/shell-baseline/scripts/install-codex.py")
SID = "019abcde-1111-2222-3333-444455556666"
TURN = "019abcde-aaaa-bbbb-cccc-444455556666"
OWNER = "1000:ttysNONE:Sun Sep 13 17:00:00 2026"

# ps as the scripts call it: `ps -o <cols> -p <pid>`. Every process reports
# pid 1000 as its parent; 1000 is the codex CLI, whose TTY the test controls.
# FAKE_AGENT_PID names the process standing in for the resident agent.
FAKE_PS = '''#!/usr/bin/python3
import os, sys
cols = sys.argv[2] if len(sys.argv) > 3 and sys.argv[1] == "-o" else ""
pid = sys.argv[-1]
tty = os.environ.get("FAKE_CODEX_TTY", "ttysNONE")
agent = os.environ.get("FAKE_AGENT_PID", "")
if cols == "ppid=":
    print("1" if pid == "1000" else "1000")
elif cols == "command=":
    if pid == "1000":
        print("/vendor/bin/codex")
    elif pid == agent:
        print("/x/ClaudeGhosttyNotify.app/Contents/MacOS/ghostty-notify-agent")
    else:
        print("/bin/bash")
elif cols == "tty=":
    print(tty if pid == "1000" else "??")
elif cols == "lstart=":
    print("Sun Sep 13 17:00:00 2026")
'''

RECORDER = '''#!/usr/bin/python3
import json, os, sys
with open(os.environ["NOTIFY_TEST_LOG"], "a") as f:
    f.write(json.dumps(sys.argv[1:]) + "\\n")
'''

# Answers the three Ghostty scripts the hooks send: the title snapshot, the
# marker lookup (reads the fake TTY file the marker was written to; MISSES
# counts answers to withhold first) and the clear-on-focus probe. TARGET_TAB_ID
# marks the focus script; it records which tab was focused.
OSASCRIPT = '''#!/usr/bin/python3
import os, sys
from pathlib import Path
root = Path(os.environ["NOTIFY_TEST_LOG"]).parent
script = sys.stdin.read() if len(sys.argv) == 1 else " ".join(sys.argv[1:])
marker = os.environ.get("MARKER", "")
target = os.environ.get("TARGET_TAB_ID", "")
if "set out to" in script:
    print("tab-1\\tOld title")
elif marker:
    misses = root / "misses"
    remaining = int(misses.read_text()) if misses.exists() else 0
    tty = Path(os.environ.get("GHOSTTY_NOTIFY_TTY", "/dev/null"))
    if remaining > 0:
        misses.write_text(str(remaining - 1))
        print("")
    elif marker in tty.read_text(errors="replace"):
        print("tab-1")
    else:
        print("")
elif "selected tab of front window" in script:
    print("yes" if (root / "selected").exists() else "no")
elif target:
    (root / "focused").write_text(target)
'''


class CodexHookTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "notification.jsonl"
        self.script(self.bin / "terminal-notifier", RECORDER)
        self.script(self.bin / "ps", FAKE_PS)
        self.codex_home = self.root / "codex"
        claude = self.root / "claude-settings.json"
        claude.write_text(json.dumps({"env": {"GHOSTTY_NOTIFY_MIN_ELAPSED": "120", "OTHER": "private"}}))
        with patch("builtins.print"):
            self.installed = legacy_installer.install(self.codex_home, claude)
        self.state = self.codex_home / "notifications/ghostty-sessions"
        self.rollout = self.root / "rollout.jsonl"
        self.env = patch.dict(os.environ, {
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "HOME": str(self.root),
            "CODEX_HOME": str(self.codex_home),
            "TERM_PROGRAM": "ghostty",
            "GHOSTTY_NOTIFY_BACKEND": "terminal-notifier",
            "GHOSTTY_NOTIFY_CLEAR_ON_FOCUS": "0",
            "GHOSTTY_NOTIFY_CODEX_SETTLE": "0",
            "GHOSTTY_NOTIFY_MARKER_RETRY_DELAYS": "",
            "NOTIFY_TEST_LOG": str(self.log),
        })
        self.env.start()
        self.addCleanup(self.env.stop)
        for name in ("GHOSTTY_NOTIFY_MIN_ELAPSED", "GHOSTTY_NOTIFY_SOUND_ELAPSED",
                     "GHOSTTY_NOTIFY_TIMEOUT", "GHOSTTY_NOTIFY_AGENT_APP", "GHOSTTY_NOTIFY_TTY",
                     "CODEX_SQLITE_HOME"):
            os.environ.pop(name, None)

    def script(self, path, body):
        path.write_text(body)
        path.chmod(0o755)

    def payload(self, event, **extra):
        return {"session_id": SID, "turn_id": TURN, "cwd": "/tmp/same-project",
                "hook_event_name": event, "transcript_path": str(self.rollout),
                "model": "gpt-6-astra", **extra}

    def run_hook(self, event, argument=None, **extra):
        started = time.monotonic()
        process = subprocess.Popen(
            ["/bin/bash", str(self.installed / "codex-hook.sh"), argument or event],
            stdin=subprocess.PIPE, text=True, start_new_session=True,
            env=os.environ,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        self.last_hook_group = process.pid
        self.addCleanup(self.stop_hook_group, process.pid)
        process.communicate(json.dumps(self.payload(event, **extra)), timeout=20)
        self.assertEqual(process.returncode, 0)
        return time.monotonic() - started

    @staticmethod
    def hook_group_gone(group):
        # killpg(group, 0) can report EPERM during runner teardown. Inspect
        # the exact group instead: zombies cannot write into the sandbox.
        # Use the real ps, not the ancestry stub installed on this test's PATH.
        snapshot = subprocess.check_output(
            ["/bin/ps", "-axo", "pgid=,stat="], text=True)
        return not any(fields[0] == str(group) and not fields[1].startswith("Z")
                       for line in snapshot.splitlines()
                       if len(fields := line.split()) == 2)

    def stop_hook_group(self, group):
        # Every hook gets its own session. Reap/stop only this test's workers
        # before TemporaryDirectory removes the files they can still write.
        if self.hook_group_gone(group):
            return
        try:
            os.killpg(group, signal.SIGTERM)
        except ProcessLookupError:
            return
        except PermissionError:
            if self.hook_group_gone(group):
                return
            raise
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline and not self.hook_group_gone(group):
            time.sleep(0.01)
        if not self.hook_group_gone(group):
            try:
                os.killpg(group, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except PermissionError:
                if not self.hook_group_gone(group):
                    raise

    def notices(self):
        if not self.log.exists():
            return []
        return [dict(zip(args[::2], args[1::2]))
                for args in map(json.loads, self.log.read_text().splitlines())]

    def wait_until(self, predicate, seconds=5):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.05)
        self.fail("the detached Stop work did not reach the expected state")

    def bind(self, owner=OWNER, started_ago=121, title="修复登录"):
        self.state.mkdir(parents=True, exist_ok=True)
        (self.state / (SID + ".codex-owner")).write_text(owner + "\n")
        (self.state / (SID + ".start")).write_text(str(int(time.time()) - started_ago))
        (self.state / (SID + ".title")).write_text(title)

    def records(self, *turns):
        # (turn_id, started_at) pairs in rollout order, as Codex writes them.
        self.rollout.write_text("".join(json.dumps({
            "type": "event_msg",
            "payload": {"type": "task_started", "turn_id": turn, "started_at": started},
        }) + "\n" for turn, started in turns))

    # ── Prompt: timer, title, owner ─────────────────────────────────────────
    def test_prompt_arms_the_timer_and_records_title_and_owner(self):
        self.run_hook("UserPromptSubmit", prompt="  修复登录\n第二行  ")
        self.assertTrue((self.state / (SID + ".start")).exists(), "prompt did not arm the timer")
        start = int((self.state / (SID + ".start")).read_text())
        self.assertLessEqual(abs(start - time.time()), 3)
        self.assertEqual((self.state / (SID + ".title")).read_text(), "修复登录 第二行\n")
        self.assertTrue((self.state / (SID + ".codex-owner")).read_text().startswith("1000:ttysNONE:"))
        (self.state / (SID + ".start")).write_text("5")
        self.run_hook("UserPromptSubmit", prompt="another prompt")
        self.assertEqual((self.state / (SID + ".title")).read_text(), "修复登录 第二行\n")
        self.assertGreater(int((self.state / (SID + ".start")).read_text()), 5)

    def test_subagent_prompt_leaves_the_round_alone(self):
        self.bind(started_ago=900)
        self.run_hook("UserPromptSubmit", prompt="child task", agent_id="agent-7")
        self.assertEqual(int((self.state / (SID + ".start")).read_text()), int(time.time()) - 900)
        self.assertEqual((self.state / (SID + ".title")).read_text(), "修复登录")

    def test_empty_first_prompt_does_not_block_a_later_title(self):
        self.run_hook("UserPromptSubmit", prompt="   ")
        self.run_hook("UserPromptSubmit", prompt="real prompt")
        self.assertEqual((self.state / (SID + ".title")).read_text(), "real prompt\n")

    def test_large_pasted_prompt_is_titled_quickly(self):
        prompt = "\n".join("line {:05d} of a pasted build log".format(i) for i in range(12000))
        elapsed = self.run_hook("UserPromptSubmit", prompt=prompt)
        self.assertLess(elapsed, 3)
        title = (self.state / (SID + ".title")).read_text().rstrip("\n")
        self.assertTrue(title.startswith("line 00000 of a pasted build log line 00001"))
        self.assertLessEqual(len(title), 120)

    def test_retired_pretooluse_entry_does_nothing(self):
        self.run_hook("PreToolUse", tool_name="Bash", tool_input={"command": "ls"})
        self.assertFalse(self.state.exists())

    def test_prompt_prunes_week_old_session_files(self):
        self.state.mkdir(parents=True)
        old = int(time.time()) - 8 * 86400
        for suffix in (".codex-owner", ".title", ".start"):
            stale = self.state / ("0ld" + suffix)
            stale.write_text("x")
            os.utime(stale, (old, old))
        fresh = self.state / "fre5h.title"
        fresh.write_text("keep")
        self.run_hook("UserPromptSubmit", prompt="hi")
        self.assertEqual(sorted(p.name for p in self.state.iterdir() if p.name.startswith(("0ld", "fre5h"))),
                         ["fre5h.title"])

    # ── The resident agent ──────────────────────────────────────────────────
    def install_agent(self, ready="authorized"):
        """A fake agent bundle at the installed location, reported alive and
        authorized. This test process stands in for the agent (the liveness
        check is `kill -0` plus what ps says the pid runs), `open` is stubbed
        so nothing is launched, and alerter is made unavailable so the only
        other way out is the recording terminal-notifier."""
        app = self.root / "Library/Application Support/claude-ghostty-notify/ClaudeGhosttyNotify.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        self.script(app / "Contents/MacOS/ghostty-notify-agent", "#!/bin/sh\nexit 0\n")
        self.script(self.bin / "open", "#!/bin/sh\nexit 0\n")
        agent_root = self.root / ".claude/notifications/ghostty-agent"
        agent_root.mkdir(parents=True)
        (agent_root / "agent.pid").write_text("{}\n".format(os.getpid()))
        (agent_root / "ready").write_text(ready + "\n")
        os.environ.update({
            "FAKE_AGENT_PID": str(os.getpid()),
            "GHOSTTY_NOTIFY_BACKEND": "auto",
            "GHOSTTY_NOTIFY_ALERTER": str(self.root / "no-alerter"),
        })
        return agent_root / "spool"

    def requests(self, spool):
        return sorted((json.loads(p.read_text()) for p in spool.glob("*.json")),
                      key=lambda request: request["type"])

    def test_prompt_anchors_and_dismisses_through_the_agent(self):
        spool = self.install_agent()
        os.environ["GHOSTTY_NOTIFY_CLEAR_ON_FOCUS"] = "1"
        self.bind()
        (self.state / (SID + ".json")).write_text('{"tab_id":"codex-target-tab"}')
        self.run_hook("UserPromptSubmit", prompt="back again")
        # The tab comes from Codex's own binding, not Claude's session dir.
        self.assertEqual(self.requests(spool), [
            {"type": "anchor", "session_id": SID, "tab_id": "codex-target-tab", "source": "codex"},
            {"type": "dismiss", "session_id": SID, "source": "codex"},
        ])

    def test_long_round_is_delivered_by_the_agent(self):
        spool = self.install_agent()
        self.bind()
        (self.state / (SID + ".json")).write_text('{"tab_id":"codex-target-tab"}')
        self.run_hook("Stop", last_assistant_message="done")
        self.wait_until(lambda: list(spool.glob("*.json")))
        request, = self.requests(spool)
        self.assertEqual(request["type"], "notify")
        self.assertEqual(request["source"], "codex")
        self.assertEqual(request["title"], "Codex ✅")
        self.assertEqual(request["subtitle"], "修复登录 — same-project")
        self.assertEqual(request["tab_id"], "codex-target-tab")
        self.assertEqual(request["timeout"], "1200")
        self.assertEqual(request["clear_on_focus"], "false")
        time.sleep(0.5)
        # Nothing reached the shell backends, and no watcher was spawned: the
        # agent withdraws on focus by itself.
        self.assertEqual(self.notices(), [])
        self.assertFalse((self.state / (SID + ".watch-pid")).exists())
        self.assertFalse((self.state / (SID + ".start")).exists())

    def test_config_can_pin_the_shell_path(self):
        spool = self.install_agent()
        settings = self.installed / "config.json"
        settings.write_text(json.dumps({**json.loads(settings.read_text()),
                                        "GHOSTTY_NOTIFY_AGENT_APP": ""}))
        self.bind()
        self.run_hook("Stop")
        self.wait_until(self.notices)
        self.assertEqual(self.notices()[0]["-title"], "Codex ✅")
        self.assertEqual(list(spool.glob("*.json")), [])

    def test_unauthorized_agent_falls_back_to_the_shell_path(self):
        spool = self.install_agent(ready="denied")
        self.bind()
        self.run_hook("Stop")
        self.wait_until(self.notices)
        self.assertEqual(list(spool.glob("*.json")), [])

    # ── Stop: delivery through the shared scripts ───────────────────────────
    def test_long_round_notifies_with_codex_branding_and_clears_timer(self):
        self.bind()
        self.run_hook("Stop", last_assistant_message="done")
        self.wait_until(self.notices)
        notice, = self.notices()
        self.assertEqual(notice["-title"], "Codex ✅")
        self.assertEqual(notice["-subtitle"], "修复登录 — same-project")
        # The hook reads the clock itself; a second may tick after bind().
        self.assertIn(notice["-message"], ("Finished after 2m 1s", "Finished after 2m 2s"))
        self.assertEqual(notice["-group"], "codex-ghostty-notify-" + SID)
        self.assertNotIn("-sound", notice)
        # The detached work fires the notice first and clears the timer after
        # it. Asserting straight away lost that race in about one run in ten.
        self.wait_until(lambda: not (self.state / (SID + ".start")).exists())

    def test_sound_past_the_long_threshold(self):
        self.bind(started_ago=601)
        self.run_hook("Stop")
        self.wait_until(self.notices)
        self.assertEqual(self.notices()[0]["-sound"], "Glass")

    def test_short_round_stays_silent(self):
        self.bind(started_ago=30)
        self.run_hook("Stop")
        self.wait_until(lambda: not (self.state / (SID + ".start")).exists())
        self.assertEqual(self.notices(), [])

    def test_round_without_a_prompt_stays_silent(self):
        self.bind()
        (self.state / (SID + ".start")).unlink()
        self.run_hook("Stop")
        time.sleep(0.6)
        self.assertEqual(self.notices(), [])

    def test_continuation_turn_is_silent_and_keeps_the_timer(self):
        now = int(time.time())
        self.bind()
        self.records(("older-turn", now - 900), (TURN, now - 121), ("next-turn", now))
        self.run_hook("Stop")
        self.wait_until(lambda: self.hook_group_gone(self.last_hook_group))
        self.assertEqual(self.notices(), [])
        self.assertTrue((self.state / (SID + ".start")).exists())
        # Control: the same rollout without the follow-up turn delivers.
        self.records(("older-turn", now - 900), (TURN, now - 121))
        self.run_hook("Stop")
        self.wait_until(self.notices)

    def test_native_event_keeps_payload_and_returns_before_settling(self):
        spool = self.install_agent()
        (spool.parent / "capabilities").write_text("hook-event-v1:{}\n".format(os.getpid()))
        self.bind()
        os.environ["GHOSTTY_NOTIFY_CODEX_SETTLE"] = "20"
        elapsed = self.run_hook("Stop", session_title="中文\t\\path\n", cwd="/tmp/空 格",
                                prompt="中" * 500, tool_output="not needed by the notifier")
        request, = self.requests(spool)
        self.assertLess(elapsed, 2)
        self.assertEqual(request["type"], "hook_event")
        self.assertEqual(request["version"], 1)
        self.assertEqual(request["source"], "codex")
        self.assertEqual(request["payload"]["session_title"], "中文\t\\path\n")
        self.assertEqual(request["payload"]["cwd"], "/tmp/空 格")
        self.assertEqual(request["payload"]["prompt"], "中" * 200)
        self.assertNotIn("tool_output", request["payload"])
        self.assertEqual(request["settings"]["GHOSTTY_NOTIFY_CODEX_SETTLE"], "20")
        self.assertEqual(request["owner"], OWNER)
        self.assertTrue(request["tty"].startswith("/dev/"))
        self.assertTrue((self.state / (SID + ".start")).exists())
        self.assertEqual(self.notices(), [])
        self.wait_until(lambda: self.hook_group_gone(self.last_hook_group))

    def test_native_prompt_advances_generation_and_does_not_run_legacy_worker(self):
        spool = self.install_agent()
        (spool.parent / "capabilities").write_text("hook-event-v1:{}\n".format(os.getpid()))
        self.run_hook("UserPromptSubmit", prompt="first")
        first, = self.requests(spool)
        self.assertEqual(first["payload"]["hook_event_name"], "UserPromptSubmit")
        self.assertEqual(first["started_at"], first["occurred_at"])
        self.assertFalse((self.state / (SID + ".title")).exists(), "title policy belongs to Swift")
        self.run_hook("UserPromptSubmit", prompt="second")
        second = next(r for r in self.requests(spool) if r["round_id"] != first["round_id"])
        self.assertEqual((self.state / (SID + ".round")).read_text().strip(), second["round_id"])

    def test_native_context_recovers_a_corrupt_round_marker(self):
        spool = self.install_agent()
        (spool.parent / "capabilities").write_text("hook-event-v1:{}\n".format(os.getpid()))
        self.bind()
        (self.state / (SID + ".round")).write_text("../invalid-round\n")
        self.run_hook("Stop")
        request, = self.requests(spool)
        self.assertRegex(request["round_id"], r"^[A-Za-z0-9-]{1,160}$")
        self.assertEqual((self.state / (SID + ".round")).read_text().strip(), request["round_id"])

    def test_stale_capability_uses_legacy_protocol(self):
        spool = self.install_agent()
        (spool.parent / "capabilities").write_text("hook-event-v1:999999\n")
        self.bind()
        self.run_hook("Stop")
        self.wait_until(lambda: list(spool.glob("*.json")))
        self.assertEqual(self.requests(spool)[0]["type"], "notify")

    def test_missing_jq_reports_to_stderr_and_does_not_block_cli(self):
        minimal = self.root / "minimal-bin"
        minimal.mkdir()
        for name, source in (("dirname", "/usr/bin/dirname"), ("cat", "/bin/cat")):
            (minimal / name).symlink_to(source)
        result = subprocess.run(["/bin/bash", str(self.installed / "codex-hook.sh"), "Stop"],
                                input=json.dumps(self.payload("Stop")), text=True, capture_output=True,
                                env={**os.environ, "PATH": str(minimal)}, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("jq is missing", result.stderr)

    def test_malformed_metadata_is_rejected_before_any_state_write(self):
        for session in (None, [], "abc\u0000def"):
            result = subprocess.run(["/bin/bash", str(self.installed / "codex-hook.sh"), "Stop"],
                                    input=json.dumps(self.payload("Stop", session_id=session)),
                                    text=True, capture_output=True, env=os.environ, timeout=5)
            self.assertEqual(result.returncode, 0)
            self.assertIn("invalid hook JSON", result.stderr)
        self.assertFalse(self.state.exists())

    def test_stale_task_started_in_the_tail_does_not_count_as_continuation(self):
        now = int(time.time())
        self.bind()
        self.records(("long-ago-turn", now - 5000))
        self.run_hook("Stop")
        self.wait_until(self.notices)

    def test_thread_name_from_codex_database_outranks_first_prompt(self):
        self.bind(title="first prompt")
        # sqlite3 finds ~/.sqliterc through the password database, not $HOME,
        # so a sandbox cannot plant one; record the invocation instead and
        # require the flags that keep a user's rc formatting out of the title.
        real = shutil.which("sqlite3", path=os.environ["PATH"].split(str(self.bin) + os.pathsep, 1)[1])
        assert real is not None
        self.script(self.bin / "sqlite3",
            '#!/bin/sh\nprintf "%s\\n" "$*" >> "${NOTIFY_TEST_LOG%/*}/sqlite3.argv"\nexec "' + real + '" "$@"\n')
        with closing(sqlite3.connect(self.codex_home / "state_5.sqlite")) as db, db:
            db.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT)")
            db.execute("INSERT INTO threads VALUES (?, ?)", (SID, "voice chat"))
        self.run_hook("Stop")
        self.wait_until(self.notices)
        self.assertEqual(self.notices()[0]["-subtitle"], "voice chat — same-project")
        argv = (self.root / "sqlite3.argv").read_text()
        self.assertIn("-init /dev/null", argv)
        self.assertIn("-noheader", argv)
        self.assertIn("-readonly", argv)

    def test_thread_name_follows_sqlite_home(self):
        self.bind(title="first prompt")
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir()
        for folder, name in ((self.codex_home, "stale name"), (elsewhere, "moved name")):
            with closing(sqlite3.connect(folder / "state_5.sqlite")) as db, db:
                db.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT)")
                db.execute("INSERT INTO threads VALUES (?, ?)", (SID, name))
        (self.codex_home / "config.toml").write_text('sqlite_home = "{}"\n'.format(elsewhere))
        self.run_hook("Stop")
        self.wait_until(self.notices)
        self.assertEqual(self.notices()[0]["-subtitle"], "moved name — same-project")

    def test_session_without_terminal_is_ignored(self):
        # Codex Desktop threads and `codex mcp-server` children report no TTY.
        os.environ["FAKE_CODEX_TTY"] = "??"
        self.run_hook("UserPromptSubmit", prompt="desktop")
        self.run_hook("Stop")
        time.sleep(0.4)
        self.assertEqual((self.state / (SID + ".codex-owner")).read_text(), "-\n")
        self.assertEqual(sorted(p.name for p in self.state.iterdir()), [SID + ".codex-owner"])
        self.assertEqual(self.notices(), [])

    def test_resume_in_another_process_drops_the_tab_binding(self):
        self.bind(owner="999:ttys001:Mon Sep 7 09:00:00 2026")
        saved = self.state / (SID + ".json")
        saved.write_text('{"tab_id":"stale-tab"}')
        self.run_hook("UserPromptSubmit", prompt="resumed")
        self.assertFalse(saved.exists())
        saved.write_text('{"tab_id":"fresh-tab"}')
        self.run_hook("UserPromptSubmit", prompt="same process")
        self.assertEqual(json.loads(saved.read_text())["tab_id"], "fresh-tab")

    def test_misrouted_event_and_bad_ids_do_nothing(self):
        # A Stop payload delivered through the prompt entry must not arm a
        # timer for a round that has already ended.
        self.run_hook("Stop", argument="UserPromptSubmit")
        self.assertFalse((self.state / (SID + ".start")).exists())
        self.bind()
        self.run_hook("Stop", session_id="../../escape")
        time.sleep(0.4)
        self.assertEqual(self.notices(), [])
        self.assertEqual([p for p in self.codex_home.rglob("*") if "escape" in p.name], [])

    def test_config_json_supplies_every_knob_unless_env_overrides(self):
        settings = self.installed / "config.json"
        self.assertEqual(json.loads(settings.read_text())["GHOSTTY_NOTIFY_MIN_ELAPSED"], "120")
        settings.write_text(json.dumps({"GHOSTTY_NOTIFY_MIN_ELAPSED": 0, "GHOSTTY_NOTIFY_SOUND_ELAPSED": 0}))
        self.bind(started_ago=5)
        self.run_hook("Stop")
        self.wait_until(self.notices)
        self.assertEqual(self.notices()[0]["-sound"], "Glass")
        os.environ["GHOSTTY_NOTIFY_MIN_ELAPSED"] = "180"
        # A second Stop for the same session and project inside the shared
        # script's 10 s rate window would be deduplicated regardless; drop
        # the stamp so only the threshold decides.
        shutil.rmtree(self.codex_home / "notifications/state")
        self.bind(started_ago=5, title="second")
        self.run_hook("Stop")
        self.wait_until(lambda: not (self.state / (SID + ".start")).exists())
        self.assertEqual(len(self.notices()), 1)

    # ── Stop: tab resolution once the turn has ended ────────────────────────
    def fake_tty(self):
        tty = self.root / "tty"
        tty.write_text("")
        os.environ["GHOSTTY_NOTIFY_TTY"] = str(tty)
        self.script(self.bin / "osascript", OSASCRIPT)
        return tty

    def test_tab_is_resolved_after_the_turn_and_the_title_restored(self):
        tty = self.fake_tty()
        self.bind()
        self.run_hook("Stop")
        self.wait_until(self.notices)
        self.assertTrue((self.state / (SID + ".json")).exists(), "tab was not bound")
        saved = json.loads((self.state / (SID + ".json")).read_text())
        self.assertEqual(saved["tab_id"], "tab-1")
        self.assertEqual(tty.read_text(), "\x1b]2;Old title\x1b\\")

    def test_marker_lookup_retries_while_the_title_still_moves(self):
        self.fake_tty()
        (self.root / "misses").write_text("1")
        os.environ["GHOSTTY_NOTIFY_MARKER_RETRY_DELAYS"] = "0.1 0.1"
        self.bind()
        self.run_hook("Stop")
        self.wait_until(self.notices)
        self.assertTrue((self.state / (SID + ".json")).exists(), "retry did not bind the tab")
        self.assertEqual(json.loads((self.state / (SID + ".json")).read_text())["tab_id"], "tab-1")
        self.assertFalse((self.state / (SID + ".attempts")).exists())

    def test_single_pass_gives_up_and_counts_the_attempt(self):
        self.fake_tty()
        (self.root / "misses").write_text("1")
        self.bind()
        self.run_hook("Stop")
        self.wait_until(self.notices)
        self.assertFalse((self.state / (SID + ".json")).exists())
        self.assertEqual((self.state / (SID + ".attempts")).read_text(), "1\n")

    def test_binding_is_refreshed_after_ghostty_restarts(self):
        tty = self.fake_tty()
        # What the hook takes for "the Ghostty that is running now".
        self.script(self.bin / "lsappinfo", '#!/bin/sh\necho \'"pid"=4242\'\n')
        saved = self.state / (SID + ".json")
        # A binding from another Ghostty, and one that predates the check.
        for stale in ('{"tab_id":"old-tab","cwd":"/x","ghostty_pid":"1"}',
                      '{"tab_id":"old-tab","cwd":"/x"}'):
            self.bind()
            saved.write_text(stale)
            tty.write_text("")
            self.run_hook("Stop")
            # The timer goes last in the detached work, after the binding.
            self.wait_until(lambda: not (self.state / (SID + ".start")).exists())
            self.assertEqual(json.loads(saved.read_text())["tab_id"], "tab-1")
            self.assertEqual(json.loads(saved.read_text()).get("ghostty_pid"), "4242")
            self.assertEqual(tty.read_text(), "\x1b]2;Old title\x1b\\")
            shutil.rmtree(self.codex_home / "notifications/state", ignore_errors=True)
        # Control: the same Ghostty is still running, so the binding stands
        # and no marker is written.
        self.bind()
        saved.write_text('{"tab_id":"old-tab","cwd":"/x","ghostty_pid":"4242"}')
        tty.write_text("")
        self.run_hook("Stop")
        self.wait_until(lambda: not (self.state / (SID + ".start")).exists())
        self.assertEqual(json.loads(saved.read_text())["tab_id"], "old-tab")
        self.assertEqual(tty.read_text(), "")

    def test_short_round_skips_the_marker_round_trip(self):
        tty = self.fake_tty()
        self.bind(started_ago=30)
        self.run_hook("Stop")
        self.wait_until(lambda: not (self.state / (SID + ".start")).exists())
        self.assertEqual(tty.read_text(), "")

    # ── Click routing through the real focus/clear scripts ──────────────────
    def install_action_backend(self, action):
        self.bind()
        (self.state / (SID + ".json")).write_text('{"tab_id":"codex-target-tab"}')
        alerter = self.bin / "alerter"
        self.script(alerter,
            '#!/usr/bin/python3\nimport json, os, sys, time\nfrom pathlib import Path\n'
            'root = Path(os.environ["NOTIFY_TEST_LOG"]).parent\n'
            'if "--help" in sys.argv: print("--close-label --remove")\n'
            'elif "--remove" in sys.argv: (root / "removed").write_text(sys.argv[sys.argv.index("--remove") + 1])\n'
            'else:\n'
            '    (root / "posted").touch()\n'
            '    time.sleep(0.2 if os.environ["TEST_ACTION"] else 15)\n'
            '    print(os.environ["TEST_ACTION"])\n')
        self.script(self.bin / "osascript", OSASCRIPT)
        self.script(self.bin / "lsappinfo", '#!/bin/sh\nprintf "com.mitchellh.ghostty\\n"\n')
        # The owner is cached, so the adapter needs no ps; the watcher must
        # see real processes to validate the PIDs it kills.
        (self.bin / "ps").unlink()
        os.environ.update({
            "GHOSTTY_NOTIFY_ALERTER": str(alerter),
            "GHOSTTY_NOTIFY_BACKEND": "alerter",
            "GHOSTTY_NOTIFY_FOCUS_POLL": "0.1",
            "TEST_ACTION": action,
        })
        self.addCleanup(lambda: subprocess.run(
            ["/bin/bash", str(self.installed / "ghostty-notify-clear.sh"), SID],
            env={**os.environ, "GHOSTTY_NOTIFY_SESSION_DIR": str(self.state),
                 "GHOSTTY_NOTIFY_GROUP_PREFIX": "codex-ghostty-notify"},
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5))

    def alerter_gone(self):
        pid_file = self.state / (SID + ".alerter-pid")
        if not pid_file.exists():
            return False
        try:
            os.kill(int(pid_file.read_text()), 0)
            return False
        except (ProcessLookupError, ValueError):
            return True

    def test_go_to_tab_focuses_the_codex_binding(self):
        self.install_action_backend("Go to tab")
        self.run_hook("Stop")
        focused = self.root / "focused"
        self.wait_until(focused.exists)
        self.assertEqual(focused.read_text(), "codex-target-tab")

    def test_dismiss_never_focuses(self):
        self.install_action_backend("Dismiss")
        self.run_hook("Stop")
        self.wait_until(self.alerter_gone)
        # A wrongly dispatched focus lands about 0.5 s after the alerter
        # exits (two osascript spawns); wait well past that before deciding.
        time.sleep(2)
        self.assertFalse((self.root / "focused").exists())

    def test_alert_survives_other_tab_then_clears_on_return(self):
        self.install_action_backend("")
        os.environ["GHOSTTY_NOTIFY_CLEAR_ON_FOCUS"] = "1"
        self.run_hook("Stop")
        self.wait_until((self.root / "posted").exists)
        # The watcher polls every 0.1 s; a wrong clear would land within
        # two polls, so a full second is a comfortable margin.
        time.sleep(1)
        self.assertFalse((self.root / "removed").exists())
        (self.root / "selected").touch()
        self.wait_until((self.root / "removed").exists)
        self.assertEqual((self.root / "removed").read_text(), "codex-ghostty-notify-" + SID)
        self.wait_until(lambda: not (self.state / (SID + ".alerter-pid")).exists())
        self.assertFalse((self.root / "focused").exists())


class HookCleanupTests(unittest.TestCase):
    def test_only_live_members_of_the_exact_group_prevent_cleanup(self):
        for snapshot, gone in (("41 Z\n42 S\n", True), ("42 S\n", True),
                               ("41 Z\n41 S\n", False), ("41 T\n", False)):
            with self.subTest(snapshot=snapshot), \
                    patch("os.killpg", side_effect=PermissionError), \
                    patch("subprocess.check_output", return_value=snapshot):
                self.assertEqual(CodexHookTests.hook_group_gone(41), gone)

    def test_cleanup_tolerates_exit_between_probe_and_signal(self):
        case = CodexHookTests()
        with patch.object(case, "hook_group_gone", return_value=False), \
                patch("os.killpg", side_effect=ProcessLookupError):
            case.stop_hook_group(41)

    def test_permission_error_is_not_silently_ignored_for_a_live_group(self):
        case = CodexHookTests()
        with patch.object(case, "hook_group_gone", return_value=False), \
                patch("os.killpg", side_effect=PermissionError):
            with self.assertRaises(PermissionError):
                case.stop_hook_group(41)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.runtime_check = patch.object(installer, "require_native_runtime", return_value=Path("/fixture/native.app"))
        self.runtime_check.start()
        self.addCleanup(self.runtime_check.stop)

    destination = Path("/Users/me/.codex/ghostty-notify")

    def test_handler_definition_is_the_one_users_have_trusted(self):
        # Codex hashes this into the trust record; changing it invalidates
        # every existing installation's trust.
        self.assertEqual(installer.our_handler(self.destination, "Stop"), {
            "type": "command", "command": '"/Users/me/.codex/ghostty-notify/codex-hook.sh" Stop',
            "timeout": 15,
        })
        self.assertEqual(installer.EVENTS, ("UserPromptSubmit", "Stop"))

    def test_merge_updates_in_place_and_keeps_other_hooks_where_they_are(self):
        mine = {"type": "command", "command": "/my/stop-logger"}
        lint = {"type": "command", "command": "/my/lint"}
        existing = {"description": "mine", "hooks": {
            "Stop": [{"hooks": [
                {"type": "command", "command": '"/old/ghostty-notify/codex-hook.sh" Stop', "timeout": 5},
                mine,
            ]}],
            "PreToolUse": [{"hooks": [{"type": "command", "command": '"/old/ghostty-notify/codex-hook.sh" PreToolUse'}]}],
            "PostToolUse": [{"matcher": "Bash", "hooks": [lint]}],
        }}
        merged, renumbered = installer.merged_hooks(existing, self.destination)
        self.assertEqual(renumbered, [])
        self.assertEqual(merged["description"], "mine")
        self.assertEqual(merged["hooks"]["Stop"], [{"hooks": [installer.our_handler(self.destination, "Stop"), mine]}])
        self.assertNotIn("PreToolUse", merged["hooks"])
        self.assertEqual(merged["hooks"]["PostToolUse"], [{"matcher": "Bash", "hooks": [lint]}])
        self.assertEqual(merged["hooks"]["UserPromptSubmit"],
                         [{"hooks": [installer.our_handler(self.destination, "UserPromptSubmit")]}])
        again, renumbered = installer.merged_hooks(json.loads(json.dumps(merged)), self.destination)
        self.assertEqual((again, renumbered), (merged, []))
        self.assertEqual(installer.merged_hooks({}, self.destination), installer.merged_hooks(None, self.destination))

    def test_merge_reports_hooks_that_had_to_move(self):
        existing = {"hooks": {"PreToolUse": [
            {"hooks": [{"type": "command", "command": '"/old/ghostty-notify/codex-hook.sh" PreToolUse'}]},
            {"hooks": [{"type": "command", "command": "/my/guard"}]},
        ]}}
        merged, renumbered = installer.merged_hooks(existing, self.destination)
        self.assertEqual(renumbered, ["PreToolUse"])
        self.assertEqual(merged["hooks"]["PreToolUse"], [{"hooks": [{"type": "command", "command": "/my/guard"}]}])

    def test_bare_legacy_notify_is_removed_with_its_comment(self):
        original = ('# Codex completion notifications in Ghostty (claude-ghostty-notify)\n'
                    'notify = ["/usr/bin/python3", "/Users/me/.codex/ghostty-notify/codex-notify.py"]\n'
                    'model = "kept"\n[tui]\nnotifications = ["approval-requested"]\n')
        self.assertEqual(installer.without_legacy_notify(original),
                         'model = "kept"\n[tui]\nnotifications = ["approval-requested"]\n')

    def test_wrapped_legacy_notify_keeps_the_wrapper(self):
        wrapper = "/Users/me/.codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"
        original = ('model = "kept"\n\nnotify = ["' + wrapper + '", "turn-ended", "--previous-notify", '
                    '"[\\"\\\\/usr\\\\/bin\\\\/python3\\",\\"\\\\/Users\\\\/me\\\\/.codex\\\\/ghostty-notify\\\\/codex-notify.py\\"]"]\n\n'
                    '[projects."/x"]\ntrust_level = "trusted"\n')
        updated = installer.without_legacy_notify(original)
        self.assertEqual(installer.tomllib.loads(updated), {
            "model": "kept", "notify": [wrapper, "turn-ended"],
            "projects": {"/x": {"trust_level": "trusted"}},
        })
        self.assertIs(installer.without_legacy_notify(updated), updated)

    def test_unrelated_notify_is_left_alone(self):
        original = 'notify = ["/custom/hook"]\nmodel = "kept"\n'
        self.assertIs(installer.without_legacy_notify(original), original)
        with self.assertRaises(ValueError):
            installer.without_legacy_notify('notify = ["/x/ghostty-notify/codex-notify.py", "extra"]\n')

    def test_tui_turn_alert_is_narrowed_but_prompts_survive(self):
        kept = ["approval-requested", "plan-mode-prompt"]
        cases = (
            ('model = "x"\n', 'model = "x"\n\n[tui]\nnotifications = ' + json.dumps(kept) + '\n'),
            ('[tui]\nanimations = false\n', '[tui]\nnotifications = ' + json.dumps(kept) + '\nanimations = false\n'),
            ('[tui]\nnotifications = true\nanimations = false\n',
             '[tui]\nnotifications = ' + json.dumps(kept) + '\nanimations = false\n'),
            ('[tui]\nnotifications = [\n  "agent-turn-complete",\n  "plan-mode-prompt",\n]\n',
             '[tui]\nnotifications = ["plan-mode-prompt"]\n'),
        )
        for original, expected in cases:
            self.assertEqual(installer.without_tui_turn_alert(original), expected)
        for untouched in ('[tui]\nnotifications = false\n', "[tui]\nnotifications = [ 'approval-requested' ]\n"):
            self.assertIs(installer.without_tui_turn_alert(untouched), untouched)

    def sandbox(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        root = Path(folder.name)
        codex = root / "codex"
        codex.mkdir()
        settings = root / "claude.json"
        settings.write_text(json.dumps({"env": {
            "GHOSTTY_NOTIFY_MIN_ELAPSED": "120", "GHOSTTY_NOTIFY_BACKEND": "terminal-notifier",
            "GHOSTTY_NOTIFY_SESSION_DIR": "/Users/me/.claude/notifications/ghostty-sessions",
            "GHOSTTY_NOTIFY_NATIVE_APP": "/private/checkout/fixture.app",
            "OTHER": "private",
        }}))
        return root, codex, settings

    def test_install_copies_scripts_migrates_config_and_backs_up(self):
        _, codex, settings = self.sandbox()
        (codex / "ghostty-notify").mkdir()
        (codex / "ghostty-notify/codex-notify.py").write_text("stale")
        (codex / "config.toml").write_text(
            'notify = ["/usr/bin/python3", "' + str(codex) + '/ghostty-notify/codex-notify.py"]\n'
            'model = "kept"\n')
        (codex / "config.toml").chmod(0o600)
        (codex / "hooks.json").write_text(json.dumps({"hooks": {"SessionStart": [
            {"hooks": [{"type": "command", "command": "/my/start"}]}]}}))
        with patch("builtins.print"):
            installer.install(codex, settings)
            installer.install(codex, settings)
        installed = codex / "ghostty-notify"
        for name in installer.FILES:
            self.assertEqual((installed / name).read_bytes(), (REPO / "hooks" / name).read_bytes())
            self.assertTrue(os.access(installed / name, os.X_OK))
        self.assertFalse((installed / "codex-notify.py").exists())
        config = json.loads((installed / "config.json").read_text())
        self.assertEqual(config["GHOSTTY_NOTIFY_MIN_ELAPSED"], "120")
        self.assertEqual(config["GHOSTTY_NOTIFY_BACKEND"], "terminal-notifier")
        self.assertNotIn("GHOSTTY_NOTIFY_SESSION_DIR", config)
        self.assertNotIn("GHOSTTY_NOTIFY_NATIVE_APP", config)
        self.assertNotIn("private", (installed / "config.json").read_text())
        hooks = json.loads((codex / "hooks.json").read_text())["hooks"]
        self.assertEqual(hooks["SessionStart"][0]["hooks"][0]["command"], "/my/start")
        self.assertNotIn("PreToolUse", hooks)
        for event in installer.EVENTS:
            self.assertEqual(len([h for g in hooks[event] for h in g["hooks"] if installer.is_ours(h)]), 1)
        self.assertEqual(installer.tomllib.loads((codex / "config.toml").read_text()),
                         {"model": "kept", "tui": {"notifications": ["approval-requested", "plan-mode-prompt"]}})
        self.assertEqual(oct((codex / "config.toml").stat().st_mode & 0o777), "0o600")
        backups = sorted(codex.joinpath("backups").iterdir())
        self.assertEqual([b.suffix for b in backups], [".json", ".toml"])
        self.assertEqual({oct(b.stat().st_mode & 0o777) for b in backups}, {"0o600"})
        self.assertEqual([p.name for p in codex.iterdir() if p.name.endswith(".tmp")], [])

    def test_unmigratable_config_aborts_before_anything_is_written(self):
        _, codex, settings = self.sandbox()
        (codex / "config.toml").write_text('notify = ["/x/ghostty-notify/codex-notify.py", "extra"]\n')
        (codex / "hooks.json").write_text("{}")
        with self.assertRaises(SystemExit):
            installer.install(codex, settings)
        self.assertEqual((codex / "hooks.json").read_text(), "{}")
        self.assertFalse((codex / "ghostty-notify").exists())
        self.assertFalse((codex / "backups").exists())
        (codex / "config.toml").write_text('[tui\n')
        with self.assertRaises(SystemExit):
            installer.install(codex, settings)
        self.assertFalse((codex / "ghostty-notify").exists())

    def test_missing_native_runtime_aborts_before_anything_is_written(self):
        _, codex, settings = self.sandbox()
        with patch.object(installer, "require_native_runtime", side_effect=SystemExit("native runtime missing")), self.assertRaises(SystemExit):
            installer.install(codex, settings)
        self.assertEqual(list(codex.iterdir()), [])

    def test_install_no_longer_depends_on_jq(self):
        _, codex, settings = self.sandbox()
        with patch.object(installer.shutil, "which", return_value=None), patch("builtins.print"):
            installer.install(codex, settings)
        self.assertTrue((codex / "ghostty-notify/native-hook.sh").is_file())
        self.assertFalse((codex / "ghostty-notify/legacy-notify.sh").exists())

    def test_failed_bootstrap_copy_preserves_registered_codex_hooks(self):
        _, codex, settings = self.sandbox()
        destination = codex / "ghostty-notify"
        shutil.copytree(REPO / "tests/fixtures/shell-baseline/hooks", destination)
        before = {p.name: p.read_bytes() for p in destination.iterdir()}
        (codex / "hooks.json").write_text('{"hooks":{}}\n')
        real_copy = shutil.copy2
        def fail_bootstrap(source, target, *args, **kwargs):
            if Path(source).name == "native-hook.sh":
                raise OSError("injected bootstrap-copy failure")
            return real_copy(source, target, *args, **kwargs)
        with patch.object(shutil, "copy2", side_effect=fail_bootstrap), self.assertRaises(OSError):
            installer.install(codex, settings)
        self.assertEqual({p.name: p.read_bytes() for p in destination.iterdir()}, before)
        self.assertEqual((codex / "hooks.json").read_text(), '{"hooks":{}}\n')
        self.assertFalse((codex / "backups").exists())

    def test_invalid_staged_script_preserves_registered_codex_hooks(self):
        root, codex, settings = self.sandbox()
        destination = codex / "ghostty-notify"
        shutil.copytree(REPO / "tests/fixtures/shell-baseline/hooks", destination)
        before = {p.name: p.read_bytes() for p in destination.iterdir()}
        source = root / "source"
        shutil.copytree(REPO / "hooks", source / "hooks")
        (source / "hooks/ghostty-tab-save.sh").write_text("#!/bin/bash\nif\n")
        with patch.object(installer, "REPO", source), self.assertRaises(subprocess.CalledProcessError):
            installer.install(codex, settings)
        self.assertEqual({p.name: p.read_bytes() for p in destination.iterdir()}, before)
        self.assertFalse((codex / "hooks.json").exists())
        self.assertFalse((codex / "backups").exists())

    def test_symlinked_files_stay_symlinks(self):
        root, codex, settings = self.sandbox()
        dotfiles = root / "dotfiles"
        dotfiles.mkdir()
        (dotfiles / "hooks.json").write_text("{}")
        (dotfiles / "config.toml").write_text('model = "kept"\n')
        (codex / "hooks.json").symlink_to(dotfiles / "hooks.json")
        (codex / "config.toml").symlink_to(dotfiles / "config.toml")
        with patch("builtins.print"):
            installer.install(codex, settings)
        for name in ("hooks.json", "config.toml"):
            self.assertTrue((codex / name).is_symlink())
        self.assertIn("Stop", json.loads((dotfiles / "hooks.json").read_text())["hooks"])
        self.assertIn("plan-mode-prompt", (dotfiles / "config.toml").read_text())
        self.assertEqual([p.name for p in dotfiles.iterdir() if p.name.endswith(".tmp")], [])


if __name__ == "__main__":
    unittest.main()
