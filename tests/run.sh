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
PASS=0 FAIL=0 SKIP=0 FAILED=()

# ---------- harness ----------
new_sandbox() {
  SB=$(mktemp -d)
  export FAWWK_ETC=$SB/etc FAWWK_VAR=$SB/var FAWWK_LOG=$SB/log FAWWK_CRON_DIR=$SB/cron.d FAWWK_HOME=$ROOT
  export FAWWK_LOGROTATE_DIR=$SB/logrotate.d FAWWK_SYSTEMD_DIR=$SB/systemd
  export FAKE_DOCKER_ROOT=$SB/docker NO_COLOR=1
  mkdir -p "$FAWWK_ETC/apps" "$FAWWK_VAR/apps" "$FAWWK_LOG" "$FAWWK_CRON_DIR" "$FAWWK_LOGROTATE_DIR" "$SB/systemd" "$SB/bin" \
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
  for l in ui common git github env build proxy release notify updates logs setup create manage settings db s3 maint doctor; do
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
  if ((rc == 0)) && grep -q '^skipped' "$out"; then
    # A test that couldn't run here (no Docker daemon, no railpack...) says so: it isn't a pass.
    SKIP=$((SKIP + 1)); printf '  skip  %s (%s)\n' "$name" "$(grep -m1 '^skipped' "$out" | sed 's/^skipped //; s/^(//; s/)$//')"
  elif ((rc == 0)); then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); FAILED+=("$name"); printf '  FAIL  %s\n' "$name"
    sed 's/^/        /' "$out" | tail -n 80
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
  has "$out" $'api.example.com {\n\timport fawwk_check\n\tencode zstd gzip\n\t# app: api\n\thandle {\n\t\treverse_proxy fawwk-api-1:8000'
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
  eq "$(build_detect "$d")" "$(build_auto_builder)"
  touch "$d/index.html"; eq "$(build_detect "$d")" static
  touch "$d/package.json"; eq "$(build_detect "$d")" "$(build_auto_builder)"
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

# A docker stub that records its arguments (docker.log) and, for each name in $SPY_ENV, the value it
# received in its environment (spy-<NAME>), so tests can tell values passed by name from values on the
# command line.
spy_docker() {
  cat >"$SB/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_DOCKER_ROOT/../docker.log"
for n in ${SPY_ENV-}; do [[ -v $n ]] && printf '%s' "${!n}" >"$FAKE_DOCKER_ROOT/../spy-$n"; done
case "$*" in
  "buildx version"*) echo "github.com/docker/buildx v0.29.0" ;;
  "info -f"*) echo "$FAKE_DOCKER_ROOT" ;;
esac
exit 0
EOF
  chmod +x "$SB/bin/docker"
}

PEM=$'-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC\nkqhkiG9w0BAQEFAASCBKcwggSjAgEAAo\n-----END PRIVATE KEY-----'

test_env_multiline_parse() {
  load_fawwk
  local out
  out=$(printf '%s\n' 'A=1' "KEY=\"${PEM%%$'\n'*}" "${PEM#*$'\n'}\" # the key" "SQ='first" "second'" 'B="quote \"inside\""' 'C=3' | env_parse 2>/dev/null)
  eq "$(env_parsed_keys <<<"$out" | tr '\n' ' ')" 'A KEY SQ B C '
  eq "$(grep '^@@ml KEY ' <<<"$out" | cut -d' ' -f3 | base64 -d)" "$PEM"
  eq "$(grep '^@@ml SQ ' <<<"$out" | cut -d' ' -f3 | base64 -d)" $'first\nsecond'
  has "$out" 'B=quote "inside"'
  # An unclosed quote takes the rest, with a warning (not silently the first line, as before).
  out=$(printf '%s\n' 'K="open' 'rest' | env_parse 2>&1)
  has "$out" 'has no closing'
}

test_env_multiline_store_and_roundtrip() {
  load_fawwk
  add_app api A_ROUTES=api.example.com A_PORT=8000 A_STATE=new
  local f d tmp
  f=$(app_envfile api); d=$(env_ml_dir "$f")
  tmp=$(mktemp)
  { printf 'PLAIN=hello\n'; env_ml_line CERT "$PEM"$'\n'; printf "TRICKY=a #b\n"; } >"$tmp"
  env_save api "$tmp"
  eq "$(cat "$f")" $'PLAIN=hello\nTRICKY=a #b'
  eq "$(cat "$d/CERT")" "$PEM"
  [[ $(tail -c1 "$d/CERT" | od -An -c | tr -d ' ') == '\n' ]]   # trailing newline kept exactly
  eq "$(stat -c %a "$d/CERT")" 600
  env_has "$f" CERT
  eq "$(env_count "$f")" 3
  # Render → parse → save gives back exactly the same stores (what `env edit` relies on).
  local before_single before_cert
  before_single=$(cat "$f"); before_cert=$(base64 -w0 "$d/CERT")
  env_render "$f" | env_parse >"$tmp"
  : >"$f"; rm -rf "$d"
  env_save api "$tmp"
  eq "$(cat "$f")" "$before_single"
  eq "$(base64 -w0 "$d/CERT")" "$before_cert"
  # A key switching kinds keeps only its last value.
  printf 'CERT=now-single\n' >"$tmp"; env_save api "$tmp"
  [[ ! -e $d/CERT ]]; has "$(cat "$f")" 'CERT=now-single'
  env_ml_line PLAIN $'two\nlines' >"$tmp"; env_save api "$tmp"
  hasnt "$(cat "$f")" 'PLAIN='; eq "$(cat "$d/PLAIN")" $'two\nlines'
  env_unset api PLAIN CERT
  [[ ! -e $d/PLAIN ]]; hasnt "$(cat "$f")" CERT
}

test_env_command_multiline() {
  load_fawwk
  add_app api A_ROUTES=api.example.com A_PORT=8000 A_STATE=new
  FAWWK_YES=1
  printf '%s\n' "$PEM" >"$SB/key.pem"
  cmd_env api set "KEY=$PEM" PLAIN=1 2>/dev/null
  cmd_env api set-file FILEKEY "$SB/key.pem" 2>/dev/null
  local d
  d=$(env_ml_dir "$(app_envfile api)")
  eq "$(cat "$d/KEY")" "$PEM"
  eq "$(cat "$d/FILEKEY")" "$PEM"
  local shown
  shown=$(cmd_env api show 2>/dev/null)
  has "$shown" 'KEY=---****'
  has "$shown" '(multi-line, 4 lines)'
  hasnt "$shown" 'MIIEvQ'
  has "$(cmd_env api show --reveal 2>/dev/null)" 'MIIEvQIBADANBgkqhkiG9w0BAQEFAASC'
}

test_multiline_env_reaches_containers() {
  load_fawwk
  spy_docker
  add_app api A_ROUTES=api.example.com A_PORT=8000 A_STATE=new
  local tmp; tmp=$(mktemp)
  { printf 'PLAIN=1\n'; env_ml_line CERT "$PEM"; } >"$tmp"
  env_save api "$tmp"
  app_load api
  app_run_args
  has " ${RUN_ARGS[*]} " " -e CERT "
  SPY_ENV=CERT app_docker run "${RUN_ARGS[@]}" img
  eq "$(cat "$SB/spy-CERT")" "$PEM"
  hasnt "$(cat "$SB/docker.log")" 'BEGIN PRIVATE'   # never on the command line
}

test_build_env_passed_by_name() {
  load_fawwk
  spy_docker
  mkdir -p "$FAWWK_VAR/apps/api/src"
  printf 'FROM scratch\n' >"$FAWWK_VAR/apps/api/src/Dockerfile"
  add_app api A_ROUTES=api.example.com A_PORT=8000 A_STATE=new A_DIR=. A_BUILD=auto
  local tmp; tmp=$(mktemp)
  { printf 'SECRET=s3cret-value\nOTHER=x\n'; env_ml_line CERT "$PEM"; } >"$tmp"
  env_save api "$tmp"
  app_load api
  SPY_ENV="SECRET CERT" build_image t1 "$SB/build.log" 2>/dev/null
  local log; log=$(cat "$SB/docker.log")
  has "$log" "--build-arg SECRET --build-arg OTHER --build-arg CERT"
  hasnt "$log" 's3cret-value'
  eq "$(cat "$SB/spy-SECRET")" s3cret-value
  eq "$(cat "$SB/spy-CERT")" "$PEM"
  # buildenv limits what the build sees.
  : >"$SB/docker.log"; rm -f "$SB"/spy-*
  A_BUILD_ENV=OTHER
  SPY_ENV="SECRET" build_image t2 "$SB/build.log" 2>/dev/null
  hasnt "$(cat "$SB/docker.log")" SECRET
  [[ ! -e $SB/spy-SECRET ]]
}

test_build_without_cache() {
  load_fawwk
  spy_docker
  mkdir -p "$FAWWK_VAR/apps/api/src"
  printf 'FROM scratch\n' >"$FAWWK_VAR/apps/api/src/Dockerfile"
  add_app api A_ROUTES=api.example.com A_PORT=8000 A_STATE=new A_DIR=. A_BUILD=auto
  app_load api
  build_image t1 "$SB/build.log" 2>/dev/null
  hasnt "$(cat "$SB/docker.log")" --no-cache
  # Once, for one deploy.
  : >"$SB/docker.log"
  FAWWK_NO_CACHE=1 build_image t2 "$SB/build.log" 2>/dev/null
  has "$(cat "$SB/docker.log")" "build --progress=plain --no-cache -t fawwk/api:t2"
  # Always, as an app setting, kept across loads and shown by info.
  cmd_build api cache off >/dev/null 2>&1
  app_load api
  eq "$A_BUILD_CACHE" off
  eq "$(cmd_info api --json | jq -r .build_cache)" off
  : >"$SB/docker.log"
  build_image t3 "$SB/build.log" 2>/dev/null
  has "$(cat "$SB/docker.log")" "--no-cache"
  cmd_build api cache on >/dev/null 2>&1
  app_load api
  eq "$(cmd_info api --json | jq -r .build_cache)" on
  : >"$SB/docker.log"
  build_image t4 "$SB/build.log" 2>/dev/null
  hasnt "$(cat "$SB/docker.log")" --no-cache
  (cmd_build api cache maybe 2>/dev/null) && return 1
  # deploy takes --no-cache in any position and refuses unknown options.
  has "$(cmd_deploy --help)" --no-cache
  (cmd_deploy api --fast 2>/dev/null) && return 1
  return 0
}

test_railpack_build() {
  command -v railpack >/dev/null || { echo "skipped (railpack not installed)"; return 0; }
  load_fawwk
  spy_docker
  local src=$FAWWK_VAR/apps/web/src
  mkdir -p "$src"
  printf '{"name":"w","version":"1.0.0","scripts":{"start":"node index.js"},"engines":{"node":"22"}}\n' >"$src/package.json"
  printf '{"lockfileVersion":3,"name":"w","packages":{"":{"name":"w"}}}\n' >"$src/package-lock.json"
  echo 'require("http").createServer((q, s) => s.end("hi")).listen(process.env.PORT)' >"$src/index.js"
  add_app web A_ROUTES=web.example.com A_PORT=3000 A_STATE=new A_DIR=. A_BUILD=auto
  local tmp; tmp=$(mktemp)
  { printf 'API_KEY=sk_live_123\n'; env_ml_line CERT "$PEM"; } >"$tmp"
  env_save web "$tmp"
  app_load web
  eq "$(build_detect "$src")" railpack
  SPY_ENV="API_KEY CERT" build_image t1 "$SB/build.log" 2>"$SB/err" || { cat "$SB/err" "$SB/build.log"; return 1; }
  local log ver
  log=$(cat "$SB/docker.log"); ver=$(railpack_version)
  has "$log" "buildx build --progress=plain --build-arg BUILDKIT_SYNTAX=ghcr.io/railwayapp/railpack-frontend:v$ver"
  has "$log" "--secret id=API_KEY,env=API_KEY --secret id=CERT,env=CERT"
  has "$log" "--build-arg cache-key=fawwk-web"
  has "$log" "-f $FAWWK_VAR/apps/web/railpack-plan.json -t fawwk/web:t1 $src"
  [[ $log =~ secrets-hash=[0-9a-f]{64} ]]
  hasnt "$log" sk_live_123
  eq "$(cat "$SB/spy-API_KEY")" sk_live_123
  eq "$(cat "$SB/spy-CERT")" "$PEM"
  # The plan names the secrets but never holds their values.
  eq "$(jq -c '.secrets' "$FAWWK_VAR/apps/web/railpack-plan.json")" '["API_KEY","CERT"]'
  hasnt "$(cat "$FAWWK_VAR/apps/web/railpack-plan.json")" sk_live_123
  has "$(cat "$SB/build.log")" "Detected Node"
}

test_railpack_migration_keeps_nixpacks_apps() {
  load_fawwk
  printf '#!/bin/sh\necho nixpacks 1.0\n' >"$SB/bin/nixpacks"; chmod +x "$SB/bin/nixpacks"
  mkdir -p "$FAWWK_VAR/apps/old/src" "$FAWWK_VAR/apps/df/src" "$FAWWK_VAR/apps/fresh/src"
  touch "$FAWWK_VAR/apps/old/src/package.json"
  printf 'FROM scratch\n' >"$FAWWK_VAR/apps/df/src/Dockerfile"
  touch "$FAWWK_VAR/apps/fresh/src/package.json"
  add_app old A_BUILD=auto A_DIR=. A_IMAGE=fawwk/old:1
  add_app df A_BUILD=auto A_DIR=. A_IMAGE=fawwk/df:1
  add_app fresh A_BUILD=auto A_DIR=.   # never deployed: picks the new default
  railpack_migrate 2>/dev/null
  app_load old; eq "$A_BUILD" nixpacks
  app_load df; eq "$A_BUILD" auto
  app_load fresh; eq "$A_BUILD" auto
  # Once per server: a later run leaves an app switched back to auto alone.
  app_load old; app_set A_BUILD auto
  # shellcheck disable=SC1090
  source "$FAWWK_CONF"
  railpack_migrate 2>/dev/null
  app_load old; eq "$A_BUILD" auto
}

test_github_deploy_status() {
  load_fawwk
  mkdir -p "$FAWWK_ETC/github/fawwk-test"
  openssl genrsa -out "$FAWWK_ETC/github/fawwk-test/key.pem" 2048 2>/dev/null
  printf 'GH_APP_ID=123\nGH_SLUG=fawwk-test\nGH_OWNER=acme\nGH_OWNER_TYPE=Organization\n' >"$FAWWK_ETC/github/fawwk-test/app.conf"
  # A fake GitHub: tokens (refused when DENY=1) and commit statuses, recorded in gh.log.
  cat >"$SB/bin/curl" <<EOF
#!/usr/bin/env bash
data='' url=''
while ((\$#)); do case \$1 in -d) data=\$2; shift ;; https://*) url=\$1 ;; esac; shift; done
printf '%s %s\n' "\$url" "\$data" >>"$SB/gh.log"
case \$url in
  */access_tokens) [[ -n \${DENY-} ]] && exit 22; echo '{"token":"ghs_status_only"}' ;;
  */statuses/*) echo '{}' ;;
esac
EOF
  chmod +x "$SB/bin/curl"
  add_app api A_AUTH=github A_GH_SOURCE=fawwk-test A_GH_INSTALL=42 A_REPO=https://github.com/acme/api.git \
    'A_ROUTES=api.example.com example.com/api'
  app_load api
  local sha=0123456789abcdef0123456789abcdef01234567 log
  deploy_status pending "Deploying" "$sha"
  deploy_status success "Live" "$sha"
  log=$(cat "$SB/gh.log")
  has "$log" '/app/installations/42/access_tokens {"repositories":["api"],"permissions":{"statuses":"write"}}'
  eq "$(grep -c access_tokens <<<"$log")" 1   # one token per deploy
  has "$log" "/repos/acme/api/statuses/$sha {\"state\":\"pending\",\"description\":\"Deploying\",\"context\":\"fawwk/api\",\"target_url\":\"https://api.example.com\"}"
  has "$log" '"state":"success"'
  # Without the permission: one hint pointing at the org's app settings, and no failure.
  DEPLOY_STATUS_TOKEN='' DEPLOY_STATUS_HINTED=0
  local out
  out=$(DENY=1 deploy_status pending x "$sha" 2>&1; DENY=1 deploy_status failure y "$sha" 2>&1)
  has "$out" 'https://github.com/organizations/acme/settings/apps/fawwk-test/permissions'
  eq "$(grep -c 'Commit statuses' <<<"$out")" 1
  # Off, or not a GitHub App app: nothing is sent.
  : >"$SB/gh.log"
  GH_STATUSES=off deploy_status pending x "$sha"
  A_AUTH=deploykey deploy_status pending x "$sha"
  [[ ! -s $SB/gh.log ]]
}

# add_db NAME TYPE — writes a database config without starting anything.
add_db() {
  mkdir -p "$FAWWK_ETC/dbs/$1"
  printf 'D_NAME=%s\nD_TYPE=%s\nD_VERSION=1\nD_IMAGE=img\nD_USER=%s\nD_PASSWORD=pw123\nD_DATABASE=%s\n' \
    "$1" "$2" "$([[ $2 == redis ]] && echo default || echo "${1//-/_}")" "${1//-/_}" >"$FAWWK_ETC/dbs/$1/db.conf"
}

# Backups to a bucket, with rclone's local backend standing in for S3 (same commands, a folder as the
# bucket). Checks what gets uploaded, what gets deleted, and that the secret key is never an argument.
test_s3_backups() {
  command -v rclone >/dev/null || { echo "skipped (rclone not installed)"; return 0; }
  load_fawwk
  local real now old f
  real=$(command -v rclone)
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/rclone.log"\nexec %s "$@"\n' "$SB" "$real" >"$SB/bin/rclone"
  printf '#!/bin/sh\nexit 0\n' >"$SB/bin/systemctl"
  chmod +x "$SB/bin/rclone" "$SB/bin/systemctl"
  cd "$SB"
  export S3_REMOTE_TYPE=local
  add_db shop-db postgres
  mkdir -p "$BACKUPS_DIR/shop-db"
  now=$(date +%Y%m%d-%H%M%S)
  old=$(date -d "@$(($(date +%s) - 40 * 86400))" +%Y%m%d-%H%M%S)
  echo new >"$BACKUPS_DIR/shop-db/shop-db-$now-scheduled.dump"
  echo old >"$BACKUPS_DIR/shop-db/shop-db-$old-manual.dump"
  echo part >"$BACKUPS_DIR/shop-db/shop-db-$now-manual.dump.partial"
  # Copies already in the bucket from a database that's gone: 5 old ones, and a file Fawwk didn't make.
  local gone=$SB/bucket/fawwk/test/db/gone-db
  mkdir -p "$gone"
  for f in 20200101 20200102 20200103 20200104 20200105; do echo x >"$gone/gone-db-$f-031700-scheduled.dump"; done
  echo mine >"$gone/notes.txt"

  FAWWK_YES=1 FAWWK_S3_ACCESS_KEY_ID=AKIDTEST FAWWK_S3_SECRET_ACCESS_KEY=s3cr3t-key-value \
    s3_cmd_setup --provider other --endpoint http://127.0.0.1:9 --bucket bucket --prefix fawwk/test --keep-days 30 >"$SB/out" 2>&1 ||
    { cat "$SB/out"; return 1; }
  # shellcheck disable=SC1090
  source "$FAWWK_CONF"
  eq "$S3_BUCKET" bucket
  eq "$(stat -c %a "$S3_KEYS")" 600
  has "$(cat "$S3_KEYS")" s3cr3t-key-value
  hasnt "$(cat "$FAWWK_CONF")" s3cr3t
  hasnt "$(cat "$SB/rclone.log")" s3cr3t
  hasnt "$(cat "$SB/rclone.log")" AKIDTEST
  [[ -f $SB/systemd/fawwk-db-backup.timer ]]   # the nightly upload runs even without databases to back up

  local up=$SB/bucket/fawwk/test
  [[ -f $up/db/shop-db/shop-db-$now-scheduled.dump ]]
  [[ ! -e $up/db/shop-db/shop-db-$old-manual.dump ]]          # older than kept: not uploaded
  [[ ! -e $up/db/shop-db/shop-db-$now-manual.dump.partial ]]  # unfinished: not uploaded
  ls "$up/server/"settings-*.tar.gz >/dev/null
  tar -tzf "$up"/server/settings-*.tar.gz | grep -q 'etc/fawwk.conf$'
  # Old copies go, but the newest 3 of each database stay, and unknown files are left alone.
  eq "$(cd "$gone" && ls | sort | tr '\n' ' ')" \
    "gone-db-20200103-031700-scheduled.dump gone-db-20200104-031700-scheduled.dump gone-db-20200105-031700-scheduled.dump notes.txt "
  ls "$up"/.fawwk-test-* >/dev/null 2>&1 && return 1           # the setup test file was removed

  # A second push uploads nothing new (settings aside).
  s3_push
  has "$S3_PUSH_SUMMARY" "1 uploaded"
  s3_status_load
  [[ -n $S3_LAST_OK && -z $S3_LAST_ERROR ]]
  has "$(doctor_s3 2>&1)" "Uploaded to bucket"

  # min 1 and keep everything: nothing is deleted with 0 days.
  s3_cmd_keep 0 >/dev/null 2>&1
  # shellcheck disable=SC1090
  source "$FAWWK_CONF"
  eq "$(s3_prune db/gone-db)" 0
  s3_cmd_keep 30 --min 1 >/dev/null 2>&1
  # shellcheck disable=SC1090
  source "$FAWWK_CONF"
  eq "$(s3_prune db/gone-db)" 2
  [[ -f $gone/gone-db-20200105-031700-scheduled.dump && -f $gone/notes.txt ]]

  # Download the newest copy back.
  rm -f "$BACKUPS_DIR/shop-db/shop-db-$now-scheduled.dump"
  s3_cmd_get shop-db latest >/dev/null 2>&1
  eq "$(cat "$BACKUPS_DIR/shop-db/shop-db-$now-scheduled.dump")" new
  has "$(s3_cmd_list shop-db 2>&1)" "shop-db-$now-scheduled.dump"

  # The nightly run uploads even when a database backup fails (here: the stub has no running container).
  echo newer >"$BACKUPS_DIR/shop-db/shop-db-$(date -d '@'$(($(date +%s) + 60)) +%Y%m%d-%H%M%S)-manual.dump"
  (db_backup_cmd --all --scheduled >/dev/null 2>&1) && return 1
  eq "$(ls "$up/db/shop-db" | wc -l)" 2
  # A broken bucket is reported and remembered for doctor.
  S3_REMOTE_TYPE=no-such-backend
  s3_push >/dev/null 2>&1 && return 1
  S3_REMOTE_TYPE=local
  s3_status_load
  has "$S3_LAST_ERROR" "Couldn't upload"
  return 0
}

test_db_urls_links_and_retention() {
  load_fawwk
  add_db shop-db postgres; add_db cache redis; add_db docs mongodb
  db_load shop-db; eq "$(db_url)" 'postgresql://shop_db:pw123@fawwk-db-shop-db:5432/shop_db'
  eq "$(db_url_masked)" 'postgresql://shop_db:****@fawwk-db-shop-db:5432/shop_db'
  db_load cache; eq "$(db_url)" 'redis://default:pw123@fawwk-db-cache:6379/0'
  db_load docs; eq "$(db_url)" 'mongodb://docs:pw123@fawwk-db-docs:27017/docs?authSource=admin'
  # Linking sets the app's env var and remembers it; unlinking removes both.
  add_app api A_STATE=new
  FAWWK_YES=1
  db_load shop-db
  db_link_apply api DATABASE_URL 2>/dev/null
  has "$(cat "$(app_envfile api)")" 'DATABASE_URL=postgresql://shop_db:pw123@fawwk-db-shop-db:5432/shop_db'
  db_load shop-db; eq "$D_LINKS" api:DATABASE_URL
  eq "$(db_links_text)" api
  db_unlink shop-db api 2>/dev/null
  hasnt "$(cat "$(app_envfile api)")" DATABASE_URL
  db_load shop-db; eq "$D_LINKS" ''
  # A value added by hand: say it's replaced; a similar name: say how to link under it.
  local out
  printf 'MONGODB_URL=mongodb://old-host/x\nMONGODB_URI=mongodb+srv://atlas/x\nREDIS_URL=redis://old\n' >"$(app_envfile api)"
  db_load docs
  out=$(db_link_apply api MONGODB_URL 2>&1)
  has "$out" 'api already has MONGODB_URL set. Linking replaces it'
  has "$out" 'api also has MONGODB_URI'; has "$out" 'fawwk db link docs api --as MONGODB_URI'
  hasnt "$out" REDIS_URL
  has "$(cat "$(app_envfile api)")" 'MONGODB_URL=mongodb://docs:pw123@fawwk-db-docs:27017/docs?authSource=admin'
  out=$(db_link_apply api MONGODB_URL 2>&1)   # same value again: nothing to warn about it
  hasnt "$out" 'already has'
  db_load shop-db
  # Retention: newest 7 scheduled / pre-restore kept, manual ones never pruned; "latest" skips safety copies.
  local d i
  d=$(db_backups shop-db); mkdir -p "$d"
  for i in 01 02 03 04 05 06 07 08 09; do
    touch -d "2026-01-$i 00:00" "$d/shop-db-202601$i-000000-scheduled.dump"
    touch -d "2026-01-$i 01:00" "$d/shop-db-202601$i-010000-manual.dump"
  done
  touch -d 2026-02-01 "$d/shop-db-20260201-000000-pre-restore.dump"
  db_prune_backups
  eq "$(find "$d" -name '*-scheduled.*' | wc -l)" 7
  eq "$(find "$d" -name '*-manual.*' | wc -l)" 9
  [[ ! -e $d/shop-db-20260101-000000-scheduled.dump ]]
  eq "$(basename "$(db_latest_backup shop-db)")" shop-db-20260109-010000-manual.dump
  # The daily timer.
  DB_BACKUP_AT=02:30 db_timer_ensure
  has "$(cat "$SYSTEMD_DIR/fawwk-db-backup.timer")" 'OnCalendar=*-*-* 02:30:00'
  has "$(cat "$SYSTEMD_DIR/fawwk-db-backup.service")" "$ROOT/bin/fawwk db backup --all --scheduled"
}

test_db_tunnel() {
  load_fawwk
  add_db docs mongodb; add_db shop-db postgres
  local running=true out
  # shellcheck disable=SC2329
  docker() {
    case "$*" in
      "inspect -f {{.State.Status}} "*) [[ $running == true ]] && echo running || echo exited ;;
      "inspect -f {{with index .NetworkSettings.Networks"*) echo 172.18.0.5 ;;
    esac
  }
  # shellcheck disable=SC2329
  server_ip() { echo 203.0.113.7; }
  out=$(SUDO_USER=deploy db_tunnel docs 2>&1)
  has "$out" 'ssh -N -L 27018:172.18.0.5:27017 deploy@203.0.113.7'
  has "$out" 'mongodb://docs:****@localhost:27018/docs?authSource=admin&directConnection=true'
  hasnt "$out" pw123; has "$out" 'Ctrl+C'; has "$out" Compass
  out=$(db_tunnel shop-db --port 6543 --reveal 2>&1)
  has "$out" 'ssh -N -L 6543:172.18.0.5:5432 <you>@203.0.113.7'   # run as root: no user to suggest
  has "$out" 'postgresql://shop_db:pw123@localhost:6543/shop_db'
  hasnt "$out" directConnection
  out=$( (db_tunnel docs --port 99999) 2>&1) && return 1; has "$out" '--port must be a port number'
  running=false
  out=$( (db_tunnel docs) 2>&1) && return 1; has "$out" "docs isn't running"
  unset -f docker server_ip
}

test_db_create_validation() {
  load_fawwk
  add_db taken postgres
  local out
  out=$( (db_create taken --type postgres) 2>&1) && return 1; has "$out" 'already exists'
  out=$( (db_create x1 --type mysql) 2>&1) && return 1;      has "$out" 'postgres, redis or mongodb'
  out=$( (db_create x1 --version latest) 2>&1) && return 1;  has "$out" 'look like 16'
  out=$( (db_create x1 --link nope) 2>&1) && return 1;       has "$out" "No app named 'nope'"
  out=$( (db_create Bad_Name) 2>&1) && return 1;             has "$out" 'lowercase'
  [[ ! -d $FAWWK_ETC/dbs/x1 ]]
}

# Real Docker: all three engines through create → link → write → backup → wipe → restore. Runs where a
# Docker daemon is available (CI has one); skipped elsewhere.
test_db_real_docker() {
  rm -f "$SB/bin/docker"   # the real one
  docker info >/dev/null 2>&1 || { echo "skipped (no Docker daemon)"; return 0; }
  load_fawwk
  add_app api A_STATE=new
  FAWWK_YES=1
  local sfx=$RANDOM
  DB_TEST_NAMES="pg$sfx rd$sfx mg$sfx mx$sfx"
  # On the way out (pass or fail): what each database container was doing, then clean up. The harness
  # only shows a test's output when it fails, so this explains failures in CI without noise otherwise.
  # (set +e: a cleanup step that fails, e.g. logs of a container that was rightly never created, must
  # not turn a passing test into a failure.)
  trap 'set +e; for n in $DB_TEST_NAMES; do
      docker ps -a --filter "name=^fawwk-db-$n\$" --format "      container {{.Names}}: {{.Status}}"
      docker logs --tail 15 "fawwk-db-$n" 2>&1 | sed "s/^/        /"
      docker rm -f "fawwk-db-$n" "fawwk-db-$n-restore" >/dev/null 2>&1; docker volume rm "fawwk_db_$n" >/dev/null 2>&1
    done; rm -rf "$SB"' EXIT
  local pw=()

  db_create "pg$sfx" --type postgres --link api
  has "$(cat "$(app_envfile api)")" "DATABASE_URL=postgresql://pg$sfx:"
  db_load "pg$sfx"; pw+=("$D_PASSWORD")
  pg() { db_exec "fawwk-db-pg$sfx" psql -tA -U "$D_USER" -h 127.0.0.1 "$D_DATABASE" -c "$1"; }
  pg "create table t(v text); insert into t values ('kept');" >/dev/null
  db_backup_cmd "pg$sfx" 2>/dev/null
  pg "drop table t; create table later(x int);" >/dev/null
  db_restore_cmd "pg$sfx" latest --yes 2>/dev/null
  eq "$(pg 'select v from t')" kept
  eq "$(pg "select count(*) from information_schema.tables where table_name = 'later'")" 0
  # The address `db tunnel` forwards to is reachable from the server itself.
  local ip; ip=$(db_ip)
  [[ -n $ip ]]
  timeout 5 bash -c "exec 3<>/dev/tcp/$ip/5432"
  has "$(server_ip() { echo 203.0.113.7; }; db_tunnel "pg$sfx" 2>&1)" "$ip:5432"

  db_create "rd$sfx" --type redis
  db_load "rd$sfx"; pw+=("$D_PASSWORD")
  rd() { db_exec "fawwk-db-rd$sfx" redis-cli "$@"; }
  eq "$(docker exec "fawwk-db-rd$sfx" redis-cli get x 2>&1 | head -c 6)" NOAUTH
  rd set k kept >/dev/null
  db_backup_cmd "rd$sfx" 2>/dev/null
  rd del k >/dev/null; rd set junk 1 >/dev/null
  db_restore_cmd "rd$sfx" latest --yes 2>/dev/null
  eq "$(rd get k)|$(rd get junk)" 'kept|'
  docker restart "fawwk-db-rd$sfx" >/dev/null; db_wait_ready 30
  eq "$(rd get k)" kept   # survives a restart (append-only file rebuilt from the snapshot)

  if grep -qw avx /proc/cpuinfo; then
    db_create "mg$sfx" --type mongodb
    db_load "mg$sfx"
    mg() { db_exec "fawwk-db-mg$sfx" mongosh --quiet -u "$D_USER" -p "$D_PASSWORD" --authenticationDatabase admin "$D_DATABASE" --eval "$1"; }
    mg 'db.c.insertOne({v: "kept"})' >/dev/null
    db_backup_cmd "mg$sfx" 2>/dev/null
    mg 'db.c.drop(); db.junk.insertOne({x: 1})' >/dev/null
    db_restore_cmd "mg$sfx" latest --yes 2>/dev/null
    eq "$(mg 'db.c.findOne().v')|$(mg 'db.junk.countDocuments()')" 'kept|0'
  else
    echo "MongoDB part skipped (CPU without AVX)"
  fi
  # MongoDB builds that refuse kernel 6.19+ are caught before they're started, with versions that work.
  if docker image inspect mongo:8.3 >/dev/null 2>&1 || docker pull -q mongo:8.3 >/dev/null 2>&1; then
    FAWWK_KERNEL=6.19.2 mongo_refuses_kernel mongo:8.3
    FAWWK_KERNEL=6.18.9 no mongo_refuses_kernel mongo:8.3   # older kernels are fine
    local out
    out=$( (FAWWK_KERNEL=6.20.0 db_create "mx$sfx" --type mongodb --version 8.3) 2>&1) && return 1
    has "$out" "won't run on this server's Linux kernel (6.20)"; has "$out" '--version 7.0'
    [[ ! -d $FAWWK_ETC/dbs/mx$sfx ]]
  fi
  FAWWK_KERNEL=6.20.0 no mongo_refuses_kernel "$(db_image_for mongodb "$(db_default_version mongodb)")"

  # Nothing secret on the containers' command lines.
  local cmdlines
  cmdlines=$(docker inspect -f '{{.Config.Cmd}} {{.Args}}' "fawwk-db-pg$sfx" "fawwk-db-rd$sfx")
  hasnt "$cmdlines" "${pw[0]}"; hasnt "$cmdlines" "${pw[1]}"
}

test_dockerfile_build_args_injected() {
  load_fawwk
  local d=$SB/df
  mkdir -p "$d"
  # Multi-stage, Coolify-style: build vars used in the builder, an indented FROM, a syntax directive,
  # one ARG already declared, and a multi-line FROM.
  printf '%s\n' '# syntax=docker/dockerfile:1.7' '  FROM node:22 AS deps' 'RUN echo deps' \
    'FROM node:22 \' '  AS builder' '    ARG NPM_TOKEN' 'RUN echo "$VITE_URL"' 'FROM alpine' 'COPY --from=builder /x /x' >"$d/Dockerfile"
  build_dockerfile_with_args "$d/Dockerfile" "$d/out" NPM_TOKEN VITE_URL
  eq "$(cat "$d/out")" "$(printf '%s\n' '# syntax=docker/dockerfile:1.7' '  FROM node:22 AS deps' 'ARG NPM_TOKEN' 'ARG VITE_URL' 'RUN echo deps' \
    'FROM node:22 \' '  AS builder' 'ARG VITE_URL' '    ARG NPM_TOKEN' 'RUN echo "$VITE_URL"' 'FROM alpine' 'COPY --from=builder /x /x')"
  # Single stage: its one stage gets them.
  printf 'FROM alpine\nRUN echo hi\n' >"$d/Dockerfile"
  build_dockerfile_with_args "$d/Dockerfile" "$d/out" A
  eq "$(cat "$d/out")" $'FROM alpine\nARG A\nRUN echo hi'
  # A Dockerfile-specific ignore file follows the copy.
  echo secret.txt >"$d/Dockerfile.dockerignore"
  build_dockerfile_with_args "$d/Dockerfile" "$d/out" A
  eq "$(cat "$d/out.dockerignore")" secret.txt
}

# Real Docker: a build var reaches the builder stage's RUN, and never the shipped image's history.
test_dockerfile_build_args_real_docker() {
  rm -f "$SB/bin/docker"
  docker info >/dev/null 2>&1 || { echo "skipped (no Docker daemon)"; return 0; }
  docker image inspect alpine:3.20 >/dev/null 2>&1 || docker pull -q alpine:3.20 >/dev/null 2>&1 || { echo "skipped (no alpine image)"; return 0; }
  load_fawwk
  local src=$FAWWK_VAR/apps/web/src tag img
  mkdir -p "$src"
  printf '%s\n' 'FROM alpine:3.20 AS builder' 'RUN echo "url=$VITE_API_URL token=${NPM_TOKEN:+set}" > /built.txt' \
    'FROM alpine:3.20' 'COPY --from=builder /built.txt /built.txt' 'RUN echo shipped' >"$src/Dockerfile"
  add_app web A_ROUTES=web.example.com A_PORT=3000 A_STATE=new A_DIR=. A_BUILD=dockerfile
  printf 'VITE_API_URL=https://api.example.com\nNPM_TOKEN=ghp_supersecret123\n' >"$(app_envfile web)"
  app_load web
  tag="t$RANDOM"; img="fawwk/web:$tag"
  trap 'docker rmi -f "fawwk/web:'"$tag"'" >/dev/null 2>&1; rm -rf "$SB"' EXIT
  build_image "$tag" "$SB/build.log" 2>/dev/null || { cat "$SB/build.log"; return 1; }
  eq "$(docker run --rm "$img" cat /built.txt)" 'url=https://api.example.com token=set'
  hasnt "$(docker history --no-trunc --format '{{.CreatedBy}}' "$img")" ghp_supersecret123
  hasnt "$(docker image inspect "$img")" ghp_supersecret123
}

test_dns_stale_local_cache() {
  load_fawwk
  SERVER_IP=203.0.113.7
  # Public DNS (fake DNS-over-HTTPS): pannel.example.com points here, missing.example.com doesn't exist.
  cat >"$SB/bin/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *name=pannel.example.com*) echo '{"Status":0,"Answer":[{"name":"pannel.example.com","type":1,"data":"203.0.113.7"}]}' ;;
  *) echo '{"Status":3}' ;;
esac
EOF
  # This server's resolver: still caching "doesn't exist" until resolvectl flushes it.
  cat >"$SB/bin/resolvectl" <<EOF
#!/usr/bin/env bash
[[ \$1 == flush-caches ]] && touch "$SB/flushed"
EOF
  chmod +x "$SB/bin/curl" "$SB/bin/resolvectl"
  dns_lookup() { [[ $1 == pannel.example.com && -e $SB/flushed ]] && echo 203.0.113.7; return 0; }
  local out
  out=$(dns_report pannel.example.com 2>&1)
  has "$out" 'had an old answer cached; cleared it'
  [[ -e $SB/flushed ]]
  # If the flush doesn't help, say how and why instead of "doesn't resolve".
  rm -f "$SB/flushed"; printf '#!/bin/sh\nexit 0\n' >"$SB/bin/resolvectl"
  out=$(dns_report pannel.example.com 2>&1)
  has "$out" 'in public DNS'; has "$out" 'sudo resolvectl flush-caches'; hasnt "$out" "doesn't resolve"
  # Really missing: the usual warning.
  out=$(dns_report missing.example.com 2>&1)
  has "$out" "missing.example.com doesn't resolve yet"
}

test_ui_quote_error_logs() {
  load_fawwk
  C_RED='<R>' C_YELLOW='<Y>' C_MUTED='<M>' C_RESET='</>' G_V='|'
  local out
  out=$(printf '%s\n' 'starting' '' 'DNSException: getaddrinfo ESERVFAIL' '  code: 1' '' '' \
    'DNSException: getaddrinfo ESERVFAIL' '  code: 1' '' 'DNSException: getaddrinfo ESERVFAIL' '  code: 1' \
    '' 'Warning: punycode is deprecated' '    at <anonymous> (/app/x.js:1:2)' '187 |   const err = new Error()' |
    ui_quote --error 2>&1)
  eq "$out" "$(printf '%s\n' \
    '     <R>|</> starting' \
    '     <R>|</>' \
    '     <R>|</> <R>DNSException: getaddrinfo ESERVFAIL</>' \
    '     <R>|</>   code: 1' \
    '     <R>|</> <M>(the same 2 more times)</>' \
    '     <R>|</>' \
    '     <R>|</> <Y>Warning: punycode is deprecated</>' \
    '     <R>|</> <M>    at <anonymous> (/app/x.js:1:2)</>' \
    '     <R>|</> <M>187 |   const err = new Error()</>')"
  # Without --error: as before, no colouring of the text.
  eq "$(printf 'Error: x\n' | ui_quote 2>&1)" "     ${C_BORDER}|</> Error: x"
}

test_ui_columns_layout() {
  load_fawwk
  ui_cols() { echo 40; }
  # Top to bottom like ls, padded to the widest item + 3, as many columns as fit (40 cols: 3 of 10).
  eq "$(ui_columns alpha beta gamma delta epsilon 2>&1)" "$(printf '    %s\n' 'alpha     gamma     epsilon' 'beta      delta')"
  ui_cols() { echo 200; }
  eq "$(ui_columns a b c d e f g 2>&1 | head -1)" '    a   c   e   g'   # never more than 4 columns
  eq "$(ui_columns 2>&1)" ''
}

test_dns_proxied_origin_check() {
  load_fawwk
  SERVER_IP=203.0.113.7
  is_cloudflare_ip 104.21.56.28; is_cloudflare_ip 172.67.176.25; is_cloudflare_ip 162.159.1.1
  local ip
  for ip in 8.8.8.8 203.0.113.7 104.15.255.255 nonsense; do ! is_cloudflare_ip "$ip" || return 1; done
  ! all_cloudflare || return 1
  ! all_cloudflare 104.21.56.28 8.8.8.8 || return 1
  add_app web A_ROUTES=web.example.com A_STATE=running A_CONTAINER=fawwk-web-1 A_PORT=3000
  mkdir -p "$CADDY_DIR"
  proxy_render >"$CADDY_DIR/Caddyfile"
  local token out
  token=$(check_token)
  [[ $token =~ ^[0-9a-f]{32}$ ]]
  eq "$(check_token)" "$token"   # made once
  has "$(cat "$CADDY_DIR/Caddyfile")" $'(fawwk_check) {\n\thandle /.well-known/fawwk-check {\n\t\trespond "'"$token"'" 200'
  has "$(cat "$CADDY_DIR/Caddyfile")" $'http:// {\n\timport fawwk_check'
  # Fake visitors' view: DoH knows nothing; each host's probe answers differently.
  cat >"$SB/bin/curl" <<EOF
#!/usr/bin/env bash
hdr=/dev/null url=''
while ((\$#)); do case \$1 in -D) hdr=\$2; shift ;; http*) url=\$1 ;; esac; shift; done
[[ \$url == *dns-query* ]] && { echo '{"Status":3}'; exit 0; }
case \$url in
  http://here.*) printf 'server: cloudflare\r\n' >"\$hdr"; printf '%s\n200' "$token" ;;
  http://loop.*) exit 47 ;;
  http://down.*) printf 'server: cloudflare\r\n' >"\$hdr"; printf 'error\n521' ;;
  http://other.*) printf 'server: nginx\r\n' >"\$hdr"; printf 'Not found\n404' ;;
  http://web.*) printf 'server: cloudflare\r\n' >"\$hdr"; printf 'error\n525' ;;
  http://new.*) printf 'server: cloudflare\r\n' >"\$hdr"; printf 'error\n525' ;;
  *) exit 7 ;;
esac
EOF
  chmod +x "$SB/bin/curl"
  dns_lookup() { case $1 in elsewhere.*) echo 198.51.100.9 ;; other.*) echo 104.21.56.28 ;; *) printf '104.21.56.28\n172.67.176.25\n' ;; esac; }
  out=$(dns_report here.example.com 2>&1)
  has "$out" 'here.example.com is proxied via Cloudflare and reaches this server'; hasnt "$out" "$G_WARN"
  has "$(dns_report loop.example.com 2>&1)" 'SSL/TLS mode is Flexible'
  has "$(dns_report down.example.com 2>&1)" "Cloudflare can't reach its server (error 521)"
  has "$(dns_report other.example.com 2>&1)" 'Cloudflare sends it to a different server. In Cloudflare, set the A record to 203.0.113.7'
  has "$(dns_report web.example.com 2>&1)" 'The certificate may not be issued yet'      # an app uses it
  has "$(dns_report new.example.com 2>&1)" 'once an app uses this address'              # nothing uses it yet
  out=$(dns_report quiet.example.com 2>&1)
  has "$out" 'quiet.example.com is proxied via Cloudflare'; has "$out" "Couldn't confirm"
  has "$(dns_report elsewhere.example.com 2>&1)" 'elsewhere.example.com → 198.51.100.9, not this server'
  # Warnings count toward doctor's summary; the cloud lines don't.
  UI_WARNINGS=0; dns_report here.example.com 2>/dev/null; eq "$UI_WARNINGS" 0
  dns_report other.example.com 2>/dev/null; eq "$UI_WARNINGS" 1
}

test_html_escape_survives_bash_52() {
  load_fawwk
  # On bash 5.2+ (patsub_replacement), an unescaped & in a replacement means the matched text: this
  # produced "quot; and an invalid GitHub App manifest.
  eq "$(html_escape $'{"a":"<b>&\'"}')" '{&quot;a&quot;:&quot;&lt;b&gt;&amp;&#39;&quot;}'
  # The manifest Fawwk sends, escaped as in `github connect`, reads back as the same JSON.
  local m back
  m=$(jq -nc --arg name fawwk-x --arg base https://panel.example.com '{name: $name, url: $base, hook_attributes: {url: ($base + "/hooks/github")}}')
  back=$(python3 -I -c 'import html, sys; print(html.unescape(sys.argv[1]))' "$(html_escape "$m")")
  eq "$back" "$m"
  jq -e . <<<"$back" >/dev/null
}

test_create_offers_installed_repos() {
  load_fawwk
  mkdir -p "$FAWWK_ETC/github/fawwk-test"
  openssl genrsa -out "$FAWWK_ETC/github/fawwk-test/key.pem" 2048 2>/dev/null
  printf 'GH_APP_ID=1\nGH_SLUG=fawwk-test\nGH_OWNER=me\n' >"$FAWWK_ETC/github/fawwk-test/app.conf"
  # A fake GitHub: two installations; one repo shows up in both; push dates decide the order.
  cat >"$SB/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=''; for a in "$@"; do [[ $a == https://* ]] && url=$a; done
case $url in
  */app/installations) echo '[{"id":11},{"id":22}]' ;;
  */installations/11/access_tokens) echo '{"token":"t11"}' ;;
  */installations/22/access_tokens) echo '{"token":"t22"}' ;;
  */installation/repositories*)
    if [[ "$*" == *t11* ]]; then
      echo '{"repositories":[{"full_name":"me/old","pushed_at":"2025-01-01T00:00:00Z"},{"full_name":"me/web","pushed_at":"2026-11-05T10:00:00Z"}]}'
    else
      echo '{"repositories":[{"full_name":"acme/api","pushed_at":"2026-11-04T10:00:00Z"},{"full_name":"me/web","pushed_at":"2026-11-05T10:00:00Z"}]}'
    fi ;;
esac
EOF
  chmod +x "$SB/bin/curl"
  eq "$(gh_installed_repos | tr '\n' ' ')" 'me/web acme/api me/old '
  # The picker: the first entry by default, and "Another repo" leaves it to the usual question.
  local repo=''
  menu() { printf -v "$1" '%s' "${PICK:-1}"; }
  create_pick_repo 2>/dev/null; eq "$repo" me/web
  repo=''; PICK=4 create_pick_repo 2>/dev/null; eq "$repo" ''
}

test_create_offers_branches() {
  load_fawwk
  local gc=(-c user.email=t@t -c user.name=t)
  git init -q -b master "$SB/multi.git"
  git -C "$SB/multi.git" "${gc[@]}" commit -q --allow-empty -m one
  git -C "$SB/multi.git" branch zeta; git -C "$SB/multi.git" branch dev; git -C "$SB/multi.git" branch feature/x
  A_NAME=web A_REPO=$SB/multi A_AUTH=public
  eq "$(git_branches master | tr '\n' ' ')" 'master dev feature/x zeta '
  # The picker: default first; "Another branch" leaves it to the usual question.
  menu() { printf -v "$1" '%s' "${PICK:-1}"; }
  A_BRANCH=''; create_pick_branch master 2>/dev/null; eq "$A_BRANCH" master
  A_BRANCH=''; PICK=3 create_pick_branch master 2>/dev/null; eq "$A_BRANCH" feature/x
  A_BRANCH=''; PICK=5 create_pick_branch master 2>/dev/null; eq "$A_BRANCH" ''
  # A single branch is used without a menu.
  git init -q -b main "$SB/single.git"
  git -C "$SB/single.git" "${gc[@]}" commit -q --allow-empty -m one
  A_REPO=$SB/single A_BRANCH=''
  menu() { echo "menu shown" >&2; return 1; }
  create_pick_branch main 2>/dev/null; eq "$A_BRANCH" main
}

test_create_offers_folders() {
  load_fawwk
  local r=$SB/mono
  mkdir -p "$r/apps/web/public" "$r/apps/api" "$r/services/worker" "$r/node_modules/x" "$r/docs"
  echo '{}' >"$r/package.json"
  echo '{}' >"$r/apps/web/package.json"; touch "$r/apps/web/index.html" "$r/apps/web/public/index.html"
  printf 'FROM scratch\n' >"$r/apps/api/Dockerfile"
  touch "$r/services/worker/requirements.txt" "$r/node_modules/x/package.json" "$r/docs/notes.md"
  eq "$(create_dir_candidates "$r" | tr '\n' ' ')" 'apps/api apps/web services/worker '
  eq "$(dir_kind "$r/apps/api")|$(dir_kind "$r/apps/web")|$(dir_kind "$r/services/worker")|$(dir_kind "$r/docs")" 'Dockerfile|Node|Python|'
  # Menu: the root (buildable here) is the default; picks map to folders; "Another folder" asks.
  local dir dir_picked seen
  menu() { seen="$2|$3|${*:4}"; printf -v "$1" '%s' "${PICK:-$3}"; }
  dir=. dir_picked=0; create_pick_dir "$r" 2>/dev/null; eq "$dir|$dir_picked" '.|1'
  has "$seen" 'Folder to deploy|1|'; has "$seen" 'apps/web'; has "$seen" '(Python)'
  dir=. dir_picked=0; PICK=3 create_pick_dir "$r" 2>/dev/null; eq "$dir|$dir_picked" 'apps/web|1'
  dir=. dir_picked=0; PICK=5 create_pick_dir "$r" 2>/dev/null; eq "$dir_picked" 0
  # Nothing buildable at the root: the first folder is the default.
  rm "$r/package.json"
  dir=. dir_picked=0; create_pick_dir "$r" 2>/dev/null; eq "$dir" apps/api; has "$seen" 'Folder to deploy|2|'
  # A plain repo: the root, no menu.
  mkdir -p "$SB/plain"; echo '{}' >"$SB/plain/package.json"
  menu() { echo "menu shown" >&2; return 1; }
  dir=. dir_picked=0; create_pick_dir "$SB/plain" 2>/dev/null; eq "$dir|$dir_picked" '.|1'
}

test_telegram_notifications() {
  load_fawwk
  local tok=123456789:AAFakeTokenForTestsOnly0123456789abcd
  # A fake Telegram: curl gets its URL on stdin (-K -); arguments and requests are recorded.
  cat >"$SB/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$SB/curl-args.log"
url=\$(sed -n 's/^url = "\(.*\)"$/\1/p')
printf '%s %s\n' "\$url" "\$*" >>"$SB/telegram.log"
case \$url in
  */getMe) echo '{"ok":true,"result":{"username":"fawwk_test_bot"}}' ;;
  */getUpdates) [[ -e "$SB/no-chat" ]] && echo '{"ok":true,"result":[]}' ||
    echo '{"ok":true,"result":[{"message":{"chat":{"id":111}}},{"message":{"chat":{"id":-1002233}}}]}' ;;
  */sendMessage) echo '{"ok":true}' ;;
esac
EOF
  chmod +x "$SB/bin/curl"
  # Setup finds the chat the bot was last messaged from, saves both, and sends a test.
  cmd_notify telegram "$tok" 2>/dev/null
  # shellcheck disable=SC1090
  source "$FAWWK_CONF"
  eq "$NOTIFY_TELEGRAM_CHAT" -1002233
  has "$(cat "$SB/telegram.log")" "https://api.telegram.org/bot$tok/sendMessage"
  has "$(cat "$SB/telegram.log")" 'chat_id=-1002233'
  hasnt "$(cat "$SB/curl-args.log")" "$tok"   # never on a command line
  # Deploy failures reach Telegram; successes only with "all".
  : >"$SB/telegram.log"
  notify ok web abc 'deployed'
  [[ ! -s $SB/telegram.log ]]
  notify failed web abc 'web: deploy failed'
  has "$(cat "$SB/telegram.log")" 'text=web: deploy failed'
  # Clear errors: a bad token, and no chat yet.
  local out
  out=$( (cmd_notify telegram not-a-token) 2>&1) && return 1; has "$out" "doesn't look like a bot token"
  touch "$SB/no-chat"
  out=$( (cmd_notify telegram "$tok") 2>&1) && return 1; has "$out" 'https://t.me/fawwk_test_bot'
  # --all with an explicit chat id.
  rm -f "$SB/no-chat"
  cmd_notify telegram "$tok" 42 --all 2>/dev/null
  # shellcheck disable=SC1090
  source "$FAWWK_CONF"
  eq "$NOTIFY_TELEGRAM_CHAT|$NOTIFY_ON" '42|all'
  cmd_notify telegram off 2>/dev/null
  # shellcheck disable=SC1090
  source "$FAWWK_CONF"
  eq "${NOTIFY_TELEGRAM_TOKEN-}${NOTIFY_TELEGRAM_CHAT-}" ''
}

test_update_notices() {
  load_fawwk
  local o=$SB/origin home=$SB/install gc=(-c user.email=t@t -c user.name=t) out
  version_gt 0.10.0 0.9.2; no version_gt 0.4.0 0.4.0; no version_gt 0.3.9 0.4.0
  # A Fawwk "origin" whose branch is at FAWWK_VERSION; this server is a clone of it.
  git init -q -b main "$o"
  mkdir -p "$o/lib"; cp "$ROOT/lib/common.sh" "$o/lib/"
  git -C "$o" add -A && git -C "$o" "${gc[@]}" commit -qm v1
  git clone -q --depth 1 "file://$o" "$home"
  FAWWK_HOME=$home
  # Same version upstream: nothing to say.
  update_check
  eq "$(update_available)" ''
  # A newer version is released upstream (an ordinary commit doesn't count: only the version).
  sed -i "s/^FAWWK_VERSION=.*/FAWWK_VERSION=\"9.9.9\"/" "$o/lib/common.sh"
  git -C "$o" "${gc[@]}" commit -qam "release 9.9.9"
  cat >"$SB/bin/curl" <<EOF
#!/usr/bin/env bash
while ((\$#)); do [[ \$1 == -d ]] && { printf '%s\n' "\$2" >>"$SB/notified"; shift; }; shift; done
EOF
  chmod +x "$SB/bin/curl"
  NOTIFY_URL=https://hooks.example.com/x
  update_check
  eq "$(update_available)" 9.9.9
  has "$(cat "$SB/notified")" "Fawwk 9.9.9 is out"
  update_check   # checked again: still one notification for this version
  eq "$(grep -c 'Fawwk 9.9.9 is out' "$SB/notified")" 1
  # The line after commands: in a terminal only, not for the updating commands.
  out=$(FAWWK_UPDATE_NOTICE_FORCE=1 update_notice list 2>&1)
  has "$out" "Fawwk 9.9.9 is out"; has "$out" "you have $FAWWK_VERSION"; has "$out" 'sudo fawwk update'
  eq "$(FAWWK_UPDATE_NOTICE_FORCE=1 update_notice update 2>&1)" ''
  eq "$(update_notice list 2>&1)" ''   # not a terminal here
  eq "$(FAWWK_UPDATE_NOTICE_FORCE=1 UPDATE_CHECK=off update_notice list 2>&1)" ''
  # The daily check runs once a day, not every minute.
  # (A check rewrites UC_CHECKED: an old value means it was skipped.)
  conf_set "$UPDATE_FILE" UC_CHECKED 1000
  UPDATE_EVERY=999999999999 update_check_daily; update_load; eq "$UC_CHECKED" 1000   # checked recently: skipped
  update_check_daily; update_load; [[ $UC_CHECKED -gt 1000 ]]                        # a day old: checks
  conf_set "$UPDATE_FILE" UC_CHECKED 1000
  UPDATE_CHECK=off update_check_daily; update_load; eq "$UC_CHECKED" 1000            # turned off
  # The release page, for a GitHub remote.
  git -C "$home" remote set-url origin https://github.com/deHypeChief/fawwk.git
  eq "$(update_release_url 0.4.0)" https://github.com/deHypeChief/fawwk/releases/tag/v0.4.0
}

test_proxy_logs_styling() {
  load_fawwk
  command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; return 0; }
  local out
  out=$(printf '%s\n' \
    '{"level":"info","ts":1793940629.21,"msg":"maxprocs: Leaving GOMAXPROCS=6: CPU quota undefined"}' \
    '{"level":"warn","ts":1793940629.21,"msg":"No files matching import glob pattern","pattern":"/etc/caddy/custom/*.caddy"}' \
    '{"level":"info","ts":1793940629.21,"msg":"serving initial configuration"}' \
    '{"level":"info","ts":1793971916.67,"logger":"admin.api","msg":"received request","method":"POST"}' \
    '{"level":"warn","ts":1793971916.67,"logger":"http.auto_https","msg":"server is listening only on the HTTP port, so no automatic HTTPS will be applied to this server"}' \
    '{"level":"warn","ts":1793971916.67,"logger":"http","msg":"HTTP/2 skipped because it requires TLS","addr":":80"}' \
    '{"level":"info","ts":1793971916.67,"logger":"http","msg":"enabling automatic TLS certificate management","domains":["panel.vaserahq.com","api.vaserahq.com"]}' \
    '{"level":"info","ts":1793971916.67,"logger":"admin.api","msg":"load complete"}' \
    '{"level":"info","ts":1793971916.68,"logger":"tls.obtain","msg":"obtaining certificate","identifier":"api.vaserahq.com"}' \
    '{"level":"info","ts":1793971917.54,"msg":"trying to solve challenge","identifier":"api.vaserahq.com","challenge_type":"http-01"}' \
    '{"level":"info","ts":1793971929.15,"logger":"tls.issuance.acme","msg":"served key authentication","identifier":"api.vaserahq.com"}' \
    '{"level":"info","ts":1793971933.07,"logger":"tls.obtain","msg":"certificate obtained successfully","identifier":"api.vaserahq.com"}' \
    '{"level":"error","ts":1793971999.00,"logger":"tls.obtain","msg":"could not get certificate from issuer","identifier":"x.vaserahq.com","error":"HTTP 429 rateLimited"}' \
    'plain text line' | TZ=UTC logs_pretty proxy)
  has "$out" "$G_H$G_H Fri  6 Nov $G_H$G_H"
  has "$out" '  04:50:29  INF  Proxy started'
  has "$out" '  13:31:56  INF  HTTPS managed for api.vaserahq.com, panel.vaserahq.com'
  has "$out" '  13:31:56  INF  Config reloaded'
  has "$out" '  13:31:56  INF  Requesting an HTTPS certificate for api.vaserahq.com'
  has "$out" "  13:31:57  INF  Let's Encrypt is checking api.vaserahq.com"
  has "$out" '  13:32:13  OK   Certificate issued for api.vaserahq.com'
  has "$out" $'  13:33:19  ERR  could not get certificate from issuer  x.vaserahq.com\n                 ↳ HTTP 429 rateLimited'
  has "$out" '                 plain text line'
  local noise
  for noise in maxprocs 'import glob' 'received request' 'only on the HTTP port' 'HTTP/2 skipped' 'served key'; do
    hasnt "$out" "$noise"
  done
}

test_logs_styling() {
  load_fawwk
  local out
  # Colours off (NO_COLOR) to compare the layout; UTC so times don't depend on the machine.
  out=$(printf '%s\n' \
    '2026-11-04T23:59:58.1Z Server listening on :3000' \
    '2026-11-05T00:00:01.0Z {"level":30,"time":1,"pid":1,"hostname":"h","msg":"connected","db":"shop","ms":42}' \
    '2026-11-05T00:00:02.0Z GET /api/classes 200 12ms' \
    '2026-11-05T00:00:05.0Z {"level":"warn","message":"slow query","ms":1250}' \
    '2026-11-05T00:00:06.0Z Error: connect ECONNREFUSED' \
    '2026-11-05T00:00:06.0Z     at TCPConnectWrap.afterConnect (node:net:1555:16)' \
    'no timestamp here' | TZ=UTC logs_pretty app)
  has "$out" "$G_H$G_H Wed  4 Nov $G_H$G_H"
  has "$out" "$G_H$G_H Thu  5 Nov $G_H$G_H"
  has "$out" '  23:59:58       Server listening on :3000'
  has "$out" '  00:00:01  INF  connected  db=shop ms=42'
  hasnt "$out" 'hostname='
  has "$out" '  00:00:02       GET /api/classes 200 12ms'
  has "$out" '  00:00:05  WRN  slow query  ms=1250'
  has "$out" '  00:00:06  ERR  Error: connect ECONNREFUSED'
  has "$out" '  00:00:06           at TCPConnectWrap'
  has "$out" '                 no timestamp here'
  # Build logs: steps, their output, done / cached, errors.
  out=$(printf '%s\n' '==> planning' '#5 [builder 2/6] COPY a b' '#5 CACHED' '#7 [builder 4/6] RUN npm ci' \
    '#7 0.512 added 312 packages' '#7 DONE 2.1s' '#9 ERROR: process "npm run build" did not complete' | logs_pretty build)
  has "$out" "$G_STEP planning"
  has "$out" "  $G_ARROW [builder 2/6] COPY a b"
  has "$out" "    $G_OK cached"
  has "$out" "    $G_V added 312 packages"
  has "$out" "    $G_OK done in 2.1s"
  has "$out" "    $G_ERR ERROR: process"
  # With colours, a 500 is red and the method bold, and the colour codes themselves stay intact.
  C_RED=$'\e[31m' C_BOLD=$'\e[1m' C_RESET=$'\e[0m' C_GREEN=$'\e[32m'
  out=$(printf '2026-11-05T00:00:04.0Z GET /x 500 3ms\n' | TZ=UTC logs_pretty app)
  has "$out" $'\e[1mGET\e[0m /x \e[31m500\e[0m 3ms'
  # Not a terminal and no override: unstyled.
  no logs_styled 0
  FAWWK_LOGS_STYLE=1 logs_styled 0
  FAWWK_LOGS_STYLE=1 no logs_styled 1   # --raw
}

test_release_notes() {
  local out
  out=$("$ROOT/scripts/release-notes.sh" 0.4.0)
  has "$out" '### New'; has "$out" 'Telegram notifications'
  hasnt "$out" '## 0.3.0'                         # stops at the next version
  [[ ${out:0:1} == '#' ]]                          # no leading blank line
  has "$("$ROOT/scripts/release-notes.sh" 0.0.1)" 'See CHANGELOG.md'
  # The version being released has notes (so a release never goes out empty).
  load_fawwk
  hasnt "$("$ROOT/scripts/release-notes.sh" "$FAWWK_VERSION")" 'See CHANGELOG.md'
}

# ---------- run ----------
echo "Fawwk tests"
for fn in $(declare -F | awk '{print $3}' | grep '^test_' | sed 's/^test_//'); do t "$fn"; done
printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) || { printf 'Failed: %s\n' "${FAILED[*]}"; exit 1; }
