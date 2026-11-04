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
build_detect() {
  local d=$1
  if build_dockerfile "$d" >/dev/null; then echo dockerfile
  elif [[ -f $d/index.html && ! -f $d/package.json ]]; then echo static
  else echo nixpacks
  fi
}

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
    nixpacks)
      if [[ -n $name ]]; then echo "Building with Nixpacks (auto-detects the stack; $name is ignored)"
      else echo "No Dockerfile, auto-detecting the stack with Nixpacks"
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
build_port_hint() {
  local d=$1 type=$2 p=''
  case $type in
    static) p=$STATIC_PORT ;;
    dockerfile) p=$(grep -iE '^[[:space:]]*EXPOSE[[:space:]]+[0-9]+' "$(build_dockerfile "$d" || true)" 2>/dev/null | head -n1 | grep -oE '[0-9]+' | head -n1 || true) ;;
    nixpacks)
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
FROM caddy:2-alpine
COPY . /srv
RUN printf ':$STATIC_PORT {\n\troot * /srv\n\tencode zstd gzip\n\ttry_files {path} {path}/ {path}.html /index.html\n\tfile_server\n}\n' > /etc/caddy/Caddyfile
EXPOSE $STATIC_PORT
EOF
  printf '.git\n.github\n.env\n.env.*\nnode_modules\n' >"$f.dockerignore"
}

# build_image DEPLOY_ID LOGFILE — builds fawwk/<app>:<id>. Sets BUILT_IMAGE.
build_image() {
  local id=$1 log=$2 ctx type image envf kv args=()
  ctx=$(build_context)
  image="fawwk/$A_NAME:$id"
  envf=$(app_envfile "$A_NAME")
  [[ -d $ctx ]] || { err "Folder '$A_DIR' doesn't exist in the repo."; return 1; }

  type=$(build_resolve "$ctx" "${A_BUILD:-auto}")
  [[ $type == dockerfile ]] && { build_warn_dockerfile "$ctx" || true; }
  info "$(build_describe "$type" "$ctx")"

  # App env is available at build time too (needed by e.g. Next.js NEXT_PUBLIC_* vars).
  # Images stay on this server; they're never pushed anywhere.
  local flag=--build-arg
  [[ $type == nixpacks ]] && flag=--env
  if [[ -f $envf ]]; then
    while IFS= read -r kv; do [[ -n $kv ]] && args+=("$flag" "$kv"); done <"$envf"
  fi

  case $type in
    dockerfile)
      local dfile
      dfile=$(build_dockerfile "$ctx") || { echo "No Dockerfile in '${A_DIR:-.}' (build type is set to dockerfile)"; exit 1; }
      DOCKER_BUILDKIT=1 docker build --progress=plain -t "$image" -f "$dfile" "${args[@]}" "$ctx" ;;
    static)
      local df
      df="$(app_var "$A_NAME")/static.Dockerfile"
      build_static_dockerfile "$df"
      DOCKER_BUILDKIT=1 docker build --progress=plain -t "$image" -f "$df" "$ctx" ;;
    nixpacks)
      command -v nixpacks >/dev/null 2>&1 || { echo "Nixpacks isn't installed. Add a Dockerfile to the repo or re-run: sudo fawwk setup"; exit 1; }
      nixpacks build "$ctx" --name "$image" "${args[@]}" ;;
    *)
      echo "Unknown build type: $type"; exit 1 ;;
  esac >>"$log" 2>&1 &
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
