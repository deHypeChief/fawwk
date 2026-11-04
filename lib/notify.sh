#!/usr/bin/env bash
# fawwk — automated deploys (timer + webhooks) and notifications about them.
#
# NOTIFY_URL in fawwk.conf receives a JSON POST for automated deploys: failures by default, every
# deploy with NOTIFY_ON=all. The body works as-is with Slack and Discord incoming webhooks ("text"
# and "content") and carries structured fields for anything else.

notify_usage() {
  cat <<'EOF'
Usage: sudo fawwk notify [command]

  (none)               Show where notifications go
  <url> [--all]        Send automated-deploy failures (or, with --all, every deploy) to a webhook URL
  test                 Send a test message
  off                  Stop sending notifications

Works with Slack and Discord incoming webhooks, or any URL that accepts a JSON POST:
  {"text": "...", "content": "...", "app": "api", "status": "failed", "commit": "3f2a1bc...", "host": "..."}
EOF
}

# notify STATUS APP COMMIT MESSAGE — STATUS is ok|failed|test. Never fails the caller.
notify() {
  local status=$1 app=$2 commit=$3 msg=$4 body
  [[ -n ${NOTIFY_URL-} ]] || return 0
  [[ $status == ok && ${NOTIFY_ON:-fail} != all ]] && return 0
  command -v jq >/dev/null 2>&1 || return 0
  body=$(jq -nc --arg t "$msg" --arg app "$app" --arg s "$status" --arg c "$commit" --arg h "$(hostname)" \
    '{text: $t, content: $t, app: $app, status: $s, commit: $c, host: $h}')
  curl -fsS --max-time 10 -X POST -H 'Content-Type: application/json' -d "$body" "$NOTIFY_URL" >/dev/null 2>&1 || true
}

# auto_deploy NAME COMMIT LOGNAME — an unattended deploy of NAME for COMMIT (skipped if the app is
# already there once it holds the lock), logged to $FAWWK_LOG/LOGNAME, with a notification.
auto_deploy() {
  local name=$1 sha=$2 logname=$3 rc=0
  line() { printf '[%s] %s\n' "$(ts)" "$1" | tee -a "$FAWWK_LOG/$logname" >&2; }
  line "$name: deploying ${sha:0:7}"
  (
    deploy_app "$name" "$sha" || exit 1
    ((DEPLOY_SKIPPED)) && exit 3
    exit 0
  ) >>"$FAWWK_LOG/$name.log" 2>&1 || rc=$?
  case $rc in
    0) line "$name: deployed ${sha:0:7}"
       notify ok "$name" "$sha" "$G_OK $name: deployed ${sha:0:7} on $(hostname)" ;;
    3) line "$name: already at ${sha:0:7}, skipped" ;;
    *) line "$name: deploy of ${sha:0:7} FAILED (see $FAWWK_LOG/$name.log)"
       notify failed "$name" "$sha" "$G_ERR $name: deploy of ${sha:0:7} failed on $(hostname). The previous version is still live. Details: fawwk logs $name --build" ;;
  esac
  unset -f line
  return 0
}

cmd_notify() {
  local sub=${1-}
  case $sub in -h | --help | help) notify_usage; return 0 ;; esac
  require_root notify; require_setup
  case $sub in
    '')
      if [[ -n ${NOTIFY_URL-} ]]; then
        info "Notifications go to ${C_ACCENT2}${NOTIFY_URL%%\?*}${C_RESET} (${NOTIFY_ON:-fail}: $([[ ${NOTIFY_ON:-fail} == all ]] && echo 'every automated deploy' || echo 'failed automated deploys'))"
      else
        info "Notifications are off."
        hint "Turn them on with: fawwk notify <webhook-url> [--all]"
      fi ;;
    off | none)
      conf_set "$FAWWK_CONF" NOTIFY_URL ''
      ok "Notifications off" ;;
    test)
      [[ -n ${NOTIFY_URL-} ]] || die "No notification URL set. Use: fawwk notify <url>"
      NOTIFY_ON=all notify test fawwk '' "Test from Fawwk on $(hostname): notifications work."
      ok "Test message sent (check the channel)" ;;
    http://* | https://*)
      conf_set "$FAWWK_CONF" NOTIFY_URL "$sub"
      if [[ ${2-} == --all ]]; then conf_set "$FAWWK_CONF" NOTIFY_ON all; else conf_set "$FAWWK_CONF" NOTIFY_ON fail; fi
      NOTIFY_URL=$sub
      NOTIFY_ON=all notify test fawwk '' "Fawwk on $(hostname) will notify you here about automated deploys."
      ok "Notifications on. A test message was sent." ;;
    *) notify_usage; return 1 ;;
  esac
}
