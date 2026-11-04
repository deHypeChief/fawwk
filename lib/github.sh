#!/usr/bin/env bash
# fawwk — GitHub App integration: connect GitHub once, install the app on repos, deploy on push.
#
# Each "source" is a private GitHub App owned by one GitHub account or organization, created in one
# click with GitHub's manifest flow. Several sources = several GitHub profiles/orgs.
#   /etc/fawwk/github/<slug>/app.conf      GH_APP_ID GH_SLUG GH_OWNER GH_OWNER_TYPE GH_HTML_URL
#   /etc/fawwk/github/<slug>/key.pem       private key: signs short-lived JWTs (root only)
#   /var/lib/fawwk/hooks/secrets/<slug>    webhook secret, mounted read-only into fawwk-hooks
# Apps using a source store A_AUTH=github, A_GH_SOURCE=<slug>, A_GH_INSTALL=<installation id>.

GH_ETC="$FAWWK_ETC/github"
HOOKS_DIR="$FAWWK_VAR/hooks"
HOOKS_CONTAINER="fawwk-hooks"
HOOKS_IMAGE="python:3.12-alpine"
HOOKS_UID=65534   # "nobody": the receiver never runs as root, even inside its container
HOOKS_REV=2       # bump when hooks_container_start's run options change; older containers get recreated
GH_API="${FAWWK_GH_API:-https://api.github.com}"

gh_sources() {
  local f
  for f in "$GH_ETC"/*/app.conf; do
    [[ -f $f ]] || continue
    f=${f%/app.conf}
    printf '%s\n' "${f##*/}"
  done
}
gh_have_sources() { [[ -n $(gh_sources) ]]; }

gh_load() {
  [[ -f $GH_ETC/$1/app.conf ]] || die "No GitHub connection named '$1'. See: fawwk github"
  GH_APP_ID='' GH_SLUG='' GH_OWNER='' GH_OWNER_TYPE='' GH_HTML_URL=''
  # shellcheck disable=SC1090
  source "$GH_ETC/$1/app.conf"
}

gh_need_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  spin_start "Installing jq"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q jq >/dev/null 2>&1 || true
  spin_stop
  command -v jq >/dev/null 2>&1 || die "jq is required. Install it with: apt-get install jq"
}

gh_b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# gh_jwt SOURCE — a 9-minute JWT signed with the app's private key (authenticates as the app).
gh_jwt() {
  gh_load "$1"
  local now head body
  now=$(date +%s)
  head=$(printf '{"alg":"RS256","typ":"JWT"}' | gh_b64url)
  body=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$GH_APP_ID" | gh_b64url)
  printf '%s.%s.%s' "$head" "$body" \
    "$(printf '%s.%s' "$head" "$body" | openssl dgst -sha256 -sign "$GH_ETC/$1/key.pem" -binary | gh_b64url)"
}

# gh_api TOKEN METHOD PATH [JSON] — prints the response body; fails on HTTP errors.
gh_api() {
  local args=(-fsS --max-time 20 -X "$2" -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28" -H "Authorization: Bearer $1")
  [[ -n ${4-} ]] && args+=(-H "Content-Type: application/json" -d "$4")
  curl "${args[@]}" "$GH_API$3"
}

# gh_find_installation owner/repo — prints "<source> <installation id>" for the first connected
# GitHub App installed on the repo.
gh_find_installation() {
  local src jwt id
  while IFS= read -r src; do
    [[ -z $src ]] && continue
    jwt=$(gh_jwt "$src") || continue
    id=$(gh_api "$jwt" GET "/repos/$1/installation" 2>/dev/null | jq -r '.id // empty' 2>/dev/null) || continue
    [[ -n $id ]] && { printf '%s %s' "$src" "$id"; return 0; }
  done < <(gh_sources)
  return 1
}

# gh_app_token — makes sure the loaded app's token file holds a valid installation token (1 hour,
# read-only, limited to this repo) and refreshes it 5 minutes before it expires.
gh_app_token() {
  local d tok exp resp found
  d=$(app_dir "$A_NAME")
  if [[ -s $d/token && -f $d/token.exp ]] && (($(cat "$d/token.exp") - $(date +%s) > 300)); then return 0; fi
  gh_need_jq >/dev/null
  resp=$(gh_api "$(gh_jwt "$A_GH_SOURCE")" POST "/app/installations/$A_GH_INSTALL/access_tokens" \
    "{\"repositories\":[\"$(repo_slug "$A_REPO")\"],\"permissions\":{\"contents\":\"read\"}}" 2>/dev/null || true)
  if [[ -z $resp ]]; then
    # The app may have been reinstalled (new installation id): look it up again.
    found=$(gh_find_installation "$(repo_path "$A_REPO")") || return 1
    read -r A_GH_SOURCE A_GH_INSTALL <<<"$found"
    conf_set "$d/app.conf" A_GH_SOURCE "$A_GH_SOURCE"
    conf_set "$d/app.conf" A_GH_INSTALL "$A_GH_INSTALL"
    resp=$(gh_api "$(gh_jwt "$A_GH_SOURCE")" POST "/app/installations/$A_GH_INSTALL/access_tokens" \
      "{\"repositories\":[\"$(repo_slug "$A_REPO")\"],\"permissions\":{\"contents\":\"read\"}}") || return 1
  fi
  tok=$(jq -r '.token // empty' <<<"$resp")
  exp=$(jq -r '.expires_at // empty' <<<"$resp")
  [[ -n $tok ]] || return 1
  (umask 077; printf '%s\n' "$tok" >"$d/token"; date -d "${exp:-now + 50 min}" +%s >"$d/token.exp")
}

# ---------- deploy status on commits ----------
# Each deploy of an app using a GitHub App shows on its commit as a status named fawwk/<app>:
# pending while it builds, then success (linking to the app) or failure. Needs the app's
# "Commit statuses: Read and write" permission, which new connections ask for.

# gh_settings_url SOURCE — the GitHub App's settings page, where its permissions are changed.
gh_settings_url() {
  gh_load "$1"
  if [[ $GH_OWNER_TYPE == Organization ]]; then printf 'https://github.com/organizations/%s/settings/apps/%s/permissions' "$GH_OWNER" "$GH_SLUG"
  else printf 'https://github.com/settings/apps/%s/permissions' "$GH_SLUG"
  fi
}

# deploy_status STATE DESCRIPTION COMMIT — STATE is pending, success or failure. Never fails a deploy:
# a GitHub outage or a missing permission only costs the status.
DEPLOY_STATUS_TOKEN='' DEPLOY_STATUS_HINTED=0
deploy_status() {
  local state=$1 desc=$2 sha=${3-} url='' body
  [[ ${A_AUTH-} == github && -n $sha && ${GH_STATUSES:-on} != off && -n ${A_GH_INSTALL-} ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  if [[ -z $DEPLOY_STATUS_TOKEN ]]; then
    # A token that can only write commit statuses, only on this repo.
    DEPLOY_STATUS_TOKEN=$(gh_api "$(gh_jwt "$A_GH_SOURCE" 2>/dev/null)" POST "/app/installations/$A_GH_INSTALL/access_tokens" \
      "{\"repositories\":[\"$(repo_slug "$A_REPO")\"],\"permissions\":{\"statuses\":\"write\"}}" 2>/dev/null | jq -r '.token // empty' 2>/dev/null || true)
  fi
  if [[ -z $DEPLOY_STATUS_TOKEN ]]; then
    if ((DEPLOY_STATUS_HINTED == 0)); then
      DEPLOY_STATUS_HINTED=1
      hint "To see deploys as a check mark on each GitHub commit, give $A_GH_SOURCE \"Commit statuses: Read and write\" at"
      hint "$(gh_settings_url "$A_GH_SOURCE"), then accept the change on its install. (Or: fawwk github statuses off)"
    fi
    return 0
  fi
  [[ -n ${A_ROUTES-} ]] && url=$(route_url "${A_ROUTES%% *}")
  body=$(jq -nc --arg s "$state" --arg d "${desc:0:140}" --arg c "fawwk/$A_NAME" --arg u "$url" \
    '{state: $s, description: $d, context: $c} + (if $u == "" then {} else {target_url: $u} end)')
  gh_api "$DEPLOY_STATUS_TOKEN" POST "/repos/$(repo_path "$A_REPO")/statuses/$sha" "$body" >/dev/null 2>&1 || true
}

github_statuses() {
  case ${1-} in
    on | off)
      conf_set "$FAWWK_CONF" GH_STATUSES "$1"
      ok "Deploy status on GitHub commits: $1" ;;
    '') info "Deploy status on GitHub commits: ${GH_STATUSES:-on}"
        hint "New GitHub connections can post them. For one connected earlier, add \"Commit statuses: Read and write\" in its settings." ;;
    *) die "Usage: fawwk github statuses [on|off]" ;;
  esac
}

gh_install_url() { gh_load "$1"; printf 'https://github.com/apps/%s/installations/new' "$GH_SLUG"; }

# ---------- webhook receiver ----------
hooks_enabled() { [[ -f $FAWWK_ETC/hooks.enabled ]]; }

# Starts the fawwk-hooks container, routes panel.<domain> to it, and installs the systemd units
# that turn queued push jobs into deploys.
# The receiver's folders. $HOOKS_DIR itself stays root-only (700), so although the folders inside
# belong to the receiver's user, no other user on the host can reach them.
hooks_dirs() {
  mkdir -p "$HOOKS_DIR"/{secrets,pages,codes,inbox}
  chmod 700 "$HOOKS_DIR" "$HOOKS_DIR/secrets"
  chown -R "$HOOKS_UID:$HOOKS_UID" "$HOOKS_DIR"/{secrets,pages,codes,inbox}
}

# 0 if the receiver container exists and was created with the current run options.
hooks_container_current() {
  [[ $(docker inspect -f '{{index .Config.Labels "fawwk.hooks"}}' "$HOOKS_CONTAINER" 2>/dev/null) == "$HOOKS_REV" ]]
}

# (Re)creates the receiver container. It's internet-facing, so it gets as little as possible: no root,
# no capabilities, no privilege escalation, a read-only filesystem, and caps on memory and processes.
# On failure prints Docker's error and returns 1.
hooks_container_start() {
  local out
  hooks_dirs
  docker rm -f "$HOOKS_CONTAINER" >/dev/null 2>&1 || true
  # Pull separately and quietly so Docker's progress output doesn't break the screen.
  docker image inspect "$HOOKS_IMAGE" >/dev/null 2>&1 || docker pull -q "$HOOKS_IMAGE" >/dev/null 2>&1 || true
  out=$(docker run -d --name "$HOOKS_CONTAINER" --network "$FAWWK_NETWORK" --restart unless-stopped \
    --label "fawwk.hooks=$HOOKS_REV" --user "$HOOKS_UID:$HOOKS_UID" \
    --read-only --tmpfs /tmp --memory 64m --pids-limit 64 \
    --cap-drop ALL --security-opt no-new-privileges \
    -v "$FAWWK_HOME/lib/hooks.py:/app/hooks.py:ro" \
    -v "$HOOKS_DIR/secrets:/secrets:ro" -v "$HOOKS_DIR/pages:/pages:ro" \
    -v "$HOOKS_DIR/codes:/codes" -v "$HOOKS_DIR/inbox:/inbox" \
    --log-opt max-size=10m --log-opt max-file=3 \
    "$HOOKS_IMAGE" python -u /app/hooks.py 2>&1) || { printf '%s\n' "$out"; return 1; }
}

hooks_ensure() {
  [[ -n ${PANEL_HOST-} ]] || die "No panel domain configured. Re-run: sudo fawwk setup"
  touch "$FAWWK_ETC/hooks.enabled"
  if ! hooks_container_current; then
    # Missing, or created by an older Fawwk with weaker settings.
    spin_start "Starting the webhook receiver"
    local out
    out=$(hooks_container_start) || { spin_stop; err "Couldn't start the webhook receiver:"; printf '%s\n' "$out" | tail -n 5 | ui_quote; die "Check Docker, then run this again."; }
    spin_stop
  else
    hooks_dirs
    [[ $(docker inspect -f '{{.State.Running}}' "$HOOKS_CONTAINER" 2>/dev/null) == true ]] || docker start "$HOOKS_CONTAINER" >/dev/null
  fi
  ok "Webhook receiver running ($HOOKS_CONTAINER)"

  cat >/etc/systemd/system/fawwk-hooks.service <<EOF
[Unit]
Description=Fawwk: deploy apps for queued GitHub push webhooks
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$FAWWK_HOME/bin/fawwk hooks-run
EOF
  cat >/etc/systemd/system/fawwk-hooks.path <<EOF
[Unit]
Description=Fawwk: watch for GitHub push webhooks

[Path]
DirectoryNotEmpty=$HOOKS_DIR/inbox

[Install]
WantedBy=paths.target
EOF
  systemctl daemon-reload
  systemctl enable --now fawwk-hooks.path >/dev/null 2>&1
  proxy_reload || die "Couldn't route $PANEL_HOST to the webhook receiver."
  ok "https://$PANEL_HOST/hooks/github receives push events"
}

# Called by fawwk-hooks.service: deploys every app whose repo + branch got a push.
cmd_hooks_run() {
  require_root hooks-run; require_setup
  gh_need_jq >/dev/null
  mkdir -p "$FAWWK_LOG"
  local f repo branch sha name
  exec 8>/run/lock/fawwk-hooks.lock
  flock -n 8 || exit 0
  while true; do
    f=$(ls -1 "$HOOKS_DIR/inbox/"*.json 2>/dev/null | head -n1 || true)
    [[ -n $f ]] || break
    repo=$(jq -r '.repo // empty' "$f" 2>/dev/null | tr 'A-Z' 'a-z' || true)
    branch=$(jq -r '.branch // empty' "$f" 2>/dev/null || true)
    sha=$(jq -r '.sha // empty' "$f" 2>/dev/null || true)
    rm -f "$f"
    [[ -n $repo && -n $branch ]] || continue
    printf '[%s] push to %s@%s (%s)\n' "$(ts)" "$repo" "$branch" "${sha:0:7}" >>"$FAWWK_LOG/hooks.log"
    while IFS= read -r name; do
      [[ -z $name ]] && continue
      (
        app_load "$name"
        [[ $(repo_path "$A_REPO" | tr 'A-Z' 'a-z') == "$repo" && $A_BRANCH == "$branch" ]] || exit 0
        [[ $A_AUTO == yes && $A_STATE != stopped ]] || exit 0
        auto_deploy "$name" "$sha" hooks.log
      ) || true
    done < <(app_names)
  done
}

# gh_update_hook_urls — after the panel domain changes, points every connected GitHub App's
# webhook at the new https://<panel>/hooks/github (GitHub would keep sending to the old one).
gh_update_hook_urls() {
  local src url="https://$PANEL_HOST/hooks/github"
  gh_have_sources || return 0
  gh_need_jq >/dev/null
  while IFS= read -r src; do
    [[ -z $src ]] && continue
    if gh_api "$(gh_jwt "$src")" PATCH /app/hook/config "{\"url\":\"$url\"}" >/dev/null 2>&1; then
      ok "GitHub App $src now sends webhooks to $url"
    else
      gh_load "$src"
      warn "Couldn't update $src's webhook URL. Set it to $url at $GH_HTML_URL"
    fi
  done < <(gh_sources)
}

# ---------- `fawwk github` ----------
github_usage() {
  cat <<'EOF'
Usage: sudo fawwk github [command]

  (none) | list        Connected GitHub accounts and the repos each can reach
  connect [--org ORG]  Connect a GitHub account (or an organization) with a one-click GitHub App
  install [name]       Link to pick which repos the app can access
  remove <name>        Forget a connection (then delete the app on GitHub)
  statuses [on|off]    Show each deploy as a check mark or cross on its commit (default: on)

Connect once per GitHub account or organization. Repos with the app installed need no deploy keys
or tokens, and every push deploys right away through a webhook.
EOF
}

cmd_github() {
  local sub=${1:-list}
  (($#)) && shift
  case $sub in -h | --help | help) github_usage; return 0 ;; esac
  require_root github; require_setup
  gh_need_jq
  case $sub in
    list | ls) github_list ;;
    connect | add) github_connect "$@" ;;
    install) github_install "${1-}" ;;
    remove | rm) github_remove "${1-}" ;;
    statuses | status) github_statuses "${1-}" ;;
    *) github_usage; return 1 ;;
  esac
}

github_list() {
  local src jwt n=0 inst repos
  while IFS= read -r src; do
    [[ -z $src ]] && continue
    n=$((n + 1))
    gh_load "$src"
    step "$GH_SLUG ${C_MUTED}($GH_OWNER)${C_RESET}"
    jwt=$(gh_jwt "$src")
    inst=$(gh_api "$jwt" GET /app/installations 2>/dev/null) || { warn "GitHub didn't answer for this app. Was it deleted on GitHub?"; continue; }
    if [[ $(jq 'length' <<<"$inst") == 0 ]]; then
      warn "Not installed on any repo yet: $(gh_install_url "$src")"
      continue
    fi
    local id acct tok
    while read -r id acct; do
      tok=$(gh_api "$jwt" POST "/app/installations/$id/access_tokens" '{}' 2>/dev/null | jq -r '.token // empty') || true
      repos=''
      [[ -n $tok ]] && repos=$(gh_api "$tok" GET "/installation/repositories?per_page=100" 2>/dev/null |
        jq -r '.repositories[].full_name' 2>/dev/null | tr '\n' ' ' || true)
      ok "Installed on ${C_BOLD}$acct${C_RESET}: ${repos:-no repos selected}"
    done < <(jq -r '.[] | "\(.id) \(.account.login)"' <<<"$inst")
    hint "Add or remove repos: $(gh_install_url "$src")"
  done < <(gh_sources)
  if ((n == 0)); then
    info "No GitHub accounts connected yet."
    hint "Connect one with: sudo fawwk github connect"
  fi
  printf '\n' >&2
}

# One-click GitHub App creation (GitHub's "manifest flow"): the browser posts a manifest to GitHub,
# GitHub creates the app under the user's account and redirects back with a code that we exchange
# for the app's id, private key and webhook secret.
github_connect() {
  local org=''
  while (($#)); do
    case $1 in
      --org) need_arg "$@"; org=$2; shift 2 ;;
      *) die "Unknown option: $1 (see: fawwk github --help)" ;;
    esac
  done
  ui_banner "Connect GitHub ${G_SEP} a private GitHub App owned by ${org:-your account}"
  step "Webhook receiver"
  dns_report "$PANEL_HOST"
  hooks_ensure
  github_check_reachable

  step "Create the GitHub App"
  local state name manifest page action base="https://$PANEL_HOST"
  state=$(openssl rand -hex 16)
  name="fawwk-$(hostname -s | tr -cd 'a-zA-Z0-9-' | cut -c1-18)-$(openssl rand -hex 2)"
  manifest=$(jq -nc --arg name "$name" --arg base "$base" '{
      name: $name, url: $base, public: false,
      hook_attributes: {url: ($base + "/hooks/github"), active: true},
      redirect_url: ($base + "/github/callback"),
      setup_url: ($base + "/github/installed"),
      default_permissions: {contents: "read", metadata: "read", statuses: "write"},
      default_events: ["push"] }')
  if [[ -n $org ]]; then action="https://github.com/organizations/$org/settings/apps/new?state=$state"
  else action="https://github.com/settings/apps/new?state=$state"
  fi
  manifest=${manifest//&/&amp;}; manifest=${manifest//\"/&quot;}; manifest=${manifest//</&lt;}; manifest=${manifest//>/&gt;}
  page="$HOOKS_DIR/pages/$state.html"
  cat >"$page" <<EOF
<!doctype html><html><head><meta charset="utf-8"><title>Fawwk: connect GitHub</title></head>
<body style="font:16px system-ui;max-width:32rem;margin:15vh auto;padding:0 1rem">
<form id="f" method="post" action="$action"><input type="hidden" name="manifest" value="$manifest">
<p>Sending you to GitHub to create the Fawwk app&hellip;</p><button type="submit">Continue to GitHub</button></form>
<script>document.getElementById('f').submit()</script></body></html>
EOF
  chmod 644 "$page"
  info "Open this link in a browser where you're logged in to GitHub${org:+ (as an admin of $org)}:"
  printf '\n    %s%s/github/setup/%s%s\n\n' "$C_ACCENT2" "$base" "$state" "$C_RESET" >&2
  hint "Click 'Create GitHub App' on the page GitHub shows. Fawwk picks it up automatically."

  local code='' deadline=$((SECONDS + 900))
  spin_start "Waiting for GitHub (ctrl+c to cancel)"
  while ((SECONDS < deadline)); do
    [[ -s $HOOKS_DIR/codes/$state ]] && { code=$(cat "$HOOKS_DIR/codes/$state"); break; }
    sleep 1
  done
  spin_stop
  rm -f "$page" "$HOOKS_DIR/codes/$state"
  [[ -n $code ]] || die "Timed out waiting for GitHub. Run: sudo fawwk github connect"

  local resp slug d
  resp=$(curl -fsS --max-time 20 -X POST -H "Accept: application/vnd.github+json" \
    "$GH_API/app-manifests/$code/conversions") || die "GitHub didn't accept the setup code. Run: sudo fawwk github connect"
  slug=$(jq -r '.slug // empty' <<<"$resp")
  [[ $slug =~ ^[a-z0-9-]+$ ]] || die "Unexpected answer from GitHub."
  d="$GH_ETC/$slug"
  mkdir -p "$d"; chmod 700 "$GH_ETC" "$d"
  (umask 077
    jq -r '.pem' <<<"$resp" >"$d/key.pem"
    jq -r '.webhook_secret' <<<"$resp" >"$HOOKS_DIR/secrets/$slug")
  chown "$HOOKS_UID:$HOOKS_UID" "$HOOKS_DIR/secrets/$slug"   # the receiver checks signatures with it
  conf_set "$d/app.conf" GH_APP_ID "$(jq -r '.id' <<<"$resp")"
  conf_set "$d/app.conf" GH_SLUG "$slug"
  conf_set "$d/app.conf" GH_OWNER "$(jq -r '.owner.login' <<<"$resp")"
  conf_set "$d/app.conf" GH_OWNER_TYPE "$(jq -r '.owner.type // "User"' <<<"$resp")"
  conf_set "$d/app.conf" GH_HTML_URL "$(jq -r '.html_url' <<<"$resp")"
  ok "Created GitHub App ${C_BOLD}$slug${C_RESET} for $(jq -r '.owner.login' <<<"$resp")"

  github_install "$slug"
}

# GitHub (and your browser) must reach https://<panel>/github/... Check it from here before waiting.
github_check_reachable() {
  local url="https://$PANEL_HOST/github/installed" i
  spin_start "Checking that $PANEL_HOST is reachable over HTTPS"
  # The first request also makes Caddy fetch the HTTPS certificate, which can take a few seconds.
  for i in 1 2 3 4 5 6; do
    curl -fsS --max-time 15 -o /dev/null "$url" 2>/dev/null && { spin_stop; ok "https://$PANEL_HOST is reachable"; return 0; }
    sleep 5
  done
  spin_stop
  err "https://$PANEL_HOST isn't reachable, so GitHub can't send you back here."
  if [[ -z $(dns_lookup "$PANEL_HOST") ]]; then
    info "Add this DNS record with your DNS provider, wait a few minutes, then run this again:"
    printf '\n      %-6s %-28s %s\n\n' A "${PANEL_HOST%%.*}   (or * for all subdomains)" "${SERVER_IP:-<server ip>}" >&2
  else
    info "DNS resolves, but HTTPS failed. Check: fawwk proxy logs"
  fi
  hint "Want a different name than '${PANEL_HOST%%.*}'? Re-run: sudo fawwk setup --panel <name>"
  FAWWK_DIED=1; exit 1
}

github_install() {
  local src=${1-} jwt n deadline
  if [[ -z $src ]]; then
    src=$(gh_sources | head -n1)
    [[ -n $src ]] || die "No GitHub account connected. Run: sudo fawwk github connect"
  fi
  gh_load "$src"
  step "Pick repos for $GH_SLUG"
  info "Open this link, choose the repos Fawwk may deploy, and click Install:"
  printf '\n    %s%s%s\n\n' "$C_ACCENT2" "$(gh_install_url "$src")" "$C_RESET" >&2
  is_interactive || return 0
  jwt=$(gh_jwt "$src")
  n=$(gh_api "$jwt" GET /app/installations 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
  ((n > 0)) && { ok "Already installed. Use the link to add more repos any time."; return 0; }
  local jwt_at=$SECONDS
  deadline=$((SECONDS + 900))
  spin_start "Waiting for you to install it (ctrl+c to skip)"
  while ((SECONDS < deadline)); do
    sleep 3
    # JWTs last 9 minutes; get a fresh one well before that.
    ((SECONDS - jwt_at >= 300)) && { jwt=$(gh_jwt "$src"); jwt_at=$SECONDS; }
    n=$(gh_api "$jwt" GET /app/installations 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
    ((n > 0)) && break
  done
  spin_stop
  if ((n > 0)); then
    ok "Installed. New apps from these repos need no keys, and pushes deploy instantly."
    hint "Deploy one now: sudo fawwk create"
  else
    warn "Not installed yet. Do it later with: sudo fawwk github install"
  fi
}

github_remove() {
  local src=${1-} name
  [[ -n $src ]] || die "Usage: fawwk github remove <name>   (see: fawwk github)"
  gh_load "$src"
  while IFS= read -r name; do
    [[ -z $name ]] && continue
    ( app_load "$name"; [[ $A_AUTH == github && $A_GH_SOURCE == "$src" ]] ) &&
      die "App '$name' uses $src. Remove it, or switch its access first: fawwk access $name deploykey"
  done < <(app_names)
  confirm "Forget $src on this server?" N || return 1
  rm -rf "${GH_ETC:?}/$src" "$HOOKS_DIR/secrets/$src"
  ok "Removed. Also delete the app on GitHub: $GH_HTML_URL/advanced"
}
