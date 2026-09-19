#!/usr/bin/env python3
"""Opt-in live check of the --worker fallback against a running Ghostty.

CI has no Ghostty, and test_native_hooks.py deliberately gives its workers a
terminal that does not exist, so no gated test sends an Apple Event from a
worker process. That is the path that hung for hours on 2026-09-17. This
script keeps the private HOME and the recording notification backend of that
suite and changes one thing: the worker is handed a real terminal device. Its
tab lookup, title marker and restoration are therefore real, while nothing is
posted to Notification Center.

    GHOSTTY_NOTIFY_TTY=/dev/ttys012 python3 tests/test-live-worker.py

NATIVE_TEST_BINARY selects a build (default: the installed app). RUNS (5),
MAX_SECONDS (3), LIMIT_SECONDS, after which a worker is declared hung (12), and
STOP_GRACE_SECONDS, which a worker then gets to stop by itself (11), are
overridable. The 2026-09-17 binary hangs on every run.

A worker that has to be killed while its marker is showing leaves that marker
on a real tab, with the tab's title recorded only inside the fixture. A worker
that overstays is therefore asked to stop first, which makes it put its own
marker back. If it has to be killed after all, the record is copied to /tmp,
the title is put back, and the copy is dropped only once the tab is confirmed
clean. The same happens when the script is interrupted with Ctrl-C, SIGTERM or
SIGHUP. SIGKILL of the script leaves no chance to.
"""
import io
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

INSTALLED = Path.home() / ("Library/Application Support/claude-ghostty-notify/"
                           "ClaudeGhosttyNotify.app/Contents/MacOS/ghostty-notify-agent")
os.environ.setdefault("NATIVE_TEST_BINARY", str(INSTALLED))
import test_native_hooks as suite  # noqa: E402  (reads NATIVE_TEST_BINARY in setUpClass)

RUNS = int(os.environ.get("RUNS", "5"))
MAX_SECONDS = float(os.environ.get("MAX_SECONDS", "3"))
LIMIT_SECONDS = float(os.environ.get("LIMIT_SECONDS", "12"))
# A worker allows itself ten seconds to clean up after SIGTERM.
STOP_GRACE_SECONDS = float(os.environ.get("STOP_GRACE_SECONDS", "11"))
TTY = os.environ.get("GHOSTTY_NOTIFY_TTY", "")
# Hex and dashes only, and unique per invocation: the marker carries it, and the
# recovery below must never act on a marker another run of this script wrote.
SID = suite.SID = "deadbeef-{}-{}".format(uuid.uuid4().hex[:4], uuid.uuid4().hex[:4])
MARKER = "__claude_TAB_MARKER_{}__".format(SID)


def tabs_showing_marker():
    """Ids of the tabs titled with this run's marker; None if Ghostty cannot be asked."""
    script = '''with timeout of 5 seconds
    tell application "Ghostty"
        set found to ""
        repeat with w in windows
            repeat with t in tabs of w
                if (name of t as text) is "%s" then set found to found & (id of t as text) & linefeed
            end repeat
        end repeat
        return found
    end tell
end timeout''' % MARKER
    try:
        asked = subprocess.run(["/usr/bin/osascript", "-e", script], capture_output=True, text=True, timeout=10)
    except subprocess.TimeoutExpired:
        return None
    return asked.stdout.split() if asked.returncode == 0 else None


class LiveWorker(suite.NativeHookTests):
    bound = []
    missed = 0
    current = None

    def setUp(self):
        LiveWorker.current = self
        super().setUp()

    def put_the_title_back(self):
        # A worker killed or failing mid-lookup leaves its marker on a real tab,
        # and the only copy of that tab's title is a record inside a fixture
        # that is about to be deleted. Nothing may still be writing by now.
        try:
            self.drain()
        except AssertionError as error:
            print("fixture processes outlived the run: {}".format(error), file=sys.stderr)
        record = self.state() / (SID + ".marker.json")
        if not record.exists():
            return
        # Kept first and dropped only once the tab is known to be clean, so that
        # no failure below, a terminal that cannot be opened included, can take
        # the title with it.
        kept = Path(tempfile.mkdtemp(prefix="ghostty-live-worker-", dir="/tmp"))
        shutil.copy2(record, kept / record.name)
        clean = False
        try:
            marked = tabs_showing_marker()
            if marked:
                titles = {tab["id"]: tab["title"] for tab in json.loads(record.read_text())["tabs"]}
                for tab in marked:
                    title = titles.get(tab, "")
                    if "_TAB_MARKER_" in title:
                        title = ""  # never a marker; Ghostty shows its default for an empty title
                    # The runtime's packet: no control characters inside the OSC.
                    title = re.sub("[\\x00-\\x1f\\x7f\\x9c]", "", title)
                    with open(TTY, "w") as terminal:
                        terminal.write("\033]2;" + title + "\033\\")
                time.sleep(0.3)
                marked = tabs_showing_marker()
            clean = marked == []
        except (OSError, ValueError, KeyError) as error:
            print("putting the title back failed: {}".format(error), file=sys.stderr)
        if clean:
            shutil.rmtree(kept, ignore_errors=True)
        else:
            print("A tab may still show a binding marker as its title.", file=sys.stderr)
            print("The record holding its real title was kept in {}".format(kept), file=sys.stderr)

    def test_worker_binds_delivers_and_exits(self):
        try:
            self.run_a_worker()
        finally:
            # Not addCleanup: unittest skips cleanups when a test is interrupted,
            # and an interrupted run is exactly when a marker may still be up.
            self.put_the_title_back()

    def run_a_worker(self):
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
        worker = subprocess.Popen([str(self.binary), "--worker"], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                  env={**self.env, "GHOSTTY_NOTIFY_TTY": TTY, "TEST_DELAY_MS": "200"})
        try:
            stdout, _ = worker.communicate(json.dumps(context), timeout=LIMIT_SECONDS)
        except subprocess.TimeoutExpired:
            self.fail("the worker was still running after {:.0f}s".format(LIMIT_SECONDS))
        finally:
            # Also on Ctrl-C, which does not reach a worker: it left this
            # process group with setsid(). Asked to stop first, because a worker
            # puts its own marker back on SIGTERM, and that beats killing it
            # mid-lookup and repairing the tab afterwards.
            if worker.poll() is None:
                worker.terminate()
                try:
                    worker.communicate(timeout=STOP_GRACE_SECONDS)
                except subprocess.TimeoutExpired:
                    worker.kill()
                    worker.communicate()
        elapsed = time.monotonic() - started
        self.assertEqual(worker.returncode, 0)
        self.assertEqual(stdout, "")
        self.assertLess(elapsed, MAX_SECONDS)
        self.assertEqual(len(self.notices()), 1)
        binding = self.state() / (SID + ".json")
        tab = json.loads(binding.read_text()).get("tab_id") if binding.exists() else None
        if not tab:
            # Nothing is wrong when a lookup misses: a TUI that redraws its title
            # between marker and lookup overwrites the marker, and Claude Code
            # animates its title while it works. The notice went out without a
            # tab, as it should. Whether the path binds is for a retry to show.
            leftovers = sorted(p.name for p in self.state().iterdir()
                               if p.name.endswith(".marker.json") or p.name.startswith("applescript-"))
            self.assertEqual(leftovers, [])
            self.skipTest("the lookup missed its marker")
        unfinished = sorted(p.name for p in self.state().iterdir()
                            if p.name.endswith(".marker.json") or p.name.startswith("applescript-"))
        self.assertEqual(unfinished, [])
        LiveWorker.bound.append((tab, elapsed))


def main():
    if not TTY.startswith("/dev/"):
        print("Set GHOSTTY_NOTIFY_TTY to the terminal device of a Ghostty tab", file=sys.stderr)
        return 2
    def interrupted(signum, frame):
        raise KeyboardInterrupt

    # Being told to stop takes the same path as Ctrl-C, through the finally
    # that puts the title back. Only SIGKILL leaves no chance to.
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    try:
        return run_all()
    except KeyboardInterrupt:
        # The interrupt can land anywhere, unittest's own cleanups included, and
        # whatever it cut short is skipped. So finish the job once more from
        # here, with further signals held off until it is done.
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(signum, signal.SIG_IGN)
        if LiveWorker.current is not None:
            try:
                LiveWorker.current.put_the_title_back()
            except Exception as error:  # a fixture interrupted before it was built
                print("cleanup after the interrupt failed: {}".format(error), file=sys.stderr)
        print("interrupted", file=sys.stderr)
        return 130


def run_all():
    for index in range(1, RUNS + 1):
        for attempt in range(1, 4):
            outcome = unittest.TextTestRunner(stream=io.StringIO(), verbosity=0).run(
                unittest.TestSuite([LiveWorker("test_worker_binds_delivers_and_exits")]))
            if not outcome.skipped:
                break
            LiveWorker.missed += 1
        if outcome.skipped:
            print("FAIL: run {} of {}: no tab was bound in three attempts".format(index, RUNS), file=sys.stderr)
            return 1
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
    # Retried misses are normal; a lookup that misses most of the time is not.
    if LiveWorker.missed * 2 > RUNS:
        print("FAIL: {} lookups missed their marker in {} runs".format(LiveWorker.missed, RUNS), file=sys.stderr)
        return 1
    print("PASS: {} workers bound {}, delivered once each, slowest {:.3f}s, {} lookups retried".format(
        RUNS, tabs.pop(), max(elapsed for _, elapsed in LiveWorker.bound), LiveWorker.missed))
    return 0


if __name__ == "__main__":
    sys.exit(main())
