#!/usr/bin/env bash
# fawwk — building images: Dockerfile, static sites, or auto-detected with Nixpacks.

STATIC_PORT=8080

build_context() {
  local src
  src="$(app_var "$A_NAME")/src"
  if [[ -z $A_DIR || $A_DIR == . ]]; then printf '%s' "$src"; else printf '%s/%s' "$src" "$A_DIR"; fi
}

# build_dockerfile DIR — prints the path of the folder's Dockerfile, whatever its casing
# (Dockerfile, DOCKERFILE, dockerfile...). Linux is case-sensitive and Docker only looks for
# "Dockerfile" by itself, so other spellings are passed to it with -f.
build_dockerfile() {
  local d=$1 f b
  [[ -f $d/Dockerfile ]] && { printf '%s' "$d/Dockerfile"; return 0; }
  for f in "$d"/*; do
    b=${f##*/}
    [[ -f $f && ${b,,} == dockerfile ]] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

# build_dockerfile_missing DIR — prints (one per line) files the Dockerfile COPYs or ADDs that aren't
# in the repo, e.g. a lock file that was never committed. Such a Dockerfile can't build.
build_dockerfile_missing() {
  local d=$1 df line rest t srcs toks i
  df=$(build_dockerfile "$d") || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ ${line^^} =~ ^[[:space:]]*(COPY|ADD)[[:space:]] ]] || continue
    rest=${line#*[[:space:]]}
    [[ $rest == *--from* || $rest == *'<<'* || $rest =~ ^[[:space:]]*\[ ]] && continue
    srcs=()
    read -ra toks <<<"$rest"
    for t in "${toks[@]}"; do [[ $t == --* ]] || srcs+=("$t"); done
    for ((i = 0; i < ${#srcs[@]} - 1; i++)); do
      t=${srcs[i]}
      [[ $t == *[*?\[]* || $t == *'$'* || $t == *://* ]] && continue
      [[ -e $d/$t ]] || printf '%s\n' "$t"
    done
  done <"$df"
}

# build_detect DIR -> dockerfile | static | nixpacks
# The builder for a repo with no Dockerfile: Railpack when installed, else Nixpacks (servers set up
# before Railpack support), else Railpack (so the error says what to install).
build_auto_builder() {
  if command -v railpack >/dev/null 2>&1; then echo railpack
  elif command -v nixpacks >/dev/null 2>&1; then echo nixpacks
  else echo railpack
  fi
}

# build_detect DIR -> dockerfile | static | railpack | nixpacks
build_detect() {
  local d=$1
  if build_dockerfile "$d" >/dev/null; then echo dockerfile
  elif [[ -f $d/index.html && ! -f $d/package.json ]]; then echo static
  else build_auto_builder
  fi
}

# build_tool_missing TYPE — prints why TYPE can't build on this server (empty if it can).
build_tool_missing() {
  case $1 in
    railpack) command -v railpack >/dev/null 2>&1 || echo "Railpack isn't installed. Re-run: sudo fawwk setup (or add a Dockerfile to the repo)" ;;
    nixpacks) command -v nixpacks >/dev/null 2>&1 || echo "Nixpacks isn't installed. Use: fawwk build <app> railpack (or add a Dockerfile)" ;;
  esac
  return 0
}

# The version of the installed railpack CLI, e.g. 0.43.0 (its frontend image must match).
railpack_version() { railpack --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1; }

# build_describe TYPE [DIR]
# build_describe TYPE [DIR]
build_describe() {
  local name=Dockerfile f
  if [[ -n ${2-} ]] && f=$(build_dockerfile "$2"); then name=${f##*/}; else name=''; fi
  case $1 in
    dockerfile)
      if [[ $name == Dockerfile ]]; then echo "Dockerfile found, building with Docker"
      else echo "${name:-Dockerfile} found, building with Docker (tip: rename it to 'Dockerfile', the standard name)"
      fi ;;
    static)     echo "Static site (index.html), served by Caddy" ;;
    railpack | nixpacks)
      local tool=Railpack
      [[ $1 == nixpacks ]] && tool=Nixpacks
      if [[ -n $name ]]; then echo "Building with $tool (auto-detects the stack; $name is ignored)"
      else echo "No Dockerfile, auto-detecting the stack with $tool"
      fi ;;
  esac
}

# build_resolve DIR TYPE — the build type to actually use ("auto": a Dockerfile always wins).
build_resolve() {
  local type=${2:-auto}
  [[ $type == auto ]] && type=$(build_detect "$1")
  printf '%s' "$type"
}

# Warns about a Dockerfile that can't build; used by create and before every Dockerfile build.
build_warn_dockerfile() {
  local d=$1 missing name
  missing=$(build_dockerfile_missing "$d")
  [[ -n $missing ]] || return 0
  name=$(build_dockerfile "$d"); name=${name##*/}
  missing=$(printf '%s' "$missing" | paste -sd, - | sed 's/,/, /g')
  warn "$name copies $missing, which isn't in the repo, so a Docker build would fail."
  return 1
}

# Best guess at the port the app listens on.
# Best guess at the port the app listens on.
build_port_hint() {
  local d=$1 type=$2 p=''
  case $type in
    static) p=$STATIC_PORT ;;
    dockerfile) p=$(grep -iE '^[[:space:]]*EXPOSE[[:space:]]+[0-9]+' "$(build_dockerfile "$d" || true)" 2>/dev/null | head -n1 | grep -oE '[0-9]+' | head -n1 || true) ;;
    railpack | nixpacks)
      if [[ -f $d/package.json ]]; then p=3000
      elif [[ -f $d/requirements.txt || -f $d/pyproject.toml ]]; then p=8000
      elif [[ -f $d/go.mod ]]; then p=8080
      fi ;;
  esac
  printf '%s' "${p:-3000}"
}

# Writes a Dockerfile (outside the repo) that serves the folder with Caddy, SPA-friendly.
build_static_dockerfile() {
  local f=$1
  cat >"$f" <<EOF
FROM $CADDY_STATIC_IMAGE
COPY . /srv
RUN printf ':$STATIC_PORT {\n\troot * /srv\n\tencode zstd gzip\n\ttry_files {path} {path}/ {path}.html /index.html\n\tfile_server\n}\n' > /etc/caddy/Caddyfile
EXPOSE $STATIC_PORT
EOF
  printf '.git\n.github\n.env\n.env.*\nnode_modules\n' >"$f.dockerignore"
}

# build_env_allowed KEY — 0 if the app's env var KEY is passed to the build (A_BUILD_ENV:
# empty or "all" = every variable, "none" = no variable, otherwise a list of keys).
build_env_allowed() {
  case ${A_BUILD_ENV:-all} in
    all) return 0 ;;
    none) return 1 ;;
  esac
  [[ " ${A_BUILD_ENV//,/ } " == *" $1 "* ]]
}

# build_image DEPLOY_ID LOGFILE — builds fawwk/<app>:<id>. Sets BUILT_IMAGE.
# build_dockerfile_with_args SRC OUT KEY... — writes SRC to OUT with `ARG KEY` declarations added, so
# build-time env vars reach the build's RUN steps without the repo declaring them (Docker only exposes
# a --build-arg to a stage that declares it; Coolify adds these lines the same way, so Dockerfiles
# written for it work unchanged). The ARGs go after every FROM except the last: in a multi-stage build
# the last stage only ships the output, and BuildKit writes the build args a RUN step sees into the
# image's history, so values (tokens included) must not reach it. A single-stage Dockerfile gets them
# in its one stage. Keys a stage already declares are left alone.
build_dockerfile_with_args() {
  local src=$1 out=$2
  shift 2
  awk -v keys="$*" '
    BEGIN { n = split(keys, k, " ") }
    # Pass 1: count stages and note which ARGs each one declares.
    NR == FNR {
      if (toupper($0) ~ /^[[:space:]]*FROM[[:space:]]/) stages++
      else if (stages && toupper($0) ~ /^[[:space:]]*ARG[[:space:]]/) {
        line = $0; sub(/^[[:space:]]*[Aa][Rr][Gg][[:space:]]+/, "", line)
        m = split(line, a, /[[:space:]]+/)
        for (j = 1; j <= m; j++) { sub(/=.*/, "", a[j]); if (a[j] != "") declared[stages, a[j]] = 1 }
      }
      next
    }
    # Pass 2: copy, adding the ARGs after each FROM (and its continuation lines) that gets them.
    {
      print
      if (toupper($0) ~ /^[[:space:]]*FROM[[:space:]]/) { stage++; pending = (stage < stages || stages == 1) }
      if (pending && $0 !~ /\\[[:space:]]*$/) {
        pending = 0
        for (j = 1; j <= n; j++) if (!((stage, k[j]) in declared)) print "ARG " k[j]
      }
    }' "$src" "$src" >"$out"
  # A Dockerfile-specific ignore file (Dockerfile.dockerignore) must follow it to its new name.
  if [[ -f $src.dockerignore ]]; then cp -f "$src.dockerignore" "$out.dockerignore"; else rm -f "$out.dockerignore"; fi
}

# build_env_keys — the loaded app's env var names that go to the build (see fawwk buildenv), one per
# line: single-line ones, then multi-line ones prefixed with "ml ".
build_env_keys() {
  local envf kv k
  envf=$(app_envfile "$A_NAME")
  if [[ -f $envf ]]; then
    while IFS= read -r kv; do
      k=${kv%%=*}
      [[ -n $kv ]] && build_env_allowed "$k" && printf '%s\n' "$k"
    done <"$envf"
  fi
  while IFS= read -r k; do build_env_allowed "$k" && printf 'ml %s\n' "$k"; done < <(env_ml_keys "$envf")
  return 0
}

# build_railpack CTX IMAGE KEY... — plan with `railpack prepare`, then build the plan through
# Railpack's BuildKit frontend with Docker's own BuildKit (no extra BuildKit container). Build-time
# env goes in as BuildKit secrets: available to build steps, never written into the image.
# Uses build_image's nocache array.
build_railpack() {
  local ctx=$1 image=$2 ver plan info rc k prep=() secrets=() hash
  shift 2
  ver=$(railpack_version)
  [[ -n $ver ]] || { echo "Couldn't run railpack. Re-run: sudo fawwk setup"; return 1; }
  docker buildx version >/dev/null 2>&1 || { echo "docker buildx is missing. Install it with: apt-get install docker-buildx-plugin"; return 1; }
  plan="$(app_var "$A_NAME")/railpack-plan.json"
  info="$(app_var "$A_NAME")/railpack-info.json"
  for k in "$@"; do prep+=(--env "$k"); secrets+=(--secret "id=$k,env=$k"); done
  echo "==> railpack $ver: planning the build"
  rc=0
  railpack prepare "$ctx" --plan-out "$plan" --info-out "$info" "${prep[@]}" || rc=$?
  # Exit 75 is a transient failure (e.g. a download): Railpack says to retry it.
  if ((rc == 75)); then echo "==> transient error, retrying"; rc=0; railpack prepare "$ctx" --plan-out "$plan" --info-out "$info" "${prep[@]}" || rc=$?; fi
  ((rc == 0)) || { echo "railpack couldn't plan this repo (exit $rc). Add a Dockerfile, or see https://railpack.com/config/file"; return 1; }
  # Layers that used a secret are rebuilt when a value changes.
  hash=$(for k in "$@"; do printf '%s=%s\n' "$k" "${!k}"; done | sha256sum | cut -d' ' -f1)
  echo "==> building with $RAILPACK_FRONTEND:v$ver"
  docker buildx build --progress=plain "${nocache[@]}" \
    --build-arg BUILDKIT_SYNTAX="$RAILPACK_FRONTEND:v$ver" \
    --build-arg secrets-hash="$hash" --build-arg cache-key="fawwk-$A_NAME" \
    "${secrets[@]}" -f "$plan" -t "$image" "$ctx"
}

# build_image DEPLOY_ID LOGFILE — builds fawwk/<app>:<id>. Sets BUILT_IMAGE.
build_image() {
  local id=$1 log=$2 ctx type image envf missing line keys=() ml=() nocache=()
  ctx=$(build_context)
  image="fawwk/$A_NAME:$id"
  envf=$(app_envfile "$A_NAME")
  [[ -d $ctx ]] || { err "Folder '$A_DIR' doesn't exist in the repo."; return 1; }

  type=$(build_resolve "$ctx" "${A_BUILD:-auto}")
  [[ $type == dockerfile ]] && { build_warn_dockerfile "$ctx" || true; }
  info "$(build_describe "$type" "$ctx")"
  missing=$(build_tool_missing "$type")
  [[ -z $missing ]] || { err "$missing"; return 1; }

  # App env is available at build time too (needed by e.g. Next.js NEXT_PUBLIC_* vars), unless
  # `fawwk buildenv` limits it. Builders get variable names; the values are exported into the build's
  # environment, so they never appear on a command line. Images stay on this server.
  while IFS= read -r line; do
    if [[ $line == 'ml '* ]]; then ml+=("${line#ml }"); keys+=("${line#ml }"); else keys+=("$line"); fi
  done < <(build_env_keys)
  if [[ $type == nixpacks && ${#ml[@]} -gt 0 ]]; then
    warn "Nixpacks can't take multi-line values at build time; not passed: ${ml[*]} (Railpack can: fawwk build $A_NAME railpack)"
  fi

  # Every step from scratch: for a Dockerfile that fetches things the cache can't see change
  # (`fawwk build <app> cache off`), or once (`fawwk deploy <app> --no-cache`).
  if [[ ${A_BUILD_CACHE:-on} == off || -n ${FAWWK_NO_CACHE-} ]]; then
    nocache=(--no-cache)
    info "Building without the cache"
  fi

  (
    ((${#nocache[@]})) && echo "==> building without the cache"
    # The values, for the names passed below.
    if [[ -f $envf ]]; then
      while IFS= read -r line; do
        [[ -n $line ]] && build_env_allowed "${line%%=*}" && export "${line?}"
      done <"$envf"
    fi
    env_export_multiline "$envf"
    case $type in
      dockerfile)
        local dfile gen args=() k
        dfile=$(build_dockerfile "$ctx") || { echo "No Dockerfile in '${A_DIR:-.}' (build type is set to dockerfile)"; exit 1; }
        for k in "${keys[@]}"; do args+=(--build-arg "$k"); done
        if ((${#keys[@]})); then
          # A copy with ARG lines for the build-time vars (outside the repo; see build_dockerfile_with_args).
          gen="$(app_var "$A_NAME")/Dockerfile.fawwk"
          build_dockerfile_with_args "$dfile" "$gen" "${keys[@]}"
          dfile=$gen
        fi
        DOCKER_BUILDKIT=1 docker build --progress=plain "${nocache[@]}" -t "$image" -f "$dfile" "${args[@]}" "$ctx" ;;
      static)
        local df
        df="$(app_var "$A_NAME")/static.Dockerfile"
        build_static_dockerfile "$df"
        DOCKER_BUILDKIT=1 docker build --progress=plain "${nocache[@]}" -t "$image" -f "$df" "$ctx" ;;
      railpack)
        build_railpack "$ctx" "$image" "${keys[@]}" ;;
      nixpacks)
        local args=() k
        # Nixpacks writes --env values into the image; it gets single-line values only.
        for k in "${keys[@]}"; do [[ " ${ml[*]} " == *" $k "* ]] || args+=(--env "$k=${!k}"); done
        nixpacks build "$ctx" --name "$image" "${nocache[@]}" "${args[@]}" ;;
      *)
        echo "Unknown build type: $type"; exit 1 ;;
    esac
  ) >>"$log" 2>&1 &
  local pid=$! t0=$SECONDS
  spin_start "Building $A_NAME" "$log"
  if ! wait "$pid"; then
    spin_stop
    err "Build failed after $((SECONDS - t0))s. Last lines of the build log:"
    tail -n 30 "$log" | ui_quote
    hint "Full log: $log"
    return 1
  fi
  spin_stop
  BUILT_IMAGE=$image
  ok "Built $image ${C_MUTED}in $((SECONDS - t0))s${C_RESET}"
}

# Removes old images for the app, keeping the newest KEEP_IMAGES plus the one running.
images_prune() {
  local tag n=0
  while IFS= read -r tag; do
    [[ -z $tag ]] && continue
    n=$((n + 1))
    ((n <= KEEP_IMAGES)) && continue
    [[ "fawwk/$A_NAME:$tag" == "$A_IMAGE" ]] && continue
    docker rmi "fawwk/$A_NAME:$tag" >/dev/null 2>&1 || true
  done < <(docker images "fawwk/$A_NAME" --format '{{.Tag}}' | sort -r)
}
