# Utility helpers: version stamping, version comparison, gitignore management,
# devcontainer.json resolution.

# ---------------------------------------------------------------------------
# extract_script_version: read the "Version: x.y.z" stamp from a file.
# Supports both shell (# Version:) and JSON (// Version:) comment styles.
# Prints the version string or nothing if no stamp is found.
# ---------------------------------------------------------------------------
extract_script_version() {
    local file_path="$1"
    [[ -f "$file_path" ]] || return 0
    local line
    line=$(grep -m1 -E '^(#|//) Version:' "$file_path" 2>/dev/null || true)
    [[ -n "$line" ]] || return 0
    echo "$line" | sed -E 's/^(#|\/\/) Version:[[:space:]]*//' | tr -d '[:space:]'
}

# ---------------------------------------------------------------------------
# get_project_version: print the project version from the VERSION file.
# Returns "unknown" when the file is missing.
# ---------------------------------------------------------------------------
get_project_version() {
    if [[ -f "$VERSION_FILE" ]]; then
        tr -d '[:space:]' < "$VERSION_FILE"
    else
        echo "unknown"
    fi
}

# ---------------------------------------------------------------------------
# _stamp_version: insert a version stamp on line 2 of a file.
# Portable across GNU and BSD sed.
# Usage: _stamp_version <file> <version> [prefix]
#   prefix defaults to "#" for shell scripts; use "//" for JSON.
# ---------------------------------------------------------------------------
_stamp_version() {
    local file="$1" version="$2" prefix="${3:-#}"
    local tmpfile
    tmpfile=$(mktemp)
    { head -1 "$file"; echo "$prefix Version: $version"; tail -n +2 "$file"; } > "$tmpfile" \
        && mv "$tmpfile" "$file"
}

# ---------------------------------------------------------------------------
# _safe_cp: copy src to dst, removing any existing symlink at dst first
# to avoid "are identical" errors.
# ---------------------------------------------------------------------------
_safe_cp() {
    local src="$1" dst="$2"
    [[ -L "$dst" ]] && rm "$dst"
    cp "$src" "$dst"
}

# ---------------------------------------------------------------------------
# version_is_newer: return 0 (true) if $1 is a newer semver than $2.
# Non-numeric characters are stripped before comparison.
# ---------------------------------------------------------------------------
version_is_newer() {
    local candidate_raw="$1"
    local current_raw="$2"
    local candidate="${candidate_raw//[^0-9.]/}"
    local current="${current_raw//[^0-9.]/}"

    [[ -n "$candidate" && -n "$current" ]] || return 1
    [[ "$candidate" == "$current" ]] && return 1

    local IFS=.
    local -a c_parts=() t_parts=()
    read -r -a c_parts <<< "$candidate"
    read -r -a t_parts <<< "$current"

    local len="${#c_parts[@]}"
    if (( ${#t_parts[@]} > len )); then
        len="${#t_parts[@]}"
    fi

    local i c t
    for ((i = 0; i < len; i++)); do
        c="${c_parts[$i]:-0}"
        t="${t_parts[$i]:-0}"
        c="${c//[^0-9]/}"
        t="${t//[^0-9]/}"
        c="${c:-0}"
        t="${t:-0}"

        if ((10#$c > 10#$t)); then
            return 0
        elif ((10#$c < 10#$t)); then
            return 1
        fi
    done

    return 1
}

# ---------------------------------------------------------------------------
# resolve_dc_file: print the path to the devcontainer.json for a workspace.
# Checks .devcontainer/devcontainer.json first, then .devcontainer.json.
# Returns 0 and prints the path if found; returns 1 with no output if not.
# Usage: dc_file=$(resolve_dc_file "/path/to/workspace")
# ---------------------------------------------------------------------------
resolve_dc_file() {
    local workspace="${1:-$WORKSPACE_PATH}"
    if [[ -f "${workspace}/.devcontainer/devcontainer.json" ]]; then
        echo "${workspace}/.devcontainer/devcontainer.json"
        return 0
    elif [[ -f "${workspace}/.devcontainer.json" ]]; then
        echo "${workspace}/.devcontainer.json"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# ensure_gitignore_entry: add an entry to .gitignore if not already present.
# Creates the .gitignore file if it does not exist.
# Usage: ensure_gitignore_entry "/path/to/project" ".env"
# ---------------------------------------------------------------------------
ensure_gitignore_entry() {
    local target_dir="$1" entry="$2"
    local gitignore_file="$target_dir/.gitignore"

    if [[ ! -f "$gitignore_file" ]]; then
        touch "$gitignore_file"
        echo "Created $gitignore_file"
    fi

    local escaped_entry
    escaped_entry=$(printf '%s' "$entry" | sed 's/[.[\*^$]/\\&/g')
    if grep -Eq "^[[:space:]]*/?${escaped_entry}([[:space:]]*|$)" "$gitignore_file"; then
        echo ".gitignore already contains '$entry'."
        return 0
    fi

    if [[ -s "$gitignore_file" ]]; then
        printf "\n" >> "$gitignore_file"
    fi
    printf "%s\n" "$entry" >> "$gitignore_file"
    echo "Added '$entry' to $gitignore_file"
}
