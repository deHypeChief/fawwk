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
- **Builds:** a `Dockerfile` in the repo is used if present. A plain static site (`index.html`, no
  `package.json`) is served by Caddy. Anything else (Node, Python, Go, Ruby, PHP...) is auto-detected
  with [Nixpacks](https://nixpacks.com).
- **Zero-downtime deploys:** the new container must answer HTTP on its port before traffic moves to it.
  If it fails, the old version stays live and the error plus logs are shown.
- **Auto-deploy:** a systemd timer polls each repo's branch every minute. There are no webhooks, so
  nothing extra is exposed. A commit that failed to deploy isn't retried until you push again.

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

It installs Docker, Caddy, Nixpacks, UFW (opens only SSH, 80, 443), fail2ban, and a 2GB swap file
on servers with under ~4GB RAM. Then it shows the DNS records to create:

```
A    example.com     <server ip>
A    *.example.com   <server ip>
```

With the wildcard record in place, every new app subdomain works without touching DNS again.

## Deploy an app

```bash
sudo fawwk create
```

The guided flow asks for:

1. **Repo:** `https://github.com/you/app` or just `you/app`. For a private repo, Fawwk generates a
   read-only **deploy key** for you to paste into GitHub (recommended), or takes a personal access token.
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
  --port 8000 --health /health --env-file ./api.env --deploy-key --yes
```

## Examples

- [Express API + React frontend](examples/express-react): two Dockerfiles deployed as two apps on one
  domain (`example.com` and `example.com/api`).

## Everyday commands

```bash
fawwk list                          # all apps, state, URL
fawwk info api                      # details, CPU/RAM, last failure
fawwk deploy api                    # pull + rebuild + zero-downtime swap
fawwk logs api -f                   # follow app logs
fawwk logs api --build              # last build log
fawwk history api                   # recent deploys
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
fawwk health api /healthz
fawwk autodeploy api off

fawwk doctor                        # server, DNS and app health check
fawwk proxy config | reload | logs
fawwk remove api
```

All commands need root (`sudo`).

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
| `/etc/fawwk/fawwk.conf` | server settings from `setup` |
| `/etc/fawwk/apps/<app>/` | `app.conf`, `env`, deploy key or token, `history` (root-only, mode 600) |
| `/etc/fawwk/caddy/Caddyfile` | generated proxy config; add your own blocks in `custom/*.caddy` |
| `/var/lib/fawwk/apps/<app>/` | git checkout and build logs |
| `/var/log/fawwk/` | auto-deploy logs (`sync.log`, `<app>.log`) |

## Notes and limits (v0.1)

- One server, one container per app. `docker-compose` multi-service apps aren't supported yet. Use a
  Dockerfile per service and create one app for each.
- Env vars are also available at build time (e.g. for Next.js `NEXT_PUBLIC_*`), so they end up in the
  locally stored image. Images never leave the server.
- Multi-line env values aren't supported; put `\n` inside a single line instead.
- The last 3 images per app are kept for rollback (`KEEP_IMAGES`).

## Roadmap

- Web panel at `panel.<domain>`
- GitHub webhooks for instant deploys
- Managed Postgres/Redis with backups
- docker-compose apps, preview deploys per branch
