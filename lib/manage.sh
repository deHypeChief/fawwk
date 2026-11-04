#!/usr/bin/env bash
# fawwk — day-to-day commands for existing apps.

# ---------- deploy / restart / stop / start ----------
cmd_deploy() {
  local name=${1-}
  [[ $name == -h || $name == --help ]] && { echo "Usage: sudo fawwk deploy <app>   Pull the latest commit and redeploy"; return 0; }
  require_root deploy; require_setup
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
  app_load "$1"; app_lock "$1"
  step "Restarting $1 (zero downtime)"
  restart_app || die "Restart failed; the previous container is still running."
  ok "Restarted"
}

cmd_stop() {
  app_require_arg "${1-}" stop; require_root stop; require_setup
  app_load "$1"; app_lock "$1"
  [[ -n $A_CONTAINER ]] && docker stop -t 15 "$A_CONTAINER" >/dev/null 2>&1 || true
  app_set A_STATE stopped
  is_worker || proxy_reload || true
  ok "$1 stopped. Its domains now answer 503. Start it again with: fawwk start $1"
}

cmd_start() {
  app_require_arg "${1-}" start; require_root start; require_setup
  app_load "$1"; app_lock "$1"
  step "Starting $1"
  restart_app || die "Couldn't start $1"
  deploy_summary
}

# ---------- rollback / history ----------
cmd_rollback() {
  app_require_arg "${1-}" rollback; require_root rollback; require_setup
  local name=$1 target=${2-} id commit image status note pick='' line
  app_load "$name"; app_lock "$name"
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
  app_require_arg "${1-}" history; require_root history; require_setup
  app_load "$1"
  local hf id commit image status note mark
  hf=$(history_file)
  [[ -f $hf ]] || { info "No deploys yet."; return 0; }
  printf '\n  %s%-2s%-17s  %-8s  %-8s  %s%s\n' "$C_MUTED" "" "DEPLOY" "COMMIT" "STATUS" "NOTE" "$C_RESET"
  while IFS=$'\t' read -r id commit image status note; do
    mark='  '
    [[ $image == "$A_IMAGE" ]] && mark="${C_ACCENT}${G_PROMPT}${C_RESET} "
    [[ $status == ok ]] && status="${C_GREEN}${G_OK} ok${C_RESET}    " || status="${C_RED}${G_ERR} failed${C_RESET}"
    printf '  %s%-17s  %s%-8s%s  %s  %s\n' "$mark" "$id" "$C_ACCENT2" "${commit:0:7}" "$C_RESET" "$status" "$note"
  done < <(tail -n "${2:-15}" "$hf" | tac)
  printf '\n  %s%s live %s roll back with: fawwk rollback %s [deploy-id]%s\n\n' "$C_MUTED" "$G_PROMPT" "$G_SEP" "$1" "$C_RESET"
}

# ---------- list / info / logs / exec ----------
cmd_list() {
  require_root list; require_setup
  local name n=0 live
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
  app_require_arg "${1-}" info; require_root info; require_setup
  app_load "$1"
  local r k
  printf '\n%s%s%s %s%s%s  %s\n\n' "$C_ACCENT" "$G_STEP" "$C_RESET" "$C_BOLD" "$A_NAME" "$C_RESET" "$(state_color "$(app_live_state)")"
  k() { printf '  %s%-14s%s %s\n' "$C_MUTED" "$1" "$C_RESET" "$2"; }
  k Repo "$(repo_path "$A_REPO") @ $A_BRANCH"
  [[ $A_DIR != . ]] && k Folder "$A_DIR"
  k Access "$A_AUTH"
  k Build "${A_BUILD:-auto}"
  if [[ -n $A_ROUTES ]]; then
    for r in $A_ROUTES; do k URL "${C_ACCENT2}$(route_url "$r")${C_RESET}"; done
    k Port "$A_PORT"
    k Health "${A_HEALTH:-any HTTP response}"
    [[ $A_ROUTES == */* ]] && k "Strip prefix" "$A_STRIP"
  else
    k Type "background worker"
  fi
  k "Env vars" "$(env_count "$(app_envfile "$A_NAME")")"
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
      for k in "$@"; do grep -v "^$k=" "$tmp" >"$tmp.2" || true; mv "$tmp.2" "$tmp"; done
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
      app_lock "$name"; restart_app && ok "Applied"
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
  app_load "$name"; app_lock "$name"
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
      rest=$(printf '%s\n' $A_ROUTES | grep -vx "$r" | tr '\n' ' ' || true)
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
  app_lock "$1"
  app_set A_PORT "$p"
  ok "Port set to $p"
  [[ -n $A_IMAGE ]] && confirm "Restart $1 now to apply?" Y && { restart_app && ok "Applied"; }
  return 0
}

cmd_health() {
  app_require_arg "${1-}" health; require_root health; require_setup
  app_load "$1"
  local p=${2-}
  [[ -n $p ]] || { info "Health check: ${A_HEALTH:-any HTTP response}   (set: fawwk health $1 /health, clear: fawwk health $1 off)"; return 0; }
  [[ $p == off || $p == none ]] && p=''
  [[ -z $p || $p == /* ]] || p="/$p"
  app_set A_HEALTH "$p"
  ok "Health check: ${p:-any HTTP response} (used from the next deploy)"
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
  local quiet=0 name
  [[ ${1-} == --quiet || ${1-} == -q ]] && quiet=1
  require_root sync; require_setup
  mkdir -p "$FAWWK_LOG"
  while IFS= read -r name; do
    [[ -z $name ]] && continue
    (
      LOCK_NOWAIT=1
      app_load "$name"
      [[ $A_AUTO == yes && $A_STATE != stopped ]] || exit 0
      head=$(git_remote_head) || exit 0
      [[ -n $head && $head != "$A_COMMIT" && $head != "$A_FAILED_COMMIT" ]] || { ((quiet)) || info "$name: up to date"; exit 0; }
      printf '[%s] %s: new commit %s, deploying\n' "$(ts)" "$name" "${head:0:7}" | tee -a "$FAWWK_LOG/sync.log" >&2
      if deploy_app "$name" >>"$FAWWK_LOG/$name.log" 2>&1; then
        printf '[%s] %s: deployed %s\n' "$(ts)" "$name" "${head:0:7}" | tee -a "$FAWWK_LOG/sync.log" >&2
      else
        printf '[%s] %s: deploy of %s FAILED (see %s)\n' "$(ts)" "$name" "${head:0:7}" "$FAWWK_LOG/$name.log" | tee -a "$FAWWK_LOG/sync.log" >&2
      fi
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
    warn "This deletes $name: its containers, images, env vars and deploy history."
    local typed
    read -r -p "  ${C_RED}${G_PROMPT}${C_RESET} Type ${C_BOLD}$name${C_RESET} to confirm: " typed
    [[ $typed == "$name" ]] || die "Cancelled."
  fi
  app_lock "$name"
  step "Removing $name"
  docker ps -aq --filter "label=fawwk.app=$name" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker images "fawwk/$name" -q | sort -u | xargs -r docker rmi -f >/dev/null 2>&1 || true
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
    status)
      if proxy_running; then ok "Caddy is running ($FAWWK_PROXY)"; else err "Caddy isn't running. Try: fawwk proxy reload"; fi ;;
    *) die "Usage: fawwk proxy [status|reload|logs|config]" ;;
  esac
}

# ---------- self update ----------
cmd_update() {
  require_root update
  [[ -d $FAWWK_HOME/.git ]] || die "Fawwk at $FAWWK_HOME wasn't installed from git. Re-run install.sh from a new copy."
  git -C "$FAWWK_HOME" pull --ff-only || die "Update failed."
  chmod +x "$FAWWK_HOME/bin/fawwk" "$FAWWK_HOME/lib/askpass.sh"
  ok "Fawwk updated to $("$FAWWK_HOME/bin/fawwk" version)"
}
