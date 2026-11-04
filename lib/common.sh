#!/usr/bin/env bash
# fawwk — shared helpers: paths, config files, validation, locking.

FAWWK_VERSION="0.2.0"

# ---------- paths (overridable for testing) ----------
FAWWK_ETC="${FAWWK_ETC:-/etc/fawwk}"          # config + secrets (root only)
FAWWK_VAR="${FAWWK_VAR:-/var/lib/fawwk}"      # source checkouts, build logs
FAWWK_LOG="${FAWWK_LOG:-/var/log/fawwk}"      # auto-deploy logs
FAWWK_CONF="$FAWWK_ETC/fawwk.conf"
APPS_ETC="$FAWWK_ETC/apps"
APPS_VAR="$FAWWK_VAR/apps"
CADDY_DIR="$FAWWK_ETC/caddy"
CRON_DIR="${FAWWK_CRON_DIR:-/etc/cron.d}"     # cron jobs: fawwk-<app>
LOGROTATE_DIR="${FAWWK_LOGROTATE_DIR:-/etc/logrotate.d}"
FAWWK_NETWORK="fawwk"
FAWWK_PROXY="fawwk-proxy"
KEEP_IMAGES="${KEEP_IMAGES:-3}"            # old images kept per app for rollback
KEEP_LOGS="${KEEP_LOGS:-20}"               # build logs kept per app
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-90}"     # default seconds a new container gets to answer
# Pinned so a re-run of setup can't silently pull a different proxy. Override to upgrade.
CADDY_IMAGE="${CADDY_IMAGE:-caddy:2.10.2}"
CADDY_STATIC_IMAGE="${CADDY_STATIC_IMAGE:-caddy:2.10.2-alpine}"

FAWWK_YES=0        # --yes: accept defaults, answer yes, never prompt
LOCK_NOWAIT=0     # used by auto-deploy: skip apps that are busy instead of waiting

# Output, prompts and menus live in ui.sh (step, info, ok, warn, err, die, ask, confirm, choose...).

# ---------- config files (KEY=value, shell-quoted, safe to source) ----------
conf_set() {
  local f=$1 k=$2 v=$3 tmp
  tmp=$(mktemp "$f.XXXXXX")
  if [[ -f $f ]]; then grep -v -E "^${k}=" "$f" >"$tmp" || true; fi
  printf '%s=%q\n' "$k" "$v" >>"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$f"
}

# ---------- app config ----------
# Every app lives in $APPS_ETC/<name>/ (app.conf, env, token|deploy_key, history)
# and $APPS_VAR/<name>/ (src checkout, build logs). Fields are prefixed A_.
APP_FIELDS=(A_NAME A_REPO A_BRANCH A_AUTH A_TOKEN_USER A_GH_SOURCE A_GH_INSTALL A_DIR A_BUILD A_BUILD_ENV
            A_PORT A_ROUTES A_STRIP A_HEALTH A_HEALTH_TIMEOUT A_MEMORY A_CPUS A_VOLUMES A_RELEASE
            A_AUTO A_STATE A_CONTAINER A_IMAGE A_COMMIT A_FAILED_COMMIT A_CREATED A_DEPLOYED)

app_dir()     { printf '%s/%s' "$APPS_ETC" "$1"; }
app_var()     { printf '%s/%s' "$APPS_VAR" "$1"; }
app_exists()  { [[ -f $APPS_ETC/$1/app.conf ]]; }
app_envfile() { printf '%s/%s/env' "$APPS_ETC" "$1"; }

app_names() {
  local f
  for f in "$APPS_ETC"/*/app.conf; do
    [[ -f $f ]] || continue
    f=${f%/app.conf}
    printf '%s\n' "${f##*/}"
  done
}

app_reset() { local v; for v in "${APP_FIELDS[@]}"; do printf -v "$v" '%s' ''; done; }

app_load() {
  app_exists "$1" || die "No app named '$1'. See: fawwk list"
  app_reset
  # shellcheck disable=SC1090
  source "$APPS_ETC/$1/app.conf"
}

# app_set KEY VALUE — persists a field of the loaded app and updates the shell variable.
app_set() {
  conf_set "$APPS_ETC/$A_NAME/app.conf" "$1" "$2"
  printf -v "$1" '%s' "$2"
}

app_save() {
  local v
  for v in "${APP_FIELDS[@]}"; do conf_set "$APPS_ETC/$A_NAME/app.conf" "$v" "${!v}"; done
}

app_require_arg() { [[ -n ${1-} ]] || die "Which app? Usage: fawwk $2 <app>   (see: fawwk list)"; }

# app_lock NAME — one operation per app at a time (deploy, restart, remove...).
# Use app_load_locked instead when you'll act on the app's state: another operation may have
# changed it while this one waited for the lock.
app_lock() {
  mkdir -p /run/lock
  exec 9>"/run/lock/fawwk-$1.lock"
  if flock -n 9; then return 0; fi
  if [[ $LOCK_NOWAIT -eq 1 ]]; then info "$1 is busy, skipping"; exit 0; fi
  info "Another operation on '$1' is running; waiting for it to finish..."
  flock 9
}

# app_load_locked NAME — takes the app's lock, then (re)loads its config so it's current.
app_load_locked() {
  app_exists "$1" || die "No app named '$1'. See: fawwk list"
  app_lock "$1"
  app_load "$1"
}

# ---------- server config ----------
require_root() { [[ $EUID -eq 0 ]] || die "fawwk needs root. Run: sudo fawwk $*"; }

require_setup() {
  [[ -f $FAWWK_CONF ]] || die "This server isn't set up yet. Run: sudo fawwk setup"
  # shellcheck disable=SC1090
  source "$FAWWK_CONF"
  command -v docker >/dev/null 2>&1 || die "Docker is missing. Re-run: sudo fawwk setup"
}

server_ip() {
  local ip
  ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
  [[ -n $ip ]] || ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") print $(i + 1)}' || true)
  printf '%s' "$ip"
}

# IPv4 addresses HOST resolves to, one per line (empty if it doesn't resolve).
dns_lookup() { getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u || true; }

# dns_points_here HOST — 0 if HOST resolves to this server's IP.
dns_points_here() {
  [[ -n ${SERVER_IP-} ]] || return 1
  local ips
  ips=$(dns_lookup "$1")
  [[ $'\n'$ips$'\n' == *$'\n'"$SERVER_IP"$'\n'* ]]
}

# IPv6 addresses HOST resolves to (AAAA records), one per line.
dns_lookup6() { getent ahostsv6 "$1" 2>/dev/null | awk '$1 ~ /:/ && $1 !~ /^::ffff:/ {print $1}' | sort -u || true; }

# This server's public IPv6 addresses, one per line.
server_ip6() { ip -6 addr show scope global 2>/dev/null | awk '/inet6/ {sub("/.*", "", $2); print $2}' || true; }

# Warns when HOST has an AAAA record that isn't this server: Let's Encrypt prefers IPv6, so a stale
# AAAA record makes certificates fail even though the A record is right.
dns_report6() {
  local host=$1 v6 mine a bad=''
  v6=$(dns_lookup6 "$host")
  [[ -n $v6 ]] || return 0
  mine=$'\n'$(server_ip6)$'\n'
  for a in $v6; do [[ $mine == *$'\n'"$a"$'\n'* ]] || bad+="$a "; done
  [[ -z $bad ]] && return 0
  warn "DNS: $host also has an AAAA (IPv6) record ${bad% } that isn't this server. Delete it, or HTTPS certificates may fail."
}

dns_report() {
  local host=$1 got
  if dns_points_here "$host"; then
    ok "DNS: $host → $SERVER_IP"
    dns_report6 "$host"
  else
    got=$(dns_lookup "$host" | tr '\n' ' ')
    if [[ -z $got ]]; then
      warn "DNS: $host doesn't resolve yet. Add an A record pointing to $SERVER_IP."
    else
      warn "DNS: $host → ${got% } (expected $SERVER_IP). Fine if it's behind a proxy like Cloudflare."
    fi
  fi
}

# ---------- validation (print a reason on failure) ----------
RE_DOMAIN='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
RE_APP='^[a-z][a-z0-9-]{0,30}[a-z0-9]$'
RE_PATH='^(/[A-Za-z0-9._~-]+)+$'

valid_app_name() { [[ $1 =~ $RE_APP ]] || { warn "Use 2-32 characters: lowercase letters, digits and dashes, starting with a letter."; return 1; }; }
valid_domain()   { [[ ${1,,} =~ $RE_DOMAIN ]] || { warn "Not a valid domain: $1"; return 1; }; }
valid_email()    { [[ $1 =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { warn "Not a valid email: $1"; return 1; }; }
valid_port()     { [[ $1 =~ ^[0-9]+$ ]] && (($1 >= 1 && $1 <= 65535)) || { warn "Port must be a number from 1 to 65535."; return 1; }; }
valid_subdir()   { [[ $1 == . || ($1 =~ ^[A-Za-z0-9._/-]+$ && $1 != /* && $1 != *..*) ]] || { warn "Use a relative folder like 'apps/web' or '.'"; return 1; }; }

# route = host or host/path, e.g. api.example.com or example.com/api
# Hostnames are case-insensitive and get lowercased; paths are case-sensitive and are kept.
route_normalize() {
  local r=$1 host path=''
  [[ ${r,,} == http://* ]] && r=${r:7}
  [[ ${r,,} == https://* ]] && r=${r:8}
  r=${r%/}
  host=${r%%/*}
  [[ $r == */* ]] && path="/${r#*/}"
  printf '%s%s' "${host,,}" "$path"
}

valid_route() {
  local host=${1%%/*} path=''
  [[ $1 == */* ]] && path="/${1#*/}"
  valid_domain "$host" || return 1
  [[ -z $path || $path =~ $RE_PATH ]] || { warn "Invalid path in '$1' (use letters, digits, . _ ~ -)"; return 1; }
}

need_arg() { [[ -n ${2-} && ${2-} != --* ]] || die "Option $1 needs a value"; }

# fawwk_version — the release, plus the commit when installed from git (e.g. 0.2.0 (3f2a1bc)).
fawwk_version() {
  local sha
  sha=$(git -C "$FAWWK_HOME" rev-parse --short HEAD 2>/dev/null || true)
  printf '%s%s' "$FAWWK_VERSION" "${sha:+ ($sha)}"
}

# sanitize "My_Repo.Name" -> "my-repo-name"
sanitize_name() {
  local s=${1,,}
  s=${s//[^a-z0-9-]/-}
  s=$(printf '%s' "$s" | sed -E 's/-+/-/g; s/^[^a-z]+//; s/-+$//')
  printf '%s' "${s:0:32}"
}
