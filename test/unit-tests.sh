#!/usr/bin/env bash
#
# Unit tests for dev-ai lib modules.
#
# Runs without podman or devcontainer — tests pure bash logic plus
# CLI behaviour via stub binaries injected into PATH.
#
# Usage:
#   ./test/unit-tests.sh          # run all phases
#   VERBOSE=1 ./test/unit-tests.sh
#
# Requirements: bash 4.3+, node (for _dc_* JSON tests; skipped if absent)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERBOSE="${VERBOSE:-0}"

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
CURRENT_TEST="(none)"
FAILED_TESTS=()

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

_pass() { echo -e "    ${GREEN}✓${NC} $*"; }
_fail() { echo -e "    ${RED}✗${NC} $*"; }
_info() { echo -e "  ${YELLOW}→${NC} $*"; }
_skip() { echo -e "    ${YELLOW}↷${NC} SKIP: $*"; }

assert_equals() {
    local description="$1" expected="$2" actual="$3"
    (( TESTS_RUN++ )) || true
    if [[ "$actual" == "$expected" ]]; then
        (( TESTS_PASSED++ )) || true
        _pass "$description"
    else
        (( TESTS_FAILED++ )) || true
        _fail "$description  (expected='$expected', got='$actual')"
        FAILED_TESTS+=("${CURRENT_TEST}: $description")
    fi
}

assert_contains() {
    local description="$1" needle="$2" haystack="$3"
    (( TESTS_RUN++ )) || true
    if [[ "$haystack" == *"$needle"* ]]; then
        (( TESTS_PASSED++ )) || true
        _pass "$description"
    else
        (( TESTS_FAILED++ )) || true
        _fail "$description  (expected to contain '$needle')"
        FAILED_TESTS+=("${CURRENT_TEST}: $description")
    fi
}

assert_not_contains() {
    local description="$1" needle="$2" haystack="$3"
    (( TESTS_RUN++ )) || true
    if [[ "$haystack" != *"$needle"* ]]; then
        (( TESTS_PASSED++ )) || true
        _pass "$description"
    else
        (( TESTS_FAILED++ )) || true
        _fail "$description  (expected NOT to contain '$needle')"
        FAILED_TESTS+=("${CURRENT_TEST}: $description")
    fi
}

assert_zero_exit() {
    local description="$1"
    shift
    local output exit_code=0
    output=$("$@" 2>&1) || exit_code=$?
    (( TESTS_RUN++ )) || true
    if [[ $exit_code -eq 0 ]]; then
        (( TESTS_PASSED++ )) || true
        _pass "$description"
    else
        (( TESTS_FAILED++ )) || true
        _fail "$description  (exit $exit_code: $output)"
        FAILED_TESTS+=("${CURRENT_TEST}: $description")
    fi
}

assert_nonzero_exit() {
    local description="$1"
    shift
    local exit_code=0
    "$@" >/dev/null 2>&1 || exit_code=$?
    (( TESTS_RUN++ )) || true
    if [[ $exit_code -ne 0 ]]; then
        (( TESTS_PASSED++ )) || true
        _pass "$description  (exit $exit_code)"
    else
        (( TESTS_FAILED++ )) || true
        _fail "$description  (expected non-zero exit, got 0)"
        FAILED_TESTS+=("${CURRENT_TEST}: $description")
    fi
}

assert_true() {
    local description="$1"
    local exit_code=0
    eval "${2:-false}" >/dev/null 2>&1 || exit_code=$?
    (( TESTS_RUN++ )) || true
    if [[ $exit_code -eq 0 ]]; then
        (( TESTS_PASSED++ )) || true
        _pass "$description"
    else
        (( TESTS_FAILED++ )) || true
        _fail "$description  (condition was false)"
        FAILED_TESTS+=("${CURRENT_TEST}: $description")
    fi
}

assert_false() {
    local description="$1"
    local exit_code=0
    eval "${2:-true}" >/dev/null 2>&1 || exit_code=$?
    (( TESTS_RUN++ )) || true
    if [[ $exit_code -ne 0 ]]; then
        (( TESTS_PASSED++ )) || true
        _pass "$description"
    else
        (( TESTS_FAILED++ )) || true
        _fail "$description  (condition was true, expected false)"
        FAILED_TESTS+=("${CURRENT_TEST}: $description")
    fi
}

# ---------------------------------------------------------------------------
# Stub setup — minimal podman + devcontainer shims so dependency checks pass
# ---------------------------------------------------------------------------
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

for _stub in podman devcontainer; do
    printf '#!/bin/bash\nexit 0\n' > "$STUB_DIR/$_stub"
    chmod +x "$STUB_DIR/$_stub"
done
export PATH="$STUB_DIR:$PATH"

DEV_AI="$PROJECT_ROOT/bin/dev-ai"

# ---------------------------------------------------------------------------
# Phase 1 — Syntax checks
# ---------------------------------------------------------------------------

echo ""
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}${BOLD}  Phase 1 — Syntax checks${NC}"
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
CURRENT_TEST="syntax"

for _f in \
    "$PROJECT_ROOT/bin/dev-ai" \
    "$PROJECT_ROOT/lib/utils.sh" \
    "$PROJECT_ROOT/lib/devcontainer_json.sh" \
    "$PROJECT_ROOT/lib/init.sh" \
    "$PROJECT_ROOT/lib/upgrade.sh" \
    "$PROJECT_ROOT/lib/image.sh" \
    "$PROJECT_ROOT/lib/container.sh" \
    "$PROJECT_ROOT/lib/ports.sh" \
    "$PROJECT_ROOT/templates/postCreate.sh" \
    "$PROJECT_ROOT/templates/initialize.sh" \
    "$PROJECT_ROOT/test/run-tests.sh" \
    "$PROJECT_ROOT/test/unit-tests.sh"
do
    _rel="${_f#"$PROJECT_ROOT/"}"
    assert_zero_exit "bash -n $_rel" bash -n "$_f"
done

# ---------------------------------------------------------------------------
# Phase 2 — CLI smoke tests (--version / --help, no workspace needed)
# ---------------------------------------------------------------------------

echo ""
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}${BOLD}  Phase 2 — CLI smoke tests${NC}"
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
CURRENT_TEST="cli-smoke"

_version_output="$("$DEV_AI" --version 2>&1)"
assert_zero_exit "--version exits 0"    "$DEV_AI" --version
assert_contains  "--version prints name" "dev-ai"  "$_version_output"
assert_contains  "--version prints number" "." "$_version_output"

assert_zero_exit "-V exits 0"  "$DEV_AI" -V
assert_zero_exit "--help exits 0" "$DEV_AI" --help
assert_zero_exit "-h exits 0"  "$DEV_AI" -h

_help_output="$("$DEV_AI" --help 2>&1)"
assert_contains "--help shows USAGE"        "USAGE"         "$_help_output"
assert_contains "--help shows --init"       "--init"        "$_help_output"
assert_contains "--help shows --upgrade"    "--upgrade"     "$_help_output"
assert_contains "--help shows --opencode"   "--opencode"    "$_help_output"
assert_contains "--help shows --claude"     "--claude"      "$_help_output"
assert_contains "--help shows --bob"        "--bob"         "$_help_output"
assert_contains "--help shows --model"      "--model"       "$_help_output"
assert_contains "--help shows --execute"    "--execute"     "$_help_output"
assert_contains "--help shows --ports"       "--ports"       "$_help_output"
assert_contains "--help shows --forward-ports" "--forward-ports" "$_help_output"

# ---------------------------------------------------------------------------
# Phase 3 — Arg parsing & error handling
# ---------------------------------------------------------------------------

echo ""
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}${BOLD}  Phase 3 — Arg parsing & error handling${NC}"
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
CURRENT_TEST="arg-parsing"

# Mutually exclusive mode flags
assert_nonzero_exit "--init --upgrade are mutually exclusive"  "$DEV_AI" --init --upgrade /tmp
assert_nonzero_exit "--init --build are mutually exclusive"    "$DEV_AI" --init --build /tmp
assert_nonzero_exit "--build --remount are mutually exclusive" "$DEV_AI" --build --remount /tmp
assert_nonzero_exit "--halt --status are mutually exclusive"   "$DEV_AI" --halt --status /tmp
assert_nonzero_exit "--ports --forward-ports are mutually exclusive" "$DEV_AI" --ports 3000 --forward-ports /tmp
assert_nonzero_exit "--ports --init are mutually exclusive"    "$DEV_AI" --ports 3000 --init /tmp

# Unknown option
assert_nonzero_exit "unknown option -Z exits non-zero"  "$DEV_AI" -Z

# --execute conflicts
assert_nonzero_exit "--execute + --opencode are mutually exclusive"  "$DEV_AI" --execute /bin/sh --opencode
assert_nonzero_exit "--execute + --claude are mutually exclusive"    "$DEV_AI" --execute /bin/sh --claude
assert_nonzero_exit "--execute + --bob are mutually exclusive"       "$DEV_AI" --execute /bin/sh --bob
assert_nonzero_exit "--execute + --github are mutually exclusive"    "$DEV_AI" --execute /bin/sh --github

# --model + --execute conflict
assert_nonzero_exit "--model + --execute are mutually exclusive"  "$DEV_AI" --model foo --execute /bin/sh

# --execute= form (long option with =)
_exec_err="$("$DEV_AI" --execute=/bin/sh --opencode 2>&1 || true)"
assert_contains "--execute=... + --opencode error message" "cannot be combined" "$_exec_err"

# --model= form
_model_err="$("$DEV_AI" --model=foo --execute /bin/sh 2>&1 || true)"
assert_contains "--model=... + --execute error message" "cannot be used with" "$_model_err"

# Missing argument for -e
_missing_err="$("$DEV_AI" -e 2>&1 || true)"
assert_contains "-e with no arg shows error" "requires an argument" "$_missing_err"

# Missing argument for -M
_missing_err="$("$DEV_AI" -M 2>&1 || true)"
assert_contains "-M with no arg shows error" "requires an argument" "$_missing_err"

# ---------------------------------------------------------------------------
# Phase 4 — Workspace validation
# ---------------------------------------------------------------------------

echo ""
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}${BOLD}  Phase 4 — Workspace validation${NC}"
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
CURRENT_TEST="workspace-validation"

# Non-existent directory
assert_nonzero_exit "non-existent workspace dir exits non-zero" \
    "$DEV_AI" /tmp/this-path-does-not-exist-xyz-abc

# Directory without devcontainer config
_no_dc_dir="$(mktemp -d)"
trap "rm -rf '$_no_dc_dir'" RETURN 2>/dev/null || true
assert_nonzero_exit "dir without devcontainer config exits non-zero" \
    "$DEV_AI" "$_no_dc_dir"
_no_dc_err="$("$DEV_AI" "$_no_dc_dir" 2>&1 || true)"
assert_contains "missing devcontainer config error message" "No devcontainer configuration" "$_no_dc_err"
rm -rf "$_no_dc_dir"

# ---------------------------------------------------------------------------
# Phase 5 — lib/utils.sh: unit tests (sourced directly)
# ---------------------------------------------------------------------------

echo ""
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}${BOLD}  Phase 5 — lib/utils.sh functions${NC}"
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
CURRENT_TEST="utils"

VERSION_FILE="$PROJECT_ROOT/VERSION"
# Source only utils — no other globals needed for this module
source "$PROJECT_ROOT/lib/utils.sh"

# --- version_is_newer ---
_info "version_is_newer"
assert_true  "1.2.3 > 1.2.2"         "version_is_newer 1.2.3 1.2.2"
assert_false "1.2.2 not > 1.2.3"      "version_is_newer 1.2.2 1.2.3"
assert_false "1.2.3 not > 1.2.3"      "version_is_newer 1.2.3 1.2.3"
assert_true  "2.0.0 > 1.9.9"          "version_is_newer 2.0.0 1.9.9"
assert_true  "1.10.0 > 1.9.0 (numeric)" "version_is_newer 1.10.0 1.9.0"
assert_true  "1.0.0 > 0.99.99"        "version_is_newer 1.0.0 0.99.99"
assert_false "empty strings"           "version_is_newer '' ''"
assert_true  "0.7.5 > 0.0.1"          "version_is_newer 0.7.5 0.0.1"

# --- get_project_version ---
_info "get_project_version"
_gv="$(get_project_version)"
assert_contains "get_project_version returns non-empty" "." "$_gv"

# --- extract_script_version ---
_info "extract_script_version"
_tmpf="$(mktemp)"
trap "rm -f '$_tmpf'" RETURN 2>/dev/null || true

# Shell stamp
printf '#!/bin/bash\n# Version: 1.2.3\necho hello\n' > "$_tmpf"
assert_equals "extract shell version stamp" "1.2.3" "$(extract_script_version "$_tmpf")"

# JSON stamp
printf '{\n// Version: 2.3.4\n  "image": "foo"\n}\n' > "$_tmpf"
assert_equals "extract JSON version stamp" "2.3.4" "$(extract_script_version "$_tmpf")"

# No stamp
printf '#!/bin/bash\necho hello\n' > "$_tmpf"
assert_equals "no stamp returns empty" "" "$(extract_script_version "$_tmpf")"

# Non-existent file
assert_equals "non-existent file returns empty" "" "$(extract_script_version /tmp/no-such-file-xyz)"

# --- _stamp_version ---
_info "_stamp_version"
printf '#!/bin/bash\necho hello\n' > "$_tmpf"
_stamp_version "$_tmpf" "3.4.5"
assert_contains "_stamp_version inserts # stamp" "# Version: 3.4.5" "$(cat "$_tmpf")"
assert_contains "_stamp_version preserves shebang on line 1" "#!/bin/bash" "$(head -1 "$_tmpf")"

printf '{\n  "image": "foo"\n}\n' > "$_tmpf"
_stamp_version "$_tmpf" "3.4.5" "//"
assert_contains "_stamp_version inserts // stamp" "// Version: 3.4.5" "$(cat "$_tmpf")"
assert_contains "_stamp_version preserves first line" "{" "$(head -1 "$_tmpf")"

# --- _safe_cp ---
_info "_safe_cp"
_src="$(mktemp)"
_dst="$(mktemp)"
echo "source content" > "$_src"
_safe_cp "$_src" "$_dst"
assert_equals "_safe_cp copies content" "source content" "$(cat "$_dst")"

# Copy over a symlink
_link="$(mktemp -u)"
ln -s "$_src" "$_link"
_safe_cp "$_src" "$_link"
assert_equals "_safe_cp replaces symlink" "source content" "$(cat "$_link")"
assert_true "_safe_cp result is a regular file, not symlink" "test -f '$_link' && ! test -L '$_link'"
rm -f "$_src" "$_dst" "$_link"

# --- ensure_gitignore_env_entry ---
_info "ensure_gitignore_entry (.env)"
_tdir="$(mktemp -d)"
ensure_gitignore_entry "$_tdir" ".env"
assert_zero_exit "gitignore created" test -f "$_tdir/.gitignore"
assert_contains "gitignore has .env" ".env" "$(cat "$_tdir/.gitignore")"

# Idempotent — second call should not duplicate
ensure_gitignore_entry "$_tdir" ".env"
_count="$(grep -c '\.env' "$_tdir/.gitignore" || true)"
assert_equals ".env entry not duplicated" "1" "$_count"
rm -rf "$_tdir"

# --- ensure_gitignore_tmp_entry ---
_info "ensure_gitignore_entry (.tmp)"
_tdir="$(mktemp -d)"
ensure_gitignore_entry "$_tdir" ".tmp"
assert_contains "gitignore has .tmp" ".tmp" "$(cat "$_tdir/.gitignore")"

ensure_gitignore_entry "$_tdir" ".tmp"
_count="$(grep -c '\.tmp' "$_tdir/.gitignore" || true)"
assert_equals ".tmp entry not duplicated" "1" "$_count"
rm -rf "$_tdir"

# ---------------------------------------------------------------------------
# Phase 6 — lib/devcontainer_json.sh: _dc_* function tests
# ---------------------------------------------------------------------------

echo ""
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}${BOLD}  Phase 6 — lib/devcontainer_json.sh functions${NC}"
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
CURRENT_TEST="devcontainer_json"

if ! command -v node >/dev/null 2>&1; then
    _skip "node not found — skipping _dc_* tests"
else
    source "$PROJECT_ROOT/lib/agents.sh"
    source "$PROJECT_ROOT/lib/devcontainer_json.sh"

    _dcjson="$(mktemp --suffix=.json)"
    trap "rm -f '$_dcjson'" RETURN 2>/dev/null || true

    # Helper: write a fresh minimal JSON
    _write_minimal_json() {
        printf '{\n  "image": "mcr.microsoft.com/devcontainers/base:ubuntu",\n  "remoteUser": "root"\n}\n' \
            > "$_dcjson"
    }

    # --- _dc_get_image ---
    _info "_dc_get_image"
    _write_minimal_json
    assert_equals "_dc_get_image" \
        "mcr.microsoft.com/devcontainers/base:ubuntu" \
        "$(_dc_get_image "$_dcjson")"

    # --- _dc_has_name / _dc_get_name / _dc_set_name ---
    _info "_dc_has_name / _dc_get_name / _dc_set_name"
    _write_minimal_json
    assert_false  "_dc_has_name returns false when absent" "_dc_has_name '$_dcjson'"
    _dc_set_name "$_dcjson" "my-project"
    assert_true   "_dc_has_name returns true after set"    "_dc_has_name '$_dcjson'"
    assert_equals "_dc_get_name returns set value" "my-project" "$(_dc_get_name "$_dcjson")"
    # Idempotent: set again with same value
    _dc_set_name "$_dcjson" "my-project"
    assert_equals "_dc_set_name is idempotent" "my-project" "$(_dc_get_name "$_dcjson")"

    # --- _dc_has_all_mounts / _dc_add_agent_mounts (copilot) ---
    _info "_dc_has_all_mounts / _dc_add_agent_mounts (copilot)"
    _write_minimal_json
    assert_false "_dc_has_all_mounts false when absent (copilot)" "_dc_has_all_mounts '$_dcjson' copilot"
    _dc_add_agent_mounts "$_dcjson" copilot
    assert_true  "_dc_has_all_mounts true after add (copilot)"   "_dc_has_all_mounts '$_dcjson' copilot"
    # Idempotent: adding again must not duplicate
    _dc_add_agent_mounts "$_dcjson" copilot
    _mount_count="$(node -e "
        const d=JSON.parse(require('fs').readFileSync('$_dcjson'));
        const n=(d.mounts||[]).filter(m=>/\.copilot/.test(String(m))).length;
        console.log(n);")"
    assert_equals "_dc_add_agent_mounts (copilot) not duplicated on second add" "1" "$_mount_count"

    # --- _dc_has_all_mounts / _dc_add_agent_mounts (opencode) ---
    _info "_dc_has_all_mounts / _dc_add_agent_mounts (opencode)"
    _write_minimal_json
    assert_false "_dc_has_all_mounts false when absent (opencode)" "_dc_has_all_mounts '$_dcjson' opencode"
    _dc_add_agent_mounts "$_dcjson" opencode
    assert_true  "_dc_has_all_mounts true after add (opencode)"   "_dc_has_all_mounts '$_dcjson' opencode"
    _dc_add_agent_mounts "$_dcjson" opencode
    _oc_count="$(node -e "
        const d=JSON.parse(require('fs').readFileSync('$_dcjson'));
        const n=(d.mounts||[]).filter(m=>/opencode/.test(String(m))).length;
        console.log(n);")"
    assert_equals "_dc_add_agent_mounts (opencode): 2 entries (config+data), not duplicated" "2" "$_oc_count"

    # --- _dc_has_all_mounts / _dc_add_agent_mounts (claude) ---
    _info "_dc_has_all_mounts / _dc_add_agent_mounts (claude)"
    _write_minimal_json
    assert_false "_dc_has_all_mounts false when absent (claude)" "_dc_has_all_mounts '$_dcjson' claude"
    _dc_add_agent_mounts "$_dcjson" claude
    assert_true  "_dc_has_all_mounts true after add (claude)"    "_dc_has_all_mounts '$_dcjson' claude"
    _dc_add_agent_mounts "$_dcjson" claude
    _cl_count="$(node -e "
        const d=JSON.parse(require('fs').readFileSync('$_dcjson'));
        const n=(d.mounts||[]).filter(m=>/\.claude/.test(String(m))).length;
        console.log(n);")"
    assert_equals "_dc_add_agent_mounts (claude) not duplicated on second add" "1" "$_cl_count"

    # --- _dc_has_all_mounts / _dc_add_agent_mounts (bob) ---
    _info "_dc_has_all_mounts / _dc_add_agent_mounts (bob)"
    _write_minimal_json
    assert_false "_dc_has_all_mounts false when absent (bob)" "_dc_has_all_mounts '$_dcjson' bob"
    _dc_add_agent_mounts "$_dcjson" bob
    assert_true  "_dc_has_all_mounts true after add (bob)"   "_dc_has_all_mounts '$_dcjson' bob"
    _dc_add_agent_mounts "$_dcjson" bob
    _bob_count="$(node -e "
        const d=JSON.parse(require('fs').readFileSync('$_dcjson'));
        const n=(d.mounts||[]).filter(m=>/\.bob/.test(String(m))).length;
        console.log(n);")"
    assert_equals "_dc_add_agent_mounts (bob) not duplicated on second add" "1" "$_bob_count"

    # --- _dc_get_init_cmd / _dc_set_init_cmd ---
    _info "_dc_get_init_cmd / _dc_set_init_cmd"
    _write_minimal_json
    assert_equals "_dc_get_init_cmd empty when absent" "" "$(_dc_get_init_cmd "$_dcjson" || true)"
    _dc_set_init_cmd "$_dcjson"
    assert_contains "_dc_get_init_cmd returns initialize.sh" "initialize.sh" \
        "$(_dc_get_init_cmd "$_dcjson")"
    # Idempotent
    _dc_set_init_cmd "$_dcjson"
    _ic_count="$(node -e "
        const d=JSON.parse(require('fs').readFileSync('$_dcjson'));
        console.log(Array.isArray(d.initializeCommand) ? 1 : 0);")"
    assert_equals "_dc_set_init_cmd is idempotent" "1" "$_ic_count"

    # --- _dc_get_post_create_cmd / _dc_has_post_create_script / _dc_set_post_create_cmd ---
    _info "_dc_get_post_create_cmd / _dc_has_post_create_script / _dc_set_post_create_cmd"
    _write_minimal_json
    assert_equals "_dc_get_post_create_cmd empty when absent" "" \
        "$(_dc_get_post_create_cmd "$_dcjson" || true)"
    assert_false "_dc_has_post_create_script false when absent" \
        "_dc_has_post_create_script '$_dcjson'"

    # Set to a wrong value first (simulates old devcontainer.json)
    _dc_modify "$_dcjson" '.postCreateCommand = "npm install -g @github/copilot"'
    assert_false "_dc_has_post_create_script false with wrong command" \
        "_dc_has_post_create_script '$_dcjson'"
    assert_contains "_dc_get_post_create_cmd returns current value" \
        "npm install" "$(_dc_get_post_create_cmd "$_dcjson")"

    _dc_set_post_create_cmd "$_dcjson"
    assert_true "_dc_has_post_create_script true after set" \
        "_dc_has_post_create_script '$_dcjson'"
    assert_contains "_dc_get_post_create_cmd returns postCreate.sh" \
        "postCreate.sh" "$(_dc_get_post_create_cmd "$_dcjson")"
    _dc_set_post_create_cmd "$_dcjson"
    assert_true "_dc_set_post_create_cmd is idempotent" \
        "_dc_has_post_create_script '$_dcjson'"

    # --- _dc_has_env_file_run_arg / _dc_add_env_file_run_arg ---
    _info "_dc_has_env_file_run_arg / _dc_add_env_file_run_arg"
    _write_minimal_json
    assert_false "_dc_has_env_file_run_arg false when absent" "_dc_has_env_file_run_arg '$_dcjson'"
    _dc_add_env_file_run_arg "$_dcjson"
    assert_true  "_dc_has_env_file_run_arg true after add"    "_dc_has_env_file_run_arg '$_dcjson'"
    _dc_add_env_file_run_arg "$_dcjson"
    _ra_count="$(node -e "
        const d=JSON.parse(require('fs').readFileSync('$_dcjson'));
        const n=(d.runArgs||[]).filter(a=>String(a).includes('.devcontainer/.env')).length;
        console.log(n);")"
    assert_equals "_dc_add_env_file_run_arg not duplicated" "1" "$_ra_count"

    # --- non-existent file ---
    _info "_dc_* on non-existent file"
    assert_false "_dc_has_all_mounts returns false for missing file (copilot)" \
        "_dc_has_all_mounts /tmp/no-such-file-xyz.json copilot"
    assert_false "_dc_has_name returns false for missing file" \
        "_dc_has_name /tmp/no-such-file-xyz.json"

    rm -f "$_dcjson"
fi

# ---------------------------------------------------------------------------
# Phase 6b — lib/ports.sh functions
# ---------------------------------------------------------------------------

echo ""
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}${BOLD}  Phase 6b — lib/ports.sh functions${NC}"
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
CURRENT_TEST="ports"

if ! command -v node >/dev/null 2>&1; then
    _skip "node not found — skipping ports tests"
else
    source "$PROJECT_ROOT/lib/devcontainer_json.sh"
    source "$PROJECT_ROOT/lib/ports.sh"

    # --- _normalize_port_spec ---
    _info "_normalize_port_spec"
    assert_equals "_normalize_port_spec bare port -> host:container" "3000:3000" \
        "$(_normalize_port_spec 3000)"
    assert_equals "_normalize_port_spec host:container preserved" "8080:80" \
        "$(_normalize_port_spec 8080:80)"
    assert_false "_normalize_port_spec rejects non-numeric" "_normalize_port_spec abc"
    assert_false "_normalize_port_spec rejects out-of-range" "_normalize_port_spec 70000"
    assert_false "_normalize_port_spec rejects zero" "_normalize_port_spec 0"

    _pjson="$(mktemp --suffix=.json)"
    _write_min_ports() {
        printf '{\n  "image": "x",\n  "runArgs": ["--env-file=${localWorkspaceFolder}/.devcontainer/.env"]\n}\n' > "$_pjson"
    }

    # --- _dc_get_published_ports / _dc_add_published_ports ---
    _info "_dc_add_published_ports / _dc_get_published_ports"
    _write_min_ports
    assert_equals "_dc_get_published_ports empty initially" "" \
        "$(_dc_get_published_ports "$_pjson")"

    _dc_add_published_ports "$_pjson" "3000:3000" "8080:80" >/dev/null
    assert_true  "_dc_has_published_port true after add (3000)" "_dc_has_published_port '$_pjson' 3000:3000"
    assert_true  "_dc_has_published_port true after add (8080)" "_dc_has_published_port '$_pjson' 8080:80"

    # Idempotent: adding the same spec must not duplicate
    _dc_add_published_ports "$_pjson" "3000:3000" >/dev/null
    _p_count="$(node -e "
        const d=JSON.parse(require('fs').readFileSync('$_pjson'));
        const n=(d.runArgs||[]).filter(a=>String(a)==='3000:3000').length;
        console.log(n);")"
    assert_equals "_dc_add_published_ports not duplicated" "1" "$_p_count"

    # env-file runArg is preserved alongside ports
    assert_true "_dc_add_published_ports preserves env-file runArg" \
        "_dc_has_env_file_run_arg '$_pjson'"

    # Host-port collision is skipped (3000 already maps to 3000)
    _dc_add_published_ports "$_pjson" "3000:9999" >/dev/null
    assert_false "_dc_add_published_ports skips host-port collision" \
        "_dc_has_published_port '$_pjson' 3000:9999"

    # -p as separate tokens is also parsed
    _info "_dc_get_published_ports parses -p token form"
    printf '{\n  "image": "x",\n  "runArgs": ["-p", "5173:5173"]\n}\n' > "$_pjson"
    assert_equals "_dc_get_published_ports reads -p token form" "5173:5173" \
        "$(_dc_get_published_ports "$_pjson")"

    rm -f "$_pjson"
fi



echo ""
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}${BOLD}  Phase 7 — dev-ai --init edge cases${NC}"
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
CURRENT_TEST="init-edge"

# Non-existent target directory
_nedir_out="$("$DEV_AI" --init /tmp/no-such-dir-xyz-abc 2>&1 || true)"
assert_contains "--init with non-existent dir shows error" "not a valid directory" "$_nedir_out"

# --init creates all template fields
_idir="$(mktemp -d)"
trap "rm -rf '$_idir'" RETURN 2>/dev/null || true
printf "1\n1\n" | "$DEV_AI" --init "$_idir" >/dev/null 2>&1 || true
_dc="$_idir/.devcontainer/devcontainer.json"
if [[ -f "$_dc" ]]; then
    _dc_content="$(cat "$_dc")"
    assert_contains "--init creates devcontainer.json with copilot mount"    ".copilot"           "$_dc_content"
    assert_contains "--init creates devcontainer.json with opencode mount"   ".config/opencode"   "$_dc_content"
    assert_contains "--init creates devcontainer.json with claude mount"     ".claude"            "$_dc_content"
    assert_contains "--init creates devcontainer.json with bob mount"        ".bob"               "$_dc_content"
    assert_contains "--init creates devcontainer.json with initializeCommand" "initialize.sh"     "$_dc_content"
    assert_contains "--init creates devcontainer.json with runArgs env-file" ".devcontainer/.env" "$_dc_content"
    assert_contains "--init creates devcontainer.json with name field"       "\"name\""           "$_dc_content"
    assert_contains "--init creates devcontainer.json with version stamp"    "// Version:"        "$_dc_content"
else
    (( TESTS_FAILED++ )) || true; (( TESTS_RUN++ )) || true
    _fail "--init did not create devcontainer.json (prerequisite failed, skipping assertions)"
fi

# --init rejects legacy .devcontainer.json
_ldir="$(mktemp -d)"
trap "rm -rf '$_ldir'" RETURN 2>/dev/null || true
echo '{"image":"foo"}' > "$_ldir/.devcontainer.json"
_legacy_out="$(echo "1" | "$DEV_AI" --init "$_ldir" 2>&1 || true)"
assert_contains "--init rejects legacy .devcontainer.json" "already exists" "$_legacy_out"
rm -rf "$_ldir" "$_idir"

# ---------------------------------------------------------------------------
# Phase 8 — lib/image.sh: pull-timestamp helpers + staleness behavior
# ---------------------------------------------------------------------------

echo ""
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}${BOLD}  Phase 8 — lib/image.sh pull-timestamp${NC}"
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
CURRENT_TEST="image-pull-timestamp"

# Use a temp dir as XDG_CACHE_HOME so tests don't pollute ~/.cache
_img_cache="$(mktemp -d)"
trap "rm -rf '$_img_cache'" EXIT
export XDG_CACHE_HOME="$_img_cache"

# containerBin must be set before sourcing image.sh; podman stub is already in PATH
containerBin="podman"
# utils.sh and devcontainer_json.sh were sourced in phases 5 and 6
source "$PROJECT_ROOT/lib/image.sh"

# --- _pull_timestamp_file ---
_info "_pull_timestamp_file"

_ts_ubuntu=$(_pull_timestamp_file "mcr.microsoft.com/devcontainers/base:ubuntu")
assert_contains "_pull_timestamp_file includes dev-ai/pull-timestamps" \
    "dev-ai/pull-timestamps" "$_ts_ubuntu"

_ts_ubuntu2=$(_pull_timestamp_file "mcr.microsoft.com/devcontainers/base:ubuntu")
assert_equals "_pull_timestamp_file is deterministic" "$_ts_ubuntu" "$_ts_ubuntu2"

_ts_alpine=$(_pull_timestamp_file "mcr.microsoft.com/devcontainers/base:alpine")
assert_true "_pull_timestamp_file differs for different images" \
    "[[ '$_ts_ubuntu' != '$_ts_alpine' ]]"

# --- _record_verified_timestamp ---
_info "_record_verified_timestamp"

_rpt_img="test.registry.io/rpt-test:v1"
_record_verified_timestamp "$_rpt_img"
_rpt_file=$(_pull_timestamp_file "$_rpt_img")
assert_true "_record_verified_timestamp creates cache file" "[[ -f '$_rpt_file' ]]"
_rpt_val=$(cat "$_rpt_file" 2>/dev/null || true)
assert_true "_record_verified_timestamp writes valid epoch" "[[ '$_rpt_val' =~ ^[0-9]+$ ]]"

_record_verified_timestamp "$_rpt_img"
_rpt_val2=$(cat "$_rpt_file" 2>/dev/null || true)
assert_true "_record_verified_timestamp is idempotent (still valid epoch)" \
    "[[ '$_rpt_val2' =~ ^[0-9]+$ ]]"

# --- check_image_staleness behavioral tests (require jq) ---
if ! command -v jq >/dev/null 2>&1; then
    _skip "jq not found — skipping check_image_staleness behavioral tests"
else
    _bws="$(mktemp -d)"
    trap "rm -rf '$_bws'" EXIT
    mkdir -p "$_bws/.devcontainer"
    printf '{"image":"test.io/stale-test:latest"}\n' \
        > "$_bws/.devcontainer/devcontainer.json"

    # Stub: reports an old Created epoch for any 'image inspect' call
    _old_epoch=$(( $(date +%s) - 30*86400 ))
    _stale_cbin="$STUB_DIR/container-stale"
    cat > "$_stale_cbin" << STUBEOF
#!/bin/bash
case "\$1 \$2" in
    "image inspect") echo $_old_epoch ;;
esac
exit 0
STUBEOF
    chmod +x "$_stale_cbin"

    _info "check_image_staleness: recent pull timestamp suppresses warning"

    _fresh_cache="$(mktemp -d)"
    trap "rm -rf '$_fresh_cache'" EXIT

    # Compute the timestamp file path using the same containerBin as the subshell
    _fresh_ts=$(XDG_CACHE_HOME="$_fresh_cache" bash -c "
        containerBin='$_stale_cbin'
        source '$PROJECT_ROOT/lib/utils.sh'
        source '$PROJECT_ROOT/lib/devcontainer_json.sh'
        source '$PROJECT_ROOT/lib/image.sh'
        _pull_timestamp_file 'test.io/stale-test:latest'")
    mkdir -p "$(dirname "$_fresh_ts")"
    date +%s > "$_fresh_ts"

    _suppress_out=$(XDG_CACHE_HOME="$_fresh_cache" WORKSPACE_PATH="$_bws" bash -c "
        containerBin='$_stale_cbin'
        source '$PROJECT_ROOT/lib/utils.sh'
        source '$PROJECT_ROOT/lib/devcontainer_json.sh'
        source '$PROJECT_ROOT/lib/image.sh'
        check_image_staleness" 2>&1 || true)
    assert_not_contains "recent pull timestamp suppresses staleness warning" \
        "Warning:" "$_suppress_out"

    _info "check_image_staleness: no pull timestamp triggers warning"

    _stale_cache="$(mktemp -d)"
    trap "rm -rf '$_stale_cache'" EXIT

    _warn_out=$(echo "n" | XDG_CACHE_HOME="$_stale_cache" WORKSPACE_PATH="$_bws" bash -c "
        containerBin='$_stale_cbin'
        source '$PROJECT_ROOT/lib/utils.sh'
        source '$PROJECT_ROOT/lib/devcontainer_json.sh'
        source '$PROJECT_ROOT/lib/image.sh'
        check_image_staleness" 2>&1 || true)
    assert_contains "no pull timestamp triggers staleness warning" \
        "Warning:" "$_warn_out"

    rm -rf "$_bws" "$_fresh_cache" "$_stale_cache"
fi

# --- _parse_image_ref: tag-resolution edge cases that drove the
#     "upstream image has changed" false-positive bug ---
_info "_parse_image_ref"

_assert_parse() {
    local desc="$1" ref="$2" want_registry="$3" want_repo="$4" want_tag="$5"
    local got registry repo tag
    got=$(_parse_image_ref "$ref")
    { IFS= read -r registry; IFS= read -r repo; IFS= read -r tag; } <<<"$got"
    assert_equals "$desc (registry)" "$want_registry" "$registry"
    assert_equals "$desc (repo)"     "$want_repo"     "$repo"
    assert_equals "$desc (tag)"      "$want_tag"      "$tag"
}

_assert_parse "MCR multi-arch ref" \
    "mcr.microsoft.com/devcontainers/base:ubuntu" \
    "mcr.microsoft.com" "devcontainers/base" "ubuntu"

_assert_parse "Docker Hub library default" \
    "ubuntu:22.04" \
    "registry-1.docker.io" "library/ubuntu" "22.04"

_assert_parse "Docker Hub bare name (default tag)" \
    "alpine" \
    "registry-1.docker.io" "library/alpine" "latest"

_assert_parse "ghcr.io owner/repo with tag" \
    "ghcr.io/owner/repo:v1" \
    "ghcr.io" "owner/repo" "v1"

_assert_parse "registry with port" \
    "localhost:5000/myimg:dev" \
    "localhost:5000" "myimg" "dev"

# Pinned digest must be stripped (we resolve the tag fresh).
_assert_parse "ref with @sha256 pin is stripped" \
    "mcr.microsoft.com/devcontainers/base:ubuntu@sha256:0000000000000000000000000000000000000000000000000000000000000000" \
    "mcr.microsoft.com" "devcontainers/base" "ubuntu"

# --- check_upstream_image_changed: regression test for the
#     manifest-list vs per-platform digest mix-up. The old code took the
#     first per-platform digest from inside the manifest list and compared
#     it to the local RepoDigest (which IS the index digest), so an
#     up-to-date image would warn on every run. The fix routes through
#     _fetch_upstream_image_digest, which we override here to return the
#     SAME digest the local image reports — the warning must NOT fire.
_info "check_upstream_image_changed: matching digest does not warn"

_cuc_ws="$(mktemp -d)"
trap "rm -rf '$_cuc_ws'" EXIT
mkdir -p "$_cuc_ws/.devcontainer"
printf '{"image":"mcr.microsoft.com/devcontainers/base:ubuntu"}\n' \
    > "$_cuc_ws/.devcontainer/devcontainer.json"

_match_digest="sha256:7ee7da33a68d997971660d91ecc8372e55a38a777c3c6bd6808daf91928052db"

# Stub container engine: reports the matching index digest as RepoDigests
# and claims the image exists locally.
_match_cbin="$STUB_DIR/container-match-digest"
cat > "$_match_cbin" << STUBEOF
#!/bin/bash
# Stub: emulates 'image inspect' for both existence checks and the two
# --format queries that lib/image.sh issues (RepoDigests and Created).
if [[ "\$1 \$2" == "image inspect" ]]; then
    args="\$*"
    if [[ "\$args" == *RepoDigests* ]]; then
        echo "mcr.microsoft.com/devcontainers/base@${_match_digest}"
    elif [[ "\$args" == *Created* ]]; then
        date +%s
    fi
    # Plain existence check (no --format) outputs nothing but exits 0.
fi
exit 0
STUBEOF
chmod +x "$_match_cbin"

_match_cache="$(mktemp -d)"
trap "rm -rf '$_match_cache'" EXIT

_match_out=$(XDG_CACHE_HOME="$_match_cache" WORKSPACE_PATH="$_cuc_ws" bash -c "
    containerBin='$_match_cbin'
    source '$PROJECT_ROOT/lib/utils.sh'
    source '$PROJECT_ROOT/lib/devcontainer_json.sh'
    source '$PROJECT_ROOT/lib/image.sh'
    # Override the upstream fetcher so the test is hermetic (no network).
    _fetch_upstream_image_digest() { echo '$_match_digest'; }
    check_upstream_image_changed" 2>&1 || true)

assert_not_contains "matching upstream digest does not warn" \
    "Security warning" "$_match_out"
assert_not_contains "matching upstream digest records no notice either" \
    "Security notice" "$_match_out"

# And the inverse: when digests truly differ, the warning MUST fire and
# the prompt MUST be answerable with 'n' to continue.
_info "check_upstream_image_changed: differing digest warns"

_diff_digest="sha256:f5a2cf592fd194be54fff4fc8e24388bd7d6b496f4653de7a4e985f41e8dc188"
_diff_out=$(echo "n" | XDG_CACHE_HOME="$_match_cache" WORKSPACE_PATH="$_cuc_ws" bash -c "
    containerBin='$_match_cbin'
    source '$PROJECT_ROOT/lib/utils.sh'
    source '$PROJECT_ROOT/lib/devcontainer_json.sh'
    source '$PROJECT_ROOT/lib/image.sh'
    _fetch_upstream_image_digest() { echo '$_diff_digest'; }
    check_upstream_image_changed" 2>&1 || true)

assert_contains "differing upstream digest emits warning" \
    "Security warning" "$_diff_out"
assert_contains "warning includes upstream digest" \
    "$_diff_digest" "$_diff_out"

rm -rf "$_cuc_ws" "$_match_cache"

# ---------------------------------------------------------------------------
# Phase 9 — _add_agent_to_install_tools unit tests
# ---------------------------------------------------------------------------

echo ""
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}${BOLD}  Phase 9 — _add_agent_to_install_tools${NC}"
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
CURRENT_TEST="_add_agent_to_install_tools"

if ! command -v jq >/dev/null 2>&1; then
    _skip "jq not found — skipping _add_agent_to_install_tools tests"
else
    # Helper: run _add_agent_to_install_tools in a subshell with a temp workspace.
    # Prints the resulting INSTALL_TOOLS value (empty string if unset).
    _run_aait() {
        local dc_json="$1" agent="$2"
        local _aait_ws
        _aait_ws="$(mktemp -d)"
        mkdir -p "$_aait_ws/.devcontainer"
        printf '%s\n' "$dc_json" > "$_aait_ws/.devcontainer/devcontainer.json"
        WORKSPACE_PATH="$_aait_ws" bash -c "
            source '$PROJECT_ROOT/lib/utils.sh'
            source '$PROJECT_ROOT/lib/agents.sh'
            source '$PROJECT_ROOT/lib/devcontainer_json.sh'
            source '$PROJECT_ROOT/lib/container.sh'
            _add_agent_to_install_tools '$agent' >/dev/null 2>&1
            jq -r '.remoteEnv.INSTALL_TOOLS // \"\"' '$_aait_ws/.devcontainer/devcontainer.json'
        "
        rm -rf "$_aait_ws"
    }

    _info "_add_agent_to_install_tools"

    _result=$(_run_aait '{"remoteEnv":{"INSTALL_TOOLS":"copilot"}}' "opencode")
    assert_contains "adds missing agent to single-item list"  "opencode" "$_result"
    assert_contains "keeps existing agent in single-item list" "copilot" "$_result"

    _result=$(_run_aait '{"remoteEnv":{"INSTALL_TOOLS":"copilot,opencode"}}' "opencode")
    _count=$(echo "$_result" | tr ',' '\n' | grep -c "^opencode$" || true)
    assert_equals "does not duplicate an already-present agent" "1" "$_count"

    _result=$(_run_aait '{"remoteEnv":{}}' "opencode")
    assert_equals "no-op when INSTALL_TOOLS is unset (default = all)" "" "$_result"

    _result=$(_run_aait '{"remoteEnv":{"INSTALL_TOOLS":"copilot opencode"}}' "claude")
    assert_contains "handles space-separated input (adds claude)" "claude" "$_result"
    assert_contains "handles space-separated input (keeps copilot)" "copilot" "$_result"

    _result=$(_run_aait '{"remoteEnv":{"INSTALL_TOOLS":"copilot,claude"}}' "opencode")
    assert_contains "adds to a two-item list" "opencode" "$_result"
    assert_contains "keeps both existing items in two-item list (copilot)" "copilot" "$_result"
    assert_contains "keeps both existing items in two-item list (claude)" "claude" "$_result"

    _result=$(_run_aait '{"remoteEnv":{"INSTALL_TOOLS":"copilot"}}' "bob")
    assert_contains "adds bob to existing list"   "bob"     "$_result"
    assert_contains "keeps existing when adding bob" "copilot" "$_result"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}All ${TESTS_PASSED}/${TESTS_RUN} assertions passed${NC}"
else
    echo -e "  ${RED}${BOLD}${TESTS_FAILED} failed, ${TESTS_PASSED} passed (${TESTS_RUN} total)${NC}"
    echo ""
    echo "  Failed:"
    for _f in "${FAILED_TESTS[@]}"; do
        echo "    - $_f"
    done
fi
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

[[ $TESTS_FAILED -eq 0 ]]
