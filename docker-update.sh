#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# docker-update.sh — Bulk Docker Compose stack updater with self-update
#
# Pulls latest images and recreates containers for all Docker Compose projects
# in the same directory. Each .yml file is treated as a separate project.
#
# Self-update: Downloads the latest version directly from GitHub — no git
# required. Only curl or wget is needed (most systems have at least one).
#
# Repository: https://github.com/chrischanson/docker-standalone-to-compose
# ─────────────────────────────────────────────────────────────────────────────

# Wrap everything in main() so the entire script is loaded into memory before
# execution begins. This is critical for self-update safety — if the script
# file is replaced mid-execution, bash would read corrupted/mixed content.
main() {

# ─── Version ─────────────────────────────────────────────────────────────────
# Bump this on every release. The self-updater compares this against the
# remote version to determine if an update is available.
SCRIPT_VERSION="1.0.0"

# ─── Self-update configuration ───────────────────────────────────────────────
GITHUB_REPO="chrischanson/docker-standalone-to-compose"
GITHUB_BRANCH="main"
SCRIPT_NAME="docker-update.sh"
RAW_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_BRANCH}/${SCRIPT_NAME}"

# ─── Colors (only when outputting to a terminal) ─────────────────────────────
if [[ -t 2 ]]; then
    GREEN='\033[0;32m'  YELLOW='\033[0;33m'  CYAN='\033[0;36m'
    RED='\033[0;31m'    BOLD='\033[1m'        DIM='\033[2m'
    RESET='\033[0m'
else
    GREEN=""  YELLOW=""  CYAN=""  RED=""  BOLD=""  DIM=""  RESET=""
fi

info()    { printf "${GREEN}✔${RESET} %s\n" "$1" >&2; }
warn()    { printf "${YELLOW}⚠${RESET}  %s\n" "$1" >&2; }
err()     { printf "${RED}✘${RESET} %s\n" "$1" >&2; }
dim()     { printf "${DIM}  %s${RESET}\n" "$1" >&2; }

# ─── Help ────────────────────────────────────────────────────────────────────

show_help() {
    cat <<'HELPTEXT'
docker-update.sh — Bulk Docker Compose stack updater

USAGE
    docker-update.sh [OPTIONS] [PROJECT ...]

DESCRIPTION
    Pulls the latest images and recreates containers for Docker Compose
    projects defined by .yml files in the script's directory.

    When run without arguments, all .yml files are processed. You can
    target specific projects by passing their names (with or without the
    .yml extension).

    On each run, the script automatically checks GitHub for a newer
    version. If one is found, you will be prompted to upgrade before
    proceeding. The check is silent when offline or when curl/wget is
    unavailable.

OPTIONS
    -h, --help              Show this help message and exit.
    -V, --version           Print the current version and exit.
    -f, --force             Force recreate all containers even if no
                            image has changed.
    --build SERVICE         Build SERVICE with --no-cache and recreate
                            with --force-recreate.
    --build=SERVICE         Same as above (= syntax).

EXAMPLES
    # Update all stacks in the folder
    docker-update.sh

    # Update only specific stacks
    docker-update.sh ddns dev-server

    # Build and recreate a specific service (no-cache)
    docker-update.sh --build web

    # Force recreate even if images haven't changed
    docker-update.sh --force ddns

REQUIREMENTS
    • Docker with Compose plugin (docker compose)
    • bash 4+
    • curl or wget (for automatic upgrade check; optional)

HELPTEXT
}

# ─── HTTP fetch helper ───────────────────────────────────────────────────────
# Uses curl or wget — whichever is available. No other tools required.

http_fetch() {
    local url="$1"
    if command -v curl &>/dev/null; then
        curl -fsSL --max-time 15 "$url" 2>/dev/null
    elif command -v wget &>/dev/null; then
        wget -qO- --timeout=15 "$url" 2>/dev/null
    else
        return 1
    fi
}

has_http_tool() {
    command -v curl &>/dev/null || command -v wget &>/dev/null
}

# ─── Version comparison ─────────────────────────────────────────────────────
# Compare two semver strings (X.Y.Z). Returns 0 if $1 < $2.

version_lt() {
    local IFS=.
    local i v1=($1) v2=($2)
    for ((i = 0; i < ${#v1[@]} || i < ${#v2[@]}; i++)); do
        local a=${v1[i]:-0}
        local b=${v2[i]:-0}
        if ((a < b)); then return 0; fi
        if ((a > b)); then return 1; fi
    done
    return 1  # equal → not less than
}

# ─── Automatic upgrade check ─────────────────────────────────────────────────
# Runs silently on every invocation. If a newer version is found on GitHub,
# prompts the user to upgrade. If the check fails for any reason (no network,
# no curl/wget, parse error), it is silently skipped so the main workflow is
# never blocked.

extract_remote_version() {
    local content="$1"
    echo "$content" | grep -m1 '^SCRIPT_VERSION=' | sed 's/^SCRIPT_VERSION=["'\'']*//;s/["'\'']*$//'
}

apply_upgrade() {
    local remote_content="$1"

    # Determine the path to this script
    local script_path
    script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

    # Verify we can write to the script location
    if [[ ! -w "$script_path" ]]; then
        err "Cannot write to ${script_path} — check file permissions."
        return 1
    fi

    # Atomic-ish update: write to a temp file first, then move into place.
    local tmp_file
    tmp_file=$(mktemp "${script_path}.XXXXXX") || {
        err "Failed to create temporary file."
        return 1
    }

    printf '%s\n' "$remote_content" > "$tmp_file"

    # Preserve the original file's permissions
    chmod --reference="$script_path" "$tmp_file" 2>/dev/null || chmod +x "$tmp_file"

    mv -f "$tmp_file" "$script_path" || {
        err "Failed to replace ${script_path}"
        rm -f "$tmp_file"
        return 1
    }

    return 0
}

check_and_offer_upgrade() {
    # Skip silently if no http tool is available
    has_http_tool || return 0

    # Skip silently if not running in an interactive terminal
    [[ -t 0 ]] || return 0

    local remote_content
    remote_content=$(http_fetch "$RAW_URL" 2>/dev/null) || return 0
    [[ -z "$remote_content" ]] && return 0

    local remote_version
    remote_version=$(extract_remote_version "$remote_content")
    [[ -z "$remote_version" ]] && return 0

    # No upgrade needed
    version_lt "$SCRIPT_VERSION" "$remote_version" || return 0

    # ── New version available — prompt the user ──
    echo "───────────────────────────────────────────────"
    printf "  ${CYAN}New version available:${RESET} %s → ${BOLD}%s${RESET}\n" "$SCRIPT_VERSION" "$remote_version"
    echo "───────────────────────────────────────────────"
    printf "  Upgrade now? [y/N] "
    local reply
    read -r reply
    case "$reply" in
        [Yy]|[Yy][Ee][Ss])
            if apply_upgrade "$remote_content"; then
                info "Upgraded successfully: ${SCRIPT_VERSION} → ${remote_version}"
                echo ""
            else
                warn "Upgrade failed — continuing with current version."
            fi
            ;;
        *)
            dim "Skipping upgrade."
            echo ""
            ;;
    esac
}

# ─── Operational defaults ────────────────────────────────────────────────────

COMPOSE_DIR="$(cd "$(dirname "$0")" && pwd)"
FORCE=false
BUILD_SERVICE=""
TARGETS=()
SUCCESS=()
FAILED=()

# ─── Argument parsing ───────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)         show_help; return 0 ;;
    -V|--version)      echo "docker-update.sh version ${SCRIPT_VERSION}"; return 0 ;;
    --force|-f)        FORCE=true; shift ;;
    --build)           [[ $# -lt 2 || "$2" == -* ]] && { err "--build requires a service name"; return 1; }; BUILD_SERVICE="$2"; shift 2 ;;
    --build=*)         BUILD_SERVICE="${1#*=}"; [[ -z "$BUILD_SERVICE" ]] && { err "--build requires a service name"; return 1; }; shift ;;
    -*)                err "Unknown option: $1"; echo "Run with --help for usage." >&2; return 1 ;;
    *)                 TARGETS+=("$1"); shift ;;
  esac
done

# ─── Automatic upgrade check (silent on failure) ─────────────────────────────
check_and_offer_upgrade

# ─── Check dependencies ─────────────────────────────────────────────────────

if ! command -v docker &>/dev/null; then
  err "docker is not installed or not in PATH"
  return 1
fi
if ! docker compose version &>/dev/null; then
  err "docker compose plugin is not available"
  return 1
fi

# ─── Determine which yml files to process ────────────────────────────────────

shopt -s nullglob
yml_files=()
if [[ ${#TARGETS[@]} -eq 0 ]]; then
  yml_files=("$COMPOSE_DIR"/*.yml)
else
  for t in "${TARGETS[@]}"; do
    f="$COMPOSE_DIR/$t"
    [[ "$f" != *.yml ]] && f="${f}.yml"
    if [[ -f "$f" ]]; then
      yml_files+=("$f")
    else
      err "Compose file not found for '$t' (tried $f)"
      return 1
    fi
  done
fi

if [[ ${#yml_files[@]} -eq 0 ]]; then
  echo "No .yml files found to process."
  return 0
fi

# ─── Helper functions ────────────────────────────────────────────────────────

force_remove_conflicting() {
  local container_name="$1"
  local max_attempts=5
  local attempt=0

  while docker ps -a --format '{{.Names}}' | grep -qx "$container_name"; do
    attempt=$((attempt + 1))
    if [[ $attempt -gt $max_attempts ]]; then
      err "    Could not remove $container_name after $max_attempts attempts"
      return 1
    fi
    echo "    Stopping and removing conflicting container: $container_name (attempt $attempt)"
    docker stop "$container_name" 2>/dev/null || true
    docker rm -f "$container_name" 2>/dev/null || true
    sleep 1
  done
}

compose_up() {
  local project="$1"
  local f="$2"
  shift 2
  # Keep compose options before service names; some Compose versions reject
  # options placed after positional service arguments.
  local up_args=(docker compose -p "$project" -f "$f" up -d --remove-orphans)
  [[ "$FORCE" == "true" ]] && up_args+=(--force-recreate)
  up_args+=("$@")

  local output exit_code
  local max_retries=5 retry=0

  while [[ $retry -le $max_retries ]]; do
    output=$("${up_args[@]}" 2>&1)
    exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
      echo "$output"
      return 0
    fi

    # Match both Docker Compose v1 ("The container name") and v2
    # ("container ... already in use") conflict messages.
    if echo "$output" | grep -qiE '(The container name|already in use by container)'; then
      local container_names
      # Extract container names from both message formats:
      #   v1: The container name "/foo" is already in use…
      #   v2: …container "foo" already exists
      container_names=$(
        printf '%s\n' "$output" \
          | sed -n \
              -e 's/.*[Tt]he container name ["\/]*\([^"/]*\)["\/]*.*/\1/p' \
              -e 's/.*container name is already in use by container "\([^"]*\)".*/\1/p' \
          | sed 's|^/||'   \
          | sort -u
      )

      # Fallback: if we couldn't parse specific names, pre-stop every service
      # defined in the compose file that is currently running.
      if [[ -z "$container_names" ]]; then
        warn "    Could not parse conflicting container names — stopping all compose services"
        container_names=$(
          docker compose -p "$project" -f "$f" config --services 2>/dev/null \
            | while IFS= read -r svc; do
                # Compose default container name: <project>-<service>-<index> or just <service>
                # Try both naming schemes.
                for candidate in "${project}-${svc}-1" "${project}_${svc}_1" "$svc"; do
                  if docker ps -a --format '{{.Names}}' | grep -qx "$candidate"; then
                    echo "$candidate"
                    break
                  fi
                done
              done
        )
      fi

      if [[ -n "$container_names" ]]; then
        local remove_failed=false
        while IFS= read -r cname; do
          [[ -z "$cname" ]] && continue
          if ! force_remove_conflicting "$cname"; then
            remove_failed=true
          fi
        done <<< "$container_names"
        if [[ "$remove_failed" == "false" ]]; then
          retry=$((retry + 1))
          continue
        fi
      fi
    fi

    echo "$output" >&2
    return $exit_code
  done

  err "    Failed to bring up $project after $max_retries retries"
  return 1
}

build_service() {
  local project="$1"
  local f="$2"
  local service="$3"

  echo ""
  echo "==> [$project] Building service '$service' (no cache)..."
  if ! docker compose -p "$project" -f "$f" build --no-cache "$service"; then
    echo "==> [$project] Build failed for service '$service'" >&2
    return 1
  fi

  echo "==> [$project] Recreating service '$service'..."
  # Use the robust compose_up function for the deployment
  if ! compose_up "$project" "$f" --force-recreate "$service"; then
    echo "==> [$project] Recreate failed for service '$service'" >&2
    return 1
  fi
  echo "==> [$project] Service '$service' updated."
  return 0
}

update_project() {
  local f="$1"
  local project
  project=$(basename "$f" .yml)

  if [[ -n "$BUILD_SERVICE" ]]; then
    # Skip compose files that don't define this service
    if ! docker compose -p "$project" -f "$f" config --services 2>/dev/null | grep -qx "$BUILD_SERVICE"; then
      echo "==> [$project] Service '$BUILD_SERVICE' not found — skipping"
      return 0
    fi
    build_service "$project" "$f" "$BUILD_SERVICE"
    return $?
  fi

  echo ""
  echo "==> [$project] Pulling latest images..."
  if ! docker compose -p "$project" -f "$f" pull; then
    echo "==> [$project] Pull failed, skipping update" >&2
    return 1
  fi

  echo "==> [$project] Bringing up containers..."
  compose_up "$project" "$f"
}

# ─── Main update loop ───────────────────────────────────────────────────────

for f in "${yml_files[@]}"; do
  project=$(basename "$f" .yml)
  if update_project "$f"; then
    SUCCESS+=("$project")
  else
    err "Failed to update $project"
    FAILED+=("$project")
  fi
done

echo ""
echo "==============================="
echo " Update Summary"
echo "==============================="
echo " Success: ${#SUCCESS[@]}"
for p in "${SUCCESS[@]}"; do echo "   ✔ $p"; done
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo " Failed:  ${#FAILED[@]}"
  for p in "${FAILED[@]}"; do echo "   ✘ $p"; done
  echo "==============================="
  echo ""
  echo "==> Removing dangling images..."
  docker image prune -f
  return 1
fi
echo "==============================="

echo ""
echo "==> Removing dangling images..."
docker image prune -f

} # end main()

main "$@"
