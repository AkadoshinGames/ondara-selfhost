# Changelog

All notable changes to ondara-selfhost are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

This repo is the **deploy recipe only** — `install.sh`, `docker-compose.yml`, and
`.env.example`. The data-plane runs from a published image
(`ghcr.io/akadoshin/ondara-services/data-plane`); there is no service source here.

## [Unreleased]

### Added

- **Self-host deploy recipe.** Initial `install.sh` + `docker-compose.yml` +
  `.env.example` + `README`, pulling the published
  `ghcr.io/akadoshin/ondara-services/data-plane` image. Three containers: the
  data-plane on `:8080` plus internal-only Postgres and Redis. golang-migrate
  runs automatically on boot.

### Changed

- **Installer requires a real license (fail-fast).** `install.sh` no longer
  writes `ONDARA_LICENSE_KEY=dev` — the data-plane rejects that in self-hosted
  mode and refuses to boot, so the installer now aborts if no license is
  provided. The generated `.env` now includes `CONTROL_PLANE_URL`,
  `API_KEY_PUBLIC_KEY`, and the revocation poll setting.
- Self-host guide rewritten to match `install.sh` and the compose file: the
  installer flow, the pinned license key, console-only admin (no self-hosted
  panel, no browser secrets), online vs. offline API-key verification, and
  automatic golang-migrate on boot.

### Fixed

- `/health` curl uses no auth; corrected secret entropy generation, container
  network isolation, and the default license claims documented in the README.
