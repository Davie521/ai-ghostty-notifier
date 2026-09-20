"""The Codex installer: what it writes into hooks.json and config.toml, what it
leaves alone, and that a failed install changes nothing.

Every test works in a throwaway CODEX_HOME. What the installed hooks then do is
covered where the code lives: `swift test --package-path agent` and
tests/test_native_hooks.py.
"""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
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


def registered_hooks(destination):
    """An earlier install that a failed one must leave byte for byte as it was."""
    destination.mkdir(parents=True)
    for source in (REPO / "hooks").glob("*.sh"):
        (destination / source.name).write_text("#!/bin/bash\n# registered by an earlier install\n")
    return {p.name: p.read_bytes() for p in destination.iterdir()}


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
        before = registered_hooks(destination)
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
        before = registered_hooks(destination)
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
