#!/usr/bin/env bash
# fawwk — `fawwk logs`: app and build logs, styled for reading in a terminal.
#
# App logs: local times with a line when the day changes, a level badge (ERR WRN INF DBG) taken from
# JSON fields or guessed from the text, JSON lines (pino, winston, structlog...) turned into
# "message  key=value", and HTTP methods and status codes highlighted. Build logs (BuildKit's plain
# output): one line per step, its output indented under it, "done in 3.2s" or "cached", errors in red.
# Piped or redirected output stays exactly as Docker gives it, and so does --raw.

# A JSON object of the theme's colours and glyphs, for the jq programs below.
logs_style_json() {
  jq -nc --arg red "$C_RED" --arg yellow "$C_YELLOW" --arg green "$C_GREEN" --arg accent "$C_ACCENT" \
    --arg accent2 "$C_ACCENT2" --arg muted "$C_MUTED" --arg border "$C_BORDER" --arg bold "$C_BOLD" \
    --arg reset "$C_RESET" --arg step "$G_STEP" --arg ok "$G_OK" --arg err "$G_ERR" --arg v "$G_V" \
    --arg h "$G_H" --arg arrow "$G_ARROW" \
    '{red: $red, yellow: $yellow, green: $green, accent: $accent, accent2: $accent2, muted: $muted,
      border: $border, bold: $bold, reset: $reset, step: $step, ok: $ok, err: $err, v: $v, h: $h, arrow: $arrow}'
}

# Input: `docker logs --timestamps` lines. Output: one styled line each (plus day separators).
read -r -d '' LOGS_JQ_APP <<'JQ' || true
def c($k): $s[$k];
def level_of:
  if type == "number" then (if . >= 50 then "ERR" elif . >= 40 then "WRN" elif . >= 30 then "INF" else "DBG" end)
  elif type == "string" then (ascii_downcase |
    if test("^(fatal|panic|crit|critical|error|err|emerg|alert|severe)") then "ERR"
    elif test("^warn") then "WRN" elif test("^(info|notice|log)") then "INF"
    elif test("^(debug|trace|verbose|fine)") then "DBG" else "" end)
  else "" end;
def guess:
  if test("(?i)\\b(error|fatal|panic|exception|critical|traceback|unhandled)\\b") then "ERR"
  elif test("(?i)\\b(warn|warning|deprecated)\\b") then "WRN"
  elif test("(?i)^\\s*\\[?info\\b") then "INF"
  elif test("(?i)^\\s*\\[?(debug|trace)\\b") then "DBG" else "" end;
def badge:
  if . == "ERR" then c("red") + c("bold") + "ERR" + c("reset")
  elif . == "WRN" then c("yellow") + "WRN" + c("reset")
  elif . == "INF" then c("green") + "INF" + c("reset")
  elif . == "DBG" then c("muted") + "DBG" + c("reset")
  else "   " end;
def tint($lvl):
  if $lvl == "ERR" then c("red") + . + c("reset")
  elif $lvl == "WRN" then c("yellow") + . + c("reset")
  elif $lvl == "DBG" then c("muted") + . + c("reset")
  else . end;
# Status codes first: the colour codes added for methods contain digits of their own.
def http:
  if test("\\b(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\\b") then
    gsub("(?<x>\\b[2][0-9]{2}\\b)"; c("green") + .x + c("reset"))
    | gsub("(?<x>\\b[3][0-9]{2}\\b)"; c("accent2") + .x + c("reset"))
    | gsub("(?<x>\\b[4][0-9]{2}\\b)"; c("yellow") + .x + c("reset"))
    | gsub("(?<x>\\b[5][0-9]{2}\\b)"; c("red") + .x + c("reset"))
    | gsub("(?<x>\\b(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\\b)"; c("bold") + .x + c("reset"))
  else . end;
# A JSON log line: [level, message, extra fields as "k=v ..."]
def from_json($j):
  ([$j.level, $j.lvl, $j.severity, $j.levelname, $j["log.level"]] | map(select(. != null)) | first // null | level_of) as $lvl
  | ([$j.msg, $j.message, $j.event, $j.text] | map(select(. != null)) | first // "" | tostring) as $msg
  | ($j | del(.level, .lvl, .severity, .levelname, .["log.level"], .msg, .message, .event, .text,
             .time, .timestamp, .ts, .["@timestamp"], .pid, .hostname, .v)
        | to_entries | map(.key + "=" + (.value | if type == "string" then . else tojson end)) | join(" ")) as $rest
  | [$lvl, $msg, $rest];
foreach inputs as $line ({day: null, last: ""};
  (($line | capture("^(?<ts>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})[^ ]* (?<msg>.*)$"))
     // {ts: null, msg: $line}) as $p
  | (if $p.ts then ($p.ts + "Z" | fromdateiso8601) else null end) as $t
  | (if $t then ($t | localtime | strftime("%a %e %b")) else .day end) as $day
  | (try ($p.msg | fromjson) catch null) as $j
  | (if ($j | type) == "object" then from_json($j) else [($p.msg | guess), $p.msg, ""] end) as [$lvl0, $msg, $rest]
  # An indented line right after an error or warning (a stack trace) carries its colour, not a badge.
  | (if $lvl0 == "" and ($msg | test("^\\s")) and (.last == "ERR" or .last == "WRN") then "~" + .last else $lvl0 end) as $lvl
  | .last = (if ($lvl | startswith("~")) then .last else $lvl end)
  | .sep = (if $t and $day != .day then "  " + c("muted") + c("h") + c("h") + " " + $day + " " + c("h") + c("h") + c("reset") + "\n" else "" end)
  | .day = $day
  | .out = .sep + "  " + c("muted") + (if $t then ($t | localtime | strftime("%H:%M:%S")) else "        " end) + c("reset")
      + "  " + ($lvl | badge) + "  " + ($msg | http | tint($lvl | ltrimstr("~")))
      + (if $rest != "" then "  " + c("muted") + $rest + c("reset") else "" end);
  .out)
JQ

# Input: a Fawwk build log (BuildKit plain progress plus Fawwk's own "==>" lines).
read -r -d '' LOGS_JQ_BUILD <<'JQ' || true
def c($k): $s[$k];
inputs |
if test("^==> ") then "\n" + c("accent") + c("step") + c("reset") + " " + c("bold") + .[4:] + c("reset")
elif test("^#[0-9]+ \\[[^\\]]*\\] ") then
  (capture("^#[0-9]+ (?<st>\\[[^\\]]*\\]) (?<cmd>.*)$")) as $m
  | if ($m.st | test("^\\[(internal|auth)")) then "  " + c("muted") + c("arrow") + " " + $m.st + " " + $m.cmd + c("reset")
    else "\n  " + c("accent") + c("arrow") + c("reset") + " " + c("muted") + $m.st + c("reset") + " " + c("bold") + $m.cmd + c("reset") end
elif test("^#[0-9]+ DONE ") then "    " + c("green") + c("ok") + c("reset") + " " + c("muted") + "done in " + (capture("DONE (?<t>[0-9.]+s)").t // "") + c("reset")
elif test("^#[0-9]+ CACHED") then "    " + c("muted") + c("ok") + " cached" + c("reset")
elif test("(?i)^(#[0-9]+ )?(error|.*\\berror:)") then "    " + c("red") + c("err") + " " + sub("^#[0-9]+ ([0-9.]+ )?"; "") + c("reset")
elif test("^#[0-9]+ [0-9.]+ ") then "    " + c("border") + c("v") + c("reset") + " " + sub("^#[0-9]+ [0-9.]+ "; "")
elif test("^#[0-9]+ ") then "    " + c("muted") + sub("^#[0-9]+ "; "") + c("reset")
elif test("^\\s*$") then empty
else "    " + . end
JQ

# logs_pretty app|build — styles stdin (needs jq; otherwise passes it through).
logs_pretty() {
  command -v jq >/dev/null 2>&1 || { cat; return; }
  local prog=$LOGS_JQ_APP
  [[ $1 == build ]] && prog=$LOGS_JQ_BUILD
  jq -nrR --unbuffered --argjson s "$(logs_style_json)" "$prog"
}

# Whether to style: only for a person at a terminal (and not with --raw).
logs_styled() { [[ ${1-0} == 0 && ( -t 1 || -n ${FAWWK_LOGS_STYLE-} ) ]] && command -v jq >/dev/null 2>&1; }
