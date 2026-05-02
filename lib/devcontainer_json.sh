# devcontainer.json accessors: read and mutate fields using jq.
#
# devcontainer.json is JSONC (JSON with comments).  The _strip_jsonc helper
# converts it to standard JSON so jq can process it.  Write operations back
# up the original file when it contained comments.

# ---------------------------------------------------------------------------
# _strip_jsonc: convert a JSONC file to valid JSON on stdout.
# Handles // line comments, /* block comments */, and trailing commas.
# Uses an awk tokenizer that correctly skips comments inside string literals.
# ---------------------------------------------------------------------------
_strip_jsonc() {
    local file="$1"
    awk '
    BEGIN { in_string = 0; in_block = 0 }
    {
        line = ""
        i = 1
        n = length($0)
        while (i <= n) {
            c  = substr($0, i, 1)
            c2 = substr($0, i, 2)

            if (in_block) {
                if (c2 == "*/") { in_block = 0; i += 2; continue }
                i++; continue
            }
            if (in_string) {
                if (c == "\\") { line = line c substr($0, i+1, 1); i += 2; continue }
                if (c == "\"") { in_string = 0 }
                line = line c; i++; continue
            }
            if (c2 == "//") break
            if (c2 == "/*") { in_block = 1; i += 2; continue }
            if (c == "\"")  { in_string = 1 }
            line = line c; i++
        }
        lines[NR] = line
    }
    END {
        for (i = 1; i <= NR; i++) {
            l = lines[i]
            # Remove trailing commas before closing } or ]
            if (match(l, /,[[:space:]]*$/)) {
                for (j = i + 1; j <= NR; j++) {
                    if (lines[j] ~ /^[[:space:]]*$/) continue
                    if (lines[j] ~ /^[[:space:]]*[}\]]/) sub(/,[[:space:]]*$/, "", l)
                    break
                }
            }
            print l
        }
    }
    ' "$file"
}

# ---------------------------------------------------------------------------
# _dc_read: print the parsed JSON of a devcontainer.json file on stdout.
# Strips JSONC comments first.  Returns 1 on parse failure.
# ---------------------------------------------------------------------------
_dc_read() {
    local dc_file="$1"
    [[ -f "$dc_file" ]] || return 1
    _strip_jsonc "$dc_file" | jq '.' 2>/dev/null
}

# ---------------------------------------------------------------------------
# _dc_modify: apply a jq filter to a devcontainer.json file in-place.
# Backs up the original if it contained comments.
# Usage: _dc_modify <dc_file> [jq-args...] <jq-filter>
# ---------------------------------------------------------------------------
_dc_modify() {
    local dc_file="$1"
    shift
    local tmp
    tmp=$(mktemp)

    # Back up when original contained comments
    if grep -qE '^\s*//' "$dc_file" 2>/dev/null; then
        cp "$dc_file" "${dc_file}.bak"
    fi

    if _strip_jsonc "$dc_file" | jq "$@" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$dc_file"
    else
        rm -f "$tmp"
        echo "Error: failed to modify $dc_file" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# _dc_has_mount: return 0 if any mount in dc_file matches the given pattern.
# Usage: _dc_has_mount <dc_file> <regex-pattern>
# ---------------------------------------------------------------------------
_dc_has_mount() {
    local dc_file="$1" pattern="$2"
    [[ -f "$dc_file" ]] || return 1
    _strip_jsonc "$dc_file" | jq -e --arg pat "$pattern" \
        '(.mounts // []) | any(tostring | test($pat))' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# _dc_has_all_mounts: return 0 if mounts exist for ALL dirs of an agent.
# Checks each directory in AGENT_DIRS[agent] (colon-separated).
# Usage: _dc_has_all_mounts <dc_file> <agent_id>
# ---------------------------------------------------------------------------
_dc_has_all_mounts() {
    local dc_file="$1" agent="$2"
    local dir
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        _dc_has_mount "$dc_file" "$dir" || return 1
    done < <(get_agent_dirs "$agent")
    return 0
}

# ---------------------------------------------------------------------------
# _dc_add_agent_mounts: add bind-mount entries for an agent to dc_file.
# Skips mounts that already exist.
# Usage: _dc_add_agent_mounts <dc_file> <agent_id>
# ---------------------------------------------------------------------------
_dc_add_agent_mounts() {
    local dc_file="$1" agent="$2"
    local dir mount_str
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        if ! _dc_has_mount "$dc_file" "$dir"; then
            mount_str="source=\${localEnv:HOME}/${dir},target=/root/${dir},type=bind"
            _dc_modify "$dc_file" --arg m "$mount_str" \
                '.mounts = ((.mounts // []) + [$m])'
        fi
    done < <(get_agent_dirs "$agent")
}

# ---------------------------------------------------------------------------
# _dc_get_init_cmd: print the initializeCommand value as JSON, or empty.
# ---------------------------------------------------------------------------
_dc_get_init_cmd() {
    local dc_file="$1"
    _strip_jsonc "$dc_file" | jq -r \
        'if .initializeCommand then .initializeCommand | tojson else empty end' 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _dc_set_init_cmd: set initializeCommand to ["bash", ".devcontainer/initialize.sh"].
# ---------------------------------------------------------------------------
_dc_set_init_cmd() {
    local dc_file="$1"
    _dc_modify "$dc_file" '.initializeCommand = ["bash", ".devcontainer/initialize.sh"]'
}

# ---------------------------------------------------------------------------
# _dc_get_post_create_cmd: print the postCreateCommand value as a string,
# or empty if absent.
# ---------------------------------------------------------------------------
_dc_get_post_create_cmd() {
    local dc_file="$1"
    _strip_jsonc "$dc_file" | jq -r \
        'if .postCreateCommand then .postCreateCommand | if type == "array" then join(" ") else . end else empty end' \
        2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _dc_has_post_create_script: return 0 if postCreateCommand references
# postCreate.sh.
# ---------------------------------------------------------------------------
_dc_has_post_create_script() {
    local dc_file="$1"
    local cmd
    cmd=$(_dc_get_post_create_cmd "$dc_file")
    [[ "$cmd" == *"postCreate.sh"* ]]
}

# ---------------------------------------------------------------------------
# _dc_set_post_create_cmd: set postCreateCommand to
# "bash .devcontainer/postCreate.sh".
# ---------------------------------------------------------------------------
_dc_set_post_create_cmd() {
    local dc_file="$1"
    _dc_modify "$dc_file" '.postCreateCommand = "bash .devcontainer/postCreate.sh"'
}

# ---------------------------------------------------------------------------
# _dc_has_env_file_run_arg: return 0 if runArgs contains an --env-file entry
# pointing to .devcontainer/.env.
# ---------------------------------------------------------------------------
_dc_has_env_file_run_arg() {
    local dc_file="$1"
    _strip_jsonc "$dc_file" | jq -e \
        '(.runArgs // []) | any(tostring | test("\\.devcontainer/\\.env"))' \
        >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# _dc_add_env_file_run_arg: append the --env-file runArg to dc_file.
# Idempotent: skips the addition if the entry already exists.
# ---------------------------------------------------------------------------
_dc_add_env_file_run_arg() {
    local dc_file="$1"
    _dc_has_env_file_run_arg "$dc_file" && return 0
    _dc_modify "$dc_file" \
        '.runArgs = ((.runArgs // []) + ["--env-file=${localWorkspaceFolder}/.devcontainer/.env"])'
}

# ---------------------------------------------------------------------------
# _dc_has_name: return 0 if the "name" field is present and non-empty.
# ---------------------------------------------------------------------------
_dc_has_name() {
    local dc_file="$1"
    [[ -f "$dc_file" ]] || return 1
    _strip_jsonc "$dc_file" | jq -e \
        '.name and (.name | length > 0)' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# _dc_get_name: print the "name" field value. Returns 1 if absent.
# ---------------------------------------------------------------------------
_dc_get_name() {
    local dc_file="$1"
    [[ -f "$dc_file" ]] || return 1
    local name
    name=$(_strip_jsonc "$dc_file" | jq -r '.name // empty' 2>/dev/null)
    if [[ -n "$name" ]]; then
        printf '%s' "$name"
    else
        return 1
    fi
}

# ---------------------------------------------------------------------------
# _dc_set_name: set the "name" field, placing it first in the object.
# ---------------------------------------------------------------------------
_dc_set_name() {
    local dc_file="$1" name="$2"
    _dc_modify "$dc_file" --arg n "$name" \
        '{name: $n} + (del(.name))'
}

# ---------------------------------------------------------------------------
# _dc_get_image: print the "image" field value. Returns 1 if absent.
# ---------------------------------------------------------------------------
_dc_get_image() {
    local dc_file="$1"
    [[ -f "$dc_file" ]] || return 1
    local img
    img=$(_strip_jsonc "$dc_file" | jq -r '.image // empty' 2>/dev/null)
    if [[ -n "$img" ]]; then
        printf '%s' "$img"
    else
        return 1
    fi
}
