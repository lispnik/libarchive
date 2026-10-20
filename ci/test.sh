#!/bin/sh
# What CI runs. The last commands are `make test' and `make check' -- the same ones a
# developer runs -- so CI can't go green on something a developer couldn't reproduce.
set -eu

if [ ! -d ocicl ]; then
    echo "==> restoring vendored dependencies"
    # ocicl exits 0 when a download fails, so the presence of the directory is checked
    # rather than the exit status. Retried: ghcr.io fails often enough to be worth it.
    for attempt in 1 2 3; do
        ocicl install && test -d ocicl && break
        echo "==> ocicl install attempt $attempt did not produce ocicl/; retrying"
        sleep 5
    done
    test -d ocicl
fi

echo "==> toolchain on this runner"
sbcl --version
pkg-config --modversion libarchive 2>/dev/null || true
tar --version | head -1 || true

make test
make check
