# Ondara — Self-Hosted

Run the [Ondara](https://ondara.co) game backend (data plane) on your own infrastructure.

This repo is the **deploy recipe only** — `install.sh` + `docker-compose.yml`. The service
runs from a published image (`ghcr.io/akadoshin/ondara-services/data-plane`); no source here.

## Requirements

- A Linux host with **Docker** + **Docker Compose v2**
- A **license key** from [console.ondara.cloud](https://console.ondara.cloud) (free tier available)
- `openssl` (the installer auto-generates your secrets)

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/AkadoshinGames/ondara-selfhost/main/install.sh | bash
```

The installer checks Docker, downloads the compose file, generates your DB password,
M2M secret and player-token keypair, asks for your license key, and starts the stack.

## Manual install

```bash
cp .env.example .env
# Edit .env:
#   ONDARA_LICENSE_KEY=...        (from the console)
#   M2M_SECRET=$(openssl rand -base64 32)
#   PLAYER_JWT_PRIVATE_KEY / _PUBLIC_KEY   (openssl recipe in .env.example)
docker compose up -d
curl http://localhost:8080/health
```

Then put a reverse proxy + TLS (Caddy / nginx) in front, and point your Unity
`OndaraConfig` base URL at your domain.

## What runs

| Service | Port | Image |
|---|---|---|
| data-plane (game API) | 8080 | `ghcr.io/akadoshin/ondara-services/data-plane` |
| postgres | — | `postgres:16-alpine` |
| redis | — | `redis:7-alpine` |

## How it works

- **License**: verified offline, in-process (RS256) — never phones home.
- **API keys**: created in the cloud console, verified against the Control Plane
  (`CONTROL_PLANE_URL=https://cp.ondara.cloud`) or fully offline with `API_KEY_PUBLIC_KEY`.
- **Player tokens**: the data-plane signs + verifies them in-process with your keypair.

Full guide: **https://docs.ondara.co/en/self-hosting**
