#!/bin/sh
# Build the JCF (JEDI Code Format) command-line formatter from the Lazarus
# component sources and install it to ~/.local/bin/jcf.
#
# JCF ships as source with Lazarus (components/jcf2) but is not built or put on
# PATH by default. GotBox uses it as its canonical Pascal formatter.
set -e

DEST="${DEST:-$HOME/.local/bin}"
LAZBUILD="${LAZBUILD:-lazbuild}"

# locate the jcf2 component tree inside the Lazarus install
JCF2=""
for d in /usr/share/lazarus/*/components/jcf2 \
         /usr/lib/lazarus/*/components/jcf2 \
         "$HOME"/lazarus/components/jcf2; do
  [ -f "$d/CommandLine/Lazarus/jcf.lpi" ] && JCF2="$d" && break
done

if [ -z "$JCF2" ]; then
  echo "Could not find Lazarus jcf2 component sources." >&2
  echo "Install Lazarus, or set JCF2 to the components/jcf2 path." >&2
  exit 1
fi

# the source tree is usually read-only (/usr/share), so build in a temp copy
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -r "$JCF2" "$WORK/jcf2"

echo "Building JCF from $JCF2 ..."
( cd "$WORK/jcf2/CommandLine/Lazarus" && "$LAZBUILD" jcf.lpi )

BIN="$(find "$WORK/jcf2" -type f -name jcf | head -n1)"
[ -n "$BIN" ] || { echo "build produced no jcf binary" >&2; exit 1; }

mkdir -p "$DEST"
install -m 755 "$BIN" "$DEST/jcf"
echo "Installed $DEST/jcf"
echo "Ensure $DEST is on your PATH."
