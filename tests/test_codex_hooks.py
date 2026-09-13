"""Drive the installed Codex adapter through the real shared shell scripts.

Every test installs into a throwaway CODEX_HOME with the real installer, then
runs `codex-hook.sh <event>` exactly as ~/.codex/hooks.json would, against a
recording notification backend and a fake `ps` that stands in for the codex
process tree. Nothing touches the developer's own tabs, terminals or
notifications: the fake TTY name cannot exist, so the OSC 2 marker is never
written, and Apple Events are stubbed wherever they would be sent.
"""

from contextlib import closing
import importlib.util
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
    assert spec is not None and spec.loader is not None
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


installer = module("install_codex", REPO / "scripts/install-codex.py")
SID = "019abcde-1111-2222-3333-444455556666"
TURN = "019abcde-aaaa-bbbb-cccc-444455556666"

# ps as the scripts call it: `ps -o <cols> -p <pid>`. Every process reports
# pid 1000 as its parent; 1000 is the codex CLI, whose TTY the test controls.
FAKE_PS = '''#!/usr/bin/python3
import os, sys
cols = sys.argv[2] if len(sys.argv) > 3 and sys.argv[1] == "-o" else ""
pid = sys.argv[-1]
tty = os.environ.get("FAKE_CODEX_TTY", "ttysNONE")
if cols == "ppid=":
    print("1" if pid == "1000" else "1000")
elif cols == "command=":
    print("/vendor/bin/codex" if pid == "1000" else "/bin/bash")
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
            self.installed = installer.install(self.codex_home, claude)
        self.state = self.codex_home / "notifications/ghostty-sessions"
        self.env = patch.dict(os.environ, {
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "HOME": str(self.root),
            "CODEX_HOME": str(self.codex_home),
            "TERM_PROGRAM": "ghostty",
            "GHOSTTY_NOTIFY_BACKEND": "terminal-notifier",
            "GHOSTTY_NOTIFY_CLEAR_ON_FOCUS": "0",
            "NOTIFY_TEST_LOG": str(self.log),
        })
        self.env.start()
        self.addCleanup(self.env.stop)
        for name in ("GHOSTTY_NOTIFY_MIN_ELAPSED", "GHOSTTY_NOTIFY_SOUND_ELAPSED",
                     "GHOSTTY_NOTIFY_TIMEOUT", "GHOSTTY_NOTIFY_AGENT_APP"):
            os.environ.pop(name, None)

    def script(self, path, body):
        path.write_text(body)
        path.chmod(0o755)

    def payload(self, event, **extra):
        return {"session_id": SID, "turn_id": TURN, "cwd": "/tmp/same-project",
                "hook_event_name": event, "transcript_path": str(self.root / "rollout.jsonl"),
                "model": "gpt-6-astra", **extra}

    def run_hook(self, event, argument=None, **extra):
        subprocess.run(
            ["/bin/bash", str(self.installed / "codex-hook.sh"), argument or event],
            input=json.dumps(self.payload(event, **extra)), text=True,
            env=os.environ, check=True, timeout=20,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )

    def notices(self):
        if not self.log.exists():
            return []
        return [dict(zip(args[::2], args[1::2]))
                for args in map(json.loads, self.log.read_text().splitlines())]

    def bind(self, owner="1000:ttysNONE:Sun Sep 13 17:00:00 2026", started_ago=121, title="修复登录"):
        self.state.mkdir(parents=True, exist_ok=True)
        (self.state / (SID + ".codex-owner")).write_text(owner + "\n")
        (self.state / (SID + ".start")).write_text(str(int(time.time()) - started_ago))
        (self.state / (SID + ".title")).write_text(title)

    def test_prompt_records_first_title_and_owner(self):
        self.run_hook("UserPromptSubmit", prompt="修复登录\n第二行")
        self.run_hook("UserPromptSubmit", prompt="another prompt")
        self.assertEqual((self.state / (SID + ".title")).read_text(), "修复登录 第二行")
        self.assertTrue((self.state / (SID + ".codex-owner")).read_text().startswith("1000:ttysNONE:"))

    def test_tool_call_starts_the_timer_under_codex_home(self):
        self.run_hook("PreToolUse", tool_name="Bash", tool_input={"command": "ls"})
        self.assertTrue((self.state / (SID + ".start")).exists())
        self.assertFalse((self.root / ".claude").exists())

    def test_long_round_notifies_with_codex_branding_and_clears_timer(self):
        self.bind()
        self.run_hook("Stop", last_assistant_message="done")
        notice, = self.notices()
        self.assertEqual(notice["-title"], "Codex ✅")
        self.assertEqual(notice["-subtitle"], "修复登录 — same-project")
        # The hook reads the clock itself; a second may tick after bind().
        self.assertIn(notice["-message"], ("Finished after 2m 1s", "Finished after 2m 2s"))
        self.assertEqual(notice["-group"], "codex-ghostty-notify-" + SID)
        self.assertNotIn("-sound", notice)
        self.assertFalse((self.state / (SID + ".start")).exists())

    def test_sound_past_the_long_threshold(self):
        self.bind(started_ago=601)
        self.run_hook("Stop")
        self.assertEqual(self.notices()[0]["-sound"], "Glass")

    def test_short_round_stays_silent(self):
        self.bind(started_ago=30)
        self.run_hook("Stop")
        self.assertEqual(self.notices(), [])

    def test_thread_name_from_codex_database_outranks_first_prompt(self):
        self.bind(title="first prompt")
        with closing(sqlite3.connect(self.codex_home / "state_5.sqlite")) as db, db:
            db.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT)")
            db.execute("INSERT INTO threads VALUES (?, ?)", (SID, "voice chat"))
        self.run_hook("Stop")
        self.assertEqual(self.notices()[0]["-subtitle"], "voice chat — same-project")

    def test_session_without_terminal_is_ignored(self):
        # Codex Desktop threads and `codex mcp-server` children report no TTY.
        os.environ["FAKE_CODEX_TTY"] = "??"
        self.run_hook("UserPromptSubmit", prompt="desktop")
        self.run_hook("PreToolUse", tool_name="Bash", tool_input={"command": "ls"})
        self.run_hook("Stop")
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
        # A Stop payload delivered through the PreToolUse entry would otherwise
        # reach ghostty-tab-save.sh, which never checks the event and would
        # arm a timer for a round that has already ended.
        self.run_hook("Stop", argument="PreToolUse")
        self.assertFalse((self.state / (SID + ".start")).exists())
        self.bind()
        self.run_hook("Stop", session_id="../../escape")
        self.assertEqual(self.notices(), [])

    def test_config_json_supplies_thresholds_unless_env_overrides(self):
        settings = self.installed / "config.json"
        self.assertEqual(json.loads(settings.read_text())["GHOSTTY_NOTIFY_MIN_ELAPSED"], "120")
        settings.write_text(json.dumps({"GHOSTTY_NOTIFY_MIN_ELAPSED": 0}))
        self.bind(started_ago=5)
        self.run_hook("Stop")
        self.assertEqual(len(self.notices()), 1)
        os.environ["GHOSTTY_NOTIFY_MIN_ELAPSED"] = "180"
        self.bind(started_ago=5)
        self.run_hook("Stop")
        self.assertEqual(len(self.notices()), 1)

    # ── Click routing through the real focus/clear scripts ──────────────────
    def install_action_backend(self, action):
        self.bind()
        (self.state / (SID + ".json")).write_text('{"tab_id":"codex-target-tab"}')
        alerter = self.bin / "alerter"
        self.script(alerter,
            '#!/usr/bin/python3\nimport os, sys, time\nfrom pathlib import Path\n'
            'root = Path(os.environ["NOTIFY_TEST_LOG"]).parent\n'
            'if "--help" in sys.argv: print("--close-label --remove")\n'
            'elif "--remove" in sys.argv: (root / "removed").touch()\n'
            'else:\n'
            '    (root / "posted").touch()\n'
            '    time.sleep(0.2 if os.environ["TEST_ACTION"] else 15)\n'
            '    print(os.environ["TEST_ACTION"])\n')
        self.script(self.bin / "osascript",
            '#!/usr/bin/python3\nimport os, sys\nfrom pathlib import Path\n'
            'root = Path(os.environ["NOTIFY_TEST_LOG"]).parent\n'
            'script = sys.stdin.read() if len(sys.argv) == 1 else ""\n'
            'target = os.environ.get("TARGET_TAB_ID", "")\n'
            'if "selected tab of front window" in script:\n'
            '    print("yes" if (root / "selected").exists() else "no")\n'
            'elif target: (root / "focused").write_text(target)\n')
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

    def wait_until(self, predicate):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.05)
        self.fail("notification callback did not reach the expected state")

    def test_go_to_tab_focuses_the_codex_binding(self):
        self.install_action_backend("Go to tab")
        self.run_hook("Stop")
        focused = self.root / "focused"
        self.wait_until(focused.exists)
        self.assertEqual(focused.read_text(), "codex-target-tab")

    def test_dismiss_never_focuses(self):
        self.install_action_backend("Dismiss")
        self.run_hook("Stop")
        self.wait_until((self.state / (SID + ".alerter-pid")).exists)
        time.sleep(0.5)
        self.assertFalse((self.root / "focused").exists())

    def test_alert_survives_other_tab_then_clears_on_return(self):
        self.install_action_backend("")
        os.environ["GHOSTTY_NOTIFY_CLEAR_ON_FOCUS"] = "1"
        self.run_hook("Stop")
        self.wait_until((self.root / "posted").exists)
        time.sleep(0.5)
        self.assertFalse((self.root / "removed").exists())
        (self.root / "selected").touch()
        self.wait_until((self.root / "removed").exists)
        self.wait_until(lambda: not (self.state / (SID + ".alerter-pid")).exists())
        self.assertFalse((self.root / "focused").exists())


class InstallerTests(unittest.TestCase):
    def test_hooks_merge_keeps_others_and_is_idempotent(self):
        destination = Path("/Users/me/.codex/ghostty-notify")
        existing = {"description": "mine", "hooks": {
            "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/my/lint"}]}],
            "Stop": [{"hooks": [
                {"type": "command", "command": '"/old/ghostty-notify/codex-hook.sh" Stop'},
                {"type": "command", "command": "/my/other"},
            ]}],
            "SessionEnd": [{"hooks": [{"type": "command", "command": '"/old/ghostty-notify/codex-hook.sh" x'}]}],
        }}
        merged = installer.merged_hooks(existing, destination)
        self.assertEqual(merged["description"], "mine")
        self.assertEqual(merged["hooks"]["PreToolUse"][0]["hooks"][0]["command"], "/my/lint")
        self.assertEqual(merged["hooks"]["Stop"][0]["hooks"], [{"type": "command", "command": "/my/other"}])
        self.assertNotIn("SessionEnd", merged["hooks"])
        for event in installer.EVENTS:
            ours = [h for g in merged["hooks"][event] for h in g["hooks"] if installer.is_ours(h)]
            self.assertEqual(ours, [{"type": "command", "timeout": 15,
                                     "command": '"/Users/me/.codex/ghostty-notify/codex-hook.sh" ' + event}])
        self.assertEqual(installer.merged_hooks(merged, destination), merged)
        self.assertEqual(installer.merged_hooks({}, destination), installer.merged_hooks(None, destination))

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
        self.assertEqual(installer.without_legacy_notify(updated), updated)

    def test_unrelated_notify_is_left_alone(self):
        original = 'notify = ["/custom/hook"]\nmodel = "kept"\n'
        self.assertEqual(installer.without_legacy_notify(original), original)
        with self.assertRaises(ValueError):
            installer.without_legacy_notify('notify = ["/x/ghostty-notify/codex-notify.py", "extra"]\n')

    def test_tui_turn_alert_is_narrowed_only_when_present(self):
        cases = (('[tui]\nnotifications = true\nanimations = false\n', ["approval-requested"]),
                 ('[tui]\nnotifications = ["agent-turn-complete", "approval-requested"]\nanimations = false\n',
                  ["approval-requested"]))
        for original, expected in cases:
            result = installer.without_tui_turn_alert(original)
            self.assertEqual(installer.tomllib.loads(result)["tui"], {"notifications": expected, "animations": False})
        for untouched in ('model = "x"\n', '[tui]\nnotifications = false\n',
                          '[tui]\nnotifications = ["approval-requested"]\n'):
            self.assertEqual(installer.without_tui_turn_alert(untouched), untouched)

    def test_install_copies_scripts_migrates_config_and_backs_up(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            codex = root / "codex"
            codex.mkdir()
            (codex / "ghostty-notify").mkdir()
            (codex / "ghostty-notify/codex-notify.py").write_text("stale")
            (codex / "config.toml").write_text(
                'notify = ["/usr/bin/python3", "' + str(codex) + '/ghostty-notify/codex-notify.py"]\n'
                'model = "kept"\n[tui]\nnotifications = true\n')
            (codex / "hooks.json").write_text(json.dumps({"hooks": {"SessionStart": [
                {"hooks": [{"type": "command", "command": "/my/start"}]}]}}))
            settings = root / "claude.json"
            settings.write_text(json.dumps({"env": {"GHOSTTY_NOTIFY_MIN_ELAPSED": "120", "OTHER": "private"}}))
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
            self.assertNotIn("private", (installed / "config.json").read_text())
            hooks = json.loads((codex / "hooks.json").read_text())["hooks"]
            self.assertEqual(hooks["SessionStart"][0]["hooks"][0]["command"], "/my/start")
            for event in installer.EVENTS:
                self.assertEqual(len([h for g in hooks[event] for h in g["hooks"] if installer.is_ours(h)]), 1)
            self.assertEqual(installer.tomllib.loads((codex / "config.toml").read_text()),
                             {"model": "kept", "tui": {"notifications": ["approval-requested"]}})
            backups = sorted((codex / "backups").iterdir())
            self.assertEqual([b.suffix for b in backups], [".json", ".toml"])


if __name__ == "__main__":
    unittest.main()
