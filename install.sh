#!/usr/bin/env bash
# Installs Fawwk to /opt/fawwk and puts `fawwk` on the PATH.
#
#   Straight from GitHub, then set up:
#     curl -fsSL https://raw.githubusercontent.com/deHypeChief/fawwk/main/install.sh | sudo bash
#     sudo fawwk setup
#   From a copy of this repo on the server:
#     sudo ./install.sh --setup
#
# --setup runs `fawwk setup` right after installing, when this script isn't piped in. Piped, the
# script itself is on stdin, so setup's questions would have to borrow the terminal through
# /dev/tty from behind sudo, which hangs with no output on some servers. It says what to run instead.
set -Eeuo pipefail

PREFIX=${FAWWK_PREFIX:-/opt/fawwk}
REPO=${FAWWK_REPO:-https://github.com/deHypeChief/fawwk.git}
RUN_SETUP=0
[[ ${1-} == --setup ]] && RUN_SETUP=1

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo ./install.sh" >&2; exit 1; }

# The install folder gets replaced, so refuse anything that isn't empty or a previous Fawwk install
# (a typo like FAWWK_PREFIX=/opt would otherwise wipe /opt).
PREFIX=${PREFIX%/}
case $PREFIX in
  '' | / | /bin | /boot | /dev | /etc | /home | /lib* | /opt | /proc | /root | /run | /sbin | /srv | /sys | /tmp | /usr | /usr/* | /var | /var/lib)
    [[ $PREFIX == /usr/local/fawwk || $PREFIX == /usr/share/fawwk ]] ||
      { echo "Refusing to install into $PREFIX. Pick a dedicated folder like /opt/fawwk." >&2; exit 1; } ;;
esac
if [[ -e $PREFIX && ! -f $PREFIX/bin/fawwk && -n $(ls -A "$PREFIX" 2>/dev/null) ]]; then
  echo "$PREFIX exists and isn't a Fawwk install. Remove it or set FAWWK_PREFIX to another folder." >&2
  exit 1
fi

here=''
if [[ -n ${BASH_SOURCE[0]-} && -f ${BASH_SOURCE[0]} ]]; then
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fi

if [[ -n $here && -f $here/bin/fawwk && -d $here/lib ]]; then
  if [[ $here != "$PREFIX" ]]; then
    echo "Installing Fawwk from $here to $PREFIX"
    mkdir -p "$PREFIX"
    rm -rf "${PREFIX:?}/bin" "${PREFIX:?}/lib"
    cp -r "$here/bin" "$here/lib" "$PREFIX/"
    cp -f "$here/README.md" "$PREFIX/" 2>/dev/null || true
    [[ -d $here/.git ]] && { rm -rf "$PREFIX/.git"; cp -r "$here/.git" "$PREFIX/"; }
  fi
else
  [[ -n $REPO ]] || { echo "Set FAWWK_REPO to the git URL of Fawwk, or run install.sh from a copy of the repo." >&2; exit 1; }
  command -v git >/dev/null || { apt-get update -q && apt-get install -y -q git; }
  # An existing install follows its branch even if upstream history was rewritten (no fast-forward).
  if [[ -d $PREFIX/.git ]]; then
    b=$(git -C "$PREFIX" symbolic-ref --short -q HEAD || echo main)
    git -C "$PREFIX" fetch -q origin "$b" && git -C "$PREFIX" checkout -q -f -B "$b" FETCH_HEAD
  else rm -rf "$PREFIX"; git clone --depth 1 "$REPO" "$PREFIX"
  fi
fi

# Files copied from Windows may carry CRLF line endings, which break bash.
find "$PREFIX/bin" "$PREFIX/lib" -type f -exec sed -i 's/\r$//' {} +
chmod 755 "$PREFIX/bin/fawwk" "$PREFIX/lib/askpass.sh"
chmod 644 "$PREFIX"/lib/*.sh "$PREFIX/lib/hooks.py"
chmod 755 "$PREFIX/lib/askpass.sh"
ln -sf "$PREFIX/bin/fawwk" /usr/local/bin/fawwk

echo "Fawwk $("$PREFIX/bin/fawwk" version) installed: $(command -v fawwk)"
WILL_SETUP=0
if ((RUN_SETUP)) && [[ -t 0 ]]; then WILL_SETUP=1; fi
# Already set up (re-install over an existing server): refresh timers, log rotation, webhook receiver.
if [[ -f /etc/fawwk/fawwk.conf ]] && ((WILL_SETUP == 0)); then "$PREFIX/bin/fawwk" post-update installed || true; fi
if ((WILL_SETUP)); then
  exec fawwk setup
elif [[ -f /etc/fawwk/fawwk.conf ]]; then
  echo "This server is already set up. Change its settings any time with: sudo fawwk setup"
elif ((RUN_SETUP)); then
  echo "Next, run setup on its own (it asks a few questions, which can't be answered through a pipe):"
  echo "  sudo fawwk setup"
else
  echo "Next: sudo fawwk setup"
fi
