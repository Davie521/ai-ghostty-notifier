#!/bin/bash
# Retired duplicate prompt entry. New prompt handling anchors and clears in
# one generation-scoped native event. Keep old installed configurations safe.
if [[ ! -t 0 ]]; then
    while IFS= read -r anchor_line || [[ -n "$anchor_line" ]]; do :; done
fi
exit 0
