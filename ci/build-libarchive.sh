#!/bin/sh
# Build a self-contained libarchive shared library for the la release binaries:
# zlib, bzip2, xz, zstd, lz4 and expat (and, on Linux, OpenSSL's libcrypto) are
# compiled as position-independent static libraries and linked into it, so it
# needs nothing but the C library (and, on macOS, the system frameworks).
#
#   ci/build-libarchive.sh PREFIX
#
# Leaves PREFIX/libarchive-bundle.so or .dylib, and prints its dependencies.
# Sources are pinned by SHA-256 and cached in PREFIX/src.
set -eu

PREFIX=$(mkdir -p "$1" && cd "$1" && pwd)
SRC=$PREFIX/src
BUILD=$PREFIX/build
DEPS=$PREFIX/deps
mkdir -p "$SRC" "$BUILD" "$DEPS"

OS=$(uname -s)
JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
export CFLAGS="-O2 -fPIC"
if [ "$OS" = Darwin ]; then
    # The library may be older than the SBCL runtime it ships with; it must not
    # be newer.
    export MACOSX_DEPLOYMENT_TARGET=11.0
fi
# Only what is built here: no Homebrew or distribution copies sneak in.
export PKG_CONFIG_PATH=$DEPS/lib/pkgconfig
export PKG_CONFIG_LIBDIR=$DEPS/lib/pkgconfig

fetch() {  # fetch URL SHA256
    file=$SRC/$(basename "$1")
    if [ ! -f "$file" ]; then
        curl -fsSL --retry 3 -o "$file.part" "$1"
        mv "$file.part" "$file"
    fi
    if command -v sha256sum >/dev/null; then
        echo "$2  $file" | sha256sum -c - >/dev/null
    else
        echo "$2  $file" | shasum -a 256 -c - >/dev/null
    fi
    rm -rf "$BUILD/$(basename "$1" | sed -E 's/\.tar\.(gz|bz2|xz)$//')"
    tar -xf "$file" -C "$BUILD"
}

step() { echo "==> $*"; }

LIBARCHIVE_VERSION=3.8.10

step zlib
fetch https://github.com/madler/zlib/releases/download/v1.3.2/zlib-1.3.2.tar.gz \
      bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16
(cd "$BUILD/zlib-1.3.2" && ./configure --static --prefix="$DEPS" >/dev/null && make -j"$JOBS" install >/dev/null)

step bzip2
fetch https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz \
      ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269
(cd "$BUILD/bzip2-1.0.8" &&
     make -j"$JOBS" libbz2.a CFLAGS="$CFLAGS -D_FILE_OFFSET_BITS=64" >/dev/null &&
     mkdir -p "$DEPS/include" "$DEPS/lib" &&
     cp bzlib.h "$DEPS/include/" && cp libbz2.a "$DEPS/lib/")

step xz
fetch https://github.com/tukaani-project/xz/releases/download/v5.8.4/xz-5.8.4.tar.gz \
      0014c7886930454fe8bd4228665b51af55eeae560ea135c9c4cd33f55b2591d9
(cd "$BUILD/xz-5.8.4" &&
     ./configure --prefix="$DEPS" --disable-shared --enable-static --with-pic \
                 --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo \
                 --disable-lzma-links --disable-scripts --disable-doc --disable-nls >/dev/null &&
     make -j"$JOBS" install >/dev/null)

step zstd
fetch https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz \
      eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3
(cd "$BUILD/zstd-1.5.7/lib" &&
     make -j"$JOBS" libzstd.a >/dev/null &&
     make install-static install-includes install-pc PREFIX="$DEPS" >/dev/null)

step lz4
fetch https://github.com/lz4/lz4/releases/download/v1.10.0/lz4-1.10.0.tar.gz \
      537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b
(cd "$BUILD/lz4-1.10.0/lib" &&
     make -j"$JOBS" liblz4.a >/dev/null &&
     make install PREFIX="$DEPS" BUILD_SHARED=no >/dev/null)

step expat
fetch https://github.com/libexpat/libexpat/releases/download/R_2_9_0/expat-2.9.0.tar.gz \
      16afbb9cefead2aa278105cf27d9f597bde7fbf3dbb85015857ca7ca6a4e89ba
(cd "$BUILD/expat-2.9.0" &&
     ./configure --prefix="$DEPS" --disable-shared --enable-static --with-pic \
                 --without-docbook --without-examples --without-tests --without-xmlwf >/dev/null &&
     make -j"$JOBS" install >/dev/null)

# macOS has CommonCrypto, which libarchive uses for zip AES and its digests.
# Elsewhere, libcrypto.
CRYPTO="-DENABLE_OPENSSL=OFF"
if [ "$OS" != Darwin ]; then
    step openssl
    fetch https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz \
          603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
    (cd "$BUILD/openssl-3.5.9" &&
         ./Configure no-shared no-tests no-docs no-module no-engine -fPIC \
                     --prefix="$DEPS" --libdir=lib >/dev/null &&
         make -j"$JOBS" build_libs >/dev/null &&
         make install_dev >/dev/null)
    CRYPTO="-DENABLE_OPENSSL=ON -DOPENSSL_USE_STATIC_LIBS=TRUE -DOPENSSL_ROOT_DIR=$DEPS"
fi

# Nothing the static libraries define is exported from the result, so nothing
# else in the process can bind to its zlib or libcrypto by accident.
case $OS in
    Darwin) LDFLAGS_SHARED="" ;;
    *)      LDFLAGS_SHARED="-Wl,--exclude-libs,ALL" ;;
esac

step libarchive $LIBARCHIVE_VERSION
fetch https://github.com/libarchive/libarchive/releases/download/v$LIBARCHIVE_VERSION/libarchive-$LIBARCHIVE_VERSION.tar.gz \
      a1bffbe5152cfe869751179e7b16648c87c461cb8c46eee75062efbe164cc57c
# shellcheck disable=SC2086
cmake -S "$BUILD/libarchive-$LIBARCHIVE_VERSION" -B "$BUILD/libarchive-cmake" \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX/install" \
      -DCMAKE_PREFIX_PATH="$DEPS" \
      -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS_SHARED" \
      -DZLIB_ROOT="$DEPS" -DZLIB_USE_STATIC_LIBS=ON \
      -DBZIP2_LIBRARIES="$DEPS/lib/libbz2.a" -DBZIP2_INCLUDE_DIR="$DEPS/include" \
      -DLIBLZMA_LIBRARY="$DEPS/lib/liblzma.a" -DLIBLZMA_INCLUDE_DIR="$DEPS/include" \
      -DZSTD_LIBRARY="$DEPS/lib/libzstd.a" -DZSTD_INCLUDE_DIR="$DEPS/include" \
      -DLZ4_LIBRARY="$DEPS/lib/liblz4.a" -DLZ4_INCLUDE_DIR="$DEPS/include" \
      -DEXPAT_LIBRARY="$DEPS/lib/libexpat.a" -DEXPAT_INCLUDE_DIR="$DEPS/include" \
      -DZLIB_LIBRARY="$DEPS/lib/libz.a" -DZLIB_INCLUDE_DIR="$DEPS/include" \
      $CRYPTO -DENABLE_MBEDTLS=OFF -DENABLE_NETTLE=OFF -DENABLE_MD=OFF -DENABLE_CNG=OFF \
      -DENABLE_LIBXML2=OFF -DENABLE_BSDXML=OFF -DENABLE_EXPAT=ON \
      -DENABLE_LIBB2=OFF -DENABLE_LZO=OFF -DENABLE_PCREPOSIX=OFF -DENABLE_PCRE2POSIX=OFF \
      -DENABLE_ACL=OFF -DENABLE_XATTR=ON -DENABLE_ICONV=ON -DENABLE_LIBGCC=OFF \
      -DENABLE_TAR=OFF -DENABLE_CPIO=OFF -DENABLE_CAT=OFF -DENABLE_UNZIP=OFF \
      -DENABLE_TEST=OFF -DENABLE_WERROR=OFF >"$BUILD/libarchive-cmake.log" \
    || { cat "$BUILD/libarchive-cmake.log"; exit 1; }
grep -E '^-- (Found|Could NOT|Looking for (EVP|CC_|AES|OPENSSL))' "$BUILD/libarchive-cmake.log" | sort -u || true
cmake --build "$BUILD/libarchive-cmake" --target archive -j"$JOBS" >/dev/null

case $OS in
    Darwin) built=$(ls "$BUILD"/libarchive-cmake/libarchive/libarchive.*.*.dylib | head -1)
            out=$PREFIX/libarchive-bundle.dylib
            cp "$built" "$out"
            # Its install name points into the build tree; nothing should look there.
            install_name_tool -id @rpath/libarchive.13.dylib "$out"
            codesign -f -s - "$out" 2>/dev/null
            echo "==> $out"; otool -L "$out" ;;
    *)      built=$(ls "$BUILD"/libarchive-cmake/libarchive/libarchive.so.*.*.* | head -1)
            out=$PREFIX/libarchive-bundle.so
            cp "$built" "$out"
            strip --strip-unneeded "$out"
            echo "==> $out"; ldd "$out" || true
            echo "glibc symbol versions needed:"
            objdump -T "$out" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -3 ;;
esac
ls -l "$out"
