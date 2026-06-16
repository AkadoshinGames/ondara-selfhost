#!/usr/bin/env bash
# Ondara Self-Hosted Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/AkadoshinGames/ondara-selfhost/main/install.sh | bash
set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

INSTALL_DIR="${ONDARA_DIR:-${HOME}/ondara}"
COMPOSE_URL="https://raw.githubusercontent.com/AkadoshinGames/ondara-selfhost/main/docker-compose.yml"
DOCS_URL="https://docs.ondara.co/en/self-hosting"
CONSOLE_URL="https://console.ondara.cloud"

# ─── Logo ─────────────────────────────────────────────────────────────────────
print_logo() {
  echo ""
  echo -e "${CYAN}${BOLD}"
  echo "  ██████╗ ███╗   ██╗██████╗  █████╗ ██████╗  █████╗ "
  echo " ██╔═══██╗████╗  ██║██╔══██╗██╔══██╗██╔══██╗██╔══██╗"
  echo " ██║   ██║██╔██╗ ██║██║  ██║███████║██████╔╝███████║"
  echo " ██║   ██║██║╚██╗██║██║  ██║██╔══██║██╔══██╗██╔══██║"
  echo " ╚██████╔╝██║ ╚████║██████╔╝██║  ██║██║  ██║██║  ██║"
  echo "  ╚═════╝ ╚═╝  ╚═══╝╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝"
  echo -e "${NC}"
  echo -e " ${BOLD}Game Backend Platform${NC} · Self-Hosted Installer"
  echo -e " ${DIM}${DOCS_URL}${NC}"
  echo ""
}

# ─── Helpers ─────────────────────────────────────────────────────────────────
info()    { echo -e " ${CYAN}→${NC} $*"; }
success() { echo -e " ${GREEN}✓${NC} $*"; }
warn()    { echo -e " ${YELLOW}⚠${NC} $*"; }
error()   { echo -e " ${RED}✗${NC} $*" >&2; exit 1; }
step()    { echo ""; echo -e " ${BOLD}$*${NC}"; echo -e " ${DIM}$(printf '─%.0s' {1..50})${NC}"; }

# ─── Requirements ─────────────────────────────────────────────────────────────
check_requirements() {
  step "Checking requirements"

  # Docker
  if ! command -v docker &>/dev/null; then
    warn "Docker not found. Installing via get.docker.com..."
    curl -fsSL https://get.docker.com | sh
    if ! getent group docker | grep -q "\b${USER}\b"; then
      sudo usermod -aG docker "$USER"
      warn "Added $USER to the docker group. You may need to log out and back in."
    fi
  fi
  success "Docker $(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)"

  # Docker Compose v2
  if ! docker compose version &>/dev/null; then
    error "Docker Compose v2 is required. Please update Docker Desktop or install the Compose plugin."
  fi
  success "Docker Compose $(docker compose version --short 2>/dev/null || echo 'v2')"

  # openssl for secret generation
  if ! command -v openssl &>/dev/null; then
    warn "openssl not found — secrets will use /dev/urandom fallback"
  fi
}

# ─── Directory setup ──────────────────────────────────────────────────────────
setup_directory() {
  step "Setting up installation directory"
  info "Installing to: ${INSTALL_DIR}"
  mkdir -p "${INSTALL_DIR}"
  cd "${INSTALL_DIR}"
  success "Directory ready"
}

# ─── Download docker-compose ──────────────────────────────────────────────────
download_compose() {
  step "Downloading service configuration"

  if [ -f docker-compose.yml ]; then
    warn "docker-compose.yml already exists — backing up to docker-compose.yml.bak"
    cp docker-compose.yml docker-compose.yml.bak
  fi

  if curl -fsSL "${COMPOSE_URL}" -o docker-compose.yml; then
    success "docker-compose.yml downloaded"
  else
    warn "Could not reach GitHub. Generating minimal docker-compose.yml..."
    cat > docker-compose.yml << 'COMPOSE'
services:
  # The merged data-plane: data + economy surfaces on one app + one DB, port 8080.
  data-plane:
    image: ghcr.io/akadoshin/ondara-services/data-plane:latest
    restart: unless-stopped
    ports: ["8080:8080"]
    environment:
      - DEPLOYMENT_MODE=selfhosted
      - APP_PORT=8080
      - ONDARA_LICENSE_KEY=${ONDARA_LICENSE_KEY}
      - LICENSE_PUBLIC_KEY=${LICENSE_PUBLIC_KEY:-}
      - M2M_SECRET=${M2M_SECRET}
      - DB_HOST=postgres
      - DB_PORT=5432
      - DB_USER=ondara
      - DB_PASSWORD=${DB_PASSWORD:-ondara_selfhosted}
      - DB_NAME=ondara_dataplane
      - REDIS_HOST=redis
      - REDIS_PORT=6379
      # Player session JWT keypair (RS256) — REQUIRED in self-hosted mode.
      - PLAYER_JWT_PRIVATE_KEY=${PLAYER_JWT_PRIVATE_KEY}
      - PLAYER_JWT_PUBLIC_KEY=${PLAYER_JWT_PUBLIC_KEY}
      - API_KEY_PUBLIC_KEY=${API_KEY_PUBLIC_KEY:-}
      - API_KEY_REVOCATION_POLL_SECONDS=${API_KEY_REVOCATION_POLL_SECONDS:-60}
      - CORS_ORIGINS=${CORS_ORIGINS:-https://console.example.com}
    depends_on: [postgres, redis]

  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: ondara
      POSTGRES_PASSWORD: ${DB_PASSWORD:-ondara_selfhosted}
      POSTGRES_DB: ondara_dataplane
    volumes: [pgdata:/var/lib/postgresql/data]

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    command: redis-server --maxmemory 128mb --maxmemory-policy allkeys-lru
    volumes: [redis-data:/data]

volumes:
  pgdata:
  redis-data:
COMPOSE
    success "Minimal docker-compose.yml created"
  fi
}

# ─── Configuration (.env) ─────────────────────────────────────────────────────
gen_secret() {
  if command -v openssl &>/dev/null; then
    openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32
  else
    head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32
  fi
}

configure_env() {
  step "Configuration"

  if [ -f .env ]; then
    warn ".env already exists — skipping configuration."
    warn "Delete .env and re-run to reconfigure."
    return
  fi

  echo ""
  echo -e " Get your license key at: ${CYAN}${CONSOLE_URL}${NC}"
  echo -e " (Free plan available — 1,000 MAU included)"
  echo ""
  printf " License key: "
  read -r LICENSE_KEY

  if [ -z "${LICENSE_KEY}" ]; then
    warn "No license key entered. Running in dev mode (no license validation)."
    LICENSE_KEY="dev"
  fi

  DB_PASS=$(gen_secret)
  M2M_SECRET=$(gen_secret)

  # Player session JWT keypair (RS256). The data-plane signs AND verifies player
  # tokens in-process and REQUIRES a private key in self-hosted (production) mode,
  # so generate one keypair up front. Needs openssl; warn and leave blank otherwise.
  PLAYER_JWT_PRIVATE_KEY=""
  PLAYER_JWT_PUBLIC_KEY=""
  if command -v openssl &>/dev/null; then
    PLAYER_JWT_PRIVATE_KEY=$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null)
    PLAYER_JWT_PUBLIC_KEY=$(printf '%s' "${PLAYER_JWT_PRIVATE_KEY}" | openssl pkey -pubout 2>/dev/null)
    success "Generated player session JWT keypair"
  else
    warn "openssl not found — could not generate the player JWT keypair."
    warn "Generate one and set PLAYER_JWT_PRIVATE_KEY / PLAYER_JWT_PUBLIC_KEY in .env,"
    warn "or the data-plane will refuse to serve the player surface."
  fi

  # These variable names must match what docker-compose.yml consumes:
  # ONDARA_LICENSE_KEY, M2M_SECRET, DB_PASSWORD, CORS_ORIGINS,
  # PLAYER_JWT_PRIVATE_KEY, PLAYER_JWT_PUBLIC_KEY.
  cat > .env << EOF
# Ondara Self-Hosted — generated $(date '+%Y-%m-%d %H:%M')
# Edit this file to customize your installation.

# ── License ───────────────────────────────────────────
ONDARA_LICENSE_KEY=${LICENSE_KEY}

# ── Database password (auto-generated, keep safe) ─────
# Used by Postgres and the data-plane.
DB_PASSWORD=${DB_PASS}

# ── Internal service auth (auto-generated) ────────────
M2M_SECRET=${M2M_SECRET}

# ── Player session JWT keypair (auto-generated, RS256) ─
# One keypair: the data-plane both signs and verifies player tokens in-process.
PLAYER_JWT_PRIVATE_KEY="${PLAYER_JWT_PRIVATE_KEY}"
PLAYER_JWT_PUBLIC_KEY="${PLAYER_JWT_PUBLIC_KEY}"

# ── Browser CORS ──────────────────────────────────────
# Set to your console origin. "*" is for local dev ONLY.
CORS_ORIGINS=https://console.example.com
EOF

  chmod 600 .env
  success ".env created with auto-generated secrets"
}

# ─── Start services ───────────────────────────────────────────────────────────
start_services() {
  step "Starting services"

  info "Pulling images..."
  docker compose pull --quiet 2>/dev/null || warn "Could not pull images — will use local or cached versions"

  info "Starting containers..."
  docker compose up -d

  info "Waiting for services to be ready..."
  sleep 8

  # Health check — port is fixed by docker-compose.yml (8080).
  DATA_PLANE_PORT=8080

  if curl -sf "http://localhost:${DATA_PLANE_PORT}/health" &>/dev/null; then
    success "Data Plane healthy"
  else
    warn "Data Plane may still be starting — check with: docker compose logs data-plane"
  fi
}

# ─── Done ─────────────────────────────────────────────────────────────────────
print_done() {
  # Port is fixed by docker-compose.yml (8080).
  DATA_PLANE_PORT=8080

  echo ""
  echo -e " ${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e " ${GREEN}${BOLD}  Ondara is running!${NC}"
  echo -e " ${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "  ${CYAN}Data Plane${NC}  http://localhost:${DATA_PLANE_PORT}   ${DIM}(data + economy)${NC}"
  echo ""
  echo -e "  ${DIM}Quick test:${NC}"
  echo -e "  ${YELLOW}curl -H 'X-API-Key: YOUR_KEY' http://localhost:${DATA_PLANE_PORT}/health${NC}"
  echo ""
  echo -e "  ${DIM}Manage:${NC}"
  echo -e "  ${YELLOW}docker compose -f ${INSTALL_DIR}/docker-compose.yml ps${NC}"
  echo -e "  ${YELLOW}docker compose -f ${INSTALL_DIR}/docker-compose.yml logs -f${NC}"
  echo ""
  echo -e "  ${DIM}Docs:${NC} ${CYAN}${DOCS_URL}${NC}"
  echo -e "  ${DIM}Console:${NC} ${CYAN}${CONSOLE_URL}${NC}"
  echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  print_logo
  check_requirements
  setup_directory
  download_compose
  configure_env
  start_services
  print_done
}

main "$@"
