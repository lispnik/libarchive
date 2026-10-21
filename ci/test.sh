#!/bin/sh
# What CI runs. The last commands are `make test' and `make check' -- the same ones a
# developer runs -- so CI can't go green on something a developer couldn't reproduce.
set -eu

ci/deps.sh

# LISP=ccl or ecl tests the library on another implementation; la is SBCL only.
LISP=${LISP:-sbcl}

echo "==> toolchain on this runner"
echo "LISP=$LISP"
case $LISP in
    *sbcl*) "$LISP" --version ;;
    *ecl*)  "$LISP" --version ;;
    *)      "$LISP" --no-init --batch --quiet --eval '(progn (princ (lisp-implementation-version)) (terpri) (quit))' </dev/null ;;
esac
pkg-config --modversion libarchive 2>/dev/null || true
tar --version | head -1 || true

make test LISP="$LISP"
make check LISP="$LISP"
make examples LISP="$LISP"
case $LISP in
    *sbcl*) make la; make cli-test ;;
esac
