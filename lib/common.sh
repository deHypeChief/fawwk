#!/usr/bin/env bash
# fawwk — shared helpers: paths, config files, validation, locking.

# Bash 5.2 (Ubuntu 24.04) made `&` in ${var//pattern/replacement} mean "the matched text", so
# ${m//\"/&quot;} gives "quot; instead of &quot;. Fawwk is written for the old rule: a literal &.
shopt -u patsub_replacement 2>/dev/null || true

FAWWK_VERSION="0.6.0"

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
SYSTEMD_DIR="${FAWWK_SYSTEMD_DIR:-/etc/systemd/system}"
FAWWK_NETWORK="fawwk"
FAWWK_PROXY="fawwk-proxy"
KEEP_IMAGES="${KEEP_IMAGES:-3}"            # old images kept per app for rollback
KEEP_LOGS="${KEEP_LOGS:-20}"               # build logs kept per app
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-90}"     # default seconds a new container gets to answer
# Pinned so a re-run of setup can't silently pull a different proxy. Override to upgrade.
CADDY_IMAGE="${CADDY_IMAGE:-caddy:2.10.2}"
CADDY_STATIC_IMAGE="${CADDY_STATIC_IMAGE:-caddy:2.10.2-alpine}"
# Railpack builds repos that have no Dockerfile (the successor to Nixpacks). setup installs this
# version; builds use the BuildKit frontend image of the same version, as Railpack recommends.
RAILPACK_VERSION="${RAILPACK_VERSION:-0.43.0}"
RAILPACK_FRONTEND="${RAILPACK_FRONTEND:-ghcr.io/railwayapp/railpack-frontend}"

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
APP_FIELDS=(A_NAME A_REPO A_BRANCH A_AUTH A_TOKEN_USER A_GH_SOURCE A_GH_INSTALL A_DIR A_BUILD A_BUILD_ENV A_BUILD_CACHE
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

# IPv4 addresses public DNS gives for HOST (Cloudflare's DNS-over-HTTPS), one per line: what visitors
# and Let's Encrypt see, whatever this server's own resolver has cached. Empty if it can't be asked.
dns_lookup_public() {
  command -v jq >/dev/null 2>&1 || return 0
  curl -fsS --max-time 5 -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=$1&type=A" 2>/dev/null |
    jq -r '.Answer[]? | select(.type == 1) | .data' 2>/dev/null | sort -u || true
}

dns_report() {
  local host=$1 got pub
  if dns_points_here "$host"; then
    ok "DNS: $host → ${SERVER_IP:-this server}"
    dns_report6 "$host"
    return 0
  fi
  # This server may still remember an answer from before the record existed ("doesn't exist" is
  # cached too, often for an hour). Public DNS says what everyone else sees.
  pub=$(dns_lookup_public "$host")
  if [[ -n ${SERVER_IP-} && $'\n'$pub$'\n' == *$'\n'"$SERVER_IP"$'\n'* ]]; then
    command -v resolvectl >/dev/null 2>&1 && resolvectl flush-caches >/dev/null 2>&1 || true
    if dns_points_here "$host"; then
      ok "DNS: $host → $SERVER_IP ${C_MUTED}(this server had an old answer cached; cleared it)${C_RESET}"
    else
      ok "DNS: $host → $SERVER_IP in public DNS"
      hint "This server still has an older answer cached, which clears itself within about an hour. Now: sudo resolvectl flush-caches"
    fi
    dns_report6 "$host"
    return 0
  fi
  got=$(dns_lookup "$host" | tr '\n' ' ')
  got=${got% }
  if [[ -z $got ]]; then
    warn "DNS: $host doesn't resolve yet. Add an A record pointing to ${SERVER_IP:-this server}."
    return 0
  fi
  local want=${SERVER_IP:-this server} cf=0 res
  # shellcheck disable=SC2086
  all_cloudflare $got && cf=1
  # DNS alone can't tell where a proxy sends traffic, so ask: only this server knows its check token.
  res=$(origin_probe "$host")
  case $res in
    here)
      if ((cf)); then cloud "DNS: $host is proxied via Cloudflare and reaches this server"
      else ok "DNS: $host → $got, a proxy in front of this server"; fi ;;
    loop)
      if ((cf)); then warn "DNS: $host is proxied via Cloudflare, but its SSL/TLS mode is Flexible, so every visit redirects forever. In Cloudflare: SSL/TLS → Overview → Full (strict)."
      else warn "DNS: $host → $got, a proxy that redirects forever. Have it connect to this server over HTTPS."; fi ;;
    cf:521 | cf:522 | cf:523)
      warn "DNS: $host is proxied via Cloudflare, but Cloudflare can't reach its server (error ${res#cf:}). In Cloudflare, set the A record to $want, and keep ports 80 and 443 open." ;;
    cf:525 | cf:526)
      if host_routed "$host"; then
        warn "DNS: $host is proxied via Cloudflare, but the HTTPS connection to this server fails (error ${res#cf:}). The certificate may not be issued yet: fawwk proxy logs"
      else
        cloud "DNS: $host is proxied via Cloudflare"
        hint "It can be checked end to end once an app uses this address."
      fi ;;
    other | cf:*)
      if ((cf)); then warn "DNS: $host is proxied via Cloudflare, but Cloudflare sends it to a different server. In Cloudflare, set the A record to $want."
      else warn "DNS: $host → $got, a different server. Change the A record to $want."; fi ;;
    *) # Couldn't check (no answer, or the proxy isn't running here).
      if ((cf)); then
        cloud "DNS: $host is proxied via Cloudflare"
        hint "Couldn't confirm it reaches this server. Cloudflare's SSL/TLS mode must be Full or Full (strict)."
      else warn "DNS: $host → $got, not this server (${want}). Change the A record, unless a proxy sits in front."; fi ;;
  esac
}

# ---------- origin check: does traffic for a host really reach this server? ----------
# Cloudflare's published IPv4 ranges (https://www.cloudflare.com/ips-v4).
CF_RANGES='173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18
108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17
162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22'

# shellcheck disable=SC2086 # split on dots on purpose
ip_to_int() { local IFS=.; set -- $1; printf '%s' $((($1 << 24) + ($2 << 16) + ($3 << 8) + $4)); }

# is_cloudflare_ip IP — 0 if IP is in one of Cloudflare's ranges.
is_cloudflare_ip() {
  [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  local ip cidr net bits
  ip=$(ip_to_int "$1")
  for cidr in $CF_RANGES; do
    net=$(ip_to_int "${cidr%/*}") bits=${cidr#*/}
    (((ip >> (32 - bits)) == (net >> (32 - bits)))) && return 0
  done
  return 1
}

# all_cloudflare IP... — 0 if there is at least one IP and every one is Cloudflare's.
all_cloudflare() {
  (($#)) || return 1
  local ip
  for ip; do is_cloudflare_ip "$ip" || return 1; done
}

CHECK_PATH=/.well-known/fawwk-check

# This server's check token (made once): Caddy answers it at CHECK_PATH on every host.
check_token() {
  local f=$FAWWK_ETC/check-token t
  if [[ ! -s $f ]]; then
    t=$(openssl rand -hex 16 2>/dev/null || printf '%04x%04x%04x%04x' $RANDOM $RANDOM $RANDOM $RANDOM)
    printf '%s\n' "$t" >"$f" 2>/dev/null || return 1
  fi
  tr -cd '0-9a-f' <"$f"
}

# host_routed HOST — 0 if the proxy has a site block for HOST (an app or the panel uses it).
host_routed() { [[ -f $CADDY_DIR/Caddyfile ]] && grep -qxF "$1 {" "$CADDY_DIR/Caddyfile"; }

# origin_probe HOST — fetches CHECK_PATH through HOST the way a visitor would and prints:
#   here (it reached this server), loop (endless redirects), cf:CODE (a Cloudflare error page),
#   other (some other server answered) or unknown (no answer, or the proxy can't answer yet).
origin_probe() {
  local host=$1 token out code body headers rc=0
  token=$(check_token) && [[ -n $token ]] || { echo unknown; return 0; }
  # A proxy config from before this check existed doesn't answer it yet: regenerate it once.
  if ! grep -qF "$token" "$CADDY_DIR/Caddyfile" 2>/dev/null; then
    [[ $EUID -eq 0 ]] && proxy_running 2>/dev/null && proxy_reload >/dev/null 2>&1 || true
    grep -qF "$token" "$CADDY_DIR/Caddyfile" 2>/dev/null || { echo unknown; return 0; }
  fi
  headers=$(mktemp)
  # -k: a certificate that isn't issued yet shouldn't hide the answer; the token is the proof.
  out=$(curl -sS -k -L --max-redirs 6 --max-time 10 -D "$headers" -w '\n%{http_code}' \
    "http://$host$CHECK_PATH" 2>/dev/null) || rc=$?
  code=${out##*$'\n'} body=${out%$'\n'*}
  if ((rc == 47)); then echo loop
  elif [[ $body == "$token" ]]; then echo here
  elif ((rc != 0)) || [[ -z $code || $code == 000 ]]; then echo unknown
  elif [[ $code == 5[0-9][0-9] ]] && grep -qi '^server: *cloudflare' "$headers"; then echo "cf:$code"
  else echo other
  fi
  rm -f "$headers"
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

# html_escape TEXT — TEXT made safe inside an HTML attribute or element.
html_escape() {
  local s=$1
  s=${s//&/&amp;}; s=${s//\"/&quot;}; s=${s//\'/&#39;}; s=${s//</&lt;}; s=${s//>/&gt;}
  printf '%s' "$s"
}

# sanitize "My_Repo.Name" -> "my-repo-name"
sanitize_name() {
  local s=${1,,}
  s=${s//[^a-z0-9-]/-}
  s=$(printf '%s' "$s" | sed -E 's/-+/-/g; s/^[^a-z]+//; s/-+$//')
  printf '%s' "${s:0:32}"
}
