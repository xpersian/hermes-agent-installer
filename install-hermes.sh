#!/usr/bin/env bash
# Hermes Agent Minimal Docker Installer
# نصب کمینه و مرحله‌ای Hermes Agent با Docker رسمی NousResearch
#
# IMPORTANT:
# - Official Hermes minimum: 1 GB RAM without browser; 2 GB with browser.
# - This script does NOT modify Apache or ports 80/443.
# - Dashboard is optional. Public Internet exposure requires authentication.
# - Basic Auth is not recommended for direct public Internet exposure.

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
DASHBOARD_PORT_DEFAULT="9119"
MIN_RAM_MB=1024
BROWSER_RAM_MB=2048
MIN_DISK_MB=500
REQUIRED_SWAP_MB=512
LOCK_FILE="/run/lock/hermes-agent-installer.lock"
NON_INTERACTIVE=0
DASHBOARD_PORT="${DASHBOARD_PORT_DEFAULT}"
HERMES_UID="${HERMES_UID:-10000}"
HERMES_GID="${HERMES_GID:-10000}"

log(){ printf '\n\033[1;36m[Hermes]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
info(){ printf '\033[0;37m       %s\033[0m\n' "$*"; }
command_exists(){ command -v "$1" >/dev/null 2>&1; }
ram_mb(){ awk '/MemTotal:/ {printf "%d\n",$2/1024}' /proc/meminfo; }
swap_mb(){ awk '/SwapTotal:/ {printf "%d\n",$2/1024}' /proc/meminfo; }
available_mb(){ awk '/MemAvailable:/ {printf "%d\n",$2/1024}' /proc/meminfo; }
cpu_count(){ nproc 2>/dev/null || echo 1; }
disk_free_mb(){ df -Pm "$APP_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || df -Pm / | awk 'NR==2 {print $4}'; }

detect_arch(){
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64";;
    aarch64|arm64) echo "arm64";;
    *) echo "$(uname -m)";;
  esac
}

usage(){
cat <<'EOF'
Hermes Agent Installer / نصب Hermes Agent

Usage:
  sudo bash install-hermes.sh
  sudo bash install-hermes.sh --non-interactive
  sudo bash install-hermes.sh --help

Uses the official NousResearch Docker image and preserves /opt/data.
Does not modify Apache or ports 80/443 or unrelated services.
EOF
}

require_root(){ [[ ${EUID} -eq 0 ]] || die "Run as root: sudo bash $0"; }

show_resources(){
  local r s a c d
  r="$(ram_mb)"; s="$(swap_mb)"; a="$(available_mb)"; c="$(cpu_count)"; d="$(disk_free_mb)"
  echo
  echo "============================================================"
  echo "Hermes resource check / بررسی منابع Hermes"
  echo "============================================================"
  printf "RAM total:        %s MiB\n" "$r"
  printf "RAM available:    %s MiB\n" "$a"
  printf "Swap total:       %s MiB\n" "$s"
  printf "CPU:              %s core(s)\n" "$c"
  printf "Disk available:   %s MiB\n" "$d"
  printf "Architecture:     %s\n" "$(detect_arch)"
  echo
  echo "Official Hermes guidance:"
  echo "  Core / no browser: >= 1 GiB RAM"
  echo "  Browser enabled:  >= 2 GiB RAM"
  echo "  Data disk:        >= 500 MiB minimum"
  echo "  CPU:              >= 1 core minimum"
  echo
  if (( r < MIN_RAM_MB )); then
    warn "RAM is below the official 1 GiB minimum. Core installation is unsupported and may OOM."
  else
    ok "RAM meets the official core minimum."
  fi
  if (( s < REQUIRED_SWAP_MB )); then warn "Swap is below ${REQUIRED_SWAP_MB} MiB."; else ok "Swap is present."; fi
  (( d >= MIN_DISK_MB )) || die "Less than ${MIN_DISK_MB} MiB free disk."
}

confirm(){
  local prompt="${1:-Continue?}" ans
  (( NON_INTERACTIVE )) && return 0
  read -r -p "$prompt [y/N]: " ans
  [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

ensure_docker(){
  if command_exists docker; then
    ok "Docker present: $(docker --version)"
  else
    log "Docker not found; installing Docker Engine from Docker's official repository."
    . /etc/os-release
    [[ "${ID:-}" == "ubuntu" || "${ID:-}" == "debian" ]] || die "Automatic Docker installation supports Ubuntu/Debian only. Install Docker manually, then rerun."
    install -m 0755 -d /etc/apt/keyrings
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl
    if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
      curl -fsSL https://download.docker.com/linux/${ID}/gpg -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc
    fi
    cat >/etc/apt/sources.list.d/docker.list <<EOF
Types: deb
URIs: https://download.docker.com/linux/${ID}
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    ok "Docker installed."
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true
}

ensure_compose(){
  if docker compose version >/dev/null 2>&1; then ok "Docker Compose present: $(docker compose version)"; return; fi
  log "Docker Compose plugin not found; installing it."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin
  docker compose version >/dev/null 2>&1 || die "Docker Compose installation failed."
}

prepare_dirs(){
  install -d -m 0755 "$APP_DIR" "$DATA_DIR" "$COMPOSE_DIR" "$BACKUP_DIR" "$SCRIPTS_DIR"
  chmod 700 "$DATA_DIR" "$BACKUP_DIR"
  touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
}

load_existing_env(){
  local v
  v="$(grep -E '^DASHBOARD_PORT=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true)"; [[ -n "$v" ]] && DASHBOARD_PORT="$v"
  v="$(grep -E '^HERMES_UID=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true)"; [[ -n "$v" ]] && HERMES_UID="$v"
  v="$(grep -E '^HERMES_GID=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true)"; [[ -n "$v" ]] && HERMES_GID="$v"
}

upsert_env(){
  local line="$1" key="${1%%=*}"
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s#^${key}=.*#${line}#" "$ENV_FILE"
  else
    printf '%s\n' "$line" >>"$ENV_FILE"
  fi
  chmod 600 "$ENV_FILE"
}

write_env(){
  grep -q '^HERMES_UID=' "$ENV_FILE" 2>/dev/null || echo "HERMES_UID=${HERMES_UID}" >>"$ENV_FILE"
  grep -q '^HERMES_GID=' "$ENV_FILE" 2>/dev/null || echo "HERMES_GID=${HERMES_GID}" >>"$ENV_FILE"
  grep -q '^DASHBOARD_PORT=' "$ENV_FILE" 2>/dev/null || echo "DASHBOARD_PORT=${DASHBOARD_PORT}" >>"$ENV_FILE"
  grep -q '^IMAGE_TAG=' "$ENV_FILE" 2>/dev/null || echo "IMAGE_TAG=${IMAGE}" >>"$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

write_compose(){
cat >"$COMPOSE_FILE" <<'EOF'
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
  if grep -q '^HERMES_DASHBOARD=' "$ENV_FILE" 2>/dev/null; then
cat >>"$COMPOSE_FILE" <<'EOF'
      HERMES_DASHBOARD: ${HERMES_DASHBOARD}
      HERMES_DASHBOARD_HOST: ${HERMES_DASHBOARD_HOST:-127.0.0.1}
      HERMES_DASHBOARD_PORT: ${DASHBOARD_PORT:-9119}
EOF
  fi
  if grep -q '^HERMES_DASHBOARD_BASIC_AUTH_USERNAME=' "$ENV_FILE" 2>/dev/null; then
cat >>"$COMPOSE_FILE" <<'EOF'
      HERMES_DASHBOARD_BASIC_AUTH_USERNAME: ${HERMES_DASHBOARD_BASIC_AUTH_USERNAME}
      HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH: ${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH}
      HERMES_DASHBOARD_BASIC_AUTH_SECRET: ${HERMES_DASHBOARD_BASIC_AUTH_SECRET}
EOF
  fi
  if grep -q '^HERMES_DASHBOARD_OAUTH_CLIENT_ID=' "$ENV_FILE" 2>/dev/null; then
cat >>"$COMPOSE_FILE" <<'EOF'
      HERMES_DASHBOARD_OAUTH_CLIENT_ID: ${HERMES_DASHBOARD_OAUTH_CLIENT_ID}
      HERMES_DASHBOARD_PUBLIC_URL: ${HERMES_DASHBOARD_PUBLIC_URL}
EOF
  fi
}

backup_now(){
  local stamp archive
  stamp="$(date +%Y%m%d-%H%M%S)"
  archive="${BACKUP_DIR}/hermes-${stamp}.tar.gz"
  tar -C "$APP_DIR" -czf "$archive" data .env compose VERSION 2>/dev/null || tar -C "$APP_DIR" -czf "$archive" data .env compose
  chmod 600 "$archive"
  echo "$archive"
}

write_helpers(){
cat >"${SCRIPTS_DIR}/setup.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
APP_DIR="/opt/hermes-agent"; DATA_DIR="$APP_DIR/data"; IMAGE="nousresearch/hermes-agent:latest"
cd "$APP_DIR"
docker compose -f "$APP_DIR/compose/docker-compose.yml" --env-file "$APP_DIR/.env" stop hermes 2>/dev/null || true
docker run -it --rm -v "$DATA_DIR:/opt/data" "$IMAGE" setup
docker compose -f "$APP_DIR/compose/docker-compose.yml" --env-file "$APP_DIR/.env" up -d
echo "Setup finished. Run $APP_DIR/scripts/healthcheck.sh"
EOF

cat >"${SCRIPTS_DIR}/healthcheck.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
APP_DIR="/opt/hermes-agent"; cd "$APP_DIR"
echo "== Hermes status =="
docker inspect -f 'state={{.State.Status}} running={{.State.Running}} restarts={{.RestartCount}} image={{.Config.Image}}' hermes 2>/dev/null || true
echo
echo "== Resources =="; free -h; swapon --show || true
echo
echo "== Recent logs =="; docker logs --tail 60 hermes 2>&1 || true
if grep -q '^HERMES_DASHBOARD=' "$APP_DIR/.env" 2>/dev/null; then
  port="$(grep '^DASHBOARD_PORT=' "$APP_DIR/.env" | tail -1 | cut -d= -f2-)"
  curl -fsS --max-time 5 "http://127.0.0.1:${port:-9119}/" >/dev/null && echo "Dashboard HTTP reachable." || echo "Dashboard HTTP check failed (auth may be expected)."
fi
EOF

cat >"${SCRIPTS_DIR}/backup.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
APP_DIR="/opt/hermes-agent"; BACKUP_DIR="$APP_DIR/backups"; mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
stamp="$(date +%Y%m%d-%H%M%S)"; archive="$BACKUP_DIR/hermes-$stamp.tar.gz"
tar -C "$APP_DIR" -czf "$archive" data .env compose VERSION 2>/dev/null || tar -C "$APP_DIR" -czf "$archive" data .env compose
chmod 600 "$archive"; echo "Backup: $archive"
EOF

cat >"${SCRIPTS_DIR}/update.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
APP_DIR="/opt/hermes-agent"; cd "$APP_DIR"
exec 9>/run/lock/hermes-agent-update.lock; flock -n 9 || { echo "Another Hermes update is running."; exit 1; }
ram="$(awk '/MemTotal:/ {printf "%d",$2/1024}' /proc/meminfo)"; avail="$(awk '/MemAvailable:/ {printf "%d",$2/1024}' /proc/meminfo)"
echo "Pre-update RAM: ${ram} MiB total, ${avail} MiB available"
backup="$($APP_DIR/scripts/backup.sh | tail -1 | sed 's/^Backup: //')"
old_id="$(docker image inspect -f '{{.Id}}' nousresearch/hermes-agent:latest 2>/dev/null || true)"
rollback_tag="hermes-agent:rollback-$(date +%Y%m%d-%H%M%S)"
if [[ -n "$old_id" ]]; then docker tag "$old_id" "$rollback_tag"; echo "$rollback_tag" > "$APP_DIR/.rollback-image"; fi
docker compose -f "$APP_DIR/compose/docker-compose.yml" --env-file "$APP_DIR/.env" config >/dev/null
docker compose -f "$APP_DIR/compose/docker-compose.yml" --env-file "$APP_DIR/.env" pull
docker compose -f "$APP_DIR/compose/docker-compose.yml" --env-file "$APP_DIR/.env" up -d --remove-orphans
sleep 8
running="$(docker inspect -f '{{.State.Running}}' hermes 2>/dev/null || echo false)"
if [[ "$running" != true ]]; then
  echo "Update failed. Previous image tag: ${rollback_tag:-none}" >&2
  echo "Backup: $backup" >&2
  exit 1
fi
echo "Update successful. Backup: $backup"
EOF

cat >"${SCRIPTS_DIR}/rollback.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
APP_DIR="/opt/hermes-agent"; cd "$APP_DIR"
[[ -f "$APP_DIR/.rollback-image" ]] || { echo "No rollback image recorded."; exit 1; }
rollback_tag="$(cat "$APP_DIR/.rollback-image")"
docker image inspect "$rollback_tag" >/dev/null 2>&1 || { echo "Rollback image not available: $rollback_tag"; exit 1; }
echo "Rolling back Hermes image to $rollback_tag"
docker tag "$rollback_tag" nousresearch/hermes-agent:latest
docker compose -f "$APP_DIR/compose/docker-compose.yml" --env-file "$APP_DIR/.env" up -d --force-recreate
sleep 8
docker inspect -f 'state={{.State.Status}} running={{.State.Running}} image={{.Config.Image}}' hermes
echo "Image rollback complete. Data backup restoration is intentionally separate to avoid accidental data loss."
echo "Available backups: $APP_DIR/backups/"
EOF

cat >"${SCRIPTS_DIR}/uninstall.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
APP_DIR="/opt/hermes-agent"
[[ -d "$APP_DIR" ]] || { echo "Hermes installation not found."; exit 0; }
echo "Only the Hermes deployment created by this installer will be removed."
echo "Docker, Apache, 9Router, 3x-ui, Mirza, MasterDNSVPN and unrelated services remain untouched."
read -r -p "Create final backup? [Y/n]: " ans
[[ "$ans" =~ ^[Nn]$ ]] || "$APP_DIR/scripts/backup.sh"
read -r -p "Remove Hermes container and /opt/hermes-agent? [y/N]: " ans
[[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]] || exit 0
docker compose -f "$APP_DIR/compose/docker-compose.yml" --env-file "$APP_DIR/.env" down --remove-orphans || true
rm -rf "$APP_DIR"
echo "Hermes removed; unrelated services were untouched."
EOF
chmod 700 "${SCRIPTS_DIR}"/*.sh
}

write_readme_local(){
cat >"${APP_DIR}/README.md" <<'EOF'
# Hermes Agent Minimal Docker Deployment

This deployment uses the official `nousresearch/hermes-agent` image.

Official guidance: 1 GiB RAM for core without browser, 2 GiB when browser automation is active, 1 CPU minimum, and 500 MiB data disk minimum.

The deployment does not modify Apache or ports 80/443 and does not touch unrelated services.
EOF
}

pull_image(){
  log "Pulling official Hermes image..."
  docker pull "$IMAGE"
  docker run --rm "$IMAGE" version || true
  ok "Official image ready."
}

start_core(){
  log "Starting Hermes core/gateway..."
  docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" config >/dev/null
  docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d
  sleep 8
  docker ps --filter "name=^/hermes$" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
  if ! docker inspect -f '{{.State.Running}}' hermes 2>/dev/null | grep -q true; then
    docker logs --tail 120 hermes 2>&1 || true
    return 1
  fi
  ok "Hermes gateway container is running."
}

dashboard_stage(){
  local r mode url cid u pw hash
  r="$(ram_mb)"
  echo
  echo "Dashboard / داشبورد رسمی Hermes"
  echo "Official minimum: 1 GiB RAM. Public Internet requires authentication."
  (( r < MIN_RAM_MB )) && { warn "Current RAM ${r} MiB < 1 GiB; dashboard remains disabled."; return 0; }
  echo "A) Disabled"
  echo "B) Nous Portal OAuth (recommended for public Internet; requires HTTPS public URL + client ID)"
  echo "C) Basic Auth (not recommended for direct public Internet)"
  (( NON_INTERACTIVE )) && return 0
  read -r -p "Choose [A/B/C]: " mode
  case "${mode^^}" in
    B)
      read -r -p "Public HTTPS URL: " url
      read -r -p "OAuth client ID: " cid
      [[ "$url" =~ ^https:// ]] || { warn "HTTPS URL required."; return 0; }
      [[ -n "$cid" ]] || { warn "Client ID required."; return 0; }
      upsert_env "HERMES_DASHBOARD=1"
      upsert_env "HERMES_DASHBOARD_HOST=0.0.0.0"
      upsert_env "DASHBOARD_PORT=$DASHBOARD_PORT"
      upsert_env "HERMES_DASHBOARD_PUBLIC_URL=$url"
      upsert_env "HERMES_DASHBOARD_OAUTH_CLIENT_ID=$cid"
      write_compose
      docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d
      ok "OAuth dashboard enabled."
      ;;
    C)
      warn "Hermes does not recommend direct public Basic Auth exposure. Prefer OAuth/OIDC."
      read -r -p "Bind dashboard to 0.0.0.0 on port [$DASHBOARD_PORT]? [y/N]: " mode
      [[ "$mode" =~ ^[Yy]$ ]] || return 0
      read -r -p "Basic Auth username: " u
      read -r -s -p "Basic Auth password: " pw; echo
      [[ -n "$u" && -n "$pw" ]] || { warn "Username/password required."; return 0; }
      hash="$(docker run --rm "$IMAGE" python -c "from plugins.dashboard_auth.basic import hash_password; print(hash_password(${pw@Q}))" 2>/dev/null || true)"
      [[ -n "$hash" ]] || { warn "Could not generate Hermes password hash."; return 1; }
      upsert_env "HERMES_DASHBOARD=1"
      upsert_env "HERMES_DASHBOARD_HOST=0.0.0.0"
      upsert_env "DASHBOARD_PORT=$DASHBOARD_PORT"
      upsert_env "HERMES_DASHBOARD_BASIC_AUTH_USERNAME=$u"
      upsert_env "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=$hash"
      upsert_env "HERMES_DASHBOARD_BASIC_AUTH_SECRET=$(openssl rand -base64 32 | tr -d '\n')"
      write_compose
      docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d
      warn "Direct public Basic Auth is not the recommended Internet-facing configuration."
      ;;
  esac
}

browser_stage(){
  local r; r="$(ram_mb)"
  echo
  echo "Browser automation / اتوماسیون مرورگر"
  echo "Official guidance: at least 2 GiB RAM when browser tools are active."
  if (( r < BROWSER_RAM_MB )); then
    warn "Current RAM: ${r} MiB < official browser minimum: ${BROWSER_RAM_MB} MiB."
    info "Playwright/Chromium remain available in the official image but actual browser use may OOM this VPS."
    return 0
  fi
  ok "Browser tooling is available in the official image."
}

provider_stage(){
cat <<'EOF'

Model/provider setup / تنظیم مدل

Hermes is NOT locked to 9Router.
Supported choices include Nous Portal, OpenRouter and OpenAI-compatible custom endpoints such as 9Router.
Configure provider/model settings in:
  /opt/hermes-agent/data/config.yaml

Fallback providers can be configured there according to the current Hermes release documentation.
Never put API keys in GitHub.
EOF
}

main(){
  require_root
  exec 9>"$LOCK_FILE"; flock -n 9 || die "Another Hermes installer operation is already running."
  case "${1:-}" in
    -h|--help) usage; exit 0;;
    --non-interactive) NON_INTERACTIVE=1;;
    "") :;;
    *) die "Unknown argument: $1";;
  esac

  log "Hermes Minimal Docker Installer"
  info "Official image: $IMAGE"
  info "No Apache changes. No port 80/443 changes."
  info "9Router, 3x-ui, Mirza, MasterDNSVPN and unrelated services are not modified."

  show_resources
  if (( $(ram_mb) < MIN_RAM_MB )); then
    if ! confirm "Proceed with UNSUPPORTED core installation for testing?"; then
      echo "Stopped. No Hermes installation was made."; exit 0
    fi
  fi

  ensure_docker
  ensure_compose
  prepare_dirs
  load_existing_env
  write_env
  write_readme_local
  write_helpers
  pull_image
  write_compose
  start_core || die "Core stage failed. Check $SCRIPTS_DIR/healthcheck.sh"

  log "Core stage complete."
  show_resources
  if (( ! NON_INTERACTIVE )); then
    dashboard_stage
    show_resources
    browser_stage
    provider_stage
  fi

  printf '\n============================================================\n'
  echo "Installation summary / خلاصه نصب"
  echo "============================================================"
  echo "Data:       $DATA_DIR"
  echo "Compose:    $COMPOSE_FILE"
  echo "Env:        $ENV_FILE"
  echo "Dashboard:  $(grep -q '^HERMES_DASHBOARD=' "$ENV_FILE" 2>/dev/null && echo enabled || echo disabled)"
  echo "Browser:    official image tooling retained; no persistent browser service"
  echo "Apache:     untouched"
  echo
  ok "Hermes deployment prepared successfully."
}

main "$@"
