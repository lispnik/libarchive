#!/bin/sh
# Make la_VERSION_ARCH.deb and la-VERSION-1.ARCH.rpm from la-linux-ARCH.tar.gz,
# with nfpm (no dpkg or rpmbuild needed, and so it runs on any Linux).
#
#   ci/linux-packages.sh ARCH        ARCH is x86_64 or aarch64
#
# The version is la's own (*version* in cli/main.lisp). The packages hold the
# same files as the tarball, where each system expects them; they depend only
# on glibc 2.28 or later, which is what the binary needs.
set -eu

ARCH=$1
NFPM_VERSION=2.47.0
VERSION=$(sed -n 's/^(defparameter \*version\* "\(.*\)")$/\1/p' cli/main.lisp)
[ -n "$VERSION" ] || { echo "no *version* in cli/main.lisp" >&2; exit 1; }

case $ARCH in
    x86_64)  GOARCH=amd64 NFPM_ARCH=x86_64
             NFPM_SHA256=0660ca602b2d2d2ae4781a06c692b3eeb9d437ffea05b831d76e41f4a3188783 ;;
    aarch64) GOARCH=arm64 NFPM_ARCH=arm64
             NFPM_SHA256=1c0f5f2999b9a974bfb04fdb0cc3306096de530ac5dbb25d739cc5f5219c919c ;;
    *) echo "unknown architecture $ARCH" >&2; exit 1 ;;
esac

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# NFPM=path uses that nfpm instead (to try this out elsewhere).
if [ -n "${NFPM:-}" ]; then
    cp "$NFPM" "$WORK/nfpm"
else
    NFPM_TARBALL=nfpm_${NFPM_VERSION}_Linux_$NFPM_ARCH.tar.gz
    curl -fsSL --retry 3 -o "$WORK/$NFPM_TARBALL" \
         "https://github.com/goreleaser/nfpm/releases/download/v$NFPM_VERSION/$NFPM_TARBALL"
    echo "$NFPM_SHA256  $WORK/$NFPM_TARBALL" | sha256sum -c - >/dev/null
    tar -xzf "$WORK/$NFPM_TARBALL" -C "$WORK" nfpm
fi

mkdir "$WORK/files"
tar -xzf "la-linux-$ARCH.tar.gz" -C "$WORK/files"
# Debian wants man pages compressed; -n keeps the result reproducible.
gzip -9n "$WORK/files/la.1"

cat > "$WORK/nfpm.yaml" <<YAML
name: la
arch: $GOARCH
platform: linux
version: $VERSION
release: 1
section: utils
priority: optional
maintainer: Matthew Kennedy
homepage: https://github.com/lispnik/libarchive
license: MIT
description: |
  Extract, create, list and compare archives in every format libarchive handles.
  la reads and writes tar, zip, 7z, cpio, iso9660, ar, shar, mtree and warc,
  with any of libarchive's compressions, and reads rar, cab and lha too. It is
  one binary, with libarchive built in.
overrides:
  deb:
    depends: ["libc6 (>= 2.28)"]
  rpm:
    depends: ["glibc >= 2.28"]
contents:
  - src: $WORK/files/la
    dst: /usr/bin/la
    file_info: { mode: 0755 }
  - src: $WORK/files/la.1.gz
    dst: /usr/share/man/man1/la.1.gz
  - src: $WORK/files/la.bash
    dst: /usr/share/bash-completion/completions/la
  - src: $WORK/files/_la
    dst: /usr/share/zsh/vendor-completions/_la
    packager: deb
  - src: $WORK/files/_la
    dst: /usr/share/zsh/site-functions/_la
    packager: rpm
  - src: $WORK/files/LICENSE
    dst: /usr/share/doc/la/copyright
    packager: deb
  - src: $WORK/files/LICENSE
    dst: /usr/share/licenses/la/LICENSE
    packager: rpm
    type: license
  - src: $WORK/files/README.md
    dst: /usr/share/doc/la/README.md
YAML

for packager in deb rpm; do
    "$WORK/nfpm" package --config "$WORK/nfpm.yaml" --packager "$packager" --target .
done
ls -l la_"$VERSION"-1_*.deb la-"$VERSION"-1.*.rpm
