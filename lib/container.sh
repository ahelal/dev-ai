# Container lifecycle: start, stop, rename, mounts, rebuild, remount.
#
# Depends on: agents.sh (KNOWN_AGENTS, AGENT_DIRS, get_agent_dirs),
#             devcontainer_json.sh (_dc_has_mount, _dc_get_name),
#             utils.sh (resolve_dc_file).

# ---------------------------------------------------------------------------
# ensure_engine_running: verify the container engine is reachable before any
# command substitution touches it.  Under `set -euo pipefail` a failing
# `podman ps` inside $(...) aborts the whole script silently with exit 125
# (e.g. when the podman machine VM is not started).  Fail loudly instead.
# ---------------------------------------------------------------------------
ensure_engine_running() {
    local err info_fmt

    # Podman and Docker expose different info template structures.
    case "${containerEngine:-$containerBin}" in
    podman) info_fmt='{{.Host.Arch}}' ;;
    *) info_fmt='{{.Architecture}}' ;;
    esac

    if err=$("$containerBin" info --format "$info_fmt" 2>&1); then
        return 0
    fi

    echo "Error: cannot connect to container engine '$containerBin'." >&2
    echo "  $err" >&2
    case "${containerEngine:-$containerBin}" in
    podman)
        echo "" >&2
        echo "  The podman machine is likely not running. Try:" >&2
        echo "    podman machine start" >&2
        echo "  If that fails, recreate it:" >&2
        echo "    podman machine rm -f && podman machine init && podman machine start" >&2
        ;;
    apple-container)
        echo "" >&2
        echo "  Apple Container does not appear to be running." >&2
        echo "  DOCKER_HOST is: ${DOCKER_HOST:-<unset>}" >&2
        echo "  Ensure the container runtime is started and the socket exists." >&2
        ;;
    docker)
        echo "" >&2
        echo "  The Docker daemon is not reachable." >&2
        echo "  Ensure Docker is running or DOCKER_HOST is set correctly." >&2
        ;;
    esac
    exit 1
}

# ---------------------------------------------------------------------------
# get_container_id: print the ID of the running devcontainer for WORKSPACE_PATH.
# devcontainer labels each container with devcontainer.local_folder=<path>.
# ---------------------------------------------------------------------------
get_container_id() {
    "$containerBin" ps \
        --filter "label=devcontainer.local_folder=$WORKSPACE_PATH" \
        --format "{{.ID}}" 2>/dev/null |
        head -1
}

# ---------------------------------------------------------------------------
# stop_container: stop the running devcontainer for WORKSPACE_PATH.
# ---------------------------------------------------------------------------
stop_container() {
    local container_id
    container_id=$(get_container_id)
    if [[ -n "$container_id" ]]; then
        echo "Stopping devcontainer (ID: $container_id)..."
        "$containerBin" stop "$container_id"
        echo "Container stopped."
    else
        echo "No running container found to stop."
    fi
}

# ---------------------------------------------------------------------------
# rename_container_to_dc_name: rename the running container to match the
# "name" field in devcontainer.json for a friendly `docker/podman ps` output.
# ---------------------------------------------------------------------------
rename_container_to_dc_name() {
    local container_id
    container_id=$(get_container_id)
    [[ -n "$container_id" ]] || return 0

    local dc_file
    dc_file=$(resolve_dc_file) || return 0

    local dc_name
    dc_name=$(_dc_get_name "$dc_file") || return 0
    [[ -n "$dc_name" ]] || return 0

    # Sanitize: container names must match [a-zA-Z0-9][a-zA-Z0-9_.-]
    local safe_name
    safe_name=$(printf '%s' "$dc_name" | tr -cs 'a-zA-Z0-9_.-' '-' | sed 's/^-//')
    [[ -n "$safe_name" ]] || return 0

    local current_name
    current_name=$("$containerBin" inspect --format '{{.Name}}' "$container_id" 2>/dev/null || true)
    current_name="${current_name#/}"
    [[ "$current_name" == "$safe_name" ]] && return 0

    # Remove any existing container with the target name (stale/stopped)
    if "$containerBin" inspect "$safe_name" >/dev/null 2>&1; then
        "$containerBin" rm -f "$safe_name" >/dev/null 2>&1 || true
    fi

    if "$containerBin" rename "$container_id" "$safe_name" 2>/dev/null; then
        echo "  Container named: $safe_name"
    fi
}

# ---------------------------------------------------------------------------
# collect_agent_mounts: build the full list of --mount args for all agents.
# Adds bind mounts for each agent's home directories when devcontainer.json
# does not already declare them.  Also adds symlink-target mounts for
# all agent directories (e.g. ~/.copilot, ~/.claude, ~/.config/opencode, etc.).
# Writes results into the nameref array passed as $1.
# NOTE: call ensure_agent_dirs before devcontainer up, not here.
# ---------------------------------------------------------------------------
collect_agent_mounts() {
    local -n _mounts_ref="$1"

    local dc_file
    dc_file=$(resolve_dc_file) || dc_file=""

    local agent dir src tgt
    for agent in "${KNOWN_AGENTS[@]}"; do
        while IFS= read -r dir; do
            [[ -n "$dir" ]] || continue
            src="${HOME}/$dir"
            tgt="/root/$dir"
            if [[ -z "$dc_file" ]] || ! _dc_has_mount "$dc_file" "$dir"; then
                [[ -d "$src" ]] &&
                    _mounts_ref+=("--mount" "type=bind,source=${src},target=${tgt}")
            fi
        done < <(get_agent_dirs "$agent")
    done

    # Also mount symlink targets inside all agent directories
    local -A seen=()
    local link target mount_src agent_dir_abs

    for agent in "${KNOWN_AGENTS[@]}"; do
        while IFS= read -r dir; do
            [[ -n "$dir" ]] || continue
            agent_dir_abs="${HOME}/$dir"
            [[ -d "$agent_dir_abs" ]] || continue

            while IFS= read -r -d '' link; do
                target=$(readlink -f "$link" 2>/dev/null) || continue
                [[ -e "$target" ]] || continue

                if [[ -d "$target" ]]; then
                    mount_src="$target"
                else
                    mount_src="$(dirname "$target")"
                fi

                # Skip if target is already inside the agent dir itself
                [[ "$mount_src" == "$agent_dir_abs" || "$mount_src" == "$agent_dir_abs/"* ]] && continue
                [[ -n "${seen[$mount_src]+x}" ]] && continue
                seen["$mount_src"]=1

                _mounts_ref+=("--mount" "type=bind,source=${mount_src},target=${mount_src}")
            done < <(find "$agent_dir_abs" -maxdepth 3 -type l -print0 2>/dev/null)
        done < <(get_agent_dirs "$agent")
    done

    # Mount symlink targets inside the workspace (limit to 5 to avoid bloat)
    local max_workspace_symlinks=5
    local ws_count=0
    if [[ -n "${WORKSPACE_PATH:-}" && -d "$WORKSPACE_PATH" ]]; then
        while IFS= read -r -d '' link; do
            ((ws_count >= max_workspace_symlinks)) && break
            target=$(readlink -f "$link" 2>/dev/null) || continue
            [[ -e "$target" ]] || continue

            if [[ -d "$target" ]]; then
                mount_src="$target"
            else
                mount_src="$(dirname "$target")"
            fi

            # Skip if target is already inside the workspace
            [[ "$mount_src" == "$WORKSPACE_PATH" || "$mount_src" == "$WORKSPACE_PATH/"* ]] && continue
            [[ -n "${seen[$mount_src]+x}" ]] && continue
            seen["$mount_src"]=1

            _mounts_ref+=("--mount" "type=bind,source=${mount_src},target=${mount_src}")
            ws_count=$((ws_count + 1))
        done < <(find "$WORKSPACE_PATH" -maxdepth 3 -type l -print0 2>/dev/null)

        if ((ws_count > 0)); then
            echo "  Mounting $ws_count workspace symlink target(s)"
        fi
    fi
}

# ---------------------------------------------------------------------------
# check_and_warn_missing_mounts: inspect a running container and warn if
# expected agent mounts are absent.  Offers to remount or rebuild.
# ---------------------------------------------------------------------------
check_and_warn_missing_mounts() {
    local container_id="$1"
    local -n _extra_ref="$2"

    # Collect actual mount sources from the running container
    local -a actual_sources=()
    mapfile -t actual_sources < <(
        "$containerBin" inspect \
            --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' \
            "$container_id" 2>/dev/null | grep -v '^$' || true
    )

    local -A actual_set=()
    local src
    for src in "${actual_sources[@]}"; do
        [[ -n "$src" ]] && actual_set["$src"]=1
    done

    # Build expected sources from agent registry
    local -a expected_sources=()
    local agent dir
    for agent in "${KNOWN_AGENTS[@]}"; do
        while IFS= read -r dir; do
            [[ -n "$dir" ]] || continue
            [[ -d "${HOME}/$dir" ]] && expected_sources+=("${HOME}/$dir")
        done < <(get_agent_dirs "$agent")
    done

    # Also check symlink-target mounts
    local i source
    for ((i = 1; i < ${#_extra_ref[@]}; i += 2)); do
        source=$(echo "${_extra_ref[$i]}" | sed 's/.*source=\([^,]*\).*/\1/')
        expected_sources+=("$source")
    done

    local -a missing=()
    for source in "${expected_sources[@]}"; do
        [[ -n "${actual_set[$source]+x}" ]] || missing+=("$source")
    done

    [[ ${#missing[@]} -eq 0 ]] && return 0

    echo ""
    echo "Warning: running container (ID: $container_id) is missing mount(s):"
    for src in "${missing[@]}"; do
        echo "  - $src"
    done
    echo ""
    echo "Mounts cannot be added to a running container."
    echo "  1) Continue without these mounts"
    echo "  2) Remount: stop and restart with correct mounts (fast, skips postCreate)  [recommended]"
    echo "  3) Rebuild: full stop/rebuild (slow, runs postCreate)"

    local choice
    while true; do
        read -r -p "Choose [1/2/3] (default: 2): " choice
        choice="${choice:-2}"
        case "$choice" in
        1)
            echo "Continuing without mounts."
            return 0
            ;;
        2)
            remount_devcontainer
            return 0
            ;;
        3)
            rebuild_devcontainer
            return 0
            ;;
        *) echo "Please enter 1, 2, or 3." ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# remove_workspace_containers: remove all containers (running or stopped)
# associated with WORKSPACE_PATH.
# ---------------------------------------------------------------------------
remove_workspace_containers() {
    local -a container_ids=()
    mapfile -t container_ids < <(
        "$containerBin" ps -a \
            --filter "label=devcontainer.local_folder=$WORKSPACE_PATH" \
            --format "{{.ID}}" 2>/dev/null || true
    )

    if ((${#container_ids[@]} > 0)); then
        echo "Removing existing devcontainer(s) for: $WORKSPACE_PATH"
        local _id
        for _id in "${container_ids[@]}"; do
            [[ -n "$_id" ]] || continue
            echo "  Removing container: $_id"
            "$containerBin" rm -f "$_id" >/dev/null 2>&1 || true
        done
    else
        echo "No existing devcontainer found to remove for: $WORKSPACE_PATH"
    fi
}

# ---------------------------------------------------------------------------
# _start_devcontainer: shared logic for starting a devcontainer with mounts.
# Usage: _start_devcontainer [--skip-post-create]
# ---------------------------------------------------------------------------
_start_devcontainer() {
    local skip_post_create=false
    [[ "${1:-}" == "--skip-post-create" ]] && skip_post_create=true

    local -a extra_mounts=()
    collect_agent_mounts extra_mounts
    if ((${#extra_mounts[@]} > 0)); then
        echo "  Mounting agent config dirs: $((${#extra_mounts[@]} / 2)) path(s)"
    fi
    ensure_agent_dirs

    local -a up_args=(
        --workspace-folder "$WORKSPACE_PATH"
        --docker-path "$CONTAINER_BIN_PATH"
    )
    $skip_post_create && up_args+=(--skip-post-create)
    up_args+=("${extra_mounts[@]+"${extra_mounts[@]}"}")

    devcontainer up "${up_args[@]}"
    rename_container_to_dc_name
}

# ---------------------------------------------------------------------------
# rebuild_devcontainer: remove and recreate the devcontainer from scratch.
# ---------------------------------------------------------------------------
rebuild_devcontainer() {
    remove_workspace_containers
    echo "Rebuilding devcontainer for: $WORKSPACE_PATH"
    _start_devcontainer
}

# ---------------------------------------------------------------------------
# remount_devcontainer: remove and restart with correct mounts, skipping
# postCreate for speed.
# ---------------------------------------------------------------------------
remount_devcontainer() {
    remove_workspace_containers
    echo "Remounting devcontainer for: $WORKSPACE_PATH (skipping postCreate)..."
    _start_devcontainer --skip-post-create
}

# ---------------------------------------------------------------------------
# _add_agent_to_install_tools: add an agent ID to INSTALL_TOOLS in
# devcontainer.json so future rebuilds include it.
# No-op when INSTALL_TOOLS is unset (defaults to all tools already) or
# when the agent is already listed.
# Usage: _add_agent_to_install_tools <agent_id>
# ---------------------------------------------------------------------------
_add_agent_to_install_tools() {
    local agent="$1"
    local dc_file
    dc_file=$(resolve_dc_file "$WORKSPACE_PATH") 2>/dev/null || return 0
    [[ -f "$dc_file" ]] || return 0

    local current_tools
    current_tools=$(_strip_jsonc "$dc_file" | jq -r '.remoteEnv.INSTALL_TOOLS // ""' 2>/dev/null || true)
    # If INSTALL_TOOLS is unset the default already includes all tools; nothing to change.
    [[ -n "$current_tools" ]] || return 0

    # Normalize: replace commas with spaces (consistent with postCreate.sh), then split
    local normalized="${current_tools//,/ }"
    local -a current_arr=()
    read -ra current_arr <<<"$normalized"

    local found=false t
    for t in "${current_arr[@]}"; do
        [[ "$t" == "$agent" ]] && found=true && break
    done
    $found && return 0

    current_arr+=("$agent")
    local new_tools
    new_tools=$(printf '%s,' "${current_arr[@]}")
    new_tools="${new_tools%,}"

    _dc_modify "$dc_file" --arg tools "$new_tools" \
        '.remoteEnv = ((.remoteEnv // {}) + {INSTALL_TOOLS: $tools})'
    echo "Updated INSTALL_TOOLS in devcontainer.json: ${new_tools}"
}

# ---------------------------------------------------------------------------
# ensure_agent_installed: check if an agent binary exists in the running
# container. If missing and on an interactive terminal, prompt the user to
# install it via pnpm. On install, also persists the change to INSTALL_TOOLS
# in devcontainer.json so future rebuilds include it.
# Usage: ensure_agent_installed <agent_id>
# ---------------------------------------------------------------------------
ensure_agent_installed() {
    local agent="$1"
    local binary="${AGENT_BIN[$agent]}"
    local pkg="${AGENT_PKG[$agent]:-}"
    local install_cmd="${AGENT_INSTALL_CMD[$agent]:-}"
    local display="${AGENT_DISPLAY[$agent]}"

    # Check if the binary is on PATH inside the container (must run through a shell)
    if devcontainer exec \
        --workspace-folder "$WORKSPACE_PATH" \
        --docker-path "$CONTAINER_BIN_PATH" \
        sh -c "command -v ${binary} >/dev/null 2>&1" >/dev/null 2>&1; then
        return 0
    fi

    echo ""
    echo "Warning: ${display} ('${binary}') is not installed in the container."

    # Only prompt on an interactive terminal
    if [[ ! -t 0 ]]; then
        echo "Non-interactive session: skipping auto-install. Run 'dev-ai -b' to rebuild." >&2
        return 0
    fi

    local answer
    read -r -p "Install ${display} now? [Y/n]: " answer
    answer="${answer:-Y}"
    if [[ "${answer,,}" != "y" ]]; then
        echo "Skipping installation. The agent may fail to launch."
        return 0
    fi

    echo "Installing ${display}..."
    if [[ -n "$pkg" ]]; then
        # Preflight: ensure pnpm is available in the container, bootstrapping it
        # via corepack (bundled with Node) if the container predates pnpm.
        if ! devcontainer exec \
            --workspace-folder "$WORKSPACE_PATH" \
            --docker-path "$CONTAINER_BIN_PATH" \
            sh -c 'command -v pnpm >/dev/null 2>&1 || { command -v corepack >/dev/null 2>&1 && COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack enable pnpm >/dev/null 2>&1 && COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack prepare pnpm@latest --activate >/dev/null 2>&1; }; command -v pnpm >/dev/null 2>&1' >/dev/null 2>&1; then
            echo "Error: pnpm not found in container and could not be bootstrapped. Run 'dev-ai -b' to rebuild the container." >&2
            return 1
        fi
        devcontainer exec \
            --workspace-folder "$WORKSPACE_PATH" \
            --docker-path "$CONTAINER_BIN_PATH" \
            sh -c "pnpm config set global-bin-dir /usr/local/bin >/dev/null 2>&1 || true; pnpm add -g ${pkg}@latest"
    elif [[ -n "$install_cmd" ]]; then
        # Preflight: ensure curl is available in the container
        if ! devcontainer exec \
            --workspace-folder "$WORKSPACE_PATH" \
            --docker-path "$CONTAINER_BIN_PATH" \
            sh -c "command -v curl >/dev/null 2>&1" >/dev/null 2>&1; then
            echo "Error: curl not found in container. Run 'dev-ai -b' to rebuild the container." >&2
            return 1
        fi
        devcontainer exec \
            --workspace-folder "$WORKSPACE_PATH" \
            --docker-path "$CONTAINER_BIN_PATH" \
            sh -c "$install_cmd"
    else
        echo "Error: no install method defined for ${display}." >&2
        return 1
    fi

    _add_agent_to_install_tools "$agent"
}
