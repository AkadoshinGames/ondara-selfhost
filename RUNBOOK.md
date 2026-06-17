# Ondara Self-Hosted — Operator Runbook

Operations procedures for a self-hosted Ondara **data plane** (`docker compose` stack from
`install.sh` / `docker-compose.yml`). Read the [README](./README.md) first for what the
stack is and how it boots.

All commands run from your **install directory** (default `~/ondara`, or wherever you
pointed `ONDARA_DIR`). The `.env` there is `0600` and holds every secret the installer
generated — treat it as the source of truth and back it up offline.

> **Admin is cloud-console only.** There is no self-hosted admin panel and no
> browser-exposed secrets. Account, license, and **API keys** are managed *exclusively* at
> [console.ondara.cloud](https://console.ondara.cloud). Nothing in this runbook obtains or
> rotates API keys — that happens in the console (see
> [API keys](#api-keys-cloud-console-only)).

---

## Stack at a glance

| Service | Port | Image | State |
|---|---|---|---|
| `data-plane` | `8080:8080` | `ghcr.io/akadoshin/ondara-services/data-plane:latest` | stateless (state lives in Postgres + Redis) |
| `postgres` | internal only | `postgres:16-alpine` | volume `pgdata`, DB `ondara_dataplane`, user `ondara` |
| `redis` | internal only | `redis:7-alpine` | volume `redis-data`, `--maxmemory 128mb --maxmemory-policy allkeys-lru` |

Postgres and Redis sit on the `internal: true` network and are **never published to the
host**, so all DB/Redis operations go *through* the `data-plane`/`postgres`/`redis`
containers (`docker compose exec`), not via a host port.

The `data-plane` itself is stateless: it can be recreated freely. Your durable state is
**`pgdata`** (everything that matters) plus your **`.env`** (the secrets to read it).

---

## Backup & restore

### What holds what

- **Postgres (`pgdata`, DB `ondara_dataplane`)** — the **authoritative store**. Player
  accounts, data records, and the economy (currencies, balances, transactions) all live
  here. This is what you must back up.
- **Redis (`redis-data`)** — **ephemeral cache only**, capped at 128 MB with
  `allkeys-lru` eviction (so it already discards entries under pressure). It holds
  cache/transient data, not a source of truth. **It does not need to be backed up** — on
  restore it repopulates from Postgres. (`redis-data` is persisted only so a container
  restart keeps a warm cache.)
- **`.env`** — not data, but the secrets (`DB_PASSWORD`, `M2M_SECRET`, `PLAYER_JWT_*`,
  `ONDARA_LICENSE_KEY`). A `pgdata` backup is useless without the matching `DB_PASSWORD`,
  and existing player sessions are unverifiable without the matching `PLAYER_JWT_PUBLIC_KEY`.
  Back it up **separately and encrypted**.

### Back up Postgres

A logical dump with `pg_dump` is the simplest portable backup. Postgres is not published,
so run it inside the container:

```bash
# from your install dir
docker compose exec -T postgres \
  pg_dump -U ondara -d ondara_dataplane --format=custom \
  > "ondara_dataplane_$(date +%Y%m%d_%H%M%S).dump"
```

Notes:
- `-T` disables TTY allocation so the dump streams cleanly to the host file.
- `--format=custom` produces a compressed, `pg_restore`-friendly archive.
- The dump is consistent without stopping the service; no downtime needed.
- For a plain SQL dump instead, drop `--format=custom` and the file will be SQL text.

Verify the dump is non-empty and keep it (plus your `.env`) off-box.

### Restore Postgres

Restore into a running `postgres` container. This **overwrites** the target objects, so do
it into a fresh stack or after confirming you want to replace current data.

```bash
# bring up only the datastore first (data-plane can stay down during restore)
docker compose up -d postgres

# custom-format archive (recommended)
docker compose exec -T postgres \
  pg_restore -U ondara -d ondara_dataplane --clean --if-exists \
  < ondara_dataplane_YYYYMMDD_HHMMSS.dump

# OR, for a plain SQL dump:
# docker compose exec -T postgres psql -U ondara -d ondara_dataplane < backup.sql

# then start the rest
docker compose up -d
```

The restoring `postgres` must use the **same `DB_PASSWORD`** as the dump's stack, so
restore your `.env` first (or set `DB_PASSWORD` to match). After the data-plane starts it
applies any pending schema migrations automatically (golang-migrate), so a dump from an
older image version is upgraded forward on first boot — restore the data, then `up -d`.

### Disaster recovery (rebuild from scratch)

1. Reinstall the recipe (`install.sh` or `git clone` + `cp .env.example .env`).
2. **Restore your saved `.env`** (do not let the installer generate new secrets — new
   `PLAYER_JWT_*` would invalidate every existing player session, and a new `DB_PASSWORD`
   would not match your dump).
3. `docker compose up -d postgres`, restore the dump (above).
4. `docker compose up -d` — migrations auto-run, Redis warms from Postgres.
5. Health check (below).

---

## Rotating self-hosted secrets

These are the secrets the installer generated into `.env`. They are **distinct from API
keys**, which are not stored here and are rotated only in the cloud console.

All rotations follow the same shape: **edit `.env` → `docker compose up -d`** (Compose
recreates the `data-plane` because its environment changed; no separate restart command is
needed). Take a `.env` backup before editing.

### `DB_PASSWORD`

`DB_PASSWORD` is consumed by **both** Postgres (as `POSTGRES_PASSWORD`) and the data-plane.
Postgres only reads `POSTGRES_PASSWORD` when it **initializes an empty `pgdata`** — it does
*not* change an existing role's password on restart. So editing `.env` alone will leave the
data-plane unable to connect. Rotate in two steps:

```bash
# 1. change the actual Postgres role password (while the old one still works)
docker compose exec postgres \
  psql -U ondara -d ondara_dataplane \
  -c "ALTER USER ondara WITH PASSWORD 'NEW_STRONG_PASSWORD';"

# 2. put the same value in .env, then recreate so the data-plane uses it
#    (set DB_PASSWORD=NEW_STRONG_PASSWORD in .env)
docker compose up -d
```

Generate a strong value with `openssl rand -base64 32`. Brief data-plane reconnect blip
only; no data loss. Postgres is internal-only, so this is low-exposure — rotate on staff
changes or on a schedule.

### `M2M_SECRET`

Internal service-auth secret. It has **no default** — an empty value keeps the management
API closed and the data-plane refuses to start without it. Pure data-plane env, so a
straight edit + recreate:

```bash
# set M2M_SECRET=<openssl rand -base64 32> in .env
docker compose up -d
```

No DB impact. The data-plane restarts; existing **player** sessions and API keys are
unaffected (different mechanisms).

### Player JWT keypair (`PLAYER_JWT_PRIVATE_KEY` / `PLAYER_JWT_PUBLIC_KEY`)

One RS256 keypair that the data-plane uses to **sign and verify player session tokens
in-process**. Generate a fresh pair:

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out player_jwt.pem
openssl pkey -in player_jwt.pem -pubout -out player_jwt.pub
# paste the full multi-line PEMs into PLAYER_JWT_PRIVATE_KEY / PLAYER_JWT_PUBLIC_KEY in .env
docker compose up -d
```

> **Rotating the player keypair invalidates all in-flight player sessions.** Existing
> player tokens were signed by the old private key; once the new public key is the only one
> the data-plane verifies against, those tokens fail verification and every logged-in
> player must re-authenticate (the SDK re-acquires a session). There is no dual-key grace
> window — rotation is a hard cutover. Plan it for a maintenance window or low-traffic
> period, and only rotate this key if you suspect the private key was exposed (or on a
> deliberate, communicated schedule). Quote the multi-line PEMs in `.env` exactly as the
> installer does.

---

## API keys (cloud-console only)

API keys are **not** a self-hosted secret and are **not** in `.env`. They are created,
listed, and revoked **only** at [console.ondara.cloud](https://console.ondara.cloud) — the
single admin surface. The data-plane just *verifies* them, online against
`CONTROL_PLANE_URL` (default `https://cp.ondara.cloud`) or offline against
`API_KEY_PUBLIC_KEY`.

To rotate an API key: create a new key in the console, ship it to your game/SDK clients,
then revoke the old one in the console. **No data-plane restart is required.** Revocations
take effect immediately in online mode, or within `API_KEY_REVOCATION_POLL_SECONDS`
(default `60`) in offline mode.

---

## Updating the license (`ONDARA_LICENSE_KEY`)

The license is a Control-Plane-signed RS256 JWT (starts with `eyJ`), verified **offline,
in-process** against a public key pinned in the data-plane binary — it never phones home,
and there is no verify-key override. To install a new license (renewal, plan change, MAU
bump):

```bash
# get the new key from console.ondara.cloud, set ONDARA_LICENSE_KEY=eyJ... in .env
docker compose up -d
```

The data-plane re-reads and re-verifies the license on boot; a malformed or wrong-signature
token makes it refuse to start (check logs). No DB or session impact.

---

## Upgrading the image

```bash
docker compose pull        # fetch the latest published data-plane (+ pinned pg/redis) images
docker compose up -d        # recreate changed containers; schema migrations auto-run
```

Schema migrations are applied automatically by the data-plane on startup (golang-migrate),
so upgrades are pull-and-up — no manual migration step. Recommended: take a Postgres dump
(above) **before** `pull` so you can roll back if a migration surprises you. To pin a
specific version instead of `:latest`, set the image tag in `docker-compose.yml` and
`up -d`.

---

## Health checks

`/health` is an **unauthenticated liveness probe** — it ignores `X-API-Key` and returns
`200` whenever the process is up. It is *not* an API-key validity check.

```bash
# host (data-plane is published on 8080)
curl -fsS http://localhost:8080/health

# container's own healthcheck status
docker compose ps                       # STATUS column shows (healthy)/(unhealthy)
docker inspect --format '{{.State.Health.Status}}' "$(docker compose ps -q data-plane)"
```

The compose healthchecks: `data-plane` probes `/health` (15s interval, 5s timeout, 3
retries, 10s start period); `postgres` uses `pg_isready -U ondara -d ondara_dataplane`;
`redis` uses `redis-cli ping`. `data-plane` only starts after both datastores report
healthy (`depends_on … condition: service_healthy`).

To confirm an **API key** works (vs. mere liveness), hit an authenticated endpoint — a
valid `secret` key returns `200`, a missing/invalid/revoked key returns `401`:

```bash
curl -H 'X-API-Key: YOUR_SECRET_KEY' http://localhost:8080/api/v1/currencies
```

---

## Logs

Logs go to the containers' stdout/stderr, read via Compose (Docker's default `json-file`
driver persists them on the host until the container is removed):

```bash
docker compose logs -f data-plane       # follow the app
docker compose logs --since 1h data-plane
docker compose logs postgres            # DB startup / migration-time errors
docker compose logs redis
docker compose logs                     # all services
```

What to look for:
- **Startup/license**: license verification failure or a missing `M2M_SECRET` / player key
  shows up as the data-plane refusing to start — check `docker compose logs data-plane`.
- **Migrations**: golang-migrate applies pending migrations on data-plane boot; failures
  surface in the data-plane log right after start.
- **DB connectivity**: a `DB_PASSWORD` mismatch (e.g. after a half-done rotation) shows as
  the data-plane failing to connect to `postgres`.

For long-running hosts, consider configuring Docker log rotation
(`max-size`/`max-file` log options) so `json-file` logs don't grow unbounded.

---

## Quick reference

| Task | Command (from install dir) | Restart? | Session impact |
|---|---|---|---|
| Backup DB | `docker compose exec -T postgres pg_dump -U ondara -d ondara_dataplane --format=custom > f.dump` | no | none |
| Restore DB | `pg_restore -U ondara -d ondara_dataplane --clean --if-exists < f.dump` | data-plane down during restore | restored state |
| Rotate `DB_PASSWORD` | `ALTER USER` + edit `.env` + `up -d` | data-plane recreate | none |
| Rotate `M2M_SECRET` | edit `.env` + `up -d` | data-plane recreate | none |
| Rotate player keypair | new PEMs in `.env` + `up -d` | data-plane recreate | **all player sessions invalidated** |
| Update license | edit `.env` + `up -d` | data-plane recreate | none |
| Upgrade image | `pull` + `up -d` | changed containers | none (migrations auto-run) |
| Rotate API key | **cloud console** (create → ship → revoke) | none | per-key, no restart |
| Health | `curl http://localhost:8080/health` | — | — |

Full guide: **https://docs.ondara.co/en/self-hosting**
