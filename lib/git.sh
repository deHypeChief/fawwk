#!/usr/bin/env bash
# fawwk — git access: public repos, personal access tokens, per-app deploy keys.

# owner/name, git@host:owner/name(.git) or https://host/owner/name(.git) -> https://host/owner/name.git
repo_https() {
  local u=${1%/}
  [[ $u =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && u="https://github.com/$u"
  [[ $u =~ ^git@([^:]+):(.+)$ ]] && u="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  [[ $u =~ ^ssh://git@([^/]+)/(.+)$ ]] && u="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  [[ $u == *.git ]] || u="$u.git"
  printf '%s' "$u"
}

repo_ssh() {
  local u
  u=$(repo_https "$1")
  [[ $u =~ ^https?://([^/]+)/(.+)$ ]] && printf 'git@%s:%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

# https://github.com/owner/name.git -> owner/name
repo_path() {
  local u
  u=$(repo_https "$1")
  u=${u#*://*/}
  printf '%s' "${u%.git}"
}

repo_slug() { local p; p=$(repo_path "$1"); printf '%s' "${p##*/}"; }

valid_repo() {
  [[ $(repo_https "$1") =~ ^https?://[^/]+/[^/]+/.+\.git$ ]] || { warn "Use a URL like https://github.com/you/app or owner/name"; return 1; }
}

# Prepares the environment so git uses the loaded app's credentials and never prompts.
git_env() {
  local d
  d=$(app_dir "$A_NAME")
  export GIT_TERMINAL_PROMPT=0
  unset GIT_ASKPASS GIT_SSH_COMMAND FAWWK_GIT_TOKEN_FILE FAWWK_GIT_USER
  case $A_AUTH in
    github)
      # Short-lived installation token from the GitHub App, refreshed as needed.
      gh_app_token || { echo "Couldn't get a GitHub App token for $A_NAME (is the app still installed on $(repo_path "$A_REPO")?)" >&2; return 1; }
      export FAWWK_GIT_TOKEN_FILE="$d/token"
      export GIT_ASKPASS="$FAWWK_HOME/lib/askpass.sh"
      ;;
    token)
      export FAWWK_GIT_TOKEN_FILE="$d/token"
      export GIT_ASKPASS="$FAWWK_HOME/lib/askpass.sh"
      # GitHub and GitLab accept any username with a token; Bitbucket needs the real one.
      [[ -n ${A_TOKEN_USER-} ]] && export FAWWK_GIT_USER=$A_TOKEN_USER
      ;;
    deploykey)
      export GIT_SSH_COMMAND="ssh -i $d/deploy_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
      ;;
  esac
}

git_url() { if [[ $A_AUTH == deploykey ]]; then repo_ssh "$A_REPO"; else repo_https "$A_REPO"; fi; }

# git_cmd ARGS... — git with the app's credentials and no credential helpers.
git_cmd() { (git_env || exit 1; timeout 300 git -c credential.helper= "$@"); }

# Returns 0 if the repo is readable with the current A_AUTH.
git_probe() { git_cmd ls-remote --heads "$(git_url)" >/dev/null 2>&1; }

git_default_branch() {
  git_cmd ls-remote --symref "$(git_url)" HEAD 2>/dev/null |
    awk '/^ref:/ {sub("refs/heads/", "", $2); print $2; exit}'
}

git_remote_head() {
  git_cmd ls-remote "$(git_url)" "refs/heads/$A_BRANCH" 2>/dev/null | awk '{print $1; exit}'
}

git_branch_exists() { [[ -n $(git_remote_head) ]]; }

# Clones or updates the app's checkout to the tip of A_BRANCH. Prints the commit hash.
git_sync() {
  local src url
  src="$(app_var "$A_NAME")/src"
  url=$(git_url)
  if [[ -d $src/.git ]]; then
    git -C "$src" remote set-url origin "$url"
    git_cmd -C "$src" fetch -q --depth 1 origin "$A_BRANCH" >&2 || return 1
    git -C "$src" reset -q --hard FETCH_HEAD >&2 || return 1
    git -C "$src" clean -q -fdx >&2
  else
    rm -rf "$src"
    mkdir -p "${src%/*}"
    git_cmd clone -q --depth 1 --branch "$A_BRANCH" "$url" "$src" >&2 || return 1
  fi
  if [[ -f $src/.gitmodules ]]; then
    git_cmd -C "$src" submodule update -q --init --recursive --depth 1 >&2 || warn "Some git submodules couldn't be fetched."
  fi
  git -C "$src" rev-parse HEAD
}

git_subject() { git -C "$(app_var "$A_NAME")/src" log -1 --format=%s 2>/dev/null || true; }

# Creates (once) a read-only SSH deploy key for the app and prints the public half.
deploykey_create() {
  local d
  d=$(app_dir "$A_NAME")
  mkdir -p "$d"
  chmod 700 "$d"
  [[ -f $d/deploy_key ]] || ssh-keygen -q -t ed25519 -N '' -C "fawwk-$A_NAME@$(hostname)" -f "$d/deploy_key"
  chmod 600 "$d/deploy_key"
  cat "$d/deploy_key.pub"
}

# Interactive: make sure the server can read A_REPO, setting A_AUTH (public|github|token|deploykey).
# git_setup_access [PRESET] [TOKEN_FILE] [TOKEN_USER]
git_setup_access() {
  local preset=${1-} token_file=${2-} token_user=${3-} pick tries pub d host found=""
  d=$(app_dir "$A_NAME")
  host=$(repo_https "$A_REPO"); host=${host#*://}; host=${host%%/*}

  A_AUTH=public
  # A connected GitHub App installed on this repo: no keys needed, and pushes deploy instantly.
  if [[ ( -z $preset || $preset == github ) && $host == github.com ]] && gh_have_sources; then

    gh_need_jq
    spin_start "Looking for the Fawwk GitHub App on $(repo_path "$A_REPO")"
    if found=$(gh_find_installation "$(repo_path "$A_REPO")"); then
      spin_stop
      read -r A_GH_SOURCE A_GH_INSTALL <<<"$found"
      A_AUTH=github
      ok "Access through GitHub App $A_GH_SOURCE ${C_MUTED}(pushes deploy instantly)${C_RESET}"
      return 0
    fi
    spin_stop
  fi
  if [[ $preset == public ]]; then
    git_probe || die "$(repo_path "$A_REPO") can't be read without credentials."
    ok "Public repository, no credentials needed"
    return 0
  fi
  if [[ -z $preset ]]; then
    spin_start "Checking access to $(repo_path "$A_REPO")"
    if git_probe; then
      spin_stop; ok "Public repository, no credentials needed"
      [[ $host == github.com ]] && hint "For instant deploys on push, connect GitHub: sudo fawwk github connect"
      return 0
    fi
    spin_stop
  fi

  if [[ -z $preset ]]; then
    warn "Can't read the repo anonymously (it's private, or the URL is wrong)."
    local opts=() kinds=()
    if [[ $host == github.com ]]; then
      if gh_have_sources; then opts+=("GitHub App: install $(gh_sources | head -n1) on this repo (recommended)")
      else opts+=("Connect GitHub: one-time setup for all your repos, instant deploys (recommended)")
      fi
      kinds+=(github)
    fi
    opts+=("Deploy key: read-only access to this one repo" "Personal access token")
    kinds+=(deploykey token)
    choose pick "How should this server get access?" 1 "${opts[@]}"
    preset=${kinds[pick - 1]}
  fi

  if [[ $preset == github ]]; then
    gh_have_sources || github_connect
    local src
    for tries in 1 2 3 4 5; do
      src=$(gh_sources | head -n1)
      gh_load "$src"
      step "Install $GH_SLUG on $(repo_path "$A_REPO")"
      info "Open $(gh_install_url "$src"), select ${C_BOLD}$(repo_path "$A_REPO")${C_RESET} and click Install (or Save)."
      is_interactive && read -r -s -p "  ${C_ACCENT}${G_PROMPT}${C_RESET} ${C_MUTED}Press Enter once it's installed${C_RESET}" _ && printf '\n' >&2
      if found=$(gh_find_installation "$(repo_path "$A_REPO")"); then
        read -r A_GH_SOURCE A_GH_INSTALL <<<"$found"
        A_AUTH=github
        ok "Access through GitHub App $A_GH_SOURCE ${C_MUTED}(pushes deploy instantly)${C_RESET}"
        return 0
      fi
      is_interactive || break
      warn "The app isn't installed on $(repo_path "$A_REPO") yet (attempt $tries/5)."
    done
    die "No GitHub App installed on $A_REPO."
  fi

  if [[ $preset == deploykey ]]; then
    A_AUTH=deploykey
    pub=$(deploykey_create)
    step "Add this deploy key to the repo"
    local where
    if [[ $host == github.com ]]; then
      where="Open ${C_ACCENT2}https://github.com/$(repo_path "$A_REPO")/settings/keys/new${C_RESET}"
    else
      where="In your git host, add a read-only deploy key for $(repo_path "$A_REPO")"
    fi
    info "$where"
    hint "Title: fawwk-$(hostname)  $G_SEP  leave 'Allow write access' unchecked"
    # Printed bare (no box or indent) so it copies cleanly.
    printf '\n%s\n\n' "$pub" >&2
    for tries in 1 2 3 4 5; do
      is_interactive && read -r -s -p "  ${C_ACCENT}${G_PROMPT}${C_RESET} ${C_MUTED}Press Enter once the key is added${C_RESET}" _ && printf '\n' >&2
      git_probe && { ok "Repository access works (deploy key)"; return 0; }
      is_interactive || break
      warn "Still can't read the repo. Check the key was saved on the right repo (attempt $tries/5)."
    done
    die "No access to $A_REPO with the deploy key."
  fi

  A_AUTH=token
  mkdir -p "$d"
  chmod 700 "$d"
  A_TOKEN_USER=$token_user
  if [[ -z $A_TOKEN_USER && $host == bitbucket.org ]]; then
    ask A_TOKEN_USER "Bitbucket username (app passwords need it)"
  fi
  if [[ -n $token_file ]]; then
    install -m 600 "$token_file" "$d/token"
  else
    info "Create a token with read access to the repo's contents"
    [[ $host == github.com ]] && hint "GitHub: Settings $G_ARROW Developer settings $G_ARROW Fine-grained tokens $G_ARROW Contents: Read-only"
    for tries in 1 2 3; do
      local tok
      ask_secret tok "Paste the token"
      (umask 077; printf '%s\n' "$tok" >"$d/token")
      git_probe && { ok "Repository access works (token)"; return 0; }
      warn "That token can't read $(repo_path "$A_REPO") (attempt $tries/3)."
    done
  fi
  git_probe || die "No access to $A_REPO with the token."
  ok "Repository access works (token)"
}
