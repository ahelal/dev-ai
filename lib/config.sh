# Config management: load and query ~/.dev-ai/config.json using jq.
#
# Config file location: ~/.dev-ai/config.json
# Supported keys:
#   default_agent      – copilot | opencode | claude   (default: copilot)
#   container_engine   – podman  | docker              (default: podman)
#
# Precedence: CLI flag > environment variable > config file > built-in default.

DEV_AI_CONFIG_DIR="${HOME}/.dev-ai"
DEV_AI_CONFIG_FILE="${DEV_AI_CONFIG_DIR}/config.json"

# ---------------------------------------------------------------------------
# _require_jq: verify that jq is installed; abort with a helpful message if not.
# ---------------------------------------------------------------------------
_require_jq() {
    if ! command -v jq &>/dev/null; then
        echo "Error: 'jq' is not installed." >&2
        echo "  Install it with:  apt-get install jq  /  brew install jq  /  apk add jq" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# get_config_value: read a single key from the config file.
# Usage: get_config_value <key> [default]
# Returns the value for <key>, or <default> if missing/unreadable.
# ---------------------------------------------------------------------------
get_config_value() {
    local key="$1" default="${2:-}"
    if [[ ! -f "$DEV_AI_CONFIG_FILE" ]]; then
        echo "$default"
        return 0
    fi
    local val
    val=$(jq -r --arg k "$key" '.[$k] // empty' "$DEV_AI_CONFIG_FILE" 2>/dev/null) || val=""
    if [[ -z "$val" ]]; then
        echo "$default"
    else
        echo "$val"
    fi
}

# ---------------------------------------------------------------------------
# _init_default_config: create ~/.dev-ai/config.json with sensible defaults
# if it does not already exist. Prints a notice on first creation.
# ---------------------------------------------------------------------------
_init_default_config() {
    [[ -f "$DEV_AI_CONFIG_FILE" ]] && return 0
    mkdir -p "$DEV_AI_CONFIG_DIR"
    cat >"$DEV_AI_CONFIG_FILE" <<'JSON'
{
  "default_agent": "copilot",
  "container_engine": "podman"
}
JSON
    echo "Created default config: $DEV_AI_CONFIG_FILE"
}

# ---------------------------------------------------------------------------
# load_config: read config file and set global defaults for AGENT and
# containerBin.  CLI flags applied later will override these values.
# ---------------------------------------------------------------------------

# Default socket path for Apple's Containerization framework.
APPLE_CONTAINER_SOCK="${HOME}/.socktainer/container.sock"

load_config() {
    _require_jq
    _init_default_config

    # Container engine: env > config > default
    if [[ -n "${DEV_AI_ENGINE:-}" ]]; then
        containerEngine="$DEV_AI_ENGINE"
    else
        containerEngine="$(get_config_value container_engine podman)"
    fi

    # Default agent: env > config > default
    if [[ -n "${DEV_AI_AGENT:-}" ]]; then
        AGENT="$DEV_AI_AGENT"
    else
        AGENT="$(get_config_value default_agent copilot)"
    fi

    # Validate container engine and resolve the actual binary
    case "$containerEngine" in
    podman)
        containerBin="podman"
        ;;
    docker)
        containerBin="docker"
        ;;
    apple-container)
        # Apple Containerization framework — uses Docker CLI over a local socket.
        containerBin="docker"
        ;;
    *)
        echo "Warning: unknown container_engine '$containerEngine' in config; falling back to podman." >&2
        containerEngine="podman"
        containerBin="podman"
        ;;
    esac

    # docker_host config: set DOCKER_HOST from config when not already in env.
    # Applies to both 'docker' and 'apple-container' engines.
    # For apple-container, defaults to the well-known socket path.
    if [[ "$containerBin" == "docker" && -z "${DOCKER_HOST:-}" ]]; then
        local configured_host
        if [[ "$containerEngine" == "apple-container" ]]; then
            configured_host="$(get_config_value docker_host "unix://${APPLE_CONTAINER_SOCK}")"
        else
            configured_host="$(get_config_value docker_host "")"
        fi
        if [[ -n "$configured_host" ]]; then
            export DOCKER_HOST="$configured_host"
        fi
    fi

    # Validate agent
    local valid=false
    local a
    for a in "${KNOWN_AGENTS[@]}"; do
        [[ "$a" == "$AGENT" ]] && {
            valid=true
            break
        }
    done
    if ! $valid; then
        echo "Warning: unknown default_agent '$AGENT' in config; falling back to copilot." >&2
        AGENT="copilot"
    fi
}
