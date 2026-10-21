#!/bin/sh
# Build SBCL from source into PREFIX, with whatever Lisp is on PATH as the host.
# Used for the Linux release binaries: an executable dumped by SBCL carries
# SBCL's runtime, so the oldest glibc la runs on is the one SBCL was built on.
#
#   ci/build-sbcl.sh PREFIX
set -eu

VERSION=2.6.8
SHA256=ad5126dfdfba5db27ee77bcc25893020fe522d0b7653d45b4c4795ade3ddc23d

PREFIX=$(mkdir -p "$1" && cd "$1" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

curl -fsSL --retry 3 -o "$WORK/sbcl.tar.bz2" \
     "https://downloads.sourceforge.net/project/sbcl/sbcl/$VERSION/sbcl-$VERSION-source.tar.bz2"
echo "$SHA256  $WORK/sbcl.tar.bz2" | sha256sum -c - >/dev/null
tar -xjf "$WORK/sbcl.tar.bz2" -C "$WORK"
cd "$WORK/sbcl-$VERSION"
echo "==> building SBCL $VERSION with $(sbcl --version)"
sh make.sh --prefix="$PREFIX" --with-sb-thread > "$WORK/build.log" 2>&1 || { tail -60 "$WORK/build.log"; exit 1; }
sh install.sh > /dev/null
"$PREFIX/bin/sbcl" --version
