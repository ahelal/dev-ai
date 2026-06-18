#!/usr/bin/env bash
# Pre-hook: runs before postCreate.sh core steps.
set -euo pipefail
echo "[pre_hook] Running postCreate_pre_hook.sh"
touch /tmp/pre_hook_ran
