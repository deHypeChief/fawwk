# Changelog

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
