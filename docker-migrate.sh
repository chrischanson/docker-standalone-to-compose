#!/usr/bin/env bash
#
# docker-migrate.sh — Generate a docker-compose.yml from running Docker containers.
#
# Inspects standalone Docker containers and produces a Compose file that
# preserves all runtime configuration: volumes, ports, environment variables,
# networks, restart policies, capabilities, devices, and more.
#
# Containers already managed by Docker Compose are skipped by default.
#
# Usage:
#   docker-migrate.sh                          Dry run: preview to stdout
#   docker-migrate.sh --write                  Write docker-compose.yml
#   docker-migrate.sh --write -o my-stack.yml  Custom output filename
#   docker-migrate.sh -a                       Include stopped containers
#   docker-migrate.sh --include-compose        Also include compose-managed containers
#   docker-migrate.sh -c mycontainer           Migrate a single container by name
#   docker-migrate.sh --env-include-all        Include all env vars (even image defaults)
#   docker-migrate.sh --pull                   Pull missing images (caution: may get newer defaults)
#
# Prerequisites: docker, jq
#

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────

OUTPUT="docker-compose.yml"
INCLUDE_ALL=false
INCLUDE_COMPOSE_MANAGED=false
WRITE=false
CONTAINER_FILTER=""
ENV_INCLUDE_ALL=false
PULL_IMAGES=false

# ─── Colors (only when outputting to a terminal) ────────────────────────────

if [[ -t 2 ]]; then
    GREEN='\033[0;32m'  YELLOW='\033[0;33m'  CYAN='\033[0;36m'
    RED='\033[0;31m'    BOLD='\033[1m'        DIM='\033[2m'
    RESET='\033[0m'
else
    GREEN=""  YELLOW=""  CYAN=""  RED=""  BOLD=""  DIM=""  RESET=""
fi

info()   { printf "${GREEN}✓${RESET} %s\n" "$1" >&2; }
warn()   { printf "${YELLOW}⚠${RESET} %s\n" "$1" >&2; }
err()    { printf "${RED}✗${RESET} %s\n" "$1" >&2; }
header() { printf "\n${BOLD}${CYAN}%s${RESET}\n" "$1" >&2; }
dim()    { printf "${DIM}  %s${RESET}\n" "$1" >&2; }

# ─── Argument parsing ────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output)          OUTPUT="$2"; shift 2 ;;
        -a|--all)             INCLUDE_ALL=true; shift ;;
        -c|--container)       CONTAINER_FILTER="$2"; shift 2 ;;
        --include-compose)    INCLUDE_COMPOSE_MANAGED=true; shift ;;
        --env-include-all)    ENV_INCLUDE_ALL=true; shift ;;
        --pull)               PULL_IMAGES=true; shift ;;
        --write)              WRITE=true; shift ;;
        -h|--help)
            sed -n '/^#/!q;s/^# \{0,1\}//p' "$0" | tail -n +2
            exit 0
            ;;
        *)
            err "Unknown option: $1"
            echo "Run with -h for usage." >&2
            exit 1
            ;;
    esac
done

# ─── Prerequisites ───────────────────────────────────────────────────────────

if ! command -v jq &>/dev/null; then
    err "jq is required but not installed."
    echo "  Install: sudo apt-get install jq" >&2
    exit 1
fi

if ! docker info &>/dev/null; then
    err "Cannot connect to Docker daemon."
    exit 1
fi

# ─── Discover containers ─────────────────────────────────────────────────────

if [[ -n "$CONTAINER_FILTER" ]]; then
    # Single container mode — look up by name
    FILTER_ID=$(docker ps --filter "name=^${CONTAINER_FILTER}$" --format '{{.ID}}' 2>/dev/null || true)
    if [[ -z "$FILTER_ID" ]]; then
        # Also try stopped containers when a specific name is given
        FILTER_ID=$(docker ps -a --filter "name=^${CONTAINER_FILTER}$" --format '{{.ID}}' 2>/dev/null || true)
    fi
    if [[ -z "$FILTER_ID" ]]; then
        err "Container '${CONTAINER_FILTER}' not found."
        exit 1
    fi
    CONTAINER_IDS=("$FILTER_ID")
else
    PS_FLAGS=(--format '{{.ID}}')
    [[ "$INCLUDE_ALL" == "true" ]] && PS_FLAGS=(-a "${PS_FLAGS[@]}")
    mapfile -t CONTAINER_IDS < <(docker ps "${PS_FLAGS[@]}")
fi

if [[ ${#CONTAINER_IDS[@]} -eq 0 ]]; then
    info "No containers found."
    exit 0
fi

header "Docker → Compose Migration"
echo "Found ${#CONTAINER_IDS[@]} container(s). Inspecting..." >&2

# ─── Temporary file & accumulators ───────────────────────────────────────────

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

declare -A NAMED_VOLUMES=()   # volume_name → 1
declare -A EXT_NETWORKS=()    # network_name → 1
declare -A IMAGE_CACHE=()     # image → inspect JSON
MIGRATED=0
SKIPPED=0

# Single-quote char in a variable — avoids the bash parser bug where
# '${var//'/''}'  inside double-quotes corrupts the parse tree.
_SQ="'"

# Write a line to the services section of our temp file
yml() { printf '%s\n' "$1" >> "$TMPFILE"; }

# Cache image inspections (multiple containers may share an image).
#
# IMPORTANT: We compare the container's config against the image it was
# ORIGINALLY BUILT FROM (identified by SHA from .[0].Image), not the latest
# tag. If we pulled the newest image, its defaults might differ from the
# version that created the container, causing every field to look "custom."
#
# Lookup order:
#   1. Image SHA embedded in the container (exact match)
#   2. Image tag/name (works if tag still points to the same version)
#   3. Pull from registry (only with --pull; WARNING: may get newer defaults)
get_image_json() {
    local img_tag="$1"       # e.g. qmcgaw/ddns-updater
    local img_sha="${2:-}"   # e.g. sha256:abc123... (from container inspect)

    # Use a combined cache key so SHA and tag hits share the cache
    local cache_key="${img_sha:-$img_tag}"
    if [[ -n "${IMAGE_CACHE[$cache_key]+x}" ]]; then
        echo "${IMAGE_CACHE[$cache_key]}"
        return
    fi

    local result="[]"

    # 1. Try the exact SHA the container was built from
    if [[ -n "$img_sha" ]]; then
        result=$(docker image inspect "$img_sha" 2>/dev/null || echo "[]")
        if [[ "$result" != "[]" && -n "$result" ]]; then
            dim "Image comparison: using original image SHA for ${img_tag}"
        fi
    fi

    # 2. Fall back to tag (same version if tag hasn't been updated)
    if [[ "$result" == "[]" || -z "$result" ]]; then
        result=$(docker image inspect "$img_tag" 2>/dev/null || echo "[]")
    fi

    # 3. Optionally pull (--pull flag) — WARNING: this may get a newer image
    if [[ ("$result" == "[]" || -z "$result") && "$PULL_IMAGES" == "true" ]]; then
        warn "  Image '${img_tag}' not available locally — pulling for metadata..."
        warn "  ⚠ This fetches the LATEST image — defaults may differ from your container's version."
        if docker pull "$img_tag" &>/dev/null; then
            result=$(docker image inspect "$img_tag" 2>/dev/null || echo "[]")
            info "  Pulled '${img_tag}' — image-default filtering enabled (latest version)."
        else
            warn "  Failed to pull '${img_tag}' — image-default filtering disabled."
            result="[]"
        fi
    fi

    IMAGE_CACHE["$cache_key"]="$result"
    echo "$result"
}

# ─── Generate service entries ────────────────────────────────────────────────

for cid in "${CONTAINER_IDS[@]}"; do
    JSON=$(docker inspect "$cid")

    NAME=$(echo "$JSON" | jq -r '.[0].Name | ltrimstr("/")')
    IMAGE=$(echo "$JSON" | jq -r '.[0].Config.Image')

    # Skip containers already managed by docker compose
    COMPOSE_PROJECT=$(echo "$JSON" | jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty')
    if [[ -n "$COMPOSE_PROJECT" && "$INCLUDE_COMPOSE_MANAGED" != "true" ]]; then
        warn "Skipping ${NAME} (compose project: ${COMPOSE_PROJECT})"
        (( ++SKIPPED ))
        continue
    fi

    # The SHA of the image this container was originally built from.
    # This is critical — we MUST compare against THIS version's defaults,
    # not whatever the latest tag points to.
    IMG_SHA=$(echo "$JSON" | jq -r '.[0].Image // empty')

    info "Migrating: ${NAME} (${IMAGE})"

    IMG_JSON=$(get_image_json "$IMAGE" "$IMG_SHA")

    # Warn when image inspect fails — env vars, entrypoint, user, workdir
    # filtering will be skipped (we can't diff against image defaults).
    IMG_INSPECT_OK=true
    if [[ "$IMG_JSON" == "[]" || -z "$IMG_JSON" ]]; then
        warn "  Could not inspect image '${IMAGE}' locally — image-default filtering disabled for ${NAME}."
        warn "  Pull the image first (docker pull ${IMAGE}) for cleaner output."
        IMG_INSPECT_OK=false
    fi

    # Service key: sanitize container name for a compose service identifier
    SERVICE=$(echo "$NAME" | sed 's/[^a-zA-Z0-9_-]/_/g')

    yml "  ${SERVICE}:"
    yml "    image: ${IMAGE}"
    yml "    container_name: ${NAME}"
    [[ "$IMG_INSPECT_OK" == "false" ]] && yml "    # WARNING: image inspect failed — env/entrypoint/user/workdir may include image defaults. Run: docker pull ${IMAGE}"

    # ── Hostname ──────────────────────────────────────────────────────────
    # Docker sets hostname to the short container ID by default — skip it.
    # Use a regex against the Docker short-ID pattern (12 lowercase hex chars)
    # rather than comparing with \${cid:0:12}, which breaks when docker ps
    # returns the full 64-char ID on some Docker versions/platforms.
    HOSTNAME_VAL=$(echo "$JSON" | jq -r '.[0].Config.Hostname // empty')
    if [[ -n "$HOSTNAME_VAL" && ! "$HOSTNAME_VAL" =~ ^[0-9a-f]{12}$ ]]; then
        yml "    hostname: ${HOSTNAME_VAL}"
    fi

    # ── Domainname ────────────────────────────────────────────────────────
    DOMAINNAME=$(echo "$JSON" | jq -r '.[0].Config.Domainname // empty')
    if [[ -n "$DOMAINNAME" ]]; then
        yml "    domainname: ${DOMAINNAME}"
    fi

    # ── Restart policy ────────────────────────────────────────────────────
    RESTART=$(echo "$JSON" | jq -r '.[0].HostConfig.RestartPolicy.Name // "no"')
    if [[ -n "$RESTART" && "$RESTART" != "no" ]]; then
        MAX_RETRY=$(echo "$JSON" | jq -r '.[0].HostConfig.RestartPolicy.MaximumRetryCount // 0')
        if [[ "$RESTART" == "on-failure" && "$MAX_RETRY" -gt 0 ]]; then
            yml "    restart: \"on-failure:${MAX_RETRY}\""
        else
            yml "    restart: ${RESTART}"
        fi
    fi

    # ── Pre-scan command for misplaced docker-run flags ─────────────────
    # Detect flags like -e KEY=VAL that were accidentally passed as command
    # args (after the image name) instead of as Docker options. Extract env
    # vars now so they can be merged into the environment section below.
    CMD=$(echo  "$JSON"     | jq -c '.[0].Config.Cmd // null')
    IMG_CMD=$(echo "$IMG_JSON" | jq -c '.[0].Config.Cmd // null' 2>/dev/null || echo "null")
    CMD_RESCUED_ENVS=()
    CLEANED_CMD=""        # set to the cleaned JSON array if flags were found
    CMD_HAS_MISPLACED_FLAGS=false

    if [[ "$CMD" != "null" && "$CMD" != "$IMG_CMD" ]]; then
        if echo "$CMD" | jq -e 'arrays | map(select(test("^-[epv]$|^--env$|^--volume$|^--publish$"))) | length > 0' &>/dev/null; then
            CMD_HAS_MISPLACED_FLAGS=true
            warn "  Container ${NAME}: command contains misplaced docker run flags — extracting env vars."

            REAL_CMD_ARGS=()
            SKIP_NEXT=false
            mapfile -t CMD_PARTS < <(echo "$CMD" | jq -r '.[]')
            for ((i=0; i<${#CMD_PARTS[@]}; i++)); do
                if [[ "$SKIP_NEXT" == "true" ]]; then
                    SKIP_NEXT=false
                    continue
                fi
                arg="${CMD_PARTS[$i]}"
                case "$arg" in
                    -e|--env)
                        if [[ $((i+1)) -lt ${#CMD_PARTS[@]} ]]; then
                            CMD_RESCUED_ENVS+=("${CMD_PARTS[$((i+1))]}")
                            SKIP_NEXT=true
                        fi
                        ;;
                    -v|--volume|-p|--publish)
                        # Can't auto-fix volume/port flags; leave a warning comment
                        # (emitted later in the command section)
                        SKIP_NEXT=true
                        ;;
                    *)
                        REAL_CMD_ARGS+=("$arg")
                        ;;
                esac
            done

            if [[ ${#REAL_CMD_ARGS[@]} -gt 0 ]]; then
                CLEANED_CMD=$(printf '%s\n' "${REAL_CMD_ARGS[@]}" | jq -R . | jq -sc .)
            fi
        fi
    fi

    # ── Environment (runtime-only — image defaults are inherited) ─────────
    # With --env-include-all, emit every env var from the container.
    # Otherwise, diff against the image defaults and skip Docker-injected vars.
    # Rescued env vars from misplaced command flags are appended at the end.
    if [[ "$ENV_INCLUDE_ALL" == "true" ]]; then
        ALL_ENVS=()
        while IFS= read -r env_line; do
            [[ -z "$env_line" ]] && continue
            key="${env_line%%=*}"
            # Always skip HOSTNAME — auto-injected by Docker, never meaningful in compose
            [[ "$key" == "HOSTNAME" ]] && continue
            ALL_ENVS+=("$env_line")
        done < <(echo "$JSON" | jq -r '.[0].Config.Env // [] | .[]')

        # Merge rescued env vars from misplaced command flags
        for renv in "${CMD_RESCUED_ENVS[@]+"${CMD_RESCUED_ENVS[@]}"}"; do
            ALL_ENVS+=("$renv")
        done

        if [[ ${#ALL_ENVS[@]} -gt 0 ]]; then
            yml "    environment:"
            if [[ ${#CMD_RESCUED_ENVS[@]} -gt 0 ]]; then
                yml "      # NOTE: env vars marked [rescued] were extracted from misplaced command-line flags."
            fi
            for env in "${ALL_ENVS[@]}"; do
                # Single-quote ' -> '' and escape compose variables $ -> $$
                escaped="${env//$_SQ/$_SQ$_SQ}"
                escaped="${escaped//\$/\$\$}"
                yml "      - '${escaped}'"
            done
        fi
    else
        declare -A IMG_ENV_MAP=()
        while IFS= read -r env_line; do
            [[ -z "$env_line" ]] && continue
            key="${env_line%%=*}"
            IMG_ENV_MAP["$key"]="$env_line"
        done < <(echo "$IMG_JSON" | jq -r '.[0].Config.Env // [] | .[]' 2>/dev/null)

        RUNTIME_ENVS=()
        while IFS= read -r env_line; do
            [[ -z "$env_line" ]] && continue
            key="${env_line%%=*}"
            # Skip Docker-injected vars that are never meaningful in compose
            case "$key" in
                HOSTNAME) continue ;;  # auto-set by Docker daemon
                PATH)     continue ;;  # always an image default
            esac
            # Include only env vars added or modified at runtime
            if [[ -z "${IMG_ENV_MAP[$key]+x}" || "${IMG_ENV_MAP[$key]}" != "$env_line" ]]; then
                RUNTIME_ENVS+=("$env_line")
            fi
        done < <(echo "$JSON" | jq -r '.[0].Config.Env // [] | .[]')
        unset IMG_ENV_MAP

        # Merge rescued env vars from misplaced command flags
        for renv in "${CMD_RESCUED_ENVS[@]+"${CMD_RESCUED_ENVS[@]}"}"; do
            RUNTIME_ENVS+=("$renv")
        done

        if [[ ${#RUNTIME_ENVS[@]} -gt 0 ]]; then
            yml "    environment:"
            if [[ ${#CMD_RESCUED_ENVS[@]} -gt 0 ]]; then
                yml "      # NOTE: env vars below marked [rescued] were extracted from misplaced command-line flags."
                yml "      # The original container was launched incorrectly (flags placed after image name)."
            fi
            for env in "${RUNTIME_ENVS[@]}"; do
                # Single-quote ' -> '' and escape compose variables $ -> $$
                # (avoids the bash parser bug with single-quotes inside "${}")
                escaped="${env//$_SQ/$_SQ$_SQ}"
                escaped="${escaped//\$/\$\$}"
                yml "      - '${escaped}'"
            done
        fi
    fi

    # ── Ports ─────────────────────────────────────────────────────────────
    PORT_LINES=$(echo "$JSON" | jq -r '
        .[0].HostConfig.PortBindings // {} | to_entries[] |
        .key as $cp |
        ($cp | split("/")) as $parts |
        $parts[0] as $cport |
        ($parts[1] // "tcp") as $proto |
        (.value // [])[] |
        # Skip ephemeral port bindings (HostPort == "0" or empty)
        select(.HostPort != "" and .HostPort != "0") |
        (if .HostIp != "" and .HostIp != "0.0.0.0" and .HostIp != "::"
         then .HostIp + ":"
         else "" end) as $ip |
        $ip + .HostPort + ":" + $cport +
        (if $proto != "tcp" then "/" + $proto else "" end)
    ' 2>/dev/null || true)

    if [[ -n "$PORT_LINES" ]]; then
        yml "    ports:"
        while IFS= read -r port; do
            [[ -n "$port" ]] && yml "      - \"${port}\""
        done <<< "$PORT_LINES"
    fi

    # ── Volumes ───────────────────────────────────────────────────────────
    MOUNT_COUNT=$(echo "$JSON" | jq '.[0].Mounts | length')
    if [[ "$MOUNT_COUNT" -gt 0 ]]; then
        yml "    volumes:"
        while IFS= read -r mount_json; do
            TYPE=$(echo "$mount_json" | jq -r '.Type')
            SRC=$(echo  "$mount_json" | jq -r '.Source')
            DST=$(echo  "$mount_json" | jq -r '.Destination')
            RW=$(echo   "$mount_json" | jq -r '.RW')
            MODE=""
            [[ "$RW" == "false" ]] && MODE=":ro"

            case "$TYPE" in
                bind)
                    # Quote the whole string to handle paths with colons or special chars
                    yml "      - '${SRC}:${DST}${MODE}'"
                    ;;
                volume)
                    VOL_NAME=$(echo "$mount_json" | jq -r '.Name // empty')
                    if [[ -n "$VOL_NAME" ]]; then
                        # Anonymous volumes have 64-char hex names — preserve as named
                        # volumes so data isn't lost on recreate
                        if [[ ${#VOL_NAME} -eq 64 && "$VOL_NAME" =~ ^[0-9a-f]+$ ]]; then
                            yml "      - ${VOL_NAME}:${DST}${MODE}  # formerly anonymous volume"
                            NAMED_VOLUMES["$VOL_NAME"]=1
                        else
                            yml "      - ${VOL_NAME}:${DST}${MODE}"
                            NAMED_VOLUMES["$VOL_NAME"]=1
                        fi
                    else
                        yml "      - ${DST}"
                    fi
                    ;;
                # tmpfs mounts are handled separately below
            esac
        done < <(echo "$JSON" | jq -c '.[0].Mounts[]')
    fi

    # ── Tmpfs ─────────────────────────────────────────────────────────────
    TMPFS_LINES=$(echo "$JSON" | jq -r '
        .[0].HostConfig.Tmpfs // {} | to_entries[] |
        .key + (if .value != "" then ":" + .value else "" end)
    ' 2>/dev/null || true)
    if [[ -n "$TMPFS_LINES" ]]; then
        yml "    tmpfs:"
        while IFS= read -r t; do
            [[ -n "$t" ]] && yml "      - ${t}"
        done <<< "$TMPFS_LINES"
    fi

    # ── Network mode & Networks ───────────────────────────────────────────
    NET_MODE=$(echo "$JSON" | jq -r '.[0].HostConfig.NetworkMode // "default"')

    if [[ "$NET_MODE" == "host" || "$NET_MODE" == "none" ]]; then
        yml "    network_mode: ${NET_MODE}"
    elif [[ "$NET_MODE" =~ ^container: ]]; then
        # container:<name|id> → service:<service_name> in compose
        REF="${NET_MODE#container:}"
        REF_NAME=$(docker inspect --format '{{.Name}}' "$REF" 2>/dev/null \
                   | sed 's#^/##' || echo "$REF")
        REF_SVC=$(echo "$REF_NAME" | sed 's/[^a-zA-Z0-9_-]/_/g')
        yml "    network_mode: service:${REF_SVC}"
    else
        # Enumerate actual networks the container is attached to
        CUSTOM_NETS=()
        while IFS= read -r net; do
            [[ -z "$net" || "$net" == "bridge" ]] && continue
            CUSTOM_NETS+=("$net")
            EXT_NETWORKS["$net"]=1
        done < <(echo "$JSON" | jq -r '.[0].NetworkSettings.Networks // {} | keys[]')

        if [[ ${#CUSTOM_NETS[@]} -gt 0 ]]; then
            yml "    networks:"
            for net in "${CUSTOM_NETS[@]}"; do
                # Check for custom aliases (exclude auto-generated ones)
                ALIASES=$(echo "$JSON" | jq -r \
                    --arg net "$net" --arg name "$NAME" --arg cid12 "${cid:0:12}" '
                    .[0].NetworkSettings.Networks[$net].Aliases // [] |
                    map(select(
                        . != $name and
                        . != $cid12 and
                        (test("^[0-9a-f]{64}$") | not)
                    )) | .[]
                ' 2>/dev/null || true)

                # Check for static IP configuration
                IPV4_ADDR=$(echo "$JSON" | jq -r \
                    --arg net "$net" '.[0].NetworkSettings.Networks[$net].IPAMConfig.IPv4Address // empty' 2>/dev/null || true)
                IPV6_ADDR=$(echo "$JSON" | jq -r \
                    --arg net "$net" '.[0].NetworkSettings.Networks[$net].IPAMConfig.IPv6Address // empty' 2>/dev/null || true)

                if [[ -n "$ALIASES" || -n "$IPV4_ADDR" || -n "$IPV6_ADDR" ]]; then
                    yml "      ${net}:"
                    if [[ -n "$ALIASES" ]]; then
                        yml "        aliases:"
                        while IFS= read -r alias; do
                            [[ -n "$alias" ]] && yml "          - ${alias}"
                        done <<< "$ALIASES"
                    fi
                    if [[ -n "$IPV4_ADDR" ]]; then
                        yml "        ipv4_address: ${IPV4_ADDR}"
                    fi
                    if [[ -n "$IPV6_ADDR" ]]; then
                        yml "        ipv6_address: ${IPV6_ADDR}"
                    fi
                else
                    yml "      - ${net}"
                fi
            done
        fi
    fi

    # ── Labels (runtime-only — skip image labels & internal labels) ───────
    declare -A IMG_LABEL_MAP=()
    while IFS= read -r lbl; do
        [[ -z "$lbl" ]] && continue
        key="${lbl%%=*}"
        IMG_LABEL_MAP["$key"]="$lbl"
    done < <(echo "$IMG_JSON" | jq -r \
        '.[0].Config.Labels // {} | to_entries[] | .key + "=" + .value' 2>/dev/null)

    RUNTIME_LABELS=()
    while IFS= read -r lbl; do
        [[ -z "$lbl" ]] && continue
        key="${lbl%%=*}"
        # Skip Docker-internal and OCI labels
        case "$key" in
            com.docker.compose.*|org.opencontainers.*|desktop.docker.*) continue ;;
        esac
        # Skip if identical to an image label
        if [[ -n "${IMG_LABEL_MAP[$key]+x}" && "${IMG_LABEL_MAP[$key]}" == "$lbl" ]]; then
            continue
        fi
        RUNTIME_LABELS+=("$lbl")
    done < <(echo "$JSON" | jq -r \
        '.[0].Config.Labels // {} | to_entries[] | .key + "=" + .value')
    unset IMG_LABEL_MAP

    if [[ ${#RUNTIME_LABELS[@]} -gt 0 ]]; then
        yml "    labels:"
        for lbl in "${RUNTIME_LABELS[@]}"; do
            escaped="${lbl//$_SQ/$_SQ$_SQ}"
            escaped="${escaped//\$/\$\$}"
            yml "      - '${escaped}'"
        done
    fi

    # ── Command (emit cleaned result from pre-scan above) ──────────────
    if [[ "$CMD" != "null" && "$CMD" != "$IMG_CMD" ]]; then
        if [[ "$CMD_HAS_MISPLACED_FLAGS" == "true" ]]; then
            # Emit only the non-flag args (if any remain after extraction)
            if [[ -n "$CLEANED_CMD" ]]; then
                yml "    command: ${CLEANED_CMD}"
            fi
            # No command emitted if all args were misplaced flags
        else
            yml "    command: ${CMD}"
        fi
    fi

    # ── Entrypoint (only if different from image default) ─────────────────
    EP=$(echo     "$JSON"     | jq -c '.[0].Config.Entrypoint // null')
    IMG_EP=$(echo "$IMG_JSON" | jq -c '.[0].Config.Entrypoint // null' 2>/dev/null || echo "null")
    # Skip if image inspect failed — we'd be emitting the image default
    if [[ "$EP" != "null" && "$EP" != "$IMG_EP" && "$IMG_INSPECT_OK" == "true" ]]; then
        yml "    entrypoint: ${EP}"
    fi

    # ── Privileged ────────────────────────────────────────────────────────
    if [[ $(echo "$JSON" | jq -r '.[0].HostConfig.Privileged') == "true" ]]; then
        yml "    privileged: true"
    fi

    # ── Capabilities ──────────────────────────────────────────────────────
    CAP_ADD=$(echo "$JSON" | jq -r '.[0].HostConfig.CapAdd // [] | .[]' 2>/dev/null || true)
    if [[ -n "$CAP_ADD" ]]; then
        yml "    cap_add:"
        while IFS= read -r cap; do
            [[ -n "$cap" ]] && yml "      - ${cap}"
        done <<< "$CAP_ADD"
    fi

    CAP_DROP=$(echo "$JSON" | jq -r '.[0].HostConfig.CapDrop // [] | .[]' 2>/dev/null || true)
    if [[ -n "$CAP_DROP" ]]; then
        yml "    cap_drop:"
        while IFS= read -r cap; do
            [[ -n "$cap" ]] && yml "      - ${cap}"
        done <<< "$CAP_DROP"
    fi

    # ── Devices ───────────────────────────────────────────────────────────
    DEVICES=$(echo "$JSON" | jq -r '
        .[0].HostConfig.Devices // [] | .[] |
        .PathOnHost + ":" + .PathInContainer +
        (if .CgroupPermissions != "rwm" then ":" + .CgroupPermissions else "" end)
    ' 2>/dev/null || true)
    if [[ -n "$DEVICES" ]]; then
        yml "    devices:"
        while IFS= read -r dev; do
            [[ -n "$dev" ]] && yml "      - ${dev}"
        done <<< "$DEVICES"
    fi

    # ── User ──────────────────────────────────────────────────────────────
    USER_VAL=$(echo  "$JSON"     | jq -r '.[0].Config.User // empty')
    IMG_USER=$(echo  "$IMG_JSON" | jq -r '.[0].Config.User // empty' 2>/dev/null || true)
    # Only emit if different from image AND image inspect succeeded
    if [[ -n "$USER_VAL" && "$USER_VAL" != "$IMG_USER" && "$IMG_INSPECT_OK" == "true" ]]; then
        yml "    user: \"${USER_VAL}\""
    fi

    # ── Working directory ─────────────────────────────────────────────────
    WORKDIR=$(echo     "$JSON"     | jq -r '.[0].Config.WorkingDir // empty')
    IMG_WORKDIR=$(echo "$IMG_JSON" | jq -r '.[0].Config.WorkingDir // empty' 2>/dev/null || true)
    # Only emit if different from image AND image inspect succeeded
    if [[ -n "$WORKDIR" && "$WORKDIR" != "$IMG_WORKDIR" && "$IMG_INSPECT_OK" == "true" ]]; then
        yml "    working_dir: ${WORKDIR}"
    fi

    # ── DNS ───────────────────────────────────────────────────────────────
    DNS_SERVERS=$(echo "$JSON" | jq -r '.[0].HostConfig.Dns // [] | .[]' 2>/dev/null || true)
    if [[ -n "$DNS_SERVERS" ]]; then
        yml "    dns:"
        while IFS= read -r d; do
            [[ -n "$d" ]] && yml "      - ${d}"
        done <<< "$DNS_SERVERS"
    fi

    # ── Extra hosts ───────────────────────────────────────────────────────
    EXTRA_HOSTS=$(echo "$JSON" | jq -r '.[0].HostConfig.ExtraHosts // [] | .[]' 2>/dev/null || true)
    if [[ -n "$EXTRA_HOSTS" ]]; then
        yml "    extra_hosts:"
        while IFS= read -r h; do
            [[ -n "$h" ]] && yml "      - \"${h}\""
        done <<< "$EXTRA_HOSTS"
    fi

    # ── SHM size (only if non-default > 64 MiB) ──────────────────────────
    SHM_SIZE=$(echo "$JSON" | jq -r '.[0].HostConfig.ShmSize // 0')
    if [[ "$SHM_SIZE" -gt 67108864 ]]; then
        SHM_HR=$(numfmt --to=iec-i --suffix=B "$SHM_SIZE" 2>/dev/null || echo "${SHM_SIZE}")
        yml "    shm_size: \"${SHM_HR}\""
    fi

    # ── PID mode ──────────────────────────────────────────────────────────
    PID_MODE=$(echo "$JSON" | jq -r '.[0].HostConfig.PidMode // empty')
    if [[ -n "$PID_MODE" && "$PID_MODE" != "private" ]]; then
        yml "    pid: \"${PID_MODE}\""
    fi

    # ── IPC mode ──────────────────────────────────────────────────────────
    IPC_MODE=$(echo "$JSON" | jq -r '.[0].HostConfig.IpcMode // empty')
    if [[ -n "$IPC_MODE" && "$IPC_MODE" != "private" && "$IPC_MODE" != "shareable" ]]; then
        yml "    ipc: ${IPC_MODE}"
    fi

    # ── Read-only root filesystem ─────────────────────────────────────────
    if [[ $(echo "$JSON" | jq -r '.[0].HostConfig.ReadonlyRootfs') == "true" ]]; then
        yml "    read_only: true"
    fi

    # ── TTY / stdin ───────────────────────────────────────────────────────
    [[ $(echo "$JSON" | jq -r '.[0].Config.OpenStdin') == "true" ]] && yml "    stdin_open: true"
    [[ $(echo "$JSON" | jq -r '.[0].Config.Tty')       == "true" ]] && yml "    tty: true"

    # ── Init process ──────────────────────────────────────────────────────
    INIT_VAL=$(echo "$JSON" | jq -r '.[0].HostConfig.Init // null')
    if [[ "$INIT_VAL" == "true" ]]; then
        yml "    init: true"
    fi

    # ── Stop signal ───────────────────────────────────────────────────────
    STOP_SIG=$(echo "$JSON" | jq -r '.[0].Config.StopSignal // empty')
    IMG_STOP_SIG=$(echo "$IMG_JSON" | jq -r '.[0].Config.StopSignal // empty' 2>/dev/null || true)
    if [[ -n "$STOP_SIG" && "$STOP_SIG" != "$IMG_STOP_SIG" && "$IMG_INSPECT_OK" == "true" ]]; then
        yml "    stop_signal: ${STOP_SIG}"
    fi

    # ── Stop grace period ─────────────────────────────────────────────────
    STOP_TIMEOUT=$(echo "$JSON" | jq -r '.[0].Config.StopTimeout // null')
    IMG_STOP_TIMEOUT=$(echo "$IMG_JSON" | jq -r '.[0].Config.StopTimeout // null' 2>/dev/null || echo "null")
    if [[ "$STOP_TIMEOUT" != "null" && "$STOP_TIMEOUT" != "$IMG_STOP_TIMEOUT" && "$STOP_TIMEOUT" -ne 0 && "$IMG_INSPECT_OK" == "true" ]]; then
        yml "    stop_grace_period: ${STOP_TIMEOUT}s"
    fi

    # ── MAC address ───────────────────────────────────────────────────────
    MAC_ADDR=$(echo "$JSON" | jq -r '.[0].Config.MacAddress // empty' 2>/dev/null || true)
    if [[ -n "$MAC_ADDR" ]]; then
        yml "    mac_address: \"${MAC_ADDR}\""
    fi

    # ── Healthcheck ───────────────────────────────────────────────────────
    # Compare against image defaults — images often define their own HEALTHCHECK
    # instruction. Skip if identical to the image's built-in healthcheck.
    HC_JSON=$(echo "$JSON"     | jq -c '.[0].Config.Healthcheck // null' 2>/dev/null || echo "null")
    IMG_HC_JSON=$(echo "$IMG_JSON" | jq -c '.[0].Config.Healthcheck // null' 2>/dev/null || echo "null")

    # Only emit if: (a) there IS a healthcheck, (b) it differs from the image
    # default, and (c) if image inspect failed, skip it (it's likely an image default).
    EMIT_HC=false
    if [[ "$HC_JSON" != "null" && -n "$HC_JSON" ]]; then
        if [[ "$IMG_INSPECT_OK" == "true" && "$HC_JSON" != "$IMG_HC_JSON" ]]; then
            EMIT_HC=true
        elif [[ "$IMG_INSPECT_OK" == "false" ]]; then
            # Can't compare — skip and warn
            dim "Skipping healthcheck for ${NAME} (can't verify against image defaults)"
        fi
    fi

    if [[ "$EMIT_HC" == "true" ]]; then
        HC_TYPE=$(echo "$JSON" | jq -r '.[0].Config.Healthcheck.Test[0] // empty' 2>/dev/null || true)
        if [[ -n "$HC_TYPE" && "$HC_TYPE" != "NONE" ]]; then
            yml "    healthcheck:"
            if [[ "$HC_TYPE" == "CMD-SHELL" ]]; then
                HC_CMD=$(echo "$JSON" | jq -r '.[0].Config.Healthcheck.Test[1] // empty')
                yml "      test: [\"CMD-SHELL\", \"${HC_CMD}\"]"
            elif [[ "$HC_TYPE" == "CMD" ]]; then
                HC_ARRAY=$(echo "$JSON" | jq -c '.[0].Config.Healthcheck.Test')
                yml "      test: ${HC_ARRAY}"
            fi

            HC_INTERVAL=$(echo "$JSON" | jq -r '.[0].Config.Healthcheck.Interval // 0')
            [[ "$HC_INTERVAL" -gt 0 ]] && yml "      interval: $((HC_INTERVAL / 1000000000))s"

            HC_TIMEOUT=$(echo "$JSON" | jq -r '.[0].Config.Healthcheck.Timeout // 0')
            [[ "$HC_TIMEOUT" -gt 0 ]] && yml "      timeout: $((HC_TIMEOUT / 1000000000))s"

            HC_RETRIES=$(echo "$JSON" | jq -r '.[0].Config.Healthcheck.Retries // 0')
            [[ "$HC_RETRIES" -gt 0 ]] && yml "      retries: ${HC_RETRIES}"

            HC_START=$(echo "$JSON" | jq -r '.[0].Config.Healthcheck.StartPeriod // 0')
            [[ "$HC_START" -gt 0 ]] && yml "      start_period: $((HC_START / 1000000000))s"
        fi
    fi

    # ── Logging ───────────────────────────────────────────────────────────
    LOG_DRIVER=$(echo "$JSON" | jq -r '.[0].HostConfig.LogConfig.Type // empty')
    LOG_OPT_COUNT=$(echo "$JSON" | jq '.[0].HostConfig.LogConfig.Config // {} | length')

    if [[ (-n "$LOG_DRIVER" && "$LOG_DRIVER" != "json-file") || "$LOG_OPT_COUNT" -gt 0 ]]; then
        yml "    logging:"
        yml "      driver: ${LOG_DRIVER:-json-file}"
        if [[ "$LOG_OPT_COUNT" -gt 0 ]]; then
            yml "      options:"
            while IFS= read -r opt_line; do
                [[ -n "$opt_line" ]] && yml "        ${opt_line}"
            done < <(echo "$JSON" | jq -r '
                .[0].HostConfig.LogConfig.Config // {} | to_entries[] |
                .key + ": \"" + .value + "\""
            ')
        fi
    fi

    # ── Ulimits ───────────────────────────────────────────────────────────
    ULIMIT_COUNT=$(echo "$JSON" | jq '.[0].HostConfig.Ulimits // [] | length')
    if [[ "$ULIMIT_COUNT" -gt 0 ]]; then
        yml "    ulimits:"
        while IFS= read -r ul_json; do
            UL_NAME=$(echo "$ul_json" | jq -r '.Name')
            UL_SOFT=$(echo "$ul_json" | jq -r '.Soft')
            UL_HARD=$(echo "$ul_json" | jq -r '.Hard')
            if [[ "$UL_SOFT" == "$UL_HARD" ]]; then
                yml "      ${UL_NAME}: ${UL_SOFT}"
            else
                yml "      ${UL_NAME}:"
                yml "        soft: ${UL_SOFT}"
                yml "        hard: ${UL_HARD}"
            fi
        done < <(echo "$JSON" | jq -c '.[0].HostConfig.Ulimits // [] | .[]')
    fi

    # ── Security options ──────────────────────────────────────────────────
    SEC_OPTS=$(echo "$JSON" | jq -r '.[0].HostConfig.SecurityOpt // [] | .[]' 2>/dev/null || true)
    if [[ -n "$SEC_OPTS" ]]; then
        yml "    security_opt:"
        while IFS= read -r so; do
            [[ -n "$so" ]] && yml "      - ${so}"
        done <<< "$SEC_OPTS"
    fi

    # ── PIDs limit ────────────────────────────────────────────────────────
    PIDS_LIMIT=$(echo "$JSON" | jq -r '.[0].HostConfig.PidsLimit // 0')
    if [[ "$PIDS_LIMIT" -gt 0 ]]; then
        yml "    pids_limit: ${PIDS_LIMIT}"
    fi

    # ── Supplementary groups ──────────────────────────────────────────────
    GROUP_ADD=$(echo "$JSON" | jq -r '.[0].HostConfig.GroupAdd // [] | .[]' 2>/dev/null || true)
    if [[ -n "$GROUP_ADD" ]]; then
        yml "    group_add:"
        while IFS= read -r grp; do
            [[ -n "$grp" ]] && yml "      - ${grp}"
        done <<< "$GROUP_ADD"
    fi

    # ── OOM score adjustment ──────────────────────────────────────────────
    OOM_SCORE=$(echo "$JSON" | jq -r '.[0].HostConfig.OomScoreAdj // 0')
    if [[ "$OOM_SCORE" -ne 0 ]]; then
        yml "    oom_score_adj: ${OOM_SCORE}"
    fi

    # ── OOM kill disable ──────────────────────────────────────────────────
    OOM_KILL=$(echo "$JSON" | jq -r '.[0].HostConfig.OomKillDisable // false')
    if [[ "$OOM_KILL" == "true" ]]; then
        yml "    oom_kill_disable: true"
    fi

    # ── CPU set ────────────────────────────────────────────────────────────
    CPUSET_CPUS=$(echo "$JSON" | jq -r '.[0].HostConfig.CpusetCpus // empty')
    if [[ -n "$CPUSET_CPUS" ]]; then
        yml "    cpuset: \"${CPUSET_CPUS}\""
    fi

    # ── Sysctls ───────────────────────────────────────────────────────────
    SYSCTL_COUNT=$(echo "$JSON" | jq '.[0].HostConfig.Sysctls // {} | length')
    if [[ "$SYSCTL_COUNT" -gt 0 ]]; then
        yml "    sysctls:"
        while IFS= read -r sc_line; do
            [[ -n "$sc_line" ]] && yml "      ${sc_line}"
        done < <(echo "$JSON" | jq -r '
            .[0].HostConfig.Sysctls // {} | to_entries[] |
            .key + ": \"" + .value + "\""
        ')
    fi

    # ── Memory / CPU limits ───────────────────────────────────────────────
    MEM_LIMIT=$(echo "$JSON" | jq -r '.[0].HostConfig.Memory // 0')
    NANO_CPUS=$(echo "$JSON" | jq -r '.[0].HostConfig.NanoCpus // 0')
    MEM_RESERVE=$(echo "$JSON" | jq -r '.[0].HostConfig.MemoryReservation // 0')

    if [[ "$MEM_LIMIT" -gt 0 || "$NANO_CPUS" -gt 0 || "$MEM_RESERVE" -gt 0 ]]; then
        yml "    deploy:"
        yml "      resources:"
        if [[ "$MEM_LIMIT" -gt 0 || "$NANO_CPUS" -gt 0 ]]; then
            yml "        limits:"
            if [[ "$MEM_LIMIT" -gt 0 ]]; then
                MEM_HR=$(numfmt --to=iec-i --suffix=B "$MEM_LIMIT" 2>/dev/null || echo "${MEM_LIMIT}")
                yml "          memory: ${MEM_HR}"
            fi
            if [[ "$NANO_CPUS" -gt 0 ]]; then
                CPU_VAL=$(awk "BEGIN {printf \"%.2f\", $NANO_CPUS / 1000000000}" 2>/dev/null || echo "$NANO_CPUS")
                yml "          cpus: '${CPU_VAL}'"
            fi
        fi
        if [[ "$MEM_RESERVE" -gt 0 ]]; then
            yml "        reservations:"
            MEM_R_HR=$(numfmt --to=iec-i --suffix=B "$MEM_RESERVE" 2>/dev/null || echo "${MEM_RESERVE}")
            yml "          memory: ${MEM_R_HR}"
        fi
    fi

    # Blank line between services for readability
    yml ""

    # Use prefix ++ so the expression evaluates to the new (nonzero) value;
    # post-increment returns the old value (0 on first call) which set -e
    # would treat as a failure exit.
    (( ++MIGRATED ))
done

# ─── Assemble the final compose file ─────────────────────────────────────────

assemble() {
    echo "# ──────────────────────────────────────────────────────────────────"
    echo "# Generated by docker-migrate.sh on $(date -Iseconds)"
    echo "#"
    echo "# Review this file carefully before use.  In particular:"
    echo "#   - Verify volume mounts and data paths are correct"
    echo "#   - Add any depends_on relationships between services"
    echo "#   - Consider using .env files for sensitive environment variables"
    echo "# ──────────────────────────────────────────────────────────────────"
    echo ""
    echo "services:"
    cat "$TMPFILE"

    # Top-level named volumes (external: true to use pre-existing volumes)
    if [[ ${#NAMED_VOLUMES[@]} -gt 0 ]]; then
        echo "volumes:"
        for vol in $(echo "${!NAMED_VOLUMES[@]}" | tr ' ' '\n' | sort); do
            echo "  ${vol}:"
            echo "    external: true"
        done
        echo ""
    fi

    # Top-level networks (external: true to use pre-existing networks)
    if [[ ${#EXT_NETWORKS[@]} -gt 0 ]]; then
        echo "networks:"
        for net in $(echo "${!EXT_NETWORKS[@]}" | tr ' ' '\n' | sort); do
            echo "  ${net}:"
            echo "    external: true"
        done
        echo ""
    fi
}

# ─── Output ──────────────────────────────────────────────────────────────────

if [[ "$WRITE" == "true" ]]; then
    if [[ -f "$OUTPUT" ]]; then
        BACKUP="${OUTPUT}.bak.$(date +%s)"
        cp "$OUTPUT" "$BACKUP"
        warn "Existing ${OUTPUT} backed up to ${BACKUP}"
    fi
    assemble > "$OUTPUT"
    info "Written to: ${OUTPUT}"
else
    echo "" >&2
    header "Generated docker-compose.yml (preview — use --write to save)"
    echo "──────────────────────────────────────────────────────────────" >&2
    assemble
    echo "──────────────────────────────────────────────────────────────" >&2
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo "" >&2
header "Summary"
info "Migrated: ${MIGRATED} container(s)"
[[ "$SKIPPED" -gt 0 ]] && warn "Skipped:  ${SKIPPED} (already managed by compose)"

if [[ "$MIGRATED" -gt 0 ]]; then
    echo "" >&2
    header "Next Steps"
    if [[ "$WRITE" != "true" ]]; then
        dim "1. Generate the file:   docker-migrate.sh --write"
        dim "2. Review & edit:       \$EDITOR docker-compose.yml"
        dim "3. Stop old containers: docker stop <container_names...>"
        dim "4. Remove them:         docker rm <container_names...>"
        dim "5. Start with compose:  docker compose up -d"
    else
        dim "1. Review & edit:       \$EDITOR ${OUTPUT}"
        dim "2. Stop old containers: docker stop <container_names...>"
        dim "3. Remove them:         docker rm <container_names...>"
        dim "4. Start with compose:  docker compose up -d"
    fi
    echo "" >&2
    dim "After migration, update containers with:"
    dim "  docker compose pull && docker compose up -d"
fi
