#!/usr/bin/env bash
# fawwk — building images: Dockerfile, static sites, or auto-detected with Nixpacks.

STATIC_PORT=8080

build_context() {
  local src
  src="$(app_var "$A_NAME")/src"
  if [[ -z $A_DIR || $A_DIR == . ]]; then printf '%s' "$src"; else printf '%s/%s' "$src" "$A_DIR"; fi
}

# build_detect DIR -> dockerfile | static | nixpacks
build_detect() {
  local d=$1
  if [[ -f $d/Dockerfile ]]; then echo dockerfile
  elif [[ -f $d/index.html && ! -f $d/package.json ]]; then echo static
  else echo nixpacks
  fi
}

build_describe() {
  case $1 in
    dockerfile) echo "Dockerfile found, building with Docker" ;;
    static)     echo "Static site (index.html), served by Caddy" ;;
    nixpacks)   echo "No Dockerfile, auto-detecting the stack with Nixpacks" ;;
  esac
}

# Best guess at the port the app listens on.
build_port_hint() {
  local d=$1 type=$2 p=''
  case $type in
    static) p=$STATIC_PORT ;;
    dockerfile) p=$(grep -iE '^[[:space:]]*EXPOSE[[:space:]]+[0-9]+' "$d/Dockerfile" 2>/dev/null | head -n1 | grep -oE '[0-9]+' | head -n1 || true) ;;
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

  type=$A_BUILD
  [[ -z $type || $type == auto ]] && type=$(build_detect "$ctx")
  info "$(build_describe "$type")"

  # App env is available at build time too (needed by e.g. Next.js NEXT_PUBLIC_* vars).
  # Images stay on this server; they're never pushed anywhere.
  local flag=--build-arg
  [[ $type == nixpacks ]] && flag=--env
  if [[ -f $envf ]]; then
    while IFS= read -r kv; do [[ -n $kv ]] && args+=("$flag" "$kv"); done <"$envf"
  fi

  case $type in
    dockerfile)
      DOCKER_BUILDKIT=1 docker build --progress=plain -t "$image" "${args[@]}" "$ctx" ;;
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
  local pid=$!
  build_progress "$pid" "$log"
  if ! wait "$pid"; then
    err "Build failed. Last lines of the build log:"
    tail -n 30 "$log" | sed 's/^/      /' >&2
    info "Full log: $log"
    return 1
  fi
  BUILT_IMAGE=$image
  ok "Built $image"
}

# Shows the latest build line while the build runs (only on a terminal).
build_progress() {
  local pid=$1 log=$2 last
  if [[ ! -t 2 ]]; then return 0; fi
  while kill -0 "$pid" 2>/dev/null; do
    last=$(tail -n 1 "$log" 2>/dev/null | tr -d '\r' | cut -c1-90)
    printf '\r\e[K    %s%s%s' "$C_DIM" "$last" "$C_RESET" >&2
    sleep 1
  done
  printf '\r\e[K' >&2
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
