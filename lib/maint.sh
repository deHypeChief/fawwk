#!/usr/bin/env bash
# fawwk — server maintenance: cleanup, backup/restore, uninstall.

# ---------- cleanup ----------
cmd_cleanup() {
  [[ ${1-} == -h || ${1-} == --help ]] && { echo "Usage: sudo fawwk cleanup   Free disk space without touching rollback images or data"; return 0; }
  require_root cleanup; require_setup
  local before after name
  before=$(df -Pm / | awk 'NR == 2 {print $4}')
  step "Cleaning up"
  while IFS= read -r name; do
    [[ -z $name ]] && continue
    (
      LOCK_NOWAIT=1
      app_load_locked "$name"
      images_prune
      deploy_cleanup
    ) || true
  done < <(app_names)
  ok "Old images (beyond the last $KEEP_IMAGES per app) and build logs (beyond $KEEP_LOGS) removed"
  docker image prune -f >/dev/null 2>&1 || true
  docker builder prune -af >/dev/null 2>&1 || true
  ok "Untagged images and the whole build cache removed (the next build of each app is slower)"
  find "$FAWWK_LOG" -name '*.log.*.gz' -mtime +60 -delete 2>/dev/null || true
  after=$(df -Pm / | awk 'NR == 2 {print $4}')
  ok "Freed $(( (after - before) > 0 ? after - before : 0 ))MB ${C_MUTED}($(df -Ph / | awk 'NR == 2 {print $4}') free)${C_RESET}"
}

# ---------- backup / restore ----------
backup_usage() {
  cat <<'EOF'
Usage: sudo fawwk backup [file] [--with-data]

Saves everything needed to rebuild this server's apps on a new one: server settings, every app's
config, env vars, deploy keys and tokens, GitHub connections, cron jobs and HTTPS certificates.
With --with-data, app volumes are included too (stop busy databases first for a consistent copy).

The file contains secrets. Keep it somewhere safe. Restore on a new server with: fawwk restore <file>
EOF
}

docker_volumes_dir() { printf '%s/volumes' "$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"; }

cmd_backup() {
  local out='' data=0 a
  for a in "$@"; do
    case $a in
      -h | --help) backup_usage; return 0 ;;
      --with-data) data=1 ;;
      -*) die "Unknown option: $a (see: fawwk backup --help)" ;;
      *) out=$a ;;
    esac
  done
  require_root backup; require_setup
  out=${out:-$PWD/fawwk-backup-$(hostname -s)-$(date +%Y%m%d-%H%M%S).tar.gz}
  local vdir paths=() vols=() name v
  vdir=$(docker_volumes_dir)
  paths+=("${FAWWK_ETC#/}")
  [[ -d $FAWWK_VAR/hooks/secrets ]] && paths+=("${FAWWK_VAR#/}/hooks/secrets")
  for a in "$CRON_DIR"/fawwk-*; do [[ -f $a ]] && paths+=("${a#/}"); done
  [[ -d $vdir/fawwk_caddy_data/_data ]] && vols+=(fawwk_caddy_data/_data)
  if ((data)); then
    while IFS= read -r name; do
      [[ -z $name ]] && continue
      app_load "$name"
      for v in $A_VOLUMES; do
        v=$(volume_name "$name" "$v")
        [[ -d $vdir/$v/_data ]] && vols+=("$v/_data")
      done
    done < <(app_names)
  fi
  local targs=(-czf "$out" -C / "${paths[@]}")
  ((${#vols[@]})) && targs+=(-C "$vdir" "${vols[@]}")
  step "Backing up to $out"
  (umask 077; tar "${targs[@]}") || die "Backup failed."
  ok "Saved $(du -h "$out" | cut -f1): $(app_names | wc -l) app(s)$( ((data)) && echo ', with volume data')"
  hint "It contains secrets (env vars, keys). Copy it off this server, e.g. scp root@server:$out ."
}

cmd_restore() {
  local file=${1-} force=0
  [[ $file == -h || $file == --help || -z $file ]] && {
    echo "Usage: sudo fawwk restore <backup.tar.gz> [--force]   Restore a 'fawwk backup' on this server"; return 0; }
  [[ ${2-} == --force ]] && force=1
  require_root restore
  [[ -f $file ]] || die "File not found: $file"
  [[ -n $(app_names) && $force == 0 ]] && die "This server already has apps. Add --force to overwrite their config."
  local tmp vdir d name
  tmp=$(mktemp -d)
  step "Restoring $file"
  tar -xzf "$file" -C "$tmp" || { rm -rf "$tmp"; die "Couldn't read the backup."; }
  [[ -f $tmp/${FAWWK_CONF#/} ]] || { rm -rf "$tmp"; die "That isn't a fawwk backup (no ${FAWWK_CONF#/})."; }
  mkdir -p "$FAWWK_ETC" "$FAWWK_VAR/hooks"
  cp -a "$tmp/${FAWWK_ETC#/}/." "$FAWWK_ETC/"
  chmod 700 "$FAWWK_ETC"
  [[ -d $tmp/${FAWWK_VAR#/}/hooks/secrets ]] && { mkdir -p "$FAWWK_VAR/hooks/secrets"; cp -a "$tmp/${FAWWK_VAR#/}/hooks/secrets/." "$FAWWK_VAR/hooks/secrets/"; }
  [[ -d $tmp/${CRON_DIR#/} ]] && { mkdir -p "$CRON_DIR"; cp -a "$tmp/${CRON_DIR#/}/." "$CRON_DIR/"; }
  ok "Restored server settings and $(app_names | wc -l) app(s)"
  # Containers and images from the old server don't exist here: every app starts as "new".
  while IFS= read -r name; do
    [[ -z $name ]] && continue
    conf_set "$APPS_ETC/$name/app.conf" A_STATE new
    for d in A_CONTAINER A_IMAGE A_COMMIT A_FAILED_COMMIT; do conf_set "$APPS_ETC/$name/app.conf" "$d" ''; done
    rm -f "$APPS_ETC/$name/history"
  done < <(app_names)
  if compgen -G "$tmp/fawwk_*" >/dev/null && ! docker info >/dev/null 2>&1; then
    setup_docker   # volumes and certificates go into Docker volumes
  fi
  if compgen -G "$tmp/fawwk_*" >/dev/null; then
    vdir=$(docker_volumes_dir)
    for d in "$tmp"/fawwk_*/_data; do
      [[ -d $d ]] || continue
      name=${d%/_data}; name=${name##*/}
      docker volume create "$name" >/dev/null
      cp -a "$d/." "$vdir/$name/_data/"
      ok "Restored volume $name"
    done
  fi
  rm -rf "$tmp"
  # shellcheck disable=SC1090
  source "$FAWWK_CONF"
  printf '\n' >&2
  ui_box --title "Restored" "Next:" "" \
    "  1. ${C_ACCENT}sudo fawwk setup --yes${C_RESET}       installs Docker, the proxy, timers" \
    "  2. Point DNS for $DOMAIN (and *.$DOMAIN) to this server" \
    "  3. ${C_ACCENT}sudo fawwk deploy --all${C_RESET}      builds and starts every app"
  UI_IN_STEP=0
}

# ---------- uninstall ----------
cmd_uninstall() {
  local data=0 yes=0 a
  for a in "$@"; do
    case $a in
      --delete-data) data=1 ;;
      -y | --yes) yes=1 ;;
      -h | --help) echo "Usage: sudo fawwk uninstall [--delete-data] [--yes]   Remove Fawwk, its apps and settings (Docker stays)"; return 0 ;;
      *) die "Unknown option: $a" ;;
    esac
  done
  require_root uninstall
  warn "This removes every Fawwk app (containers, images, env vars, keys), the proxy, the webhook"
  warn "receiver, timers and all Fawwk settings. Docker, UFW and fail2ban stay installed."
  ((data)) && warn "--delete-data: app volumes and HTTPS certificates are deleted too." ||
    info "App volumes and HTTPS certificates are kept (docker volume ls | grep fawwk_)."
  if ((yes == 0)); then
    is_interactive || die "Add --yes to uninstall without a prompt."
    local typed
    read -r -p "  ${C_RED}${G_PROMPT}${C_RESET} Type ${C_BOLD}uninstall${C_RESET} to confirm: " typed
    [[ $typed == uninstall ]] || die "Cancelled."
  fi
  step "Uninstalling Fawwk"
  systemctl disable --now fawwk-autodeploy.timer fawwk-hooks.path >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/fawwk-autodeploy.{service,timer} /etc/systemd/system/fawwk-hooks.{service,path}
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -f "$CRON_DIR"/fawwk-* /etc/logrotate.d/fawwk
  ok "Timers, webhook watcher and cron jobs removed"
  if command -v docker >/dev/null 2>&1; then
    docker ps -aq --filter label=fawwk.app | xargs -r docker rm -f >/dev/null 2>&1 || true
    docker rm -f "$FAWWK_PROXY" fawwk-hooks >/dev/null 2>&1 || true
    docker images --format '{{.Repository}}:{{.Tag}}' | grep '^fawwk/' | xargs -r docker rmi -f >/dev/null 2>&1 || true
    docker network rm "$FAWWK_NETWORK" >/dev/null 2>&1 || true
    if ((data)); then
      docker volume ls -q | grep '^fawwk_' | xargs -r docker volume rm >/dev/null 2>&1 || true
    fi
    ok "Containers, images and network removed"
  fi
  rm -rf "${FAWWK_ETC:?}" "${FAWWK_VAR:?}" "${FAWWK_LOG:?}"
  ok "Settings and data removed"
  [[ -L /usr/local/bin/fawwk ]] && rm -f /usr/local/bin/fawwk
  if [[ $FAWWK_HOME == /opt/fawwk && -d /opt/fawwk/bin ]]; then rm -rf /opt/fawwk; fi
  ok "Fawwk is uninstalled"
}
