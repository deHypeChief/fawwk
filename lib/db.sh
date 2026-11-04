#!/usr/bin/env bash
# fawwk — managed databases: Postgres, Redis and MongoDB in containers on the private fawwk network,
# linked to apps through env vars, with logical backups (scheduled daily) and restore.
#
#   /etc/fawwk/dbs/<name>/db.conf      settings and password (root only)
#   docker volume fawwk_db_<name>      the data
#   /var/lib/fawwk/backups/<name>/     backups: <name>-<date>-<kind>.<ext>, kind = scheduled|manual|pre-restore
#
# Databases have no published ports: only containers on the fawwk network (your apps) can reach them,
# as fawwk-db-<name>. Use `fawwk db shell <name>` to get a prompt.

DBS_ETC="$FAWWK_ETC/dbs"
BACKUPS_DIR="$FAWWK_VAR/backups"
DB_KEEP_BACKUPS="${DB_KEEP_BACKUPS:-7}"   # scheduled and pre-restore backups kept per database
DB_FIELDS=(D_NAME D_TYPE D_VERSION D_IMAGE D_USER D_PASSWORD D_DATABASE D_MEMORY D_LINKS D_CREATED)

db_dir()       { printf '%s/%s' "$DBS_ETC" "$1"; }
db_exists()    { [[ -f $DBS_ETC/$1/db.conf ]]; }
db_container() { printf 'fawwk-db-%s' "$1"; }
db_volume()    { printf 'fawwk_db_%s' "$1"; }
db_backups()   { printf '%s/%s' "$BACKUPS_DIR" "$1"; }

db_names() {
  local f
  for f in "$DBS_ETC"/*/db.conf; do
    [[ -f $f ]] || continue
    f=${f%/db.conf}
    printf '%s\n' "${f##*/}"
  done
}

db_load() {
  db_exists "$1" || die "No database named '$1'. See: fawwk db"
  local v
  for v in "${DB_FIELDS[@]}"; do printf -v "$v" '%s' ''; done
  # shellcheck disable=SC1090
  source "$DBS_ETC/$1/db.conf"
}

db_set() { conf_set "$DBS_ETC/$D_NAME/db.conf" "$1" "$2"; printf -v "$1" '%s' "$2"; }

# ---------- per-type details ----------
# MongoDB defaults to 7.0. MongoDB 8 builds (8.0.x and 8.3.x so far) refuse to start on Linux kernel
# 6.19 and newer (MongoDB issue SERVER-121912), and its patch releases have been adding that refusal,
# so a floating 8.x tag could stop working on new kernels. 7.0 doesn't have the problem.
db_default_version() { case $1 in postgres) echo 17 ;; redis) echo 7 ;; mongodb) echo 7.0 ;; esac; }

# The running kernel as MAJOR.MINOR (FAWWK_KERNEL overrides it, for tests).
kernel_version() { local k=${FAWWK_KERNEL:-$(uname -r)}; [[ $k =~ ^([0-9]+)\.([0-9]+) ]] && printf '%s.%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; }

# kernel_at_least X.Y — 0 when the running kernel is X.Y or newer.
kernel_at_least() { [[ $(printf '%s\n%s\n' "$1" "$(kernel_version)" | sort -V | head -n1) == "$1" ]]; }

# mongo_refuses_kernel IMAGE — 0 when that MongoDB build refuses to run on this kernel. The refusal
# is compiled into mongod with its message, so look for it instead of keeping a list of versions.
mongo_refuses_kernel() {
  kernel_at_least 6.19 || return 1
  local hits
  hits=$(docker run --rm --network none --entrypoint sh "$1" -c 'grep -c "kernel versions 6.19" "$(command -v mongod)"' 2>/dev/null || true)
  ((${hits:-0} > 0))
}
db_image_for() {
  case $1 in
    postgres) printf 'postgres:%s-alpine' "$2" ;;
    redis) printf 'redis:%s-alpine' "$2" ;;
    mongodb) printf 'mongo:%s' "$2" ;;
  esac
}
db_port() { case $1 in postgres) echo 5432 ;; redis) echo 6379 ;; mongodb) echo 27017 ;; esac; }
db_data_dir() { case $1 in postgres) echo /var/lib/postgresql/data ;; redis) echo /data ;; mongodb) echo /data/db ;; esac; }
db_default_var() { case $1 in postgres) echo DATABASE_URL ;; redis) echo REDIS_URL ;; mongodb) echo MONGODB_URL ;; esac; }
db_backup_ext() { case $1 in postgres) echo dump ;; redis) echo rdb ;; mongodb) echo archive.gz ;; esac; }
db_label() { case $1 in postgres) echo PostgreSQL ;; redis) echo Redis ;; mongodb) echo MongoDB ;; esac; }

# The connection URL apps use (inside the fawwk network).
db_url() {
  local host port
  host=$(db_container "$D_NAME") port=$(db_port "$D_TYPE")
  case $D_TYPE in
    postgres) printf 'postgresql://%s:%s@%s:%s/%s' "$D_USER" "$D_PASSWORD" "$host" "$port" "$D_DATABASE" ;;
    redis) printf 'redis://default:%s@%s:%s/0' "$D_PASSWORD" "$host" "$port" ;;
    mongodb) printf 'mongodb://%s:%s@%s:%s/%s?authSource=admin' "$D_USER" "$D_PASSWORD" "$host" "$port" "$D_DATABASE" ;;
  esac
}

db_url_masked() { local u; u=$(db_url); printf '%s' "${u/$D_PASSWORD/****}"; }

# Starts (creating if needed) the database container from its settings.
db_run() {
  local c args=()
  c=$(db_container "$D_NAME")
  if docker inspect "$c" >/dev/null 2>&1; then
    [[ $(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null) == true ]] || docker start "$c" >/dev/null
    return 0
  fi
  docker network inspect "$FAWWK_NETWORK" >/dev/null 2>&1 || docker network create "$FAWWK_NETWORK" >/dev/null
  args=(-d --name "$c" --network "$FAWWK_NETWORK" --restart unless-stopped --label "fawwk.db=$D_NAME"
    -v "$(db_volume "$D_NAME"):$(db_data_dir "$D_TYPE")" --security-opt no-new-privileges:true
    --log-opt max-size=10m --log-opt max-file=3)
  [[ -n $D_MEMORY ]] && args+=(--memory "$D_MEMORY")
  # Passwords go in as env vars from this process's environment (-e NAME), never on the command line.
  case $D_TYPE in
    postgres)
      POSTGRES_USER=$D_USER POSTGRES_PASSWORD=$D_PASSWORD POSTGRES_DB=$D_DATABASE \
        docker run "${args[@]}" -e POSTGRES_USER -e POSTGRES_PASSWORD -e POSTGRES_DB "$D_IMAGE" >/dev/null ;;
    redis)
      # Back through the image's entrypoint, so Redis drops from root to its own user.
      REDIS_PASSWORD=$D_PASSWORD docker run "${args[@]}" -e REDIS_PASSWORD "$D_IMAGE" \
        sh -c 'exec docker-entrypoint.sh redis-server --appendonly yes --requirepass "$REDIS_PASSWORD"' >/dev/null ;;
    mongodb)
      MONGO_INITDB_ROOT_USERNAME=$D_USER MONGO_INITDB_ROOT_PASSWORD=$D_PASSWORD \
        docker run "${args[@]}" -e MONGO_INITDB_ROOT_USERNAME -e MONGO_INITDB_ROOT_PASSWORD "$D_IMAGE" >/dev/null ;;
  esac
}

# db_exec ARGS... — runs a command in the database container with its credentials in the environment.
# (The password reaches docker exec through its environment, so it never shows in `ps`.)
db_exec() {
  case $D_TYPE in
    postgres) PGPASSWORD=$D_PASSWORD docker exec -e PGPASSWORD "$@" ;;
    redis) REDISCLI_AUTH=$D_PASSWORD docker exec -e REDISCLI_AUTH "$@" ;;
    mongodb) docker exec "$@" ;;
  esac
}

# 0 when the database answers queries.
db_ready() {
  local c
  c=$(db_container "$D_NAME")
  case $D_TYPE in
    postgres) db_exec "$c" pg_isready -q -U "$D_USER" -d "$D_DATABASE" -h 127.0.0.1 >/dev/null 2>&1 ;;
    redis) [[ $(db_exec "$c" redis-cli ping 2>/dev/null) == PONG ]] ;;
    mongodb) [[ $(db_exec "$c" mongosh --quiet -u "$D_USER" -p "$D_PASSWORD" --authenticationDatabase admin \
      --eval 'db.runCommand({ping: 1}).ok' 2>/dev/null | tail -n1) == 1 ]] ;;
  esac
}

# What the readiness check prints (for error messages).
db_ready_output() {
  local c
  c=$(db_container "$D_NAME")
  case $D_TYPE in
    postgres) db_exec "$c" pg_isready -U "$D_USER" -d "$D_DATABASE" -h 127.0.0.1 ;;
    redis) db_exec "$c" redis-cli ping ;;
    mongodb) db_exec "$c" mongosh --quiet -u "$D_USER" -p "$D_PASSWORD" --authenticationDatabase admin --eval 'db.runCommand({ping: 1}).ok' ;;
  esac
}

db_wait_ready() {
  local deadline=$((SECONDS + ${1:-90}))
  while ((SECONDS < deadline)); do
    db_ready && return 0
    [[ $(docker inspect -f '{{.State.Running}}' "$(db_container "$D_NAME")" 2>/dev/null) == true ]] || return 1
    sleep 1
  done
  return 1
}

db_state() { docker inspect -f '{{.State.Status}}' "$(db_container "$D_NAME")" 2>/dev/null || echo missing; }

# ---------- backups ----------
# db_backup_now KIND — writes a backup of the loaded database and prints its path.
db_backup_now() {
  local kind=$1 dir file c tmp rc=0
  c=$(db_container "$D_NAME")
  dir=$(db_backups "$D_NAME")
  mkdir -p "$dir"; chmod 700 "$BACKUPS_DIR" "$dir"
  file="$dir/$D_NAME-$(date +%Y%m%d-%H%M%S)-$kind.$(db_backup_ext "$D_TYPE")"
  tmp="$file.partial"
  (
    umask 077
    case $D_TYPE in
      postgres)
        db_exec "$c" pg_dump -Fc -U "$D_USER" -h 127.0.0.1 "$D_DATABASE" >"$tmp" ;;
      mongodb)
        db_exec "$c" mongodump --quiet --archive --gzip -u "$D_USER" -p "$D_PASSWORD" --authenticationDatabase admin >"$tmp" ;;
      redis)
        # BGSAVE writes /data/dump.rdb in the background. SCHEDULE queues it if Redis is busy rewriting
        # its append-only file (as it does right after starting) instead of refusing.
        local before info i saved=0
        before=$(db_exec "$c" redis-cli LASTSAVE)
        # LASTSAVE counts in seconds: start in a later second than the last save, or we can't tell them apart.
        while (($(date +%s) <= before)); do sleep 0.2; done
        db_exec "$c" redis-cli BGSAVE SCHEDULE >/dev/null
        for i in $(seq 1 600); do
          info=$(db_exec "$c" redis-cli INFO persistence | tr -d '\r')
          [[ $info == *rdb_last_bgsave_status:err* && $info == *rdb_bgsave_in_progress:0* ]] && { echo "Redis couldn't save (see: fawwk db logs $D_NAME)" >&2; exit 1; }
          if [[ $info == *rdb_bgsave_in_progress:0* ]] && (($(sed -n 's/^rdb_last_save_time://p' <<<"$info") > before)); then saved=1; break; fi
          sleep 0.5
        done
        ((saved)) || { echo "Redis didn't finish saving within 5 minutes" >&2; exit 1; }
        docker cp "$c:/data/dump.rdb" "$tmp" >/dev/null ;;
    esac
  ) || rc=$?
  if ((rc != 0)) || [[ ! -s $tmp ]]; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$file"
  printf '%s' "$file"
}

# Keeps the newest DB_KEEP_BACKUPS scheduled and pre-restore backups; manual ones stay until deleted.
db_prune_backups() {
  local kind f n
  for kind in scheduled pre-restore; do
    n=0
    while IFS= read -r f; do
      n=$((n + 1))
      ((n > DB_KEEP_BACKUPS)) && rm -f "$f"
    done < <(ls -1t "$(db_backups "$D_NAME")"/*-"$kind".* 2>/dev/null || true)
  done
  return 0
}

# The newest backup to restore from. Safety copies taken by a restore don't count: right after a
# restore, "latest" still means the backup you made, not the data you just replaced.
db_latest_backup() {
  find "$(db_backups "$1")" -maxdepth 1 -type f ! -name '*.partial' ! -name '*-pre-restore.*' -printf '%T@ %p\n' 2>/dev/null |
    sort -nr | head -n1 | cut -d' ' -f2- || true
}

# db_restore_file FILE — replaces the loaded database's data with FILE's.
db_restore_file() {
  local file=$1 c
  c=$(db_container "$D_NAME")
  case $D_TYPE in
    postgres)
      # A fresh, empty database first: `pg_restore --clean` alone would keep tables made after the backup.
      # WITH (FORCE) disconnects the apps using it; they reconnect once it's back.
      db_exec "$c" psql -q -v ON_ERROR_STOP=1 -U "$D_USER" -h 127.0.0.1 -d postgres \
        -c "DROP DATABASE IF EXISTS \"$D_DATABASE\" WITH (FORCE)" -c "CREATE DATABASE \"$D_DATABASE\" OWNER \"$D_USER\"" &&
        db_exec -i "$c" pg_restore -U "$D_USER" -h 127.0.0.1 -d "$D_DATABASE" --no-owner --exit-on-error <"$file" ;;
    mongodb)
      # Drop every app database first (admin, config and local stay: they hold users and server state),
      # so collections made after the backup don't survive the restore.
      db_exec "$c" mongosh --quiet -u "$D_USER" -p "$D_PASSWORD" --authenticationDatabase admin --eval '
        db.adminCommand({listDatabases: 1}).databases.map(d => d.name)
          .filter(n => !["admin", "config", "local"].includes(n))
          .forEach(n => db.getSiblingDB(n).dropDatabase())' >/dev/null &&
        db_exec -i "$c" mongorestore --quiet --archive --gzip --drop --nsExclude 'admin.*' --nsExclude 'config.*' \
          -u "$D_USER" -p "$D_PASSWORD" --authenticationDatabase admin <"$file" ;;
    redis)
      # With appendonly on and no append-only file, Redis 7 starts empty instead of loading the
      # snapshot. So: load it in a throwaway Redis with appendonly off, switch appendonly on there
      # (Redis writes a fresh append-only file from the loaded data), shut it down, start the real one.
      local v t info i
      v=$(db_volume "$D_NAME") t="fawwk-db-$D_NAME-restore"
      docker stop -t 10 "$c" >/dev/null
      docker run --rm -v "$v:/data" --entrypoint sh "$D_IMAGE" -c 'rm -rf /data/appendonlydir /data/dump.rdb' >/dev/null
      docker cp "$file" "$c:/data/dump.rdb" >/dev/null
      docker run -d --rm --name "$t" --network none -v "$v:/data" "$D_IMAGE" redis-server --appendonly no >/dev/null
      for i in $(seq 1 60); do [[ $(docker exec "$t" redis-cli ping 2>/dev/null) == PONG ]] && break; sleep 0.5; done
      docker exec "$t" redis-cli CONFIG SET appendonly yes >/dev/null
      for i in $(seq 1 600); do
        info=$(docker exec "$t" redis-cli INFO persistence 2>/dev/null | tr -d '\r')
        [[ $info == *aof_enabled:1* && $info == *aof_rewrite_in_progress:0* && $info == *aof_rewrite_scheduled:0* ]] && break
        sleep 0.5
      done
      docker exec "$t" redis-cli SHUTDOWN >/dev/null 2>&1 || true
      for i in $(seq 1 60); do docker inspect "$t" >/dev/null 2>&1 || break; sleep 0.5; done
      docker start "$c" >/dev/null
      db_wait_ready 60 ;;
  esac
}

# Redis forks to save in the background; without memory overcommit that fork can fail on a busy
# server. Redis asks for vm.overcommit_memory=1, so set it (and keep it across reboots).
db_redis_overcommit() {
  [[ $(cat /proc/sys/vm/overcommit_memory 2>/dev/null) == 1 ]] && return 0
  if sysctl -q -w vm.overcommit_memory=1 >/dev/null 2>&1; then
    printf 'vm.overcommit_memory = 1\n' >/etc/sysctl.d/90-fawwk-redis.conf 2>/dev/null || true
    ok "Enabled vm.overcommit_memory, which Redis needs for reliable background saves"
  else
    warn "Couldn't set vm.overcommit_memory=1; Redis background saves may fail under memory pressure."
  fi
}

# ---------- daily backups ----------
db_timer_ensure() {
  local at=${DB_BACKUP_AT:-03:17}
  if [[ $at == off ]]; then
    systemctl disable --now fawwk-db-backup.timer >/dev/null 2>&1 || true
    return 0
  fi
  cat >"$SYSTEMD_DIR/fawwk-db-backup.service" <<EOF
[Unit]
Description=Fawwk: back up managed databases
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$FAWWK_HOME/bin/fawwk db backup --all --scheduled
EOF
  cat >"$SYSTEMD_DIR/fawwk-db-backup.timer" <<EOF
[Unit]
Description=Fawwk: daily database backups

[Timer]
OnCalendar=*-*-* $at:00
Persistent=true
RandomizedDelaySec=120

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now fawwk-db-backup.timer >/dev/null 2>&1 || true
}

# ---------- linking ----------
# db_links_add APP VAR / db_links_remove APP — D_LINKS is "app:VAR app2:VAR2".
db_links_add() {
  local l out=()
  for l in $D_LINKS; do [[ ${l%%:*} == "$1" ]] || out+=("$l"); done
  out+=("$1:$2")
  db_set D_LINKS "${out[*]}"
}
db_links_remove() {
  local l out=()
  for l in $D_LINKS; do [[ ${l%%:*} == "$1" ]] || out+=("$l"); done
  db_set D_LINKS "${out[*]-}"
}

# ---------- `fawwk db` ----------
db_usage() {
  cat <<'EOF'
Usage: sudo fawwk db [command]

  (none) | list                     Databases, state and last backup
  create <name> [options]           Start a new database
      --type postgres|redis|mongodb   (default: postgres)
      --version <v>                   e.g. 16 for Postgres 16 (default: 17, Redis 7, MongoDB 7.0)
      --memory <size>                 memory limit, e.g. 512m
      --link <app> [--as VAR]         give an app its URL (default var: DATABASE_URL,
                                      REDIS_URL or MONGODB_URL)
  info <name> [--reveal]            Details and connection URL (password masked)
  url <name>                        Print the connection URL
  link <name> <app> [--as VAR]      Set the URL as an env var of an app
  unlink <name> <app>               Remove it again
  shell <name>                      psql, redis-cli or mongosh inside the database
  backup <name> | --all             Back up now (kept until you delete it)
  backups <name>                    List backups
  restore <name> <file|latest>      Replace the data with a backup (a safety backup is taken first)
  schedule [HH:MM | off]            Daily backup time (default 03:17); keeps the last 7 (DB_KEEP_BACKUPS)
  start | stop | restart <name>|--all
  logs <name> [-f]
  remove <name> [--yes] [--keep-data]

Databases are only reachable by your apps (as fawwk-db-<name>), never from the internet.
EOF
}

cmd_db() {
  local sub=${1:-list}
  (($#)) && shift
  case $sub in -h | --help | help) db_usage; return 0 ;; esac
  require_root db; require_setup
  case $sub in
    list | ls) db_list "$@" ;;
    create | new | add) db_create "$@" ;;
    info | show) db_info "$@" ;;
    url) db_require "${1-}"; db_url; echo ;;
    link) db_link "$@" ;;
    unlink) db_unlink "$@" ;;
    shell | psql | cli) db_shell "$@" ;;
    backup) db_backup_cmd "$@" ;;
    backups) db_backups_list "$@" ;;
    restore) db_restore_cmd "$@" ;;
    schedule) db_schedule "$@" ;;
    start | stop | restart) db_power "$sub" "$@" ;;
    logs | log) db_logs "$@" ;;
    remove | rm | delete) db_remove "$@" ;;
    *) db_usage; return 1 ;;
  esac
}

db_require() { [[ -n ${1-} ]] || die "Which database? See: fawwk db"; db_load "$1"; }

db_list() {
  local name n=0 last
  printf '\n  %s%-20s %-11s %-12s %-20s %s%s\n' "$C_MUTED" NAME STATE TYPE "LAST BACKUP" "USED BY" "$C_RESET"
  while IFS= read -r name; do
    [[ -z $name ]] && continue
    n=$((n + 1))
    db_load "$name"
    last=$(db_latest_backup "$name")
    [[ -n $last ]] && last=$(date -r "$last" '+%Y-%m-%d %H:%M')
    printf '  %s%-20s%s %s %-12s %-20s %s\n' "$C_BOLD" "$name" "$C_RESET" "$(state_color "$(db_state)")" \
      "$D_TYPE $D_VERSION" "${last:-never}" "$(db_links_text)"
  done < <(db_names)
  printf '\n'
  ((n)) || hint "No databases yet. Create one with: sudo fawwk db create <name> --type postgres|redis|mongodb"
}

# "api, worker" — apps linked to the loaded database that still exist.
db_links_text() {
  local l out=()
  for l in $D_LINKS; do app_exists "${l%%:*}" && out+=("${l%%:*}"); done
  local IFS=,
  printf '%s' "${out[*]:--}"
}

db_create() {
  local name='' type=postgres version='' memory='' link='' as=''
  while (($#)); do
    case $1 in
      --type) need_arg "$@"; type=${2,,}; shift 2 ;;
      --version) need_arg "$@"; version=$2; shift 2 ;;
      --memory) need_arg "$@"; memory=${2,,}; shift 2 ;;
      --link) need_arg "$@"; link=$2; shift 2 ;;
      --as) need_arg "$@"; as=$2; shift 2 ;;
      -*) die "Unknown option: $1 (see: fawwk db --help)" ;;
      *) [[ -z $name ]] && name=$1 || die "Unexpected argument: $1"; shift ;;
    esac
  done
  [[ $type == postgresql || $type == pg ]] && type=postgres
  [[ $type == mongo ]] && type=mongodb
  [[ $type =~ ^(postgres|redis|mongodb)$ ]] || die "--type must be postgres, redis or mongodb"
  [[ -n $name ]] || ask name "Database name" "$type" valid_app_name
  valid_app_name "$name" || exit 1
  db_exists "$name" && die "A database named '$name' already exists."
  version=${version:-$(db_default_version "$type")}
  [[ $version =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "--version must look like 16 or 7.4"
  [[ -z $memory || $memory =~ ^[0-9]+[mg]$ ]] || die "--memory must look like 512m or 2g"
  [[ -z $link ]] || app_exists "$link" || die "No app named '$link'. See: fawwk list"
  [[ -z $as || $as =~ $RE_ENV_KEY ]] || die "--as must be an env var name, e.g. DATABASE_URL"
  docker volume inspect "$(db_volume "$name")" >/dev/null 2>&1 &&
    die "A volume $(db_volume "$name") is left from an earlier database. Remove it first: docker volume rm $(db_volume "$name")"

  local d
  d=$(db_dir "$name")
  mkdir -p "$d"; chmod 700 "$DBS_ETC" "$d"
  local v
  for v in "${DB_FIELDS[@]}"; do printf -v "$v" '%s' ''; done
  D_NAME=$name D_TYPE=$type D_VERSION=$version D_IMAGE=$(db_image_for "$type" "$version") D_MEMORY=$memory
  D_USER=${name//-/_} D_DATABASE=${name//-/_} D_PASSWORD=$(openssl rand -hex 24) D_CREATED=$(ts)
  [[ $type == redis ]] && D_USER=default
  for v in "${DB_FIELDS[@]}"; do conf_set "$d/db.conf" "$v" "${!v}"; done

  step "Creating $(db_label "$type") $version database '$name'"
  [[ $type == redis ]] && db_redis_overcommit
  spin_start "Pulling $D_IMAGE"
  docker image inspect "$D_IMAGE" >/dev/null 2>&1 || docker pull -q "$D_IMAGE" >/dev/null 2>&1 || {
    spin_stop; rm -rf "$d"; die "Couldn't pull $D_IMAGE. Check the version exists."; }
  spin_stop
  if [[ $type == mongodb ]] && mongo_refuses_kernel "$D_IMAGE"; then
    rm -rf "$d"
    die "MongoDB $version won't run on this server's Linux kernel ($(kernel_version)): it refuses kernel 6.19 and newer (MongoDB issue SERVER-121912). Use a version that does: --version 7.0"
  fi
  spin_start "Starting it"
  if ! db_run || ! db_wait_ready 120; then
    spin_stop
    err "The database didn't start. Its last log lines:"
    docker logs --tail 20 "$(db_container "$name")" 2>&1 | ui_quote
    info "Container: $(docker inspect -f 'status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} restarts={{.RestartCount}}' "$(db_container "$name")" 2>&1)"
    info "Readiness check said: $(db_ready_output 2>&1 | tail -n 3 | tr '\n' ' ')"
    # MongoDB 5+ dies with an illegal instruction (exit 132) on CPUs without AVX.
    if [[ $type == mongodb ]] && { [[ $(docker inspect -f '{{.State.ExitCode}}' "$(db_container "$name")" 2>/dev/null) == 132 ]] ||
      docker logs --tail 50 "$(db_container "$name")" 2>&1 | grep -qiE 'illegal instruction|AVX'; }; then
      hint "This CPU lacks AVX, which MongoDB 5 and newer need. Try: --version 4.4"
    fi
    docker rm -f "$(db_container "$name")" >/dev/null 2>&1 || true
    docker volume rm "$(db_volume "$name")" >/dev/null 2>&1 || true
    rm -rf "$d"
    die "Nothing was kept. Fix the issue above and try again."
  fi
  spin_stop
  ok "$(db_label "$type") $version is running as $(db_container "$name") ${C_MUTED}(reachable only from your apps)${C_RESET}"
  db_timer_ensure
  [[ ${DB_BACKUP_AT:-03:17} == off ]] || ok "Backed up daily at ${DB_BACKUP_AT:-03:17} (last $DB_KEEP_BACKUPS kept)"
  if [[ -n $link ]]; then
    db_link_apply "$link" "${as:-$(db_default_var "$type")}"
  else
    hint "Give an app its URL: fawwk db link $name <app>   (sets $(db_default_var "$type"))"
  fi
}

db_info() {
  db_require "${1-}"
  local reveal=0 last
  [[ ${2-} == --reveal ]] && reveal=1
  printf '\n%s%s%s %s%s%s  %s\n\n' "$C_ACCENT" "$G_STEP" "$C_RESET" "$C_BOLD" "$D_NAME" "$C_RESET" "$(state_color "$(db_state)")"
  k() { printf '  %s%-14s%s %s\n' "$C_MUTED" "$1" "$C_RESET" "$2"; }
  k Type "$(db_label "$D_TYPE") $D_VERSION ($D_IMAGE)"
  k Host "$(db_container "$D_NAME"):$(db_port "$D_TYPE") ${C_MUTED}(fawwk network only)${C_RESET}"
  if ((reveal)); then k URL "$(db_url)"; else k URL "$(db_url_masked)  ${C_MUTED}(--reveal shows the password)${C_RESET}"; fi
  k "Used by" "$(db_links_text)"
  k Memory "${D_MEMORY:-unlimited}"
  k Volume "$(db_volume "$D_NAME")"
  last=$(db_latest_backup "$D_NAME")
  k "Last backup" "${last:-never}"
  k Schedule "$([[ ${DB_BACKUP_AT:-03:17} == off ]] && echo off || echo "daily at ${DB_BACKUP_AT:-03:17}, last $DB_KEEP_BACKUPS kept")"
  k Created "$D_CREATED"
  printf '\n'
  unset -f k
}

# db_link_apply APP VAR — sets the loaded database's URL on APP and offers a restart.
db_link_apply() {
  local app=$1 var=$2 tmp
  tmp=$(mktemp)
  printf '%s=%s\n' "$var" "$(db_url)" >"$tmp"
  env_save "$app" "$tmp"
  rm -f "$tmp"
  db_links_add "$app" "$var"
  ok "$app gets $var (the $D_NAME connection URL)"
  (
    app_load "$app"
    [[ $(app_live_state) == running ]] || exit 0
    if confirm "Restart $app now so it picks up $var? (zero downtime)" Y; then
      app_load_locked "$app"; restart_app && ok "$app restarted"
    else
      info "Apply later with: fawwk restart $app"
    fi
  )
}

db_link() {
  local name=${1-} app=${2-} as=''
  [[ ${3-} == --as ]] && as=${4-}
  [[ -n $name && -n $app ]] || die "Usage: fawwk db link <database> <app> [--as VAR]"
  db_load "$name"
  app_exists "$app" || die "No app named '$app'. See: fawwk list"
  [[ -z $as || $as =~ $RE_ENV_KEY ]] || die "--as must be an env var name, e.g. DATABASE_URL"
  db_link_apply "$app" "${as:-$(db_default_var "$D_TYPE")}"
}

db_unlink() {
  local name=${1-} app=${2-} l var=''
  [[ -n $name && -n $app ]] || die "Usage: fawwk db unlink <database> <app>"
  db_load "$name"
  for l in $D_LINKS; do [[ ${l%%:*} == "$app" ]] && var=${l#*:}; done
  [[ -n $var ]] || die "$app isn't linked to $name."
  app_exists "$app" && env_unset "$app" "$var"
  db_links_remove "$app"
  ok "Removed $var from $app (restart it to apply: fawwk restart $app)"
}

db_shell() {
  db_require "${1-}"
  [[ $(db_state) == running ]] || die "$D_NAME isn't running. Start it: fawwk db start $D_NAME"
  local c tty=(-i)
  c=$(db_container "$D_NAME")
  [[ -t 0 ]] && tty=(-it)
  case $D_TYPE in
    postgres) db_exec "${tty[@]}" "$c" psql -U "$D_USER" -h 127.0.0.1 "$D_DATABASE" ;;
    redis) db_exec "${tty[@]}" "$c" redis-cli ;;
    mongodb) db_exec "${tty[@]}" "$c" mongosh --quiet -u "$D_USER" -p "$D_PASSWORD" --authenticationDatabase admin "$D_DATABASE" ;;
  esac
}

db_backup_cmd() {
  local target=${1-} scheduled=0 names=() name file failed=()
  [[ ${2-} == --scheduled || ${1-} == --scheduled ]] && scheduled=1
  if [[ $target == --all || $target == --scheduled ]]; then mapfile -t names < <(db_names)
  else [[ -n $target ]] || die "Usage: fawwk db backup <name> | --all"; db_load "$target"; names=("$target")
  fi
  for name in "${names[@]}"; do
    [[ -z $name ]] && continue
    db_load "$name"
    if [[ $(db_state) != running ]]; then
      warn "$name isn't running; skipped"
      failed+=("$name")
      continue
    fi
    if file=$(db_backup_now "$([[ $scheduled == 1 ]] && echo scheduled || echo manual)"); then
      ok "$name $G_ARROW $file ($(du -h "$file" | cut -f1))"
      db_prune_backups
    else
      err "Backup of $name failed"
      failed+=("$name")
    fi
  done
  if ((${#failed[@]})); then
    ((scheduled)) && notify failed "${failed[*]}" '' "$G_ERR Database backup failed on $(hostname): ${failed[*]}. Check: fawwk db"
    FAWWK_DIED=1; exit 1
  fi
}

db_backups_list() {
  db_require "${1-}"
  local f n=0
  while IFS= read -r f; do
    [[ -z $f || $f == *.partial ]] && continue
    n=$((n + 1))
    printf '  %-60s %8s  %s\n' "$f" "$(du -h "$f" | cut -f1)" "$(date -r "$f" '+%Y-%m-%d %H:%M')"
  done < <(ls -1t "$(db_backups "$D_NAME")"/*.* 2>/dev/null || true)
  ((n)) || info "No backups of $D_NAME yet. Make one: fawwk db backup $D_NAME"
}

db_restore_cmd() {
  local name=${1-} file=${2-} yes=0 a safety
  for a in "$@"; do [[ $a == --yes || $a == -y ]] && yes=1; done
  [[ -n $name && -n $file ]] || die "Usage: fawwk db restore <name> <file|latest> [--yes]"
  db_load "$name"
  [[ $file == latest ]] && { file=$(db_latest_backup "$name"); [[ -n $file ]] || die "No backups of $name yet."; }
  [[ -f $file ]] || die "File not found: $file"
  [[ $(db_state) == running ]] || die "$name isn't running. Start it: fawwk db start $name"
  warn "This replaces everything in $name with the backup ${file##*/}."
  if ((yes == 0)); then confirm "Continue?" N || die "Cancelled. Nothing changed."; fi
  step "Restoring $name"
  mkdir -p "$FAWWK_LOG"
  if [[ -n $(docker run --rm -v "$(db_volume "$name"):/v" --entrypoint sh "$D_IMAGE" -c 'ls -A /v' 2>/dev/null) ]]; then
    safety=$(db_backup_now pre-restore) || die "Couldn't take a safety backup first, so nothing was changed."
    ok "Safety backup of the current data: $safety"
  fi
  spin_start "Restoring ${file##*/}"
  if ! db_restore_file "$file" >"$FAWWK_LOG/db-restore-$name.log" 2>&1; then
    spin_stop
    err "Restore failed. Last lines:"
    tail -n 15 "$FAWWK_LOG/db-restore-$name.log" | ui_quote
    [[ -n ${safety-} ]] && hint "Go back to the data from before: fawwk db restore $name $safety"
    FAWWK_DIED=1; exit 1
  fi
  spin_stop
  ok "$name now holds the data from ${file##*/}"
}

db_schedule() {
  local at=${1-}
  if [[ -z $at ]]; then
    info "Daily database backups: ${DB_BACKUP_AT:-03:17} (keeps the last $DB_KEEP_BACKUPS per database)"
    hint "Change: fawwk db schedule 02:30   $G_SEP   turn off: fawwk db schedule off"
    return 0
  fi
  [[ $at == off || $at =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "Use a time like 02:30 (24-hour), or off"
  conf_set "$FAWWK_CONF" DB_BACKUP_AT "$at"
  DB_BACKUP_AT=$at
  db_timer_ensure
  ok "Daily database backups: $at"
}

db_power() {
  local action=$1 target=${2-} names=() name
  [[ -n $target ]] || die "Usage: fawwk db $action <name> | --all"
  if [[ $target == --all ]]; then mapfile -t names < <(db_names); else db_load "$target"; names=("$target"); fi
  for name in "${names[@]}"; do
    [[ -z $name ]] && continue
    db_load "$name"
    case $action in
      stop) docker stop -t 30 "$(db_container "$name")" >/dev/null 2>&1 || true; ok "$name stopped" ;;
      start | restart)
        [[ $action == restart ]] && docker restart -t 30 "$(db_container "$name")" >/dev/null 2>&1
        db_run && db_wait_ready 120 && ok "$name is running" || err "$name didn't start: fawwk db logs $name" ;;
    esac
  done
  [[ $action == stop ]] || db_timer_ensure
}

db_logs() {
  db_require "${1-}"
  local follow=()
  [[ ${2-} == -f || ${2-} == --follow ]] && follow=(-f)
  docker logs --tail 100 "${follow[@]}" "$(db_container "$D_NAME")"
}

db_remove() {
  local name='' yes=0 keep=0 a
  for a in "$@"; do
    case $a in -y | --yes) yes=1 ;; --keep-data) keep=1 ;; *) name=$a ;; esac
  done
  db_require "$name"
  if ((yes == 0)); then
    is_interactive || die "Add --yes to remove without a prompt."
    warn "This deletes the database $name$( ((keep)) || echo ' and all its data')."
    [[ -n $(db_links_text | tr -d -) ]] && warn "Apps using it: $(db_links_text)"
    local typed
    read -r -p "  ${C_RED}${G_PROMPT}${C_RESET} Type ${C_BOLD}$name${C_RESET} to confirm: " typed
    [[ $typed == "$name" ]] || die "Cancelled."
  fi
  docker rm -f "$(db_container "$name")" >/dev/null 2>&1 || true
  if ((keep)); then
    info "Data kept in docker volume $(db_volume "$name"); backups in $(db_backups "$name")"
  else
    docker volume rm "$(db_volume "$name")" >/dev/null 2>&1 || true
    info "Backups are kept in $(db_backups "$name") (delete them yourself when you're sure)"
  fi
  rm -rf "$(db_dir "$name")"
  ok "Database $name removed"
  [[ -n $(db_names) ]] || systemctl disable --now fawwk-db-backup.timer >/dev/null 2>&1 || true
}
