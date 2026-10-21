#!/bin/sh
# Build SBCL from source into PREFIX, with whatever SBCL is on PATH as the host,
# for the release binaries:
#
# - An executable dumped by SBCL carries SBCL's runtime, so the oldest glibc
#   (Linux) or macOS release la runs on is the one this SBCL was built for.
# - With core compression, the image in the executable is zstd-compressed,
#   about a quarter of its size. zstd is linked in statically, from ZSTD (the
#   static, position-independent copy ci/build-libarchive.sh builds), so the
#   runtime still needs nothing but the C library.
#
#   ZSTD=DIR ci/build-sbcl.sh PREFIX
set -eu

VERSION=2.6.8
SHA256=ad5126dfdfba5db27ee77bcc25893020fe522d0b7653d45b4c4795ade3ddc23d

PREFIX=$(mkdir -p "$1" && cd "$1" && pwd)
: "${ZSTD:?set ZSTD to a directory with include/zstd.h and lib/libzstd.a}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

curl -fsSL --retry 3 -o "$WORK/sbcl.tar.bz2" \
     "https://downloads.sourceforge.net/project/sbcl/sbcl/$VERSION/sbcl-$VERSION-source.tar.bz2"
if command -v sha256sum >/dev/null; then
    echo "$SHA256  $WORK/sbcl.tar.bz2" | sha256sum -c - >/dev/null
else
    echo "$SHA256  $WORK/sbcl.tar.bz2" | shasum -a 256 -c - >/dev/null
fi
tar -xjf "$WORK/sbcl.tar.bz2" -C "$WORK"
cd "$WORK/sbcl-$VERSION"

# First in the search paths, so -lzstd finds the static library before any
# shared one (Homebrew's, on macOS, is appended after these by SBCL's Config).
export CPATH=$ZSTD/include LIBRARY_PATH=$ZSTD/lib
if [ "$(uname -s)" = Darwin ]; then
    export MACOSX_DEPLOYMENT_TARGET=11.0
fi

echo "==> building SBCL $VERSION with $(sbcl --version)"
sh make.sh --prefix="$PREFIX" --with-sb-thread --with-sb-core-compression \
   > "$WORK/build.log" 2>&1 || { tail -60 "$WORK/build.log"; exit 1; }
sh install.sh > /dev/null

if [ "$(uname -s)" = Darwin ]; then
    otool -L "$PREFIX/bin/sbcl"
    deps=$(otool -L "$PREFIX/bin/sbcl")
else
    ldd "$PREFIX/bin/sbcl"
    deps=$(ldd "$PREFIX/bin/sbcl")
fi
if echo "$deps" | grep -q zstd; then
    echo "SBCL's runtime links a shared zstd; it must be static" >&2
    exit 1
fi
"$PREFIX/bin/sbcl" --noinform --non-interactive --no-userinit --no-sysinit \
    --eval '(progn (princ (lisp-implementation-version)) (assert (member :sb-core-compression *features*)))'
echo
