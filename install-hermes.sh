#!/usr/bin/env bash
# Hermes Agent Docker Installer
# Uses the official NousResearch Hermes Docker image.

set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="hermes-agent"
APP_DIR="/opt/${APP_NAME}"
DATA_DIR="${APP_DIR}/data"
COMPOSE_DIR="${APP_DIR}/compose"
BACKUP_DIR="${APP_DIR}/backups"
SCRIPTS_DIR="${APP_DIR}/scripts"
ENV_FILE="${APP_DIR}/.env"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"
IMAGE="nousresearch/hermes-agent:latest"
CONTAINER="hermes"
MIN_RAM_MB=1024
MIN_DISK_MB=500
DEFAULT_SWAP_MB=4096
LOCK_FILE="/run/lock/hermes-agent-installer.lock"
NON_INTERACTIVE=0

log() { printf '\n\033[1;36m[Hermes]\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
ram_mb() { awk '/MemTotal:/ {printf "%d\n", $2 / 1024}' /proc/meminfo; }
available_mb() { awk '/MemAvailable:/ {printf "%d\n", $2 / 1024}' /proc/meminfo; }
swap_mb() { awk '/SwapTotal:/ {printf "%d\n", $2 / 1024}' /proc/meminfo; }
cpu_count() { nproc 2>/dev/null || printf '1\n'; }
disk_free_mb() { df -Pm / | awk 'NR == 2 {print $4}'; }

usage() {
  cat <<'EOF'
Usage:
  sudo bash install-hermes.sh
  sudo bash install-hermes.sh --non-interactive
  sudo bash install-hermes.sh --help

Options:
  --non-interactive  Do not ask questions. No swap file is created automatically.
  --help             Show this help.
EOF
}

require_root() {
  [[ ${EUID} -eq 0 ]] || die "Run as root: sudo bash $0"
}

confirm() {
  local prompt="$1"
  local answer
  if (( NON_INTERACTIVE )); then
    return 1
  fi
  read -r -p "${prompt} [y/N]: " answer
  [[ "$answer" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

show_resources() {
  local r a s c d
  r="$(ram_mb)"
  a="$(available_mb)"
  s="$(swap_mb)"
  c="$(cpu_count)"
  d="$(disk_free_mb)"

  printf '\n============================================================\n'
  printf 'Hermes resource check\n'
  printf '============================================================\n'
  printf 'RAM total:        %s MiB\n' "$r"
  printf 'RAM available:    %s MiB\n' "$a"
  printf 'Swap total:       %s MiB\n' "$s"
  printf 'CPU:              %s core(s)\n' "$c"
  printf 'Disk available:   %s MiB\n' "$d"
  printf '\nOfficial Hermes guidance:\n'
  printf '  Core / no browser: >= 1 GiB RAM\n'
  printf '  Browser enabled:  >= 2 GiB RAM\n'
  printf '  Data disk:        >= 500 MiB minimum\n'
  printf '  CPU:              >= 1 core minimum\n\n'

  if (( r < MIN_RAM_MB )); then
    warn "RAM is below the official 1 GiB minimum. Core installation is unsupported and may OOM."
  else
    ok "RAM meets the official core minimum."
  fi

  (( d >= MIN_DISK_MB )) || die "Less than ${MIN_DISK_MB} MiB of free disk is available."
}

create_swap() {
  local path="/swapfile"
  local free_mb
  free_mb="$(disk_free_mb)"

  (( free_mb >= DEFAULT_SWAP_MB + 512 )) || {
    warn "Not enough free disk for the default 4 GiB swap file. Free disk: ${free_mb} MiB."
    return 1
  }

  if swapon --show --noheadings 2>/dev/null | grep -q .; then
    ok "Swap is already active. No swap settings were changed."
    return 0
  fi

  if [[ -e "$path" ]]; then
    warn "$path already exists but is not active. It will not be overwritten automatically."
    return 1
  fi

  log "Creating a 4 GiB swap file."
  if command_exists fallocate; then
    fallocate -l 4G "$path" || dd if=/dev/zero of="$path" bs=1M count="$DEFAULT_SWAP_MB" status=progress
  else
    dd if=/dev/zero of="$path" bs=1M count="$DEFAULT_SWAP_MB" status=progress
  fi
  chmod 600 "$path"
  mkswap "$path" >/dev/null
  swapon "$path"

  if ! grep -qsE '^/swapfile[[:space:]]+none[[:space:]]+swap[[:space:]]' /etc/fstab; then
    printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
  fi

  ok "Swap created and activated."
  swapon --show
}

ensure_swap() {
  local current_swap
  current_swap="$(swap_mb)"

  if (( current_swap > 0 )); then
    ok "Swap is already active (${current_swap} MiB). No swap settings were changed."
    return 0
  fi

  warn "No active swap was detected."
  if (( NON_INTERACTIVE )); then
    warn "Non-interactive mode will not create swap automatically."
    return 0
  fi

  if confirm "Create and activate a 4 GiB swap file?"; then
    create_swap || warn "Swap creation failed. Continuing without swap."
  else
    warn "Swap creation skipped."
  fi
}

check_resource_gate() {
  local total_ram
  total_ram="$(ram_mb)"
  if (( total_ram >= MIN_RAM_MB )); then
    return 0
  fi

  if (( NON_INTERACTIVE )); then
    die "Stopped before installation because RAM is below the official 1 GiB minimum."
  fi

  if confirm "Continue with an unsupported low-memory installation anyway?"; then
    warn "Continuing with an unsupported low-memory installation."
  else
    printf 'Stopped. No Hermes installation was made.\n'
    exit 0
  fi
}

ensure_docker() {
  local distro codename
  if command_exists docker; then
    ok "Docker present: $(docker --version)"
    systemctl enable --now docker >/dev/null 2>&1 || true
    return 0
  fi

  log "Docker not found. Installing Docker Engine from Docker's official repository."
  [[ -r /etc/os-release ]] || die "Cannot identify the operating system."
  . /etc/os-release
  distro="${ID:-}"
  codename="${VERSION_CODENAME:-}"
  [[ "$distro" == "ubuntu" || "$distro" == "debian" ]] || die "Automatic Docker installation supports Ubuntu and Debian only."

  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL "https://download.docker.com/linux/${distro}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi
  cat > /etc/apt/sources.list.d/docker.list <<EOF
Types: deb
URIs: https://download.docker.com/linux/${distro}
Suites: ${codename}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  ok "Docker installed."
}

ensure_compose() {
  if docker compose version >/dev/null 2>&1; then
    ok "Docker Compose present: $(docker compose version)"
    return 0
  fi
  log "Docker Compose plugin not found. Installing it."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin
  docker compose version >/dev/null 2>&1 || die "Docker Compose installation failed."
}

prepare_dirs() {
  install -d -m 0755 "$APP_DIR" "$DATA_DIR" "$COMPOSE_DIR" "$BACKUP_DIR" "$SCRIPTS_DIR"
  chmod 700 "$DATA_DIR" "$BACKUP_DIR"
  touch "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

env_get() {
  grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2- || true
}

env_set() {
  local key="$1"
  local value="$2"
  if grep -qE "^${key}=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
  chmod 600 "$ENV_FILE"
}

write_env() {
  [[ -n "$(env_get HERMES_UID)" ]] || env_set HERMES_UID 10000
  [[ -n "$(env_get HERMES_GID)" ]] || env_set HERMES_GID 10000
  [[ -n "$(env_get IMAGE_TAG)" ]] || env_set IMAGE_TAG "$IMAGE"
}

write_compose() {
  cat > "$COMPOSE_FILE" <<'EOF'
services:
  hermes:
    image: ${IMAGE_TAG:-nousresearch/hermes-agent:latest}
    container_name: hermes
    restart: unless-stopped
    network_mode: host
    command: ["gateway", "run"]
    volumes:
      - /opt/hermes-agent/data:/opt/data
    environment:
      HERMES_UID: ${HERMES_UID:-10000}
      HERMES_GID: ${HERMES_GID:-10000}
EOF
}

write_helpers() {
  cat > "${SCRIPTS_DIR}/backup.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
APP_DIR="/opt/hermes-agent"
BACKUP_DIR="${APP_DIR}/backups"
stamp="$(date +%Y%m%d-%H%M%S)"
archive="${BACKUP_DIR}/hermes-${stamp}.tar.gz"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
tar -C "$APP_DIR" -czf "$archive" data .env compose
chmod 600 "$archive"
printf '%s\n' "$archive"
EOF

  cat > "${SCRIPTS_DIR}/healthcheck.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
docker inspect -f 'state={{.State.Status}} running={{.State.Running}} restarts={{.RestartCount}} image={{.Config.Image}}' hermes 2>/dev/null || true
printf '\n'
free -h
printf '\n'
swapon --show || true
printf '\n'
docker logs --tail 60 hermes 2>&1 || true
EOF

  cat > "${SCRIPTS_DIR}/update.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
APP_DIR="/opt/hermes-agent"
COMPOSE_FILE="${APP_DIR}/compose/docker-compose.yml"
ENV_FILE="${APP_DIR}/.env"
exec 9>/run/lock/hermes-agent-update.lock
flock -n 9 || { echo "Another Hermes update is running."; exit 1; }
backup="$(${APP_DIR}/scripts/backup.sh)"
old_id="$(docker image inspect -f '{{.Id}}' nousresearch/hermes-agent:latest 2>/dev/null || true)"
rollback_tag="hermes-agent:rollback-$(date +%Y%m%d-%H%M%S)"
if [[ -n "$old_id" ]]; then
  docker tag "$old_id" "$rollback_tag"
  printf '%s\n' "$rollback_tag" > "${APP_DIR}/.rollback-image"
fi
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" config >/dev/null
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d --remove-orphans
sleep 8
[[ "$(docker inspect -f '{{.State.Running}}' hermes 2>/dev/null || echo false)" == "true" ]] || { echo "Update failed. Backup: $backup" >&2; exit 1; }
echo "Update successful. Backup: $backup"
EOF

  cat > "${SCRIPTS_DIR}/rollback.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
APP_DIR="/opt/hermes-agent"
COMPOSE_FILE="${APP_DIR}/compose/docker-compose.yml"
ENV_FILE="${APP_DIR}/.env"
rollback_file="${APP_DIR}/.rollback-image"
[[ -f "$rollback_file" ]] || { echo "No rollback image recorded."; exit 1; }
rollback_tag="$(cat "$rollback_file")"
docker image inspect "$rollback_tag" >/dev/null 2>&1 || { echo "Rollback image is unavailable: $rollback_tag"; exit 1; }
docker tag "$rollback_tag" nousresearch/hermes-agent:latest
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d --force-recreate
echo "Rollback complete."
EOF

  cat > "${SCRIPTS_DIR}/uninstall.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
APP_DIR="/opt/hermes-agent"
COMPOSE_FILE="${APP_DIR}/compose/docker-compose.yml"
ENV_FILE="${APP_DIR}/.env"
read -r -p "Stop and remove Hermes? Persistent data will be kept. [y/N]: " answer
[[ "$answer" =~ ^([Yy]|[Yy][Ee][Ss])$ ]] || exit 0
if [[ -f "$COMPOSE_FILE" && -f "$ENV_FILE" ]]; then
  docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" down --remove-orphans || true
fi
echo "Hermes container removed. Persistent data remains in ${APP_DIR}."
EOF

  chmod 700 "${SCRIPTS_DIR}"/*.sh
}

install_hermes() {
  prepare_dirs
  write_env
  write_compose
  write_helpers
  docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" config >/dev/null
  log "Pulling the official Hermes image."
  docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull
  log "Starting Hermes."
  docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d --remove-orphans
  sleep 5

  if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)" == "true" ]]; then
    ok "Hermes container is running."
  else
    warn "Hermes did not stay running. Check: docker logs --tail 100 ${CONTAINER}"
  fi

  printf '\nInstallation complete.\n'
  printf 'Management directory: %s\n' "$APP_DIR"
  printf 'Health check: %s/scripts/healthcheck.sh\n' "$APP_DIR"
  printf 'Backup: %s/scripts/backup.sh\n' "$APP_DIR"
  printf 'Update: %s/scripts/update.sh\n' "$APP_DIR"
  printf 'Rollback: %s/scripts/rollback.sh\n' "$APP_DIR"
  printf 'Uninstall: %s/scripts/uninstall.sh\n' "$APP_DIR"
}

main() {
  case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    --non-interactive) NON_INTERACTIVE=1 ;;
    "") ;;
    *) die "Unknown option: $1" ;;
  esac

  require_root
  mkdir -p "$(dirname "$LOCK_FILE")"
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "Another Hermes installer process is already running."

  log "Hermes Agent Docker Installer"
  show_resources
  ensure_swap
  check_resource_gate
  ensure_docker
  ensure_compose
  install_hermes
}

main "$@"
