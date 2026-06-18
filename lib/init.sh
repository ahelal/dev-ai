# Initialise a fresh .devcontainer from the project template.
#
# Depends on: agents.sh (ensure_agent_dirs), utils.sh (ensure_gitignore_entry,
#   _stamp_version, _safe_cp, get_project_version, extract_script_version,
#   version_is_newer, resolve_dc_file).

# ---------------------------------------------------------------------------
# init_devcontainer: create a new .devcontainer directory from the project
# template.  Prompts for base image selection and installs scripts.
# Usage: init_devcontainer [target_dir]
# ---------------------------------------------------------------------------
init_devcontainer() {
    local target_dir
    target_dir=$(realpath "${1:-$PWD}")

    if [[ ! -d "$target_dir" ]]; then
        echo "Error: '$target_dir' is not a valid directory." >&2
        exit 1
    fi

    if [[ ! -f "$TEMPLATE_FILE" ]]; then
        echo "Error: Template not found at '$TEMPLATE_FILE'" >&2
        exit 1
    fi

    local dc_dir="$target_dir/.devcontainer"
    local dc_file="$dc_dir/devcontainer.json"
    local should_write_dc=true
    local existing_dc_file=""

    # Never overwrite existing devcontainer config.
    if existing_dc_file=$(resolve_dc_file "$target_dir") 2>/dev/null; then
        should_write_dc=false
    fi

    mkdir -p "$dc_dir"

    if $should_write_dc; then
        # Project-type menu — images from https://github.com/devcontainers/images
        local -a _labels _images
        _labels=(
            "Ubuntu (base)"
            "Debian (base)"
            "Alpine (base)"
            "Python"
            "Node.js / JavaScript"
            "TypeScript + Node"
            "Go"
            "Java 21"
            "Java 8"
            ".NET / C#"
            "C / C++"
            "PHP"
            "Ruby"
            "Rust"
            "Anaconda (Data Science)"
            "Miniconda"
            "Universal (multi-language)"
        )
        _images=(
            "mcr.microsoft.com/devcontainers/base:ubuntu"
            "mcr.microsoft.com/devcontainers/base:debian"
            "mcr.microsoft.com/devcontainers/base:alpine"
            "mcr.microsoft.com/devcontainers/python:3"
            "mcr.microsoft.com/devcontainers/javascript-node:20"
            "mcr.microsoft.com/devcontainers/typescript-node:20"
            "mcr.microsoft.com/devcontainers/go:1"
            "mcr.microsoft.com/devcontainers/java:21"
            "mcr.microsoft.com/devcontainers/java-8:21"
            "mcr.microsoft.com/devcontainers/dotnet:8"
            "mcr.microsoft.com/devcontainers/cpp:1"
            "mcr.microsoft.com/devcontainers/php:8"
            "mcr.microsoft.com/devcontainers/ruby:3"
            "mcr.microsoft.com/devcontainers/rust:1"
            "mcr.microsoft.com/devcontainers/anaconda:3"
            "mcr.microsoft.com/devcontainers/miniconda:3"
            "mcr.microsoft.com/devcontainers/universal:2"
        )

        echo ""
        echo "Select project type:"
        local _i
        for _i in "${!_labels[@]}"; do
            printf "  %2d) %s\n" "$((_i + 1))" "${_labels[$_i]}"
        done
        echo ""

        local _choice
        while true; do
            read -r -p "Enter number [1-${#_labels[@]}]: " _choice
            if [[ "$_choice" =~ ^[0-9]+$ ]] && (( _choice >= 1 && _choice <= ${#_labels[@]} )); then
                break
            fi
            echo "Invalid choice. Please enter a number between 1 and ${#_labels[@]}."
        done

        local _selected_image="${_images[$((_choice - 1))]}"
        echo "Using image: $_selected_image"

        # --- Tool selection ---
        local _selected_tools=""
        prompt_tool_selection _selected_tools "${AGENT:-copilot}"

        local _folder_name
        _folder_name=$(basename "$target_dir")
        local _escaped_image _escaped_folder
        _escaped_image=$(printf '%s' "$_selected_image" | sed 's/[&|\\]/\\&/g')
        _escaped_folder=$(printf '%s' "$_folder_name" | sed 's/[&|\\]/\\&/g')
        sed -e "s|\"image\": \"[^\"]*\"|\"image\": \"$_escaped_image\"|" \
            -e "s|__FOLDER_NAME__|$_escaped_folder|" \
            "$TEMPLATE_FILE" > "$dc_file"

        _dc_modify "$dc_file" --arg tools "$_selected_tools" \
            '.remoteEnv = ((.remoteEnv // {}) + {INSTALL_TOOLS: $tools})'

        # --- Port forwarding (optional) ---
        local _selected_ports=""
        prompt_port_selection _selected_ports
        if [[ -n "$_selected_ports" ]]; then
            # shellcheck disable=SC2086
            _dc_add_published_ports "$dc_file" $_selected_ports
        fi

        local _project_version
        _project_version="$(get_project_version)"
        if [[ "$_project_version" != "unknown" ]]; then
            _stamp_version "$dc_file" "$_project_version" "//"
        fi

        echo ""
        echo "Created : $dc_file"
        echo "Name    : $_folder_name"
        echo "Image   : $_selected_image"
        echo "Tools   : $_selected_tools"
        if [[ -n "$_selected_ports" ]]; then
            echo "Ports   : $_selected_ports"
        fi
    else
        echo "Error: devcontainer config already exists at '$existing_dc_file'." >&2
        echo "  Use 'dev-ai --upgrade' to update scripts and config fields." >&2
        exit 1
    fi

    # --- Install template scripts ---
    local _script_name _template_path
    for _script_name in "postCreate.sh" "initialize.sh"; do
        case "$_script_name" in
            postCreate.sh) _template_path="$POST_CREATE_TEMPLATE" ;;
            initialize.sh) _template_path="$INITIALIZE_TEMPLATE" ;;
        esac

        if [[ ! -f "$_template_path" ]]; then
            echo "Warning: template for $_script_name not found at '$_template_path'" >&2
            continue
        fi

        local _target_script="$dc_dir/$_script_name"
        local template_version target_version
        template_version="$(get_project_version)"
        target_version="$(extract_script_version "$_target_script")"

        if [[ ! -f "$_target_script" ]]; then
            _safe_cp "$_template_path" "$_target_script"
            chmod +x "$_target_script"
            _stamp_version "$_target_script" "$template_version"
            echo "Script  : $_target_script (installed${template_version:+ v$template_version})"
        elif [[ -z "$target_version" ]] || version_is_newer "$template_version" "$target_version"; then
            _safe_cp "$_template_path" "$_target_script"
            chmod +x "$_target_script"
            _stamp_version "$_target_script" "$template_version"
            echo "Script  : $_target_script (updated v${target_version:-unknown} -> v${template_version:-unknown})"
        else
            echo "Script  : $_target_script (kept; current ${target_version:-unknown}, template ${template_version:-unknown})"
        fi
    done

    ensure_gitignore_entry "$dc_dir" ".env"
    ensure_gitignore_entry "$dc_dir" ".tmp"
    ensure_gitignore_entry "$dc_dir" "tmp"
}
