#!/usr/bin/env bash
# fawwk — copies of the backups in S3-compatible storage (Amazon S3, Cloudflare R2, Backblaze B2,
# Wasabi, MinIO...), so losing the server doesn't lose the data.
#
# After the nightly database backups, every local backup the bucket doesn't have yet is uploaded,
# with a copy of the server's settings (`fawwk backup`: apps, env vars, keys). Then copies older than
# S3_KEEP_DAYS are deleted, but the newest S3_KEEP_MIN of each database always stay, even when they're
# old: if backups stop working for a month, the last good ones are still there.
#
# Layout in the bucket:  <prefix>/db/<database>/<backup file>   and   <prefix>/server/settings-<time>.tar.gz
# Uploads go through rclone. Its settings come from the environment (never a command line), and the
# keys live in /etc/fawwk/s3.env (root only).

S3_KEYS="$FAWWK_ETC/s3.env"
S3_STATUS="$FAWWK_VAR/s3-status"
S3_RCLONE_CONF="$FAWWK_ETC/rclone.conf"
S3_TS_RE='([0-9]{8})-([0-9]{6})'   # the time in a backup's name: 20261106-031700

s3_enabled() { [[ -n ${S3_BUCKET-} && -f $S3_KEYS ]]; }

s3_usage() {
  cat <<'EOF'
Usage: sudo fawwk backup s3 [command]

Keeps copies of the backups in S3-compatible storage (Amazon S3, Cloudflare R2, Backblaze B2,
Wasabi, MinIO...). Each night, after the database backups, new backups and a copy of the server's
settings are uploaded, and old copies are deleted.

  (none) | status            What's set up, and the last upload
  setup                      Connect a bucket (asks for its details, then tests it)
  test                       Upload, read and delete a small test file
  push                       Upload now (and delete old copies)
  list [database|server]     What's in the bucket
  get <database|server> [latest|file]
                             Download a copy (then: fawwk db restore / fawwk restore)
  keep <days> [--min N]      Delete copies older than this (0 = never), always keeping the newest N
  settings on|off            Whether the server's settings go up too (they contain secrets)
  off                        Stop uploading (the bucket's contents stay)

Without prompts:
  FAWWK_S3_ACCESS_KEY_ID=... FAWWK_S3_SECRET_ACCESS_KEY=... fawwk backup s3 setup \
    --provider r2|aws|other --account-id ID (R2) | --endpoint URL (other) [--region R] \
    --bucket NAME [--prefix fawwk/<host>] [--keep-days 30] --yes
EOF
}

# ---------- rclone ----------
s3_rclone_version() { rclone version 2>/dev/null | sed -n '1s/^rclone v\([0-9.]*\).*/\1/p'; }

s3_provider_label() {
  case ${1-} in r2) echo "Cloudflare R2" ;; aws) echo "Amazon S3" ;; *) echo "S3-compatible" ;; esac
}

# rclone's name for the provider (Cloudflare needs rclone 1.59; older ones treat R2 as "Other").
s3_rclone_provider() {
  case ${S3_PROVIDER-} in
    aws) echo AWS ;;
    r2) if version_gt "$(s3_rclone_version)" 1.58.99; then echo Cloudflare; else echo Other; fi ;;
    *) echo Other ;;
  esac
}

s3_install_rclone() {
  command -v rclone >/dev/null 2>&1 && return 0
  spin_start "Installing rclone (uploads the backups)"
  if DEBIAN_FRONTEND=noninteractive apt-get install -y -q rclone >/dev/null 2>&1 ||
    { apt-get update -q >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y -q rclone >/dev/null 2>&1; }; then
    spin_stop; ok "rclone $(s3_rclone_version) installed"
  else
    spin_stop; err "Couldn't install rclone. Try: apt-get install rclone"; return 1
  fi
}

# s3_rclone ARGS... — rclone with the bucket as the remote "fawwks3:". Keys come from S3_KEYS, or from
# S3_ACCESS_KEY_ID / S3_SECRET_ACCESS_KEY already set (setup tests them before saving).
s3_rclone() {
  (
    if [[ -z ${S3_ACCESS_KEY_ID-} && -r $S3_KEYS ]]; then
      # shellcheck disable=SC1090
      source "$S3_KEYS"
    fi
    export RCLONE_CONFIG_FAWWKS3_TYPE=${S3_REMOTE_TYPE:-s3}
    RCLONE_CONFIG_FAWWKS3_PROVIDER=$(s3_rclone_provider)
    export RCLONE_CONFIG_FAWWKS3_PROVIDER
    export RCLONE_CONFIG_FAWWKS3_ENV_AUTH=false
    export RCLONE_CONFIG_FAWWKS3_ACCESS_KEY_ID=${S3_ACCESS_KEY_ID-}
    export RCLONE_CONFIG_FAWWKS3_SECRET_ACCESS_KEY=${S3_SECRET_ACCESS_KEY-}
    export RCLONE_CONFIG_FAWWKS3_REGION=${S3_REGION:-us-east-1}
    [[ -n ${S3_ENDPOINT-} ]] && export RCLONE_CONFIG_FAWWKS3_ENDPOINT=$S3_ENDPOINT
    # Keys limited to one bucket can't check or create buckets; the bucket already exists.
    export RCLONE_CONFIG_FAWWKS3_NO_CHECK_BUCKET=true
    [[ -f $S3_RCLONE_CONF ]] || { (umask 077; : >"$S3_RCLONE_CONF"); }
    local extra=()
    # The AWS SDK inside rclone can't use AWS_CA_BUNDLE ("unsupported transport"); rclone's flag works.
    if [[ -n ${AWS_CA_BUNDLE-} ]]; then extra+=(--ca-cert "$AWS_CA_BUNDLE"); unset AWS_CA_BUNDLE; fi
    exec rclone --config "$S3_RCLONE_CONF" --retries 3 --low-level-retries 10 --contimeout 30s "${extra[@]}" "$@"
  )
}

s3_root() { printf 'fawwks3:%s/%s' "$S3_BUCKET" "${S3_PREFIX:-fawwk}"; }

# s3_ls DIR — file names in <prefix>/DIR (none when it doesn't exist yet).
s3_ls() {
  local out rc=0
  out=$(s3_rclone lsf --files-only "$(s3_root)/$1" 2>&1) || rc=$?
  if ((rc == 3)) || [[ $out == *"directory not found"* ]]; then return 0; fi   # nothing there yet
  ((rc == 0)) || { printf '%s\n' "$out" >&2; return 1; }
  [[ -n $out ]] && printf '%s\n' "$out"
  return 0
}

s3_dirs() {
  local out rc=0
  out=$(s3_rclone lsf --dirs-only "$(s3_root)/$1" 2>&1) || rc=$?
  if ((rc == 3)) || [[ $out == *"directory not found"* ]]; then return 0; fi
  ((rc == 0)) || { printf '%s\n' "$out" >&2; return 1; }
  [[ -n $out ]] && printf '%s\n' "${out//\//}"
  return 0
}

s3_put() { s3_rclone copyto "$1" "$(s3_root)/$2"; }
s3_fetch() { s3_rclone copyto "$(s3_root)/$1" "$2"; }
s3_rm() { s3_rclone deletefile "$(s3_root)/$1"; }

# ---------- status ----------
s3_status_set() {
  mkdir -p "$FAWWK_VAR"
  conf_set "$S3_STATUS" "$1" "$2"
}

s3_status_load() {
  S3_LAST_OK='' S3_LAST_ERROR='' S3_LAST_ERROR_AT='' S3_LAST_SUMMARY=''
  # shellcheck disable=SC1090
  [[ -r $S3_STATUS ]] && source "$S3_STATUS" 2>/dev/null
  return 0
}

s3_ago() {
  local s=$(($(date +%s) - $1))
  if ((s < 3600)); then echo "$((s / 60))m ago"; elif ((s < 172800)); then echo "$((s / 3600))h ago"; else echo "$((s / 86400)) days ago"; fi
}

# ---------- uploading and pruning ----------
# s3_stamp NAME — "YYYYmmddHHMMSS" from the last date-time in a backup's name, or nothing.
s3_stamp() { [[ $1 =~ ^.*$S3_TS_RE ]] && printf '%s%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; return 0; }

# The oldest stamp that is kept by age ("" when copies are kept forever).
s3_cutoff() {
  local days=${S3_KEEP_DAYS:-30}
  [[ $days =~ ^[0-9]+$ ]] || days=30
  ((days > 0)) || return 0
  date -d "@$(($(date +%s) - days * 86400))" +%Y%m%d%H%M%S
}

# s3_prune DIR — deletes copies in DIR older than S3_KEEP_DAYS, except the newest S3_KEEP_MIN.
# Files whose name has no date-time in it weren't made by Fawwk and are never touched.
s3_prune() {
  local dir=$1 cutoff min=${S3_KEEP_MIN:-3} f stamp n=0 deleted=0 rows=()
  cutoff=$(s3_cutoff)
  [[ -n $cutoff ]] || { printf 0; return 0; }
  [[ $min =~ ^[0-9]+$ ]] || min=3
  while IFS= read -r f; do
    [[ -z $f ]] && continue
    stamp=$(s3_stamp "$f")
    [[ -n $stamp ]] && rows+=("$stamp $f")
  done < <(s3_ls "$dir" 2>/dev/null)
  while IFS=' ' read -r stamp f; do
    [[ -z $f ]] && continue
    n=$((n + 1))
    ((n <= min)) && continue
    if [[ $stamp < $cutoff ]]; then
      s3_rm "$dir/$f" >/dev/null 2>&1 && deleted=$((deleted + 1))
    fi
  done < <(((${#rows[@]})) && printf '%s\n' "${rows[@]}" | sort -r)
  printf '%s' "$deleted"
}

# s3_push — uploads what the bucket is missing, then prunes. Prints a summary; returns 1 on a failure.
s3_push() {
  local name f base have cutoff up=0 failed=() dir deleted=0 d tmp stamp
  cutoff=$(s3_cutoff)
  while IFS= read -r name; do
    [[ -z $name ]] && continue
    dir="db/$name"
    if ! have=$(s3_ls "$dir"); then failed+=("$name (couldn't list the bucket)"); continue; fi
    while IFS= read -r f; do
      [[ -z $f ]] && continue
      base=${f##*/}
      [[ $base == *.partial ]] && continue
      grep -qxF -- "$base" <<<"$have" && continue
      stamp=$(s3_stamp "$base")
      [[ -n $cutoff && -n $stamp && $stamp < $cutoff ]] && continue   # would be deleted right away
      if s3_put "$f" "$dir/$base" >/dev/null 2>&1; then up=$((up + 1)); else failed+=("$base"); fi
    done < <(find "$(db_backups "$name")" -maxdepth 1 -type f 2>/dev/null | sort)
  done < <(db_names)
  if [[ ${S3_SETTINGS:-on} == on ]]; then
    tmp=$(mktemp -d)
    f="$tmp/settings-$(date +%Y%m%d-%H%M%S).tar.gz"
    if (cmd_backup "$f") >/dev/null 2>&1 && s3_put "$f" "server/${f##*/}" >/dev/null 2>&1; then up=$((up + 1))
    else failed+=("server settings"); fi
    rm -rf "$tmp"
  fi
  # Prune every database folder in the bucket, including databases since removed from this server.
  while IFS= read -r d; do
    [[ -n $d ]] && deleted=$((deleted + $(s3_prune "db/$d")))
  done < <(s3_dirs db 2>/dev/null || true)
  deleted=$((deleted + $(s3_prune server)))
  S3_PUSH_SUMMARY="$up uploaded, $deleted old cop$( ((deleted == 1)) && echo y || echo ies) deleted"
  if ((${#failed[@]})); then
    S3_PUSH_FAILED="${failed[*]}"
    s3_status_set S3_LAST_ERROR "Couldn't upload: ${failed[*]}"
    s3_status_set S3_LAST_ERROR_AT "$(date +%s)"
    return 1
  fi
  s3_status_set S3_LAST_OK "$(date +%s)"
  s3_status_set S3_LAST_SUMMARY "$S3_PUSH_SUMMARY"
  s3_status_set S3_LAST_ERROR ''
  return 0
}

# After the nightly database backups (fawwk db backup --all --scheduled).
s3_nightly() {
  s3_enabled || return 0
  command -v rclone >/dev/null 2>&1 || s3_install_rclone >/dev/null 2>&1 || true
  if s3_push; then
    ok "Bucket: $S3_PUSH_SUMMARY"
  else
    err "Upload to the bucket failed: $S3_PUSH_FAILED"
    notify failed backups '' "$G_ERR Uploading backups to $(s3_provider_label "$S3_PROVIDER") failed on $(hostname): $S3_PUSH_FAILED. Check: fawwk backup s3 test"
    return 1
  fi
}

# s3_test — upload, list, download and delete a small file. Says which step failed.
s3_test() {
  local tmp name back
  tmp=$(mktemp -d)
  name=".fawwk-test-$(date +%s)-$RANDOM"
  printf 'fawwk %s\n' "$(hostname)" >"$tmp/up"
  if ! s3_put "$tmp/up" "$name" >"$tmp/log" 2>&1; then
    err "Couldn't upload to $S3_BUCKET."
    tail -n 5 "$tmp/log" | ui_quote --error
    hint "Check the bucket name, the endpoint and that the key may write objects (R2: Object Read & Write)."
    rm -rf "$tmp"; return 1
  fi
  if ! s3_ls '' 2>"$tmp/log" | grep -qxF -- "$name"; then
    err "Uploaded, but couldn't list the bucket (the key needs list access too)."
    tail -n 5 "$tmp/log" | ui_quote --error
    s3_rm "$name" >/dev/null 2>&1 || true
    rm -rf "$tmp"; return 1
  fi
  back="$tmp/down"
  if ! s3_fetch "$name" "$back" >"$tmp/log" 2>&1 || ! cmp -s "$tmp/up" "$back"; then
    err "Uploaded, but couldn't read it back (the key needs read access too)."
    tail -n 5 "$tmp/log" | ui_quote --error
    s3_rm "$name" >/dev/null 2>&1 || true
    rm -rf "$tmp"; return 1
  fi
  if ! s3_rm "$name" >"$tmp/log" 2>&1; then
    err "Couldn't delete the test file (the key needs delete access, or old backups can't be removed)."
    tail -n 5 "$tmp/log" | ui_quote --error
    rm -rf "$tmp"; return 1
  fi
  rm -rf "$tmp"
  return 0
}

# ---------- commands ----------
cmd_backup_s3() {
  local sub=${1:-status}
  (($#)) && shift
  case $sub in
    -h | --help | help) s3_usage; return 0 ;;
  esac
  require_root "backup s3"; require_setup
  case $sub in
    status) s3_cmd_status ;;
    setup) s3_cmd_setup "$@" ;;
    test) s3_require; s3_install_rclone || exit 1; step "Testing $S3_BUCKET"; s3_test || { FAWWK_DIED=1; exit 1; }; ok "Upload, list, download and delete all work" ;;
    push) s3_require; s3_install_rclone || exit 1; step "Uploading backups to $S3_BUCKET"
      spin_start "Uploading"
      if s3_push; then spin_stop; ok "$S3_PUSH_SUMMARY"; else spin_stop; err "Couldn't upload: $S3_PUSH_FAILED"; hint "Check with: fawwk backup s3 test"; FAWWK_DIED=1; exit 1; fi ;;
    list | ls) s3_require; s3_install_rclone || exit 1; s3_cmd_list "$@" ;;
    get | download) s3_require; s3_install_rclone || exit 1; s3_cmd_get "$@" ;;
    keep) s3_cmd_keep "$@" ;;
    settings)
      case ${1-} in
        on | off) conf_set "$FAWWK_CONF" S3_SETTINGS "$1"; ok "Server settings in the bucket: $1" ;;
        *) die "Usage: fawwk backup s3 settings on|off" ;;
      esac ;;
    off)
      s3_enabled || { info "Not set up."; return 0; }
      confirm "Stop uploading backups to $S3_BUCKET? (what's there stays)" Y || return 0
      rm -f "$S3_KEYS" "$S3_STATUS"
      conf_set "$FAWWK_CONF" S3_BUCKET ''
      ok "Stopped. Backups stay on this server only. Set up again with: fawwk backup s3 setup" ;;
    *) err "Unknown command: backup s3 $sub"; s3_usage >&2; return 1 ;;
  esac
}

s3_require() { s3_enabled || die "No bucket set up yet. Connect one with: sudo fawwk backup s3 setup"; }

s3_cmd_status() {
  if ! s3_enabled; then
    info "Backups are only on this server. Copies in S3 / R2 survive losing it: sudo fawwk backup s3 setup"
    return 0
  fi
  s3_status_load
  local k last
  k() { printf '  %s%-14s%s %s\n' "$C_MUTED" "$1" "$C_RESET" "$2"; }
  step "Backups in $(s3_provider_label "$S3_PROVIDER")"
  k Bucket "$S3_BUCKET/${S3_PREFIX:-fawwk}/"
  [[ -n ${S3_ENDPOINT-} ]] && k Endpoint "$S3_ENDPOINT"
  if [[ ${S3_KEEP_DAYS:-30} == 0 ]]; then k Keeps "every copy (never deletes)"
  else k Keeps "${S3_KEEP_DAYS:-30} days, and always the newest ${S3_KEEP_MIN:-3} of each database"; fi
  k Settings "${S3_SETTINGS:-on} $([[ ${S3_SETTINGS:-on} == on ]] && echo '(apps, env vars and keys go up too)')"
  if [[ -n $S3_LAST_OK ]]; then last="$(s3_ago "$S3_LAST_OK") ($S3_LAST_SUMMARY)"; else last=never; fi
  k "Last upload" "$last"
  [[ -n $S3_LAST_ERROR ]] && k "Last error" "${C_RED}$S3_LAST_ERROR${C_RESET} ($(s3_ago "${S3_LAST_ERROR_AT:-0}"))"
  unset -f k
  hint "Uploads run after the nightly backups (${DB_BACKUP_AT:-03:17}). Now: fawwk backup s3 push"
}

valid_bucket() { [[ $1 =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || { warn "Bucket names are 3-63 lowercase letters, digits, dots and dashes."; return 1; }; }
valid_url() { [[ $1 =~ ^https?://[^[:space:]]+$ ]] || { warn "Give the full URL, e.g. https://s3.eu-central-003.backblazeb2.com"; return 1; }; }
valid_r2_account() { [[ $1 =~ ^[0-9a-f]{32}$ ]] || { warn "The account ID is 32 characters (0-9, a-f): Cloudflare dashboard, R2, Account details."; return 1; }; }
valid_days() { [[ $1 =~ ^[0-9]+$ ]] || { warn "A number of days (0 = keep forever)."; return 1; }; }
valid_prefix() { [[ $1 =~ ^[A-Za-z0-9._/-]+$ && $1 != /* && $1 != */ ]] || { warn "Letters, digits, . _ - and /, not starting or ending with /."; return 1; }; }

s3_cmd_setup() {
  local provider='' endpoint='' region='' bucket='' prefix='' days='' account='' pick key_id='' secret=''
  while (($#)); do
    case $1 in
      --provider) need_arg "$@"; provider=$2; shift 2 ;;
      --endpoint) need_arg "$@"; endpoint=$2; shift 2 ;;
      --account-id) need_arg "$@"; account=$2; shift 2 ;;
      --region) need_arg "$@"; region=$2; shift 2 ;;
      --bucket) need_arg "$@"; bucket=$2; shift 2 ;;
      --prefix) need_arg "$@"; prefix=$2; shift 2 ;;
      --keep-days) need_arg "$@"; days=$2; shift 2 ;;
      -y | --yes) FAWWK_YES=1; shift ;;
      *) die "Unknown option: $1 (see: fawwk backup s3 --help)" ;;
    esac
  done
  ui_banner "Backups to S3 ${G_SEP} copies that survive losing this server"
  step "Storage"
  if [[ -z $provider ]]; then
    if is_interactive; then
      menu pick "Where should the backups go?" 1 "Cloudflare R2" "Amazon S3" \
        "Another S3-compatible service (Backblaze B2, Wasabi, DigitalOcean Spaces, MinIO...)"
      provider=$(case $pick in 1) echo r2 ;; 2) echo aws ;; *) echo other ;; esac)
    else
      provider=${S3_PROVIDER:-r2}
    fi
  fi
  [[ $provider =~ ^(r2|aws|other)$ ]] || die "--provider is r2, aws or other"
  case $provider in
    r2)
      if [[ -z $endpoint ]]; then
        ask account "Cloudflare account ID (R2 page, Account details)" "$account" valid_r2_account
        endpoint="https://$account.r2.cloudflarestorage.com"
      fi
      region=auto ;;
    aws)
      endpoint=''
      ask region "AWS region of the bucket" "${region:-${S3_REGION:-us-east-1}}" ;;
    other)
      ask endpoint "Endpoint URL (from the provider's S3 settings)" "${endpoint:-${S3_ENDPOINT-}}" valid_url
      ask region "Region (enter if the provider doesn't name one)" "${region:-${S3_REGION:-us-east-1}}" ;;
  esac
  ask bucket "Bucket name (create it first; keep it private)" "${bucket:-${S3_BUCKET-}}" valid_bucket
  ask prefix "Folder in the bucket for this server" "${prefix:-${S3_PREFIX:-fawwk/$(hostname -s)}}" valid_prefix
  key_id=${FAWWK_S3_ACCESS_KEY_ID-} secret=${FAWWK_S3_SECRET_ACCESS_KEY-}
  [[ -n $key_id ]] || ask_secret key_id "Access key ID"
  [[ -n $secret ]] || ask_secret secret "Secret access key"
  ask days "Delete copies older than how many days? (0 = never)" "${days:-${S3_KEEP_DAYS:-30}}" valid_days

  s3_install_rclone || die "rclone is needed to upload."
  step "Testing the bucket"
  S3_PROVIDER=$provider S3_ENDPOINT=$endpoint S3_REGION=$region S3_BUCKET=$bucket S3_PREFIX=$prefix
  S3_ACCESS_KEY_ID=$key_id S3_SECRET_ACCESS_KEY=$secret
  spin_start "Uploading, listing, reading and deleting a test file"
  if ! s3_test; then spin_stop; die "Nothing was saved. Fix the above and run: sudo fawwk backup s3 setup"; fi
  spin_stop
  ok "The bucket works"

  (umask 077; printf 'S3_ACCESS_KEY_ID=%q\nS3_SECRET_ACCESS_KEY=%q\n' "$key_id" "$secret" >"$S3_KEYS")
  chmod 600 "$S3_KEYS"
  unset S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY
  local kv
  for kv in "S3_PROVIDER=$provider" "S3_ENDPOINT=$endpoint" "S3_REGION=$region" "S3_BUCKET=$bucket" \
    "S3_PREFIX=$prefix" "S3_KEEP_DAYS=$days" "S3_KEEP_MIN=${S3_KEEP_MIN:-3}" "S3_SETTINGS=${S3_SETTINGS:-on}"; do
    conf_set "$FAWWK_CONF" "${kv%%=*}" "${kv#*=}"
  done
  S3_KEEP_DAYS=$days
  # The nightly timer runs the upload, also on a server without databases (for the settings).
  db_timer_ensure
  ok "Saved. Each night after the backups (${DB_BACKUP_AT:-03:17}), new ones go to $bucket/$prefix/"
  if ((days > 0)); then info "Copies older than $days days are deleted; the newest ${S3_KEEP_MIN:-3} of each database always stay."
  else info "Copies are never deleted (change: fawwk backup s3 keep 30)."; fi
  info "The server's settings go up too (they contain secrets: keep the bucket private). Turn off: fawwk backup s3 settings off"
  if confirm "Upload the backups this server has now?" Y; then
    spin_start "Uploading"
    if s3_push; then spin_stop; ok "$S3_PUSH_SUMMARY"
    else spin_stop; warn "Some uploads failed: $S3_PUSH_FAILED. Retry: fawwk backup s3 push"; fi
  fi
}

s3_cmd_list() {
  local what=${1-} dirs=() d f n=0
  if [[ -n $what ]]; then
    [[ $what == server ]] && dirs=(server) || dirs=("db/$what")
  else
    while IFS= read -r d; do [[ -n $d ]] && dirs+=("db/$d"); done < <(s3_dirs db)
    dirs+=(server)
  fi
  for d in "${dirs[@]}"; do
    step "$S3_BUCKET/${S3_PREFIX:-fawwk}/$d"
    local out
    out=$(s3_rclone lsf --files-only --format 'pst' --separator '|' "$(s3_root)/$d" 2>/dev/null || true)
    if [[ -z $out ]]; then info "(empty)"; continue; fi
    while IFS='|' read -r f size t; do
      [[ -z $f ]] && continue
      n=$((n + 1))
      printf '  %-58s %9s  %s\n' "$f" "$(numfmt --to=iec "$size" 2>/dev/null || echo "$size")" "${t:0:16}"
    done < <(sort -r <<<"$out")
  done
  ((n)) || hint "Nothing uploaded yet. Upload now: fawwk backup s3 push"
}

# fawwk backup s3 get <database|server> [latest|file]
s3_cmd_get() {
  local what=${1-} which=${2:-latest} dir dest f stamp best='' bestf=''
  [[ -n $what ]] || die "Usage: fawwk backup s3 get <database|server> [latest|file]"
  if [[ $what == server ]]; then dir=server dest=$PWD; else dir="db/$what" dest=$(db_backups "$what"); fi
  if [[ $which == latest ]]; then
    while IFS= read -r f; do
      [[ $f == *-pre-restore.* ]] && continue
      stamp=$(s3_stamp "$f")
      [[ -n $stamp && $stamp > $best ]] && best=$stamp bestf=$f
    done < <(s3_ls "$dir")
    [[ -n $bestf ]] || die "No copies of $what in the bucket. See: fawwk backup s3 list"
    which=$bestf
  fi
  mkdir -p "$dest"
  [[ $what == server ]] || chmod 700 "$BACKUPS_DIR" "$dest"
  spin_start "Downloading $which"
  s3_fetch "$dir/$which" "$dest/$which" >/dev/null 2>&1 || { spin_stop; die "Couldn't download $dir/$which. See: fawwk backup s3 list $what"; }
  spin_stop
  ok "Downloaded: $dest/$which ($(du -h "$dest/$which" | cut -f1))"
  if [[ $what == server ]]; then
    hint "Rebuild this server from it: sudo fawwk restore $dest/$which"
  elif db_exists "$what" 2>/dev/null; then
    hint "Put it back: sudo fawwk db restore $what $dest/$which"
  else
    hint "Create the database first (sudo fawwk db create $what --type ...), then: sudo fawwk db restore $what $dest/$which"
  fi
}

s3_cmd_keep() {
  local days=${1-} min=''
  [[ ${2-} == --min ]] && min=${3-}
  if [[ -z $days ]]; then
    info "Copies are kept ${S3_KEEP_DAYS:-30} days (0 = forever), always the newest ${S3_KEEP_MIN:-3} of each database."
    return 0
  fi
  valid_days "$days" || die "Usage: fawwk backup s3 keep <days> [--min N]"
  [[ -z $min || $min =~ ^[1-9][0-9]*$ ]] || die "--min is a number of copies, at least 1"
  conf_set "$FAWWK_CONF" S3_KEEP_DAYS "$days"
  [[ -n $min ]] && conf_set "$FAWWK_CONF" S3_KEEP_MIN "$min"
  if ((days == 0)); then ok "Copies in the bucket are never deleted"
  else ok "Copies older than $days days are deleted after each upload, keeping the newest ${min:-${S3_KEEP_MIN:-3}} of each database"; fi
}
