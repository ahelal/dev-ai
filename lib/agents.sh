# Agent registry: centralised metadata for all supported AI coding tools.
#
# Each agent is defined by its ID (copilot, opencode, claude) and described
# by a set of associative arrays keyed on that ID.  Functions below provide
# convenient lookup helpers so callers never hard-code agent details.

# Ordered list of every supported agent ID.
KNOWN_AGENTS=(copilot opencode claude bob)

# Human-readable display name.
declare -A AGENT_DISPLAY=(
    [copilot]="GitHub Copilot CLI"
    [opencode]="OpenCode"
    [claude]="Claude Code"
    [bob]="Bob Shell"
)

# Binary name used to launch the agent inside the container.
declare -A AGENT_BIN=(
    [copilot]="copilot"
    [opencode]="opencode"
    [claude]="claude"
    [bob]="bob"
)

# Registry package name for install/upgrade via pnpm.  Empty means the agent
# is not distributed as a package; see AGENT_INSTALL_CMD for the install method.
declare -A AGENT_PKG=(
    [copilot]="@github/copilot"
    [opencode]="opencode-ai"
    [claude]="@anthropic-ai/claude-code"
    [bob]=""
)

# Install command for agents not distributed as a registry package.
# Used by ensure_agent_installed and postCreate.sh when AGENT_PKG is empty.
declare -A AGENT_INSTALL_CMD=(
    [copilot]=""
    [opencode]=""
    [claude]=""
    [bob]="curl -fsSL https://bob.ibm.com/download/bobshell.sh | bash"
)

# Directories relative to $HOME that the agent needs (colon-separated).
# These are created on the host and bind-mounted into the container.
declare -A AGENT_DIRS=(
    [copilot]=".copilot"
    [opencode]=".config/opencode:.local/share/opencode"
    [claude]=".claude"
    [bob]=".bob"
)

# Optional command prefix placed before the agent binary at launch time.
declare -A AGENT_LAUNCH_PREFIX=(
    [copilot]="env COPILOT_ALLOW_ALL=true"
    [opencode]=""
    [claude]=""
    [bob]=""
)

# Extra CLI flags appended after the agent binary (before --model).
declare -A AGENT_LAUNCH_ARGS=(
    [copilot]="--allow-all --allow-all-tools --allow-all-paths --allow-all-urls"
    [opencode]=""
    [claude]=""
    [bob]=""
)

# ---------------------------------------------------------------------------
# get_agent_dirs: print the list of home-relative directories for an agent,
#   one per line.  Usage:  get_agent_dirs copilot
# ---------------------------------------------------------------------------
get_agent_dirs() {
    local agent="$1"
    local dirs="${AGENT_DIRS[$agent]:-}"
    [[ -z "$dirs" ]] && return 0
    IFS=: read -ra _parts <<< "$dirs"
    printf '%s\n' "${_parts[@]}"
}

# ---------------------------------------------------------------------------
# ensure_agent_dirs: create the home-relative directories for the given
#   agent(s).  With no arguments, creates dirs for ALL known agents.
#   Usage:  ensure_agent_dirs              # all agents
#           ensure_agent_dirs copilot      # just copilot
# ---------------------------------------------------------------------------
ensure_agent_dirs() {
    local agents=("$@")
    if (( ${#agents[@]} == 0 )); then
        agents=("${KNOWN_AGENTS[@]}")
    fi
    local agent dir
    for agent in "${agents[@]}"; do
        while IFS= read -r dir; do
            [[ -n "$dir" ]] && mkdir -p "${HOME}/$dir"
        done < <(get_agent_dirs "$agent")
    done
}

# ---------------------------------------------------------------------------
# prompt_tool_selection: interactive menu to select which AI tools to install.
# Writes a comma-separated list of agent IDs to the nameref variable $1.
# Optional $2: default agent ID (used to pre-select a number; falls back to
#   the global AGENT variable, then "copilot").
# Usage:
#   local selected=""
#   prompt_tool_selection selected "copilot"
# ---------------------------------------------------------------------------
prompt_tool_selection() {
    local -n _pts_result="$1"
    local _pts_default_agent="${2:-${AGENT:-copilot}}"

    echo ""
    echo "Select AI tools to install (space-separated numbers, or 'a' for all):"
    local _pts_ti _pts_default_num=1
    for _pts_ti in "${!KNOWN_AGENTS[@]}"; do
        printf "  %2d) %s\n" "$((_pts_ti + 1))" "${AGENT_DISPLAY[${KNOWN_AGENTS[$_pts_ti]}]}"
        if [[ "${KNOWN_AGENTS[$_pts_ti]}" == "$_pts_default_agent" ]]; then
            _pts_default_num=$((_pts_ti + 1))
        fi
    done
    echo ""

    while true; do
        read -r -p "Enter numbers [default: $_pts_default_num] or 'a' for all: " _pts_input
        _pts_input="${_pts_input:-$_pts_default_num}"

        if [[ "${_pts_input,,}" == "a" || "${_pts_input,,}" == "all" ]]; then
            _pts_result=$(printf '%s,' "${KNOWN_AGENTS[@]}")
            _pts_result="${_pts_result%,}"
            return 0
        fi

        local -a _pts_chosen=()
        local _pts_valid=true
        local _pts_n
        for _pts_n in $_pts_input; do
            if [[ "$_pts_n" =~ ^[0-9]+$ ]] && (( _pts_n >= 1 && _pts_n <= ${#KNOWN_AGENTS[@]} )); then
                _pts_chosen+=("${KNOWN_AGENTS[$((_pts_n - 1))]}")
            else
                echo "Invalid: '$_pts_n'. Enter numbers 1-${#KNOWN_AGENTS[@]}, or 'a' for all."
                _pts_valid=false
                break
            fi
        done
        if ! $_pts_valid; then continue; fi
        if (( ${#_pts_chosen[@]} == 0 )); then
            echo "Please select at least one tool."
            continue
        fi

        # Deduplicate while preserving order
        local -A _pts_seen=()
        local -a _pts_dedup=()
        local _pts_c
        for _pts_c in "${_pts_chosen[@]}"; do
            if [[ -z "${_pts_seen[$_pts_c]+x}" ]]; then
                _pts_seen["$_pts_c"]=1
                _pts_dedup+=("$_pts_c")
            fi
        done
        _pts_result=$(printf '%s,' "${_pts_dedup[@]}")
        _pts_result="${_pts_result%,}"
        return 0
    done
}

#   Writes the command words to the nameref array passed as $1.
#   Usage:
#     local -a cmd=()
#     build_agent_cmd cmd copilot "claude-sonnet-4.5"
#     devcontainer exec ... "${cmd[@]}"
# ---------------------------------------------------------------------------
build_agent_cmd() {
    local -n _cmd_ref="$1"
    local agent="$2"
    local model="${3:-}"

    _cmd_ref=()

    # Optional prefix (e.g. env COPILOT_ALLOW_ALL=true)
    local prefix="${AGENT_LAUNCH_PREFIX[$agent]:-}"
    if [[ -n "$prefix" ]]; then
        read -ra _prefix_parts <<< "$prefix"
        _cmd_ref+=("${_prefix_parts[@]}")
    fi

    # Agent binary
    _cmd_ref+=("${AGENT_BIN[$agent]}")

    # Extra agent-specific flags
    local extra="${AGENT_LAUNCH_ARGS[$agent]:-}"
    if [[ -n "$extra" ]]; then
        read -ra _extra_parts <<< "$extra"
        _cmd_ref+=("${_extra_parts[@]}")
    fi

    # Model flag (common across all agents)
    if [[ -n "$model" ]]; then
        _cmd_ref+=("--model" "$model")
    fi
}
