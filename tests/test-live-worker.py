#!/usr/bin/env python3
"""Opt-in live check of the --worker fallback against a running Ghostty.

CI has no Ghostty, and test_native_hooks.py deliberately gives its workers a
terminal that does not exist, so no gated test sends an Apple Event from a
worker process. That is the path that hung for hours on 2026-09-17. This
script keeps the private HOME and the recording notification backend of that
suite and changes one thing: the worker is handed a real terminal device. Its
tab lookup, title marker and restoration are therefore real, while nothing is
posted to Notification Center.

Open a new Ghostty tab for this, a plain shell with nothing drawing in it, and
run the check there (or name that tab's terminal from elsewhere):

    python3 tests/test-live-worker.py
    GHOSTTY_NOTIFY_TTY=/dev/ttys012 python3 tests/test-live-worker.py

The tab is the fixture: it ends up with Ghostty's default title, whatever it
said before. A program that sets the tab's title while the check runs, as
Claude Code does twice a second, overwrites the markers: the runs then fail,
and its title is lost.

A build is selected the same way as for tests/test-live-binding.sh, so that one
setting cannot leave the two checks testing different things:
NATIVE_TEST_BINARY names an executable, GHOSTTY_NOTIFY_NATIVE_APP an app bundle,
the executable wins, and the default is the installed app. RUNS (5),
MAX_SECONDS (3) and LIMIT_SECONDS, after which a worker is declared hung (12),
are overridable. The 2026-09-17 binary hangs on every run.
"""
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import unittest
import uuid

INSTALLED = Path.home() / ("Library/Application Support/claude-ghostty-notify/"
                           "ClaudeGhosttyNotify.app/Contents/MacOS/ghostty-notify-agent")
BUNDLE = os.environ.get("GHOSTTY_NOTIFY_NATIVE_APP")
os.environ.setdefault(
    "NATIVE_TEST_BINARY",
    str(Path(BUNDLE) / "Contents/MacOS/ghostty-notify-agent") if BUNDLE else str(INSTALLED))
import test_native_hooks as suite  # noqa: E402  (reads NATIVE_TEST_BINARY in setUpClass)

RUNS = int(os.environ.get("RUNS", "5"))
MAX_SECONDS = float(os.environ.get("MAX_SECONDS", "3"))
LIMIT_SECONDS = float(os.environ.get("LIMIT_SECONDS", "12"))
TTY = os.environ.get("GHOSTTY_NOTIFY_TTY") or (os.ttyname(0) if sys.stdin.isatty() else "")
# Hex and dashes only: intake silently ignores any other session id.
SID = suite.SID = "deadbeef-{}-{}".format(uuid.uuid4().hex[:4], uuid.uuid4().hex[:4])


class LiveWorker(suite.NativeHookTests):
    bound = []
    current = None
    worker = None

    def setUp(self):
        LiveWorker.current = self
        super().setUp()

    def stop_the_worker(self):
        # Asked first, so that a healthy worker tidies up after itself. Ctrl-C
        # never reaches it, since it left this process group with setsid(), and
        # drain() does not see it either: it runs the binary under test, which
        # lives outside the fixture. A worker allows itself ten seconds.
        if self.worker is None or self.worker.poll() is not None:
            return
        self.worker.terminate()
        try:
            self.worker.wait(timeout=11)
        except subprocess.TimeoutExpired:
            self.worker.kill()
            self.worker.wait()

    def test_worker_binds_delivers_and_exits(self):
        self.start()
        settings = {k: v for k, v in self.env.items() if k.startswith("GHOSTTY_NOTIFY_")}
        settings.update({"GHOSTTY_NOTIFY_BACKEND": "terminal-notifier", "GHOSTTY_NOTIFY_TIMEOUT": "1",
                         "GHOSTTY_NOTIFY_CLEAR_ON_FOCUS": "0", "GHOSTTY_NOTIFY_TTY": TTY})
        now = time.time()
        context = {
            "version": 1, "source": "claude",
            "round_id": (self.state() / (SID + ".round")).read_text().strip(),
            "occurred_at": now, "started_at": now - 700,
            "session_dir": str(self.state()), "rate_dir": str(self.root / "worker-rates"),
            "hooks_dir": str(self.hooks), "settings": settings,
            "home_dir": str(self.root), "search_path": str(self.bin), "tty": TTY,
            "payload": {"session_id": SID, "hook_event_name": "Stop", "cwd": "/work/fixture"},
        }
        started = time.monotonic()
        # The recording backend exits by itself, so the worker can finish too.
        worker = self.worker = subprocess.Popen(
            [str(self.binary), "--worker"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True,
            env={**self.env, "GHOSTTY_NOTIFY_TTY": TTY, "TEST_DELAY_MS": "200"})
        try:
            stdout, _ = worker.communicate(json.dumps(context), timeout=LIMIT_SECONDS)
        except subprocess.TimeoutExpired:
            self.fail("the worker was still running after {:.0f}s".format(LIMIT_SECONDS))
        finally:
            self.stop_the_worker()
            for stream in (worker.stdin, worker.stdout, worker.stderr):
                if stream is not None and not stream.closed:
                    stream.close()
        elapsed = time.monotonic() - started
        self.assertEqual(worker.returncode, 0)
        self.assertEqual(stdout, "")
        self.assertLess(elapsed, MAX_SECONDS)
        self.assertEqual(len(self.notices()), 1)
        # A record still here is a marker the worker did not put back.
        unfinished = sorted(p.name for p in self.state().iterdir()
                            if p.name.endswith(".marker.json") or p.name.startswith("applescript-"))
        self.assertEqual(unfinished, [])
        binding = self.state() / (SID + ".json")
        tab = json.loads(binding.read_text()).get("tab_id") if binding.exists() else None
        self.assertTrue(tab, "no tab was bound")
        LiveWorker.bound.append((tab, elapsed))


def main():
    if not TTY.startswith("/dev/"):
        print("Run inside a Ghostty tab, or set GHOSTTY_NOTIFY_TTY to its terminal device", file=sys.stderr)
        return 2
    print("Testing {}".format(os.environ["NATIVE_TEST_BINARY"]), flush=True)

    def interrupted(signum, frame):
        raise KeyboardInterrupt

    # Being told to stop takes the same path as Ctrl-C.
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    try:
        return run_all()
    except KeyboardInterrupt:
        # Once is enough: a second interrupt here would skip the rest, and leave
        # a worker alive to retitle the tab after it has been reset.
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(signum, signal.SIG_IGN)
        # unittest skips a test's cleanups when it is interrupted.
        test = LiveWorker.current
        if test is not None:
            test.stop_the_worker()
            test.doCleanups()
        print("interrupted", file=sys.stderr)
        return 130
    finally:
        # Whatever a killed worker left showing, the tab goes back to Ghostty's default.
        with open(TTY, "w") as terminal:
            terminal.write("\033]2;\033\\")


def run_all():
    for index in range(1, RUNS + 1):
        outcome = unittest.TextTestRunner(stream=io.StringIO(), verbosity=0).run(
            unittest.TestSuite([LiveWorker("test_worker_binds_delivers_and_exits")]))
        if not outcome.wasSuccessful():
            for _, trace in outcome.failures + outcome.errors:
                print(trace.strip().splitlines()[-1], file=sys.stderr)
            print("FAIL: run {} of {}".format(index, RUNS), file=sys.stderr)
            return 1
        tab, elapsed = LiveWorker.bound[-1]
        print("  ok  run {}: {:.3f}s -> {}".format(index, elapsed, tab))
    tabs = {tab for tab, _ in LiveWorker.bound}
    if len(tabs) != 1:
        print("FAIL: runs disagreed about the tab: {}".format(sorted(tabs)), file=sys.stderr)
        return 1
    print("PASS: {} workers bound {}, delivered once each, slowest {:.3f}s".format(
        RUNS, tabs.pop(), max(elapsed for _, elapsed in LiveWorker.bound)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
