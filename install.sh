#!/usr/bin/env bash
# Ondara Self-Hosted Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/AkadoshinGames/ondara-selfhost/main/install.sh | bash
set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

INSTALL_DIR="${ONDARA_DIR:-${HOME}/ondara}"

# Pin the fetched compose to an IMMUTABLE ref (a git tag), not the mutable `main`
# branch — so `curl | bash` can't be silently re-pointed at a different file after
# this installer ships. Override with ONDARA_REF=<tag-or-commit> to test a newer ref.
ONDARA_REF="${ONDARA_REF:-v1.0.0}"
COMPOSE_URL="https://raw.githubusercontent.com/AkadoshinGames/ondara-selfhost/${ONDARA_REF}/docker-compose.yml"
# SHA-256 of the docker-compose.yml at ${ONDARA_REF}. The download is verified against
# this digest before use; a mismatch aborts the install (supply-chain integrity).
# This MUST match the docker-compose.yml AT THE TAGGED REF (${ONDARA_REF}), NOT the
# working tree — so do not update it for un-released edits to docker-compose.yml.
# Regenerate when CUTTING A RELEASE, after tagging, with: shasum -a 256 docker-compose.yml
# Set ONDARA_COMPOSE_SHA256=skip to bypass (NOT recommended; e.g. local-ref testing).
COMPOSE_SHA256="${ONDARA_COMPOSE_SHA256:-f215246a399b5f7fe220d70eec1eee26b55d8d1de50dbd330c01bbca443fdf96}"
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

# Print the SHA-256 of a file (sha256sum on Linux, shasum -a 256 on macOS).
sha256_of() {
  if command -v sha256sum &>/dev/null; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum &>/dev/null; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo ""  # no tool available
  fi
}

# ─── Requirements ─────────────────────────────────────────────────────────────
check_requirements() {
  step "Checking requirements"

  # Docker
  if ! command -v docker &>/dev/null; then
    # We do NOT silently pipe a third-party script into a shell. get.docker.com is the
    # vendor's official, frequently-updated installer, so a static checksum here would
    # constantly drift; instead we make installing it an explicit opt-in. Operators who
    # want a pinned/verified Docker should install it via their distro package manager.
    if [ "${ONDARA_INSTALL_DOCKER:-}" != "1" ]; then
      error "Docker is not installed. Install it first (your distro package manager, or Docker Desktop), then re-run.\n   To let this script install it from the official https://get.docker.com convenience script, re-run with ONDARA_INSTALL_DOCKER=1.\n   (That script is fetched over HTTPS straight from Docker, but is not pinned/checksummed — review https://get.docker.com before trusting it.)"
    fi
    warn "Installing Docker via the official get.docker.com convenience script (ONDARA_INSTALL_DOCKER=1)..."
    curl -fsSL https://get.docker.com | sh
    if ! getent group docker | grep -q "\b${USER}\b"; then
      sudo usermod -aG docker "$USER"
      warn "Added $USER to the docker group."
    fi
  fi
  success "Docker $(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)"

  # The docker-group membership added above only takes effect in a NEW login session.
  # If we can't reach the daemon socket in THIS shell, do not soldier on into
  # `docker compose pull/up` (they'd fail with a confusing permission-denied mid-install).
  # Re-exec under the new group if `sg` is available; otherwise tell the user to re-login.
  if ! docker info &>/dev/null; then
    if [ -z "${ONDARA_REEXECED:-}" ] && [ -f "$0" ] && command -v sg &>/dev/null && getent group docker | grep -q "\b${USER}\b"; then
      warn "Re-running under the 'docker' group so the new membership takes effect..."
      export ONDARA_REEXECED=1
      # This installer takes no positional args (config is env/interactive), so re-exec
      # the script itself under the docker group. ONDARA_REEXECED guards against a loop.
      exec sg docker -c "$(printf '%q' "$0")"
    fi
    error "Cannot talk to the Docker daemon as '${USER}' yet. The docker-group membership only applies to a NEW login session.\n   Log out and back in (or run 'newgrp docker'), then re-run this installer.\n   (If Docker is installed but not running, start it first: 'sudo systemctl start docker'.)"
  fi

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

  if curl -fsSL "${COMPOSE_URL}" -o docker-compose.yml.dl; then
    # Verify the download against the pinned SHA-256 before trusting it. The URL is
    # already pinned to an immutable ref (${ONDARA_REF}); this digest check catches a
    # tampered mirror / MITM / a re-pointed tag.
    if [ "${COMPOSE_SHA256}" = "skip" ]; then
      warn "Compose checksum verification SKIPPED (ONDARA_COMPOSE_SHA256=skip)."
      mv docker-compose.yml.dl docker-compose.yml
      success "docker-compose.yml downloaded (unverified)"
    else
      GOT_SHA="$(sha256_of docker-compose.yml.dl)"
      if [ -z "${GOT_SHA}" ]; then
        rm -f docker-compose.yml.dl
        error "No sha256sum/shasum available to verify the download. Install coreutils or re-run with ONDARA_COMPOSE_SHA256=skip to bypass (not recommended)."
      elif [ "${GOT_SHA}" != "${COMPOSE_SHA256}" ]; then
        rm -f docker-compose.yml.dl
        error "docker-compose.yml checksum MISMATCH — refusing to continue.\n   expected ${COMPOSE_SHA256}\n   got      ${GOT_SHA}\n   The file at ${COMPOSE_URL} does not match the pinned release. Aborting."
      fi
      mv docker-compose.yml.dl docker-compose.yml
      success "docker-compose.yml downloaded and checksum-verified (${ONDARA_REF})"
    fi
  else
    rm -f docker-compose.yml.dl
    warn "Could not reach GitHub. Generating minimal docker-compose.yml..."
    cat > docker-compose.yml << 'COMPOSE'
services:
  # The merged data-plane: data + economy surfaces on one app + one DB, port 8080.
  data-plane:
    # Pinned to an immutable release tag (matches the Pi) — never :latest.
    image: ghcr.io/akadoshin/ondara-services/data-plane:1.0.0
    restart: unless-stopped
    # Bound to LOOPBACK by default — plain HTTP, no in-process TLS. Put a TLS reverse
    # proxy in front. To expose on all interfaces (behind a proxy/LB), use "8080:8080".
    ports: ["127.0.0.1:8080:8080"]
    environment:
      - DEPLOYMENT_MODE=selfhosted
      - APP_PORT=8080
      - ONDARA_LICENSE_KEY=${ONDARA_LICENSE_KEY}
      # API keys you create in the cloud console are verified against the Control Plane.
      - CONTROL_PLANE_URL=${CONTROL_PLANE_URL:-https://cp.ondara.cloud}
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
      # Optional offline API-key verification (RS256 PUBLIC half) — no round-trip.
      - API_KEY_PUBLIC_KEY=${API_KEY_PUBLIC_KEY:-}
      - API_KEY_REVOCATION_POLL_SECONDS=${API_KEY_REVOCATION_POLL_SECONDS:-60}
      - CORS_ORIGINS=${CORS_ORIGINS:-https://console.example.com}
    depends_on: [postgres, redis]
    networks: [public, internal]

  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    # Modest tuning so the planner uses the economy/leaderboard indexes and sorts stay
    # in RAM (stock 16-alpine under-sizes effective_cache_size). See RUNBOOK.md.
    command: ["postgres","-c","shared_buffers=64MB","-c","effective_cache_size=192MB","-c","work_mem=8MB"]
    environment:
      POSTGRES_USER: ondara
      POSTGRES_PASSWORD: ${DB_PASSWORD:-ondara_selfhosted}
      POSTGRES_DB: ondara_dataplane
    volumes: [pgdata:/var/lib/postgresql/data]
    networks: [internal]

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    command: redis-server --maxmemory 128mb --maxmemory-policy allkeys-lru
    volumes: [redis-data:/data]
    networks: [internal]

volumes:
  pgdata:
  redis-data:

networks:
  public:
    driver: bridge
  internal:
    driver: bridge
    internal: true
COMPOSE
    success "Minimal docker-compose.yml created"
  fi
}

# ─── Configuration (.env) ─────────────────────────────────────────────────────
gen_secret() {
  # 32 random bytes (~256 bits). Strip non-alnum so the value is safe to drop into
  # .env unquoted (no /, +, = to escape) but keep the FULL length — do NOT truncate,
  # so the entropy matches the documented `openssl rand -base64 32` recipe.
  if command -v openssl &>/dev/null; then
    openssl rand -base64 32 | tr -dc 'a-zA-Z0-9'
  else
    head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9'
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
    error "A license key is required. Self-hosted mode verifies an offline RS256 JWT license and refuses to start without one. Get a free key (1,000 MAU included) at ${CONSOLE_URL}"
  fi

  # Fail fast at install time: a self-hosted JWT license is a JWS compact token
  # and always starts with "eyJ". The data-plane rejects anything else at boot,
  # so catch a mistyped/placeholder value here instead of in a restart loop.
  case "${LICENSE_KEY}" in
    eyJ*) ;;
    *) error "Invalid license key. It must be an offline JWT license token (it starts with \"eyJ\"). Copy it from ${CONSOLE_URL}" ;;
  esac

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
  # PLAYER_JWT_PRIVATE_KEY, PLAYER_JWT_PUBLIC_KEY, and the optional
  # CONTROL_PLANE_URL, API_KEY_PUBLIC_KEY, API_KEY_REVOCATION_POLL_SECONDS.
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

# ── API-key verification (optional) ───────────────────
# Online verification endpoint for API keys you create in the console.
# Defaults to https://cp.ondara.cloud when unset.
# CONTROL_PLANE_URL=https://cp.ondara.cloud
#
# For offline / air-gapped verification instead, set the Control Plane's
# RS256 API-key PUBLIC key (PEM). When empty, keys are verified online.
# API_KEY_PUBLIC_KEY=
#
# How often (seconds) the local revocation list refreshes. Default 60.
# API_KEY_REVOCATION_POLL_SECONDS=60
EOF

  chmod 600 .env
  success ".env created with auto-generated secrets"
}

# ─── Start services ───────────────────────────────────────────────────────────
start_services() {
  step "Starting services"

  # The canonical compose references REMOTE-ONLY ghcr images with no `build:` context,
  # so a failed pull on a first install means there is nothing local to fall back to and
  # `up -d` would fail later with a misleading error. Treat a pull failure as fatal
  # UNLESS the data-plane image is already present locally (a re-install / cached host).
  info "Pulling images..."
  if ! docker compose pull --quiet; then
    DP_IMAGE="$(docker compose config --images 2>/dev/null | grep 'data-plane' | head -1)"
    if [ -n "${DP_IMAGE}" ] && docker image inspect "${DP_IMAGE}" &>/dev/null; then
      warn "Could not pull images — falling back to the locally cached ${DP_IMAGE}."
    else
      error "Could not pull the Ondara images and none are cached locally.\n   Check your network / GitHub Container Registry access and re-run.\n   (These images are pull-only — there is no local build fallback.)"
    fi
  fi

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
  echo -e "  ${DIM}Quick test (liveness probe — no auth needed):${NC}"
  echo -e "  ${YELLOW}curl http://localhost:${DATA_PLANE_PORT}/health${NC}"
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
