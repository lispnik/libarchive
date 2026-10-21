#!/bin/sh
# Smoke tests for the built la binary: what the in-process suite cannot reach.
# Real exit codes, standard input and output as archives, and archives made by
# la read by the system's own tar and unzip (and the other way round).
#
#   ci/cli-smoke.sh bin/la
set -eu

LA=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
WORK=$(mktemp -d "${TMPDIR:-/tmp}/la-smoke.XXXXXX")
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
cd "$WORK"

pass=0
check() {  # check DESCRIPTION COMMAND...
    desc=$1; shift
    if "$@" >/dev/null 2>&1; then
        pass=$((pass + 1))
    else
        echo "FAIL: $desc" >&2
        echo "  \$ $*" >&2
        "$@" >&2 || true
        exit 1
    fi
}
has() { command -v "$1" >/dev/null 2>&1; }

mkdir -p proj/src
echo "read me" > proj/README
echo "int main(void) { return 0; }" > proj/src/main.c
echo "loose" > loose.txt

check "version names libarchive"      sh -c "'$LA' --version | grep -q libarchive"
check "no arguments is a usage error" sh -c "'$LA'; test \$? -eq 2"
check "unknown option is a usage error" sh -c "'$LA' x --bogus x.tar; test \$? -eq 2"

# Create, list, test, extract.
check "a .tar.zst"         "$LA" a -q p.tar.zst proj loose.txt
check "l lists 5 entries"  sh -c "test \$('$LA' l p.tar.zst | wc -l) -eq 5"
check "t passes"           "$LA" t -q p.tar.zst
check "x multi-root"       "$LA" x -q p.tar.zst -C out
check "  into out/p/"      test -f out/p/proj/src/main.c
check "  content intact"   cmp proj/src/main.c out/p/proj/src/main.c

check "l | head is not an error" sh -c "'$LA' l -l p.tar.zst 2>err | head -1 >/dev/null; test ! -s err"

# Choosing entries, appending, comparing.
check "x chosen entries"   "$LA" x -q p.tar.zst -C chosen 'proj/src/*.c'
check "  only those"       sh -c "test -f chosen/proj/src/main.c && test ! -e chosen/proj/README"
check "diff of a fresh copy" "$LA" diff -q p.tar.zst -C out/p
check "diff sees a change" sh -c "echo x >> out/p/loose.txt; '$LA' diff -q p.tar.zst -C out/p; test \$? -eq 1"
check "a -r appends"       sh -c "'$LA' a -r -q p.tar.zst out/p/loose.txt && test \$('$LA' l p.tar.zst | wc -l) -eq 6"

check "cat to stdout"       sh -c "test \"\$('$LA' cat p.tar.zst proj/README)\" = 'read me'"
check "rm removes"           sh -c "'$LA' rm -q p.tar.zst out && test \$('$LA' l p.tar.zst | wc -l) -eq 5"
check "-T threads"           sh -c "'$LA' a -q -T 0 threads.tar.zst proj && '$LA' t -q threads.tar.zst"

# Bare compression both ways.
check "a .gz of one file"  "$LA" a -q loose.txt.gz loose.txt
check "x .gz decompresses" "$LA" x -q loose.txt.gz -C gz
check "  to loose.txt"     cmp loose.txt gz/loose.txt

# Standard output and input.
check "a to stdout"        sh -c "'$LA' a -q -F tar -z gzip - proj > piped.tgz"
check "l from stdin"       sh -c "'$LA' l - < piped.tgz | grep -q proj/README"
check "x from stdin"       sh -c "'$LA' x -q - -C fromstdin < piped.tgz"
check "  extracted"        test -f fromstdin/proj/README
check "stdout needs -F"    sh -c "'$LA' a - proj > /dev/null; test \$? -eq 2"

# Errors exit 1 and leave nothing behind.
check "missing archive"    sh -c "'$LA' x nonesuch.zip; test \$? -eq 1"
check "refuses to clobber" sh -c "'$LA' a p.tar.zst loose.txt; test \$? -eq 1"
check "failed a leaves no file" sh -c "'$LA' a broken.tar proj nonesuch; test \$? -eq 1 && test ! -e broken.tar"

# Interoperability with the system's tools.
if has tar; then
    check "system tar reads la's .tar.gz" sh -c "'$LA' a -q sys.tar.gz proj && tar -tzf sys.tar.gz | grep -q proj/src/main.c"
    check "la reads system tar's .tar.gz" sh -c "tar -czf fromtar.tar.gz proj && '$LA' x -q fromtar.tar.gz -C t && test -f t/proj/README"
fi
if has unzip; then
    check "unzip reads la's zip"  sh -c "'$LA' a -q sys.zip proj && unzip -tq sys.zip"
fi
if has zip; then
    check "la reads Info-ZIP's zip" sh -c "zip -qr fromzip.zip proj && '$LA' x -q fromzip.zip -C z && test -f z/proj/src/main.c"
fi

echo "cli-smoke: $pass checks passed"
