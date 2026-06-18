# Interactively upgrade scripts and devcontainer.json.  Also checks if
# upgrade is needed on normal startup.
#
# Depends on: agents.sh (KNOWN_AGENTS, AGENT_DISPLAY, _dc_has_all_mounts,
#   _dc_add_agent_mounts), devcontainer_json.sh, utils.sh.

# ---------------------------------------------------------------------------
# upgrade_devcontainer: interactively upgrade scripts and devcontainer.json
# fields in an existing .devcontainer directory.
# Usage: upgrade_devcontainer [target_dir]
# ---------------------------------------------------------------------------
upgrade_devcontainer() {
    local target_dir
    target_dir=$(realpath "${1:-$PWD}")

    if [[ ! -d "$target_dir" ]]; then
        echo "Error: '$target_dir' is not a valid directory." >&2
        exit 1
    fi

    local existing_dc_file
    existing_dc_file=$(resolve_dc_file "$target_dir") || {
        echo "Error: No devcontainer config found in '$target_dir'." >&2
        echo "  Run 'dev-ai --init' to create one." >&2
        exit 1
    }

    local dc_dir="$target_dir/.devcontainer"

    echo "Upgrading devcontainer in: $target_dir"
    echo ""

    # --- Scripts ---
    local script_name template_file target_script template_version target_version choice

    for script_name in "postCreate.sh" "initialize.sh"; do
        case "$script_name" in
            postCreate.sh) template_file="$POST_CREATE_TEMPLATE" ;;
            initialize.sh)  template_file="$INITIALIZE_TEMPLATE" ;;
        esac
        target_script="$dc_dir/$script_name"

        if [[ ! -f "$template_file" ]]; then
            echo "  ! template for $script_name not found at '$template_file'" >&2
            continue
        fi

        template_version="$(get_project_version)"
        target_version="$(extract_script_version "$target_script")"

        if [[ ! -f "$target_script" ]]; then
            read -r -p "  $script_name not found — install v${template_version:-unknown}? [Y/n]: " choice
            if [[ "${choice:-Y}" =~ ^[Yy] ]]; then
                _safe_cp "$template_file" "$target_script"
                chmod +x "$target_script"
                _stamp_version "$target_script" "$template_version"
                echo "  ✓ Installed $script_name (v${template_version:-unknown})"
            else
                echo "  - Skipped $script_name"
            fi
        elif [[ -z "$target_version" ]] || version_is_newer "$template_version" "$target_version"; then
            echo "  $script_name outdated (v${target_version:-unknown} → v${template_version:-unknown})"
            echo ""
            diff -u "$target_script" "$template_file" \
                --label "installed/$script_name" --label "template/$script_name" 2>/dev/null || true
            echo ""
            read -r -p "  Apply update? [Y/n]: " choice
            if [[ "${choice:-Y}" =~ ^[Yy] ]]; then
                _safe_cp "$template_file" "$target_script"
                chmod +x "$target_script"
                _stamp_version "$target_script" "$template_version"
                echo "  ✓ Updated $script_name (v${target_version:-unknown} → v${template_version:-unknown})"
            else
                echo "  - Kept $script_name (v${target_version:-unknown})"
            fi
        elif version_is_newer "$target_version" "$template_version"; then
            echo "  ! $script_name is newer than template (v${target_version:-unknown} > v${template_version:-unknown}) — skipping"
        else
            echo "  ✓ $script_name up to date (v${target_version:-unknown})"
        fi
    done

    echo ""
    echo "Checking $existing_dc_file..."

    # --- Agent mounts (iterate registry instead of per-agent blocks) ---
    local agent
    for agent in "${KNOWN_AGENTS[@]}"; do
        if _dc_has_all_mounts "$existing_dc_file" "$agent"; then
            echo "  ✓ ${AGENT_DISPLAY[$agent]} bind mount(s) present"
        else
            echo "  ! ${AGENT_DISPLAY[$agent]} bind mount(s) missing"
            read -r -p "  Add them? [Y/n]: " choice
            if [[ "${choice:-Y}" =~ ^[Yy] ]]; then
                if _dc_add_agent_mounts "$existing_dc_file" "$agent"; then
                    echo "  ✓ Added ${AGENT_DISPLAY[$agent]} bind mount(s)"
                fi
            else
                echo "  - Skipped"
            fi
        fi
    done

    # --- initializeCommand ---
    local current_ic
    current_ic="$(_dc_get_init_cmd "$existing_dc_file" || true)"
    if echo "$current_ic" | grep -q 'initialize\.sh'; then
        echo "  ✓ initializeCommand → initialize.sh"
    elif [[ -z "$current_ic" ]]; then
        echo "  ! initializeCommand missing"
        read -r -p '  Set to ["bash", ".devcontainer/initialize.sh"]? [Y/n]: ' choice
        if [[ "${choice:-Y}" =~ ^[Yy] ]]; then
            if _dc_set_init_cmd "$existing_dc_file"; then
                echo "  ✓ Set initializeCommand → .devcontainer/initialize.sh"
            fi
        else
            echo "  - Skipped"
        fi
    else
        echo "  ! initializeCommand is: $current_ic"
        echo "    Expected: [\"bash\", \".devcontainer/initialize.sh\"]"
        echo "    Move any custom logic to .devcontainer/initialize_pre_hook.sh"
        read -r -p "  Replace? [Y/n]: " choice
        if [[ "${choice:-Y}" =~ ^[Yy] ]]; then
            if _dc_set_init_cmd "$existing_dc_file"; then
                echo "  ✓ Updated initializeCommand → .devcontainer/initialize.sh"
            fi
        else
            echo "  - Kept existing initializeCommand"
        fi
    fi

    # --- postCreateCommand ---
    if _dc_has_post_create_script "$existing_dc_file"; then
        echo "  ✓ postCreateCommand → postCreate.sh"
    else
        local current_pcc
        current_pcc="$(_dc_get_post_create_cmd "$existing_dc_file" || true)"
        if [[ -z "$current_pcc" ]]; then
            echo "  ! postCreateCommand missing"
            read -r -p '  Set to "bash .devcontainer/postCreate.sh"? [Y/n]: ' choice
        else
            echo "  ! postCreateCommand is: $current_pcc"
            echo "    Expected: bash .devcontainer/postCreate.sh"
            echo "    Move any custom logic to .devcontainer/postCreate_pre_hook.sh"
            read -r -p "  Replace? [Y/n]: " choice
        fi
        if [[ "${choice:-Y}" =~ ^[Yy] ]]; then
            if _dc_set_post_create_cmd "$existing_dc_file"; then
                echo "  ✓ Set postCreateCommand → bash .devcontainer/postCreate.sh"
            fi
        else
            echo "  - Kept existing postCreateCommand"
        fi
    fi

    # --- runArgs --env-file ---
    if _dc_has_env_file_run_arg "$existing_dc_file"; then
        echo "  ✓ runArgs --env-file present"
    else
        echo "  ! runArgs --env-file .devcontainer/.env missing"
        read -r -p "  Add '--env-file=\${localWorkspaceFolder}/.devcontainer/.env' to runArgs? [Y/n]: " choice
        if [[ "${choice:-Y}" =~ ^[Yy] ]]; then
            if _dc_add_env_file_run_arg "$existing_dc_file"; then
                echo "  ✓ Added runArgs --env-file"
            fi
        else
            echo "  - Skipped"
        fi
    fi

    # --- Forwarded ports (runArgs -p) ---
    local -a _declared_ports=()
    mapfile -t _declared_ports < <(_dc_get_published_ports "$existing_dc_file")
    if (( ${#_declared_ports[@]} > 0 )); then
        echo "  ✓ forwarded port(s): ${_declared_ports[*]}"
        read -r -p "  Add more forwarded ports? [y/N]: " choice
    else
        echo "  ! no forwarded ports declared"
        read -r -p "  Forward any ports now? [y/N]: " choice
    fi
    if [[ "${choice:-N}" =~ ^[Yy] ]]; then
        local _new_ports=""
        prompt_port_selection _new_ports
        if [[ -n "$_new_ports" ]]; then
            # shellcheck disable=SC2086
            _dc_add_published_ports "$existing_dc_file" $_new_ports
            echo "    Restart the container ('dev-ai --remount') to apply."
        fi
    fi

    # --- name field ---
    if _dc_has_name "$existing_dc_file"; then
        echo "  ✓ name field present"
    else
        local _dc_folder_name
        _dc_folder_name=$(basename "$target_dir")
        echo "  ! name field missing"
        read -r -p "  Set name to '$_dc_folder_name'? [Y/n]: " choice
        if [[ "${choice:-Y}" =~ ^[Yy] ]]; then
            if _dc_set_name "$existing_dc_file" "$_dc_folder_name"; then
                echo "  ✓ Set name to '$_dc_folder_name'"
            fi
        else
            echo "  - Skipped"
        fi
    fi

    # --- INSTALL_TOOLS in remoteEnv ---
    local current_tools
    current_tools=$(_strip_jsonc "$existing_dc_file" \
        | jq -r '.remoteEnv.INSTALL_TOOLS // empty' 2>/dev/null || true)
    if [[ -n "$current_tools" ]]; then
        echo "  ✓ INSTALL_TOOLS = $current_tools"
        read -r -p "  Change tool selection? [y/N]: " choice
        if [[ "${choice:-N}" =~ ^[Yy] ]]; then
            local new_tools=""
            prompt_tool_selection new_tools "$current_tools"
            if _dc_modify "$existing_dc_file" --arg tools "$new_tools" \
                '.remoteEnv = ((.remoteEnv // {}) + {INSTALL_TOOLS: $tools})'; then
                echo "  ✓ INSTALL_TOOLS updated to: $new_tools"
                echo "    Rebuild the container ('dev-ai --build') to apply."
            fi
        fi
    else
        echo "  ! INSTALL_TOOLS not set in remoteEnv (defaults to all tools)"
        read -r -p "  Set it now? [y/N]: " choice
        if [[ "${choice:-N}" =~ ^[Yy] ]]; then
            local new_tools=""
            prompt_tool_selection new_tools "${AGENT:-copilot}"
            if _dc_modify "$existing_dc_file" --arg tools "$new_tools" \
                '.remoteEnv = ((.remoteEnv // {}) + {INSTALL_TOOLS: $tools})'; then
                echo "  ✓ INSTALL_TOOLS set to: $new_tools"
                echo "    Rebuild the container ('dev-ai --build') to apply."
            fi
        fi
    fi

    # --- Version stamp in devcontainer.json ---
    local json_version
    json_version="$(extract_script_version "$existing_dc_file")"
    local project_ver
    project_ver="$(get_project_version)"
    if [[ "$project_ver" != "unknown" ]]; then
        if [[ -z "$json_version" ]]; then
            _stamp_version "$existing_dc_file" "$project_ver" "//"
            echo "  ✓ Added version stamp to devcontainer.json (v$project_ver)"
        elif version_is_newer "$project_ver" "$json_version"; then
            local tmpfile
            tmpfile=$(mktemp)
            sed -E 's|^// Version:.*|// Version: '"$project_ver"'|' "$existing_dc_file" > "$tmpfile" \
                && mv "$tmpfile" "$existing_dc_file"
            echo "  ✓ Updated version stamp in devcontainer.json (v${json_version} → v$project_ver)"
        else
            echo "  ✓ devcontainer.json version stamp up to date (v${json_version})"
        fi
    fi

    echo ""
    ensure_gitignore_entry "$dc_dir" ".env"
    ensure_gitignore_entry "$dc_dir" ".tmp"
    ensure_gitignore_entry "$dc_dir" "tmp"
    echo "Done."
}

# ---------------------------------------------------------------------------
# _check_upgrade_needed: warn on normal startup if devcontainer scripts in
# WORKSPACE_PATH are outdated compared to the project VERSION.
# ---------------------------------------------------------------------------
_check_upgrade_needed() {
    local project_version
    project_version="$(get_project_version)"
    [[ "$project_version" != "unknown" ]] || return 0

    local dc_dir="$WORKSPACE_PATH/.devcontainer"
    local file outdated=false

    for file in "$dc_dir/postCreate.sh" "$dc_dir/initialize.sh" "$dc_dir/devcontainer.json"; do
        [[ -f "$file" ]] || continue
        local installed_version
        installed_version="$(extract_script_version "$file")"
        if [[ -z "$installed_version" ]] || version_is_newer "$project_version" "$installed_version"; then
            outdated=true
            break
        fi
    done

    if $outdated; then
        echo ""
        echo "Notice: devcontainer scripts in '$WORKSPACE_PATH' are outdated (latest: v$project_version)."
        echo "  Run '$SCRIPT_NAME --upgrade $WORKSPACE_PATH' to update."
        echo ""
        sleep 5
    fi
}
