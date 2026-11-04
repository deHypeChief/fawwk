#!/usr/bin/env bash
# fawwk — terminal UI: theme, step/result output, boxes, spinners, prompts and arrow-key menus.
#
# Look: a transcript of steps, each with its results hanging underneath:
#
#   ● Fetching code
#     ⎿  ✓ Cloned at 3f2a1bc: Fix login redirect
#
# Environment:
#   FAWWK_THEME=mint|ocean|ember|mono   colour theme (default: mint)
#   NO_COLOR=1                          no colours at all
#   FAWWK_ASCII=1                       plain ASCII symbols instead of Unicode

shopt -s extglob

# ---------- locale: box drawing and symbols need UTF-8 ----------
case ${LC_ALL:-${LC_CTYPE:-${LANG-}}} in
  *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*) ;;
  *) [[ -z ${LC_ALL-} ]] && locale -a 2>/dev/null | grep -qiE '^c\.utf-?8$' && export LC_CTYPE=C.UTF-8 ;;
esac
UI_UNICODE=1
case ${LC_ALL:-${LC_CTYPE:-${LANG-}}} in *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*) ;; *) UI_UNICODE=0 ;; esac
[[ ${FAWWK_ASCII:-0} == 1 || ${TERM-} == linux ]] && UI_UNICODE=0

if ((UI_UNICODE)); then
  G_STEP='●' G_HANG='⎿' G_OK='✓' G_WARN='▲' G_ERR='✗' G_ASK='?' G_PROMPT='❯' G_LOGO='◆'
  G_DOT='●' G_ARROW='→' G_SEP='·' G_ELLIPSIS='…'
  G_TL='╭' G_TR='╮' G_BL='╰' G_BR='╯' G_H='─' G_V='│'
  UI_SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
else
  G_STEP='*' G_HANG='\_' G_OK='+' G_WARN='!' G_ERR='x' G_ASK='?' G_PROMPT='>' G_LOGO='#'
  G_DOT='*' G_ARROW='->' G_SEP='-' G_ELLIPSIS='...'
  G_TL='+' G_TR='+' G_BL='+' G_BR='+' G_H='-' G_V='|'
  UI_SPIN=('|' '/' '-' '\')
fi

# ---------- theme ----------
# C_ACCENT is the brand colour (steps, prompts, selection); C_ACCENT2 highlights names and values.
ui_theme() {
  local e=$'\e[' basic=0
  C_RESET='' C_BOLD='' C_DIM='' C_ITAL='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''
  C_ACCENT='' C_ACCENT2='' C_MUTED='' C_BORDER=''
  [[ -t 2 && -z ${NO_COLOR-} && ${TERM-} != dumb ]] || return 0
  [[ ${TERM-} == *256color* || ${TERM-} == *truecolor* || -n ${COLORTERM-} || ${TERM-} == xterm* || ${TERM-} == tmux* || ${TERM-} == screen* ]] || basic=1

  C_RESET="${e}0m" C_BOLD="${e}1m" C_DIM="${e}2m" C_ITAL="${e}3m"
  if ((basic)) || [[ ${FAWWK_THEME-} == mono ]]; then
    C_RED="${e}31m" C_GREEN="${e}32m" C_YELLOW="${e}33m" C_BLUE="${e}34m" C_CYAN="${e}36m"
    C_ACCENT="${e}36m" C_ACCENT2="${e}35m" C_MUTED="${e}2m" C_BORDER="${e}2m"
    [[ ${FAWWK_THEME-} == mono ]] && C_ACCENT="${e}1m" C_ACCENT2="${e}1m"
    return 0
  fi
  C_RED="${e}38;5;204m" C_GREEN="${e}38;5;114m" C_YELLOW="${e}38;5;221m"
  C_BLUE="${e}38;5;75m" C_CYAN="${e}38;5;80m" C_MUTED="${e}38;5;245m" C_BORDER="${e}38;5;240m"
  case ${FAWWK_THEME:-mint} in
    ocean) C_ACCENT="${e}38;5;75m" C_ACCENT2="${e}38;5;117m" ;;
    ember) C_ACCENT="${e}38;5;203m" C_ACCENT2="${e}38;5;222m" ;;
    *)     C_ACCENT="${e}38;5;79m" C_ACCENT2="${e}38;5;141m" ;;   # mint + violet
  esac
}
ui_theme

ui_tty() { [[ -t 2 ]]; }

# Visible length of a string (ANSI colour codes don't count).
ui_len() { local s=${1//$'\e['*([0-9;])m/}; printf '%s' "${#s}"; }

ui_cols() {
  local r c=''
  { read -r r c < <(stty size </dev/tty 2>/dev/null); } 2>/dev/null || true
  [[ $c =~ ^[0-9]+$ && $c -gt 20 ]] || c=80
  printf '%s' "$c"
}

# Terminal rows a line of text takes up (it may wrap).
ui_rows() {
  local len cols
  len=$(ui_len "$1"); cols=$(ui_cols)
  ((len == 0)) && { echo 1; return; }
  echo $(((len + cols - 1) / cols))
}

# Erases the last N terminal rows, leaving the cursor at the start of the first one.
ui_erase() { (($1 > 0)) && printf '\e[%dA\r\e[J' "$1" >&2; return 0; }

# Ctrl-C anywhere: stop the spinner, bring the cursor back, end the line cleanly.
ui_on_int() { spin_stop; ui_cursor_show; printf '\n' >&2; FAWWK_DIED=1; exit 130; }

ui_cursor_hide() { ui_tty && printf '\e[?25l' >&2; return 0; }
ui_cursor_show() { ui_tty && printf '\e[?25h' >&2; return 0; }

# ---------- output ----------
# Lines printed after a step hang under it: the first with ⎿, the rest indented to match.
UI_IN_STEP=0 UI_HANG=0

# ui_lead sets UI_LEAD (not printed: a $(subshell) would lose the "first line done" state).
ui_lead() {
  if ((UI_HANG)); then UI_HANG=0; UI_LEAD="  ${C_MUTED}${G_HANG}${C_RESET}  "
  elif ((UI_IN_STEP)); then UI_LEAD='     '
  else UI_LEAD='  '
  fi
}

step() { printf '\n%s%s%s %s%s%s\n' "$C_ACCENT" "$G_STEP" "$C_RESET" "$C_BOLD" "$*" "$C_RESET" >&2; UI_IN_STEP=1 UI_HANG=1; }
info() { ui_lead; printf '%s%s\n' "$UI_LEAD" "$*" >&2; }
hint() { ui_lead; printf '%s%s%s%s\n' "$UI_LEAD" "$C_MUTED" "$*" "$C_RESET" >&2; }
ok()   { ui_lead; printf '%s%s%s%s %s\n' "$UI_LEAD" "$C_GREEN" "$G_OK" "$C_RESET" "$*" >&2; }
warn() { ui_lead; printf '%s%s%s%s %s\n' "$UI_LEAD" "$C_YELLOW" "$G_WARN" "$C_RESET" "$*" >&2; }
err()  { ui_lead; printf '%s%s%s%s %s\n' "$UI_LEAD" "$C_RED" "$G_ERR" "$C_RESET" "$*" >&2; }
die()  { spin_stop; err "$*"; FAWWK_DIED=1; exit 1; }
ts()   { date '+%Y-%m-%d %H:%M:%S'; }

# Indents piped text (logs) under the current step, dimmed.
ui_quote() {
  local line
  while IFS= read -r line || [[ -n $line ]]; do
    printf '     %s%s%s %s\n' "$C_BORDER" "$G_V" "$C_RESET" "$line" >&2
  done
}

# kv "Label" "value" — an aligned key/value line (used inside boxes and info screens).
kv() { printf '%s%-14s%s %s' "$C_MUTED" "$1" "$C_RESET" "$2"; }

# ui_box [--title TEXT] LINE... — draws a rounded box around the lines.
ui_box() {
  local title='' line w=0 l cols pad
  if [[ ${1-} == --title ]]; then title=$2; shift 2; fi
  for line in "$@"; do l=$(ui_len "$line"); ((l > w)) && w=$l; done
  [[ -n $title ]] && { l=$(($(ui_len "$title") + 3)); ((l > w)) && w=$l; }
  ((w < 46)) && w=46
  cols=$(ui_cols); ((w > cols - 6)) && w=$((cols - 6))
  local bar
  printf -v bar '%*s' $((w + 2)) ''; bar=${bar// /$G_H}
  if [[ -n $title ]]; then
    local tb
    printf -v tb '%*s' $((w - $(ui_len "$title") - 1)) ''; tb=${tb// /$G_H}
    printf '%s%s%s %s%s%s %s%s%s\n' "$C_BORDER" "$G_TL" "$G_H" "$C_RESET$C_BOLD" "$title" "$C_RESET" "$C_BORDER" "$tb$G_TR" "$C_RESET" >&2
  else
    printf '%s%s%s%s%s\n' "$C_BORDER" "$G_TL" "$bar" "$G_TR" "$C_RESET" >&2
  fi
  for line in "$@"; do
    pad=$((w - $(ui_len "$line"))); ((pad < 0)) && pad=0
    printf '%s%s%s %s%*s %s%s%s\n' "$C_BORDER" "$G_V" "$C_RESET" "$line" "$pad" '' "$C_BORDER" "$G_V" "$C_RESET" >&2
  done
  printf '%s%s%s%s%s\n' "$C_BORDER" "$G_BL" "$bar" "$G_BR" "$C_RESET" >&2
}

# The header shown by `fawwk` and at the start of guided flows.
ui_banner() {
  local sub=${1:-Deploy git repos to containers on this server}
  local where="${C_MUTED}host${C_RESET} $(hostname 2>/dev/null || echo '?')"
  [[ -n ${DOMAIN-} ]] && where+="  ${C_MUTED}${G_SEP} domain${C_RESET} $DOMAIN"
  printf '\n' >&2
  ui_box "${C_ACCENT}${G_LOGO}${C_RESET} ${C_BOLD}Fawwk${C_RESET} ${C_MUTED}v$FAWWK_VERSION${C_RESET}" \
    "" "  $sub" "  $where"
}

# ---------- spinner ----------
# spin_start "Label" [LOGFILE] — animates on stderr until spin_stop; shows the log's last line under it.
UI_SPIN_PID=''

spin_start() {
  spin_stop
  ui_tty || { info "$1$G_ELLIPSIS"; return 0; }
  local label=$1 log=${2-} parent=$$ lead
  # The spinner line is erased when it stops, so the next real line still gets the ⎿.
  local hang=$UI_HANG
  ui_lead; lead=$UI_LEAD; UI_HANG=$hang
  ui_cursor_hide
  (
    set +eE; trap - ERR EXIT INT; trap 'exit 0' TERM
    local i=0 start=$SECONDS last cols el
    cols=$(ui_cols)
    while kill -0 "$parent" 2>/dev/null; do
      el=$((SECONDS - start))
      printf '\r\e[K%s%s%s%s %s%s %s(%ds)%s' "$lead" "$C_ACCENT" "${UI_SPIN[i % ${#UI_SPIN[@]}]}" "$C_RESET" \
        "$label" "$G_ELLIPSIS" "$C_MUTED" "$el" "$C_RESET" >&2
      if [[ -n $log ]]; then
        last=$(tail -n 1 "$log" 2>/dev/null | tr -d '\r\t' | cut -c1-$((cols - 12)))
        printf '\n\r\e[K       %s%s%s\e[1A' "$C_MUTED" "$last" "$C_RESET" >&2
      fi
      i=$((i + 1))
      sleep 0.12
    done
  ) >/dev/null &
  UI_SPIN_PID=$!
}

spin_stop() {
  [[ -n ${UI_SPIN_PID-} ]] || return 0
  kill "$UI_SPIN_PID" 2>/dev/null || true
  wait "$UI_SPIN_PID" 2>/dev/null || true
  UI_SPIN_PID=''
  printf '\r\e[J' >&2
  ui_cursor_show
}

# ---------- prompts ----------
is_interactive() { [[ $FAWWK_YES -eq 0 && -t 0 ]]; }

# ui_read VAR "Question" DEFAULT [secret] — question on one line, ❯ input under it.
# Once answered, both collapse into a single "? Question › answer" line.
ui_read() {
  # Locals are prefixed so they can't shadow the caller's variable name.
  local __rv=$1 _rq=$2 _rdef=${3-} _rsecret=${4-} _rans='' _rqline _rpline _rrows _rshown
  _rqline="  ${C_ACCENT}${G_ASK}${C_RESET} ${C_BOLD}$_rq${C_RESET}"
  [[ -n $_rdef ]] && _rqline+="  ${C_MUTED}(enter for ${_rdef})${C_RESET}"
  _rpline="  ${C_ACCENT}${G_PROMPT}${C_RESET} "
  # Same prompt for readline, with colour codes wrapped in \001..\002 so line editing measures it right.
  local _rl="  "$'\001'"$C_ACCENT"$'\002'"$G_PROMPT"$'\001'"$C_RESET"$'\002'" "
  printf '%s\n' "$_rqline" >&2
  if [[ -n $_rsecret ]]; then
    read -r -s -p "$_rpline" _rans || _rans=''
    printf '\n' >&2
  else
    read -r -e -p "$_rl" _rans || _rans=''
  fi
  _rans=${_rans:-$_rdef}
  if ui_tty; then
    _rrows=$(ui_rows "$_rqline")
    if [[ -n $_rsecret ]]; then _rrows=$((_rrows + 1)); _rshown=${_rans//?/•}; _rshown=${_rshown:0:12}
    else _rrows=$((_rrows + $(ui_rows "$_rpline${_rans:-x}"))); _rshown=$_rans
    fi
    ui_erase "$_rrows"
    printf '  %s%s%s %s %s%s%s %s\n' "$C_GREEN" "$G_OK" "$C_RESET" "$_rq" "$C_MUTED" "$G_PROMPT" "$C_RESET" \
      "${C_ACCENT2}${_rshown:-${C_MUTED}skipped}${C_RESET}" >&2
  fi
  UI_HANG=0
  printf -v "$__rv" '%s' "$_rans"
}

# ask VAR "Question" [default] [validator]
# Re-asks until the validator passes. Non-interactive: uses the default or dies.
ask() {
  local __var=$1 q=$2 def=${3-} check=${4-} ans=''
  while true; do
    if is_interactive; then
      ui_read ans "$q" "$def"
      if [[ -z $ans ]]; then warn "A value is required."; continue; fi
    else
      ans=$def
      [[ -n $ans ]] || die "Missing value for: $q (pass it as a flag or run interactively)"
    fi
    if [[ -n $check ]] && ! "$check" "$ans"; then
      is_interactive || die "Invalid value for '$q': $ans"
      continue
    fi
    printf -v "$__var" '%s' "$ans"
    return 0
  done
}

# ask_optional VAR "Question" [default] — empty answer allowed.
ask_optional() {
  local __var=$1 q=$2 def=${3-} ans=''
  if is_interactive; then ui_read ans "$q" "$def"; fi
  printf -v "$__var" '%s' "${ans:-$def}"
}

# ask_secret VAR "Question" — hidden input, required.
ask_secret() {
  local __var=$1 q=$2 ans=''
  is_interactive || die "Missing secret: $q (run interactively)"
  while [[ -z $ans ]]; do ui_read ans "$q" '' secret; done
  printf -v "$__var" '%s' "$ans"
}

# menu VAR "Question" DEFAULT_INDEX "option 1" "option 2" ... — sets VAR to the 1-based index.
# Arrow keys (or j/k) move, Enter picks, a number or an option's first letter picks directly.
# Falls back to typing a number when there's no terminal to draw on.
menu() {
  local __mv=$1 _q=$2 _sel=$3
  shift 3
  local _opts=("$@") _n=$# _i _key _rest _pick=''
  if ! is_interactive; then printf -v "$__mv" '%s' "$_sel"; return 0; fi

  if ! ui_tty; then
    printf '  %s %s\n' "$G_ASK" "$_q" >&2
    for ((_i = 1; _i <= _n; _i++)); do printf '      %d. %s\n' "$_i" "${_opts[_i - 1]}" >&2; done
    while true; do
      read -r -p "    choice [$_sel]: " _key || _key=''
      _key=${_key:-$_sel}
      [[ $_key =~ ^[0-9]+$ ]] && ((_key >= 1 && _key <= _n)) && { printf -v "$__mv" '%s' "$_key"; return 0; }
      printf '    Pick a number between 1 and %d.\n' "$_n" >&2
    done
  fi

  local _qline="  ${C_ACCENT}${G_ASK}${C_RESET} ${C_BOLD}$_q${C_RESET}" _rows
  printf '%s\n' "$_qline" >&2
  _menu_draw() {
    for ((_i = 1; _i <= _n; _i++)); do
      if ((_i == _sel)); then
        printf '\r\e[K  %s%s %d. %s%s\n' "$C_ACCENT" "$G_PROMPT" "$_i" "${_opts[_i - 1]}" "$C_RESET" >&2
      else
        printf '\r\e[K    %s%d.%s %s\n' "$C_MUTED" "$_i" "$C_RESET" "${_opts[_i - 1]}" >&2
      fi
    done
    printf '\r\e[K    %s↑/↓ to move %s enter to select%s' "$C_MUTED" "$G_SEP" "$C_RESET" >&2
  }
  ui_cursor_hide
  _menu_draw
  while true; do
    IFS= read -rsn1 _key || { _pick=$_sel; break; }
    case $_key in
      $'\e')
        _rest=''
        IFS= read -rsn2 -t 0.05 _rest || true
        case $_rest in
          '[A' | OA) ((_sel > 1)) && _sel=$((_sel - 1)) || _sel=$_n ;;
          '[B' | OB) ((_sel < _n)) && _sel=$((_sel + 1)) || _sel=1 ;;
        esac ;;
      '' | ' ') _pick=$_sel ;;
      k) ((_sel > 1)) && _sel=$((_sel - 1)) || _sel=$_n ;;
      j) ((_sel < _n)) && _sel=$((_sel + 1)) || _sel=1 ;;
      [1-9]) ((_key <= _n)) && _pick=$_key ;;
      *)
        for ((_i = 1; _i <= _n; _i++)); do
          [[ ${_opts[_i - 1]:0:1} == [${_key,,}${_key^^}] ]] && { _pick=$_i; break; }
        done ;;
    esac
    [[ -n $_pick ]] && break
    printf '\e[%dA' "$_n" >&2
    _menu_draw
  done
  unset -f _menu_draw
  # Collapse the question and options into one answered line.
  printf '\r' >&2
  _rows=$(($(ui_rows "$_qline") + _n))
  printf '\e[%dA\r\e[J' "$_rows" >&2
  ui_cursor_show
  printf '  %s%s%s %s %s%s%s %s%s%s\n' "$C_GREEN" "$G_OK" "$C_RESET" "$_q" "$C_MUTED" "$G_PROMPT" "$C_RESET" \
    "$C_ACCENT2" "${_opts[_pick - 1]}" "$C_RESET" >&2
  UI_HANG=0
  printf -v "$__mv" '%s' "$_pick"
}

# choose VAR "Question" DEFAULT_INDEX "option 1" ... — kept as the name the rest of fawwk uses.
choose() { menu "$@"; }

# confirm "Question" [Y|N] — returns 0 for yes. Shown as a Yes/No menu; y/n keys also work.
confirm() {
  local q=$1 def=${2:-Y} pick
  if ! is_interactive; then
    [[ $FAWWK_YES -eq 1 || $def == Y ]]
    return
  fi
  if [[ $def == Y ]]; then menu pick "$q" 1 "Yes" "No"; else menu pick "$q" 2 "Yes" "No"; fi
  [[ $pick == 1 ]]
}
