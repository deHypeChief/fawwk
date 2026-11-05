#!/usr/bin/env bash
# fawwk — knowing when a new Fawwk version is out.
#
# Once a day the auto-deploy timer fetches Fawwk's branch (into refs/fawwk/latest, leaving the install
# alone) and reads its FAWWK_VERSION. The answer is cached in $FAWWK_VAR/update-check, so commands can
# show a one-line notice without touching the network. Only new *versions* count, not every commit,
# and each one is sent once through `fawwk notify`. Nothing updates by itself: `sudo fawwk update`.
# UPDATE_CHECK=off in fawwk.conf turns the daily check off.

UPDATE_FILE="$FAWWK_VAR/update-check"
UPDATE_EVERY="${UPDATE_EVERY:-86400}"   # seconds between automatic checks

# version_gt A B — 0 when version A is newer than B (0.10.0 > 0.9.2).
version_gt() { [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1) == "$1" ]]; }

update_load() {
  UC_CHECKED='' UC_LATEST='' UC_BRANCH='' UC_NOTIFIED=''
  # shellcheck disable=SC1090
  [[ -r $UPDATE_FILE ]] && source "$UPDATE_FILE" 2>/dev/null
  return 0
}

# The page about a version, when Fawwk comes from GitHub.
update_release_url() {
  local u
  u=$(git -C "$FAWWK_HOME" remote get-url origin 2>/dev/null) || return 0
  u=${u%.git}
  [[ $u =~ github\.com[:/]([^/]+/[^/]+)$ ]] && printf 'https://github.com/%s/releases/tag/v%s' "${BASH_REMATCH[1]}" "$1"
  return 0
}

# update_check — asks the branch for its latest version now; caches the answer and sends one
# notification per new version. Returns 1 when it couldn't ask (offline, not a git install).
update_check() {
  local g=(git -C "$FAWWK_HOME") branch latest url
  [[ -d $FAWWK_HOME/.git ]] || return 1
  branch=$("${g[@]}" symbolic-ref --short -q HEAD || echo main)
  timeout 60 "${g[@]}" fetch -q --depth 1 origin "+refs/heads/$branch:refs/fawwk/latest" 2>/dev/null || return 1
  latest=$("${g[@]}" show refs/fawwk/latest:lib/common.sh 2>/dev/null | sed -n 's/^FAWWK_VERSION="\(.*\)"$/\1/p')
  [[ $latest =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
  mkdir -p "$FAWWK_VAR"
  update_load
  conf_set "$UPDATE_FILE" UC_CHECKED "$(date +%s)"
  conf_set "$UPDATE_FILE" UC_LATEST "$latest"
  conf_set "$UPDATE_FILE" UC_BRANCH "$branch"
  chmod 644 "$UPDATE_FILE"   # no secrets; lets non-root commands show the notice
  if version_gt "$latest" "$FAWWK_VERSION" && [[ $UC_NOTIFIED != "$latest" ]]; then
    url=$(update_release_url "$latest")
    local news=''
    [[ -n $url ]] && news="  $G_SEP What's new: $url"
    notify update fawwk '' "$G_ARROW Fawwk $latest is out (this server, $(hostname), runs $FAWWK_VERSION). Update with: sudo fawwk update$news"
    conf_set "$UPDATE_FILE" UC_NOTIFIED "$latest"
    chmod 644 "$UPDATE_FILE"
  fi
  return 0
}

# Runs update_check when the last one is a day old (called by the every-minute timer).
update_check_daily() {
  [[ ${UPDATE_CHECK:-on} != off ]] || return 0
  update_load
  (($(date +%s) - ${UC_CHECKED:-0} >= UPDATE_EVERY)) || return 0
  update_check >/dev/null 2>&1 || conf_set "$UPDATE_FILE" UC_CHECKED "$(($(date +%s) - UPDATE_EVERY + 3600))"   # offline: retry in an hour
  return 0
}

# The newer version waiting, from the last check (empty when up to date or never checked).
update_available() {
  update_load
  [[ -n $UC_LATEST ]] && version_gt "$UC_LATEST" "$FAWWK_VERSION" && printf '%s' "$UC_LATEST"
  return 0
}

# update_notice COMMAND — one line after a command's output when a newer version is out. Only in a
# terminal, never for the commands that update or run unattended. FAWWK_NO_UPDATE_NOTICE=1 hides it.
update_notice() {
  case ${1-} in update | self-update | post-update | sync | hooks-run | cron-run | version | -v | --version) return 0 ;; esac
  [[ -t 2 || -n ${FAWWK_UPDATE_NOTICE_FORCE-} ]] || return 0
  [[ -z ${FAWWK_NO_UPDATE_NOTICE-} && ${UPDATE_CHECK:-on} != off ]] || return 0
  local latest url news=''
  latest=$(update_available)
  [[ -n $latest ]] || return 0
  url=$(update_release_url "$latest")
  [[ -n $url ]] && news="  ${C_MUTED}$G_SEP what's new: $url${C_RESET}"
  printf '\n  %s%s%s Fawwk %s%s%s is out %s(you have %s)%s %s %ssudo fawwk update%s%s\n' \
    "$C_YELLOW" "$G_WARN" "$C_RESET" "$C_BOLD" "$latest" "$C_RESET" "$C_MUTED" "$FAWWK_VERSION" "$C_RESET" \
    "$G_ARROW" "$C_ACCENT" "$C_RESET" "$news" >&2
}

# `fawwk update --check`
update_check_cmd() {
  require_root update
  step "Checking for a new Fawwk version"
  update_check || die "Couldn't reach Fawwk's git remote ($(git -C "$FAWWK_HOME" remote get-url origin 2>/dev/null || echo 'none'))."
  local latest
  latest=$(update_available)
  if [[ -n $latest ]]; then
    warn "Fawwk $latest is out (you have $FAWWK_VERSION). Update with: sudo fawwk update"
    local url; url=$(update_release_url "$latest"); [[ -n $url ]] && hint "What's new: $url"
  else
    ok "Fawwk $FAWWK_VERSION is the latest on ${UC_BRANCH:-main}"
  fi
}
