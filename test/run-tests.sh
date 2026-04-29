#!/usr/bin/env bash
#
# Integration test runner for dev-ai.
#
# Runs a full devcontainer lifecycle for each distro:
#   1. Copies the latest postCreate.sh into the test workspace
#   2. Starts the devcontainer (devcontainer up → runs postCreateCommand)
#   3. Asserts correct state inside the container
#   4. Destroys the container
#
# Usage:
#   ./test/run-tests.sh                       # run all: ubuntu, debian, alpine
#   ./test/run-tests.sh ubuntu                # run only ubuntu
#   ./test/run-tests.sh ubuntu alpine         # run specific distros
#   CONTAINER_BIN=docker ./test/run-tests.sh  # use docker instead of podman
#   VERBOSE=1 ./test/run-tests.sh             # show full container output
#
# Requirements:
#   - podman (or docker; set CONTAINER_BIN=docker)
#   - devcontainer CLI  (npm install -g @devcontainers/cli)
#   - bash 4.3+

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONTAINER_BIN="${CONTAINER_BIN:-podman}"
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
FAILED_TESTS=()

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

_pass() { echo -e "    ${GREEN}✓${NC} $*"; }
_fail() { echo -e "    ${RED}✗${NC} $*"; }
_info() { echo -e "  ${YELLOW}→${NC} $*"; }

assert_ge() {
    local description="$1" min="$2" actual="$3"
    (( TESTS_RUN++ )) || true
    if (( actual >= min )); then
        (( TESTS_PASSED++ )) || true
        _pass "$description  (${actual} >= ${min})"
    else
        (( TESTS_FAILED++ )) || true
        _fail "$description  (expected >= ${min}, got ${actual})"
        FAILED_TESTS+=("${CURRENT_TEST}: $description")
    fi
}

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
    if echo "$haystack" | grep -qF "$needle"; then
        (( TESTS_PASSED++ )) || true
        _pass "$description"
    else
        (( TESTS_FAILED++ )) || true
        _fail "$description  (expected to contain '$needle')"
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

# ---------------------------------------------------------------------------
# init / upgrade helpers
# ---------------------------------------------------------------------------

# Image selection number for the interactive dev-ai --init menu.
_init_image_number() {
    case "$1" in
        ubuntu) echo "1" ;;
        debian) echo "2" ;;
        alpine) echo "3" ;;
        *)      echo "1" ;;
    esac
}

# Expected devcontainer image URI per distro.
_expected_image() {
    case "$1" in
        ubuntu) echo "mcr.microsoft.com/devcontainers/base:ubuntu" ;;
        debian) echo "mcr.microsoft.com/devcontainers/base:debian" ;;
        alpine) echo "mcr.microsoft.com/devcontainers/base:alpine" ;;
        *)      echo "" ;;
    esac
}

# Stamp a file with a version line on line 2 — mirrors _stamp_version in dev-ai.
_stamp_version_local() {
    local file="$1" version="$2" prefix="${3:-#}"
    local tmp
    tmp="$(mktemp)"
    { head -1 "$file"; echo "$prefix Version: $version"; tail -n +2 "$file"; } \
        > "$tmp" && mv "$tmp" "$file"
}

# Read the version stamp from a file.
_extract_version_local() {
    local file="$1"
    grep -m1 -E '^(#|//) Version:' "$file" 2>/dev/null \
        | sed -E 's/^(#|\/\/) Version:[[:space:]]*//' \
        | tr -d '[:space:]'
}

# ---------------------------------------------------------------------------
# Container helpers
# ---------------------------------------------------------------------------

_container_bin_path() { command -v "$CONTAINER_BIN"; }

# Run a command inside the test workspace's devcontainer.
_cexec() {
    local workspace="$1"
    shift
    devcontainer exec \
        --workspace-folder "$workspace" \
        --docker-path "$(_container_bin_path)" \
        "$@" 2>/dev/null
}

# Remove all containers associated with a workspace (silent).
_remove_containers() {
    local workspace="$1"
    local -a ids=()
    mapfile -t ids < <(
        "$CONTAINER_BIN" ps -a \
            --filter "label=devcontainer.local_folder=$workspace" \
            --format "{{.ID}}" 2>/dev/null || true
    )
    local id
    for id in "${ids[@]}"; do
        [[ -n "$id" ]] || continue
        "$CONTAINER_BIN" rm -f "$id" >/dev/null 2>&1 || true
    done
}

# ---------------------------------------------------------------------------
# Per-test setup / teardown
# ---------------------------------------------------------------------------

_setup() {
    local workspace="$1"
    _info "Copying postCreate.sh from templates..."
    cp "$PROJECT_ROOT/templates/postCreate.sh" "$workspace/.devcontainer/postCreate.sh"
    chmod +x "$workspace/.devcontainer/postCreate.sh"

    _info "Removing any pre-existing container..."
    _remove_containers "$workspace"
}

_teardown() {
    local workspace="$1"
    _info "Destroying container..."
    _remove_containers "$workspace"
    rm -f "$workspace/.devcontainer/postCreate.sh"
}

# ---------------------------------------------------------------------------
# --init tests
#
# Verifies that `dev-ai --init <dir>` creates the expected files and is
# idempotent (second run must fail because config already exists).
# ---------------------------------------------------------------------------

test_init_command() {
    local name="$1"
    local image_num expected_image tmpdir
    image_num="$(_init_image_number "$name")"
    expected_image="$(_expected_image "$name")"
    CURRENT_TEST="init:$name"
    tmpdir="$(mktemp -d)"
    trap "rm -rf '$tmpdir'" RETURN

    echo ""
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}${BOLD}  Test: init ($name)${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    _info "Running: dev-ai --init $tmpdir  (selecting image $image_num = $expected_image)"
    local init_output init_exit=0
    init_output="$(echo "$image_num" | "$PROJECT_ROOT/bin/dev-ai" --init "$tmpdir" 2>&1)" \
        || init_exit=$?
    if [[ "$VERBOSE" == "1" ]]; then
        echo "$init_output" | sed 's/^/    /'
    fi

    _info "Assertions..."

    # 1 – command exits successfully
    assert_equals "dev-ai --init exits 0" "0" "$init_exit"

    # 2 – devcontainer.json created
    assert_zero_exit "devcontainer.json created" \
        test -f "$tmpdir/.devcontainer/devcontainer.json"

    # 3 – correct image written into devcontainer.json
    local json_content
    json_content="$(cat "$tmpdir/.devcontainer/devcontainer.json" 2>/dev/null || echo "")"
    assert_contains "devcontainer.json uses $name image" "$expected_image" "$json_content"

    # 4 – version stamp present in devcontainer.json
    assert_contains "devcontainer.json has version stamp" "// Version:" "$json_content"

    # 4b – OpenCode mounts present in devcontainer.json
    assert_contains "devcontainer.json has OpenCode config mount" ".config/opencode" "$json_content"
    assert_contains "devcontainer.json has OpenCode data mount" ".local/share/opencode" "$json_content"

    # 5, 6 – postCreate.sh installed and executable
    assert_zero_exit "postCreate.sh installed" \
        test -f "$tmpdir/.devcontainer/postCreate.sh"
    assert_zero_exit "postCreate.sh is executable" \
        test -x "$tmpdir/.devcontainer/postCreate.sh"

    # 7, 8 – initialize.sh installed and executable
    assert_zero_exit "initialize.sh installed" \
        test -f "$tmpdir/.devcontainer/initialize.sh"
    assert_zero_exit "initialize.sh is executable" \
        test -x "$tmpdir/.devcontainer/initialize.sh"

    # 9 – .gitignore updated with .env entry
    local gitignore_content
    gitignore_content="$(cat "$tmpdir/.gitignore" 2>/dev/null || echo "")"
    assert_contains ".gitignore contains .env" ".env" "$gitignore_content"

    # 9b – .gitignore updated with .tmp entry
    assert_contains ".gitignore contains .tmp" ".tmp" "$gitignore_content"

    # 10 – re-running --init on the same dir must fail (config already exists)
    local reinit_exit=0
    echo "$image_num" \
        | "$PROJECT_ROOT/bin/dev-ai" --init "$tmpdir" >/dev/null 2>&1 \
        || reinit_exit=$?
    (( TESTS_RUN++ )) || true
    if [[ $reinit_exit -ne 0 ]]; then
        (( TESTS_PASSED++ )) || true
        _pass "re-running --init on same dir fails as expected (exit $reinit_exit)"
    else
        (( TESTS_FAILED++ )) || true
        _fail "re-running --init on same dir should fail but exited 0"
        FAILED_TESTS+=("${CURRENT_TEST}: re-running --init on same dir should fail")
    fi

    echo ""
}

# ---------------------------------------------------------------------------
# --upgrade tests
#
# Sets up a workspace with outdated scripts (v0.0.1) and a minimal
# devcontainer.json (no mounts / initializeCommand / runArgs), then runs
# `dev-ai --upgrade` and asserts all changes are applied.
# A second run verifies idempotency (no prompts, exits 0).
# ---------------------------------------------------------------------------

test_upgrade_command() {
    local name="$1"
    local expected_image tmpdir
    expected_image="$(_expected_image "$name")"
    CURRENT_TEST="upgrade:$name"
    tmpdir="$(mktemp -d)"
    trap "rm -rf '$tmpdir'" RETURN

    echo ""
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}${BOLD}  Test: upgrade ($name)${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # --- Setup: minimal devcontainer.json + scripts stamped as v0.0.1 ---
    mkdir -p "$tmpdir/.devcontainer"

    # Minimal devcontainer.json — intentionally missing mounts, initializeCommand, runArgs.
    printf '{\n  "image": "%s",\n  "remoteUser": "root"\n}\n' \
        "$expected_image" > "$tmpdir/.devcontainer/devcontainer.json"

    # Outdated postCreate.sh (v0.0.1) — upgrade should replace it.
    cp "$PROJECT_ROOT/templates/postCreate.sh" "$tmpdir/.devcontainer/postCreate.sh"
    chmod +x "$tmpdir/.devcontainer/postCreate.sh"
    _stamp_version_local "$tmpdir/.devcontainer/postCreate.sh" "0.0.1"

    # Outdated initialize.sh (v0.0.1) — upgrade should replace it.
    cp "$PROJECT_ROOT/templates/initialize.sh" "$tmpdir/.devcontainer/initialize.sh"
    chmod +x "$tmpdir/.devcontainer/initialize.sh"
    _stamp_version_local "$tmpdir/.devcontainer/initialize.sh" "0.0.1"

    # --- Run upgrade (6 interactive prompts, answer y to each) ---
    # Prompts in order: update postCreate.sh, update initialize.sh,
    #   add ~/.copilot mount, set initializeCommand, add --env-file runArg,
    #   add OpenCode bind mounts.
    _info "Running: dev-ai --upgrade $tmpdir  (answering y to all prompts)"
    local upgrade_output upgrade_exit=0
    upgrade_output="$(printf "y\ny\ny\ny\ny\ny\n" \
        | "$PROJECT_ROOT/bin/dev-ai" --upgrade "$tmpdir" 2>&1)" \
        || upgrade_exit=$?
    if [[ "$VERBOSE" == "1" ]]; then
        echo "$upgrade_output" | sed 's/^/    /'
    fi

    local current_version
    current_version="$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION")"

    _info "Assertions..."

    # 1 – command exits successfully
    assert_equals "dev-ai --upgrade exits 0" "0" "$upgrade_exit"

    # 2, 3 – postCreate.sh updated to current version and executable
    local pc_version
    pc_version="$(_extract_version_local "$tmpdir/.devcontainer/postCreate.sh")"
    assert_equals "postCreate.sh updated to v$current_version" "$current_version" "$pc_version"
    assert_zero_exit "postCreate.sh is executable after upgrade" \
        test -x "$tmpdir/.devcontainer/postCreate.sh"

    # 4, 5 – initialize.sh updated to current version and executable
    local init_version
    init_version="$(_extract_version_local "$tmpdir/.devcontainer/initialize.sh")"
    assert_equals "initialize.sh updated to v$current_version" "$current_version" "$init_version"
    assert_zero_exit "initialize.sh is executable after upgrade" \
        test -x "$tmpdir/.devcontainer/initialize.sh"

    # 6, 7, 8, 9 – devcontainer.json fields added
    local dc_content
    dc_content="$(cat "$tmpdir/.devcontainer/devcontainer.json")"
    assert_contains "devcontainer.json has ~/.copilot mount"     ".copilot"           "$dc_content"
    assert_contains "devcontainer.json has initializeCommand"    "initialize.sh"      "$dc_content"
    assert_contains "devcontainer.json has --env-file runArg"    ".devcontainer/.env" "$dc_content"
    assert_contains "devcontainer.json has version stamp"        "// Version:"        "$dc_content"
    assert_contains "devcontainer.json has OpenCode config mount" ".config/opencode"  "$dc_content"
    assert_contains "devcontainer.json has OpenCode data mount"   ".local/share/opencode" "$dc_content"

    # 10 – idempotent: second run needs no prompts and exits 0
    _info "Verifying --upgrade is idempotent..."
    local idempotent_exit=0
    "$PROJECT_ROOT/bin/dev-ai" --upgrade "$tmpdir" \
        </dev/null >/dev/null 2>&1 \
        || idempotent_exit=$?
    assert_equals "re-running --upgrade is idempotent (exits 0)" "0" "$idempotent_exit"

    echo ""
}

# ---------------------------------------------------------------------------
# Core test
# ---------------------------------------------------------------------------

run_test() {
    local name="$1"
    local workspace
    workspace="$(realpath "$SCRIPT_DIR/$name")"

    CURRENT_TEST="$name"

    echo ""
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}${BOLD}  Test: $name${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if [[ ! -d "$workspace/.devcontainer" ]]; then
        echo -e "  ${RED}ERROR${NC}: $workspace/.devcontainer not found" >&2
        FAILED_TESTS+=("$name: workspace missing")
        (( TESTS_FAILED++ )) || true
        (( TESTS_RUN++ )) || true
        return 0
    fi

    # Always teardown when this function returns (pass or fail).
    trap "_teardown '$workspace'" RETURN

    _setup "$workspace"

    # --- Start container ---
    _info "Running devcontainer up (this may take several minutes on first run)..."
    local up_log
    up_log="$(mktemp /tmp/devcontainer-up-${name}-XXXXXX.log)"
    local up_exit=0

    if [[ "$VERBOSE" == "1" ]]; then
        devcontainer up \
            --workspace-folder "$workspace" \
            --docker-path "$(_container_bin_path)" \
            2>&1 | tee "$up_log" || up_exit=$?
    else
        devcontainer up \
            --workspace-folder "$workspace" \
            --docker-path "$(_container_bin_path)" \
            >"$up_log" 2>&1 || up_exit=$?
    fi

    if [[ $up_exit -ne 0 ]]; then
        (( TESTS_FAILED++ )) || true
        (( TESTS_RUN++ )) || true
        _fail "devcontainer up failed (exit $up_exit) — log: $up_log"
        echo "--- begin log ---"
        tail -40 "$up_log"
        echo "--- end log ---"
        FAILED_TESTS+=("$name: devcontainer up failed")
        return 0
    fi
    _pass "devcontainer up succeeded"
    (( TESTS_PASSED++ )) || true
    (( TESTS_RUN++ )) || true

    echo ""
    _info "Running assertions..."

    # 1. Correct distro detected
    local detected_distro
    detected_distro=$(_cexec "$workspace" sh -c '. /etc/os-release 2>/dev/null && echo "${ID:-unknown}"' || echo "unknown")
    assert_equals "Container distro is $name" "$name" "$detected_distro"

    # 2. Node.js version >= 24
    local node_ver node_major
    node_ver=$(_cexec "$workspace" node --version 2>/dev/null || echo "v0")
    node_major=$(echo "$node_ver" | sed 's/^v//' | cut -d. -f1)
    assert_ge "Node.js >= v24" 24 "${node_major:-0}"

    # 3. npm is available
    assert_zero_exit "npm available" _cexec "$workspace" npm --version

    # 4. @github/copilot CLI installed
    local copilot_list
    copilot_list=$(_cexec "$workspace" npm -g list @github/copilot --depth=0 2>/dev/null || echo "")
    assert_contains "@github/copilot installed" "@github/copilot" "$copilot_list"

    # 4b. opencode-ai installed
    local opencode_list
    opencode_list=$(_cexec "$workspace" npm -g list opencode-ai --depth=0 2>/dev/null || echo "")
    assert_contains "opencode-ai installed" "opencode-ai" "$opencode_list"

    # 5. /workspace trusted in Copilot config
    local config_content
    config_content=$(_cexec "$workspace" cat /tmp/test-copilot/config.json 2>/dev/null || echo "")
    assert_contains "/workspace in trusted_folders" "/workspace" "$config_content"

    # 6. Pre-hook ran
    local pre_hook_check
    pre_hook_check=$(_cexec "$workspace" sh -c 'test -f /tmp/pre_hook_ran && echo yes || echo no')
    assert_equals "postCreate_pre_hook.sh ran" "yes" "$pre_hook_check"

    # 7. Post-hook ran
    local post_hook_check
    post_hook_check=$(_cexec "$workspace" sh -c 'test -f /tmp/post_hook_ran && echo yes || echo no')
    assert_equals "postCreate_post_hook.sh ran" "yes" "$post_hook_check"

    # 8. Post-hook received exit code 0
    local post_hook_exit
    post_hook_exit=$(_cexec "$workspace" cat /tmp/post_hook_exit_code 2>/dev/null || echo "missing")
    assert_equals "post_hook received POST_CREATE_EXIT_CODE=0" "0" "$post_hook_exit"

    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Prerequisite checks
for _bin in "$CONTAINER_BIN" devcontainer; do
    if ! command -v "$_bin" >/dev/null 2>&1; then
        echo -e "${RED}Error${NC}: '$_bin' not found. Cannot run tests." >&2
        echo "  Install devcontainer CLI: npm install -g @devcontainers/cli" >&2
        exit 1
    fi
done

ALL_TESTS=("ubuntu" "debian" "alpine")
TESTS_TO_RUN=()

if [[ $# -gt 0 ]]; then
    for _arg in "$@"; do
        # Validate
        local_valid=false
        for _t in "${ALL_TESTS[@]}"; do
            [[ "$_arg" == "$_t" ]] && local_valid=true && break
        done
        if ! $local_valid; then
            echo "Error: unknown test '$_arg'. Valid: ${ALL_TESTS[*]}" >&2
            exit 1
        fi
        TESTS_TO_RUN+=("$_arg")
    done
else
    TESTS_TO_RUN=("${ALL_TESTS[@]}")
fi

echo -e "${BOLD}dev-ai integration tests${NC}"
echo "  Container runtime : $CONTAINER_BIN"
echo "  Tests to run      : ${TESTS_TO_RUN[*]}"
echo "  Verbose           : $VERBOSE"
echo ""

echo -e "${BOLD}Phase 1 — devcontainer lifecycle (up / exec / down)${NC}"
for _test in "${TESTS_TO_RUN[@]}"; do
    run_test "$_test"
done

echo ""
echo -e "${BOLD}Phase 2 — dev-ai --init${NC}"
for _test in "${TESTS_TO_RUN[@]}"; do
    test_init_command "$_test"
done

echo ""
echo -e "${BOLD}Phase 3 — dev-ai --upgrade${NC}"
for _test in "${TESTS_TO_RUN[@]}"; do
    test_upgrade_command "$_test"
done

# Summary
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

[[ $TESTS_FAILED -eq 0 ]]
