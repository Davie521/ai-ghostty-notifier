"""Release packaging and the one-command installer, in private homes.

scripts/package-release.sh turns the current build into the release assets;
scripts/setup.sh installs them from a file:// "release" laid out like GitHub's
(latest/download/..., download/vX.Y.Z/...), piped into bash the way
`curl ... | bash` does. Installs use --no-start, and every service or UI
command is a tripwire, as in test_native_install.py: no LaunchAgent,
LaunchServices registration or permission prompt is touched.

scripts/register-claude-hooks.py runs under /usr/bin/python3, the 3.9 macOS
ships, because that is what a fresh machine has.
"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

REPO = Path(__file__).resolve().parent.parent
BUNDLE = "ClaudeGhosttyNotify.app"
EXECUTABLE = "Contents/MacOS/ghostty-notify-agent"
REGISTER = REPO / "scripts/register-claude-hooks.py"
LAUNCHERS = ("ghostty-tab-save.sh", "ghostty-round-reset.sh", "ghostty-notify.sh")
EVENTS = ["Notification", "PreToolUse", "Stop", "UserPromptSubmit"]
ASSET = "ai-ghostty-notifier-macos.zip"


def oldest_python():
    system = "/usr/bin/python3"
    if os.access(system, os.X_OK):
        probe = subprocess.run([system, "-c", "import sys; print(sys.version_info >= (3, 9))"],
                               capture_output=True, text=True, timeout=60)
        if probe.returncode == 0 and probe.stdout.strip() == "True":
            return system
    return sys.executable


def commands(settings, event):
    return [hook["command"] for group in settings["hooks"][event] for hook in group["hooks"]]


class RegisterClaudeHooksTests(unittest.TestCase):
    python = oldest_python()

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="ghostty-register-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.hooks = self.root / "config 中文 & spaces" / "hooks"
        self.hooks.mkdir(parents=True)
        for launcher in LAUNCHERS:
            (self.hooks / launcher).write_text("#!/bin/bash\n")
        self.settings = self.root / "settings.json"

    def register(self, *extra, settings=None):
        return subprocess.run([self.python, str(REGISTER), "--settings", str(settings or self.settings),
                               "--hooks-dir", str(self.hooks), *extra],
                              capture_output=True, text=True, timeout=60)

    def backups(self):
        return sorted(self.root.glob("*.ghostty-notify-backup-*"))

    def test_fresh_settings_get_all_four_events(self):
        result = self.register()
        self.assertEqual(result.returncode, 0, result.stderr)
        settings = json.loads(self.settings.read_text())
        self.assertEqual(sorted(settings["hooks"]), EVENTS)
        self.assertEqual(settings["hooks"]["PreToolUse"][0]["matcher"], "")
        self.assertNotIn("matcher", settings["hooks"]["UserPromptSubmit"][0])
        for event in EVENTS:
            [hook] = [h for g in settings["hooks"][event] for h in g["hooks"]]
            self.assertEqual(hook["timeout"], 15)
        # Quoted, because the path has spaces and Claude runs it through a shell.
        self.assertEqual(commands(settings, "Stop"), ["'%s'" % (self.hooks / "ghostty-notify.sh")])
        self.assertEqual(self.backups(), [])

    def test_existing_settings_are_kept_and_backed_up(self):
        original = {"model": "opus", "env": {"X": "1"}, "unknownKey": [1, 2],
                    "hooks": {"Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "/other/stop.sh"}]}],
                              "SessionStart": [{"hooks": [{"type": "command", "command": "/other/start.sh"}]}]}}
        self.settings.write_text(json.dumps(original))
        result = self.register()
        self.assertEqual(result.returncode, 0, result.stderr)
        settings = json.loads(self.settings.read_text())
        for key in ("model", "env", "unknownKey"):
            self.assertEqual(settings[key], original[key])
        self.assertEqual(settings["hooks"]["SessionStart"], original["hooks"]["SessionStart"])
        self.assertEqual(commands(settings, "Stop")[0], "/other/stop.sh")
        self.assertEqual(len(commands(settings, "Stop")), 2)
        [backup] = self.backups()
        self.assertEqual(json.loads(backup.read_text()), original)
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)

    def test_second_run_adds_nothing(self):
        self.assertEqual(self.register().returncode, 0)
        first = self.settings.read_text()
        result = self.register()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already registered", result.stdout)
        self.assertEqual(self.settings.read_text(), first)
        self.assertEqual(self.backups(), [])

    def test_an_existing_manual_entry_is_not_duplicated(self):
        manual = {"hooks": {"PreToolUse": [{"matcher": "", "hooks": [
            {"type": "command", "command": "/Users/someone/.claude/hooks/ghostty-tab-save.sh"}]}]}}
        self.settings.write_text(json.dumps(manual))
        self.assertEqual(self.register().returncode, 0)
        settings = json.loads(self.settings.read_text())
        self.assertEqual(commands(settings, "PreToolUse"), ["/Users/someone/.claude/hooks/ghostty-tab-save.sh"])
        self.assertEqual(sorted(settings["hooks"]), EVENTS)

    def test_unparseable_settings_are_left_untouched(self):
        self.settings.write_text("{not json")
        result = self.register()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.settings.read_text(), "{not json")
        self.assertEqual(self.backups(), [])

    def test_hooks_of_the_wrong_type_are_refused(self):
        self.settings.write_text('{"hooks": []}')
        self.assertEqual(self.register().returncode, 2)
        self.assertEqual(self.settings.read_text(), '{"hooks": []}')

    def test_enabled_plugin_refuses_without_writing(self):
        text = '{"enabledPlugins": {"ai-ghostty-notifier@ai-ghostty-notifier": true}}'
        self.settings.write_text(text)
        result = self.register()
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertEqual(self.settings.read_text(), text)

    def test_a_disabled_plugin_does_not_block_registration(self):
        self.settings.write_text('{"enabledPlugins": {"ai-ghostty-notifier@ai-ghostty-notifier": false}}')
        self.assertEqual(self.register().returncode, 0)

    def test_symlinked_settings_are_written_through(self):
        real = self.root / "dotfiles" / "settings.json"
        real.parent.mkdir()
        real.write_text("{}")
        self.settings.symlink_to(real)
        self.assertEqual(self.register().returncode, 0)
        self.assertTrue(self.settings.is_symlink())
        self.assertEqual(sorted(json.loads(real.read_text())["hooks"]), EVENTS)

    def test_missing_launchers_are_refused(self):
        (self.hooks / "ghostty-notify.sh").unlink()
        self.assertEqual(self.register().returncode, 2)
        self.assertFalse(self.settings.exists())

    def test_a_relative_hooks_dir_is_refused(self):
        # It would be resolved against whatever directory Claude Code runs hooks from.
        result = self.register("--hooks-dir", "hooks")
        self.assertEqual(result.returncode, 2)
        self.assertIn("must be absolute", result.stderr)
        self.assertFalse(self.settings.exists())


class ReleaseSetupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bundle = REPO / "build" / BUNDLE
        if not (cls.bundle / EXECUTABLE).exists():
            raise RuntimeError("Build the bundle (scripts/build-agent.sh) before testing the release")
        with open(cls.bundle / "Contents/Info.plist", "rb") as handle:
            cls.version = plistlib.load(handle)["CFBundleShortVersionString"]
        fixture = tempfile.TemporaryDirectory(prefix="ghostty-release-")
        cls.addClassCleanup(fixture.cleanup)
        cls.out = Path(fixture.name) / "out"
        result = subprocess.run(["/bin/bash", str(REPO / "scripts/package-release.sh"), cls.version, str(cls.out)],
                                capture_output=True, text=True, timeout=120)
        if result.returncode != 0:
            raise RuntimeError("package-release.sh failed:\n" + result.stdout + result.stderr)
        cls.release = Path(fixture.name) / "release"
        for folder in (cls.release / "latest/download", cls.release / "download" / ("v" + cls.version)):
            folder.mkdir(parents=True)
            for name in (ASSET, "setup.sh", "SHA256SUMS"):
                shutil.copy2(cls.out / name, folder / name)

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="ghostty-setup-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.home = self.root / "home 中文 & spaces"
        (self.home / ".claude").mkdir(parents=True)
        self.settings = self.home / ".claude/settings.json"
        self.original_settings = '{"model": "opus"}'
        self.settings.write_text(self.original_settings)
        self.app = self.home / "Library/Application Support/claude-ghostty-notify" / BUNDLE
        self.calls = self.root / "service-calls"
        stubs = self.root / "stubs"
        stubs.mkdir()
        for command in ("launchctl", "open", "pkill"):
            target = stubs / command
            target.write_text('#!/bin/bash\nprintf "%s\\n" "$0 $*" >> "$INSTALL_TEST_CALLS"\nexit 97\n')
            target.chmod(0o755)
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith("GHOSTTY_NOTIFY_")
                    and k not in ("CODEX_HOME", "CODEX_SQLITE_HOME", "CLAUDE_CONFIG_DIR")}
        self.env.update({"HOME": str(self.home),
                         "PATH": f"{stubs}:/usr/bin:/bin:/usr/sbin:/sbin",
                         "GHOSTTY_NOTIFY_RELEASE_URL": self.release.as_uri(),
                         "GHOSTTY_NOTIFY_LSREGISTER": "/usr/bin/true",
                         "INSTALL_TEST_CALLS": str(self.calls)})

    def setup_sh(self, *args, release=None, service_calls=()):
        env = dict(self.env)
        if release is not None:
            env["GHOSTTY_NOTIFY_RELEASE_URL"] = release.as_uri()
        # Piped, exactly as `curl ... | bash -s -- ARGS` runs it.
        result = subprocess.run(["/bin/bash", "-s", "--", *args], input=(self.out / "setup.sh").read_text(),
                                env=env, capture_output=True, text=True, timeout=120)
        # Every service or UI command is a tripwire, except the ones a test expects.
        calls = self.calls.read_text() if self.calls.exists() else ""
        unexpected = [line for line in calls.splitlines() if Path(line.split()[0]).name not in service_calls]
        self.assertEqual(unexpected, [], "setup invoked a service/UI command:\n" + calls)
        return result

    def assert_nothing_installed(self):
        self.assertFalse(self.app.exists())
        self.assertFalse((self.home / ".claude/hooks").exists())
        self.assertEqual(self.settings.read_text(), self.original_settings)

    def test_installs_the_app_and_claude_hooks_from_a_release(self):
        result = self.setup_sh("--no-start", "--claude", "--no-codex", "--allow-unnotarized")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(self.app)], check=True)
        for launcher in LAUNCHERS:
            self.assertTrue((self.home / ".claude/hooks" / launcher).is_file(), launcher)
        settings = json.loads(self.settings.read_text())
        self.assertEqual(settings["model"], "opus")
        self.assertEqual(sorted(settings["hooks"]), EVENTS)
        self.assertIn("What only you can do", result.stdout)
        # One list of next steps, not install.sh's as well.
        self.assertEqual(result.stdout.count("Next steps:"), 0)
        # The way out is this script's own, not a checkout the user does not have.
        self.assertIn("setup.sh | bash -s -- --uninstall", result.stdout)
        self.assertNotIn("install-agent.sh --uninstall", result.stdout)

    def test_claude_config_dir_selects_where_the_hooks_go(self):
        other = self.home / ".claude-b"
        other.mkdir()
        self.env["CLAUDE_CONFIG_DIR"] = str(other)
        result = self.setup_sh("--no-start", "--claude", "--no-codex", "--allow-unnotarized")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((other / "settings.json").exists(), result.stdout)
        self.assertEqual(sorted(json.loads((other / "settings.json").read_text())["hooks"]), EVENTS)
        for launcher in LAUNCHERS:
            self.assertTrue((other / "hooks" / launcher).is_file(), launcher)
        self.assertEqual(self.settings.read_text(), self.original_settings)
        self.assertFalse((self.home / ".claude/hooks").exists())

    def test_a_pinned_version_uses_its_own_download_path(self):
        (self.release / "latest").rename(self.root / "latest-moved")
        self.addCleanup(lambda: (self.root / "latest-moved").rename(self.release / "latest"))
        result = self.setup_sh("--version", self.version, "--no-start", "--no-claude", "--no-codex",
                               "--allow-unnotarized")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.app / EXECUTABLE).exists())

    def test_a_bundle_that_is_not_notarized_is_refused_by_default(self):
        result = self.setup_sh("--no-start", "--claude", "--no-codex")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a notarized Developer ID build", result.stderr)
        self.assert_nothing_installed()

    def test_a_checksum_mismatch_installs_nothing(self):
        tampered = self.root / "tampered"
        shutil.copytree(self.release, tampered)
        sums = tampered / "latest/download/SHA256SUMS"
        sums.write_text(sums.read_text().replace(sums.read_text()[:8], "00000000", 1))
        result = self.setup_sh("--no-start", "--claude", "--no-codex", "--allow-unnotarized", release=tampered)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum mismatch", result.stderr)
        self.assert_nothing_installed()

    def test_a_missing_release_installs_nothing(self):
        result = self.setup_sh("--version", "0.0.0", "--no-start", "--claude", "--allow-unnotarized")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("download failed", result.stderr)
        self.assert_nothing_installed()

    def test_an_unknown_option_installs_nothing(self):
        result = self.setup_sh("--frobnicate")
        self.assertNotEqual(result.returncode, 0)
        self.assert_nothing_installed()

    def test_uninstall_removes_the_app_and_downloads_nothing(self):
        result = self.setup_sh("--no-start", "--no-claude", "--no-codex", "--allow-unnotarized")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        plist = self.home / "Library/LaunchAgents/io.github.davie521.cgnotify.plist"
        plist.parent.mkdir(parents=True, exist_ok=True)
        plist.write_text("<plist/>")
        # Pointed at a release that does not exist: an uninstall that downloaded would fail.
        result = self.setup_sh("--uninstall", release=self.root / "no-release", service_calls=("launchctl", "pkill"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.app.parent.exists())
        self.assertFalse(plist.exists())
        self.assertIn("launchctl bootout gui/", self.calls.read_text())
        self.assertIn("Hooks are still registered", result.stdout)

    def test_a_long_signature_report_does_not_end_setup_early(self):
        # A Developer ID signature makes codesign -dvv report several Authority
        # lines and more after them. A reader that stopped at the first one left
        # codesign to die of SIGPIPE, and under pipefail and set -e setup.sh
        # ended right there with status 141, silently, having installed nothing.
        # This codesign reports a Developer ID first and then more than a pipe
        # holds, so that race is lost every time instead of sometimes.
        fake = self.root / "fake-codesign"
        fake.mkdir()
        (fake / "codesign").write_text(
            '#!/bin/bash\n'
            'if [[ "$1" == "-dvv" ]]; then\n'
            '    echo "Authority=Developer ID Application: Stub Co. (STUBTEAM01)" >&2\n'
            '    for i in $(seq 1 20000); do echo "Filler=$i" >&2; done\n'
            '    exit 0\n'
            'fi\n'
            'exec /usr/bin/codesign "$@"\n')
        (fake / "codesign").chmod(0o755)
        self.env["PATH"] = f"{fake}:{self.env['PATH']}"
        result = self.setup_sh("--no-start", "--no-claude", "--no-codex", "--allow-unnotarized")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("signed by: Developer ID Application: Stub Co. (STUBTEAM01)", result.stdout)
        self.assertTrue((self.app / EXECUTABLE).exists())

    def test_the_archive_carries_what_setup_installs_and_nothing_local(self):
        with zipfile.ZipFile(self.out / ASSET) as archive:
            names = set(archive.namelist())
        root = "ai-ghostty-notifier/"
        for required in ("install.sh", "LICENSE", "VERSION", "scripts/install-agent.sh",
                         "scripts/install-codex.py", "scripts/register-claude-hooks.py",
                         BUNDLE + "/" + EXECUTABLE, *("hooks/" + launcher for launcher in LAUNCHERS)):
            self.assertIn(root + required, names)
        self.assertFalse(any(name.startswith(root + "hooks/bin/") for name in names))
        self.assertNotIn(root + "hooks/hooks.json", names)

    def test_packaging_refuses_a_version_the_app_does_not_report(self):
        result = subprocess.run(["/bin/bash", str(REPO / "scripts/package-release.sh"), "9.9.9",
                                 str(self.root / "out")], capture_output=True, text=True, timeout=60)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("reports " + self.version, result.stderr)
        self.assertFalse((self.root / "out" / ASSET).exists())


if __name__ == "__main__":
    unittest.main()
