#!/usr/bin/env bash
# @brief Build and install the plugin into the plugin dir of the Audacious
#        that actually runs (not whichever audacious.pc pkg-config finds first).
#
# Usage: ./install.sh [-n] [-y] [-a /path/to/audacious]
#   -n  dry run: print what would happen, change nothing
#   -y  remove stale copies in other plugin dirs without asking
#   -a  target this audacious binary (default: first `audacious` in PATH)

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SRC_DIR/build"
PLUGIN="discord-rpc.so"

dry_run=0
assume_yes=0
aud_bin=""

while getopts "nya:h" opt; do
     case "$opt" in
          n) dry_run=1 ;;
          y) assume_yes=1 ;;
          a) aud_bin="$OPTARG" ;;
          *) sed -n '2,9p' "$0"; exit 0 ;;
     esac
done

run() {
     echo "+ $*"
     [[ $dry_run -eq 1 ]] || "$@"
}

# Use sudo only when the target isn't writable by us
as_root() {
     if [[ -w "$1" ]]; then shift; run "$@"; else shift; run sudo "$@"; fi
}

# === Locate the target Audacious === #

aud_bin="${aud_bin:-$(command -v audacious || true)}"
if [[ -z "$aud_bin" ]]; then
     echo "error: audacious not found in PATH (use -a)" >&2
     exit 1
fi
aud_bin="$(readlink -f "$aud_bin")"
prefix="$(dirname "$(dirname "$aud_bin")")"

pc_file=""
for d in lib lib64 lib/x86_64-linux-gnu share; do
     if [[ -f "$prefix/$d/pkgconfig/audacious.pc" ]]; then
          pc_file="$prefix/$d/pkgconfig/audacious.pc"
          break
     fi
done

plugin_dir=""
if [[ -n "$pc_file" ]]; then
     plugin_dir="$(pkg-config --variable=plugin_dir "$pc_file")"
fi
if [[ -z "$plugin_dir" ]]; then
     # Fall back to the conventional location under the binary's prefix
     for d in lib lib64; do
          if [[ -d "$prefix/$d/audacious/General" ]]; then
               plugin_dir="$prefix/$d/audacious"
               break
          fi
     done
fi
if [[ -z "$plugin_dir" ]]; then
     echo "error: could not determine plugin dir for $aud_bin" >&2
     exit 1
fi

dest="$plugin_dir/General"
echo "Audacious:  $aud_bin"
echo "pkg-config: ${pc_file:-<none>}"
echo "Install to: $dest/$PLUGIN"
echo

# === Build === #
# Point pkg-config at the target's audacious.pc so CMake checks the right one

export PKG_CONFIG_PATH="${pc_file:+$(dirname "$pc_file")}${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
run cmake -S "$SRC_DIR" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release
run cmake --build "$BUILD_DIR" -j"$(nproc)"

# === Install === #

as_root "$(dirname "$dest")" install -Dm755 "$BUILD_DIR/$PLUGIN" "$dest/$PLUGIN"

# === Stale copies in other plugin dirs === #

stale=()
for f in /usr/lib/audacious/General/$PLUGIN \
         /usr/lib64/audacious/General/$PLUGIN \
         /usr/local/lib/audacious/General/$PLUGIN \
         /usr/local/lib64/audacious/General/$PLUGIN \
         "$HOME"/.local/lib/audacious/General/$PLUGIN; do
     [[ -e "$f" ]] || continue
     f="$(readlink -f "$f")"  # /usr/lib64 is often a symlink to /usr/lib
     if [[ "$f" == "$(readlink -m "$dest/$PLUGIN")" ]] \
          || [[ " ${stale[*]} " == *" $f "* ]]; then
          continue
     fi
     stale+=("$f")
done

for f in "${stale[@]}"; do
     owner=""
     if command -v pacman >/dev/null; then
          owner="$(pacman -Qoq "$f" 2>/dev/null || true)"
     elif command -v dpkg >/dev/null; then
          owner="$(dpkg -S "$f" 2>/dev/null | cut -d: -f1 || true)"
     fi
     if [[ -n "$owner" ]]; then
          echo "note: $f belongs to package '$owner', leaving it alone"
          continue
     fi

     echo "Stale copy (another Audacious install would load this): $f"
     if [[ $assume_yes -eq 1 ]]; then
          ans=y
     elif [[ $dry_run -eq 1 ]]; then
          ans=n
     else
          read -rp "Remove it? [y/N] " ans
     fi
     if [[ "$ans" =~ ^[Yy]$ ]]; then
          as_root "$(dirname "$f")" rm -f "$f"
     fi
done

echo
echo "Done. Restart Audacious to load the new plugin."
if pgrep -x audacious >/dev/null; then
     echo "(Audacious is running now: quit it and start it again.)"
fi
