#!/usr/bin/env bash
# Post-hook: runs after postCreate.sh core steps.
# Receives $POST_CREATE_EXIT_CODE from the main script.
set -euo pipefail
echo "[post_hook] Running postCreate_post_hook.sh (exit_code=${POST_CREATE_EXIT_CODE:-unset})"
touch /tmp/post_hook_ran
echo "${POST_CREATE_EXIT_CODE:-unset}" > /tmp/post_hook_exit_code
