#!/usr/bin/env bash
# fawwk — `fawwk doctor`: check that the server and every app are healthy.

cmd_doctor() {
  require_root doctor
  local problems=0 name r disk mem
  step "Server"
  if [[ -f $FAWWK_CONF ]]; then
    # shellcheck disable=SC1090
    source "$FAWWK_CONF"
    ok "Configured for $DOMAIN (setup on $SETUP_AT)"
  else
    err "Not set up. Run: sudo fawwk setup"; return 1
  fi
  local ip
  ip=$(server_ip)
  if [[ -n $ip && $ip != "$SERVER_IP" ]]; then
    warn "Public IP changed: $SERVER_IP → $ip (updating)"
    conf_set "$FAWWK_CONF" SERVER_IP "$ip"; SERVER_IP=$ip
  fi
  if docker info >/dev/null 2>&1; then ok "Docker is running"; else err "Docker isn't running: systemctl start docker"; problems=$((problems + 1)); fi
  if proxy_running; then ok "Caddy proxy is running"; else err "Caddy proxy is down: fawwk proxy reload"; problems=$((problems + 1)); fi
  if systemctl is-active --quiet fawwk-autodeploy.timer; then ok "Auto-deploy timer is active"; else warn "Auto-deploy timer is off: systemctl enable --now fawwk-autodeploy.timer"; fi
  command -v nixpacks >/dev/null 2>&1 && ok "Nixpacks installed" || warn "Nixpacks missing (only needed for repos without a Dockerfile)"
  if ufw status 2>/dev/null | grep -q 'Status: active'; then ok "Firewall active"; else warn "Firewall (ufw) is inactive"; fi

  disk=$(df -P / | awk 'NR == 2 {gsub("%", "", $5); print $5}' || true)
  if ((disk >= 90)); then err "Disk ${disk}% full. Free space: docker system prune -a"; problems=$((problems + 1))
  elif ((disk >= 75)); then warn "Disk ${disk}% full"
  else ok "Disk ${disk}% used"; fi
  mem=$(free -m | awk '/^Mem:/ {printf "%d/%dMB", $3, $2}' || true)
  ok "Memory $mem used"

  step "DNS"
  dns_report "$DOMAIN"
  dns_report "fawwk-check-$RANDOM.$DOMAIN"

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
    for r in $A_ROUTES; do
      [[ ${r%%/*} == *".$DOMAIN" || ${r%%/*} == "$DOMAIN" ]] && continue
      dns_report "${r%%/*}"
    done
  done < <(app_names)
  ((n)) || info "No apps yet."

  printf '\n' >&2
  UI_IN_STEP=0
  if ((problems)); then err "$problems problem(s) found"; return 1; fi
  ok "Everything looks good"
}
