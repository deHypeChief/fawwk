#!/usr/bin/env bash
# fawwk — automated deploys (timer + webhooks) and notifications about them.
#
# Notifications go to every channel set up in fawwk.conf, for failed automated deploys and cron jobs
# (every deploy with NOTIFY_ON=all), and new Fawwk versions:
#   NOTIFY_URL                         a JSON POST; works as-is with Slack and Discord incoming webhooks
#                                      ("text" and "content") and carries structured fields for anything else
#   NOTIFY_TELEGRAM_TOKEN / _CHAT      a Telegram bot and the chat it writes to

notify_usage() {
  cat <<'EOF'
Usage: sudo fawwk notify [command]

  (none)                            Show where notifications go
  <url> [--all]                     A webhook URL: Slack, Discord, or anything taking a JSON POST
  telegram <bot-token> [chat-id]    A Telegram bot. Without a chat id, Fawwk finds the chat you
                                    last messaged the bot from (send it any message first)
  telegram off                      Stop Telegram messages
  all | failures                    Every automated deploy, or only failures (the default)
  test                              Send a test message to every channel
  off                               Stop all notifications

What's sent: failed automated deploys (every one with "all"), failed cron jobs, failed nightly
database backups, and new Fawwk versions. Webhooks get a JSON body:
  {"text": "...", "content": "...", "app": "api", "status": "failed", "commit": "3f2a1bc...", "host": "..."}

Telegram: create a bot by messaging @BotFather in Telegram (/newbot), copy the token it gives you,
send your new bot any message, then run: sudo fawwk notify telegram <token>
EOF
}

# notify STATUS APP COMMIT MESSAGE — STATUS is ok|failed|test|update. Never fails the caller.
notify() {
  local status=$1 app=$2 commit=$3 msg=$4 body
  [[ $status == ok && ${NOTIFY_ON:-fail} != all ]] && return 0
  if [[ -n ${NOTIFY_URL-} ]] && command -v jq >/dev/null 2>&1; then
    body=$(jq -nc --arg t "$msg" --arg app "$app" --arg s "$status" --arg c "$commit" --arg h "$(hostname)" \
      '{text: $t, content: $t, app: $app, status: $s, commit: $c, host: $h}')
    curl -fsS --max-time 10 -X POST -H 'Content-Type: application/json' -d "$body" "$NOTIFY_URL" >/dev/null 2>&1 || true
  fi
  if [[ -n ${NOTIFY_TELEGRAM_TOKEN-} && -n ${NOTIFY_TELEGRAM_CHAT-} ]]; then
    telegram_api "$NOTIFY_TELEGRAM_TOKEN" sendMessage --data-urlencode "chat_id=$NOTIFY_TELEGRAM_CHAT" \
      --data-urlencode "text=$msg" --data-urlencode "disable_web_page_preview=true" >/dev/null 2>&1 || true
  fi
  return 0
}

# telegram_api TOKEN METHOD [curl args...] — calls the Telegram Bot API, printing its JSON answer. The
# token is part of the URL, so it's handed to curl on stdin (-K -), never as an argument `ps` would show.
telegram_api() {
  local token=$1 method=$2
  shift 2
  printf 'url = "%s/bot%s/%s"\n' "${FAWWK_TELEGRAM_API:-https://api.telegram.org}" "$token" "$method" |
    curl -fsS --max-time 15 -K - "$@"
}

RE_TELEGRAM_TOKEN='^[0-9]{5,}:[A-Za-z0-9_-]{30,}$'

# notify_telegram_setup TOKEN [CHAT] — checks the bot, finds the chat when none is given, saves both.
notify_telegram_setup() {
  local token=$1 chat=${2-} me bot updates
  [[ $token =~ $RE_TELEGRAM_TOKEN ]] || die "That doesn't look like a bot token (like 123456789:AAF...). Get one from @BotFather in Telegram."
  me=$(telegram_api "$token" getMe 2>/dev/null) || die "Telegram didn't accept that token. Check it with @BotFather (/mybots)."
  bot=$(jq -r '.result.username // empty' <<<"$me")
  if [[ -z $chat ]]; then
    updates=$(telegram_api "$token" getUpdates 2>/dev/null || true)
    chat=$(jq -r '[.result[]? | (.message // .channel_post // .my_chat_member // .edited_message).chat.id // empty] | last // empty' <<<"$updates" 2>/dev/null)
    [[ -n $chat ]] || die "No chat found yet. Open https://t.me/${bot:-your_bot} in Telegram, send it any message (or add it to a group and say hi), then run this again."
  fi
  [[ $chat =~ ^-?[0-9]+$ || $chat =~ ^@[A-Za-z0-9_]{5,}$ ]] || die "Not a Telegram chat id: $chat"
  conf_set "$FAWWK_CONF" NOTIFY_TELEGRAM_TOKEN "$token"
  conf_set "$FAWWK_CONF" NOTIFY_TELEGRAM_CHAT "$chat"
  NOTIFY_TELEGRAM_TOKEN=$token NOTIFY_TELEGRAM_CHAT=$chat
  ok "Telegram notifications on, through @${bot:-your bot} to chat $chat"
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
  local any=0
  case $sub in
    '')
      [[ -n ${NOTIFY_URL-} ]] && { any=1; info "Webhook: ${C_ACCENT2}${NOTIFY_URL%%\?*}${C_RESET}"; }
      [[ -n ${NOTIFY_TELEGRAM_TOKEN-} && -n ${NOTIFY_TELEGRAM_CHAT-} ]] && { any=1; info "Telegram: chat ${C_ACCENT2}$NOTIFY_TELEGRAM_CHAT${C_RESET}"; }
      if ((any)); then
        hint "Sent: $([[ ${NOTIFY_ON:-fail} == all ]] && echo 'every automated deploy' || echo 'failed automated deploys'), failed cron jobs and backups, new Fawwk versions"
      else
        info "Notifications are off."
        hint "Turn them on: fawwk notify <webhook-url>   or   fawwk notify telegram <bot-token>"
      fi ;;
    off | none)
      conf_set "$FAWWK_CONF" NOTIFY_URL ''
      conf_set "$FAWWK_CONF" NOTIFY_TELEGRAM_TOKEN ''; conf_set "$FAWWK_CONF" NOTIFY_TELEGRAM_CHAT ''
      ok "Notifications off" ;;
    all | failures)
      conf_set "$FAWWK_CONF" NOTIFY_ON "$([[ $sub == all ]] && echo all || echo fail)"
      ok "Notifications: $([[ $sub == all ]] && echo 'every automated deploy' || echo 'failed automated deploys only')" ;;
    test)
      [[ -n ${NOTIFY_URL-} || -n ${NOTIFY_TELEGRAM_CHAT-} ]] || die "No notifications set up. See: fawwk notify --help"
      notify test fawwk '' "Test from Fawwk on $(hostname): notifications work."
      ok "Test message sent to every channel (check them)" ;;
    telegram)
      gh_need_jq >/dev/null
      if [[ ${2-} == off ]]; then
        conf_set "$FAWWK_CONF" NOTIFY_TELEGRAM_TOKEN ''; conf_set "$FAWWK_CONF" NOTIFY_TELEGRAM_CHAT ''
        ok "Telegram notifications off"; return 0
      fi
      local targs=() a all=0
      for a in "${@:2}"; do if [[ $a == --all ]]; then all=1; else targs+=("$a"); fi; done
      ((${#targs[@]})) || { notify_usage; return 1; }
      notify_telegram_setup "${targs[0]}" "${targs[1]-}"
      ((all)) && conf_set "$FAWWK_CONF" NOTIFY_ON all
      NOTIFY_URL='' notify test fawwk '' "Fawwk on $(hostname) will notify you here about deploys and updates."
      ok "A test message was sent: check Telegram." ;;
    http://* | https://*)
      conf_set "$FAWWK_CONF" NOTIFY_URL "$sub"
      if [[ ${2-} == --all ]]; then conf_set "$FAWWK_CONF" NOTIFY_ON all; else conf_set "$FAWWK_CONF" NOTIFY_ON fail; fi
      NOTIFY_URL=$sub
      NOTIFY_TELEGRAM_CHAT='' notify test fawwk '' "Fawwk on $(hostname) will notify you here about automated deploys."
      ok "Notifications on. A test message was sent." ;;
    *) notify_usage; return 1 ;;
  esac
}
