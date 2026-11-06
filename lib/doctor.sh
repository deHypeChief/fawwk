#!/usr/bin/env bash
# fawwk — `fawwk doctor`: check that the server and every app are healthy.

cmd_doctor() {
  require_root doctor
  local problems=0 name r disk mem
  step "Server"
  if [[ -f $FAWWK_CONF ]]; then
    # shellcheck disable=SC1090
    source "$FAWWK_CONF"
    ok "Configured for $DOMAIN (setup on ${SETUP_AT:-unknown date})"
  else
    err "Not set up. Run: sudo fawwk setup"; return 1
  fi
  local ip
  ip=$(server_ip)
  if [[ -n $ip && $ip != "$SERVER_IP" ]]; then
    warn "Public IP changed: $SERVER_IP → $ip (updating)"
    conf_set "$FAWWK_CONF" SERVER_IP "$ip"; SERVER_IP=$ip
  fi
  if [[ ${UPDATE_CHECK:-on} != off ]] && update_check >/dev/null 2>&1; then
    local newer; newer=$(update_available)
    if [[ -n $newer ]]; then warn "Fawwk $newer is out (you have $FAWWK_VERSION): sudo fawwk update"
    else ok "Fawwk $FAWWK_VERSION is up to date"; fi
  fi
  if docker info >/dev/null 2>&1; then ok "Docker is running"; else err "Docker isn't running: systemctl start docker"; problems=$((problems + 1)); fi
  if proxy_running; then
    ok "Caddy proxy is running ($(proxy_image))"
    [[ $(proxy_image) == "$CADDY_IMAGE" ]] || hint "Fawwk now pins $CADDY_IMAGE. Switch with: sudo fawwk proxy upgrade"
  else err "Caddy proxy is down: fawwk proxy reload"; problems=$((problems + 1)); fi
  if systemctl is-active --quiet fawwk-autodeploy.timer; then ok "Auto-deploy timer is active"; else warn "Auto-deploy timer is off: systemctl enable --now fawwk-autodeploy.timer"; fi
  if command -v railpack >/dev/null 2>&1; then ok "Railpack $(railpack_version) installed"
  else warn "Railpack missing (builds repos without a Dockerfile): sudo fawwk setup"; fi
  command -v nixpacks >/dev/null 2>&1 && ok "Nixpacks installed (used by apps pinned to it)"
  if ufw status 2>/dev/null | grep -q 'Status: active'; then ok "Firewall active"; else warn "Firewall (ufw) is inactive"; fi
  [[ -f $LOGROTATE_DIR/fawwk ]] || warn "Fawwk's logs aren't rotated. Fix: sudo fawwk post-update"
  if [[ -n ${NOTIFY_URL-} ]]; then ok "Notifications on (${NOTIFY_ON:-fail})"
  else hint "You won't hear about failed auto-deploys. Turn on notifications: fawwk notify <webhook-url>"; fi

  disk=$(df -P / | awk 'NR == 2 {gsub("%", "", $5); print $5}' || true)
  # Not `docker system prune -a`: that deletes the images kept for rollback.
  if ((disk >= 90)); then err "Disk ${disk}% full. Free space: sudo fawwk cleanup"; problems=$((problems + 1))
  elif ((disk >= 75)); then warn "Disk ${disk}% full. Free space: sudo fawwk cleanup"
  else ok "Disk ${disk}% used"; fi
  mem=$(free -m | awk '/^Mem:/ {printf "%d/%dMB", $3, $2}' || true)
  ok "Memory $mem used"

  if hooks_enabled; then
    if [[ $(docker inspect -f '{{.State.Running}}' "$HOOKS_CONTAINER" 2>/dev/null) == true ]]; then ok "Webhook receiver is running"
    else err "Webhook receiver is down: sudo fawwk github connect (or docker start $HOOKS_CONTAINER)"; problems=$((problems + 1)); fi
    systemctl is-active --quiet fawwk-hooks.path && ok "Webhook deploys are active" || warn "Webhook watcher is off: systemctl enable --now fawwk-hooks.path"
    local src queued
    while IFS= read -r src; do [[ -n $src ]] && ok "GitHub App: $src"; done < <(gh_sources)
    queued=$(find "$HOOKS_DIR/inbox" -name '*.json' -mmin +10 2>/dev/null | wc -l)
    ((queued == 0)) || { warn "$queued webhook job(s) waiting over 10 minutes. Check: journalctl -u fawwk-hooks.service"; }
  fi

  step "DNS"
  dns_report "$DOMAIN"
  hooks_enabled && dns_report "$PANEL_HOST"
  dns_report "fawwk-check-$RANDOM.$DOMAIN"

  if [[ -n $(db_names) ]]; then
    step "Databases"
    local db last age
    while IFS= read -r db; do
      [[ -z $db ]] && continue
      db_load "$db"
      if [[ $D_TYPE == mongodb ]] && mongo_refuses_kernel "$D_IMAGE"; then
        err "$db: MongoDB $D_VERSION refuses to run on this kernel ($(kernel_version)). Back it up, then move it to --version 7.0 (see: fawwk db --help)"
        problems=$((problems + 1))
      fi
      if [[ $(db_state) == running ]] && db_ready; then ok "$db ($(db_label "$D_TYPE") $D_VERSION) is running"
      else err "$db isn't answering ($(db_state)). Try: fawwk db restart $db, then: fawwk db logs $db"; problems=$((problems + 1)); fi
      last=$(db_latest_backup "$db")
      if [[ -z $last ]]; then warn "$db has never been backed up: fawwk db backup $db"
      else
        age=$(( ($(date +%s) - $(date -r "$last" +%s)) / 3600 ))
        if ((age > 48)) && [[ ${DB_BACKUP_AT:-03:17} != off ]]; then warn "$db's last backup is ${age}h old. Check: journalctl -u fawwk-db-backup.service"
        else ok "$db last backed up ${age}h ago"; fi
      fi
    done < <(db_names)
    [[ ${DB_BACKUP_AT:-03:17} == off ]] && warn "Daily database backups are off: fawwk db schedule 03:17"
  fi
  doctor_s3

  step "Apps"
  local n=0 state
  while IFS= read -r name; do
    [[ -z $name ]] && continue
    n=$((n + 1))
    app_load "$name"
    state=$(app_live_state)
    case $state in
      running) ok "$name is running (${A_COMMIT:0:7})" ;;
      stopped | new) info "$name is $state" ;;
      *) err "$name: container is $state. Try: fawwk restart $name"; problems=$((problems + 1)) ;;
    esac
    [[ -n $A_FAILED_COMMIT ]] && warn "$name: last deploy of ${A_FAILED_COMMIT:0:7} failed (fawwk logs $name --build)"
    [[ $state == running && -n $A_MEMORY ]] &&
      [[ $(docker inspect -f '{{.State.OOMKilled}}' "$A_CONTAINER" 2>/dev/null) == true ]] &&
      warn "$name was killed for using too much memory (limit $A_MEMORY): fawwk limits $name memory=<more>"
    for r in $A_ROUTES; do
      [[ ${r%%/*} == *".$DOMAIN" || ${r%%/*} == "$DOMAIN" ]] && continue
      dns_report "${r%%/*}"
    done
  done < <(app_names)
  ((n)) || info "No apps yet."

  printf '\n' >&2
  UI_IN_STEP=0
  if ((problems)); then err "$problems problem(s) found"; FAWWK_DIED=1; exit 1; fi
  if ((UI_WARNINGS)); then warn "No problems, but $UI_WARNINGS warning(s) above"
  else ok "Everything looks good"; fi
}

# Copies of the backups in a bucket (fawwk backup s3).
doctor_s3() {
  if ! s3_enabled; then
    [[ -n $(db_names) ]] && info "Backups are only on this server. Keep copies in S3 / R2: fawwk backup s3 setup"
    return 0
  fi
  step "Backups in $(s3_provider_label "$S3_PROVIDER")"
  command -v rclone >/dev/null 2>&1 || { warn "rclone is missing, so nothing is uploaded: apt-get install rclone"; return 0; }
  s3_status_load
  if [[ -n $S3_LAST_ERROR ]]; then
    warn "Last upload failed ($(s3_ago "${S3_LAST_ERROR_AT:-0}")): $S3_LAST_ERROR. Check: fawwk backup s3 test"
  fi
  if [[ -z $S3_LAST_OK ]]; then
    warn "Nothing uploaded to $S3_BUCKET yet. Now: fawwk backup s3 push"
  elif (($(date +%s) - S3_LAST_OK > 48 * 3600)); then
    warn "The last upload to $S3_BUCKET was $(s3_ago "$S3_LAST_OK"). Check: fawwk backup s3 test"
  else
    ok "Uploaded to $S3_BUCKET $(s3_ago "$S3_LAST_OK") ($S3_LAST_SUMMARY)"
  fi
}
