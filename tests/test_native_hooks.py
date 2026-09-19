"""Exercise installed launchers + the real native binary, with private state.

Codex ancestry is a compiled process owning a private PTY, not a fake ps.
Notification executables are recording native fixtures. Apple Events and real
notifications are deliberately not used; terminal-binding state is unit-tested.
"""
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parent.parent
SID = "deadbeef-1010-2020"


class NativeHookTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        candidate = os.environ.get("NATIVE_TEST_BINARY")
        if candidate:
            cls.binary = Path(candidate)
        else:
            output = subprocess.check_output(["swift", "build", "--package-path", str(REPO / "agent"),
                                              "--show-bin-path"], text=True).strip()
            cls.binary = Path(output) / "ghostty-notify-agent"
        if not cls.binary.is_file():
            raise RuntimeError("Build the native runtime before running this suite")
        version = subprocess.check_output([str(cls.binary), "--hook-runtime-version"], text=True).strip()
        if version != "native-hook-v1":
            raise RuntimeError("Native runtime is stale")
        cls.fixture = tempfile.TemporaryDirectory(prefix="ghostty-native-fixture-")
        cls.host = Path(cls.fixture.name) / "host"
        subprocess.run(["/usr/bin/clang", str(REPO / "tests/fixtures/native-host.c"),
                        "-Wall", "-Wextra", "-Werror", "-o", str(cls.host)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.fixture.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ghostty-native-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.hooks = self.root / "hooks"
        self.hooks.mkdir()
        for script in (REPO / "hooks").glob("*.sh"):
            shutil.copy2(script, self.hooks / script.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("codex", "claude", "alerter", "terminal-notifier"):
            shutil.copy2(self.host, self.bin / name)
        self.app = self.root / "Fixture.app"
        executable = self.app / "Contents/MacOS/ghostty-notify-agent"
        executable.parent.mkdir(parents=True)
        executable.symlink_to(self.binary)
        resources = self.app / "Contents/Resources"
        resources.mkdir()
        (resources / "native-hook-v1").write_text("native-hook-v1\n")
        self.log = self.root / "calls.jsonl"
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("GHOSTTY_NOTIFY_")}
        self.env.update({
            "HOME": str(self.root), "CODEX_HOME": str(self.root / "codex-home"),
            "PATH": str(self.bin), "TERM_PROGRAM": "ghostty", "GHOSTTY_RESOURCES_DIR": "",
            "GHOSTTY_NOTIFY_NATIVE_APP": str(self.app), "GHOSTTY_NOTIFY_AGENT_APP": "",
            "GHOSTTY_NOTIFY_BACKEND": "terminal-notifier", "GHOSTTY_NOTIFY_CLEAR_ON_FOCUS": "0",
            "GHOSTTY_NOTIFY_MIN_ELAPSED": "0", "GHOSTTY_NOTIFY_SOUND_ELAPSED": "0",
            "GHOSTTY_NOTIFY_CODEX_SETTLE": "0", "GHOSTTY_NOTIFY_TIMEOUT": "1",
            "GHOSTTY_NOTIFY_TTY": "/not-a-terminal-fixture", "NOTIFY_TEST_LOG": str(self.log),
        })

    def state(self, source="claude"):
        base = self.root / ("codex-home" if source == "codex" else ".claude")
        return base / "notifications/ghostty-sessions"

    def invoke(self, event, source="claude", payload=None, env=None, owner=True):
        entry = {"PreToolUse": "ghostty-tab-save.sh", "UserPromptSubmit": "ghostty-round-reset.sh"}.get(event, "ghostty-notify.sh")
        command = ["/bin/bash", str(self.hooks / ("codex-hook.sh" if source == "codex" else entry))]
        if source == "codex": command.append(event)
        command = [str(self.bin / source)] + ([] if owner else ["--without-tty"]) + command
        data = payload if payload is not None else {"session_id": SID, "hook_event_name": event, "cwd": "/work/中文项目"}
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, env={**self.env, **(env or {})})
        # The fixture CLI calls setsid(), so its pid names the process group a
        # detached worker inherits. Registered after the temporary directory's
        # own cleanup, this runs before it: a worker that outlives the test
        # would otherwise write agent.log back into a directory already removed.
        self.addCleanup(self.stop_hook_group, process.pid)
        try:
            stdout, stderr = process.communicate(data if isinstance(data, str) else json.dumps(data), timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
            raise
        result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        return result

    @staticmethod
    def hook_group_gone(group):
        # killpg(group, 0) can report EPERM during runner teardown, so inspect
        # the exact group instead. Zombies cannot write into the sandbox.
        snapshot = subprocess.check_output(["/bin/ps", "-axo", "pgid=,stat="], text=True)
        return not any(fields[0] == str(group) and not fields[1].startswith("Z")
                       for line in snapshot.splitlines() if len(fields := line.split()) == 2)

    def stop_hook_group(self, group):
        # Let a worker that is about to finish do so, then stop what is left.
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline and not self.hook_group_gone(group):
            time.sleep(0.02)
        for sent in (signal.SIGTERM, signal.SIGKILL):
            if self.hook_group_gone(group): return
            try:
                os.killpg(group, sent)
            except ProcessLookupError:
                return
            except PermissionError:
                if self.hook_group_gone(group): return
                raise
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and not self.hook_group_gone(group):
                time.sleep(0.02)

    def wait(self, predicate, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate(): return
            time.sleep(0.02)
        self.fail("Timed out waiting for native work")

    def calls(self):
        if not self.log.exists(): return []
        results = []
        for line in self.log.read_text().splitlines():
            try: results.append(json.loads(line))
            except json.JSONDecodeError: pass
        return results

    def notices(self):
        return [args for args in self.calls() if "-title" in args or "--title" in args]

    def start(self, source="claude"):
        self.invoke("UserPromptSubmit", source=source)
        if source == "claude": self.invoke("PreToolUse")
        (self.state(source) / (SID + ".start")).write_text(str(int(time.time()) - 700) + "\n")

    def test_claude_round_and_external_delivery_need_no_jq_ps_shell_worker(self):
        # PATH contains only the native recording backends; no jq/ps/osascript/
        # sqlite3/sleep/python/bash can be resolved by runtime subprocesses.
        self.start()
        self.invoke("Stop")
        self.wait(lambda: len(self.notices()) == 1)
        args = self.notices()[0]
        self.assertIn("Glass", args)
        self.assertIn("Task Complete — 中文项目", args)
        self.assertNotIn("-execute", args)
        self.assertNotIn("-activate", args)
        self.assertFalse((self.state() / (SID + ".watch-pid")).exists())
        self.assertFalse((self.state() / (SID + ".start")).exists())

    def test_codex_owner_is_real_native_process_with_tty(self):
        self.start("codex")
        owner = (self.state("codex") / (SID + ".codex-owner")).read_text()
        self.assertRegex(owner, r"^[0-9]+:ttys[0-9]+:[0-9]+\.[0-9]+\n$")
        self.invoke("Stop", source="codex")
        self.wait(lambda: len(self.notices()) == 1)
        self.assertIn("codex-ghostty-notify-" + SID, self.notices()[0])
        self.assertIn("Codex ✅", self.notices()[0])

    def test_no_native_owner_subagent_or_wrong_event_does_not_create_state(self):
        self.invoke("UserPromptSubmit", source="codex", owner=False)
        self.assertFalse(self.state("codex").exists())
        self.invoke("UserPromptSubmit", source="codex", payload={"session_id": SID, "hook_event_name": "Stop"})
        self.invoke("UserPromptSubmit", source="codex", payload={"session_id": SID, "agent_id": "child", "hook_event_name": "UserPromptSubmit"})
        self.assertFalse(self.state("codex").exists())

    def test_malformed_and_non_ghostty_inputs_are_fail_open(self):
        for value in ("{", "[]", '{"session_id":"../escape","hook_event_name":"Stop"}'):
            self.invoke("Stop", payload=value)
        self.invoke("Stop", payload={"session_id": "ＡＢＣ-１２３", "hook_event_name": "Stop"})
        self.invoke("Stop", env={"TERM_PROGRAM": "iTerm.app"})
        self.assertFalse(self.state().exists())
        self.assertEqual(self.notices(), [])

    def test_missing_runtime_is_reported_and_large_stdin_is_drained(self):
        result = self.invoke("Stop", payload="x" * 200000,
                             env={"GHOSTTY_NOTIFY_NATIVE_APP": str(self.root / "missing.app")})
        self.assertIn("native runtime missing", result.stderr)
        self.assertFalse(self.state().exists())

    def test_pretool_is_synchronous_and_repeated_tools_keep_the_start(self):
        self.invoke("UserPromptSubmit")
        self.assertFalse((self.state() / (SID + ".start")).exists())
        self.invoke("PreToolUse")
        first = (self.state() / (SID + ".start")).read_text()
        self.invoke("PreToolUse")
        self.assertEqual((self.state() / (SID + ".start")).read_text(), first)
        self.invoke("UserPromptSubmit")
        self.assertFalse((self.state() / (SID + ".start")).exists())

    def test_codex_config_is_loaded_once_and_environment_wins_even_when_empty(self):
        (self.hooks / "config.json").write_text(json.dumps({
            "GHOSTTY_NOTIFY_AGENT_APP": "/must-not-launch.app", "GHOSTTY_NOTIFY_MIN_ELAPSED": 99999,
            "GHOSTTY_NOTIFY_APP_NAME": "must-not-override-identity"}))
        self.start("codex")
        self.invoke("Stop", source="codex")
        self.wait(lambda: len(self.notices()) == 1)
        self.assertIn("Codex ✅", self.notices()[0])

    def test_unicode_title_and_metacharacters_are_literal_argv(self):
        self.start()
        title = '中文 " $(touch /never) `id` ; $HOME'
        self.invoke("Stop", payload={"session_id": SID, "hook_event_name": "Stop", "session_title": title, "cwd": "/work/project"})
        self.wait(lambda: len(self.notices()) == 1)
        self.assertIn(title + " — project", self.notices()[0])

    def test_empty_app_and_group_overrides_keep_defaults(self):
        self.start()
        self.invoke("Stop", env={"GHOSTTY_NOTIFY_APP_NAME": "", "GHOSTTY_NOTIFY_GROUP_PREFIX": ""})
        self.wait(lambda: len(self.notices()) == 1)
        self.assertIn("Claude ✅", self.notices()[0])
        self.assertIn("ghostty-notify-" + SID, self.notices()[0])

    def test_empty_backend_still_selects_the_ready_native_resident(self):
        self.start()
        resident_executable = self.bin / "ghostty-notify-agent"
        shutil.copy2(self.host, resident_executable)
        resident = subprocess.Popen([str(resident_executable)], stdin=subprocess.DEVNULL,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        def stop_resident():
            if resident.poll() is None:
                resident.terminate()
            try:
                resident.wait(timeout=3)
            except subprocess.TimeoutExpired:
                resident.kill()
                resident.wait(timeout=3)

        self.addCleanup(stop_resident)
        root = self.root / ".claude/notifications/ghostty-agent"
        root.mkdir(parents=True, exist_ok=True)
        (root / "agent.pid").write_text(str(resident.pid))
        (root / "ready").write_text("authorized\n")
        (root / "capabilities").write_text(f"hook-event-v1:{resident.pid}\n")
        (root / "native-hook-ready").write_text(f"native-hook-v1:{resident.pid}\n")
        self.invoke("Stop", env={"GHOSTTY_NOTIFY_BACKEND": "", "GHOSTTY_NOTIFY_AGENT_APP": str(self.app)})
        requests = list((root / "spool").glob("*.json"))
        self.assertEqual(len(requests), 1, "empty BACKEND must mean auto, not bypass the resident")
        event = json.loads(requests[0].read_text())
        self.assertEqual(event["type"], "hook_event")
        self.assertEqual(event["payload"]["session_id"], SID)
        self.assertEqual(event["settings"]["GHOSTTY_NOTIFY_BACKEND"], "")

    def test_duplicate_stop_does_not_deliver_twice(self):
        self.start()
        self.invoke("Stop")
        self.invoke("Stop")
        self.wait(lambda: len(self.notices()) == 1)
        time.sleep(0.2)
        self.assertEqual(len(self.notices()), 1)

    def test_new_prompt_cancels_detached_codex_settle(self):
        self.start("codex")
        self.invoke("Stop", source="codex", env={"GHOSTTY_NOTIFY_CODEX_SETTLE": "0.3"})
        old = (self.state("codex") / (SID + ".round")).read_text()
        self.invoke("UserPromptSubmit", source="codex")
        self.assertNotEqual((self.state("codex") / (SID + ".round")).read_text(), old)
        time.sleep(0.6)
        self.assertEqual(self.notices(), [])
        self.assertTrue((self.state("codex") / (SID + ".start")).exists())

    def test_native_prompt_removes_external_notice_without_shell_clear_helper(self):
        self.start()
        self.invoke("Stop")
        self.wait(lambda: len(self.notices()) == 1)
        self.invoke("UserPromptSubmit", env={"GHOSTTY_NOTIFY_CLEAR_ON_FOCUS": "1"})
        self.wait(lambda: any("-remove" in args for args in self.calls()))
        self.wait(lambda: not (self.state() / (SID + ".native-notice.json")).exists())

    def test_direct_clear_with_empty_session_override_uses_default_directory(self):
        self.start()
        self.invoke("Stop")
        record = self.state() / (SID + ".native-notice.json")
        self.wait(lambda: record.exists())
        result = subprocess.run(["/bin/bash", str(self.hooks / "ghostty-notify-clear.sh"), SID],
                                stdin=subprocess.DEVNULL, capture_output=True,
                                env={**self.env, "GHOSTTY_NOTIFY_SESSION_DIR": ""}, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertFalse(record.exists())
        self.assertTrue(any("-remove" in args for args in self.calls()))

    def test_retired_alerter_setting_uses_display_only_fallback(self):
        self.start()
        self.invoke("Stop", env={"GHOSTTY_NOTIFY_BACKEND": "alerter", "TEST_ACTION": "Dismiss"})
        self.wait(lambda: len(self.notices()) == 1)
        args = self.notices()[0]
        self.assertIn("-title", args)
        self.assertNotIn("--close-label", args)
        self.assertNotIn("Go to tab", args)
        self.assertNotIn("-execute", args)

    def stuck_hook(self, deadline, stderr=subprocess.PIPE):
        # stdin is never closed, so the hook cannot even finish reading its
        # payload. That stands in for every wait nothing in-process can end: on
        # 2026-09-17 it was an Apple Event whose reply was never serviced, and
        # Claude Code sat on "Running PreToolUse hook" for its 600-second limit.
        hook = subprocess.Popen([str(self.binary), "--hook", "claude", "PreToolUse"],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr,
                                env={**self.env, "GHOSTTY_NOTIFY_HOOK_DEADLINE": str(deadline)})

        def cleanup():
            if hook.poll() is None:
                hook.kill()
            hook.wait(timeout=5)
            for stream in (hook.stdin, hook.stdout, hook.stderr):
                if stream is not None:
                    stream.close()

        self.addCleanup(cleanup)
        return hook

    def test_hook_that_cannot_finish_exits_successfully_at_its_deadline(self):
        started = time.monotonic()
        hook = self.stuck_hook(deadline=1)
        self.assertEqual(hook.wait(timeout=8), 0)
        elapsed = time.monotonic() - started
        self.assertGreaterEqual(elapsed, 0.9, "the deadline fired before its budget")
        self.assertLess(elapsed, 5)
        self.assertEqual(hook.stdout.read(), b"", "a hook's stdout is a decision the CLI parses")
        self.assertIn(b"outlived its budget", hook.stderr.read())

    def test_deadline_exit_does_not_wait_for_anyone_to_read_stderr(self):
        # A full pipe nobody drains: the next write to it blocks for good. The
        # deadline reports on stderr, and must not end up waiting on its report.
        reader, writer = os.pipe()
        self.addCleanup(os.close, reader)
        flags = fcntl.fcntl(writer, fcntl.F_GETFL)
        fcntl.fcntl(writer, fcntl.F_SETFL, flags | os.O_NONBLOCK)
        try:
            while True:
                os.write(writer, b"x" * 4096)
        except BlockingIOError:
            pass
        # The flag lives on the open file description the child will share;
        # left set, the child's write would fail fast instead of blocking.
        fcntl.fcntl(writer, fcntl.F_SETFL, flags)
        try:
            hook = self.stuck_hook(deadline=1, stderr=writer)
        finally:
            os.close(writer)
        self.assertEqual(hook.wait(timeout=8), 0)

    def test_sigterm_ends_a_hook_whose_work_cannot_be_cancelled(self):
        hook = self.stuck_hook(deadline=60)
        # Readiness without a sleep: more than a pipe buffer can hold returns
        # from write only once the hook is draining stdin, and it installs its
        # SIGTERM handling before it reads. A signal that arrives earlier meets
        # the default action, which is not the subject here.
        hook.stdin.write(b" " * (1 << 18))
        hook.stdin.flush()
        started = time.monotonic()
        hook.terminate()
        self.assertEqual(hook.wait(timeout=8), 0)
        self.assertLess(time.monotonic() - started, 5)
        self.assertIn(b"cleanup outlived SIGTERM", hook.stderr.read())

    def test_worker_sigterm_reaps_its_backend_and_removes_its_notice(self):
        self.check_worker_shutdown(clear_on_focus=False)

    def test_worker_sigterm_with_clear_enabled_reaps_backend(self):
        self.check_worker_shutdown(clear_on_focus=True)

    def check_worker_shutdown(self, clear_on_focus):
        self.start()
        settings = {key: value for key, value in self.env.items() if key.startswith("GHOSTTY_NOTIFY_")}
        settings.update({"GHOSTTY_NOTIFY_BACKEND": "terminal-notifier", "GHOSTTY_NOTIFY_TIMEOUT": "0",
                         "GHOSTTY_NOTIFY_CLEAR_ON_FOCUS": "1" if clear_on_focus else "0"})
        now = time.time()
        context = {
            "version": 1, "source": "claude",
            "round_id": (self.state() / (SID + ".round")).read_text().strip(),
            "occurred_at": now, "started_at": now - 700,
            "session_dir": str(self.state()), "rate_dir": str(self.root / "worker-rates"),
            "hooks_dir": str(self.hooks), "settings": settings,
            "home_dir": str(self.root), "search_path": str(self.bin),
            "tty": "/not-a-live-terminal-fixture",
            "payload": {"session_id": SID, "hook_event_name": "Stop", "cwd": "/work/fixture"},
        }
        worker = subprocess.Popen([str(self.binary), "--worker"], stdin=subprocess.PIPE,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True,
                                  env={**self.env, "TEST_DELAY_MS": "30000"})
        backend_pid = None

        def alive(pid):
            try:
                os.kill(pid, 0)
                return True
            except ProcessLookupError:
                return False

        def cleanup():
            if worker.poll() is None:
                worker.kill()
            worker.wait(timeout=5)
            # Failure cleanup targets only the backend in this private record.
            if backend_pid is not None and alive(backend_pid):
                os.kill(backend_pid, signal.SIGKILL)

        self.addCleanup(cleanup)
        worker.stdin.write(json.dumps(context))
        worker.stdin.close()
        record = self.state() / (SID + ".native-notice.json")
        self.wait(lambda: record.exists())
        backend_pid = json.loads(record.read_text())["childPID"]
        self.assertTrue(alive(backend_pid))
        # The parent publishes childPID as soon as spawn succeeds, before the
        # child necessarily reaches main(). Test shutdown during an established
        # delivery, not a race that kills the recorder before it logs anything.
        self.wait(lambda: len(self.notices()) == 1)
        # Foundation ignores TMPDIR, so ask the backend where its output went
        # instead of scanning a directory every other process also writes to.
        listing = subprocess.check_output(
            ["/usr/sbin/lsof", "-a", "-p", str(backend_pid), "-d", "1", "-Fn"], text=True)
        output_dir = Path(next(line[1:] for line in listing.splitlines() if line.startswith("n"))).parent
        self.assertTrue(output_dir.name.startswith("ghostty-command-") and output_dir.is_dir(), output_dir)
        worker.terminate()
        worker.wait(timeout=5)
        self.assertFalse(alive(backend_pid), "worker left its notification process running")
        self.assertEqual(worker.returncode, 0)
        self.assertFalse(record.exists())
        self.assertEqual(len(self.notices()), 1, "cancellation must not start a fallback notification")
        # A signalled worker never runs deinit; the directory must already be gone.
        self.assertFalse(output_dir.exists(), "worker left its backend output directory behind")


if __name__ == "__main__":
    unittest.main()
