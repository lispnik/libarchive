#!/bin/sh
# Build the release la: bin/la with libarchive built in and its image
# compressed, checked with no libarchive installed, and packaged with its man
# page and shell completions as la-OS-ARCH.tar.gz.
#
#   ci/release-build.sh OS ARCH
#
# SBCL is built here too (ci/build-sbcl.sh), for core compression and because
# the binary carries SBCL's runtime: on Linux this runs inside an ubuntu:20.04
# container (see ci.yml), so the binary needs only glibc 2.28; on macOS the
# runtime targets macOS 11. Built tools are kept in .release/ for CI's cache.
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
    LIB=$CACHE/libarchive/libarchive-bundle.so
else
    LIB=$CACHE/libarchive/libarchive-bundle.dylib
fi

# libarchive first: its static zstd is what SBCL's core compression links.
if [ ! -f "$LIB" ]; then
    ci/build-libarchive.sh "$CACHE/libarchive"
fi
if [ ! -x "$CACHE/sbcl/bin/sbcl" ]; then
    ZSTD=$CACHE/libarchive/deps ci/build-sbcl.sh "$CACHE/sbcl"
fi
SBCL=$CACHE/sbcl/bin/sbcl

# Fasls of its own: any other SBCL's, even one of the same version, may have
# been built with other features and cannot be loaded.
export XDG_CACHE_HOME=$CACHE/fasl
rm -f bin/la bin/la.1
LA_BUNDLE_LIBARCHIVE=$LIB make la docs SBCL="$SBCL"
unset XDG_CACHE_HOME

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
        # LC_BUILD_VERSION's minos, or LC_VERSION_MIN_MACOSX's version.
        otool -l bin/la | grep -A4 -E 'LC_BUILD_VERSION|LC_VERSION_MIN_MACOSX' \
            | grep -E 'minos|version' || true ;;
esac
ci/cli-smoke.sh bin/la

mkdir -p dist
cp bin/la bin/la.1 bin/_la bin/la.bash LICENSE README.md dist/
tar -czf "la-$OS-$ARCH.tar.gz" -C dist la la.1 _la la.bash LICENSE README.md
ls -l "la-$OS-$ARCH.tar.gz"
