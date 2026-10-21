# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

CFFI bindings to **libarchive** for Common Lisp (tested on SBCL, CCL and ECL; the
`la` tool is SBCL only), in two layers: a generated raw layer over
every function and constant in `archive.h`/`archive_entry.h`, and an ergonomic layer
(readers, writers, entries, extraction and disk archiving). Developed on macOS arm64
against Homebrew libarchive 3.8.9, which is keg-only at `/opt/homebrew/opt/libarchive`.

## Commands

Dependencies are vendored under `ocicl/` (restore with `ocicl install`).

```sh
make test       # FiveAM suite; exits non-zero on failure (LISP=ecl or ccl: on those)
make check      # test, then load and print version + export count
make examples   # every examples/*.lisp in its own image; they ASSERT their output
make la         # bin/la, the libarchive/cli system dumped with program-op
make cli-test   # libarchive/cli/tests in-process, then ci/cli-smoke.sh bin/la
make generate   # rerun tools/gen-ffi.py against the installed headers
make clean
```

To run one test from a REPL:
`(fiveam:run! 'libarchive/tests::extract-refuses-escaping-names)`. Suites:
`libarchive-symbols`, `-entries`, `-roundtrip`, `-streams`, `-callbacks`, `-encryption`,
`-disk`, `-errors`, `-hygiene` (last; it asserts that the client-data registry is empty).

CI (`.github/workflows/ci.yml`) has three jobs, all on every push to main and on
`workflow_dispatch` (other branches only run when dispatched: `gh workflow run ci.yml
--ref BRANCH`):
- **`test`** runs `ci/test.sh`: `ci/deps.sh` (`ocicl install` if `ocicl/` is absent),
  then `make test check examples la cli-test`. On Ubuntu 24.04 x86_64 and aarch64 (apt
  SBCL, libarchive 3.7.2, so it covers an older library and the Linux
  `mode_t`/`dev_t` sizes) and macOS 15 arm64 and Intel (Homebrew).
- **`other-lisps`**: the same script with `LISP=` CCL 1.13 and Ubuntu's ECL 21.2,
  library only.
- **`build`**: the release `la`, via `ci/release-build.sh`. `ci/build-libarchive.sh`
  builds libarchive 3.8.10 as one shared library with its compression and crypto
  libraries static inside, and `LA_BUNDLE_LIBARCHIVE` builds it into the image. Linux
  builds in an `ubuntu:20.04` container. SBCL is built from source on every
  platform (`ci/build-sbcl.sh`, with core compression and libarchive's static zstd),
  because the dumped binary carries SBCL's runtime and so its glibc or macOS floor
  (macOS 11). The result is checked on glibc 2.28 (AlmaLinux 8). `.release/` caches
  the built toolchain, and `.release/fasl` keeps its fasls apart from any other
  SBCL's (same version, different features: they will not load).

`ocicl/` is gitignored, and `ocicl.csv` pins it.

**Releasing:** bump `*version*` in `cli/main.lisp` and every `:version` in the `.asd`,
then push a `v*` tag. The `release` job publishes the four `la-<os>-<arch>.tar.gz` and
`SHA256SUMS`, then regenerates `Formula/la.rb` in github.com/lispnik/homebrew-tap with
`ci/tap-formula.sh` and pushes it, using the `TAP_DEPLOY_KEY` secret (a deploy key with
write access to the tap only).
The ocicl request is ocicl/request-system-additions-here#78.

The Makefile's `BOOT` is a **hermetic** source registry: this tree as a `:tree`,
ignoring inherited configuration. Copy it at a REPL rather than relying on `~/.sbclrc`.

## Architecture

```
libarchive/ffi    cffi + bordeaux-threads                     generated raw layer
libarchive        ffi + trivial-garbage + babel (+ uax-15 off SBCL on macOS)
libarchive/tests  libarchive + fiveam + trivial-gray-streams
libarchive/cli    libarchive + clingon + sb-posix                the la binary (cli/)
libarchive/cli/tests  libarchive/cli + fiveam                    cli-tests/
```

### la (cli/)

Laid out like ud18's CLI: each command file registers a maker with
`register-command`, and `main.lisp` builds the clingon tree on every `run`.
- **`run`** takes argv and *returns* the exit code: 0, 1 for failure, 2 for usage. It
  calls `clingon:parse-command-line` and the handler itself, because `clingon:run`
  always exits.
- **`main`** is the binary's entry point.
- **Paths** are merged with `*default-pathname-defaults*` and the process never
  `chdir`s, so the tests bind it to a scratch directory.
- **Standard input** (`-`) is spooled to a temp file, because `la x` reads the
  archive twice (once for the top-level roots, once to extract).
- **Not covered in-process:** stdin/stdout, real exit codes and the bundled library.
  `ci/cli-smoke.sh` tests those against the built binary.
- **Bundled libarchive** (`cli/bundle.lisp`): `main`, not `run`, writes the embedded
  bytes once to `~/.cache/la/libarchive-<fnv>.dylib`, compares it byte for byte on
  every start, and loads it from there. A fixed path matters: macOS vets each new
  library file, about 120 ms a run when it was a fresh temp file. If the cache fails,
  an `mkstemp` file is loaded and unlinked. `LA_LIBARCHIVE=system` or `=FILE`
  overrides; `la --version` says which is in use.
- **Image compression**: `libarchive/cli`'s `:perform` for `program-op` passes
  `:compression` when the SBCL has `:sb-core-compression` (Homebrew's doesn't).
- **`cli/docs.lisp`** writes `la.1` (own mdoc writer: clingon's errors on aliases),
  `_la` (own zsh writer, with file completion) and `la.bash` (calls clingon's
  `--bash-completions`). `make docs`. A command's `:description` is one line (menus,
  `--help` listings); details go in `:long-description`.
- **`la rm`** and **`la a -r`** both go through `rewrite-archive`.
- **`la a -r`** spools the new files to a pax file first, so their names are known,
  then writes old (unreplaced) entries and the spool with `transfer-entry` to a temp
  file beside the archive, and renames it over the original.
- **`la x ENTRY...`** filters through `make-selector`; patterns match original names,
  before `--strip-components`.

`cli/formats.lisp` holds the single extension table, used for writing and for
`archive-stem`.
- **Bare-filter extensions** (`.gz`, `.xz`, …) mean the `:raw` format.
- **`la x` forces raw for those names,** because format detection reads a one-line
  text file as an mtree manifest.
- **warc, ar and raw can't store directories,** so `la a` passes
  `archive-directory :directories nil` for them.

- **Generated files**: `src/ffi-archive.lisp`, `src/ffi-entry.lisp`,
  `src/ffi-names.lisp`, `src/constants.lisp`. Don't hand-edit them. Change
  `tools/gen-ffi.py` and run `make generate`. The generator maps `const char *` to
  `:string` both ways, other pointers to `:pointer`, and renames `archive_*_open_FILE`
  to `%archive-*-open-stdio`, because they would otherwise fold onto `open_file`. It drops
  `_WIN32`-only declarations.
- `mode_t`/`dev_t` are per-platform `defctype`s in `src/types.lisp`. They aren't
  groveled, so no C compiler is needed.
- Nothing calls into C at load time. `load-libraries` is lazy and is invoked by every
  ergonomic entry point.

### Callbacks: no closures, on purpose

Every libarchive callback takes a client-data `void *`. `src/registry.lisp` maps an
integer key (passed as that pointer) to the Lisp handle, and `src/callbacks.lisp` has
exactly one `defcallback` per callback type. Do **not** add cffi-callback-closures. It
would only be needed for a C callback without user data, and libarchive has none.

Every callback body goes through `define-guarded-callback`. A Lisp condition is stored
as the handle's `pending-error`, reported to libarchive via `archive_set_error`, and the
callback returns failure. `check-result` then re-signals the original condition. Never
let a condition unwind through a C frame.

### Handles and entries

`archive-reader` ⊃ `disk-reader`, `archive-writer` ⊃ `disk-writer`. This mirrors
libarchive's read/write split, which decides which close and free functions apply.
`close-archive` is idempotent, frees foreign buffers, unregisters the key and runs
cleanups (`finish-output`, collecting `:octets`).

Readers use `archive_read_next_header2` into one entry they own. The Lisp `entry` that
`next-entry` returns is *borrowed* and gets invalidated (null pointer) on the next call
or close. Owned entries (`make-entry`, `copy-entry`) have a trivial-garbage finalizer
that `free-entry` cancels.

### Gotchas found the hard way

- `ARCHIVE_RETRY` (-10) is numerically *greater* than `ARCHIVE_WARN` (-20). Test
  `code >= 0` for success, never `code >= WARN`.
- From a format setter, `ARCHIVE_WARN` means "not supported in this build" and leaves no
  format set (e.g. xar without libxml2). `open-archive-writer` treats it as failure. From
  `archive_read_support_*`, WARN means "via an external program" and is ignored.
- libarchive pads the last block *after* compression for callback/memory output. That
  breaks gzip consumers (trailing garbage) and libarchive's own zstd reader. The writer
  sets `bytes_in_last_block` to 1 except for uncompressed tar/cpio.
- Lisps don't call `setlocale`, and libarchive converts every name through the locale:
  under "C" the pax writer dereferences a failed conversion (crash), ustar writes "",
  7z writes a damaged archive, cpio refuses. `load-libraries` switches `LC_CTYPE` to
  UTF-8 (`ensure-utf-8-locale`). It is locked, too: concurrent first calls crashed.
- On Apple, libarchive returns names in NFD; `native-string` (entry.lisp) recomposes
  to NFC. The pax writer stores each xattr twice (LIBARCHIVE. and SCHILY.) and the
  reader returns both; `entry-xattrs` dedupes. A negated module option is
  `module:!opt`, not `!module:opt`.
- `archive_filter_name(0)` is the filter nearest the format (innermost), not the
  outermost. Tar hard links read back with file type 0, so `entry-type` is NIL.
- `extract-archive` prefixes the target directory onto entry names (its truename, because
  macOS `/tmp` is a symlink and `SECURE_SYMLINKS` would refuse it). So the names libarchive
  sees are absolute, and `SECURE_NOABSOLUTEPATHS` can't be used. `check-extract-name`
  enforces it on the original names instead.
- A zip read from a stream that can't seek has no file types (they are in the central
  directory): a symlink reads as a regular file whose data is its target.
- ZipCrypto checks a passphrase with one byte, so about 1 wrong passphrase in 256
  passes the check and then fails in decompression. Tests that offer wrong
  passphrases use `encrypted-zip-rejecting`.
- Portability: the library avoids `sb-` symbols (bordeaux-threads for the load lock,
  `uiop:register-image-restore-hook`, uax-15 for NFC off SBCL). The tests use
  libarchive's own `archive_read_disk_entry_from_file` for lstat and readlink.
