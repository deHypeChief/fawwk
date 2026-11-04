#!/usr/bin/env bash
# fawwk — day-to-day commands for existing apps.

# ---------- deploy / restart / stop / start ----------
cmd_deploy() {
  local name=${1-}
  [[ $name == -h || $name == --help ]] && { echo "Usage: sudo fawwk deploy <app> | --all   Pull the latest commit and redeploy"; return 0; }
  require_root deploy; require_setup
  if [[ $name == --all ]]; then
    local failed=() n
    while IFS= read -r n; do
      [[ -z $n ]] && continue
      ( deploy_app "$n" ) || failed+=("$n")
    done < <(app_names)
    ((${#failed[@]} == 0)) || die "Deploy failed for: ${failed[*]}"
    return 0
  fi
  if [[ -z $name ]]; then
    local apps
    apps=$(app_names | tr '\n' ' ' || true)
    [[ -n $apps ]] || { info "No apps yet."; cmd_create; return; }
    ask name "Which app? ($apps)" "" app_exists_check
  fi
  if ! app_exists "$name"; then
    confirm "There's no app named '$name'. Create it now?" Y || return 1
    cmd_create "$name"
    return
  fi
  deploy_app "$name" || die "Deploy failed; the previous version is still live."
}

app_exists_check() { app_exists "$1" || { warn "No app named '$1'"; return 1; }; }

cmd_restart() {
  app_require_arg "${1-}" restart; require_root restart; require_setup
  app_load_locked "$1"
  step "Restarting $1 (zero downtime)"
  restart_app || die "Restart failed; the previous container is still running."
  ok "Restarted"
}

cmd_stop() {
  app_require_arg "${1-}" stop; require_root stop; require_setup
  app_load_locked "$1"
  [[ -n $A_CONTAINER ]] && docker stop -t 15 "$A_CONTAINER" >/dev/null 2>&1 || true
  app_set A_STATE stopped
  is_worker || proxy_reload || true
  ok "$1 stopped. Its domains now answer 503. Start it again with: fawwk start $1"
}

cmd_start() {
  app_require_arg "${1-}" start; require_root start; require_setup
  app_load_locked "$1"
  step "Starting $1"
  restart_app || die "Couldn't start $1"
  deploy_summary
}

# ---------- rollback / history ----------
cmd_rollback() {
  app_require_arg "${1-}" rollback; require_root rollback; require_setup
  local name=$1 target=${2-} id commit image status note pick='' line
  app_load_locked "$name"
  local hf
  hf=$(history_file)
  [[ -f $hf ]] || die "$name has no deploy history yet."
  while IFS=$'\t' read -r id commit image status note; do
    [[ $status == ok && $image != - ]] || continue
    if [[ -n $target ]]; then
      [[ $id == "$target" || $commit == "$target"* ]] || continue
    else
      [[ $image == "$A_IMAGE" ]] && continue
    fi
    docker image inspect "$image" >/dev/null 2>&1 || continue
    pick="$id"$'\t'"$commit"$'\t'"$image"
    break
  done < <(tac "$hf")
  [[ -n $pick ]] || die "No earlier version available to roll back to (fawwk keeps the last $KEEP_IMAGES images)."
  IFS=$'\t' read -r id commit image <<<"$pick"
  [[ $image != "$A_IMAGE" ]] || die "That version is already live."
  local from=$A_COMMIT
  step "Rolling back $name to ${commit:0:7} (deploy $id)"
  confirm "Continue?" Y || return 1
  local nid
  nid=$(deploy_id)
  release_image "$image" "$commit" "$nid" || die "Rollback failed; the current version is still live."
  history_add "$nid" "$commit" "$image" ok "rollback to $id"
  # Don't let auto-deploy immediately bring back the commit we rolled away from.
  [[ -n $from ]] && app_set A_FAILED_COMMIT "$from"
  ok "Rolled back. Auto-deploy will resume on your next push."
}

cmd_history() {
  local name='' n=15 json=0
  while (($#)); do
    case $1 in
      --json) json=1; shift ;;
      -n) need_arg "$@"; n=$2; shift 2 ;;
      *) [[ -z $name ]] && name=$1 || n=$1; shift ;;
    esac
  done
  set -- "$name" "$n"
  app_require_arg "${1-}" history; require_root history; require_setup
  app_load "$1"
  local hf id commit image status note mark
  hf=$(history_file)
  if ((json)); then
    [[ -f $hf ]] || { echo '[]'; return 0; }
    tail -n "$2" "$hf" | tac | jq -R -s --arg live "$A_IMAGE" '
      split("\n") | map(select(length > 0) | split("\t") |
        {id: .[0], commit: .[1], image: .[2], status: .[3], note: (.[4] // ""), live: (.[2] == $live)})'
    return 0
  fi
  [[ -f $hf ]] || { info "No deploys yet."; return 0; }
  printf '\n  %s%-2s%-22s  %-8s  %-8s  %s%s\n' "$C_MUTED" "" "DEPLOY" "COMMIT" "STATUS" "NOTE" "$C_RESET"
  while IFS=$'\t' read -r id commit image status note; do
    mark='  '
    [[ $image == "$A_IMAGE" ]] && mark="${C_ACCENT}${G_PROMPT}${C_RESET} "
    [[ $status == ok ]] && status="${C_GREEN}${G_OK} ok${C_RESET}    " || status="${C_RED}${G_ERR} failed${C_RESET}"
    printf '  %s%-22s  %s%-8s%s  %s  %s\n' "$mark" "$id" "$C_ACCENT2" "${commit:0:7}" "$C_RESET" "$status" "$note"
  done < <(tail -n "${2:-15}" "$hf" | tac)
  printf '\n  %s%s live %s roll back with: fawwk rollback %s [deploy-id]%s\n\n' "$C_MUTED" "$G_PROMPT" "$G_SEP" "$1" "$C_RESET"
}

# ---------- list / info / logs / exec ----------
# app_json — the loaded app as a JSON object (for --json output; secrets are never included).
app_json() {
  jq -n --arg name "$A_NAME" --arg repo "$(repo_path "$A_REPO")" --arg branch "$A_BRANCH" --arg dir "${A_DIR:-.}" \
    --arg auth "$A_AUTH" --arg build "${A_BUILD:-auto}" --arg build_env "${A_BUILD_ENV:-all}" \
    --arg routes "$A_ROUTES" --arg port "$A_PORT" --arg health "$A_HEALTH" \
    --arg health_timeout "${A_HEALTH_TIMEOUT:-$HEALTH_TIMEOUT}" --arg memory "$A_MEMORY" --arg cpus "$A_CPUS" \
    --arg volumes "$A_VOLUMES" --arg release "$A_RELEASE" --arg auto "$A_AUTO" --arg state "$(app_live_state)" \
    --arg container "$A_CONTAINER" --arg image "$A_IMAGE" --arg commit "$A_COMMIT" \
    --arg failed "$A_FAILED_COMMIT" --arg created "$A_CREATED" --arg deployed "$A_DEPLOYED" \
    --argjson env_count "$(env_count "$(app_envfile "$A_NAME")")" '
    def words: split(" ") | map(select(length > 0));
    def nul: if . == "" then null else . end;
    {name: $name, repo: $repo, branch: $branch, dir: $dir, auth: $auth, build: $build, build_env: $build_env,
     routes: ($routes | words), urls: ($routes | words | map("https://" + .)),
     port: ($port | nul | if . then tonumber else null end), health: ($health | nul),
     health_timeout: ($health_timeout | tonumber), memory: ($memory | nul), cpus: ($cpus | nul),
     volumes: ($volumes | words), release: ($release | nul), auto_deploy: ($auto == "yes"), state: $state,
     container: ($container | nul), image: ($image | nul), commit: ($commit | nul),
     failed_commit: ($failed | nul), created: ($created | nul), deployed: ($deployed | nul), env_count: $env_count}'
}

cmd_list() {
  local json=0
  [[ ${1-} == --json ]] && json=1
  require_root list; require_setup
  local name n=0 live
  if ((json)); then
    while IFS= read -r name; do
      [[ -z $name ]] && continue
      app_load "$name"
      app_json
    done < <(app_names) | jq -s .
    return 0
  fi
  printf '\n  %s%-20s %-11s %-8s %-19s %s%s\n' "$C_MUTED" "APP" "STATE" "COMMIT" "DEPLOYED" "URL" "$C_RESET"
  while IFS= read -r name; do
    [[ -z $name ]] && continue
    n=$((n + 1))
    app_load "$name"
    live=$(app_live_state)
    printf '  %s%-20s%s %s %s%-8s%s %-19s %s\n' "$C_BOLD" "$name" "$C_RESET" "$(state_color "$live")" \
      "$C_ACCENT2" "${A_COMMIT:0:7}" "$C_RESET" "${A_DEPLOYED:--}" \
      "$( [[ -n $A_ROUTES ]] && route_url "${A_ROUTES%% *}" || echo "${C_MUTED}(worker)${C_RESET}")"
  done < <(app_names)
  printf '\n'
  ((n)) || hint "No apps yet. Create one with: sudo fawwk create"
}

app_live_state() {
  [[ $A_STATE == stopped ]] && { echo stopped; return; }
  [[ -z $A_CONTAINER ]] && { echo new; return; }
  docker inspect -f '{{.State.Status}}' "$A_CONTAINER" 2>/dev/null || echo missing
}

# A coloured dot plus the state, always 11 visible characters wide so tables line up.
state_color() {
  local c
  case $1 in
    running) c=$C_GREEN ;;
    stopped | new) c=$C_MUTED ;;
    restarting | created) c=$C_YELLOW ;;
    *) c=$C_RED ;;
  esac
  printf '%s%s %-9s%s' "$c" "$G_DOT" "$1" "$C_RESET"
}

cmd_info() {
  local json=0 a
  for a in "$@"; do [[ $a == --json ]] && json=1; done
  [[ ${1-} == --json ]] && shift
  app_require_arg "${1-}" info; require_root info; require_setup
  app_load "$1"
  ((json)) && { app_json; return 0; }
  local r k
  printf '\n%s%s%s %s%s%s  %s\n\n' "$C_ACCENT" "$G_STEP" "$C_RESET" "$C_BOLD" "$A_NAME" "$C_RESET" "$(state_color "$(app_live_state)")"
  k() { printf '  %s%-14s%s %s\n' "$C_MUTED" "$1" "$C_RESET" "$2"; }
  k Repo "$(repo_path "$A_REPO") @ $A_BRANCH"
  [[ $A_DIR != . ]] && k Folder "$A_DIR"
  k Access "$A_AUTH${A_GH_SOURCE:+ ($A_GH_SOURCE)}"
  k Build "${A_BUILD:-auto}${A_BUILD_ENV:+ ${C_MUTED}(build-time env: $A_BUILD_ENV)${C_RESET}}"
  if [[ -n $A_ROUTES ]]; then
    for r in $A_ROUTES; do k URL "${C_ACCENT2}$(route_url "$r")${C_RESET}"; done
    k Port "$A_PORT"
    k Health "${A_HEALTH:-any HTTP response} ${C_MUTED}(timeout ${A_HEALTH_TIMEOUT:-$HEALTH_TIMEOUT}s)${C_RESET}"
    [[ $A_ROUTES == */* ]] && k "Strip prefix" "$A_STRIP"
  else
    k Type "background worker"
  fi
  k "Env vars" "$(env_count "$(app_envfile "$A_NAME")")"
  k Limits "memory ${A_MEMORY:-unlimited}, cpus ${A_CPUS:-unlimited}"
  [[ -n $A_VOLUMES ]] && k Volumes "$A_VOLUMES"
  [[ -n $A_RELEASE ]] && k Release "$A_RELEASE"
  [[ -s $(app_dir "$A_NAME")/cron ]] && k "Cron jobs" "$(wc -l <"$(app_dir "$A_NAME")/cron") ${C_MUTED}(fawwk cron $A_NAME)${C_RESET}"
  k Auto-deploy "$A_AUTO"
  k Commit "${A_COMMIT:0:7}"
  k Deployed "${A_DEPLOYED:--}"
  k Container "${A_CONTAINER:--}"
  if [[ -n $A_CONTAINER ]] && docker inspect "$A_CONTAINER" >/dev/null 2>&1; then
    k Usage "$(docker stats --no-stream --format 'CPU {{.CPUPerc}}  RAM {{.MemUsage}}' "$A_CONTAINER" 2>/dev/null)"
  fi
  [[ -n $A_FAILED_COMMIT ]] && k "Last failure" "${A_FAILED_COMMIT:0:7} (auto-deploy skips it until a new push)"
  printf '\n'
  unset -f k
}

cmd_logs() {
  local name='' follow=() tail=100 build=0
  while (($#)); do
    case $1 in
      -f | --follow) follow=(-f); shift ;;
      -n | --tail) need_arg "$@"; tail=$2; shift 2 ;;
      --build) build=1; shift ;;
      -*) die "Unknown option: $1" ;;
      *) name=$1; shift ;;
    esac
  done
  app_require_arg "$name" logs; require_root logs; require_setup
  app_load "$name"
  if ((build)); then
    local last
    last=$(ls -1t "$(app_var "$name")/logs/"*.log 2>/dev/null | head -n1 || true)
    [[ -n $last ]] || die "No build logs yet."
    hint "Build log: $last"
    tail -n "$tail" "${follow[@]}" "$last"
    return
  fi
  [[ -n $A_CONTAINER ]] || die "$name isn't running. Build logs: fawwk logs $name --build"
  docker logs --tail "$tail" "${follow[@]}" "$A_CONTAINER"
}

cmd_exec() {
  app_require_arg "${1-}" exec; require_root exec; require_setup
  app_load "$1"; shift
  [[ $(app_live_state) == running ]] || die "$A_NAME isn't running."
  local tty=(-i)
  [[ -t 0 ]] && tty=(-it)
  if (($#)); then docker exec "${tty[@]}" "$A_CONTAINER" "$@"
  else docker exec "${tty[@]}" "$A_CONTAINER" sh -c 'command -v bash >/dev/null && exec bash || exec sh'
  fi
}

# ---------- env ----------
env_usage() {
  cat <<'EOF'
Usage: sudo fawwk env <app> [command]

  show [--reveal]     List variables (values masked unless --reveal)
  set KEY=value ...   Add or change variables
  unset KEY ...       Remove variables
  import [file]       Merge a .env file, or paste one if no file is given
  edit                Open all variables in your editor ($EDITOR, default nano)
  check               Compare with the repo's .env.example

Changes apply on the next restart; fawwk offers to restart right away.
EOF
}

cmd_env() {
  local name=${1-} sub=${2:-show}
  [[ $name == -h || $name == --help || -z $name ]] && { env_usage; return 0; }
  require_root env; require_setup
  app_load "$name"
  shift 2 || shift $#
  local f tmp changed=0 kv k
  f=$(app_envfile "$name")
  [[ -f $f ]] || install -m 600 /dev/null "$f"
  case $sub in
    show | ls | list)
      [[ -s $f ]] || { info "No variables set."; return 0; }
      while IFS= read -r kv; do
        k=${kv%%=*}
        if [[ ${1-} == --reveal ]]; then printf '%s\n' "$kv"
        else printf '%s=%s\n' "$k" "$(env_mask "${kv#*=}")"; fi
      done <"$f"
      ;;
    set)
      (($#)) || die "Usage: fawwk env $name set KEY=value [KEY=value ...]"
      tmp=$(mktemp)
      printf '%s\n' "$@" | env_parse >"$tmp"
      [[ -s $tmp ]] || { rm -f "$tmp"; die "Nothing valid to set. Use KEY=value."; }
      env_save "$name" "$tmp"
      ok "Set: $(cut -d= -f1 "$tmp" | tr '\n' ' ')"
      rm -f "$tmp"; changed=1
      ;;
    unset | rm)
      (($#)) || die "Usage: fawwk env $name unset KEY [KEY ...]"
      tmp=$(mktemp)
      cp "$f" "$tmp"
      for k in "$@"; do awk -v k="$k" 'index($0, k "=") != 1' "$tmp" >"$tmp.2"; mv "$tmp.2" "$tmp"; done
      install -m 600 "$tmp" "$f"; rm -f "$tmp"
      ok "Removed: $*"; changed=1
      ;;
    import)
      tmp=$(mktemp)
      if [[ -n ${1-} ]]; then
        [[ -f $1 ]] || die "File not found: $1"
        env_parse <"$1" >"$tmp"
      else
        env_read_paste >"$tmp"
      fi
      env_save "$name" "$tmp"
      ok "Imported $(grep -c '=' "$tmp" || true) variable(s)"
      rm -f "$tmp"; changed=1
      ;;
    edit)
      tmp=$(mktemp --suffix=.env)
      chmod 600 "$tmp"
      cp "$f" "$tmp"
      "${EDITOR:-nano}" "$tmp"
      env_parse <"$tmp" >"$tmp.clean"
      if cmp -s "$tmp.clean" "$f"; then info "No changes."
      else install -m 600 "$tmp.clean" "$f"; ok "Saved"; changed=1
      fi
      rm -f "$tmp" "$tmp.clean"
      ;;
    check)
      local ex
      ex=$(env_example_file "$(build_context)" 2>/dev/null) || { info "The repo has no .env.example."; return 0; }
      env_warn_missing "$(build_context)"
      info "Compared with $(basename "$ex")"
      ;;
    *) env_usage; return 1 ;;
  esac
  if ((changed)) && [[ $(app_live_state) == running ]]; then
    if confirm "Restart $name now to apply? (zero downtime)" Y; then
      app_load_locked "$name"; restart_app && ok "Applied"
    else
      info "Apply later with: fawwk restart $name"
    fi
  fi
}

# ---------- domains / port / health ----------
cmd_domain() {
  local name=${1-} sub=${2:-list} r
  [[ -z $name || $name == -h || $name == --help ]] && {
    echo "Usage: sudo fawwk domain <app> [list | add <domain[/path]> | rm <domain[/path]>]"; return 0; }
  require_root domain; require_setup
  app_load_locked "$name"
  case $sub in
    list | ls)
      [[ -n $A_ROUTES ]] || { info "No domains (background worker)."; return 0; }
      for r in $A_ROUTES; do printf '%s\n' "$(route_url "$r")"; done
      return 0 ;;
    add)
      r=$(route_normalize "${3-}")
      [[ -n $r ]] || die "Usage: fawwk domain $name add <domain[/path]>"
      route_check "$r" "$name" || exit 1
      [[ " $A_ROUTES " == *" $r "* ]] && die "$r is already on $name."
      if [[ -z $A_PORT ]]; then ask A_PORT "Port the app listens on" 3000 valid_port; app_set A_PORT "$A_PORT"; fi
      app_set A_ROUTES "${A_ROUTES:+$A_ROUTES }$r"
      dns_report "${r%%/*}" ;;
    rm | remove)
      r=$(route_normalize "${3-}")
      [[ " $A_ROUTES " == *" $r "* ]] || die "$name doesn't have $r. Current: ${A_ROUTES:-none}"
      local rest
      rest=$(printf '%s\n' $A_ROUTES | grep -Fvx -- "$r" | tr '\n' ' ' || true)
      app_set A_ROUTES "${rest% }" ;;
    *) die "Unknown subcommand: $sub (list, add, rm)" ;;
  esac
  proxy_reload || die "Couldn't update the proxy."
  ok "Domains for $name: ${A_ROUTES:-none}"
  [[ -z $A_ROUTES && $(app_live_state) == running ]] && info "No domains left; the app keeps running as a worker."
  return 0
}

cmd_port() {
  app_require_arg "${1-}" port; require_root port; require_setup
  app_load "$1"
  local p=${2-}
  [[ -n $p ]] || { info "$1 listens on port ${A_PORT:-none}"; return 0; }
  valid_port "$p" || exit 1
  app_load_locked "$1"
  app_set A_PORT "$p"
  ok "Port set to $p"
  [[ -n $A_IMAGE ]] && confirm "Restart $1 now to apply?" Y && { restart_app && ok "Applied"; }
  return 0
}

cmd_health() {
  app_require_arg "${1-}" health; require_root health; require_setup
  app_load "$1"
  local name=$1 p='' t='' set_path=0
  shift
  while (($#)); do
    case $1 in
      --timeout) need_arg "$@"; t=$2; shift 2 ;;
      *) p=$1; set_path=1; shift ;;
    esac
  done
  if ((set_path == 0)) && [[ -z $t ]]; then
    info "Health check: ${A_HEALTH:-any HTTP response}, timeout ${A_HEALTH_TIMEOUT:-$HEALTH_TIMEOUT}s"
    hint "Set: fawwk health $name /health [--timeout 120]   $G_SEP   clear: fawwk health $name off"
    return 0
  fi
  if [[ -n $t ]]; then
    [[ $t =~ ^[0-9]+$ ]] && ((t >= 5 && t <= 3600)) || die "--timeout must be 5 to 3600 seconds"
    app_set A_HEALTH_TIMEOUT "$t"
    ok "Health check timeout: ${t}s"
  fi
  if ((set_path)); then
    [[ $p == off || $p == none ]] && p=''
    [[ -z $p || $p == /* ]] || p="/$p"
    app_set A_HEALTH "$p"
    ok "Health check: ${p:-any HTTP response} (used from the next deploy)"
  fi
}

# ---------- build method ----------
cmd_build() {
  app_require_arg "${1-}" build; require_root build; require_setup
  app_load "$1"
  local t=${2-} ctx
  ctx=$(build_context)
  if [[ -z $t ]]; then
    info "Build method for $1: ${A_BUILD:-auto}"
    [[ -d $ctx ]] && hint "Next deploy: $(build_describe "$(build_resolve "$ctx" "${A_BUILD:-auto}")" "$ctx")"
    hint "Change with: fawwk build $1 auto|dockerfile|nixpacks|static"
    return 0
  fi
  [[ $t =~ ^(auto|dockerfile|nixpacks|static)$ ]] || die "Use: fawwk build $1 auto|dockerfile|nixpacks|static"
  app_set A_BUILD "$t"
  ok "Build method for $1: $t (used from the next deploy)"
  if [[ -n $A_IMAGE ]] && confirm "Redeploy $1 now?" Y; then
    deploy_app "$1" || die "Deploy failed; the previous version is still live."
  fi
}

# ---------- auto-deploy ----------
cmd_autodeploy() {
  app_require_arg "${1-}" autodeploy; require_root autodeploy; require_setup
  app_load "$1"
  case ${2-} in
    on | yes) app_set A_AUTO yes; ok "Auto-deploy on: pushes to $A_BRANCH deploy within a minute" ;;
    off | no) app_set A_AUTO no; ok "Auto-deploy off" ;;
    '') info "Auto-deploy for $1: $A_AUTO" ;;
    *) die "Usage: fawwk autodeploy $1 on|off" ;;
  esac
}

# Called by the systemd timer every minute. Deploys apps whose branch has a new commit.
cmd_sync() {
  local quiet=0 name out
  [[ ${1-} == --quiet || ${1-} == -q ]] && quiet=1
  require_root sync; require_setup
  mkdir -p "$FAWWK_LOG"
  # After `fawwk update`, bring a webhook receiver started by an older Fawwk up to the current settings.
  if hooks_enabled && docker inspect "$HOOKS_CONTAINER" >/dev/null 2>&1 && ! hooks_container_current; then
    if out=$(hooks_container_start); then
      printf '[%s] webhook receiver recreated with current settings\n' "$(ts)" >>"$FAWWK_LOG/sync.log"
    else
      printf '[%s] webhook receiver: recreate FAILED: %s\n' "$(ts)" "$(tail -n 1 <<<"$out")" >>"$FAWWK_LOG/sync.log"
    fi
  fi
  while IFS= read -r name; do
    [[ -z $name ]] && continue
    (
      LOCK_NOWAIT=1
      app_load "$name"
      [[ $A_AUTO == yes && $A_STATE != stopped ]] || exit 0
      head=$(git_remote_head) || exit 0
      [[ -n $head && $head != "$A_COMMIT" && $head != "$A_FAILED_COMMIT" ]] || { ((quiet)) || info "$name: up to date"; exit 0; }
      auto_deploy "$name" "$head" sync.log
    ) || true
  done < <(app_names)
}

# ---------- remove ----------
cmd_remove() {
  local name='' yes=0
  while (($#)); do
    case $1 in -y | --yes) yes=1; shift ;; *) name=$1; shift ;; esac
  done
  app_require_arg "$name" remove; require_root remove; require_setup
  app_load "$name"
  if ((yes == 0)); then
    is_interactive || die "Add --yes to remove without a prompt."
    warn "This deletes $name: its containers, images, env vars, deploy history${A_VOLUMES:+ and the data in its volumes ($A_VOLUMES)}."
    local typed
    read -r -p "  ${C_RED}${G_PROMPT}${C_RESET} Type ${C_BOLD}$name${C_RESET} to confirm: " typed
    [[ $typed == "$name" ]] || die "Cancelled."
  fi
  app_load_locked "$name"
  step "Removing $name"
  docker ps -aq --filter "label=fawwk.app=$name" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker images "fawwk/$name" -q | sort -u | xargs -r docker rmi -f >/dev/null 2>&1 || true
  local v
  for v in $A_VOLUMES; do docker volume rm "$(volume_name "$name" "$v")" >/dev/null 2>&1 || true; done
  rm -f "$CRON_DIR/fawwk-$name" "$FAWWK_LOG/$name.log" "$FAWWK_LOG/$name-cron.log"
  rm -rf "$(app_dir "$name")" "$(app_var "$name")"
  proxy_reload || true
  if [[ $A_AUTH == deploykey ]]; then
    info "You can also delete the 'fawwk-$(hostname)' deploy key from the repo settings."
  fi
  ok "$name removed"
}

# ---------- proxy ----------
cmd_proxy() {
  require_root proxy; require_setup
  case ${1:-status} in
    reload) proxy_reload && ok "Proxy config regenerated and reloaded" ;;
    logs) docker logs --tail "${2:-100}" -f "$FAWWK_PROXY" ;;
    config) cat "$CADDY_DIR/Caddyfile" ;;
    upgrade)
      info "Proxy image: $(proxy_image) $G_ARROW $CADDY_IMAGE ${C_MUTED}(sites pause for a few seconds)${C_RESET}"
      confirm "Recreate the proxy now?" Y || return 1
      proxy_upgrade && ok "Proxy is running $CADDY_IMAGE" ;;
    status)
      if proxy_running; then ok "Caddy is running ($FAWWK_PROXY, $(proxy_image))"; else err "Caddy isn't running. Try: fawwk proxy reload"; fi ;;
    *) die "Usage: fawwk proxy [status|reload|logs|config|upgrade]" ;;
  esac
}

# ---------- self update ----------
cmd_update() {
  require_root update
  [[ -d $FAWWK_HOME/.git ]] || die "Fawwk at $FAWWK_HOME wasn't installed from git. Re-run install.sh from a new copy."
  local before
  before=$(fawwk_version)
  git -C "$FAWWK_HOME" pull --ff-only || die "Update failed."
  chmod +x "$FAWWK_HOME/bin/fawwk" "$FAWWK_HOME/lib/askpass.sh"
  # Finish with the new code: it knows what the new version needs on the server.
  exec "$FAWWK_HOME/bin/fawwk" post-update "$before"
}

# Runs after `fawwk update` (from the new code): refreshes what setup installed.
cmd_post_update() {
  require_root post-update
  [[ -f $FAWWK_CONF ]] || { ok "Fawwk updated to $(fawwk_version)"; return 0; }
  require_setup
  setup_logrotate >/dev/null 2>&1 || true
  if hooks_enabled; then
    # The webhook receiver runs code from this checkout; recreate or restart it to pick up changes.
    if hooks_container_current; then
      docker restart "$HOOKS_CONTAINER" >/dev/null 2>&1 || true
    else
      hooks_ensure >/dev/null 2>&1 || warn "Couldn't refresh the webhook receiver. Run: sudo fawwk github connect"
    fi
  fi
  ok "Fawwk updated: ${1:-?} $G_ARROW $(fawwk_version)"
  [[ $(proxy_image) == "$CADDY_IMAGE" ]] || hint "A pinned proxy image is available: sudo fawwk proxy upgrade"
}
