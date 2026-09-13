"""Exercise real shared shell delivery with a recording notification backend."""

import importlib.util
from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch


REPO = Path(__file__).resolve().parent.parent


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


notify = module("codex_notify", REPO / "hooks/codex-notify.py")
installer = module("install_codex", REPO / "scripts/install-codex.py")
SID = "019abcde-1111-2222-3333-444455556666"
TURN = "019abcde-aaaa-bbbb-cccc-444455556666"


class CodexNotifyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "notification.jsonl"
        recorder = self.bin / "terminal-notifier"
        recorder.write_text(
            '#!/usr/bin/python3\nimport json, os, sys\n'
            'with open(os.environ["NOTIFY_TEST_LOG"], "a") as f:\n'
            '    f.write(json.dumps(sys.argv[1:]) + "\\n")\n'
        )
        recorder.chmod(0o755)
        # Never probe or retitle the developer's actual terminal during tests.
        (self.bin / "ps").write_text("#!/bin/sh\nexit 0\n")
        (self.bin / "ps").chmod(0o755)
        self.env = patch.dict(os.environ, {
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "TERM_PROGRAM": "ghostty",
            "GHOSTTY_NOTIFY_BACKEND": "terminal-notifier",
            "GHOSTTY_NOTIFY_AGENT_APP": "",
            "GHOSTTY_NOTIFY_MIN_ELAPSED": "120",
            "GHOSTTY_NOTIFY_SOUND_ELAPSED": "600",
            "GHOSTTY_NOTIFY_CLEAR_ON_FOCUS": "0",
            "NOTIFY_TEST_LOG": str(self.log),
        })
        self.env.start()
        self.addCleanup(self.env.stop)
        self.rollout = self.root / "rollout.jsonl"
        with closing(sqlite3.connect(self.root / "state_5.sqlite")) as db, db:
            db.execute("CREATE TABLE threads (id TEXT, rollout_path TEXT, title TEXT, source TEXT)")
            db.execute("INSERT INTO threads VALUES (?, ?, ?, ?)",
                       (SID, str(self.rollout), "修复登录", "cli"))

    def records(self, events):
        self.rollout.write_text("".join(json.dumps({
            "type": "event_msg", "payload": e,
        }) + "\n" for e in events))

    def completed(self, duration, turn=TURN):
        return {"type": "task_complete", "turn_id": turn, "duration_ms": duration * 1000}

    def payload(self, **extra):
        return {"type": "agent-turn-complete", "thread-id": SID, "turn-id": TURN,
                "cwd": "/tmp/same-project", "input-messages": ["fallback title"], **extra}

    def dispatch(self, **extra):
        notify.dispatch(self.payload(**extra), self.root, "pid:tty:start")

    def notices(self):
        if not self.log.exists():
            return []
        return [dict(zip(args[::2], args[1::2]))
                for args in map(json.loads, self.log.read_text().splitlines())]

    def test_short_turn_silent_even_after_old_long_turn(self):
        self.records([self.completed(2000, "deadbeef"), self.completed(119)])
        self.dispatch()
        self.assertEqual(self.notices(), [])

    def test_medium_turn_uses_codex_title_and_exact_duration_without_sound(self):
        self.records([self.completed(121)])
        self.dispatch()
        notice, = self.notices()
        self.assertEqual(notice["-title"], "Codex ✅")
        self.assertEqual(notice["-subtitle"], "修复登录 — same-project")
        self.assertEqual(notice["-message"], "Finished after 2m 1s")
        self.assertEqual(notice["-group"], "codex-ghostty-notify-" + SID)
        self.assertNotIn("-sound", notice)

    def test_long_turn_adds_glass_sound(self):
        self.records([self.completed(601)])
        self.dispatch()
        self.assertEqual(self.notices()[0]["-sound"], "Glass")

    def test_duplicate_callback_does_not_notify_twice(self):
        self.records([self.completed(121)])
        self.dispatch()
        self.dispatch()
        self.assertEqual(len(self.notices()), 1)

    def test_missing_rollout_still_notifies_without_invented_time_or_sound(self):
        self.dispatch()
        notice, = self.notices()
        self.assertEqual(notice["-message"], "Task complete")
        self.assertNotIn("-sound", notice)

    def test_pending_rollout_flush_uses_current_start_after_interruption(self):
        now = time.time()
        self.records([
            {"type": "task_started", "turn_id": "deadbeef", "started_at": now - 4000},
            {"type": "turn_aborted", "turn_id": "deadbeef"},
            {"type": "task_started", "turn_id": TURN, "started_at": now - 121},
        ])
        self.assertEqual(notify.turn_elapsed(self.rollout, TURN, now), 121)

    def test_unrelated_turn_and_embedded_event_text_do_not_supply_timing(self):
        self.records([self.completed(5000, "deadbeef")])
        with self.rollout.open("a") as stream:
            stream.write(json.dumps({"type": "response_item", "payload": self.completed(9999)}) + "\n")
        self.assertIsNone(notify.turn_elapsed(self.rollout, TURN, time.time()))

    def test_subagent_completion_does_not_alert_parent(self):
        with closing(sqlite3.connect(self.root / "state_5.sqlite")) as db, db:
            db.execute("UPDATE threads SET source = ?", ('{"subagent":{"thread_spawn":{}}}',))
        self.records([self.completed(601)])
        self.dispatch()
        self.assertEqual(self.notices(), [])

    def test_rollout_lookup_survives_missing_database(self):
        (self.root / "state_5.sqlite").unlink()
        folder = self.root / "sessions/2026/09/06"
        folder.mkdir(parents=True)
        path = folder / ("rollout-2026-09-06T00-00-00-" + SID + ".jsonl")
        path.write_text(json.dumps({"type": "session_meta", "payload": {"source": "cli"}}) + "\n")
        self.assertEqual(notify.thread_info(self.root, SID)["rollout_path"], str(path))

    def test_fallback_lookup_also_rejects_subagent(self):
        (self.root / "state_5.sqlite").unlink()
        folder = self.root / "sessions"
        folder.mkdir()
        (folder / ("rollout-date-" + SID + ".jsonl")).write_text(json.dumps({
            "type": "session_meta", "payload": {"source": {"subagent": {}}},
        }) + "\n")
        self.dispatch()
        self.assertEqual(self.notices(), [])

    def test_resuming_new_process_drops_old_tab_binding(self):
        state = self.root / "notifications/ghostty-sessions"
        state.mkdir(parents=True)
        (state / (SID + ".codex.json")).write_text(json.dumps({"owner": "old:tty:start"}))
        saved = state / (SID + ".json")
        saved.write_text('{"tab_id":"old-tab"}')
        self.records([self.completed(121)])
        self.dispatch()
        self.assertFalse(saved.exists())

    def test_same_process_retains_exact_tab(self):
        state = self.root / "notifications/ghostty-sessions"
        state.mkdir(parents=True)
        (state / (SID + ".codex.json")).write_text(json.dumps({"owner": "pid:tty:start"}))
        saved = state / (SID + ".json")
        saved.write_text('{"tab_id":"exact-tab"}')
        self.records([self.completed(121)])
        self.dispatch()
        self.assertEqual(json.loads(saved.read_text())["tab_id"], "exact-tab")

    def test_invalid_ids_cannot_create_state(self):
        self.dispatch(**{"thread-id": "../../escape"})
        self.dispatch(**{"turn-id": []})
        self.assertFalse((self.root / "notifications").exists())

    def test_reverse_scan_handles_large_unicode_line_and_incomplete_tail(self):
        self.records([self.completed(145)])
        with self.rollout.open("a") as stream:
            stream.write(json.dumps({"content": "中" * 100000}) + "\n{broken")
        self.assertEqual(notify.turn_elapsed(self.rollout, TURN, time.time()), 145)

    def test_ephemeral_zero_seconds_and_invalid_durations(self):
        self.records([self.completed(0)])
        self.assertEqual(notify.turn_elapsed(self.rollout, TURN, time.time()), 0)
        for value in (float("inf"), float("nan"), True, -3, "300"):
            self.assertIsNone(notify.seconds(value))

    def test_native_codex_ancestor_is_required(self):
        answers = [subprocess.CompletedProcess([], 0, "20 ?? /bin/bash\n"),
                   subprocess.CompletedProcess([], 0, "1 ttys005 /vendor/bin/codex\n"),
                   subprocess.CompletedProcess([], 0, "Sun Sep 6 23:00:00 2026\n")]
        with patch.object(notify.subprocess, "run", side_effect=answers):
            self.assertIn(":ttys005:", notify.codex_terminal())
        with patch.object(notify.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "1 ?? /vendor/bin/codex\n")):
            self.assertIsNone(notify.codex_terminal())

    def install_action_backend(self, action):
        # Bind the session as if its first callback had already resolved it.
        # This lets the actual focus/clear scripts run against only fake
        # Apple Events; no test touches the user's tabs or notifications.
        state = self.root / "notifications/ghostty-sessions"
        state.mkdir(parents=True)
        (state / (SID + ".codex.json")).write_text(json.dumps({"owner": "pid:tty:start"}))
        (state / (SID + ".json")).write_text('{"tab_id":"codex-target-tab"}')
        self.records([self.completed(121)])
        alerter = self.bin / "alerter"
        alerter.write_text(
            '#!/usr/bin/python3\nimport os, sys, time\nfrom pathlib import Path\n'
            'root = Path(os.environ["NOTIFY_TEST_LOG"]).parent\n'
            'if "--help" in sys.argv: print("--close-label --remove")\n'
            'elif "--remove" in sys.argv: (root / "removed").touch()\n'
            'else:\n'
            '    (root / "posted").touch()\n'
            '    time.sleep(0.2 if os.environ["TEST_ACTION"] else 15)\n'
            '    print(os.environ["TEST_ACTION"])\n'
        )
        alerter.chmod(0o755)
        osascript = self.bin / "osascript"
        osascript.write_text(
            '#!/usr/bin/python3\nimport os, sys\nfrom pathlib import Path\n'
            'root = Path(os.environ["NOTIFY_TEST_LOG"]).parent\n'
            'script = sys.stdin.read() if len(sys.argv) == 1 else ""\n'
            'target = os.environ.get("TARGET_TAB_ID", "")\n'
            'if "selected tab of front window" in script:\n'
            '    print("yes" if (root / "selected").exists() else "no")\n'
            'elif target: (root / "focused").write_text(target)\n'
        )
        osascript.chmod(0o755)
        (self.bin / "ps").unlink()  # The watcher validates its own live PID.
        front = self.bin / "lsappinfo"
        front.write_text('#!/bin/sh\nprintf "com.mitchellh.ghostty\\n"\n')
        front.chmod(0o755)
        os.environ.update({
            "GHOSTTY_NOTIFY_ALERTER": str(alerter),
            "GHOSTTY_NOTIFY_BACKEND": "alerter",
            "GHOSTTY_NOTIFY_FOCUS_POLL": "0.1",
            "TEST_ACTION": action,
        })
        self.addCleanup(lambda: subprocess.run(
            ["/bin/bash", str(REPO / "hooks/ghostty-notify-clear.sh"), SID],
            env=notify.environment(self.root), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=5,
        ))
        return state

    def wait_until(self, predicate):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.05)
        self.fail("Notification callback did not reach its expected state")

    def test_body_click_routes_through_real_focus_script_with_codex_state(self):
        self.install_action_backend("@CONTENTCLICKED")
        self.dispatch()
        focused = self.root / "focused"
        self.wait_until(focused.exists)
        self.assertEqual(focused.read_text(), "codex-target-tab")

    def test_go_to_tab_routes_through_real_focus_script_with_codex_state(self):
        self.install_action_backend("Go to tab")
        self.dispatch()
        focused = self.root / "focused"
        self.wait_until(focused.exists)
        self.assertEqual(focused.read_text(), "codex-target-tab")

    def test_dismiss_does_not_focus_codex(self):
        state = self.install_action_backend("Dismiss")
        self.dispatch()
        pid_file = state / (SID + ".alerter-pid")
        self.wait_until(pid_file.exists)
        time.sleep(0.5)
        self.assertFalse((self.root / "focused").exists())

    def test_codex_notification_survives_other_tab_then_clears_on_return(self):
        state = self.install_action_backend("")
        os.environ["GHOSTTY_NOTIFY_CLEAR_ON_FOCUS"] = "1"
        self.dispatch()
        self.wait_until((self.root / "posted").exists)
        time.sleep(0.5)
        self.assertFalse((self.root / "removed").exists())
        (self.root / "selected").touch()
        self.wait_until((self.root / "removed").exists)
        self.wait_until(lambda: not (state / (SID + ".alerter-pid")).exists())
        self.assertFalse((self.root / "focused").exists())


class InstallerTests(unittest.TestCase):
    def test_repairs_misplaced_notify_and_preserves_all_other_settings(self):
        original = 'model = "existing-model"\n[notice.model_migrations]\nold = "new"\n# Code-Notify: Desktop notifications\nnotify = "/Users/me/.code-notify/lib/notifier.sh stop codex"\n[tui]\nnotifications = true\n'
        command = ["/usr/bin/python3", "/a path/codex-notify.py"]
        updated = installer.updated_config(original, command)
        self.assertEqual(installer.tomllib.loads(updated), {
            "notify": command, "model": "existing-model",
            "notice": {"model_migrations": {"old": "new"}}, "tui": {"notifications": ["approval-requested"]},
        })
        self.assertEqual(installer.updated_config(updated, command), updated)

    def test_multiline_legacy_root_notify(self):
        original = 'notify = [\n"/a/.code-notify/notify.sh",\n"codex",\n]\nmodel = "kept"\n'
        result = installer.updated_config(original, ["/usr/bin/python3", "/new/codex-notify.py"])
        self.assertEqual(installer.tomllib.loads(result)["model"], "kept")

    def test_unrelated_callback_is_not_overwritten(self):
        with self.assertRaises(ValueError):
            installer.updated_config('notify = ["/custom/hook"]\n', ["/new"])

    def test_preserves_tui_opt_out_and_other_events(self):
        for before, after in ((False, False),
                              (["agent-turn-complete", "approval-requested"], ["approval-requested"]),
                              (["approval-requested"], ["approval-requested"])):
            original = '[tui]\nnotifications = ' + json.dumps(before) + '\nanimations = false\n'
            result = installer.updated_config(original, ["/new"])
            self.assertEqual(installer.tomllib.loads(result)["tui"], {"notifications": after, "animations": False})

    def test_install_copies_scripts_and_claude_preferences(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            settings = root / "claude.json"
            settings.write_text(json.dumps({"env": {"GHOSTTY_NOTIFY_MIN_ELAPSED": "120", "OTHER": "private"}}))
            installer.install(root / "codex", settings)
            installer.install(root / "codex", settings)
            installed = root / "codex/ghostty-notify"
            self.assertEqual(json.loads((installed / "config.json").read_text())["GHOSTTY_NOTIFY_MIN_ELAPSED"], "120")
            self.assertNotIn("private", (installed / "config.json").read_text())
            for name in installer.FILES:
                self.assertEqual((installed / name).read_bytes(), (REPO / "hooks" / name).read_bytes())


if __name__ == "__main__":
    unittest.main()
