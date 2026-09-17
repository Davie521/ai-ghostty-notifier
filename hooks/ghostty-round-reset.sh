#!/bin/bash
# Stable compatibility entry; the shared bootstrap execs the native runtime.
# shellcheck source=hooks/native-hook.sh
source "${BASH_SOURCE[0]%/*}/native-hook.sh" --hook claude UserPromptSubmit
