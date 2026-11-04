#!/usr/bin/env bash
# fawwk — deploying: fetch → build → start new container → health check → switch traffic → retire old.

deploy_id() { date +%Y%m%d-%H%M%S; }

# history: one TSV line per deploy: id, commit, image, status, note
history_add() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "${2:--}" "${3:--}" "$4" "${5-}" >>"$(app_dir "$A_NAME")/history"
}

history_file() { printf '%s/history' "$(app_dir "$A_NAME")"; }

is_worker() { [[ -z $A_ROUTES ]]; }

# Waits until the container answers HTTP on A_PORT (or, for workers, stays up for 10s).
health_wait() {
  local c=$1 ip code='' state restarts deadline=$((SECONDS + HEALTH_TIMEOUT)) url
  if is_worker; then
    info "Worker app (no domain): checking it stays running..."
    sleep 10
    state=$(docker inspect -f '{{.State.Status}} {{.RestartCount}}' "$c" 2>/dev/null || echo 'gone 0')
    [[ $state == "running 0" ]] && return 0
    err "Container isn't staying up (state: $state)"
    return 1
  fi
  info "Waiting for the app to answer on port $A_PORT (up to ${HEALTH_TIMEOUT}s)..."
  while ((SECONDS < deadline)); do
    read -r state restarts < <(docker inspect -f '{{.State.Status}} {{.RestartCount}}' "$c" 2>/dev/null || echo 'gone 0')
    if [[ $state == exited || $state == dead || $state == gone ]] || ((restarts > 1)); then
      err "The container crashed (state: $state, restarts: $restarts)."
      return 1
    fi
    ip=$(docker inspect -f "{{with index .NetworkSettings.Networks \"$FAWWK_NETWORK\"}}{{.IPAddress}}{{end}}" "$c" 2>/dev/null || true)
    if [[ -n $ip ]]; then
      url="http://$ip:$A_PORT${A_HEALTH:-/}"
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$url" 2>/dev/null || true)
      if [[ -n $A_HEALTH ]]; then
        [[ $code =~ ^[23] ]] && { ok "Health check passed ($A_HEALTH → $code)"; return 0; }
      else
        [[ -n $code && $code != 000 ]] && { ok "App is answering (HTTP $code)"; return 0; }
      fi
    fi
    sleep 2
  done
  err "No healthy answer on port $A_PORT within ${HEALTH_TIMEOUT}s (last HTTP code: ${code:-none})."
  info "The app must listen on 0.0.0.0:$A_PORT. It receives PORT=$A_PORT in its environment."
  info "Wrong port? fawwk port $A_NAME <port>"
  return 1
}

# release_image IMAGE COMMIT ID — zero-downtime swap to a new container running IMAGE.
release_image() {
  local image=$1 commit=$2 id=$3
  local cname="fawwk-$A_NAME-$id" envf old=$A_CONTAINER old_image=$A_IMAGE old_commit=$A_COMMIT old_state=$A_STATE
  envf=$(app_envfile "$A_NAME")
  [[ -f $envf ]] || install -m 600 /dev/null "$envf"

  local args=(-d --name "$cname" --network "$FAWWK_NETWORK" --restart unless-stopped
    --label "fawwk.app=$A_NAME" --label "fawwk.deploy=$id"
    --log-opt max-size=10m --log-opt max-file=3
    --env-file "$envf")
  if ! is_worker; then
    if env_has "$envf" PORT; then
      local envport
      envport=$(grep '^PORT=' "$envf" | tail -n1 | cut -d= -f2 || true)
      [[ $envport == "$A_PORT" ]] || warn "Your env sets PORT=$envport but the app is routed to port $A_PORT."
    else
      args+=(-e "PORT=$A_PORT")
    fi
  fi

  step "Starting new container"
  docker rm -f "$cname" >/dev/null 2>&1 || true
  if ! docker run "${args[@]}" "$image" >/dev/null; then
    err "Docker couldn't start the container."
    return 1
  fi

  if ! health_wait "$cname"; then
    err "Keeping the current version live. Last logs from the new container:"
    docker logs --tail 40 "$cname" 2>&1 | sed 's/^/      /' >&2
    docker rm -f "$cname" >/dev/null 2>&1 || true
    return 1
  fi

  app_set A_CONTAINER "$cname"
  app_set A_IMAGE "$image"
  app_set A_COMMIT "$commit"
  app_set A_STATE running
  app_set A_DEPLOYED "$(ts)"

  if ! is_worker; then
    step "Switching traffic"
    if ! proxy_reload; then
      app_set A_CONTAINER "$old"; app_set A_IMAGE "$old_image"
      app_set A_COMMIT "$old_commit"; app_set A_STATE "$old_state"
      docker rm -f "$cname" >/dev/null 2>&1 || true
      return 1
    fi
    ok "Traffic now goes to $cname"
    sleep 3   # let in-flight requests on the old container finish
  fi

  # Retire every other container of this app.
  local c
  while IFS= read -r c; do
    [[ -z $c || $c == "$cname" ]] && continue
    docker stop -t 15 "$c" >/dev/null 2>&1 || true
    docker rm -f "$c" >/dev/null 2>&1 || true
  done < <(docker ps -a --filter "label=fawwk.app=$A_NAME" --format '{{.Names}}')
  return 0
}

# deploy_app NAME — the full pipeline. Returns non-zero on failure (the old version stays live).
deploy_app() {
  local name=$1 id commit log subject
  app_load "$name"
  app_lock "$name"
  id=$(deploy_id)
  mkdir -p "$(app_var "$name")/logs"
  log="$(app_var "$name")/logs/$id.log"

  step "Deploying $name from $(repo_path "$A_REPO")@$A_BRANCH"
  if ! commit=$(git_sync); then
    err "Couldn't fetch the code. Check access with: fawwk info $name"
    history_add "$id" - - failed "git fetch failed"
    return 1
  fi
  subject=$(git_subject)
  ok "Commit ${commit:0:7}: ${subject:0:70}"
  env_warn_missing "$(build_context)"

  step "Building"
  BUILT_IMAGE=''
  if ! build_image "$id" "$log"; then
    app_set A_FAILED_COMMIT "$commit"
    history_add "$id" "$commit" - failed "build failed"
    return 1
  fi

  if ! release_image "$BUILT_IMAGE" "$commit" "$id"; then
    app_set A_FAILED_COMMIT "$commit"
    history_add "$id" "$commit" "$BUILT_IMAGE" failed "did not start"
    docker rmi "$BUILT_IMAGE" >/dev/null 2>&1 || true
    return 1
  fi

  app_set A_FAILED_COMMIT ''
  history_add "$id" "$commit" "$BUILT_IMAGE" ok "${subject:0:60}"
  images_prune
  deploy_summary
}

deploy_summary() {
  local r
  step "$A_NAME is live"
  if is_worker; then
    ok "Running as a background worker (no domain)"
  else
    for r in $A_ROUTES; do ok "$(route_url "$r")"; done
    info "HTTPS certificates are issued on the first visit once DNS points here."
  fi
}

# Recreates the container from the current image (picks up env changes). Zero downtime.
restart_app() {
  [[ -n $A_IMAGE ]] || die "$A_NAME has never been deployed. Run: fawwk deploy $A_NAME"
  docker image inspect "$A_IMAGE" >/dev/null 2>&1 || die "Image $A_IMAGE is gone. Run: fawwk deploy $A_NAME"
  local id
  id=$(deploy_id)
  release_image "$A_IMAGE" "$A_COMMIT" "$id" || return 1
  history_add "$id" "$A_COMMIT" "$A_IMAGE" ok "restart"
}
