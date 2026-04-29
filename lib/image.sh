# Image freshness checks: upstream digest comparison and staleness warning.
#
# Depends on: utils.sh (resolve_dc_file), devcontainer_json.sh (_dc_get_image).
# Timestamps cached under ~/.cache/dev-ai/pull-timestamps/ (XDG_CACHE_HOME aware).

# ---------------------------------------------------------------------------
# pull_base_image: pull the base image from the registry to refresh the
# local cache.  A plain rebuild reuses the cached image and will NOT pick up
# a newer base — always call this first when a fresh pull is needed.
# ---------------------------------------------------------------------------
pull_base_image() {
    local dc_file
    dc_file=$(resolve_dc_file) || return 1

    local image_name
    image_name=$(_dc_get_image "$dc_file" 2>/dev/null) || return 1
    [[ -n "$image_name" ]] || return 1

    echo "Pulling fresh base image: $image_name"
    "$containerBin" pull "$image_name" && _record_verified_timestamp "$image_name"
}

# ---------------------------------------------------------------------------
# _pull_timestamp_file: return the pull-timestamp cache file path for an
# image.  Keyed by sha256(containerBin:image_name) to avoid collisions
# across images and container engines.  Returns 1 with no output when no
# suitable cache directory is available.
# ---------------------------------------------------------------------------
_pull_timestamp_file() {
    local image_name="$1"
    local cache_dir
    if [[ -n "${XDG_CACHE_HOME:-}" ]]; then
        cache_dir="${XDG_CACHE_HOME}/dev-ai/pull-timestamps"
    elif [[ -n "${HOME:-}" ]]; then
        cache_dir="${HOME}/.cache/dev-ai/pull-timestamps"
    else
        return 1
    fi
    local key_hash
    key_hash=$(printf '%s' "${containerBin:-docker}:${image_name}" \
        | sha256sum 2>/dev/null | cut -c1-32) || return 1
    [[ -n "$key_hash" ]] || return 1
    printf '%s/%s' "$cache_dir" "$key_hash"
}

# ---------------------------------------------------------------------------
# _record_verified_timestamp: write the current epoch to the cache file for
# image_name.  Called after a confirmed-fresh pull OR a matching digest check
# so that check_image_staleness suppresses repeat warnings within the window.
# ---------------------------------------------------------------------------
_record_verified_timestamp() {
    local image_name="$1"
    local ts_file
    ts_file=$(_pull_timestamp_file "$image_name") || return 0
    mkdir -p "$(dirname "$ts_file")" 2>/dev/null || return 0
    date +%s > "$ts_file" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _prompt_pull_and_rebuild: shared yes/no prompt for both freshness checks.
# Pulls the base image and rebuilds on 'y'; continues on 'n'.
# ---------------------------------------------------------------------------
_prompt_pull_and_rebuild() {
    local prompt_text="$1"
    local choice
    while true; do
        printf "  %s [y/N]: " "$prompt_text"
        read -r choice
        choice="${choice:-N}"
        case "$choice" in
            [Yy]) pull_base_image && rebuild_devcontainer; return 0 ;;
            [Nn]) echo "  Continuing with existing image."; return 0 ;;
            *) printf "  Please enter y or n.\n" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# _parse_image_ref: split a fully-qualified image reference into
# registry / repository / tag, applying Docker Hub defaults.  Writes three
# lines to stdout in that order so the caller can read them with mapfile or
# a `read` loop.  Returns 1 on parse failure.
#
# Examples:
#   mcr.microsoft.com/devcontainers/base:ubuntu
#     -> mcr.microsoft.com / devcontainers/base / ubuntu
#   ubuntu:22.04
#     -> registry-1.docker.io / library/ubuntu / 22.04
#   ghcr.io/owner/repo
#     -> ghcr.io / owner/repo / latest
# ---------------------------------------------------------------------------
_parse_image_ref() {
    local ref="$1"
    [[ -n "$ref" ]] || return 1

    # Strip any pinned digest (`@sha256:...`) — we resolve the tag fresh.
    ref="${ref%@*}"

    local registry rest
    local first="${ref%%/*}"
    if [[ "$ref" == */* ]] && \
       [[ "$first" == *.* || "$first" == *:* || "$first" == "localhost" ]]; then
        registry="$first"
        rest="${ref#*/}"
    else
        registry="registry-1.docker.io"
        rest="$ref"
        [[ "$rest" != */* ]] && rest="library/$rest"
    fi

    local repo tag
    # Tag separator is the LAST ':' in the remaining path component.
    if [[ "$rest" == *:* ]] && [[ "${rest##*/}" == *:* ]]; then
        repo="${rest%:*}"
        tag="${rest##*:}"
    else
        repo="$rest"
        tag="latest"
    fi

    printf '%s\n%s\n%s\n' "$registry" "$repo" "$tag"
}

# ---------------------------------------------------------------------------
# _fetch_upstream_image_digest: return the digest of the manifest document
# the upstream tag currently resolves to.
#
# This is the digest recorded in `RepoDigests` after `docker pull <tag>`.
# For multi-arch images it is the manifest-list (image index) digest, not a
# per-platform sub-manifest digest — so comparing it against the local
# RepoDigest yields a true equality check.
#
# Strategy (first success wins):
#   1. HTTP HEAD against the registry; read `Docker-Content-Digest`.
#      Handles Bearer-token auth via the WWW-Authenticate challenge.
#   2. `skopeo inspect --raw` → sha256sum of the raw manifest bytes.
#   3. `docker buildx imagetools inspect --raw` → sha256sum of the bytes.
#
# Outputs the digest (e.g. `sha256:abc...`) to stdout, or returns 1.
# ---------------------------------------------------------------------------
_fetch_upstream_image_digest() {
    local image_name="$1"
    [[ -n "$image_name" ]] || return 1

    # ---- Strategy 1: registry HEAD via curl ----
    if command -v curl >/dev/null 2>&1; then
        local parsed registry repo tag
        parsed=$(_parse_image_ref "$image_name") || parsed=""
        if [[ -n "$parsed" ]]; then
            { IFS= read -r registry; IFS= read -r repo; IFS= read -r tag; } <<<"$parsed"
            local url="https://${registry}/v2/${repo}/manifests/${tag}"
            local accept="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"

            local headers status
            headers=$(curl -sSI --max-time 10 -H "Accept: ${accept}" "$url" 2>/dev/null || true)
            status=$(printf '%s' "$headers" | head -1 | awk '{print $2}')

            # If the registry demands auth, honour the Bearer challenge.
            if [[ "$status" == "401" ]]; then
                local www_auth realm service scope token token_resp
                www_auth=$(printf '%s' "$headers" | grep -i '^www-authenticate:' | head -1 | tr -d '\r')
                realm=$(printf '%s' "$www_auth"   | grep -o 'realm="[^"]*"'   | head -1 | sed 's/realm="//;s/"$//')
                service=$(printf '%s' "$www_auth" | grep -o 'service="[^"]*"' | head -1 | sed 's/service="//;s/"$//')
                scope=$(printf '%s' "$www_auth"   | grep -o 'scope="[^"]*"'   | head -1 | sed 's/scope="//;s/"$//')
                [[ -z "$scope" ]] && scope="repository:${repo}:pull"

                if [[ -n "$realm" ]]; then
                    local auth_url="${realm}?service=${service}&scope=${scope}"
                    token_resp=$(curl -sS --max-time 10 "$auth_url" 2>/dev/null || true)
                    token=$(printf '%s' "$token_resp" \
                        | grep -o '"\(access_token\|token\)"[[:space:]]*:[[:space:]]*"[^"]*"' \
                        | head -1 \
                        | sed 's/.*"\([^"]*\)"$/\1/')
                    if [[ -n "$token" ]]; then
                        headers=$(curl -sSI --max-time 10 \
                            -H "Authorization: Bearer $token" \
                            -H "Accept: ${accept}" \
                            "$url" 2>/dev/null || true)
                    fi
                fi
            fi

            local digest
            digest=$(printf '%s' "$headers" \
                | grep -i '^docker-content-digest:' \
                | head -1 \
                | grep -o 'sha256:[0-9a-f]\{64\}')
            if [[ -n "$digest" ]]; then
                printf '%s\n' "$digest"
                return 0
            fi
        fi
    fi

    # ---- Strategy 2: skopeo (compute hash of raw manifest bytes) ----
    if command -v skopeo >/dev/null 2>&1 && command -v sha256sum >/dev/null 2>&1; then
        local raw_hash
        raw_hash=$(skopeo inspect --raw "docker://${image_name}" 2>/dev/null \
            | sha256sum 2>/dev/null \
            | awk '{print $1}')
        if [[ "$raw_hash" =~ ^[0-9a-f]{64}$ ]]; then
            printf 'sha256:%s\n' "$raw_hash"
            return 0
        fi
    fi

    # ---- Strategy 3: docker buildx imagetools (raw manifest bytes) ----
    if command -v sha256sum >/dev/null 2>&1 \
       && "${containerBin:-docker}" buildx version >/dev/null 2>&1; then
        local raw_hash
        raw_hash=$("${containerBin:-docker}" buildx imagetools inspect --raw "$image_name" 2>/dev/null \
            | sha256sum 2>/dev/null \
            | awk '{print $1}')
        if [[ "$raw_hash" =~ ^[0-9a-f]{64}$ ]]; then
            printf 'sha256:%s\n' "$raw_hash"
            return 0
        fi
    fi

    return 1
}

# ---------------------------------------------------------------------------
# check_upstream_image_changed: warn if the upstream registry image has a
# newer digest than the locally cached image.  This catches base-image
# rebuilds (OS patches, CVE fixes) even when the tag name hasn't changed.
#
# Strategy:
#   1. Read the image name from devcontainer.json.
#   2. Get the digest(s) from the local image (RepoDigests).
#   3. Fetch the upstream manifest digest via _fetch_upstream_image_digest
#      (registry HTTP, skopeo, or buildx imagetools).
#   4. Compare — if they differ, warn and offer to rebuild.
#
# The check is best-effort: network errors or unsupported registries are
# silently skipped so they never block a normal boot.
# ---------------------------------------------------------------------------
check_upstream_image_changed() {
    local dc_file
    dc_file=$(resolve_dc_file) || return 0

    local image_name
    image_name=$(_dc_get_image "$dc_file" 2>/dev/null) || return 0
    [[ -n "$image_name" ]] || return 0

    # Skip if the image is not present locally (first run)
    "$containerBin" image inspect "$image_name" >/dev/null 2>&1 || return 0

    # ---- Step 1: collect local repo-digests ----
    local local_digests_raw
    local_digests_raw=$("$containerBin" image inspect \
        --format '{{range .RepoDigests}}{{println .}}{{end}}' \
        "$image_name" 2>/dev/null || true)

    local local_digests=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local digest_part="${line##*@}"
        [[ "$digest_part" =~ ^sha256:[0-9a-f]{64}$ ]] && local_digests+=("$digest_part")
    done <<< "$local_digests_raw"

    # ---- Step 2: fetch the upstream digest ----
    #
    # IMPORTANT: For multi-arch images the registry tag points to a manifest
    # list (image index).  The digest stored in the local RepoDigests is the
    # *index* digest, NOT any per-platform sub-manifest digest.
    #
    # `<engine> manifest inspect <tag>` prints the parsed index JSON whose
    # `manifests[*].digest` entries are per-platform digests — comparing those
    # to the local RepoDigest will never match and produces a false-positive
    # warning on every run.  We must obtain the digest of the manifest
    # document itself, which the registry returns in the `Docker-Content-Digest`
    # response header (preferred) or which we can compute as sha256 of the
    # raw manifest bytes (fallback).
    local upstream_digest=""
    upstream_digest=$(_fetch_upstream_image_digest "$image_name" 2>/dev/null || true)

    [[ -n "$upstream_digest" ]] || return 0

    # ---- Step 3: compare ----
    local found=false d
    for d in "${local_digests[@]}"; do
        [[ "$d" == "$upstream_digest" ]] && { found=true; break; }
    done

    if $found; then
        # Digests match — image is confirmed current; reset the verified timestamp.
        _record_verified_timestamp "$image_name"
        return 0
    fi

    local _red='\033[0;31m' _bold='\033[1m' _yellow='\033[0;33m' _reset='\033[0m'
    printf "\n"
    if (( ${#local_digests[@]} == 0 )); then
        printf "${_yellow}${_bold}Security notice: upstream base image '%s' cannot be verified.${_reset}\n" \
            "$image_name"
        printf "${_yellow}  No pull digest recorded — image may have been built locally.${_reset}\n"
        printf "${_yellow}  Upstream digest : %s${_reset}\n" "$upstream_digest"
    else
        printf "${_red}${_bold}Security warning: upstream image '%s' has changed.${_reset}\n" \
            "$image_name"
        printf "${_red}  Local digest    : %s${_reset}\n" "${local_digests[0]}"
        printf "${_red}  Upstream digest : %s${_reset}\n" "$upstream_digest"
        printf "${_red}  The base image may have been updated (new OS patches or a new tag).${_reset}\n"
    fi
    printf "\n"

    _prompt_pull_and_rebuild "Pull fresh image and rebuild?"
}


# ---------------------------------------------------------------------------
# check_image_staleness: warn if the locally cached image is older than a
# configurable threshold (default: 7 days).  Set STALE_IMAGE_DAYS to override.
# ---------------------------------------------------------------------------
check_image_staleness() {
    local stale_threshold=${STALE_IMAGE_DAYS:-7}

    local dc_file
    dc_file=$(resolve_dc_file) || return 0

    local image_name
    image_name=$(_dc_get_image "$dc_file" 2>/dev/null) || return 0
    [[ -n "$image_name" ]] || return 0

    "$containerBin" image inspect "$image_name" >/dev/null 2>&1 || return 0

    local now_epoch
    now_epoch=$(date +%s)

    # If the image was verified fresh within the threshold window, skip.
    local _ts_file _last_verified _verified_age_days
    _ts_file=$(_pull_timestamp_file "$image_name") || true
    if [[ -n "${_ts_file:-}" && -f "$_ts_file" ]]; then
        _last_verified=$(cat "$_ts_file" 2>/dev/null || true)
        if [[ "$_last_verified" =~ ^[0-9]+$ ]]; then
            _verified_age_days=$(( (now_epoch - _last_verified) / 86400 ))
            (( _verified_age_days <= stale_threshold )) && return 0
        fi
    fi

    # No recent verification — fall back to image creation date as a proxy.
    local age_days
    if [[ -n "${_verified_age_days:-}" ]]; then
        age_days=$_verified_age_days
    else
        local created_epoch
        created_epoch=$("$containerBin" image inspect \
            --format '{{.Created.Unix}}' "$image_name" 2>/dev/null || true)
        if ! [[ "$created_epoch" =~ ^[0-9]+$ ]]; then
            local created_str
            created_str=$("$containerBin" image inspect \
                --format '{{.Created}}' "$image_name" 2>/dev/null || true)
            [[ -n "$created_str" ]] || return 0
            created_epoch=$(date -d "$created_str" +%s 2>/dev/null || true)
        fi
        [[ "$created_epoch" =~ ^[0-9]+$ ]] || return 0
        age_days=$(( (now_epoch - created_epoch) / 86400 ))
    fi

    if (( age_days > stale_threshold )); then
        local _age_label
        if [[ -n "${_verified_age_days:-}" ]]; then
            _age_label="last verified ${age_days} day(s) ago"
        else
            _age_label="built ${age_days} day(s) ago, no pull record found"
        fi
        local _red='\033[0;31m' _bold='\033[1m' _reset='\033[0m'
        printf "\n"
        printf "${_red}${_bold}Warning: upstream base image '%s' may be outdated (%s).${_reset}\n" \
            "$image_name" "$_age_label"
        printf "${_red}  The upstream registry image may have been updated with new OS patches or security fixes${_reset}\n"
        printf "${_red}  since your local copy was last verified. A plain rebuild reuses the cached image —${_reset}\n"
        printf "${_red}  run: dev-ai -b -f  (or answer y below) to pull the latest upstream version.${_reset}\n"
        printf "\n"

        _prompt_pull_and_rebuild "Force-pull and rebuild?"
    fi
}
