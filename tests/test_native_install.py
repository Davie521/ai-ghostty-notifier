"""Native runtime installation in private homes, with no service/UI mutation.

Use a real signed release bundle and the public --no-start installation mode.
Service commands are tripwires; no launchd registration or permission prompts
are exercised here. The resident's lifecycle has a separate integration suite.
"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parent.parent
BUNDLE = "ClaudeGhosttyNotify.app"
EXECUTABLE = "Contents/MacOS/ghostty-notify-agent"
MARKER = "Contents/Resources/native-hook-v1"


class NativeInstallTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bundle = REPO / "build" / BUNDLE
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(cls.bundle)],
                       check=True, capture_output=True)
        version = subprocess.check_output([str(cls.bundle / EXECUTABLE), "--hook-runtime-version"], text=True)
        if version.strip() != "native-hook-v1":
            raise RuntimeError("Build the current release bundle before testing installation")
        fixture = tempfile.TemporaryDirectory(prefix="ghostty-install-host-")
        cls.addClassCleanup(fixture.cleanup)
        cls.host = Path(fixture.name) / "host"
        subprocess.run(["/usr/bin/clang", str(REPO / "tests/fixtures/native-host.c"),
                        "-o", str(cls.host)], check=True)

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="ghostty-install-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.home = self.root / "home 中文 & spaces"
        self.home.mkdir()
        self.checkout = self.root / "checkout with spaces"
        (self.checkout / "scripts").mkdir(parents=True)
        for name in ("install-agent.sh", "install-codex.py"):
            shutil.copy2(REPO / "scripts" / name, self.checkout / "scripts" / name)
        shutil.copy2(REPO / "install.sh", self.checkout / "install.sh")
        shutil.copytree(REPO / "hooks", self.checkout / "hooks")
        self.built = self.checkout / "build" / BUNDLE
        shutil.copytree(self.bundle, self.built)
        self.app = self.home / "Library/Application Support/claude-ghostty-notify" / BUNDLE
        self.plist = self.home / "Library/LaunchAgents/io.github.davie521.cgnotify.plist"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # No jq, notification backend or shell worker is available.
        for command in ("uname", "dirname", "id", "mkdir", "mktemp", "ditto", "codesign",
                        "mv", "rm", "rmdir", "cp", "chmod", "cat", "sed", "plutil", "seq", "awk"):
            executable = shutil.which(command, path="/usr/bin:/bin:/usr/sbin:/sbin")
            if executable is None:
                raise RuntimeError("Missing installer utility " + command)
            (self.bin / command).symlink_to(executable)
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith("GHOSTTY_NOTIFY_") and k not in ("CODEX_HOME", "CODEX_SQLITE_HOME")}
        self.env.update({"HOME": str(self.home), "PATH": str(self.bin), "TERM_PROGRAM": "",
                         "GHOSTTY_RESOURCES_DIR": "",
                         "INSTALL_TEST_CALLS": str(self.root / "service-calls")})
        for command in ("launchctl", "pkill", "open", "sleep"):
            self.stub(command, 'printf "%s\\n" "$0" >> "$INSTALL_TEST_CALLS"\nexit 97\n')

    def stub(self, name, body):
        target = self.bin / name
        target.unlink(missing_ok=True)
        target.write_text("#!/bin/bash\n" + body)
        target.chmod(0o755)

    def run_script(self, name, *args, success=True, env=None):
        executable = sys.executable if name.endswith(".py") else "/bin/bash"
        result = subprocess.run([executable, str(self.checkout / name), *args], cwd=self.checkout,
                                env={**self.env, **(env or {})}, capture_output=True, text=True, timeout=15)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / "service-calls").exists(), "installer invoked a service/UI command")
        return result

    def install_app(self):
        return self.run_script("scripts/install-agent.sh", "--no-start")

    def old_app(self):
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / EXECUTABLE).write_text("previous version\n")
        (self.app / EXECUTABLE).chmod(0o755)

    def assert_old_app_intact(self):
        self.assertEqual((self.app / EXECUTABLE).read_text(), "previous version\n")
        self.assertEqual(list(self.app.parent.glob(".native-install.*")), [])

    def test_first_install_and_both_hook_installers_without_jq_or_running_app(self):
        self.install_app()
        self.assertTrue((self.app / MARKER).is_file())
        self.assertFalse(self.plist.exists())
        self.assertFalse((self.home / ".claude/notifications").exists())
        self.run_script("install.sh")
        self.run_script("scripts/install-codex.py")
        for destination in (self.home / ".claude/hooks", self.home / ".codex/ghostty-notify"):
            self.assertEqual((destination / "native-hook.sh").read_bytes(),
                             (REPO / "hooks/native-hook.sh").read_bytes())
            self.assertFalse((destination / "agent-common.sh").exists())
            self.assertFalse((destination / "legacy-notify.sh").exists())
        # Resolve the actual installed bundle (no override or checkout fallback).
        # Explicitly enter Ghostty intake; otherwise non-Ghostty input is
        # intentionally ignored before JSON parsing. Do not inherit this from
        # the developer terminal: hosted CI has no GHOSTTY_RESOURCES_DIR.
        result = subprocess.run(["/bin/bash", str(self.home / ".claude/hooks/ghostty-notify.sh")],
                                input="{", text=True, capture_output=True,
                                env={**self.env, "TERM_PROGRAM": "ghostty"}, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertNotIn("runtime missing", result.stderr)
        self.assertIn("ghostty-notify", result.stderr)

    def test_upgrade_keeps_settings_state_and_unrelated_hooks(self):
        self.old_app()
        state = self.home / ".claude/notifications/ghostty-sessions"
        state.mkdir(parents=True)
        (state / "deadbeef.start").write_text("123\n")
        codex = self.home / ".codex"
        (codex / "ghostty-notify").mkdir(parents=True)
        (codex / "ghostty-notify/config.json").write_text('{"GHOSTTY_NOTIFY_MIN_ELAPSED":"55"}\n')
        other = {"type": "command", "command": "/my/other-hook"}
        (codex / "hooks.json").write_text(json.dumps({"hooks": {"Stop": [{"hooks": [other]}]}}))
        self.install_app()
        self.run_script("scripts/install-codex.py")
        hooks_before = (codex / "hooks.json").read_bytes()
        self.install_app()
        self.run_script("scripts/install-codex.py")
        self.assertEqual((codex / "hooks.json").read_bytes(), hooks_before)
        self.assertEqual(json.loads(hooks_before)["hooks"]["Stop"][0]["hooks"][0], other)
        self.assertEqual((codex / "ghostty-notify/config.json").read_text(),
                         '{"GHOSTTY_NOTIFY_MIN_ELAPSED":"55"}\n')
        self.assertEqual((state / "deadbeef.start").read_text(), "123\n")
        self.assertTrue((self.app / MARKER).is_file())
        self.assertEqual(list(self.app.parent.glob(".native-install.*")), [])

    def test_missing_or_old_app_rejected_before_hook_installation(self):
        for existing in (False, True):
            with self.subTest(existing=existing):
                if existing:
                    self.old_app()
                for script in ("install.sh", "scripts/install-codex.py"):
                    result = self.run_script(script, success=False)
                    self.assertIn("missing or too old", result.stdout + result.stderr)
                self.assertFalse((self.home / ".claude").exists())
                self.assertFalse((self.home / ".codex").exists())

    def test_explicit_empty_native_override_is_not_replaced_with_default(self):
        self.install_app()
        for script in ("install.sh", "scripts/install-codex.py"):
            self.run_script(script, success=False, env={"GHOSTTY_NOTIFY_NATIVE_APP": ""})
        self.assertFalse((self.home / ".claude").exists())
        self.assertFalse((self.home / ".codex").exists())

    def test_old_build_rejected_without_touching_previous_installation(self):
        self.old_app()
        (self.built / MARKER).unlink()
        self.run_script("scripts/install-agent.sh", "--no-start", success=False)
        self.assert_old_app_intact()

    def test_failed_copy_preserves_previous_installation(self):
        self.old_app()
        self.stub("ditto", 'mkdir -p "$2/Contents"\nexit 23\n')
        self.run_script("scripts/install-agent.sh", "--no-start", success=False)
        self.assert_old_app_intact()

    def test_failed_signature_verification_preserves_previous_installation(self):
        self.old_app()
        self.stub("codesign", "exit 24\n")
        self.run_script("scripts/install-agent.sh", "--no-start", success=False)
        self.assert_old_app_intact()

    def test_failed_publish_restores_previous_installation(self):
        self.old_app()
        self.stub("mv", 'case "$1" in */.native-install.*/ClaudeGhosttyNotify.app) exit 25 ;; esac\nexec /bin/mv "$@"\n')
        self.run_script("scripts/install-agent.sh", "--no-start", success=False)
        self.assert_old_app_intact()

    def test_runtime_only_upgrade_refuses_existing_launchagent(self):
        self.old_app()
        self.plist.parent.mkdir(parents=True)
        self.plist.write_text("keep service configuration\n")
        result = self.run_script("scripts/install-agent.sh", "--no-start", success=False)
        self.assertIn("rerun without --no-start", result.stderr)
        self.assert_old_app_intact()
        self.assertEqual(self.plist.read_text(), "keep service configuration\n")

    def test_runtime_only_upgrade_refuses_live_resident_without_launchagent(self):
        self.old_app()
        shutil.copy2(self.host, self.app / EXECUTABLE)
        previous = (self.app / EXECUTABLE).read_bytes()
        resident = subprocess.Popen([str(self.app / EXECUTABLE)], env=self.env,
                                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL)
        def stop_resident():
            resident.terminate()
            resident.wait(timeout=5)
        self.addCleanup(stop_resident)
        state = self.home / ".claude/notifications/ghostty-agent"
        state.mkdir(parents=True)
        (state / "agent.pid").write_text(str(resident.pid))
        for _ in range(100):
            found = subprocess.check_output([str(self.built / EXECUTABLE), "--resident-pid"],
                                            env=self.env, text=True, timeout=5).strip()
            if found == str(resident.pid):
                break
            time.sleep(0.01)
        self.assertEqual(found, str(resident.pid))
        result = self.run_script("scripts/install-agent.sh", "--no-start", success=False)
        self.assertIn("resident " + str(resident.pid) + " is running", result.stderr)
        self.assertIsNone(resident.poll(), "--no-start must never signal the resident")
        self.assertEqual((self.app / EXECUTABLE).read_bytes(), previous)
        self.assertFalse(self.plist.exists())

    def test_runtime_only_install_ignores_unrelated_pid(self):
        state = self.home / ".claude/notifications/ghostty-agent"
        state.mkdir(parents=True)
        (state / "agent.pid").write_text(str(os.getpid()))
        self.install_app()
        self.assertTrue((self.app / MARKER).is_file())

    def registered_hooks(self):
        # An earlier install that a failed one must leave byte for byte as it was.
        destination = self.home / ".claude/hooks"
        destination.mkdir(parents=True)
        for source in (REPO / "hooks").glob("*.sh"):
            (destination / source.name).write_text("#!/bin/bash\n# registered by an earlier install\n")
        return {p.name: p.read_bytes() for p in destination.iterdir()}

    def test_failed_bootstrap_copy_preserves_registered_claude_hooks(self):
        self.install_app()
        before = self.registered_hooks()
        destination = self.home / ".claude/hooks"
        self.stub("cp", 'case "$1" in */native-hook.sh) exit 23 ;; esac\nexec /bin/cp "$@"\n')
        self.run_script("install.sh", success=False)
        self.assertEqual({p.name: p.read_bytes() for p in destination.iterdir()}, before)

    def test_failed_download_preserves_registered_claude_hooks(self):
        self.install_app()
        before = self.registered_hooks()
        destination = self.home / ".claude/hooks"
        # Absence of local source hooks selects the existing download workflow.
        (self.checkout / "hooks").rename(self.checkout / "source-hooks")
        self.stub("curl", "exit 22\n")
        self.run_script("install.sh", success=False)
        self.assertEqual({p.name: p.read_bytes() for p in destination.iterdir()}, before)

    def test_invalid_staged_script_preserves_registered_claude_hooks(self):
        self.install_app()
        before = self.registered_hooks()
        destination = self.home / ".claude/hooks"
        (self.checkout / "hooks/ghostty-tab-save.sh").write_text("#!/bin/bash\nif\n")
        self.run_script("install.sh", success=False)
        self.assertEqual({p.name: p.read_bytes() for p in destination.iterdir()}, before)

    def test_launch_agent_is_valid_for_a_home_with_xml_metacharacters(self):
        # The full install is not run here: it registers with LaunchServices.
        # What it writes is what this mode prints.
        home = self.root / "a&b <c>"
        result = self.run_script("scripts/install-agent.sh", "--print-launch-agent", env={"HOME": str(home)})
        agent = plistlib.loads(result.stdout.encode())
        self.assertEqual(agent["ProgramArguments"], [str(
            home / "Library/Application Support/claude-ghostty-notify" / "ClaudeGhosttyNotify.app" / EXECUTABLE)])
        self.assertEqual(agent["Label"], "io.github.davie521.cgnotify")
        self.assertFalse(home.exists())

    HELPER = '''#!/bin/bash
# Stands for a process of the previous version: on SIGTERM it says whether the
# new bundle is already in place, takes a second to clean up, and says it again.
mark=$1; app=$2
seen() { [[ -e "$app" ]] && echo yes || echo no; }
trap 'echo "asked to stop; new bundle in place: $(seen)" > "$mark"; /bin/sleep 1; echo "finished; new bundle in place: $(seen)" >> "$mark"; exit 0' TERM
echo ready > "$mark.ready"
while :; do /bin/sleep 0.05; done
'''

    def start_full_install(self, home, ps_stub, launchd=""):
        """The whole install, with a stand-in for every service command.

        `launchd` is shell that runs inside the launchctl stand-in after the
        call has been recorded, with the subcommand in $1.
        """
        calls = self.root / "full-install-calls"
        self.stub("launchctl", '''if [[ ! -e "$CALLS" ]]; then
    for staged in "$HOME/Library/Application Support/claude-ghostty-notify"/.native-install.*/*.plist; do
        plutil -lint "$staged" >/dev/null && echo "valid plist staged before the first service command" >> "$CALLS"
    done
fi
[[ "$1" == print ]] || echo "launchctl $1" >> "$CALLS"
STATE="$HOME/.claude/notifications/ghostty-agent"
''' + launchd)
        self.stub("lsregister", 'echo "lsregister $1" >> "$CALLS"\n')
        self.stub("pkill", 'echo "pkill $*" >> "$CALLS"\n')
        # Only the wait for processes to exit really waits; the rest would take a minute.
        self.stub("sleep", '[[ "$1" == 0.25 ]] && exec /bin/sleep 0.05\nexit 0\n')
        # Stands in for the agent answering the permission prompt.
        self.stub("open", 'STATE="$HOME/.claude/notifications/ghostty-agent"\n'
                  '[[ -e "$STATE/agent.pid" ]] && echo "agent.pid was there at the permission check" >> "$CALLS"\n'
                  'mkdir -p "$STATE" && echo authorized > "$STATE/ready"\n')
        self.stub("ps", ps_stub)
        return subprocess.Popen(
            ["/bin/bash", str(self.checkout / "scripts/install-agent.sh")], cwd=self.checkout,
            env={**self.env, "HOME": str(home), "CALLS": str(calls),
                 "GHOSTTY_NOTIFY_LSREGISTER": str(self.bin / "lsregister")},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            # A group of its own, so that a test can press Ctrl-C on it.
            start_new_session=True)

    def full_install(self, home, ps_stub, launchd=""):
        installer = self.start_full_install(home, ps_stub, launchd)
        self.addCleanup(installer.kill)
        output, errors = installer.communicate(timeout=60)
        calls = self.root / "full-install-calls"
        return (subprocess.CompletedProcess(installer.args, installer.returncode, output, errors),
                calls.read_text().splitlines() if calls.exists() else [])

    def previous_version(self, home):
        """An installed bundle of the previous version that says so when it is started."""
        installed = home / "Library/Application Support/claude-ghostty-notify" / BUNDLE
        (installed / "Contents/MacOS").mkdir(parents=True)
        (installed / "Contents/Resources").mkdir()
        (installed / MARKER).write_text("")
        started = self.root / "the-previous-version-was-started"
        (installed / EXECUTABLE).write_text('#!/bin/bash\necho started >> "{}"\n'.format(started))
        (installed / EXECUTABLE).chmod(0o755)
        return installed, started

    def stand_in(self, name, script, installed):
        """A real process for the installer to find. Returns (process, mark file)."""
        mark = self.root / (name.replace(" ", "-") + ".mark")
        process = subprocess.Popen([str(script), str(mark), str(installed)])
        self.addCleanup(process.wait)
        self.addCleanup(process.kill)
        deadline = time.monotonic() + 5
        while not Path(str(mark) + ".ready").exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        return process, mark

    @staticmethod
    def listed(process, path):
        """One line of `ps -o pid=,lstart=,comm=` for a real process under a staged path."""
        started = subprocess.check_output(["/bin/ps", "-o", "lstart=", "-p", str(process.pid)], text=True).strip()
        return "{:>5} {} {}\n".format(process.pid, started, path)

    # The listing is staged; a question about one pid goes to the real ps,
    # since the stand-ins are real processes.
    REAL_PS_FOR_ONE_PID = 'if [[ " $* " == *" -p "* ]]; then exec /bin/ps "$@"; fi\n'

    def test_full_install_waits_for_its_own_processes_and_touches_no_others(self):
        # The only test of the path that starts a service. HOME has the
        # characters that used to break the plist after the old agent had been
        # stopped, and three real processes stand for what may be running.
        home = self.root / "a&b <c>"
        installed = home / "Library/Application Support/claude-ghostty-notify/ClaudeGhosttyNotify.app"
        helper = self.root / "previous-version"
        helper.write_text(self.HELPER)
        helper.chmod(0o755)
        names = ("hook of this installation", "resident started from a checkout", "test agent of another checkout")
        running = {name: self.stand_in(name, helper, installed) for name in names}
        state = home / ".claude/notifications/ghostty-agent"
        state.mkdir(parents=True)
        (state / "agent.pid").write_text("{}\n".format(running[names[1]][0].pid))
        elsewhere = "/another/checkout/build/ClaudeGhosttyNotify.app/" + EXECUTABLE
        (self.root / "process-table").write_text(
            self.listed(running[names[0]][0], installed / EXECUTABLE)
            + self.listed(running[names[1]][0], elsewhere)
            + self.listed(running[names[2]][0], elsewhere)
            # A shell that only mentions the binary, as `ps` shows it: by its executable.
            + "  501 Sun 20 Sep 10:00:00 2026 /bin/zsh\n")
        result, recorded = self.full_install(
            home, self.REAL_PS_FOR_ONE_PID + 'cat "{}"\n'.format(self.root / "process-table"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(recorded[0], "valid plist staged before the first service command")
        self.assertIn("launchctl bootstrap", recorded)
        # Signalled by pid, from the list of executables: nothing is matched by command line any more.
        self.assertEqual([line for line in recorded if line.startswith("pkill")], [])
        for name in names[:2]:
            process, mark = running[name]
            # Asked to stop, given the second it needed, and nothing replaced under it meanwhile.
            self.assertEqual(mark.read_text().splitlines(),
                             ["asked to stop; new bundle in place: no", "finished; new bundle in place: no"], name)
            self.assertEqual(process.wait(timeout=5), 0, name + " was killed rather than waited for")
        bystander, mark = running[names[2]]
        self.assertFalse(mark.exists(), "another checkout's test agent was signalled")
        self.assertIsNone(bystander.poll())
        agent = plistlib.loads((home / "Library/LaunchAgents/io.github.davie521.cgnotify.plist").read_bytes())
        self.assertEqual(agent["ProgramArguments"], [str(installed / EXECUTABLE)])
        self.assertTrue((installed / MARKER).is_file())
        self.assertEqual(list(installed.parent.glob(".native-install.*")), [])

    def test_a_pid_that_was_given_to_another_process_is_left_alone(self):
        # The list of owned processes is acted on for up to twenty seconds. A
        # listed process may exit in that time and its number go to something
        # else, which must then be neither waited for nor killed. The bystander
        # here ignores SIGTERM, so without the check it would sit out the wait
        # and be killed at the end of it.
        home = self.root / "home-with-a-reused-pid"
        installed = home / "Library/Application Support/claude-ghostty-notify/ClaudeGhosttyNotify.app"
        stubborn = self.root / "bystander"
        stubborn.write_text("#!/bin/bash\ntrap '' TERM\necho ready > \"$1.ready\"\nwhile :; do /bin/sleep 0.05; done\n")
        stubborn.chmod(0o755)
        bystander, _ = self.stand_in("bystander with a reused pid", stubborn, installed)
        (self.root / "process-table").write_text(self.listed(bystander, installed / EXECUTABLE))
        # Asked about that pid: the first answer is the real one, and from the
        # second on it is a process that started at another time.
        asked = self.root / "asked-about-the-pid"
        ps_stub = '''if [[ " $* " == *" -p "* ]]; then
    count=$(($(cat "{asked}" 2>/dev/null || echo 0) + 1)); echo "$count" > "{asked}"
    if ((count == 1)); then exec /bin/ps "$@"; fi
    echo "S    Thu  1 Jan 00:00:00 1970"; exit 0
fi
cat "{table}"
'''.format(asked=asked, table=self.root / "process-table")
        result, _ = self.full_install(home, ps_stub)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIsNone(bystander.poll(), "a process that only shares a pid with a listed one was killed")
        # Dropped as soon as it was seen to be another process, not checked 80 times.
        self.assertLess(int(asked.read_text()), 10)

    def test_full_install_ends_with_the_resident_that_launchd_started(self):
        # A hook of a session in use starts the app when it finds none, and can
        # win the moment between the previous agent leaving and launchd
        # starting its own. launchd's copy then bows out with status 0 and is
        # not restarted: a resident runs, and nothing would bring it back.
        home = self.root / "home-with-an-interloper"
        installed = home / "Library/Application Support/claude-ghostty-notify/ClaudeGhosttyNotify.app"
        helper = self.root / "previous-version"
        helper.write_text(self.HELPER)
        helper.chmod(0o755)
        interloper, asked_to_stop = self.stand_in("resident started by a hook", helper, installed)
        launchds, _ = self.stand_in("resident started by launchd", helper, installed)
        (self.root / "table-with-interloper").write_text(self.listed(interloper, installed / EXECUTABLE))
        (self.root / "table-with-launchds").write_text(self.listed(launchds, installed / EXECUTABLE))
        ps_stub = self.REAL_PS_FOR_ONE_PID + '''if [[ -e "$CALLS.kickstarted" ]]; then cat "{after}"
elif [[ -e "$CALLS.bootstrapped" ]]; then cat "{before}"
fi
'''.format(before=self.root / "table-with-interloper", after=self.root / "table-with-launchds")
        launchd = '''case "$1" in
    bootstrap) : > "$CALLS.bootstrapped"; mkdir -p "$STATE"; echo {interloper} > "$STATE/agent.pid" ;;
    kickstart) : > "$CALLS.kickstarted"; mkdir -p "$STATE"; echo {launchds} > "$STATE/agent.pid" ;;
    print) if [[ -e "$CALLS.kickstarted" ]]; then printf '\\tstate = running\\n\\tpid = {launchds}\\n'; else printf '\\tstate = not running\\n'; fi ;;
esac
'''.format(interloper=interloper.pid, launchds=launchds.pid)
        result, recorded = self.full_install(home, ps_stub, launchd)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("launchctl kickstart", recorded)
        self.assertEqual(asked_to_stop.read_text().splitlines()[0], "asked to stop; new bundle in place: yes")
        self.assertEqual(interloper.wait(timeout=5), 0)
        self.assertIsNone(launchds.poll(), "the resident launchd started was stopped as well")
        self.assertIn("running under launchd as pid {}".format(launchds.pid), result.stdout)

    BUSY_HOOK = '''#!/bin/bash
# Stands for a hook of a session in use: asked to stop, it does what the session
# does next and runs a registered hook, through the real launcher.
mark=$1
trap '/usr/bin/env -i HOME="{home}" PATH=/usr/bin:/bin /bin/bash "{hooks}/ghostty-notify.sh" </dev/null 2>"$mark.stderr"; echo "hook exit $?" > "$mark"; exit 0' TERM
echo ready > "$mark.ready"
while :; do /bin/sleep 0.05; done
'''

    STUBBORN = '''#!/bin/bash
trap '' TERM
echo ready > "$1.ready"
while :; do /bin/sleep 0.05; done
'''

    def test_nothing_can_start_the_previous_version_while_it_is_being_stopped(self):
        # A session in use fires hooks all the time. One that starts while the
        # previous version is being stopped is not in the list that is waited
        # for, and what it starts (a worker lives for minutes, a resident for
        # good) would run the old code beside the new. So the way in is shut
        # before the list is made.
        home = self.root / "home with a session in use"
        installed, started = self.previous_version(home)
        hooks = self.root / "registered-hooks"  # As install.sh leaves them: no build beside them.
        shutil.copytree(REPO / "hooks", hooks)
        busy = self.root / "busy-hook"
        busy.write_text(self.BUSY_HOOK.format(home=home, hooks=hooks))
        busy.chmod(0o755)
        process, mark = self.stand_in("hook of a session in use", busy, installed)
        (self.root / "process-table").write_text(self.listed(process, installed / EXECUTABLE))
        result, _ = self.full_install(
            home, self.REAL_PS_FOR_ONE_PID + 'cat "{}"\n'.format(self.root / "process-table"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(mark.read_text(), "hook exit 0\n")
        self.assertFalse(started.exists(), "a hook started the previous version while it was being stopped")
        self.assertIn("native runtime missing", Path(str(mark) + ".stderr").read_text())
        # And open again, as the new version. Compared, not run: running a
        # bundle's binary registers that bundle with LaunchServices.
        self.assertTrue(os.access(installed / EXECUTABLE, os.X_OK))
        self.assertEqual((installed / EXECUTABLE).read_bytes(), (self.built / EXECUTABLE).read_bytes())

    def test_the_previous_version_can_start_again_when_the_install_fails(self):
        home = self.root / "home-where-the-swap-fails"
        installed, _ = self.previous_version(home)
        before = (installed / EXECUTABLE).read_bytes()
        self.stub("mv", '[[ "${!#}" == */previous.app ]] && { echo "mv: staged failure" >&2; exit 1; }\n'
                  'exec /bin/mv "$@"\n')
        result, _ = self.full_install(home, self.REAL_PS_FOR_ONE_PID)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("staged failure", result.stderr)
        self.assertEqual((installed / EXECUTABLE).read_bytes(), before)
        self.assertTrue(os.access(installed / EXECUTABLE, os.X_OK), "the previous version was left unable to start")
        self.assertEqual(list(installed.parent.glob(".native-install.*")), [])

    def test_the_previous_version_can_start_again_when_the_install_is_interrupted(self):
        # Interrupted while it waits for a process that will not go: by a
        # signal to the installer, and by Ctrl-C, which goes to its whole group.
        stubborn = self.root / "stubborn"
        stubborn.write_text(self.STUBBORN)
        stubborn.chmod(0o755)
        interruptions = {"SIGTERM": lambda installer: installer.terminate(),
                         "Ctrl-C": lambda installer: os.killpg(installer.pid, signal.SIGINT)}
        for name, interrupt in interruptions.items():
            with self.subTest(name):
                home = self.root / ("home-of-an-install-interrupted-by-" + name)
                installed, _ = self.previous_version(home)
                process, _ = self.stand_in("hook that will not stop for " + name, stubborn, installed)
                (self.root / "process-table").write_text(self.listed(process, installed / EXECUTABLE))
                installer = self.start_full_install(
                    home, self.REAL_PS_FOR_ONE_PID + 'cat "{}"\n'.format(self.root / "process-table"))
                self.addCleanup(installer.kill)
                deadline = time.monotonic() + 10
                while os.access(installed / EXECUTABLE, os.X_OK) and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertFalse(os.access(installed / EXECUTABLE, os.X_OK), "the way in was never shut")
                interrupt(installer)
                installer.communicate(timeout=30)
                self.assertNotEqual(installer.returncode, 0)
                self.assertTrue(os.access(installed / EXECUTABLE, os.X_OK),
                                "the previous version was left unable to start")
                self.assertEqual(list(installed.parent.glob(".native-install.*")), [])

    def test_a_process_is_not_even_asked_to_stop_once_its_pid_is_another_process(self):
        # The same reuse, earlier: between the listing and the first signal.
        home = self.root / "home-with-a-pid-reused-early"
        installed = home / "Library/Application Support/claude-ghostty-notify/ClaudeGhosttyNotify.app"
        helper = self.root / "previous-version"
        helper.write_text(self.HELPER)
        helper.chmod(0o755)
        bystander, asked_to_stop = self.stand_in("bystander with a pid reused early", helper, installed)
        (self.root / "process-table").write_text(self.listed(bystander, installed / EXECUTABLE))
        ps_stub = ('if [[ " $* " == *" -p "* ]]; then echo "S    Thu  1 Jan 00:00:00 1970"; exit 0; fi\n'
                   'cat "{}"\n'.format(self.root / "process-table"))
        result, _ = self.full_install(home, ps_stub)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(asked_to_stop.exists(), "a process that only shares a pid with a listed one was signalled")
        self.assertIsNone(bystander.poll())

    def listings(self, *tables):
        """A ps whose successive listings are `tables`, and empty after the last.

        The first is the one the installer asks for before it stops anything.
        """
        for number, table in enumerate(tables, start=1):
            (self.root / "listing-{}".format(number)).write_text(table)
        return self.REAL_PS_FOR_ONE_PID + '''number=$(($(cat "$CALLS.listings" 2>/dev/null || echo 0) + 1))
echo "$number" > "$CALLS.listings"
cat "{}/listing-$number" 2>/dev/null || true
'''.format(self.root)

    def previous_versions(self, installed, *names):
        helper = self.root / "previous-version"
        helper.write_text(self.HELPER)
        helper.chmod(0o755)
        running = [self.stand_in(name, helper, installed) for name in names]
        return running, [self.listed(process, installed / EXECUTABLE) for process, _ in running]

    def test_what_appears_while_the_others_are_stopped_is_stopped_before_the_bundle_is_replaced(self):
        # Shutting the way in covers the installed binary. A resident from
        # somewhere else can still turn up, so the list is made again until
        # nothing in it is running.
        home = self.root / "home-with-a-latecomer"
        installed = home / "Library/Application Support/claude-ghostty-notify/ClaudeGhosttyNotify.app"
        running, lines = self.previous_versions(installed, "listed from the start", "latecomer")
        result, _ = self.full_install(home, self.listings(lines[0], lines[0], lines[0] + lines[1]))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for process, mark in running:
            self.assertEqual(mark.read_text().splitlines(),
                             ["asked to stop; new bundle in place: no", "finished; new bundle in place: no"])
            self.assertEqual(process.wait(timeout=5), 0)
        self.assertNotIn("kept appearing", result.stderr)

    def test_liveness_markers_stay_when_it_cannot_be_confirmed_that_nothing_is_left(self):
        # Something new in every list: the markers may describe a resident that
        # is still there, and the permission check would wait two minutes for
        # an answer that resident has already given.
        home = self.root / "home-where-something-keeps-appearing"
        installed = home / "Library/Application Support/claude-ghostty-notify/ClaudeGhosttyNotify.app"
        state = home / ".claude/notifications/ghostty-agent"
        state.mkdir(parents=True)
        (state / "agent.pid").write_text("1\n")
        _, lines = self.previous_versions(installed, "first", "second", "third")
        result, recorded = self.full_install(home, self.listings("", lines[0], lines[1], lines[2]))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("kept appearing", result.stderr)
        self.assertIn("agent.pid was there at the permission check", recorded)

    LATE_LAUNCHD = '''case "$1" in
    kickstart) echo $(($(cat "$CALLS.restarts" 2>/dev/null || echo 0) + 1)) > "$CALLS.restarts"; echo 0 > "$CALLS.looks" ;;
    print)
        if [[ "$(cat "$CALLS.restarts" 2>/dev/null)" == 3 ]]; then
            looks=$(($(cat "$CALLS.looks") + 1)); echo "$looks" > "$CALLS.looks"
            if ((looks >= 3)); then mkdir -p "$STATE"; echo PID > "$STATE/agent.pid"; printf '\\tpid = PID\\n'; exit 0; fi
        fi
        printf '\\tstate = not running\\n' ;;
esac
'''

    def test_the_last_restart_is_waited_for_like_the_others(self):
        # The app publishes its pid a moment after it starts. Here launchd's
        # copy only stays on the third restart, and is seen on the third look.
        home = self.root / "home-where-the-third-restart-works"
        result, recorded = self.full_install(
            home, self.REAL_PS_FOR_ONE_PID, self.LATE_LAUNCHD.replace("PID", str(os.getpid())))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(recorded.count("launchctl kickstart"), 3)
        self.assertIn("running under launchd as pid {}".format(os.getpid()), result.stdout)

    def test_full_install_stops_nothing_when_processes_cannot_be_listed(self):
        # An empty list and a failed listing used to look the same, and the
        # install went on to replace the bundle under whatever was running.
        home = self.root / "home-without-ps"
        result, recorded = self.full_install(home, 'echo "ps: cannot get process list" >&2\nexit 1\n')
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("cannot list running processes", result.stderr)
        self.assertEqual(recorded, [])
        self.assertFalse((home / "Library/Application Support/claude-ghostty-notify/ClaudeGhosttyNotify.app").exists())
        self.assertFalse((home / "Library/LaunchAgents").exists())

    def test_unknown_option_aborts_without_writes(self):
        self.run_script("scripts/install-agent.sh", "--typo", success=False)
        self.assertEqual(list(self.home.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
