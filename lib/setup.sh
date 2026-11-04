#!/usr/bin/env bash
# fawwk — one-time server setup (safe to re-run).

setup_usage() {
  cat <<'EOF'
Usage: sudo fawwk setup [options]

Prepares a fresh Ubuntu server: Docker, Caddy (HTTPS proxy), firewall, fail2ban,
Nixpacks, swap for small servers, and the auto-deploy timer.

Options:
  --domain <domain>     Main domain. Apps get <app>.<domain> by default
  --email <email>       Email for Let's Encrypt certificates
  --panel <subdomain>   Subdomain reserved for the web panel (default: panel)
  --no-firewall         Don't touch UFW
  --no-swap             Don't create a swap file
  -y, --yes             Use the values given / defaults, don't prompt
EOF
}

cmd_setup() {
  local domain='' email='' panel='' firewall=1 swap=1 os_id os_name
  while (($#)); do
    case $1 in
      --domain) need_arg "$@"; domain=$2; shift 2 ;;
      --email) need_arg "$@"; email=$2; shift 2 ;;
      --panel) need_arg "$@"; panel=$2; shift 2 ;;
      --no-firewall) firewall=0; shift ;;
      --no-swap) swap=0; shift ;;
      -y | --yes) FAWWK_YES=1; shift ;;
      -h | --help) setup_usage; return 0 ;;
      *) die "Unknown option: $1 (see: fawwk setup --help)" ;;
    esac
  done
  require_root setup

  os_id=$(. /etc/os-release 2>/dev/null && echo "${ID-}")
  os_name=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME-unknown}")
  [[ $os_id == ubuntu ]] || warn "Fawwk is built for Ubuntu; this is $os_name. Continuing anyway."

  # Re-running setup keeps previous answers as defaults.
  local DOMAIN='' EMAIL='' PANEL_SUB='' PANEL_HOST='' old_panel
  # shellcheck disable=SC1090
  [[ -f $FAWWK_CONF ]] && source "$FAWWK_CONF"
  old_panel=$PANEL_HOST

  ui_banner "Server setup ${G_SEP} Docker, HTTPS proxy, firewall, auto-deploy"
  step "Server details"
  ask domain "Main domain (apps get <app>.<domain>)" "${domain:-$DOMAIN}" valid_domain
  domain=${domain,,}
  ask email "Email for HTTPS certificates (Let's Encrypt)" "${email:-$EMAIL}" valid_email
  ask panel "Subdomain for the web panel (reserved for later)" "${panel:-${PANEL_SUB:-panel}}" valid_subdomain_label

  step "Installing packages"
  export DEBIAN_FRONTEND=noninteractive
  spin_start "apt-get install base packages"
  apt-get update -q >/dev/null
  apt-get install -y -q ca-certificates cron curl git gnupg jq logrotate openssl ufw fail2ban openssh-client unattended-upgrades >/dev/null
  spin_stop
  ok "Base packages"

  setup_docker
  setup_nixpacks
  ((swap)) && setup_swap
  ((firewall)) && setup_firewall
  systemctl enable --now fail2ban >/dev/null 2>&1 && ok "fail2ban is protecting SSH" || warn "Couldn't start fail2ban"

  step "Saving configuration"
  mkdir -p "$FAWWK_ETC" "$APPS_ETC" "$APPS_VAR" "$FAWWK_LOG" "$CADDY_DIR/custom"
  chmod 700 "$FAWWK_ETC"
  local ip
  ip=$(server_ip)
  conf_set "$FAWWK_CONF" DOMAIN "$domain"
  conf_set "$FAWWK_CONF" EMAIL "$email"
  conf_set "$FAWWK_CONF" PANEL_SUB "$panel"
  conf_set "$FAWWK_CONF" PANEL_HOST "$panel.$domain"
  conf_set "$FAWWK_CONF" SERVER_IP "$ip"
  conf_set "$FAWWK_CONF" SETUP_AT "$(ts)"
  # shellcheck disable=SC1090
  source "$FAWWK_CONF"
  ok "Saved to $FAWWK_CONF"
  setup_logrotate && ok "Fawwk logs rotate weekly (8 weeks kept)"

  step "Starting the HTTPS proxy (Caddy)"
  proxy_ensure
  proxy_reload && ok "Caddy is running on ports 80 and 443"

  setup_timer
  if hooks_enabled; then
    step "GitHub webhooks"
    hooks_ensure
    [[ -n $old_panel && $old_panel != "$PANEL_HOST" ]] && gh_update_hook_urls
  fi

  step "DNS"
  info "Create these records with your DNS provider (both pointing to $ip):"
  printf '\n' >&2
  ui_box "$(printf '%s%-6s %-28s %s%s' "$C_MUTED" Type Name Value "$C_RESET")" \
    "$(printf '%-6s %-28s %s' A "$domain" "$ip")" \
    "$(printf '%-6s %-28s %s' A "*.$domain" "$ip")"
  printf '\n' >&2
  UI_IN_STEP=0
  hint "The wildcard record means every new app subdomain works without touching DNS again."
  dns_report "$domain"
  dns_report "fawwk-check-$RANDOM.$domain"

  printf '\n' >&2
  ui_box --title "Server is ready" \
    "Deploy your first app:" "" "  ${C_ACCENT}sudo fawwk create${C_RESET}" "" \
    "${C_MUTED}Check everything later with: fawwk doctor${C_RESET}"
  printf '\n' >&2
}

valid_subdomain_label() { [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || { warn "Use one label like 'panel' (letters, digits, dashes)."; return 1; }; }

setup_docker() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    ok "Docker $(docker version -f '{{.Server.Version}}' 2>/dev/null) already installed"
    return 0
  fi
  spin_start "Installing Docker from the official repository"
  local codename arch
  # Sensible daemon defaults on a fresh install: rotate every container's logs, and cap the build
  # cache so months of deploys don't fill the disk. An existing daemon.json is left alone.
  if [[ ! -f /etc/docker/daemon.json ]]; then
    mkdir -p /etc/docker
    cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "builder": { "gc": { "enabled": true, "defaultKeepStorage": "10GB" } }
}
EOF
  fi
  codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
  arch=$(dpkg --print-architecture)
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $codename stable" \
    >/etc/apt/sources.list.d/docker.list
  apt-get update -q >/dev/null
  apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
  systemctl enable --now docker >/dev/null 2>&1
  spin_stop
  docker info >/dev/null 2>&1 || die "Docker installed but isn't running. Check: systemctl status docker"
  ok "Docker $(docker version -f '{{.Server.Version}}') installed"
}

setup_nixpacks() {
  if command -v nixpacks >/dev/null 2>&1; then
    ok "Nixpacks already installed"
    return 0
  fi
  spin_start "Installing Nixpacks (builds repos that have no Dockerfile)"
  if curl -fsSL https://nixpacks.com/install.sh | bash >/dev/null 2>&1 && command -v nixpacks >/dev/null 2>&1; then
    spin_stop
    ok "Nixpacks installed"
  else
    spin_stop
    warn "Nixpacks couldn't be installed. Repos without a Dockerfile won't build until it is."
  fi
}

setup_swap() {
  local mem_mb
  mem_mb=$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo)
  if (($(swapon --noheadings 2>/dev/null | wc -l) > 0)); then
    ok "Swap already configured"
    return 0
  fi
  ((mem_mb < 3500)) || return 0
  info "Only ${mem_mb}MB RAM: adding a 2GB swap file so builds don't run out of memory..."
  if fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none; then
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null && swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
    ok "2GB swap enabled"
  else
    warn "Couldn't create a swap file"
  fi
}

# Every port SSH might be listening on, so enabling the firewall can never lock you out.
ssh_ports() {
  {
    # The port of the SSH session running this setup, if any.
    [[ -n ${SSH_CONNECTION-} ]] && awk '{print $4}' <<<"$SSH_CONNECTION"
    # sshd's effective config (fails on Ubuntu 24.04 when sshd is socket-activated, hence the fallbacks).
    sshd -T 2>/dev/null | awk '$1 == "port" {print $2}'
    # Port lines in the config files.
    cat /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk 'tolower($1) == "port" {print $2}'
    # Ports sshd is actually listening on right now.
    ss -Hltnp 2>/dev/null | awk '/"sshd"/ {n = split($4, a, ":"); print a[n]}'
    echo 22
  } 2>/dev/null | grep -E '^[0-9]+$' | sort -un || true
}

setup_firewall() {
  local p ports
  ports=$(ssh_ports | tr '\n' ' ')
  for p in $ports; do ufw allow "$p/tcp" comment 'ssh' >/dev/null; done
  ufw allow 80/tcp comment 'http' >/dev/null
  ufw allow 443/tcp comment 'https' >/dev/null
  ufw allow 443/udp comment 'http3' >/dev/null
  ufw --force enable >/dev/null
  ok "Firewall on: SSH (${ports% }), HTTP (80), HTTPS (443) open; everything else closed"
}

# Rotates Fawwk's own logs (sync.log, hooks.log, <app>.log, <app>-cron.log).
setup_logrotate() {
  [[ -d $LOGROTATE_DIR ]] || return 1
  cat >"$LOGROTATE_DIR/fawwk" <<EOF
$FAWWK_LOG/*.log {
	weekly
	rotate 8
	compress
	delaycompress
	missingok
	notifempty
	copytruncate
}
EOF
}

setup_timer() {
  step "Auto-deploy timer"
  cat >/etc/systemd/system/fawwk-autodeploy.service <<EOF
[Unit]
Description=Fawwk auto-deploy: redeploy apps that have new commits
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$FAWWK_HOME/bin/fawwk sync --quiet
EOF
  cat >/etc/systemd/system/fawwk-autodeploy.timer <<'EOF'
[Unit]
Description=Check git repos for new commits every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now fawwk-autodeploy.timer >/dev/null 2>&1
  ok "Checks for new commits every minute (apps with auto-deploy on)"
}
