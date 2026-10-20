# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

CFFI bindings to **libarchive** for SBCL, in two layers: a generated raw layer over
every function and constant in `archive.h`/`archive_entry.h`, and an ergonomic layer
(readers, writers, entries, extraction and disk archiving). Developed on macOS arm64
against Homebrew libarchive 3.8.9, which is keg-only at `/opt/homebrew/opt/libarchive`.

## Commands

Dependencies are vendored under `ocicl/` (restore with `ocicl install`).

```sh
make test       # FiveAM suite; exits non-zero on failure
make check      # test, then load and print version + export count
make generate   # rerun tools/gen-ffi.py against the installed headers
make clean
```

To run one test from a REPL:
`(fiveam:run! 'libarchive/tests::extract-refuses-escaping-names)`. Suites:
`libarchive-symbols`, `-entries`, `-roundtrip`, `-streams`, `-callbacks`, `-encryption`,
`-disk`, `-errors`, `-hygiene` (last; it asserts that the client-data registry is empty).

CI (`.github/workflows/ci.yml`) runs `ci/test.sh`, which is `ocicl install` if `ocicl/`
is absent, then `make test` and `make check`. It runs on Ubuntu 24.04 x86_64 and aarch64
(apt SBCL, libarchive 3.7.2, so it covers an older library and the Linux
`mode_t`/`dev_t` sizes) and on macOS 15 arm64 (Homebrew). `ocicl/` is gitignored, and
`ocicl.csv` pins it.

The Makefile's `BOOT` is a **hermetic** source registry: this tree as a `:tree`,
ignoring inherited configuration. Copy it at a REPL rather than relying on `~/.sbclrc`.

## Architecture

```
libarchive/ffi    cffi                                        generated raw layer
libarchive        ffi + bordeaux-threads + trivial-garbage + babel
libarchive/tests  libarchive + fiveam
```

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
- `extract-archive` prefixes the target directory onto entry names (its truename, because
  macOS `/tmp` is a symlink and `SECURE_SYMLINKS` would refuse it). So the names libarchive
  sees are absolute, and `SECURE_NOABSOLUTEPATHS` can't be used. `check-extract-name`
  enforces it on the original names instead.
