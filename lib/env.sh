#!/usr/bin/env bash
# fawwk — environment variables: parse pasted .env text, merge, mask, check against .env.example.

RE_ENV_LINE='^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$'
RE_ENV_DQ='^"(.*)"[[:space:]]*(#.*)?$'
RE_ENV_SQ="^'(.*)'[[:space:]]*(#.*)?\$"

# env_parse < dotenv-text  ->  KEY=VALUE lines (docker --env-file format, no quotes)
# Handles comments, blank lines, `export KEY=...`, quoted values and CRLF line endings.
env_parse() {
  local line key val
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    [[ -z $line || $line == \#* ]] && continue
    [[ $line == export[[:space:]]* ]] && line=${line#export} && line=${line#"${line%%[![:space:]]*}"}
    if [[ ! $line =~ $RE_ENV_LINE ]]; then
      warn "Skipped a line that isn't KEY=VALUE: ${line:0:40}"
      continue
    fi
    key=${BASH_REMATCH[1]}
    val=${BASH_REMATCH[2]}
    if [[ $val =~ $RE_ENV_DQ ]]; then
      val=${BASH_REMATCH[1]}
      val=${val//\\\"/\"}
    elif [[ $val =~ $RE_ENV_SQ ]]; then
      val=${BASH_REMATCH[1]}
    elif [[ $val == \"* || $val == \'* ]]; then
      warn "$key looks like a multi-line value; only the first line was kept. Use \\n inside one line instead."
      val=${val:1}
    else
      val=${val%%[[:space:]]#*}
      val=${val%"${val##*[![:space:]]}"}
    fi
    printf '%s=%s\n' "$key" "$val"
  done
}

# env_merge FILE... -> merged KEY=VALUE on stdout; later files win, first-seen order kept.
env_merge() {
  # Missing files are fine (e.g. a new app has no env file yet); pipefail must not trip on cat.
  { cat "$@" 2>/dev/null || true; } | awk '
    { i = index($0, "="); if (i < 2) next; k = substr($0, 1, i - 1)
      if (!(k in v)) order[++n] = k; v[k] = $0 }
    END { for (j = 1; j <= n; j++) print v[order[j]] }'
}

env_keys() { [[ -f $1 ]] && cut -d= -f1 "$1" || true; }
env_has()  { [[ -f $1 ]] && grep -q "^$2=" "$1"; }
env_count() { if [[ -f $1 ]]; then grep -c '=' "$1" || true; else echo 0; fi; }

# env_save APP TMPFILE — merges new values into the app's env file (root-only).
env_save() {
  local f tmp
  f=$(app_envfile "$1")
  tmp=$(mktemp)
  env_merge "$f" "$2" >"$tmp"
  install -m 600 "$tmp" "$f"
  rm -f "$tmp"
}

# Keys listed in the repo's example env file.
env_example_file() {
  local d=$1 f
  for f in .env.example .env.sample .env.template .env.dist example.env; do
    [[ -f $d/$f ]] && { printf '%s' "$d/$f"; return 0; }
  done
  return 1
}

env_example_keys() {
  local f
  f=$(env_example_file "$1") || return 0
  env_parse <"$f" 2>/dev/null | cut -d= -f1
}

# Reads a pasted .env block from the terminal until Ctrl-D.
env_read_paste() {
  is_interactive || return 0
  printf '  %s%s%s %sPaste your environment variables%s %s(.env format)%s\n' "$C_ACCENT" "$G_ASK" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_MUTED" "$C_RESET" >&2
  printf '    %sEnter then ctrl+d when done %s nothing to add? just ctrl+d%s\n' "$C_MUTED" "$G_SEP" "$C_RESET" >&2
  printf '%s' "$C_MUTED" >&2
  env_parse
  printf '%s' "$C_RESET" >&2
}

# Prompts for keys from .env.example that are still missing. Appends to TMPFILE.
env_ask_missing() {
  local srcdir=$1 tmp=$2 key val missing=()
  while IFS= read -r key; do
    [[ -z $key || $key == PORT ]] && continue
    env_has "$tmp" "$key" || missing+=("$key")
  done < <(env_example_keys "$srcdir")
  ((${#missing[@]})) || return 0
  info "$(basename "$(env_example_file "$srcdir")") lists ${#missing[@]} variable(s) you haven't set ${C_MUTED}(enter skips)${C_RESET}"
  for key in "${missing[@]}"; do
    ask_optional val "$key"
    [[ -n $val ]] && printf '%s=%s\n' "$key" "$val" >>"$tmp"
  done
}

# Prints a warning listing example keys missing from the app's env (used on every deploy).
env_warn_missing() {
  local srcdir=$1 f key missing=()
  f=$(app_envfile "$A_NAME")
  while IFS= read -r key; do
    [[ -z $key || $key == PORT ]] && continue
    env_has "$f" "$key" || missing+=("$key")
  done < <(env_example_keys "$srcdir")
  ((${#missing[@]} == 0)) || warn "Not set (listed in the example env): ${missing[*]}  ${C_MUTED}$G_ARROW fawwk env $A_NAME set KEY=value${C_RESET}"
}

env_mask() {
  local v=$1
  if ((${#v} <= 4)); then printf '****'; else printf '%s****' "${v:0:3}"; fi
}
