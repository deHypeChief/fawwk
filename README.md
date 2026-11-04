# Fawwk

Deploy GitHub repos to Docker containers on your own Ubuntu server, with automatic HTTPS.
One command prepares the server; one guided command turns a repo into a live app.

```
sudo fawwk setup      # once per server
sudo fawwk create     # once per app: repo → domain → env → live
git push              # redeploys automatically within a minute
```

## How it works

```
             ┌────────────────────────── your Ubuntu server ──────────────────────────┐
 browser ──► │ Caddy (fawwk-proxy) :80/:443 ──► fawwk-web-…  (example.com)             │
             │   auto HTTPS, routes by        ──► fawwk-api-…  (api.example.com,      │
             │   domain and path                                  example.com/api)     │
             │                                                                         │
             │ fawwk-autodeploy.timer ── every minute: new commit? → build → swap      │
             └─────────────────────────────────────────────────────────────────────────┘
```

- **Proxy:** [Caddy](https://caddyserver.com) runs in a container, gets and renews Let's Encrypt
  certificates, and routes each domain or path to the right app container. App containers are never
  exposed to the internet directly.
- **Builds:** a `Dockerfile` in the repo is used if present (any casing, e.g. `DOCKERFILE`). Before building,
  Fawwk checks that every file it `COPY`s is actually in the repo (a missing lock file is the usual culprit). A plain static site (`index.html`, no
  `package.json`) is served by Caddy. Anything else (Node, Python, Go, Ruby, PHP...) is auto-detected
  with [Nixpacks](https://nixpacks.com).
- **Zero-downtime deploys:** an optional release command (e.g. migrations) runs in the new image first,
  then the new container must answer HTTP on its port before traffic moves to it. If either fails, the
  old version stays live and the error plus logs are shown.
- **Auto-deploy:** with GitHub connected (below), every push deploys within seconds through a webhook.
  A systemd timer also checks each repo's branch every minute, for other git hosts and as a backup.
  A commit that failed to deploy isn't retried until you push again. When a webhook and the timer fire
  for the same push, it's deployed once. Failures can notify Slack, Discord or any webhook URL.

## Install

On a fresh Ubuntu 22.04/24.04 server:

```bash
curl -fsSL https://raw.githubusercontent.com/deHypeChief/fawwk/main/install.sh | sudo bash -s -- --setup
```

This clones Fawwk to `/opt/fawwk`, links the `fawwk` command, and starts `setup`. Leave off
`-s -- --setup` to install without running setup. Update later with `sudo fawwk update`.

`setup` asks for:

| Question | Example | Used for |
| --- | --- | --- |
| Main domain | `example.com` | default app URLs: `<app>.example.com` |
| Email | `you@example.com` | Let's Encrypt certificate notices |
| Panel subdomain | `panel` | reserved for the upcoming web panel |

It installs Docker, Caddy, Nixpacks, UFW (opens only SSH, 80, 443), fail2ban, cron, log rotation for
Fawwk's logs, and a 2GB swap file on servers with under ~4GB RAM. On a fresh Docker install it also caps
container logs and the build cache (`/etc/docker/daemon.json`). Then it shows the DNS records to create:

```
A    example.com     <server ip>
A    *.example.com   <server ip>
```

With the wildcard record in place, every new app subdomain works without touching DNS again. Don't
leave a stale `AAAA` (IPv6) record on those names: Let's Encrypt prefers IPv6, so certificates would
fail. `fawwk doctor` warns about it.

## Connect GitHub (recommended)

```bash
sudo fawwk github connect            # your account
sudo fawwk github connect --org acme # or an organization
```

This creates a private **GitHub App** owned by you, in one click: open the link Fawwk prints, click
**Create GitHub App**, then choose which repos it may access and click **Install**. After that:

- Repos with the app installed need no deploy keys or tokens. Fawwk gets a 1-hour, read-only token for
  one repo each time it fetches code.
- Every push deploys within seconds. GitHub sends a signed webhook to `https://panel.<domain>/hooks/github`.
- Several GitHub accounts or orgs? Run `connect` once for each (log in to the other account first).

```bash
fawwk github                 # connected accounts and the repos each can reach
fawwk github install         # add or remove repos
fawwk github remove <name>   # forget a connection
```

It needs `panel.<domain>` to point to this server (the wildcard DNS record covers it). Webhooks are
received by a small, locked-down container (`fawwk-hooks`) that only checks signatures and queues jobs;
the deploy itself runs on the host.

## Deploy an app

```bash
sudo fawwk create
```

The guided flow asks for:

1. **Repo:** `https://github.com/you/app` or just `you/app`. If the connected GitHub App is installed on
   it, that's all. Otherwise, for a private repo, Fawwk offers to connect GitHub, a read-only **deploy
   key** for you to paste into GitHub, or a personal access token.
2. **Branch:** defaults to the repo's default branch.
3. **Folder:** for monorepos, e.g. `apps/web`.
4. **Domains:** `app.example.com`, `example.com`, `example.com/api`, several at once, or `none` for a
   background worker. Path routes strip the prefix by default (`/api/users` reaches the app as `/users`).
5. **Port:** what the app listens on. It's also passed in as `PORT`, so apps that read `$PORT` just work.
6. **Health check path:** optional, e.g. `/health`.
7. **Env vars:** paste your whole `.env` and press Ctrl-D. If the repo has a `.env.example`, Fawwk then
   asks for each variable you haven't set.
8. **Auto-deploy:** on by default.

Everything can be passed as flags for scripting:

```bash
sudo fawwk create api --repo you/api --domain "api.example.com example.com/api" \
  --port 8000 --health /health --env-file ./api.env --deploy-key \
  --volume /app/data --release "npm run migrate" --memory 512m --yes
```

For Bitbucket, add `--token-user <username>` to `--token-file` (app passwords need the real username).

## Everyday commands

```bash
fawwk list [--json]                 # all apps, state, URL
fawwk info api [--json]             # details, CPU/RAM, limits, last failure
fawwk deploy api                    # pull + rebuild + zero-downtime swap (--all: every app)
fawwk logs api -f                   # follow app logs
fawwk logs api --build              # last build log
fawwk history api [--json]          # recent deploys
fawwk rollback api [deploy-id]      # back to the previous (or a given) version
fawwk restart | stop | start api
fawwk exec api                      # shell inside the container

fawwk env api                       # list vars (masked); --reveal to show values
fawwk env api set KEY=value         # then offers a zero-downtime restart
fawwk env api unset KEY
fawwk env api import [file]         # merge a .env file, or paste one
fawwk env api edit                  # open in $EDITOR
fawwk env api check                 # compare with .env.example

fawwk domain api add api2.example.com
fawwk domain api rm example.com/api
fawwk port api 8080
fawwk health api /healthz --timeout 180   # path, and how long a new version gets to boot
fawwk autodeploy api off
fawwk build api nixpacks            # build method: auto | dockerfile | nixpacks | static
fawwk buildenv api NEXT_PUBLIC_URL  # only these env vars reach the build (all | none | KEY,KEY)

fawwk doctor                        # server, DNS and app health check
fawwk proxy config | reload | logs | upgrade
fawwk remove api
```

All commands need root (`sudo`).

### Change what an app deploys

```bash
fawwk branch api develop            # deploy another branch
fawwk folder api apps/api           # another folder of a monorepo
fawwk repo api you/new-api          # another repo (checks access first)
fawwk access api deploykey          # switch access: github | deploykey | token | public
```

Each one checks the change works before saving it, then offers to redeploy.

### Persistent data (volumes)

Every deploy starts a fresh container, so anything an app writes to disk is lost unless it lives in a
volume:

```bash
fawwk volume api add /app/data      # kept across deploys, restarts and rollbacks
fawwk volume api                    # list volumes, sizes and where they live on the server
fawwk volume api rm /app/data       # stop mounting it (add --delete-data to delete it too)
```

During a zero-downtime deploy, the old and new container both mount the volume for a few seconds. That's
fine for uploads and caches. For SQLite, use WAL mode, or run a real database as its own app.

### Release commands (migrations)

```bash
fawwk release api "npm run migrate"   # or: python manage.py migrate, bin/rails db:migrate...
fawwk release api off
```

The command runs on every deploy, in a one-off container from the new image with the app's env and
volumes, before the new version gets any traffic. If it fails, the deploy stops and the current version
stays live. The image needs `sh`.

### Cron jobs

```bash
fawwk cron api add "*/15 * * * *" node scripts/sync.js
fawwk cron api add @daily npm run cleanup
fawwk cron api                      # list jobs
fawwk cron api run 1                # run job 1 now
fawwk cron api rm 1
```

Jobs run inside the live container (`docker exec`), in the server's time zone. A job is skipped while
its previous run is still going. Output goes to `/var/log/fawwk/<app>-cron.log`, and a failed job
sends a notification if those are on.

### Resource limits

```bash
fawwk limits api memory=512m cpus=1
fawwk limits api memory=off
```

Without limits, one leaking app can use all the server's memory and take the others (and the proxy)
down with it. If an app is killed for going over its memory limit, `fawwk doctor` and the deploy output
say so.

### Notifications

```bash
fawwk notify https://hooks.slack.com/services/...   # failures of automated deploys and cron jobs
fawwk notify https://discord.com/api/webhooks/... --all   # every automated deploy
fawwk notify test
fawwk notify off
```

The JSON body works with Slack and Discord incoming webhooks. It also carries `app`, `status`,
`commit` and `host` fields for anything else.

### Disk space, backups, updates

```bash
fawwk cleanup                       # old images and build logs, untagged layers, build cache
fawwk backup [file] [--with-data]   # settings, apps, env vars, keys, GitHub connections, certificates
fawwk restore backup.tar.gz         # on a new server, then: fawwk setup --yes && fawwk deploy --all
fawwk update                        # update Fawwk (also refreshes timers, log rotation, webhooks)
fawwk update --branch <branch>      # try another branch, e.g. a pull request; --branch main to go back
fawwk uninstall [--delete-data]     # remove Fawwk and its apps; Docker stays
```

After each deploy, Fawwk keeps the last 20 build logs per app (`KEEP_LOGS`) and removes untagged image
layers and build cache older than a week. Tagged images, which rollback needs, are kept. A backup
contains secrets, so store it somewhere safe. `--with-data` copies volumes as they are, so stop busy
databases first for a consistent copy.

## Terminal UI

Output reads like a transcript: each step (`●`) has its results hanging under it (`⎿`), long work shows
a spinner with the live build line, and questions collapse to one answered line once you reply. Choices
are arrow-key menus (`↑/↓` or `j/k`, Enter; a number or the first letter also works).

| Variable | Effect |
| --- | --- |
| `FAWWK_THEME=mint` | default: mint and violet. Also `ocean`, `ember`, `mono` |
| `NO_COLOR=1` | no colours |
| `FAWWK_ASCII=1` | plain ASCII symbols, for terminals without Unicode |

Run `sudo` with `-E`, or set the variable after it (`sudo FAWWK_THEME=ocean fawwk list`).
When output isn't a terminal (auto-deploy logs, pipes), colours, spinners and menus switch off.

## Files on the server

| Path | What |
| --- | --- |
| `/opt/fawwk` | Fawwk itself (`/usr/local/bin/fawwk` links here) |
| `/etc/fawwk/fawwk.conf` | server settings from `setup` (and `notify`) |
| `/etc/fawwk/apps/<app>/` | `app.conf`, `env`, deploy key or token, `history`, `cron` (root-only, mode 600) |
| `/etc/fawwk/github/<app-slug>/` | connected GitHub Apps: `app.conf` and private key (root-only) |
| `/var/lib/fawwk/hooks/` | webhook secrets and the queue of push events |
| `/etc/fawwk/caddy/Caddyfile` | generated proxy config; add your own blocks in `custom/*.caddy` |
| `/var/lib/fawwk/apps/<app>/` | git checkout and build logs |
| `/var/log/fawwk/` | auto-deploy logs (`sync.log`, `hooks.log`, `<app>.log`, `<app>-cron.log`), rotated weekly |
| `/etc/cron.d/fawwk-<app>` | generated from `fawwk cron` |
| Docker volumes `fawwk_<app>_*` | app volumes; `fawwk_caddy_data` holds HTTPS certificates |

## Security notes

- App containers run with `no-new-privileges` and a process limit, so `sudo` inside an app container
  won't work. They're only reachable through Caddy and are never published on a host port.
- Env vars are passed to the build by default (Next.js `NEXT_PUBLIC_*` and similar need them), which
  bakes them into the locally stored image. Limit that with `fawwk buildenv <app> KEY,KEY` or `none`.
- The webhook receiver runs as `nobody` in its own read-only container with no capabilities, and limits
  what one client can tie up: 10s socket timeout, 8 requests at once, 4 MiB bodies. It only checks
  signatures and queues jobs: it has no access to Docker, app secrets or the shell.
- Docker-published ports bypass UFW. Fawwk only publishes 80 and 443 (the proxy). If you run other
  containers with `-p`, UFW won't protect those ports.
- The proxy image is pinned (`CADDY_IMAGE`). Servers set up before 0.2 can switch to it with
  `fawwk proxy upgrade`.

## Notes and limits

- One server, one container per app. `docker-compose` multi-service apps aren't supported yet. Use a
  Dockerfile per service and create one app for each.
- Multi-line env values aren't supported; put `\n` inside a single line instead.
- The last 3 images per app are kept for rollback (`KEEP_IMAGES`).
- Nixpacks, used for repos without a Dockerfile, is in maintenance mode upstream. For anything
  non-trivial, a Dockerfile gives you the most control.

## Development

```bash
sudo tests/run.sh            # the whole suite (sandboxed: stub docker, temp dirs)
sudo tests/run.sh pipeline   # tests whose name matches
shellcheck bin/fawwk lib/*.sh install.sh tests/run.sh
```

CI runs both on every push and pull request (`.github/workflows/ci.yml`).

## Roadmap

- Web panel at `panel.<domain>`
- Managed Postgres/Redis with scheduled backups
- docker-compose apps, preview deploys per branch
- Deploy status reported back to GitHub
