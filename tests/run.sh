#!/usr/bin/env bash
# Fawwk's test suite: plain bash, no dependencies, never touches the real server. Everything runs
# against a throwaway FAWWK_ETC/FAWWK_VAR/FAWWK_LOG and a stub `docker`. Run as root (CI: sudo):
# the commands under test check for it, and app locks live in /run/lock.
#
#   tests/run.sh            run everything
#   tests/run.sh routes     only tests whose name contains "routes"
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FILTER=${1-}
PASS=0 FAIL=0 FAILED=()

# ---------- harness ----------
new_sandbox() {
  SB=$(mktemp -d)
  export FAWWK_ETC=$SB/etc FAWWK_VAR=$SB/var FAWWK_LOG=$SB/log FAWWK_CRON_DIR=$SB/cron.d FAWWK_HOME=$ROOT
  export FAWWK_LOGROTATE_DIR=$SB/logrotate.d
  export FAKE_DOCKER_ROOT=$SB/docker NO_COLOR=1
  mkdir -p "$FAWWK_ETC/apps" "$FAWWK_VAR/apps" "$FAWWK_LOG" "$FAWWK_CRON_DIR" "$FAWWK_LOGROTATE_DIR" "$SB/bin" \
    "$FAKE_DOCKER_ROOT/volumes"
  printf 'DOMAIN=example.com\nEMAIL=ops@example.com\nPANEL_SUB=panel\nPANEL_HOST=panel.example.com\nSERVER_IP=203.0.113.7\n' >"$FAWWK_ETC/fawwk.conf"
  # A docker stub: enough for the code paths under test, silent success for the rest.
  cat >"$SB/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1 ${2-}" in
  "info -f") echo "$FAKE_DOCKER_ROOT" ;;
  "info "*) exit 0 ;;
  "volume create") mkdir -p "$FAKE_DOCKER_ROOT/volumes/$3/_data"; echo "$3" ;;
  "inspect "* | "image inspect" | "volume inspect") exit 1 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$SB/bin/docker"
  export PATH="$SB/bin:$PATH"
}

# Loads fawwk's libraries into the current (sub)shell, like bin/fawwk does.
load_fawwk() {
  local l
  for l in ui common git github env build proxy release notify setup create manage settings maint doctor; do
    # shellcheck disable=SC1090
    source "$ROOT/lib/$l.sh"
  done
  # shellcheck disable=SC1090
  source "$FAWWK_CONF"
}

# add_app NAME KEY=VALUE... — writes an app.conf.
add_app() {
  local name=$1 kv
  shift
  mkdir -p "$FAWWK_ETC/apps/$name"
  {
    printf 'A_NAME=%q\n' "$name"
    for kv in "$@"; do printf '%s=%q\n' "${kv%%=*}" "${kv#*=}"; done
  } >"$FAWWK_ETC/apps/$name/app.conf"
}

eq() {
  [[ $1 == "$2" ]] && return 0
  printf '      expected: %q\n      got:      %q\n' "$2" "$1" >&2
  return 1
}
has() {
  [[ $1 == *"$2"* ]] && return 0
  printf '      expected to contain: %q\n      in: %s\n' "$2" "$1" >&2
  return 1
}
# no CMD... — CMD must fail. (A bare `! cmd` never fails a test under set -e.)
no() {
  if "$@"; then printf '      expected to fail: %s\n' "$*" >&2; return 1; fi
  return 0
}
hasnt() {
  [[ $1 != *"$2"* ]] && return 0
  printf '      expected NOT to contain: %q\n' "$2" >&2
  return 1
}

t() {
  local name=$1
  [[ -z $FILTER || $name == *"$FILTER"* ]] || return 0
  local rc=0 out
  out=$(mktemp)
  # Not inside `if (...)`: errexit would be off for the whole test and only its last line would count.
  set +e
  (set -e; trap 'echo "      failed at line $LINENO: $BASH_COMMAND" >&2' ERR
    new_sandbox; trap 'rm -rf "$SB"' EXIT; "test_$name") >"$out" 2>&1
  rc=$?
  set -e
  if ((rc == 0)); then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); FAILED+=("$name"); printf '  FAIL  %s\n' "$name"
    sed 's/^/        /' "$out" | tail -n 25
  fi
  rm -f "$out"
}

# ---------- tests ----------
test_env_parse() {
  load_fawwk
  local out
  out=$(printf '%s\n' 'A=1' 'B="two words" # c' "C='x#y'" 'D=val # comment' 'E=val#keep' 'export F=6' \
    'H=' 'URL=postgres://u:p@h/db?sslmode=require' '# comment' '' $'G=crlf\r' | env_parse 2>/dev/null)
  eq "$out" $'A=1\nB=two words\nC=x#y\nD=val\nE=val#keep\nF=6\nH=\nURL=postgres://u:p@h/db?sslmode=require\nG=crlf'
}

test_env_merge_later_wins_keeps_order() {
  load_fawwk
  printf 'A=1\nB=2\n' >"$SB/a"; printf 'B=3\nC=4\n' >"$SB/b"
  eq "$(env_merge "$SB/a" "$SB/b")" $'A=1\nB=3\nC=4'
}

test_route_normalize() {
  load_fawwk
  eq "$(route_normalize 'HTTPS://Example.COM/API/V1/')" 'example.com/API/V1'
  eq "$(route_normalize 'api.example.com')" 'api.example.com'
}

test_validation() {
  load_fawwk
  valid_route example.com/api 2>/dev/null
  valid_route api.example.com 2>/dev/null
  no valid_route 'example.com/a b' 2>/dev/null
  no valid_route 'not a domain' 2>/dev/null
  valid_app_name my-app 2>/dev/null
  no valid_app_name My_App 2>/dev/null
  no valid_app_name a 2>/dev/null
  valid_subdir apps/web 2>/dev/null
  no valid_subdir ../etc 2>/dev/null
  no valid_subdir /abs 2>/dev/null
  eq "$(sanitize_name 'My_Repo.Name')" my-repo-name
}

test_repo_urls() {
  load_fawwk
  eq "$(repo_https you/app)" https://github.com/you/app.git
  eq "$(repo_https git@gitlab.com:team/app.git)" https://gitlab.com/team/app.git
  eq "$(repo_ssh https://github.com/you/app)" git@github.com:you/app.git
  eq "$(repo_path https://github.com/you/app.git)" you/app
  eq "$(repo_slug you/app)" app
}

test_proxy_routes_order_and_states() {
  load_fawwk
  add_app web A_ROUTES=example.com A_STATE=running A_CONTAINER=fawwk-web-1 A_PORT=3000
  add_app api 'A_ROUTES=example.com/api api.example.com' A_STATE=running A_CONTAINER=fawwk-api-1 A_PORT=8000 A_STRIP=yes
  add_app v2 A_ROUTES=example.com/api/v2 A_STATE=stopped A_CONTAINER=fawwk-v2-1 A_PORT=8000 A_STRIP=no
  add_app worker A_ROUTES=
  local out
  out=$(proxy_render)
  has "$out" $'api.example.com {\n\tencode zstd gzip\n\t# app: api\n\thandle {\n\t\treverse_proxy fawwk-api-1:8000'
  # Longest path first; the stopped app answers 503 and keeps its prefix.
  has "$out" $'@r1 path /api/v2 /api/v2/*\n\thandle @r1 {\n\t\trespond "Service unavailable" 503'
  has "$out" $'@r2 path /api /api/*\n\thandle @r2 {\n\t\turi strip_prefix /api\n\t\treverse_proxy fawwk-api-1:8000'
  hasnt "$out" 'worker'
  hasnt "$out" 'panel.example.com'   # webhooks not enabled
  touch "$FAWWK_ETC/hooks.enabled"
  has "$(proxy_render)" $'panel.example.com {'
}

test_route_conflicts() {
  load_fawwk
  add_app web A_ROUTES='example.com www.example.com'
  no route_check www.example.com other 2>/dev/null
  route_check www.example.com web 2>/dev/null
  no route_check panel.example.com other 2>/dev/null
  route_check new.example.com other 2>/dev/null
}

test_build_detection() {
  load_fawwk
  local d=$SB/ctx
  mkdir -p "$d"
  eq "$(build_detect "$d")" nixpacks
  touch "$d/index.html"; eq "$(build_detect "$d")" static
  touch "$d/package.json"; eq "$(build_detect "$d")" nixpacks
  printf 'FROM node:20\nEXPOSE 4000\n' >"$d/DOCKERFILE"
  eq "$(build_detect "$d")" dockerfile
  eq "$(build_dockerfile "$d")" "$d/DOCKERFILE"
  eq "$(build_port_hint "$d" dockerfile)" 4000
}

test_dockerfile_missing_files() {
  load_fawwk
  local d=$SB/ctx
  mkdir -p "$d"; touch "$d/package.json"
  printf '%s\n' 'FROM node:20 AS build' 'COPY package.json package-lock.json ./' 'COPY --chown=node . .' \
    'COPY --from=build /app /app' 'ADD https://example.com/x.tgz /tmp/' 'COPY src/*.js ./' >"$d/Dockerfile"
  eq "$(build_dockerfile_missing "$d")" package-lock.json
}

test_build_env_filter() {
  load_fawwk
  A_BUILD_ENV=''; build_env_allowed SECRET
  A_BUILD_ENV=all; build_env_allowed SECRET
  A_BUILD_ENV=none; no build_env_allowed SECRET
  A_BUILD_ENV=NEXT_PUBLIC_URL,NODE_ENV
  build_env_allowed NODE_ENV
  no build_env_allowed SECRET
  no build_env_allowed NODE   # whole names only
}

test_deploy_ids_are_unique() {
  load_fawwk
  local a b
  a=$(deploy_id); b=$(deploy_id)
  [[ $a =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$ ]] || { echo "bad id: $a"; return 1; }
  [[ $a != "$b" ]]
}

test_run_args_limits_volumes() {
  load_fawwk
  add_app api A_ROUTES=api.example.com A_PORT=8000 A_MEMORY=512m A_CPUS=1.5 'A_VOLUMES=/app/data /var/uploads'
  app_load api
  app_run_args
  local s=" ${RUN_ARGS[*]} "
  has "$s" ' --memory 512m '
  has "$s" ' --cpus 1.5 '
  has "$s" ' -v fawwk_api_app-data:/app/data '
  has "$s" ' -v fawwk_api_var-uploads:/var/uploads '
  has "$s" ' -e PORT=8000 '
  has "$s" ' --security-opt no-new-privileges:true '
  # PORT from the app's own env wins.
  printf 'PORT=9000\n' >"$(app_envfile api)"
  app_run_args
  hasnt " ${RUN_ARGS[*]} " ' -e PORT='
}

test_cron_jobs() {
  load_fawwk
  add_app api A_ROUTES=api.example.com
  app_load api
  valid_cron_schedule '*/5 * * * *'
  valid_cron_schedule '@daily'
  no valid_cron_schedule '* * * *'
  no valid_cron_schedule '* * * * * ; rm -rf /'
  FAWWK_YES=1
  cmd_cron api add "0 3 * * *" npm run cleanup 2>/dev/null
  cmd_cron api add '@hourly' 'echo "100%" done' 2>/dev/null
  local f=$CRON_DIR/fawwk-api
  has "$(cat "$f")" "0 3 * * * root $ROOT/bin/fawwk cron-run api 1 >>$FAWWK_LOG/api-cron.log 2>&1"
  has "$(cat "$f")" "@hourly root $ROOT/bin/fawwk cron-run api 2"
  hasnt "$(cat "$f")" '100%'   # commands never go into the crontab itself
  has "$(cmd_info api 2>&1)" 'Cron jobs      2'
  cmd_cron api rm 1 2>/dev/null
  hasnt "$(cat "$f")" 'cron-run api 1'
  cmd_cron api rm 2 2>/dev/null
  [[ ! -e $f ]]
}

test_notify_payload() {
  load_fawwk
  cat >"$SB/bin/curl" <<EOF
#!/usr/bin/env bash
while ((\$#)); do [[ \$1 == -d ]] && { printf '%s' "\$2" >"$SB/posted"; shift; }; shift; done
EOF
  chmod +x "$SB/bin/curl"
  NOTIFY_URL=https://hooks.example.com/x NOTIFY_ON=fail
  notify ok api abc 'deployed'
  [[ ! -e $SB/posted ]]   # successes are skipped unless NOTIFY_ON=all
  notify failed api abc123 'it "broke"'
  eq "$(jq -r '.text + "|" + .content + "|" + .status + "|" + .app' "$SB/posted")" 'it "broke"|it "broke"|failed|api'
}

test_cli_help_and_version() {
  local out
  out=$("$ROOT/bin/fawwk" help 2>&1)
  has "$out" 'volume <app>'
  has "$out" 'notify'
  [[ $("$ROOT/bin/fawwk" version) =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]
}

test_cli_deliberate_failure_is_not_a_crash() {
  local out rc=0
  out=$("$ROOT/bin/fawwk" frobnicate 2>&1) || rc=$?
  eq "$rc" 1
  has "$out" 'Unknown command'
  hasnt "$out" 'stopped unexpectedly'
  # A command that shows its usage and returns 1 (needs root: run where we have it).
  if [[ $EUID -eq 0 ]]; then
    rc=0
    out=$("$ROOT/bin/fawwk" github bogus 2>&1) || rc=$?
    eq "$rc" 1
    hasnt "$out" 'stopped unexpectedly'
  fi
}

test_backup_restore_roundtrip() {
  [[ $EUID -eq 0 ]] || { echo "skipped (needs root for chmod/ownership semantics)"; return 0; }
  load_fawwk
  add_app api A_ROUTES=api.example.com A_STATE=running A_CONTAINER=fawwk-api-1 A_IMAGE=fawwk/api:1 A_COMMIT=abc 'A_VOLUMES=/data'
  printf 'SECRET=s3cret\n' >"$(app_envfile api)"
  printf '1\t1\t-\tok\tfirst\n' >"$FAWWK_ETC/apps/api/history"
  mkdir -p "$FAKE_DOCKER_ROOT/volumes/fawwk_api_data/_data" "$FAKE_DOCKER_ROOT/volumes/fawwk_caddy_data/_data"
  echo rows >"$FAKE_DOCKER_ROOT/volumes/fawwk_api_data/_data/db.sqlite"
  echo cert >"$FAKE_DOCKER_ROOT/volumes/fawwk_caddy_data/_data/cert.pem"
  cmd_backup "$SB/b.tgz" --with-data 2>/dev/null
  [[ $(stat -c %a "$SB/b.tgz") == 600 ]]
  # Restore onto an empty "server".
  rm -rf "$FAWWK_ETC" "$FAKE_DOCKER_ROOT/volumes"/*
  mkdir -p "$FAWWK_ETC"
  cmd_restore "$SB/b.tgz" 2>/dev/null
  eq "$(cat "$FAWWK_ETC/apps/api/env")" SECRET=s3cret
  eq "$(cat "$FAKE_DOCKER_ROOT/volumes/fawwk_api_data/_data/db.sqlite")" rows
  eq "$(cat "$FAKE_DOCKER_ROOT/volumes/fawwk_caddy_data/_data/cert.pem")" cert
  app_load api
  eq "$A_STATE|$A_CONTAINER|$A_IMAGE" 'new||'
  [[ ! -e $FAWWK_ETC/apps/api/history ]]
}

test_hooks_receiver() {
  command -v python3 >/dev/null || { echo "skipped (no python3)"; return 0; }
  python3 -I "$ROOT/tests/test_hooks.py" "$ROOT/lib/hooks.py"
}

test_settings_commands() {
  load_fawwk
  add_app api A_ROUTES=api.example.com A_PORT=8000 A_STATE=new A_AUTH=public A_REPO=https://github.com/me/api.git A_BRANCH=main
  FAWWK_YES=1
  cmd_limits api memory=512M cpus=1 2>/dev/null
  cmd_volume api add /app/data 2>/dev/null
  cmd_release api npm run migrate 2>/dev/null
  cmd_buildenv api 'NODE_ENV, NEXT_PUBLIC_URL' 2>/dev/null
  cmd_health api /healthz --timeout 180 2>/dev/null
  app_load api
  eq "$A_MEMORY|$A_CPUS|$A_VOLUMES|$A_RELEASE|$A_BUILD_ENV|$A_HEALTH|$A_HEALTH_TIMEOUT" \
    '512m|1|/app/data|npm run migrate|NEXT_PUBLIC_URL,NODE_ENV|/healthz|180'
  exec 9>&-   # release the app lock this shell holds, or the subshells below would wait for it
  (cmd_limits api memory=lots 2>/dev/null) && return 1
  (cmd_limits api cpus=9999 2>/dev/null) && return 1
  (cmd_volume api add relative/path 2>/dev/null) && return 1
  (cmd_buildenv api 'BAD-NAME' 2>/dev/null) && return 1
  cmd_limits api memory=off cpus=off 2>/dev/null
  cmd_release api off 2>/dev/null
  cmd_volume api rm /app/data 2>/dev/null
  cmd_buildenv api all 2>/dev/null
  app_load api
  eq "$A_MEMORY|$A_CPUS|$A_VOLUMES|$A_RELEASE|$A_BUILD_ENV" '||||'
}

test_json_output() {
  load_fawwk
  add_app api 'A_ROUTES=api.example.com example.com/api' A_PORT=8000 A_STATE=new A_REPO=https://github.com/me/api.git \
    A_BRANCH=main A_AUTO=yes 'A_VOLUMES=/data' A_IMAGE=fawwk/api:2
  printf 'SECRET=hunter2\n' >"$(app_envfile api)"
  printf 'id1\tc1\tfawwk/api:1\tok\tfirst\nid2\tc2\tfawwk/api:2\tok\tsecond\n' >"$FAWWK_ETC/apps/api/history"
  local out
  out=$(cmd_info api --json)
  eq "$(jq -r '[.name, .repo, (.urls | join(",")), (.port | tostring), .auto_deploy, .volumes[0], .env_count] | map(tostring) | join("|")' <<<"$out")" \
    'api|me/api|https://api.example.com,https://example.com/api|8000|true|/data|1'
  hasnt "$out" hunter2
  eq "$(cmd_list --json | jq -r 'length')" 1
  eq "$(cmd_history api --json | jq -r 'map(.id + ":" + (.live | tostring)) | join(",")')" 'id2:true,id1:false'
}

test_env_unset_and_domain_rm_are_literal() {
  load_fawwk
  add_app api 'A_ROUTES=a.example.com abexample.com' A_PORT=8000 A_STATE=new
  printf 'A.B=1\nAXB=2\nKEEP=3\n' >"$(app_envfile api)"
  FAWWK_YES=1
  cmd_env api unset A.B 2>/dev/null
  eq "$(cat "$(app_envfile api)")" $'AXB=2\nKEEP=3'
  cmd_domain api rm a.example.com 2>/dev/null
  app_load api
  eq "$A_ROUTES" abexample.com
}

test_notify_settings() {
  load_fawwk
  printf '#!/bin/sh\nexit 0\n' >"$SB/bin/curl"; chmod +x "$SB/bin/curl"
  cmd_notify https://hooks.slack.com/services/x --all 2>/dev/null
  # shellcheck disable=SC1090
  source "$FAWWK_CONF"
  eq "$NOTIFY_URL|$NOTIFY_ON" 'https://hooks.slack.com/services/x|all'
  cmd_notify off 2>/dev/null
  # shellcheck disable=SC1090
  source "$FAWWK_CONF"
  eq "${NOTIFY_URL-}" ''
}

# A docker stub that behaves like a healthy daemon and records every call in $SB/docker.log.
smart_docker() {
  cat >"$SB/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_DOCKER_ROOT/../docker.log"
case "$*" in
  "run --rm "*) [[ -n ${FAIL_RELEASE-} ]] && { echo "migration exploded"; exit 1; }; echo "migrated"; exit 0 ;;
  "inspect -f {{.State.Status}} {{.RestartCount}} "*) echo "running 0" ;;
  "inspect -f {{with index .NetworkSettings.Networks"*) echo 127.0.0.1 ;;
  "inspect -f {{.State.Running}} "*) echo true ;;
  "inspect -f {{.State.OOMKilled}} "*) echo false ;;
  "ps -a --filter label=fawwk.app="*) cat "$FAKE_DOCKER_ROOT/../containers" 2>/dev/null ;;
  "images "*) ;;
  build*) echo "Step 1/1 : FROM scratch" ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$SB/bin/docker"
}

test_deploy_pipeline_end_to_end() {
  command -v git >/dev/null && command -v python3 >/dev/null || { echo "skipped (needs git + python3)"; return 0; }
  load_fawwk
  smart_docker
  # The "app": a real HTTP server the health check can reach on 127.0.0.1.
  local port
  port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  python3 -m http.server "$port" --bind 127.0.0.1 --directory "$SB" >/dev/null 2>&1 &
  APP_PID=$!
  trap 'kill $APP_PID 2>/dev/null; rm -rf "$SB"' EXIT
  # A real git repo to deploy from (fawwk adds .git to repo URLs).
  git init -q -b main "$SB/repo.git"
  printf 'FROM scratch\nEXPOSE 3000\n' >"$SB/repo.git/Dockerfile"
  git -C "$SB/repo.git" add . && git -C "$SB/repo.git" -c user.email=t@t -c user.name=t commit -qm "first commit"
  local sha
  sha=$(git -C "$SB/repo.git" rev-parse HEAD)
  add_app api A_REPO="$SB/repo" A_BRANCH=main A_AUTH=public A_DIR=. A_BUILD=auto A_ROUTES=api.example.com \
    A_PORT="$port" A_STATE=new A_AUTO=yes A_MEMORY=256m A_VOLUMES=/data A_RELEASE='npm run migrate'
  HEALTH_TIMEOUT=10
  echo fawwk-api-old >"$SB/containers"

  deploy_app api 2>"$SB/out" || { cat "$SB/out"; return 1; }
  app_load api
  eq "$A_STATE|$A_COMMIT" "running|$sha"
  [[ $A_CONTAINER =~ ^fawwk-api-[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$ ]]
  local log
  log=$(cat "$SB/docker.log")
  has "$log" "-c npm run migrate"                  # release command ran...
  has "$log" "--entrypoint sh fawwk/api:"          # ...in the new image
  has "$log" "-v fawwk_api_data:/data"
  has "$log" "--memory 256m"
  has "$log" "stop -t 15 fawwk-api-old"            # the old container was retired
  has "$(tail -n1 "$FAWWK_ETC/apps/api/history")" $'\tok\tfirst commit'
  has "$(cat "$CADDY_DIR/Caddyfile")" "reverse_proxy $A_CONTAINER:$port"

  # Triggered again for the same commit (webhook + timer racing): skipped once the lock is held.
  : >"$SB/docker.log"
  deploy_app api "$sha" 2>/dev/null
  eq "$DEPLOY_SKIPPED" 1
  hasnt "$(cat "$SB/docker.log")" build

  # A failing release command stops the deploy; the live version is untouched.
  local live=$A_CONTAINER
  git -C "$SB/repo.git" -c user.email=t@t -c user.name=t commit -qm "second" --allow-empty
  FAIL_RELEASE=1 deploy_app api 2>/dev/null && return 1
  app_load api
  eq "$A_CONTAINER|$A_COMMIT" "$live|$sha"
  eq "$A_FAILED_COMMIT" "$(git -C "$SB/repo.git" rev-parse HEAD)"
  has "$(tail -n1 "$FAWWK_ETC/apps/api/history")" $'\tfailed\trelease command failed'

  # Automated deploys: a repeat is logged as skipped; a failure is logged and sends a notification.
  local real_curl
  real_curl=$(command -v curl)
  cat >"$SB/bin/curl" <<EOF
#!/usr/bin/env bash
[[ "\$*" == *notify.example* ]] || exec "$real_curl" "\$@"
while ((\$#)); do [[ \$1 == -d ]] && { printf '%s' "\$2" >"$SB/posted"; shift; }; shift; done
EOF
  chmod +x "$SB/bin/curl"
  NOTIFY_URL=https://notify.example/hook NOTIFY_ON=fail
  exec 9>&-   # this shell still holds the app lock from deploy_app above; sync/hooks loops never do
  auto_deploy api "$sha" sync.log 2>/dev/null
  has "$(cat "$FAWWK_LOG/sync.log")" "api: already at ${sha:0:7}, skipped"
  [[ ! -e $SB/posted ]]
  git -C "$SB/repo.git" -c user.email=t@t -c user.name=t commit -qm "third" --allow-empty
  local third
  third=$(git -C "$SB/repo.git" rev-parse HEAD)
  FAIL_RELEASE=1 auto_deploy api "$third" sync.log 2>/dev/null
  has "$(cat "$FAWWK_LOG/sync.log")" "api: deploy of ${third:0:7} FAILED"
  eq "$(jq -r '.status + " " + .app + " " + .commit' "$SB/posted")" "failed api $third"
}

# fawwk update on a shallow install whose upstream branch was force-rewritten (no fast-forward possible),
# with local edits (kept unless confirmed), and switching branches with --branch.
test_update_follows_rewritten_history() {
  [[ $EUID -eq 0 ]] || { echo "skipped (needs root)"; return 0; }
  local o=$SB/origin home=$SB/opt-fawwk gc=(-c user.email=t@t -c user.name=t) out rc
  git init -q -b main "$o"
  (cd "$ROOT" && git ls-files -co --exclude-standard -z | xargs -0 cp --parents -t "$o")
  git -C "$o" add -A && git -C "$o" "${gc[@]}" commit -qm "v1"
  git clone -q --depth 1 "file://$o" "$home"
  # Upstream rewrites main: the installed commit is no longer an ancestor.
  echo rewritten >"$o/MARKER"
  git -C "$o" add -A && git -C "$o" "${gc[@]}" commit -q --amend -m "v1, rewritten"
  out=$("$home/bin/fawwk" update 2>&1) || { echo "$out"; return 1; }
  eq "$(git -C "$home" rev-parse HEAD)" "$(git -C "$o" rev-parse HEAD)"
  has "$out" "Fawwk updated"
  [[ -f $FAWWK_LOGROTATE_DIR/fawwk ]]   # post-update ran from the new code

  # Local edits: not discarded without a yes (non-interactive = no), and a copy is saved.
  echo "# local tweak" >>"$home/lib/ui.sh"
  echo more >>"$o/MARKER"; git -C "$o" "${gc[@]}" commit -qam "v2"
  rc=0; out=$("$home/bin/fawwk" update 2>&1 </dev/null) || rc=$?
  eq "$rc" 1
  has "$out" "Update cancelled"
  has "$(tail -n1 "$home/lib/ui.sh")" "# local tweak"
  has "$(cat "$FAWWK_VAR"/fawwk-local-changes-*.patch)" "+# local tweak"
  git -C "$home" checkout -q -- lib/ui.sh

  # --branch: try another branch, then go back.
  git -C "$o" checkout -q -b feature && echo f >"$o/FEATURE" && git -C "$o" add -A && git -C "$o" "${gc[@]}" commit -qm feature
  "$home/bin/fawwk" update --branch feature >/dev/null 2>&1
  [[ -f $home/FEATURE ]]
  eq "$(git -C "$home" symbolic-ref --short HEAD)" feature
  "$home/bin/fawwk" update --branch main >/dev/null 2>&1
  [[ ! -e $home/FEATURE ]]
  eq "$(git -C "$home" rev-parse HEAD)" "$(git -C "$o" rev-parse main)"
}

test_doctor_counts_warnings() {
  load_fawwk
  UI_WARNINGS=0
  warn "one" 2>/dev/null; warn "two" 2>/dev/null
  eq "$UI_WARNINGS" 2
}

# ---------- run ----------
echo "Fawwk tests"
for fn in $(declare -F | awk '{print $3}' | grep '^test_' | sed 's/^test_//'); do t "$fn"; done
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0)) || { printf 'Failed: %s\n' "${FAILED[*]}"; exit 1; }
