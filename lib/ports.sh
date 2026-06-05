# Port forwarding: declare published ports in devcontainer.json runArgs as
# "-p HOST:CONTAINER" entries, and verify/repair them on a running container.
#
# Only the canonical TCP form is managed: each spec is "HOST:CONTAINER" (a bare
# "PORT" is expanded to "PORT:PORT").  Pre-existing runArgs that use protocols,
# host IPs, or port ranges are left untouched and not managed by dev-ai.
#
# Depends on: devcontainer_json.sh (_strip_jsonc, _dc_modify),
#             container.sh (get_container_id, remount_devcontainer,
#                           rebuild_devcontainer),
#             utils.sh (resolve_dc_file).

# ---------------------------------------------------------------------------
# prompt_port_selection: interactively ask which ports to forward.  Writes a
# space-separated list of normalized HOST:CONTAINER specs (possibly empty) to
# the nameref variable passed as $1.  Used by init.
# Usage:
#   local selected=""
#   prompt_port_selection selected
# ---------------------------------------------------------------------------
prompt_port_selection() {
    local -n _pps_result="$1"
    _pps_result=""

    echo ""
    echo "Forward ports from the container to the host? (optional)"
    echo "  Enter ports separated by spaces or commas. Use PORT or HOST:CONTAINER."
    echo "  Examples: 3000 8080   |   8080:80   |   leave empty to skip."

    local _pps_input
    read -r -p "Ports to forward [none]: " _pps_input || true
    _pps_input="${_pps_input//,/ }"
    [[ -z "${_pps_input// }" ]] && return 0

    local -a _pps_specs=()
    local -A _pps_seen=()
    local _pps_p _pps_norm
    for _pps_p in $_pps_input; do
        if _pps_norm=$(_normalize_port_spec "$_pps_p"); then
            if [[ -z "${_pps_seen[$_pps_norm]+x}" ]]; then
                _pps_seen["$_pps_norm"]=1
                _pps_specs+=("$_pps_norm")
            fi
        else
            echo "  ! ignoring invalid port: '$_pps_p'"
        fi
    done

    _pps_result="${_pps_specs[*]}"
}

# ---------------------------------------------------------------------------
# _normalize_port_spec: validate a port spec and echo it as HOST:CONTAINER.
# Accepts "3000" (-> "3000:3000") or "8080:80".  Returns 1 on invalid input.
# ---------------------------------------------------------------------------
_normalize_port_spec() {
    local spec="$1" host container
    if [[ "$spec" =~ ^([0-9]+):([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"; container="${BASH_REMATCH[2]}"
    elif [[ "$spec" =~ ^([0-9]+)$ ]]; then
        host="$spec"; container="$spec"
    else
        return 1
    fi
    (( host >= 1 && host <= 65535 && container >= 1 && container <= 65535 )) || return 1
    printf '%s:%s' "$host" "$container"
}

# ---------------------------------------------------------------------------
# _dc_get_published_ports: print each managed "-p"/"--publish" value from a
# devcontainer.json's runArgs, one per line.  Only canonical HOST:CONTAINER
# (or bare PORT) forms are returned; anything else is ignored.
# Usage: _dc_get_published_ports <dc_file>
# ---------------------------------------------------------------------------
_dc_get_published_ports() {
    local dc_file="$1"
    [[ -f "$dc_file" ]] || return 0

    local -a args=()
    mapfile -t args < <(_strip_jsonc "$dc_file" | jq -r '(.runArgs // [])[]' 2>/dev/null || true)

    local i n="${#args[@]}" raw norm
    for ((i = 0; i < n; i++)); do
        raw=""
        case "${args[$i]}" in
            -p|--publish)      (( i + 1 < n )) && { raw="${args[$((i + 1))]}"; i=$((i + 1)); } ;;
            -p=*)              raw="${args[$i]#-p=}" ;;
            --publish=*)       raw="${args[$i]#--publish=}" ;;
        esac
        [[ -n "$raw" ]] || continue
        if norm=$(_normalize_port_spec "$raw"); then
            printf '%s\n' "$norm"
        fi
    done
}

# ---------------------------------------------------------------------------
# _dc_has_published_port: return 0 if the exact HOST:CONTAINER spec is already
# declared in runArgs.  Usage: _dc_has_published_port <dc_file> <host:container>
# ---------------------------------------------------------------------------
_dc_has_published_port() {
    local dc_file="$1" spec="$2" existing
    while IFS= read -r existing; do
        [[ "$existing" == "$spec" ]] && return 0
    done < <(_dc_get_published_ports "$dc_file")
    return 1
}

# ---------------------------------------------------------------------------
# _dc_add_published_ports: append "-p HOST:CONTAINER" entries to runArgs.
# Idempotent (skips exact duplicates) and skips host-port collisions (a host
# port already mapped to a different container port).  Echoes a line per spec
# describing the outcome.
# Usage: _dc_add_published_ports <dc_file> <host:container>...
# ---------------------------------------------------------------------------
_dc_add_published_ports() {
    local dc_file="$1"; shift

    # Collect host ports already mapped (declared + pending in this batch).
    local -A host_to_container=()
    local existing
    while IFS= read -r existing; do
        host_to_container["${existing%%:*}"]="${existing##*:}"
    done < <(_dc_get_published_ports "$dc_file")

    local spec host container
    for spec in "$@"; do
        host="${spec%%:*}"
        container="${spec##*:}"

        if _dc_has_published_port "$dc_file" "$spec"; then
            echo "  - $spec already declared (skipped)"
            continue
        fi
        if [[ -n "${host_to_container[$host]+x}" ]]; then
            echo "  ! host port $host already maps to container port ${host_to_container[$host]} (skipped $spec)"
            continue
        fi

        if _dc_modify "$dc_file" --arg p "$spec" \
            '.runArgs = ((.runArgs // []) + ["-p", $p])'; then
            host_to_container["$host"]="$container"
            echo "  + forwarding $host (host) -> $container (container)"
        fi
    done
}

# ---------------------------------------------------------------------------
# get_published_container_ports: print the TCP port mappings actually published
# on a running container as HOST:CONTAINER lines (deduplicated, /tcp only).
# Usage: get_published_container_ports <container_id>
# ---------------------------------------------------------------------------
get_published_container_ports() {
    local container_id="$1"
    "$containerBin" inspect --format \
        '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{range $conf}}{{.HostPort}} {{$p}}{{"\n"}}{{end}}{{end}}{{end}}' \
        "$container_id" 2>/dev/null \
        | awk '
            $2 ~ /\/tcp$/ {
                sub(/\/tcp$/, "", $2)
                key = $1 ":" $2
                if (!(key in seen) && $1 != "") { seen[key] = 1; print key }
            }'
}

# ---------------------------------------------------------------------------
# check_and_warn_missing_ports: compare ports declared in devcontainer.json
# against those actually published on the running container.  If any declared
# port is not published, warn and (interactively) offer to remount or rebuild.
# Usage: check_and_warn_missing_ports <container_id>
# Returns: 0 if nothing missing or the user repaired it; 1 if ports remain
#          unforwarded (user continued, or non-interactive session).
# ---------------------------------------------------------------------------
check_and_warn_missing_ports() {
    local container_id="$1"

    local dc_file
    dc_file=$(resolve_dc_file) || return 0

    local -a declared=()
    mapfile -t declared < <(_dc_get_published_ports "$dc_file")
    (( ${#declared[@]} > 0 )) || return 0

    local -A actual_set=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && actual_set["$line"]=1
    done < <(get_published_container_ports "$container_id")

    local -a missing=()
    local spec
    for spec in "${declared[@]}"; do
        [[ -n "${actual_set[$spec]+x}" ]] || missing+=("$spec")
    done

    (( ${#missing[@]} == 0 )) && return 0

    echo ""
    echo "Warning: running container (ID: $container_id) is missing port forward(s):"
    for spec in "${missing[@]}"; do
        echo "  - ${spec%%:*} (host) -> ${spec##*:} (container)"
    done
    echo ""
    echo "Ports cannot be published on an already-running container."

    if [[ ! -t 0 ]]; then
        echo "Non-interactive session: continuing without these port forward(s)." >&2
        return 1
    fi

    echo "  1) Continue without forwarding these port(s)"
    echo "  2) Remount: stop and restart with port forwarding (fast, skips postCreate)  [recommended]"
    echo "  3) Rebuild: full stop/rebuild (slow, runs postCreate)"

    local choice
    while true; do
        read -r -p "Choose [1/2/3] (default: 2): " choice
        choice="${choice:-2}"
        case "$choice" in
            1) echo "Continuing without port forwarding."; return 1 ;;
            2) remount_devcontainer; return 0 ;;
            3) rebuild_devcontainer; return 0 ;;
            *) echo "Please enter 1, 2, or 3." ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# add_forwarded_ports: declare ports in devcontainer.json and, if a container
# is already running, offer to apply them.  Entry point for `-p`/`--ports`.
# Usage: add_forwarded_ports <comma/space-separated port list>
# ---------------------------------------------------------------------------
add_forwarded_ports() {
    local input="$1"

    local dc_file
    dc_file=$(resolve_dc_file) || {
        echo "Error: No devcontainer config found in '$WORKSPACE_PATH'." >&2
        echo "  Run 'dev-ai --init' to create one." >&2
        return 1
    }

    # Accept commas or spaces as separators.
    input="${input//,/ }"

    local -a specs=()
    local -A seen=()
    local p norm
    for p in $input; do
        if norm=$(_normalize_port_spec "$p"); then
            if [[ -z "${seen[$norm]+x}" ]]; then
                seen["$norm"]=1
                specs+=("$norm")
            fi
        else
            echo "  ! ignoring invalid port: '$p' (use PORT or HOST:CONTAINER)"
        fi
    done

    if (( ${#specs[@]} == 0 )); then
        echo "No valid ports given. Nothing to do." >&2
        return 1
    fi

    echo "Declaring forwarded port(s) in $dc_file:"
    _dc_add_published_ports "$dc_file" "${specs[@]}"

    local container_id
    container_id=$(get_container_id)
    if [[ -z "$container_id" ]]; then
        echo ""
        echo "No running container — port(s) will be published next time you start it."
        return 0
    fi

    check_and_warn_missing_ports "$container_id" || true
    return 0
}

# ---------------------------------------------------------------------------
# forward_ports: verify and repair port forwarding on the running container.
# Entry point for `-P`/`--forward-ports`.
# ---------------------------------------------------------------------------
forward_ports() {
    local dc_file
    dc_file=$(resolve_dc_file) || {
        echo "Error: No devcontainer config found in '$WORKSPACE_PATH'." >&2
        return 1
    }

    local -a declared=()
    mapfile -t declared < <(_dc_get_published_ports "$dc_file")
    if (( ${#declared[@]} == 0 )); then
        echo "No forwarded ports declared in $dc_file."
        echo "  Add some with: dev-ai --ports <PORT[,PORT...]>"
        return 0
    fi

    echo "Declared forwarded port(s):"
    local spec
    for spec in "${declared[@]}"; do
        echo "  - ${spec%%:*} (host) -> ${spec##*:} (container)"
    done

    local container_id
    container_id=$(get_container_id)
    if [[ -z "$container_id" ]]; then
        echo ""
        echo "No running container — port(s) will be published next time you start it."
        return 0
    fi

    if check_and_warn_missing_ports "$container_id"; then
        echo ""
        echo "All declared ports are forwarded."
        return 0
    fi
    return 1
}
