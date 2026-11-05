# Fawwk

Deploy GitHub repos to Docker containers on your own Ubuntu server, with automatic HTTPS.
One command prepares the server; one guided command turns a repo into a live app.

```
sudo fawwk setup      # once per server
sudo fawwk create     # once per app: pick the repo, branch and folder → domain → env → live
git push              # redeploys in seconds (GitHub connected), or within a minute
```

## How it works

![How Fawwk works: visitors reach Caddy, which serves HTTPS and routes each domain or path to an app container; apps reach their private, nightly backed-up databases; a GitHub push reaches fawwk-hooks, which builds, runs the release command, health-checks the new version and swaps traffic to it with zero downtime; a timer checks every minute as a backup.](docs/architecture.png)

<sub>Source: [`docs/architecture.svg`](docs/architecture.svg). Edit it, then render the PNG at 2× (for example with a headless browser).</sub>

- **Proxy:** [Caddy](https://caddyserver.com) runs in a container, gets and renews Let's Encrypt
  certificates, and routes each domain or path to the right app container. App containers are never
  exposed to the internet directly.
- **Builds:** a `Dockerfile` in the repo is used if present (any casing, e.g. `DOCKERFILE`). Before building,
  Fawwk checks that every file it `COPY`s is actually in the repo (a missing lock file is the usual culprit).
  Env vars reach the build without `ARG` lines in the Dockerfile: Fawwk adds them, as Coolify does, so
  Vite's `VITE_*` and similar build-time values work and Coolify Dockerfiles move over unchanged. A plain static site (`index.html`, no
  `package.json`) is served by Caddy. Anything else (Node, Python, Go, Ruby, PHP...) is auto-detected
  with [Railpack](https://railpack.com), the successor to Nixpacks.
- **Zero-downtime deploys:** an optional release command (e.g. migrations) runs in the new image first,
  then the new container must answer HTTP on its port before traffic moves to it. If either fails, the
  old version stays live and the error plus logs are shown.
- **Databases:** Postgres, Redis and MongoDB run next to your apps, reachable only from them, and are
  backed up every night (`fawwk db`).
- **Auto-deploy:** with GitHub connected (below), every push deploys within seconds through a webhook.
  A systemd timer also checks each repo's branch every minute, for other git hosts and as a backup.
  A commit that failed to deploy isn't retried until you push again. When a webhook and the timer fire
  for the same push, it's deployed once. Each deploy shows as a ✓ or ✗ on its GitHub commit.
- **Notifications:** failed deploys, cron jobs and backups, and new Fawwk versions, sent to Telegram,
  Slack, Discord or any webhook (`fawwk notify`).
- **Logs:** `fawwk logs <app>` shows readable, coloured logs: local times, error and warning badges,
  JSON logs as plain lines, and build logs as a list of steps.
- **Updates:** Fawwk tells you when a new version is out (after commands, in `doctor`, in your
  notifications) and never updates itself: `sudo fawwk update` when it suits you.

## Install

On a fresh Ubuntu 22.04/24.04 server. 2 GB of RAM is enough for a few small apps; with databases and
several apps building on one server, use 4 GB or more (builds are the hungriest part).

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

It installs Docker, Caddy, Railpack, UFW (opens only SSH, 80, 443), fail2ban, cron, log rotation for
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
- Every deploy shows on its commit on GitHub: a pending dot while it builds, then a check mark (linking
  to the app) or a cross saying what failed, as the status `fawwk/<app>`.
- Several GitHub accounts or orgs? Run `connect` once for each (log in to the other account first).

```bash
fawwk github                 # connected accounts and the repos each can reach
fawwk github install         # add or remove repos
fawwk github remove <name>   # forget a connection
fawwk github statuses off    # stop posting deploy status on commits
```

GitHub Apps connected before Fawwk 0.3 don't have the permission for commit statuses yet. Deploys work
the same, and the deploy output says where to add it: the app's settings page on GitHub → Permissions
→ **Commit statuses: Read and write**, then accept the change on its install.

It needs `panel.<domain>` to point to this server (the wildcard DNS record covers it). Webhooks are
received by a small, locked-down container (`fawwk-hooks`) that only checks signatures and queues jobs;
the deploy itself runs on the host.

## Deploy an app

```bash
sudo fawwk create
```

The guided flow asks for:

1. **Repo:** with GitHub connected, pick one from the repos the app is installed on (most recently pushed
   first). Or type `https://github.com/you/app` or just `you/app`. If the connected GitHub App is installed on
   it, that's all. Otherwise, for a private repo, Fawwk offers to connect GitHub, a read-only **deploy
   key** for you to paste into GitHub, or a personal access token.
2. **Branch:** pick from the repo's branches (its default branch first), or type one.
3. **Folder:** for monorepos, pick from the repo root and the folders that look deployable (each labelled:
   Dockerfile, Node, Python...), or type one like `apps/web`. A repo with nothing to pick uses its root.
4. **Domains:** `app.example.com`, `example.com`, `example.com/api`, several at once, or `none` for a
   background worker. Path routes strip the prefix by default (`/api/users` reaches the app as `/users`).
5. **Port:** what the app listens on. It's also passed in as `PORT`, so apps that read `$PORT` just work.
6. **Health check path:** optional, e.g. `/health`.
7. **Env vars:** paste your whole `.env` and press Ctrl-D. Quoted values may span several lines (PEM
   keys, certificates). If the repo has a `.env.example`, Fawwk then
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
fawwk deploy api --no-cache         # the same, building every step from scratch this once
fawwk logs api -f                   # follow app logs (styled: times, levels, JSON, HTTP codes)
fawwk logs api --build              # last build log, step by step (--raw: as Docker gives them)
fawwk history api [--json]          # recent deploys
fawwk rollback api [deploy-id]      # back to the previous (or a given) version
fawwk restart | stop | start api
fawwk exec api                      # shell inside the container

fawwk env api                       # list vars (masked); --reveal to show values
fawwk env api set KEY=value         # then offers a zero-downtime restart
fawwk env api set-file KEY key.pem  # a file's contents, e.g. a private key (multi-line is fine)
fawwk env api unset KEY
fawwk env api import [file]         # merge a .env file, or paste one
fawwk env api edit                  # open in $EDITOR
fawwk env api check                 # compare with .env.example

fawwk domain api add api2.example.com
fawwk domain api rm example.com/api
fawwk port api 8080
fawwk health api /healthz --timeout 180   # path, and how long a new version gets to boot
fawwk autodeploy api off
fawwk build api railpack            # build method: auto | dockerfile | railpack | nixpacks | static
fawwk build api cache off           # rebuild every step on every deploy (see below)
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

### Databases

```bash
fawwk db create shop --type postgres --link api    # also: --type redis, --type mongodb
fawwk db                                           # all databases, state, last backup, apps using them
fawwk db info shop                                 # details; the URL with --reveal
fawwk db url shop                                  # print the connection URL (for scripts)
fawwk db link shop worker                          # give another app the URL (DATABASE_URL)
fawwk db unlink shop worker                        # take it away again
fawwk db shell shop                                # psql / redis-cli / mongosh
fawwk db backup shop                               # back up now
fawwk db backups shop                              # list its backups
fawwk db restore shop latest                       # or a file from: fawwk db backups shop
fawwk db schedule 02:30                            # daily backup time (default 03:17), or off
fawwk db start | stop | restart shop               # or --all
fawwk db logs shop -f
fawwk db remove shop                               # see "Deleting a database" below
```

- Each database runs in its own container on the private Fawwk network, as `fawwk-db-<name>`, with a
  random password and its data in a Docker volume. Nothing is published to the internet: only your apps
  can reach it.
- `--link` (or `fawwk db link`) sets the connection URL on an app: `DATABASE_URL` for Postgres,
  `REDIS_URL` for Redis, `MONGODB_URL` for MongoDB (`--as NAME` to pick another), then offers a restart.
- Versions: Postgres 17, Redis 7 and MongoDB 7.0 by default; pick another with `--version 16`.
- MongoDB 8 builds refuse to start on Linux kernel 6.19 and newer (MongoDB issue SERVER-121912), so
  MongoDB defaults to 7.0. If you pick an 8.x version, Fawwk checks it against the kernel before
  starting it, and `doctor` warns if a kernel upgrade would stop one. MongoDB 5 and later also need a
  CPU with AVX, which some older or emulated VPS CPUs lack.
- Backups are logical (`pg_dump`, a Redis snapshot, `mongodump`) in `/var/lib/fawwk/backups/<name>/`.
  The nightly ones keep the last 7 (`DB_KEEP_BACKUPS`); ones you make by hand stay until you delete them.
  A failed nightly backup sends a notification (`fawwk notify`).
- `restore` replaces the database's contents with the backup's, exactly: data added after the backup is
  gone. A safety backup of the current data is taken first. Apps are disconnected for a moment.
- Redis runs with its append-only file on, so a restart loses nothing.

#### Deleting a database

```bash
fawwk db unlink shop api        # for each app using it (fawwk db lists them), then: fawwk restart api
fawwk db remove shop            # asks you to type the name; --yes skips that
```

- `remove` deletes the container **and its data** (the `fawwk_db_<name>` volume). With `--keep-data`
  it deletes only the container: the volume stays on disk, for you to copy files out of. Fawwk won't
  reuse it, and `db create` refuses that name until it's gone (`docker volume rm fawwk_db_<name>`). To
  bring a database back, create it again with the same name, then `fawwk db restore <name> latest`.
- **Its backups are kept** in `/var/lib/fawwk/backups/<name>/`, in case you change your mind. When
  you're sure: `sudo rm -rf /var/lib/fawwk/backups/<name>`
- **Unlink apps first.** `remove` warns you which apps use the database but leaves their env alone, so
  without `unlink` an app keeps a `DATABASE_URL` (or `REDIS_URL` / `MONGODB_URL`) pointing at a database
  that's gone.

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
fawwk notify https://hooks.slack.com/services/...   # a webhook: Slack, Discord, or any JSON endpoint
fawwk notify telegram 123456789:AAF...               # a Telegram bot (see below)
fawwk notify all                                     # every automated deploy, not just failures
fawwk notify test                                    # a test message to every channel
fawwk notify off
```

What's sent: failed automated deploys (every one with `all`), failed cron jobs, failed nightly
database backups, and new Fawwk versions, to every channel you set up. The webhook's JSON body works
with Slack and Discord incoming webhooks, and also carries `app`, `status`, `commit` and `host` fields
for anything else.

**Telegram:** in Telegram, message **@BotFather**, send `/newbot` and copy the token it gives you. Send
your new bot any message (or add it to a group and say hi), then run
`sudo fawwk notify telegram <token>`. Fawwk finds that chat itself and sends a test message. To pick
the chat yourself: `fawwk notify telegram <token> <chat-id>`.

### Disk space, backups, updates

```bash
fawwk cleanup                       # old images and build logs, untagged layers, build cache
fawwk backup [file] [--with-data]   # settings, apps, env vars, keys, GitHub connections, certificates
                                    # (--with-data: app volumes and a fresh backup of every database)
fawwk restore backup.tar.gz         # on a new server, then: fawwk setup --yes && fawwk deploy --all
fawwk update                        # update Fawwk (also refreshes timers, log rotation, webhooks)
fawwk update --check                # just check whether a new version is out
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
are arrow-key menus (`↑/↓` or `j/k`, Enter; a number or the first letter also works). `fawwk create`
uses them for the repo, branch and folder, so there's rarely anything to type.

| Variable | Effect |
| --- | --- |
| `FAWWK_THEME=mint` | default: mint and violet. Also `ocean`, `ember`, `mono` |
| `NO_COLOR=1` | no colours |
| `FAWWK_ASCII=1` | plain ASCII symbols, for terminals without Unicode |
| `FAWWK_NO_UPDATE_NOTICE=1` | no "new Fawwk version" line after commands |

Run `sudo` with `-E`, or set the variable after it (`sudo FAWWK_THEME=ocean fawwk list`).
When output isn't a terminal (auto-deploy logs, pipes), colours, spinners and menus switch off, and
`fawwk logs` prints logs exactly as Docker gives them, ready for `grep`.

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
| `/etc/fawwk/apps/<app>/env.d/` | multi-line env values, one file each (root-only) |
| `/etc/fawwk/dbs/<name>/` | database settings and password (root-only) |
| `/var/lib/fawwk/backups/<name>/` | database backups |
| `/var/lib/fawwk/update-check` | the last check for a new Fawwk version |
| Docker volumes `fawwk_<app>_*` | app volumes; `fawwk_caddy_data` holds HTTPS certificates |
| Docker volumes `fawwk_db_<name>` | database data |

## Security notes

- App containers run with `no-new-privileges` and a process limit, so `sudo` inside an app container
  won't work. They're only reachable through Caddy and are never published on a host port.
- Env vars are available to the build by default (Next.js `NEXT_PUBLIC_*` and similar need them). Fawwk
  passes builders variable names and keeps the values in their environment, so values never show on a
  command line. With Railpack they're BuildKit secrets and don't end up in the image. For a Dockerfile,
  Fawwk declares them (`ARG`) in every build stage but the last: in a multi-stage build the last stage
  is what ships, and BuildKit writes the build args a `RUN` sees into the image's history. A
  single-stage Dockerfile, a value its own `ARG`s use in the last stage, and Nixpacks do end up in the
  locally stored image. Limit what a build sees with `fawwk buildenv <app> KEY,KEY` or `none`.
- Databases have no published ports, random 48-character passwords, and run as their own users with
  `no-new-privileges`. Their passwords reach Docker through the environment, never a command line.
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
- The last 3 images per app are kept for rollback (`KEEP_IMAGES`).
- Railpack builds repos without a Dockerfile. Apps that already deployed with Nixpacks before Fawwk 0.3
  keep using it (Nixpacks is in maintenance mode upstream). Switch one with `fawwk build <app> railpack`.
- Docker reuses a build step when its instructions and files haven't changed. A Dockerfile that
  fetches something itself (a `git clone` of another repo, a `curl` download) keeps the first copy it
  got. Build that app without the cache: `fawwk build <app> cache off`, or once with
  `fawwk deploy <app> --no-cache`. A push to the other repo doesn't redeploy the app; run
  `fawwk deploy <app>` then.
- Moving a database to a new major version isn't automatic: back up, create a new database with
  `--version`, restore into it, then `fawwk db link` it.

## Staying up to date

Fawwk never updates itself: you run `sudo fawwk update` when it suits you. To know when there's
something new:

- Once a day the server checks Fawwk's branch for a new version. `fawwk` commands then end with a line
  like `▲ Fawwk 0.5.0 is out (you have 0.4.0) → sudo fawwk update`, and `fawwk doctor` says so too.
- Each new version is sent once to your notifications (`fawwk notify`, e.g. Telegram).
- Every version is a [GitHub Release](https://github.com/deHypeChief/fawwk/releases) with its notes.
  For an email each time, watch the repo: **Watch → Custom → Releases**.

Only new versions count, not every change merged into `main`. `UPDATE_CHECK=off` in
`/etc/fawwk/fawwk.conf` turns the check off, and `FAWWK_NO_UPDATE_NOTICE=1` hides the line for one shell.

## Development

```bash
sudo tests/run.sh            # the whole suite (sandboxed: temp dirs, a stub docker; the database test
                             # uses real Docker when it's running, and the Railpack test needs railpack)
sudo tests/run.sh pipeline   # tests whose name matches
shellcheck bin/fawwk lib/*.sh install.sh tests/run.sh
```

CI runs both on every push and pull request (`.github/workflows/ci.yml`). Releasing is a version bump:
set `FAWWK_VERSION` in `lib/common.sh` and add its section to `CHANGELOG.md`. When that reaches `main`,
`.github/workflows/release.yml` tags `vX.Y.Z` and publishes the release with those notes.

## Roadmap

- Web panel at `panel.<domain>`
- docker-compose apps, preview deploys per branch
- Off-server backup copies (S3-compatible storage)
