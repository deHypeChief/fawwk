#!/usr/bin/env bash
# Installs Fawwk to /opt/fawwk and puts `fawwk` on the PATH.
#
#   One line, straight from GitHub:
#     curl -fsSL https://raw.githubusercontent.com/deHypeChief/fawwk/main/install.sh | sudo bash -s -- --setup
#   From a copy of this repo on the server:
#     sudo ./install.sh --setup
#
# --setup runs `fawwk setup` right after installing.
set -Eeuo pipefail

PREFIX=${FAWWK_PREFIX:-/opt/fawwk}
REPO=${FAWWK_REPO:-https://github.com/deHypeChief/fawwk.git}
RUN_SETUP=0
[[ ${1-} == --setup ]] && RUN_SETUP=1

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo ./install.sh" >&2; exit 1; }

here=''
if [[ -n ${BASH_SOURCE[0]-} && -f ${BASH_SOURCE[0]} ]]; then
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fi

if [[ -n $here && -f $here/bin/fawwk && -d $here/lib ]]; then
  if [[ $here != "$PREFIX" ]]; then
    echo "Installing Fawwk from $here to $PREFIX"
    mkdir -p "$PREFIX"
    rm -rf "$PREFIX/bin" "$PREFIX/lib"
    cp -r "$here/bin" "$here/lib" "$PREFIX/"
    cp -f "$here/README.md" "$PREFIX/" 2>/dev/null || true
    [[ -d $here/.git ]] && { rm -rf "$PREFIX/.git"; cp -r "$here/.git" "$PREFIX/"; }
  fi
else
  [[ -n $REPO ]] || { echo "Set FAWWK_REPO to the git URL of Fawwk, or run install.sh from a copy of the repo." >&2; exit 1; }
  command -v git >/dev/null || { apt-get update -q && apt-get install -y -q git; }
  if [[ -d $PREFIX/.git ]]; then git -C "$PREFIX" pull --ff-only
  else rm -rf "$PREFIX"; git clone --depth 1 "$REPO" "$PREFIX"
  fi
fi

# Files copied from Windows may carry CRLF line endings, which break bash.
find "$PREFIX/bin" "$PREFIX/lib" -type f -exec sed -i 's/\r$//' {} +
chmod 755 "$PREFIX/bin/fawwk" "$PREFIX/lib/askpass.sh"
chmod 644 "$PREFIX"/lib/*.sh
chmod 755 "$PREFIX/lib/askpass.sh"
ln -sf "$PREFIX/bin/fawwk" /usr/local/bin/fawwk

echo "Fawwk $("$PREFIX/bin/fawwk" version) installed: $(command -v fawwk)"
if ((RUN_SETUP)); then
  # When piped from curl, stdin is the script itself; answer setup's questions from the terminal.
  if [[ ! -t 0 && -r /dev/tty ]]; then exec fawwk setup </dev/tty; fi
  exec fawwk setup
else
  echo "Next: sudo fawwk setup"
fi
