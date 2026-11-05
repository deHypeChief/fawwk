#!/usr/bin/env bash
# scripts/release-notes.sh VERSION — prints VERSION's section of CHANGELOG.md (used for GitHub Releases).
set -euo pipefail
v=${1:?usage: scripts/release-notes.sh VERSION}
notes=$(awk -v v="$v" '$0 == "## " v {on = 1; next} on && /^## / {exit} on' "$(dirname "$0")/../CHANGELOG.md")
if [[ -z ${notes//[[:space:]]/} ]]; then
  echo "See CHANGELOG.md for what changed in $v."
else
  printf '%s\n' "$notes" | sed '/./,$!d'
fi
