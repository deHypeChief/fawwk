#!/usr/bin/env bash
# fawwk — shared helpers: paths, output, prompts, config files, validation, locking.

FAWWK_VERSION="0.1.0"

# ---------- paths (overridable for testing) ----------
FAWWK_ETC="${FAWWK_ETC:-/etc/fawwk}"          # config + secrets (root only)
FAWWK_VAR="${FAWWK_VAR:-/var/lib/fawwk}"      # source checkouts, build logs
FAWWK_LOG="${FAWWK_LOG:-/var/log/fawwk}"      # auto-deploy logs
FAWWK_CONF="$FAWWK_ETC/fawwk.conf"
APPS_ETC="$FAWWK_ETC/apps"
APPS_VAR="$FAWWK_VAR/apps"
CADDY_DIR="$FAWWK_ETC/caddy"
FAWWK_NETWORK="fawwk"
FAWWK_PROXY="fawwk-proxy"
KEEP_IMAGES="${KEEP_IMAGES:-3}"            # old images kept per app for rollback
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-90}"     # seconds a new container gets to answer

FAWWK_YES=0        # --yes: accept defaults, answer yes, never prompt
LOCK_NOWAIT=0     # used by auto-deploy: skip apps that are busy instead of waiting

# ---------- output ----------
if [[ -t 2 ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_RED=$'\e[31m'
  C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''
fi

step() { printf '\n%s==>%s %s%s%s\n' "$C_BLUE" "$C_RESET" "$C_BOLD" "$*" "$C_RESET" >&2; }
info() { printf '    %s\n' "$*" >&2; }
ok()   { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }
ts()   { date '+%Y-%m-%d %H:%M:%S'; }

# ---------- prompts ----------
is_interactive() { [[ $FAWWK_YES -eq 0 && -t 0 ]]; }

# ask VAR "Question" [default] [validator]
# Re-asks until the validator passes. Non-interactive: uses the default or dies.
ask() {
  local __var=$1 q=$2 def=${3-} check=${4-} ans
  while true; do
    if is_interactive; then
      if [[ -n $def ]]; then
        read -r -p "  ${C_CYAN}?${C_RESET} $q ${C_DIM}[$def]${C_RESET}: " ans || ans=''
      else
        read -r -p "  ${C_CYAN}?${C_RESET} $q: " ans || ans=''
      fi
      ans=${ans:-$def}
      if [[ -z $ans ]]; then warn "A value is required."; continue; fi
    else
      ans=$def
      [[ -n $ans ]] || die "Missing value for: $q (pass it as a flag or run interactively)"
    fi
    if [[ -n $check ]] && ! "$check" "$ans"; then
      is_interactive || die "Invalid value for '$q': $ans"
      continue
    fi
    printf -v "$__var" '%s' "$ans"
    return 0
  done
}

# ask_optional VAR "Question" [default] — empty answer allowed.
ask_optional() {
  local __var=$1 q=$2 def=${3-} ans=''
  if is_interactive; then
    read -r -p "  ${C_CYAN}?${C_RESET} $q ${C_DIM}[${def:-skip}]${C_RESET}: " ans || ans=''
  fi
  printf -v "$__var" '%s' "${ans:-$def}"
}

# ask_secret VAR "Question" — hidden input, required.
ask_secret() {
  local __var=$1 q=$2 ans=''
  is_interactive || die "Missing secret: $q (run interactively)"
  while [[ -z $ans ]]; do
    read -r -s -p "  ${C_CYAN}?${C_RESET} $q: " ans || ans=''
    printf '\n' >&2
  done
  printf -v "$__var" '%s' "$ans"
}

# confirm "Question" [Y|N] — returns 0 for yes.
confirm() {
  local q=$1 def=${2:-Y} ans hint
  [[ $def == Y ]] && hint='Y/n' || hint='y/N'
  if ! is_interactive; then
    [[ $FAWWK_YES -eq 1 || $def == Y ]]
    return
  fi
  read -r -p "  ${C_CYAN}?${C_RESET} $q ${C_DIM}[$hint]${C_RESET}: " ans || ans=''
  ans=${ans:-$def}
  [[ $ans =~ ^[Yy] ]]
}

# choose VAR "Question" DEFAULT_INDEX "option 1" "option 2" ... — sets VAR to the 1-based index.
choose() {
  local __var=$1 q=$2 def=$3 i ans
  shift 3
  if ! is_interactive; then printf -v "$__var" '%s' "$def"; return 0; fi
  printf '  %s?%s %s\n' "$C_CYAN" "$C_RESET" "$q" >&2
  for ((i = 1; i <= $#; i++)); do printf '      %d) %s\n' "$i" "${!i}" >&2; done
  while true; do
    read -r -p "    choice ${C_DIM}[$def]${C_RESET}: " ans || ans=''
    ans=${ans:-$def}
    if [[ $ans =~ ^[0-9]+$ ]] && ((ans >= 1 && ans <= $#)); then
      printf -v "$__var" '%s' "$ans"
      return 0
    fi
    warn "Pick a number between 1 and $#."
  done
}

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
APP_FIELDS=(A_NAME A_REPO A_BRANCH A_AUTH A_DIR A_BUILD A_PORT A_ROUTES A_STRIP A_HEALTH
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
app_lock() {
  mkdir -p /run/lock
  exec 9>"/run/lock/fawwk-$1.lock"
  if flock -n 9; then return 0; fi
  if [[ $LOCK_NOWAIT -eq 1 ]]; then info "$1 is busy, skipping"; exit 0; fi
  info "Another operation on '$1' is running; waiting for it to finish..."
  flock 9
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
  [[ -n $ip ]] || ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") print $(i + 1)}')
  printf '%s' "$ip"
}

# dns_points_here HOST — 0 if HOST resolves to this server's IP.
dns_points_here() {
  [[ -n ${SERVER_IP-} ]] || return 1
  getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | grep -qx "$SERVER_IP"
}

dns_report() {
  local host=$1 got
  if dns_points_here "$host"; then
    ok "DNS: $host → $SERVER_IP"
  else
    got=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
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
route_normalize() {
  local r=${1,,}
  r=${r#http://}; r=${r#https://}
  r=${r%/}
  printf '%s' "$r"
}

valid_route() {
  local host=${1%%/*} path=''
  [[ $1 == */* ]] && path="/${1#*/}"
  valid_domain "$host" || return 1
  [[ -z $path || $path =~ $RE_PATH ]] || { warn "Invalid path in '$1' (use letters, digits, . _ ~ -)"; return 1; }
}

need_arg() { [[ -n ${2-} && ${2-} != --* ]] || die "Option $1 needs a value"; }

# sanitize "My_Repo.Name" -> "my-repo-name"
sanitize_name() {
  local s=${1,,}
  s=${s//[^a-z0-9-]/-}
  s=$(printf '%s' "$s" | sed -E 's/-+/-/g; s/^[^a-z]+//; s/-+$//')
  printf '%s' "${s:0:32}"
}
