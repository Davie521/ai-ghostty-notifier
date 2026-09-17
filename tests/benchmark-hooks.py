#!/usr/bin/env python3
"""Compare real Bash entrypoint latency using cached tabs and a recording spool.

All state and executable stubs live in a TemporaryDirectory. No app is launched,
no notification is displayed, and the baseline checkout is only read.
"""
import argparse
from contextlib import ExitStack
import json
import os
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import tempfile
import time


def stop_fixture(process):
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def benchmark(checkout, samples, native_app, host, ghostty_pid):
    with tempfile.TemporaryDirectory(prefix="ghostty-benchmark-") as temporary, ExitStack() as cleanup:
        root = Path(temporary)
        binary = root / "bin"
        binary.mkdir()
        for name, body in {
            "lsappinfo": '#!/bin/bash\nprintf \'"pid"=' + ghostty_pid + ';\\n\'\n',
            "ps": '#!/bin/bash\nprintf \'/bundle/ghostty-notify-agent\\n\'\n',
        }.items():
            path = binary / name
            path.write_text(body)
            path.chmod(0o755)
        program = binary / "ghostty-notify-agent"
        shutil.copy2(host, program)
        resident = subprocess.Popen([str(program)], stdin=subprocess.DEVNULL,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cleanup.callback(stop_fixture, resident)
        agent = root / ".claude/notifications/ghostty-agent"
        agent.mkdir(parents=True)
        (agent / "agent.pid").write_text(str(resident.pid))
        (agent / "ready").write_text("authorized\n")
        (agent / "capabilities").write_text(f"hook-event-v1:{resident.pid}\n")
        (agent / "native-hook-ready").write_text(f"native-hook-v1:{resident.pid}\n")
        sessions, rates = root / "sessions", root / "rates"
        sessions.mkdir()
        rates.mkdir()
        sid = "abc-123"
        (sessions / f"{sid}.json").write_text(json.dumps({"tab_id": "tab-1", "ghostty_pid": ghostty_pid}))
        (sessions / f"{sid}.round").write_text("benchmark-round\n")
        env = {key: value for key, value in os.environ.items() if not key.startswith("GHOSTTY_NOTIFY_")}
        env.update({"HOME": str(root), "PATH": str(binary) + os.pathsep + env["PATH"],
                    "TERM_PROGRAM": "ghostty", "GHOSTTY_NOTIFY_AGENT_APP": str(native_app),
                    "GHOSTTY_NOTIFY_NATIVE_APP": str(native_app), "GHOSTTY_NOTIFY_TTY": "/not-a-live-terminal-fixture",
                    "GHOSTTY_NOTIFY_SESSION_DIR": str(sessions), "GHOSTTY_NOTIFY_RATE_DIR": str(rates),
                    "GHOSTTY_NOTIFY_CLEAR_ON_FOCUS": "0"})
        # Seed the current real owner once, outside timing. This makes cached
        # PreToolUse representative even when the benchmark runs under Claude.
        if (checkout / "hooks/native-hook.sh").is_file():
            subprocess.run(["/bin/bash", str(checkout / "hooks/ghostty-round-reset.sh")],
                           input=json.dumps({"session_id": sid, "hook_event_name": "UserPromptSubmit"}),
                           text=True, env=env, capture_output=True, check=True, timeout=5)
            (sessions / f"{sid}.json").write_text(json.dumps({"tab_id": "tab-1", "ghostty_pid": ghostty_pid}))
            for request in (agent / "spool").glob("*.json"): request.unlink()
        results = {}
        for kind, script in (("cached_pretool", "ghostty-tab-save.sh"), ("stop", "ghostty-notify.sh")):
            timings = []
            for index in range(samples + 5):
                (sessions / f"{sid}.start").write_text(str(int(time.time()) - 1000))
                for stamp in rates.glob("ghostty-notify-*"):
                    if stamp.is_file():
                        stamp.unlink()
                payload = json.dumps({"session_id": sid, "cwd": "/work/benchmark",
                                      "hook_event_name": "PreToolUse" if kind == "cached_pretool" else "Stop",
                                      "session_title": "benchmark"})
                started = time.perf_counter_ns()
                subprocess.run(["/bin/bash", str(checkout / "hooks" / script)], input=payload,
                               text=True, env=env, check=True, capture_output=True, timeout=5)
                elapsed = (time.perf_counter_ns() - started) / 1_000_000
                # A silent early exit must never look like a speedup. Keep
                # validation outside the timed region and drain our fake spool.
                if kind == "cached_pretool":
                    assert (sessions / f"{sid}.start").is_file()
                    assert json.loads((sessions / f"{sid}.json").read_text())["tab_id"] == "tab-1"
                else:
                    requests = list((agent / "spool").glob("*.json"))
                    assert len(requests) == 1, f"expected one delivery, got {requests}"
                    request = json.loads(requests[0].read_text())
                    expected = "hook_event" if any((checkout / "hooks" / name).is_file()
                                                   for name in ("hook-common.sh", "native-hook.sh")) else "notify"
                    assert request["type"] == expected, request
                    actual_sid = request["payload"]["session_id"] if expected == "hook_event" else request["session_id"]
                    assert actual_sid == sid
                    requests[0].unlink()
                if index >= 5:
                    timings.append(elapsed)
            results[kind] = {"median_ms": round(statistics.median(timings), 2),
                             "p95_ms": round(sorted(timings)[int(len(timings) * 0.95)], 2)}
        return results


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--samples", type=int, default=60)
    args = parser.parse_args()
    if args.samples < 20:
        parser.error("at least 20 samples are required")
    checkout = Path(__file__).resolve().parent.parent
    native_app = checkout / "build/ClaudeGhosttyNotify.app"
    assert (native_app / "Contents/Resources/native-hook-v1").exists(), "Build the release app first"
    pid_output = subprocess.check_output(["/usr/bin/lsappinfo", "info", "-only", "pid", "com.mitchellh.ghostty"], text=True)
    ghostty_pid = "".join(re.findall(r"[0-9]+", pid_output))
    assert ghostty_pid, "A running Ghostty is needed for read-only process-cache validation"
    with tempfile.TemporaryDirectory(prefix="ghostty-bench-host-") as folder:
        host = Path(folder) / "host"
        subprocess.run(["/usr/bin/clang", str(checkout / "tests/fixtures/native-host.c"), "-o", str(host)], check=True)
        print(json.dumps({"samples": args.samples, "warmups": 5,
                          "baseline": benchmark(args.baseline.resolve(), args.samples, native_app, host, ghostty_pid),
                          "migration": benchmark(checkout, args.samples, native_app, host, ghostty_pid)}, indent=2))
