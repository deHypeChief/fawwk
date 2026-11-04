#!/usr/bin/env bash
# fawwk — changing an app after `create`: source (repo, branch, folder, access), resources
# (limits, volumes), release command, build-time env and cron jobs.

# settings_apply MODE — offers to apply a changed setting: "deploy" rebuilds, "restart" recreates
# the container from the current image. Does nothing for apps that were never deployed.
settings_apply() {
  [[ -n $A_IMAGE ]] || return 0
  if [[ $1 == deploy ]]; then
    confirm "Redeploy $A_NAME now to apply?" Y && { deploy_app "$A_NAME" || die "Deploy failed; the previous version is still live."; }
  else
    [[ $(app_live_state) == running ]] || return 0
    confirm "Restart $A_NAME now to apply? (zero downtime)" Y && { restart_app && ok "Applied"; }
  fi
  return 0
}

# ---------- source: branch / folder / repo / access ----------
cmd_branch() {
  app_require_arg "${1-}" branch; require_root branch; require_setup
  app_load_locked "$1"
  local b=${2-}
  [[ -n $b ]] || { info "$1 deploys $(repo_path "$A_REPO")@$A_BRANCH"; hint "Change with: fawwk branch $1 <branch>"; return 0; }
  local old=$A_BRANCH
  A_BRANCH=$b
  git_branch_exists || { A_BRANCH=$old; die "Branch '$b' doesn't exist in $(repo_path "$A_REPO")."; }
  app_set A_BRANCH "$b"
  app_set A_FAILED_COMMIT ''
  ok "$1 now deploys $(repo_path "$A_REPO")@$b"
  settings_apply deploy
}

cmd_folder() {
  app_require_arg "${1-}" folder; require_root folder; require_setup
  app_load_locked "$1"
  local d=${2-}
  [[ -n $d ]] || { info "$1 deploys the folder '${A_DIR:-.}'"; hint "Change with: fawwk folder $1 <path>   ('.' is the repo root)"; return 0; }
  valid_subdir "$d" || exit 1
  d=${d%/}
  local src
  src="$(app_var "$1")/src"
  [[ ! -d $src/.git || $d == . || -d $src/$d ]] || die "No folder '$d' in the last checkout of the repo."
  app_set A_DIR "$d"
  ok "$1 now deploys the folder '$d'"
  settings_apply deploy
}

access_usage() {
  cat <<'EOF'
Usage: sudo fawwk access <app> [method] [options]

  (none)        Show how the server reads the repo
  github        Through a connected GitHub App (see: fawwk github)
  deploykey     A read-only SSH deploy key for this repo
  token         A personal access token  [--token-file FILE] [--token-user USER]
  public        No credentials (public repos)
EOF
}

# access_switch PRESET TOKEN_FILE TOKEN_USER — re-runs the access setup for the loaded app. Runs in a
# subshell so a failed attempt leaves the current access (and its token file) exactly as it was.
access_switch() {
  local d out f rc=0
  d=$(app_dir "$A_NAME")
  out=$(mktemp)
  for f in token token.exp; do [[ -f $d/$f ]] && cp -p "$d/$f" "$d/$f.bak"; done
  (
    FAWWK_DIED=1   # this subshell reports its own errors
    git_setup_access "$1" "$2" "$3"
    declare -p A_AUTH A_GH_SOURCE A_GH_INSTALL A_TOKEN_USER >"$out"
  ) || rc=$?
  if ((rc != 0)); then
    for f in token token.exp; do
      if [[ -f $d/$f.bak ]]; then mv -f "$d/$f.bak" "$d/$f"; else rm -f "$d/$f"; fi
    done
    rm -f "$out"
    return 1
  fi
  rm -f "$d/token.bak" "$d/token.exp.bak"
  # shellcheck disable=SC1090
  source "$out"; rm -f "$out"
  [[ $A_AUTH == github ]] || rm -f "$d/token.exp"
  app_set A_AUTH "$A_AUTH"
  app_set A_GH_SOURCE "${A_GH_SOURCE-}"
  app_set A_GH_INSTALL "${A_GH_INSTALL-}"
  app_set A_TOKEN_USER "${A_TOKEN_USER-}"
}

cmd_access() {
  local name='' method='' token_file='' token_user=''
  while (($#)); do
    case $1 in
      -h | --help) access_usage; return 0 ;;
      --token-file) need_arg "$@"; token_file=$2; shift 2 ;;
      --token-user) need_arg "$@"; token_user=$2; shift 2 ;;
      -*) die "Unknown option: $1 (see: fawwk access --help)" ;;
      *) if [[ -z $name ]]; then name=$1; else method=$1; fi; shift ;;
    esac
  done
  app_require_arg "$name" access; require_root access; require_setup
  [[ -z $token_file || -f $token_file ]] || die "Token file not found: $token_file"
  app_load_locked "$name"
  if [[ -z $method ]]; then
    info "$name reads $(repo_path "$A_REPO") with: $A_AUTH${A_GH_SOURCE:+ ($A_GH_SOURCE)}"
    hint "Change with: fawwk access $name github|deploykey|token|public"
    return 0
  fi
  [[ $method =~ ^(github|deploykey|token|public)$ ]] || { access_usage; return 1; }
  [[ $method == token || -z $token_file ]] || die "--token-file only goes with: fawwk access $name token"
  step "Repository access for $name"
  access_switch "$method" "$token_file" "$token_user" || die "Access unchanged (still $A_AUTH)."
  ok "$name now reads the repo with: $A_AUTH"
}

cmd_repo() {
  local name='' url='' auth='' token_file='' token_user=''
  while (($#)); do
    case $1 in
      -h | --help) echo "Usage: sudo fawwk repo <app> <url|owner/name> [--github|--deploy-key|--token-file FILE]"; return 0 ;;
      --github) auth=github; shift ;;
      --deploy-key) auth=deploykey; shift ;;
      --token-file) need_arg "$@"; token_file=$2; auth=token; shift 2 ;;
      --token-user) need_arg "$@"; token_user=$2; shift 2 ;;
      -*) die "Unknown option: $1" ;;
      *) if [[ -z $name ]]; then name=$1; else url=$1; fi; shift ;;
    esac
  done
  app_require_arg "$name" repo; require_root repo; require_setup
  app_load_locked "$name"
  [[ -n $url ]] || { info "$name deploys $(repo_path "$A_REPO")@$A_BRANCH"; hint "Change with: fawwk repo $name <url|owner/name>"; return 0; }
  valid_repo "$url" || exit 1
  local old_repo=$A_REPO
  A_REPO=$(repo_https "$url")
  [[ $A_REPO != "$old_repo" ]] || { info "$name already deploys $(repo_path "$A_REPO")"; return 0; }
  step "Repository access for $(repo_path "$A_REPO")"
  if ! access_switch "$auth" "$token_file" "$token_user"; then
    A_REPO=$old_repo
    die "Repo unchanged."
  fi
  if ! git_branch_exists; then
    local def
    def=$(git_default_branch || true)
    [[ -n $def ]] || { A_REPO=$old_repo; die "Couldn't read the new repo's branches. Repo unchanged."; }
    warn "Branch '$A_BRANCH' doesn't exist there; using its default branch '$def'."
    app_set A_BRANCH "$def"
  fi
  app_set A_REPO "$A_REPO"
  app_set A_FAILED_COMMIT ''
  rm -rf "$(app_var "$name")/src"   # a fresh clone of the new repo on the next deploy
  ok "$name now deploys $(repo_path "$A_REPO")@$A_BRANCH"
  settings_apply deploy
}

# ---------- resources: limits / volumes ----------
cmd_limits() {
  app_require_arg "${1-}" limits; require_root limits; require_setup
  local name=$1 a k v changed=0 ncpu
  shift
  app_load_locked "$name"
  if (($# == 0)); then
    info "$name limits: memory ${A_MEMORY:-unlimited}, cpus ${A_CPUS:-unlimited}"
    hint "Set: fawwk limits $name memory=512m cpus=1   $G_SEP   remove: fawwk limits $name memory=off cpus=off"
    return 0
  fi
  ncpu=$(nproc 2>/dev/null || echo 1)
  for a in "$@"; do
    [[ $a == *=* ]] || die "Use KEY=value, e.g. memory=512m or cpus=1.5"
    k=${a%%=*} v=${a#*=}
    [[ $v == off || $v == none ]] && v=''
    case $k in
      memory | mem)
        v=${v,,}; v=${v%b}
        [[ -z $v || $v =~ ^[0-9]+[kmg]$ ]] || die "memory must look like 256m or 2g"
        [[ -z $v || $v != *k ]] || die "memory is too small (use m or g)"
        [[ -z $v || ! $v =~ ^[0-5]m$ ]] || die "Docker needs at least 6m of memory"
        app_set A_MEMORY "$v" ;;
      cpus | cpu)
        [[ -z $v || $v =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "cpus must be a number like 0.5 or 2"
        [[ -z $v ]] || awk -v v="$v" -v n="$ncpu" 'BEGIN { exit !(v > 0 && v <= n) }' || die "cpus must be more than 0 and at most $ncpu (this server's cores)"
        app_set A_CPUS "$v" ;;
      *) die "Unknown limit: $k (use memory or cpus)" ;;
    esac
    changed=1
  done
  ((changed)) && ok "$name limits: memory ${A_MEMORY:-unlimited}, cpus ${A_CPUS:-unlimited}"
  settings_apply restart
}

volume_usage() {
  cat <<'EOF'
Usage: sudo fawwk volume <app> [command]

  (none) | list            Volumes and where their data lives on the server
  add <path>               Keep <path> inside the container across deploys (e.g. /app/data)
  rm <path> [--delete-data]  Stop mounting it; the data is kept unless --delete-data

Each volume is a Docker volume, so it survives deploys, restarts and rollbacks. During a
zero-downtime deploy the old and new container both mount it for a few seconds.
EOF
}

cmd_volume() {
  local name=${1-} sub=${2:-list} p=${3-} v
  [[ -z $name || $name == -h || $name == --help ]] && { volume_usage; return 0; }
  require_root volume; require_setup
  app_load_locked "$name"
  case $sub in
    list | ls)
      [[ -n $A_VOLUMES ]] || { info "No volumes. Files written in the container are lost on each deploy."; hint "Keep a folder: fawwk volume $name add /app/data"; return 0; }
      for v in $A_VOLUMES; do
        local vn mp size
        vn=$(volume_name "$name" "$v")
        mp=$(docker volume inspect -f '{{.Mountpoint}}' "$vn" 2>/dev/null || true)
        size=$([[ -n $mp ]] && du -sh "$mp" 2>/dev/null | cut -f1 || echo '-')
        printf '  %s%-28s%s %-8s %s%s%s\n' "$C_ACCENT2" "$v" "$C_RESET" "${size:--}" "$C_MUTED" "${mp:-(created on next start)}" "$C_RESET"
      done ;;
    add)
      [[ $p =~ ^(/[A-Za-z0-9._-]+)+$ ]] || die "Use an absolute path inside the container, e.g. /app/data"
      [[ " $A_VOLUMES " == *" $p "* ]] && die "$p is already a volume of $name."
      app_set A_VOLUMES "${A_VOLUMES:+$A_VOLUMES }$p"
      ok "$p is now kept across deploys ${C_MUTED}(docker volume $(volume_name "$name" "$p"))${C_RESET}"
      settings_apply restart ;;
    rm | remove)
      [[ " $A_VOLUMES " == *" $p "* ]] || die "$name has no volume $p. Current: ${A_VOLUMES:-none}"
      local rest='' del=0
      [[ ${4-} == --delete-data ]] && del=1
      for v in $A_VOLUMES; do [[ $v == "$p" ]] || rest+="$v "; done
      app_set A_VOLUMES "${rest% }"
      ok "$p is no longer mounted"
      settings_apply restart
      if ((del)); then
        if docker volume rm "$(volume_name "$name" "$p")" >/dev/null 2>&1; then ok "Deleted its data"
        else warn "Couldn't delete the data yet (still in use?). Later: docker volume rm $(volume_name "$name" "$p")"
        fi
      else
        hint "Data kept in docker volume $(volume_name "$name" "$p"). Re-add the path to use it again."
      fi ;;
    *) volume_usage; return 1 ;;
  esac
}

# ---------- release command / build env ----------
cmd_release() {
  app_require_arg "${1-}" release; require_root release; require_setup
  app_load_locked "$1"
  local name=$1
  shift
  if (($# == 0)); then
    if [[ -n $A_RELEASE ]]; then info "Release command for $name: ${C_ACCENT2}$A_RELEASE${C_RESET}"
    else info "No release command for $name."
    fi
    hint "Runs in the new image before it gets traffic; a failure stops the deploy."
    hint "Set: fawwk release $name \"npm run migrate\"   $G_SEP   clear: fawwk release $name off"
    return 0
  fi
  local cmd="$*"
  [[ $cmd == off || $cmd == none ]] && cmd=''
  app_set A_RELEASE "$cmd"
  if [[ -n $cmd ]]; then ok "Release command: $cmd (runs on every deploy, before traffic switches)"
  else ok "Release command removed"
  fi
}

cmd_buildenv() {
  app_require_arg "${1-}" buildenv; require_root buildenv; require_setup
  app_load_locked "$1"
  local name=$1 v=${2-} k
  if [[ -z $v ]]; then
    info "Env vars passed to the build for $name: ${A_BUILD_ENV:-all}"
    hint "Build-time vars end up in the image. Limit them: fawwk buildenv $name NEXT_PUBLIC_API_URL,NODE_ENV"
    hint "Or: fawwk buildenv $name none | all"
    return 0
  fi
  if [[ $v != all && $v != none ]]; then
    local keys=()
    read -ra keys <<<"${v//,/ }"
    for k in "${keys[@]}"; do [[ $k =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "Not a variable name: $k"; done
    v=$(printf '%s\n' "${keys[@]}" | sort -u | paste -sd, -)
  fi
  app_set A_BUILD_ENV "$([[ $v == all ]] || printf '%s' "$v")"
  ok "Build-time env for $name: $v (all variables are still available at runtime)"
  hint "Applies from the next deploy."
}

# ---------- cron jobs ----------
# Jobs live in $APPS_ETC/<app>/cron as "id<TAB>schedule<TAB>command" and run inside the live container
# via /etc/cron.d/fawwk-<app>, which only references job ids (no quoting or % pitfalls in crontab).
cron_usage() {
  cat <<'EOF'
Usage: sudo fawwk cron <app> [command]

  (none) | list                     Scheduled jobs
  add "<schedule>" <command...>     Run a command in the app's container on a schedule
  rm <id>                           Remove a job
  run <id>                          Run a job now

Schedules use cron syntax ("*/5 * * * *", "0 3 * * *") or @hourly, @daily, @weekly, @monthly.
Times are the server's time zone. Output goes to /var/log/fawwk/<app>-cron.log.
EOF
}

cron_file() { printf '%s/cron' "$(app_dir "$A_NAME")"; }

# Rewrites /etc/cron.d/fawwk-<app> from the app's job list.
cron_render() {
  local f out="$CRON_DIR/fawwk-$A_NAME" id sched cmd
  f=$(cron_file)
  if [[ ! -s $f ]]; then rm -f "$out"; return 0; fi
  {
    printf '# Generated by fawwk for %s. Edit with: fawwk cron %s\n' "$A_NAME" "$A_NAME"
    printf 'SHELL=/bin/sh\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n'
    while IFS=$'\t' read -r id sched cmd; do
      [[ -n $id ]] || continue
      printf '%s root %s cron-run %s %s >>%s/%s-cron.log 2>&1\n' "$sched" "$FAWWK_HOME/bin/fawwk" "$A_NAME" "$id" "$FAWWK_LOG" "$A_NAME"
    done <"$f"
  } >"$out.tmp"
  chmod 644 "$out.tmp"
  mv -f "$out.tmp" "$out"
}

valid_cron_schedule() {
  local s=$1 f fields=()
  [[ $s =~ ^@(hourly|daily|weekly|monthly|yearly|annually|midnight)$ ]] && return 0
  read -ra fields <<<"$s"   # not `for f in $s`: each * would expand to file names
  ((${#fields[@]} == 5)) || return 1
  for f in "${fields[@]}"; do [[ $f =~ ^[0-9A-Za-z*/,-]+$ ]] || return 1; done
  return 0
}

cmd_cron() {
  local name=${1-} sub=${2:-list}
  [[ -z $name || $name == -h || $name == --help ]] && { cron_usage; return 0; }
  require_root cron; require_setup
  app_load_locked "$name"
  shift 2 || shift $#
  local f id sched cmd next
  f=$(cron_file)
  case $sub in
    list | ls)
      [[ -s $f ]] || { info "No cron jobs for $name."; hint "Add one: fawwk cron $name add \"0 3 * * *\" npm run cleanup"; return 0; }
      printf '\n  %s%-4s %-18s %s%s\n' "$C_MUTED" ID SCHEDULE COMMAND "$C_RESET"
      while IFS=$'\t' read -r id sched cmd; do
        printf '  %s%-4s%s %-18s %s\n' "$C_ACCENT2" "$id" "$C_RESET" "$sched" "$cmd"
      done <"$f"
      printf '\n' ;;
    add)
      sched=${1-}; shift || true
      cmd="$*"
      valid_cron_schedule "$sched" || die "Not a cron schedule: '$sched' (e.g. \"*/5 * * * *\" or @daily)"
      [[ -n $cmd ]] || die "Usage: fawwk cron $name add \"<schedule>\" <command...>"
      [[ $cmd != *$'\t'* && $cmd != *$'\n'* ]] || die "The command can't contain tabs or newlines."
      command -v cron >/dev/null 2>&1 || [[ -x /usr/sbin/cron ]] || warn "cron isn't installed. Install it with: apt-get install cron"
      next=$(( $(cut -f1 "$f" 2>/dev/null | sort -n | tail -n1 || echo 0) + 1 ))
      printf '%s\t%s\t%s\n' "$next" "$sched" "$cmd" >>"$f"
      chmod 600 "$f"
      cron_render
      ok "Job $next: $sched $G_ARROW $cmd" ;;
    rm | remove)
      id=${1-}
      [[ $id =~ ^[0-9]+$ ]] && grep -q "^$id"$'\t' "$f" 2>/dev/null || die "No job $id. See: fawwk cron $name"
      awk -F'\t' -v id="$id" '$1 != id' "$f" >"$f.tmp" && mv -f "$f.tmp" "$f"
      cron_render
      ok "Removed job $id" ;;
    run)
      cmd_cron_run "$name" "${1-}" ;;
    *) cron_usage; return 1 ;;
  esac
}

# Called by cron: runs job ID of APP inside its live container (skipped if one is still running).
cmd_cron_run() {
  local name=${1-} id=${2-} sched cmd line
  require_root cron-run; require_setup
  app_load "$name"
  line=$(awk -F'\t' -v id="$id" '$1 == id' "$(cron_file)" 2>/dev/null)
  [[ -n $line ]] || die "No job $id for $name."
  IFS=$'\t' read -r id sched cmd <<<"$line"
  [[ $(app_live_state) == running ]] || { printf '[%s] job %s skipped: %s is not running\n' "$(ts)" "$id" "$name"; return 0; }
  exec 7>"/run/lock/fawwk-cron-$name-$id.lock"
  flock -n 7 || { printf '[%s] job %s skipped: the previous run is still going\n' "$(ts)" "$id"; return 0; }
  printf '[%s] job %s: %s\n' "$(ts)" "$id" "$cmd"
  local rc=0
  docker exec "$A_CONTAINER" sh -c "$cmd" || rc=$?
  printf '[%s] job %s finished (exit %s)\n' "$(ts)" "$id" "$rc"
  ((rc == 0)) && return 0
  notify failed "$name" "" "$G_ERR $name: cron job $id ($cmd) failed with exit $rc on $(hostname)"
  FAWWK_DIED=1   # the job failed, not fawwk: no "stopped unexpectedly" report
  exit "$rc"
}
