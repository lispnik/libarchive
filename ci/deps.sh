#!/bin/sh
# Restore the vendored dependencies in ocicl/ if they are not there (CI caches them).
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
