"""Native runtime installation in private homes, with no service/UI mutation.

Use a real signed release bundle and the public --no-start installation mode.
Service commands are tripwires; no launchd registration or permission prompts
are exercised here. The resident's lifecycle has a separate integration suite.
"""
import json
import os
from pathlib import Path
import shutil
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
                        "mv", "rm", "rmdir", "cp", "chmod", "cat"):
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

    def test_failed_bootstrap_copy_preserves_registered_claude_hooks(self):
        self.install_app()
        destination = self.home / ".claude/hooks"
        shutil.copytree(REPO / "tests/fixtures/shell-baseline/hooks", destination)
        before = {p.name: p.read_bytes() for p in destination.iterdir()}
        self.stub("cp", 'case "$1" in */native-hook.sh) exit 23 ;; esac\nexec /bin/cp "$@"\n')
        self.run_script("install.sh", success=False)
        self.assertEqual({p.name: p.read_bytes() for p in destination.iterdir()}, before)

    def test_failed_download_preserves_registered_claude_hooks(self):
        self.install_app()
        destination = self.home / ".claude/hooks"
        shutil.copytree(REPO / "tests/fixtures/shell-baseline/hooks", destination)
        before = {p.name: p.read_bytes() for p in destination.iterdir()}
        # Absence of local source hooks selects the existing download workflow.
        (self.checkout / "hooks").rename(self.checkout / "source-hooks")
        self.stub("curl", "exit 22\n")
        self.run_script("install.sh", success=False)
        self.assertEqual({p.name: p.read_bytes() for p in destination.iterdir()}, before)

    def test_invalid_staged_script_preserves_registered_claude_hooks(self):
        self.install_app()
        destination = self.home / ".claude/hooks"
        shutil.copytree(REPO / "tests/fixtures/shell-baseline/hooks", destination)
        before = {p.name: p.read_bytes() for p in destination.iterdir()}
        (self.checkout / "hooks/ghostty-tab-save.sh").write_text("#!/bin/bash\nif\n")
        self.run_script("install.sh", success=False)
        self.assertEqual({p.name: p.read_bytes() for p in destination.iterdir()}, before)

    def test_unknown_option_aborts_without_writes(self):
        self.run_script("scripts/install-agent.sh", "--typo", success=False)
        self.assertEqual(list(self.home.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
