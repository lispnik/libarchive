#!/bin/sh
# Build the release la: bin/la with libarchive built in, checked with no
# libarchive installed, and packaged as la-OS-ARCH.tar.gz.
#
#   ci/release-build.sh OS ARCH
#
# On Linux this runs inside an ubuntu:20.04 container (see ci.yml), so the
# binary needs only glibc 2.31. Built tools are kept in .release/ for CI's cache.
set -eu

OS=$1 ARCH=$2
CMAKE_VERSION=4.4.4
ROOT=$(pwd)
CACHE=$ROOT/.release

if [ "$OS" = linux ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    # sbcl is only the host for building a current SBCL; zip, unzip and tar
    # are for the smoke test. No libarchive: the point is to run without one.
    apt-get install -y -qq --no-install-recommends \
        build-essential curl ca-certificates perl pkg-config bzip2 xz-utils \
        sbcl zip unzip tar make >/dev/null
    # 20.04's CMake is older than libarchive needs; Kitware's runs on anything.
    if [ ! -x "$CACHE/cmake/bin/cmake" ]; then
        mkdir -p "$CACHE/cmake"
        curl -fsSL --retry 3 "https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/cmake-$CMAKE_VERSION-linux-$(uname -m).tar.gz" \
            | tar -xz -C "$CACHE/cmake" --strip-components 1
    fi
    export PATH=$CACHE/cmake/bin:$PATH
    if [ ! -x "$CACHE/sbcl/bin/sbcl" ]; then
        ci/build-sbcl.sh "$CACHE/sbcl"
    fi
    SBCL=$CACHE/sbcl/bin/sbcl
    LIB=$CACHE/libarchive/libarchive-bundle.so
else
    SBCL=sbcl
    LIB=$CACHE/libarchive/libarchive-bundle.dylib
fi

if [ ! -f "$LIB" ]; then
    ci/build-libarchive.sh "$CACHE/libarchive"
fi

rm -f bin/la
LA_BUNDLE_LIBARCHIVE=$LIB make la SBCL="$SBCL"

echo "==> checking"
bin/la --version
bin/la --version | grep -q '(bundled)'
case $OS in
    linux)
        if ldconfig -p | grep -q libarchive; then
            echo "a libarchive is installed; the check below would prove nothing" >&2
            exit 1
        fi
        echo "glibc symbol versions bin/la needs:"
        objdump -T bin/la | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1 ;;
    macos)
        otool -L bin/la
        otool -l bin/la | grep -A3 LC_BUILD_VERSION | grep minos ;;
esac
ci/cli-smoke.sh bin/la

mkdir -p dist
cp bin/la LICENSE README.md dist/
tar -czf "la-$OS-$ARCH.tar.gz" -C dist la LICENSE README.md
ls -l "la-$OS-$ARCH.tar.gz"
