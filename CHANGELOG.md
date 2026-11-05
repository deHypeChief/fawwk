# Changelog

## Unreleased

### New

- **Dockerfile builds get build-time env without `ARG` lines,** as on Coolify: Fawwk declares each
  build-time variable in every stage but the last (the last stage ships, and BuildKit records build
  args in the image's history), skipping ones a stage already declares. Vite's `VITE_*` values and
  similar now reach `npm run build` / `bun run build`, and Dockerfiles written for Coolify work as they are.
- **`doctor` tells a stale DNS cache from a missing record:** when this server's lookup fails but public
  DNS (what visitors and Let's Encrypt use) already points here, it clears the cache
  (`resolvectl flush-caches`) and says so, instead of "doesn't resolve yet".

### Fixed

- `fawwk github connect` sent GitHub an invalid app manifest ("The manifest is not valid JSON") on
  bash 5.2 and newer (Ubuntu 24.04): bash 5.2 made `&` in a string replacement mean the matched text,
  which turned the HTML-escaped `&quot;` into `"quot;`. Fawwk now turns that bash behaviour off.

### Changed

- Tests that can't run where they are (no Docker daemon, no railpack...) report `skip`, not `ok`.

## 0.3.0

### Upgrading from 0.2

```bash
sudo fawwk update
```

`update` runs the new post-update step itself. It installs Railpack, and keeps Nixpacks for apps that
already deployed with it, so nothing changes how an existing app builds. To post deploy status on
commits, a GitHub App connected before 0.3 needs one extra permission (see below).

### New

- **Managed databases:** `fawwk db create <name> --type postgres|redis|mongodb [--link <app>]`. Each
  runs in its own container on the private Fawwk network (no published ports), with a random password
  and a Docker volume. `--link` / `fawwk db link` sets `DATABASE_URL`, `REDIS_URL` or `MONGODB_URL` on an
  app. Also `info`, `url`, `shell` (psql / redis-cli / mongosh), `start|stop|restart`, `logs`, `remove`.
  - **Backups:** nightly at 03:17 (`fawwk db schedule HH:MM|off`), keeping the last 7
    (`DB_KEEP_BACKUPS`); `fawwk db backup <name>` on demand. They're logical (`pg_dump`, a Redis
    snapshot, `mongodump`), and a failed nightly backup sends a notification.
  - **Versions:** Postgres 17, Redis 7, MongoDB 7.0 by default (`--version` picks another). MongoDB 8
    builds refuse to start on Linux kernel 6.19+ (SERVER-121912), so Fawwk checks an 8.x choice
    against the kernel before starting it, and `doctor` flags one a kernel upgrade would stop.
  - **Restore:** `fawwk db restore <name> <file|latest>` replaces the contents exactly, after taking a
    safety backup.
  - **Integration:** `fawwk backup --with-data` includes a fresh backup of every database, `restore`
    lists the steps to bring them back, and `doctor` checks each database and the age of its last backup.
- **Railpack** is the builder for repos without a Dockerfile (Nixpacks is in maintenance mode). It
  builds through Docker's own BuildKit, with build-time env as BuildKit secrets that never end up in
  the image. `fawwk build <app> railpack` switches an app that's still on Nixpacks.
- **Deploy status on GitHub:** each deploy shows on its commit as `fawwk/<app>`: pending, then a check
  mark linking to the app, or a cross saying what failed. New GitHub connections ask for the permission.
  For one connected earlier, add "Commit statuses: Read and write" in its settings; the deploy output
  links there. `fawwk github statuses off` turns it off.
- **Multi-line env values** (PEM keys, certificates): quoted values may span lines in pasted or imported
  .env text, `fawwk env <app> set KEY="$(cat key.pem)"` works, and `fawwk env <app> set-file KEY <file>`
  reads a file. They reach the container, the build and release commands exactly as written.

### Changed

- Builders get env variable names and read the values from their environment, so values no longer
  appear on `docker build` / `nixpacks` command lines.
- `fawwk env <app> edit` writes values that need it in quotes, so a value containing ` #` or starting
  with a quote survives an edit unchanged. Before, the value was cut at the ` #` or lost its quote.
- `setup` no longer installs Nixpacks on new servers.

### Fixed

- `doctor` crashed on a config without `SETUP_AT` or `SERVER_IP`.

## 0.2.0

### Upgrading from 0.1.0

```bash
sudo fawwk update
sudo fawwk post-update     # once: 0.1's updater doesn't know this step yet
sudo fawwk proxy upgrade   # optional: move the proxy to the pinned Caddy image (a few seconds' pause)
```

If `fawwk update` says `Not possible to fast-forward` (servers installed before `main`'s history was
rewritten on 2026-11-04), update by hand once, then continue with `post-update`:

```bash
sudo git -C /opt/fawwk fetch origin main && sudo git -C /opt/fawwk reset --hard FETCH_HEAD
```

### New

- **Volumes:** `fawwk volume <app> add /app/data` keeps a folder across deploys, restarts and rollbacks.
- **Release commands:** `fawwk release <app> "npm run migrate"` runs in the new image before it gets
  traffic. A failure stops the deploy, and the current version stays live.
- **Cron jobs:** `fawwk cron <app> add "0 3 * * *" <command>` runs commands inside the app's container.
- **Resource limits:** `fawwk limits <app> memory=512m cpus=1`. Deploys and `doctor` report when an
  app is killed for running out of memory.
- **Notifications:** `fawwk notify <url> [--all]` sends automated-deploy and cron failures to Slack,
  Discord or any webhook.
- **Change an app after create:** `fawwk branch`, `fawwk folder`, `fawwk repo`, `fawwk access`.
- **Build-time env control:** `fawwk buildenv <app> KEY,KEY | none | all`.
- **Per-app health check timeout:** `fawwk health <app> /health --timeout 180`.
- **Backup and restore:** `fawwk backup [--with-data]` and `fawwk restore <file>` cover settings, apps,
  env vars, keys, GitHub connections, cron jobs, certificates and (optionally) volumes.
- `fawwk cleanup`, `fawwk uninstall`, `fawwk deploy --all`, `fawwk proxy upgrade`.
- `--json` for `list`, `info` and `history`.
- `create` flags: `--volume`, `--release`, `--memory`, `--cpus`, `--token-user`.
- `fawwk version` shows the git commit too.
- `fawwk update --branch <branch>` tries another branch (e.g. a pull request) and switches back.

### Fixed

- `fawwk update` (and re-running `install.sh`) failed with "Not possible to fast-forward" once the
  published branch's history had been rewritten. Updates now follow the branch whatever its history,
  after saving a copy of any local edits to Fawwk's files and asking before discarding them.
- `fawwk doctor` said "Everything looks good" right after printing warnings (e.g. DNS not set up).

- A webhook and the every-minute timer could deploy the same push twice. App state is now re-read
  after taking the app's lock, and an automated deploy is skipped if the app is already at that commit.
  The same lock-then-reload applies to restart, stop, start, rollback, env, domain and port.
- `fawwk doctor` recommended `docker system prune -a`, which deletes the images kept for rollback. It
  now points to `fawwk cleanup`.
- Deploy ids only went down to the second: a restart and a deploy in the same second could remove the
  live container. Ids now end in a random suffix.
- Commands that deliberately exit non-zero (showing usage, answering "No") printed a false
  "Fawwk stopped unexpectedly" report.
- `route_normalize` lowercased URL paths (`example.com/API` became `/api`); only hostnames are
  lowercased now.
- `env unset` and `domain rm` treated their input as a regex (`.` matched any character).
- Changing the panel subdomain with `setup --panel` silently broke GitHub webhooks. Setup now updates
  each connected GitHub App's webhook URL.
- GitHub App installs that took more than a few minutes could time out on an expired token.
- `install.sh` could wipe a folder like `/opt` if `FAWWK_PREFIX` was mistyped.
- Token access on Bitbucket (app passwords need the real username).
- The deploy summary said certificates are issued "on the first visit"; Caddy requests them right away.

### Hardening and housekeeping

- App containers run with `no-new-privileges` and a process limit.
- Webhook receiver ([#1](https://github.com/deHypeChief/fawwk/pull/1)): runs as `nobody` with
  `no-new-privileges` and a process limit, drops connections that stall for 10s, handles at most 8
  requests at once, caps bodies at 4 MiB (also enforced by Caddy), and no longer rejects every webhook
  when one secret file is unreadable. It's recreated automatically after an update.
- Webhook receiver: each GitHub delivery is queued once, even when GitHub retries or redelivers it.
- The Caddy images are pinned (`caddy:2.10.2`, `caddy:2.10.2-alpine`).
- Disk use stays flat: old build logs, untagged layers and week-old build cache are removed after each
  deploy; Fawwk's logs rotate weekly; fresh Docker installs cap container logs and the build cache.
- `doctor` also checks: stale IPv6 (`AAAA`) records, the proxy image, log rotation, notifications, a
  stuck webhook queue.
- A test suite (`tests/run.sh`, including an end-to-end deploy against a stub Docker) and GitHub
  Actions CI running it alongside ShellCheck.

## 0.1.0

First release: `setup`, guided `create`, zero-downtime deploys behind Caddy with automatic HTTPS,
GitHub App integration with push webhooks, env management, rollback, `doctor`.
