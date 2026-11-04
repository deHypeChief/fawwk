#!/usr/bin/env bash
# fawwk — `fawwk create`: the guided flow that turns a git repo into a live app.

create_usage() {
  cat <<'EOF'
Usage: sudo fawwk create [name] [options]

Walks you through connecting a repo, domains, port and env vars, then deploys.
Every question can be answered with a flag instead (add --yes to skip prompts).

Options:
  --repo <url|owner/name>  Git repository
  --branch <branch>        Branch to deploy (default: the repo's default branch)
  --dir <folder>           Subfolder to deploy, for monorepos (default: .)
  --domain "<routes>"      Space/comma separated: app.example.com example.com/api
                           Use "none" for a background worker with no web traffic
  --port <port>            Port the app listens on inside the container
  --health <path>          Health check path, e.g. /health (default: any response)
  --env-file <file>        Load env vars from a .env file
  --token-file <file>      Private repo: file containing a personal access token
  --deploy-key             Private repo: use a generated SSH deploy key
  --build <type>           auto | dockerfile | nixpacks | static (default: auto)
  --no-strip               Keep the path prefix when proxying (example.com/api → /api/...)
  --auto / --no-auto       Auto-deploy on every push (default: on)
  --no-deploy              Save the app without deploying yet
  -y, --yes                Don't prompt; use flags and defaults
EOF
}

cmd_create() {
  local name='' repo='' branch='' dir='' domains='' port='' health='' envfile='' token_file=''
  local auth='' build=auto strip=yes auto='' do_deploy=1 has_health=0
  while (($#)); do
    case $1 in
      --repo) need_arg "$@"; repo=$2; shift 2 ;;
      --name) need_arg "$@"; name=$2; shift 2 ;;
      --branch) need_arg "$@"; branch=$2; shift 2 ;;
      --dir) need_arg "$@"; dir=$2; shift 2 ;;
      --domain | --domains) need_arg "$@"; domains=$2; shift 2 ;;
      --port) need_arg "$@"; port=$2; shift 2 ;;
      --health) need_arg "$@"; health=$2; has_health=1; shift 2 ;;
      --env-file) need_arg "$@"; envfile=$2; shift 2 ;;
      --token-file) need_arg "$@"; token_file=$2; auth=token; shift 2 ;;
      --deploy-key) auth=deploykey; shift ;;
      --build) need_arg "$@"; build=$2; shift 2 ;;
      --no-strip) strip=no; shift ;;
      --auto) auto=yes; shift ;;
      --no-auto) auto=no; shift ;;
      --no-deploy) do_deploy=0; shift ;;
      -y | --yes) FAWWK_YES=1; shift ;;
      -h | --help) create_usage; return 0 ;;
      -*) die "Unknown option: $1 (see: fawwk create --help)" ;;
      *) [[ -z $name ]] && name=$1 || die "Unexpected argument: $1"; shift ;;
    esac
  done
  require_root create
  require_setup
  [[ -z $envfile || -f $envfile ]] || die "Env file not found: $envfile"
  [[ -z $token_file || -f $token_file ]] || die "Token file not found: $token_file"
  [[ $build =~ ^(auto|dockerfile|nixpacks|static)$ ]] || die "--build must be auto, dockerfile, nixpacks or static"

  printf '\n  %sNew app%s\n' "$C_BOLD" "$C_RESET" >&2

  # --- repo + name -------------------------------------------------------
  step "Repository"
  ask repo "GitHub repo (URL or owner/name)" "$repo" valid_repo
  [[ -n $name ]] || name=$(sanitize_name "$(repo_slug "$repo")")
  ask name "App name" "$name" valid_new_app_name

  app_reset
  A_NAME=$name
  A_REPO=$(repo_https "$repo")
  A_CREATED=$(ts)
  A_STATE=new
  A_STRIP=$strip
  # Leftovers from an earlier create that was aborted.
  rm -rf "$(app_dir "$name")" "$(app_var "$name")"
  mkdir -p "$(app_dir "$name")" "$(app_var "$name")/logs"
  chmod 700 "$(app_dir "$name")"
  trap 'create_abort' INT

  git_setup_access "$auth" "$token_file"

  local def_branch
  def_branch=$(git_default_branch || true)
  while true; do
    ask A_BRANCH "Branch to deploy" "${branch:-${def_branch:-main}}"
    git_branch_exists && break
    warn "Branch '$A_BRANCH' doesn't exist in the repo."
    is_interactive || die "Branch not found: $A_BRANCH"
    branch=''
  done

  step "Fetching code"
  local commit
  commit=$(git_sync) || die "Couldn't clone the repo."
  ok "Cloned at ${commit:0:7}: $(git_subject | cut -c1-70)"

  # --- what to build ----------------------------------------------------
  local src ctx detected
  src="$(app_var "$name")/src"
  if [[ -z $dir ]]; then
    dir=.
    create_suggest_dir "$src"
  fi
  while true; do
    ask A_DIR "Folder to deploy (for monorepos; '.' is the repo root)" "$dir" valid_subdir
    A_DIR=${A_DIR%/}
    ctx=$(build_context)
    [[ -d $ctx ]] && break
    warn "No folder '$A_DIR' in the repo."
    is_interactive || die "Folder not found: $A_DIR"
  done
  A_BUILD=$build
  detected=$build
  [[ $detected == auto ]] && detected=$(build_detect "$ctx")
  ok "$(build_describe "$detected")"
  if [[ $detected == nixpacks ]] && ! command -v nixpacks >/dev/null 2>&1; then
    die "This repo has no Dockerfile and Nixpacks isn't installed. Re-run: sudo fawwk setup"
  fi

  # --- routing ----------------------------------------------------------
  step "Domains"
  info "Where should it be reachable? Separate several with spaces."
  info "Examples: $name.$DOMAIN   $DOMAIN   $DOMAIN/api   none (background worker)"
  while true; do
    ask domains "Domain(s)" "${domains:-$name.$DOMAIN}"
    create_parse_routes "$domains" && break
    is_interactive || die "Invalid --domain value"
    domains=''
  done

  if [[ -n $A_ROUTES ]]; then
    if [[ $A_ROUTES == */* && $strip == yes ]] && is_interactive; then
      confirm "Strip the path prefix before it reaches the app? (example.com/api/users → /users)" Y || A_STRIP=no
    fi
    if [[ $detected == static ]]; then
      A_PORT=$STATIC_PORT
    else
      ask A_PORT "Port the app listens on" "${port:-$(build_port_hint "$ctx" "$detected")}" valid_port
    fi
    if ((has_health)); then
      A_HEALTH=$health
    else
      ask_optional A_HEALTH "Health check path, e.g. /health (blank: any HTTP response counts)"
    fi
    [[ -z $A_HEALTH || $A_HEALTH == /* ]] || A_HEALTH="/$A_HEALTH"
  fi

  # --- env --------------------------------------------------------------
  step "Environment variables"
  local tmp
  tmp=$(mktemp)
  chmod 600 "$tmp"
  if [[ -n $envfile ]]; then
    env_parse <"$envfile" >>"$tmp"
  else
    env_read_paste >>"$tmp"
  fi
  env_ask_missing "$ctx" "$tmp"
  env_save "$name" "$tmp"
  rm -f "$tmp"
  ok "$(env_count "$(app_envfile "$name")") variable(s) saved (readable by root only)"

  # --- auto deploy ------------------------------------------------------
  step "Auto-deploy"
  if [[ -z $auto ]]; then
    confirm "Redeploy automatically when you push to $A_BRANCH?" Y && auto=yes || auto=no
  fi
  A_AUTO=$auto

  app_save
  trap - INT

  create_summary
  if ((do_deploy == 0)) || ! confirm "Deploy now?" Y; then
    ok "Saved. Deploy whenever you're ready: sudo fawwk deploy $name"
    return 0
  fi
  local r
  for r in $A_ROUTES; do dns_report "${r%%/*}"; done
  deploy_app "$name" || die "Deploy failed. Fix the issue, then run: sudo fawwk deploy $name"
}

valid_new_app_name() {
  valid_app_name "$1" || return 1
  app_exists "$1" && { warn "An app named '$1' already exists."; return 1; }
  return 0
}

# Sets A_ROUTES from user input; validates each route and checks for conflicts.
create_parse_routes() {
  local input=${1//,/ } r out=()
  if [[ ${input,,} == none ]]; then A_ROUTES=''; return 0; fi
  for r in $input; do
    r=$(route_normalize "$r")
    route_check "$r" "$A_NAME" || return 1
    out+=("$r")
  done
  ((${#out[@]})) || { warn "Enter at least one domain, or 'none'."; return 1; }
  A_ROUTES="${out[*]}"
}

# Lists likely app folders in a monorepo to help pick --dir.
create_suggest_dir() {
  local src=$1 found
  [[ -f $src/Dockerfile || -f $src/package.json || -f $src/index.html ]] && return 0
  found=$(cd "$src" && find . -mindepth 2 -maxdepth 3 \( -name Dockerfile -o -name package.json \) \
    -not -path '*/node_modules/*' 2>/dev/null | xargs -r -n1 dirname | sed 's#^\./##' | sort -u | head -n 8 | tr '\n' ' ')
  [[ -n $found ]] && info "Nothing to build at the repo root. Candidate folders: $found"
  return 0
}

create_summary() {
  step "Summary"
  local r
  printf '      %-14s %s\n' "App" "$A_NAME" >&2
  printf '      %-14s %s @ %s\n' "Repo" "$(repo_path "$A_REPO")" "$A_BRANCH" >&2
  [[ $A_DIR != . ]] && printf '      %-14s %s\n' "Folder" "$A_DIR" >&2
  printf '      %-14s %s\n' "Access" "$A_AUTH" >&2
  if [[ -z $A_ROUTES ]]; then
    printf '      %-14s %s\n' "Type" "background worker (no domain)" >&2
  else
    for r in $A_ROUTES; do printf '      %-14s %s\n' "URL" "$(route_url "$r")" >&2; done
    printf '      %-14s %s\n' "Port" "$A_PORT" >&2
    printf '      %-14s %s\n' "Health check" "${A_HEALTH:-any HTTP response}" >&2
  fi
  printf '      %-14s %s\n' "Env vars" "$(env_count "$(app_envfile "$A_NAME")")" >&2
  printf '      %-14s %s\n' "Auto-deploy" "$A_AUTO" >&2
}

create_abort() {
  printf '\n' >&2
  warn "Cancelled. Nothing was deployed."
  [[ -n ${A_NAME-} ]] && ! app_exists "$A_NAME" && rm -rf "$(app_dir "$A_NAME")" "$(app_var "$A_NAME")"
  exit 130
}
