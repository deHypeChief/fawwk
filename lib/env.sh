#!/usr/bin/env bash
# fawwk — environment variables: parse pasted .env text, merge, mask, check against .env.example.

RE_ENV_LINE='^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$'
RE_ENV_DQ='^"(.*)"[[:space:]]*(#.*)?$'
RE_ENV_SQ="^'(.*)'[[:space:]]*(#.*)?\$"
# The closing quote of a multi-line value: the last unescaped quote on a line (a comment may follow).
RE_ENV_DQ_END='^(.*[^\\]|)"[[:space:]]*(#.*)?$'
RE_ENV_SQ_END="^(.*)'[[:space:]]*(#.*)?\$"
RE_ENV_KEY='^[A-Za-z_][A-Za-z0-9_]*$'

# Storage: <app>/env holds single-line values in Docker's --env-file format (KEY=VALUE, no quotes).
# Docker's env file can't hold a value with newlines (PEM keys, certificates), so each of those lives
# in its own file, <app>/env.d/<KEY>, and reaches containers as `-e KEY` with the value exported
# into the docker command's own environment (see env_export_multiline).
env_ml_dir() { printf '%s.d' "$1"; }   # env_ml_dir ENVFILE

# env_parse < dotenv-text  ->  "KEY=VALUE" lines, plus "@@ml KEY <base64>" for multi-line values.
# Handles comments, blank lines, `export KEY=...`, quoted values (including quoted values that span
# several lines) and CRLF line endings. Consumers use env_save, which understands both line kinds.
env_parse() {
  local line key val q acc closed
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
      # An opening quote with no closing one on this line: the value continues on the next lines.
      q=${val:0:1} acc=${val:1} closed=0
      while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        if [[ $q == '"' && $line =~ $RE_ENV_DQ_END ]] || [[ $q == "'" && $line =~ $RE_ENV_SQ_END ]]; then
          acc+=$'\n'"${BASH_REMATCH[1]}"
          closed=1
          break
        fi
        acc+=$'\n'"$line"
      done
      ((closed)) || warn "$key: its opening $q has no closing $q; kept everything after it as the value."
      [[ $q == '"' ]] && acc=${acc//\\\"/\"}
      printf '@@ml %s %s\n' "$key" "$(printf '%s' "$acc" | base64 -w0)"
      continue
    else
      val=${val%%[[:space:]]#*}
      val=${val%"${val##*[![:space:]]}"}
    fi
    printf '%s=%s\n' "$key" "$val"
  done
}

# Keys in env_parse output (either line kind), one per line.
# shellcheck disable=SC2120  # callers in other files pass a file
env_parsed_keys() { awk '/^@@ml / {print $2; next} {i = index($0, "="); if (i > 1) print substr($0, 1, i - 1)}' "$@"; }

# env_ml_line KEY VALUE — a multi-line value in env_parse's output format.
env_ml_line() { printf '@@ml %s %s\n' "$1" "$(printf '%s' "$2" | base64 -w0)"; }

# env_merge FILE... -> merged KEY=VALUE on stdout; later files win, first-seen order kept.
env_merge() {
  # Missing files are fine (e.g. a new app has no env file yet); pipefail must not trip on cat.
  { cat "$@" 2>/dev/null || true; } | awk '
    { i = index($0, "="); if (i < 2) next; k = substr($0, 1, i - 1)
      if (!(k in v)) order[++n] = k; v[k] = $0 }
    END { for (j = 1; j <= n; j++) print v[order[j]] }'
}

# Multi-line keys stored for an env file, one per line.
env_ml_keys() {
  local d f
  d=$(env_ml_dir "$1")
  for f in "$d"/*; do [[ -f $f ]] && printf '%s\n' "${f##*/}"; done
  return 0
}

env_keys() { { [[ -f $1 ]] && cut -d= -f1 "$1"; env_ml_keys "$1"; } || true; }
# env_has FILE KEY — works on an app's env file and on env_parse output.
env_has()  { [[ -f $1 ]] && grep -qE "^($2=|@@ml $2 )" "$1" && return 0; [[ -f $(env_ml_dir "$1")/$2 ]]; }
env_count() {
  local n=0
  [[ -f $1 ]] && n=$(grep -c '=' "$1" || true)
  echo $((n + $(env_ml_keys "$1" | wc -l)))
}

# env_save APP TMPFILE — merges env_parse output into the app's env (root-only). The last value
# given for a key wins, and decides whether it's stored as a single-line or a multi-line value.
env_save() {
  local f d tmp single line k v
  local -A kind=()
  f=$(app_envfile "$1")
  d=$(env_ml_dir "$f")
  single=$(mktemp)
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == '@@ml '* ]]; then
      line=${line#@@ml }; k=${line%% *}; v=${line#* }
      [[ $k =~ $RE_ENV_KEY ]] || continue
      mkdir -p "$d"; chmod 700 "$d"
      (umask 077; printf '%s' "$v" | base64 -d >"$d/$k")
      kind[$k]=ml
    elif [[ $line == *=* ]]; then
      k=${line%%=*}
      printf '%s\n' "$line" >>"$single"
      rm -f "$d/$k"
      kind[$k]=single
    fi
  done <"$2"
  tmp=$(mktemp)
  env_merge "$f" "$single" | while IFS= read -r line; do
    [[ ${kind[${line%%=*}]-} == ml ]] || printf '%s\n' "$line"
  done >"$tmp"
  install -m 600 "$tmp" "$f"
  rm -f "$tmp" "$single"
}

# env_unset APP KEY... — removes keys of either kind.
env_unset() {
  local f d k tmp
  f=$(app_envfile "$1"); shift
  d=$(env_ml_dir "$f")
  tmp=$(mktemp)
  [[ -f $f ]] && cp "$f" "$tmp"
  for k in "$@"; do
    awk -v k="$k" 'index($0, k "=") != 1' "$tmp" >"$tmp.2"; mv "$tmp.2" "$tmp"
    rm -f "$d/$k"
  done
  install -m 600 "$tmp" "$f"
  rm -f "$tmp"
}

# env_export_multiline ENVFILE — exports every multi-line value into the current shell, for
# `docker run -e KEY` / `docker build --build-arg KEY` to pick up. Call it in a subshell.
env_export_multiline() {
  local k v d
  d=$(env_ml_dir "$1")
  while IFS= read -r k; do
    [[ $k =~ $RE_ENV_KEY ]] || continue
    IFS= read -r -d '' v <"$d/$k" || true
    export "$k=$v"
  done < <(env_ml_keys "$1")
}

# env_render ENVFILE — the whole env as dotenv text that env_parse reads back exactly (for editing).
env_render() {
  local line k v d
  d=$(env_ml_dir "$1")
  if [[ -f $1 ]]; then
    while IFS= read -r line; do
      k=${line%%=*} v=${line#*=}
      printf '%s=' "$k"; env_quote "$v"; printf '\n'
    done <"$1"
  fi
  # Printed directly, not via $(...): that would drop a value's trailing newline (PEM files have one).
  while IFS= read -r k; do
    IFS= read -r -d '' v <"$d/$k" || true
    printf '%s=' "$k"; env_quote "$v"; printf '\n'
  done < <(env_ml_keys "$1")
}

# env_quote VALUE — VALUE written so env_parse gives it back unchanged.
env_quote() {
  local v=$1
  # Plain values need no quotes: no comment marker, no quote at the start, no edge spaces or newlines.
  if [[ $v != *$'\n'* && $v != *' #'* && $v != *$'\t#'* && $v != [\"\']* && $v != [[:space:]]* && $v != *[[:space:]] ]]; then
    printf '%s' "$v"
  elif [[ $v != *"'"* ]]; then
    printf "'%s'" "$v"
  else
    printf '"%s"' "${v//\"/\\\"}"
  fi
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
  env_parse <"$f" 2>/dev/null | env_parsed_keys
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

# env_mask VALUE — enough to recognise a value, never enough to use it.
env_mask() {
  local v=$1
  if ((${#v} <= 4)); then printf '****'; else printf '%s****' "${v:0:3}"; fi
}
