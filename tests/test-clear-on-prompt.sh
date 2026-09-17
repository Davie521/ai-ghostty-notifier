#!/usr/bin/env bash
# Native equivalent of the retired shell fallback-clear suite. Run after
# building the app; private fixtures never touch real notifications or tabs.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE/.."
export PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}"
python3 -m unittest -v \
    test_native_hooks.NativeHookTests.test_native_prompt_removes_external_notice_without_shell_clear_helper \
    test_native_hooks.NativeHookTests.test_direct_clear_with_empty_session_override_uses_default_directory \
    test_native_hooks.NativeHookTests.test_new_prompt_cancels_detached_codex_settle
