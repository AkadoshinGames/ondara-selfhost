# Ondara — Self-Hosted

Run the [Ondara](https://ondara.co) game backend (the **data plane**) on your own
infrastructure.

This repo is the **deploy recipe only** — `install.sh`, `docker-compose.yml`, and
`.env.example`. The service runs from a published image
(`ghcr.io/akadoshin/ondara-services/data-plane`); there is no source here.

## Admin model (read this first)

Self-host runs the **data plane only**. There is **no self-hosted admin panel and no
browser-exposed secrets**. The **cloud console** at
[console.ondara.cloud](https://console.ondara.cloud) is the *only* admin surface — you
manage your account, license, and API keys there. Games and tooling talk to your
self-hosted data plane **through the SDK** using an API key.

Your cloud Control Plane keeps issuing your **license** and **API keys**; your self-hosted
data plane just serves the game API and verifies those credentials (offline or online).

## Requirements

- A Linux host with **Docker** + **Docker Compose v2** (the installer can install Docker
  for you via `get.docker.com`).
- A **license key** from [console.ondara.cloud](https://console.ondara.cloud) (free tier
  available — 1,000 MAU included).
- `openssl` — used to auto-generate your secrets and the player-token keypair. If it is
  missing, secrets fall back to `/dev/urandom` and you must supply the player keypair
  yourself.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/AkadoshinGames/ondara-selfhost/main/install.sh | bash
```

The installer:

1. Checks Docker + Compose v2 (installs Docker if absent) and `openssl`.
2. Creates the install directory — `~/ondara` by default, override with `ONDARA_DIR`.
3. Downloads `docker-compose.yml` (falls back to an inlined minimal copy if GitHub is
   unreachable).
4. Prompts for your **license key** (only this is asked interactively).
5. Auto-generates `DB_PASSWORD`, `M2M_SECRET`, and the **player JWT keypair**, then writes
   a `0600` `.env`.
6. Pulls images and runs `docker compose up -d`, then health-checks
   `http://localhost:8080/health`.

If `.env` already exists, configuration is skipped — delete it and re-run to reconfigure.

## Manual install

```bash
cp .env.example .env
# Edit .env — see "Required env / secrets" below.
docker compose up -d
curl http://localhost:8080/health
```

Then put a reverse proxy + TLS (Caddy / nginx) in front of port 8080, set
`CORS_ORIGINS`, and point your Unity `OndaraConfig` base URL at your domain.

## What runs

The compose stack starts **three services** on **two networks** (`public` is bridged;
`internal` is `internal: true`, so Postgres/Redis are never published to the host):

| Service | Published port | Image | Notes |
|---|---|---|---|
| `data-plane` (game API: data + economy) | `8080:8080` | `ghcr.io/akadoshin/ondara-services/data-plane:latest` | one app, one DB (`ondara_dataplane`); healthchecked on `/health` |
| `postgres` | none (internal only) | `postgres:16-alpine` | DB `ondara_dataplane`, user `ondara`; volume `pgdata` |
| `redis` | none (internal only) | `redis:7-alpine` | `--maxmemory 128mb --maxmemory-policy allkeys-lru`; volume `redis-data` |

Volumes: `pgdata`, `redis-data`. The Control Plane is **not** part of self-host — it stays
in Ondara's cloud.

> Note: the inlined fallback compose in `install.sh` (used only when GitHub is
> unreachable) publishes the same `8080` port, the same two networks
> (`public` bridged, `internal` `internal: true`), and defaults to **online**
> API-key verification via `CONTROL_PLANE_URL=https://cp.ondara.cloud` — exactly like
> the downloaded `docker-compose.yml`. It is a trimmed copy, though: it omits the
> per-service healthchecks and CPU/memory `deploy` limits. For **offline** verification,
> set `API_KEY_PUBLIC_KEY` in `.env` (empty by default = online).

## Required env / secrets

| Var | Required | What it is |
|---|---|---|
| `ONDARA_LICENSE_KEY` | yes | RS256 JWT license from the console (starts with `eyJ`). Verified offline, in-process — never phones home. |
| `M2M_SECRET` | yes | Internal service-auth secret. **No default** — the data plane refuses to start without it and keeps its management API closed when empty. Generate with `openssl rand -base64 32`. |
| `PLAYER_JWT_PRIVATE_KEY` / `PLAYER_JWT_PUBLIC_KEY` | yes | One RS256 keypair the data plane uses to **sign and verify** player session tokens in-process. Required in self-host (production) mode. |
| `DB_PASSWORD` | recommended | Postgres password (default `ondara_selfhosted` — change it). Used by both Postgres and the data plane. |
| `CORS_ORIGINS` | recommended | Comma-separated browser origins (your console/game). This compose recipe defaults it to `https://console.example.com` (the image's own default is `http://localhost:3023`). `*` is for local dev ONLY. |
| `CONTROL_PLANE_URL` | optional | Online API-key verification endpoint. This compose recipe defaults it to `https://cp.ondara.cloud` (the image's own default is `http://localhost:8080`), so a manual `docker run` without this compose needs it set explicitly. |
| `API_KEY_PUBLIC_KEY` | optional | RS256 **public** half for **offline** API-key verification (air-gapped; no round-trip). |
| `API_KEY_REVOCATION_POLL_SECONDS` | optional | Revocation-list refresh interval (default `60`). |

Generate a player keypair manually:

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out player_jwt.pem
openssl pkey -in player_jwt.pem -pubout -out player_jwt.pub
# paste the full multi-line PEMs into PLAYER_JWT_PRIVATE_KEY / PLAYER_JWT_PUBLIC_KEY
```

## How licensing & auth work

- **License**: a Control-Plane-signed RS256 JWT. The data plane verifies it offline,
  in-process, against a public key **pinned in its binary** (no env override). No phone-home.
- **API keys** (how your game/SDK authenticates to the data plane): created in the cloud
  console, tied to your account. The data plane verifies them either:
  - **online** — `CONTROL_PLANE_URL=https://cp.ondara.cloud` (round-trip per key, cached), or
  - **offline / air-gapped** — `API_KEY_PUBLIC_KEY=<CP API-key public key>` (no round-trip);
    revocations sync every `API_KEY_REVOCATION_POLL_SECONDS`.
- **Player tokens**: signed and verified in-process by the data plane with your
  `PLAYER_JWT_*` keypair.

## Obtaining & rotating API keys

1. Create an API key in [console.ondara.cloud](https://console.ondara.cloud) (the only
   admin surface).
2. Put it in your game/SDK via `OndaraConfig` (sent as `X-API-Key`). Never embed it in a
   browser.
3. **Rotate**: create a new key in the console, ship it to clients, then revoke the old
   one. Revocations take effect immediately in online mode, or within
   `API_KEY_REVOCATION_POLL_SECONDS` in offline mode. No data-plane restart needed.

Test that a key is valid by hitting an **authenticated** endpoint (a `secret` key
returns `200`; a missing/invalid/revoked key returns `401`):

```bash
curl -H 'X-API-Key: YOUR_SECRET_KEY' http://localhost:8080/api/v1/currencies
```

`/health` is an **unauthenticated** liveness probe — it ignores `X-API-Key` and always
returns `200` while the process is up, so it is not a key-validity check.

## Operate & upgrade

```bash
# from your install dir (default ~/ondara)
docker compose ps
docker compose logs -f data-plane

# upgrade to the latest published image
docker compose pull
docker compose up -d            # DB schema migrations run automatically on start

# rotate the DB password / M2M secret: edit .env, then
docker compose up -d
```

Schema migrations are applied automatically by the data plane on startup (golang-migrate),
so upgrades are pull-and-up.

Full guide: **https://docs.ondara.co/en/self-hosting**
