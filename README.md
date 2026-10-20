# libarchive

Common Lisp (SBCL) bindings to [libarchive](https://libarchive.org): read, write and
extract tar (pax, ustar, gnutar, v7), zip, 7z, cpio, iso9660, ar, xar, rar (read), cab
(read), with gzip, bzip2, xz, lzma, zstd, lz4, lzip, compress, uuencode and base64 filters.

Two layers, one package (`libarchive`):

- **`libarchive/ffi`**: every function in `archive.h` and `archive_entry.h` (453 of them)
  as `%archive-...`, and every integer `ARCHIVE_*`/`AE_*` macro as `+archive-...+`.
  Generated from the headers by `tools/gen-ffi.py`. Depends only on CFFI, and loads even
  where libarchive is not installed.
- **`libarchive`**: readers, writers, entries, and extraction to and archiving from disk.
  Readers and writers work on files, octet vectors, and any binary Lisp stream.

## Install

```sh
brew install libarchive        # or: apt install libarchive13
ocicl install                  # restores ocicl/ from ocicl.csv
```

```lisp
(asdf:load-system :libarchive)
```

## Use

The [tutorial](docs/tutorial.md) walks through everything below in more depth, and
[`examples/`](examples/) has a runnable, self-checking program for each part of it
(`make examples`).

```lisp
(use-package :libarchive)

;; Write a .tar.gz to a file (or :octets, or a stream)
(with-archive-writer (w #p"/tmp/x.tar.gz" :format :pax-restricted :filters :gzip)
  (add-entry w "docs/")
  (add-entry w "docs/hello.txt" :data "hello, world")
  (add-entry w "docs/data.bin" :data (make-array 4 :element-type '(unsigned-byte 8)
                                                   :initial-contents '(1 2 3 4))
                               :perm #o600)
  (add-entry w "docs/latest" :symlink "hello.txt")
  (add-entry w "docs/hosts" :data #p"/etc/hosts"))   ; data from a file

;; Read: the format and compression are detected
(with-archive-reader (r #p"/tmp/x.tar.gz")
  (do-archive-entries (e r)
    (format t "~A ~A ~D~%" (entry-strmode e) (entry-pathname e) (entry-size e))
    (when (eq (entry-type e) :regular)
      (print (read-entry-string r)))))       ; or READ-ENTRY-DATA, COPY-ENTRY-DATA

;; In memory
(let ((zip (with-archive-to-octets (w :format :zip)
             (add-entry w "a.txt" :data "a"))))
  (archive-entry-names zip))                 ; => ("a.txt")

;; Encrypted zip
(with-archive-writer (w "s.zip" :format :zip :passphrase "pw"
                                :options '(("zip:encryption" . "aes256")))
  (add-entry w "secret" :data "..."))
(with-archive-reader (r "s.zip" :passphrase '("guess" "pw"))   ; or a function
  ...)

;; Disk
(extract-archive #p"/tmp/x.tar.gz" #p"/tmp/out/")    ; => list of names extracted
(archive-directory #p"/tmp/out/" #p"/tmp/out.tar.zst" :format :pax-restricted
                   :filters :zstd
                   :filter (lambda (e) (not (search "/.git" (entry-pathname e)))))
```

### Entries

`next-entry` returns a **borrowed** entry. libarchive reuses the struct, so the entry is
invalidated by the next `next-entry` and by closing the reader. After that, any accessor
signals an error instead of returning another entry's fields. Call `copy-entry` to keep
one. `make-entry`/`with-entry` create owned entries.

Accessors are `setf`-able: `entry-pathname`, `entry-type` (`:regular` `:directory`
`:symlink` `:fifo` `:socket` `:character-device` `:block-device`), `entry-size`,
`entry-perm`, `entry-mode`, `entry-uid`/`gid`/`uname`/`gname`, `entry-symlink`,
`entry-hardlink`, `entry-mtime`/`atime`/`ctime`/`birthtime`. Times are **universal times**,
and NIL means unset. Strings go through libarchive's `_utf8` accessors, so results don't
depend on the process locale.

### Errors

| libarchive      | Lisp                                                            |
|-----------------|-----------------------------------------------------------------|
| `ARCHIVE_WARN`  | `archive-warning`, signalled with `warn`; the operation succeeded |
| `ARCHIVE_RETRY` | `archive-retry`                                                 |
| `ARCHIVE_FAILED`| `archive-error`; the archive is still usable                    |
| `ARCHIVE_FATAL` | `archive-fatal-error`; the archive can only be closed           |

Each condition carries `archive-condition-message` (libarchive's `archive_error_string`),
`-errno`, `-code` and `-operation`. An error raised by *your* code inside a callback (a
stream's `read-sequence`, a passphrase function, a filter) is re-signalled as itself
after libarchive returns. It never unwinds through C.

`extract-archive` refuses entries with absolute names or `..` components, and offers a
`skip-entry` restart for those and for any other per-entry failure.

### Callbacks

Every callback libarchive takes comes paired with a `void *` of client data. So this
binding uses a fixed set of `cffi:defcallback`s that look the Lisp handle up by a
registry key passed as that pointer. Runtime-minted closures (such as
cffi-callback-closures) aren't needed, and neither is libffi.

## Notes

- A handle isn't thread-safe. Use one per thread; separate handles in separate threads
  are fine.
- In-memory and stream output isn't padded except for uncompressed tar/cpio, which keep
  the traditional 10240-byte blocking. libarchive would otherwise append zeros after the
  compressed stream, and its own zstd reader rejects those zeros.
- `archive-directory` stores hard links as separate copies.
- The first call into libarchive sets `LC_CTYPE` to a UTF-8 locale if it isn't one:
  SBCL never calls `setlocale`, and in the "C" locale libarchive mangles or refuses
  non-ASCII names (the pax writer crashes on them). Set `*ensure-utf-8-locale*` to NIL
  first to opt out.
- On macOS libarchive decomposes names it reads (NFD); the entry accessors recompose
  them to NFC, so a name reads back as written.
- Entry points newer than the library you load can be probed with
  `(foreign-function-available-p "archive_...")`.

## la: the command-line tool

`libarchive/cli` builds **`la`**, one archive tool for every format libarchive
handles (`make la` → `bin/la`):

```sh
la a site.tar.zst site/ README.md     # create: format and compression from the name
la a -x '*.o' -l 9 src.zip src/        # exclude, compression level
la a -p secret private.zip notes/      # AES-256 encrypted zip
la a notes.txt.xz notes.txt            # a bare compressed file
la x download.tar.gz                   # one top-level entry: extracted here as is
la x photos.zip -C ~/Pictures          # several: into ~/Pictures/photos/ (photos-1/, ...)
la x notes.txt.xz                      # decompresses to notes.txt
la x --strip-components 1 pkg.tar.gz   # drop the leading pkg-1.0/
la l -l release.7z                     # list; t tests, i describes
curl -sL https://.../x.tgz | la x -    # - is standard input (or output, with -F)
```

**Behaviour:**
- `la x` never overwrites existing files without `--overwrite`. It reports each
  one it skips and exits 1.
- It refuses entries that would escape the target directory.
- It names the entry that failed. A file it created and then failed to fill is removed.
- **Passphrases:** without `-p` or `LA_PASSPHRASE`, an encrypted archive is asked for
  on the terminal, once per command.
- **Symlinks:** a symlink named on `la a`'s command line is stored as a symlink, as tar
  does; name `link/` to store what it points to.

Prebuilt binaries for macOS arm64 and Linux x86_64/aarch64 are on the
[releases page](https://github.com/lispnik/libarchive/releases).

Exit codes: 0 for success, 1 when something failed, 2 for a usage error. The binary opens
libarchive when it runs, so it uses whichever libarchive the machine has.
`la --help` and `la <command> --help` describe every option.

## Develop

```sh
make test       # FiveAM suite (hermetic source registry: this tree + ocicl/)
make check      # test + load report
make examples   # run examples/*.lisp, each checking its own output
make la         # build bin/la
make cli-test   # la's suite, plus ci/cli-smoke.sh against bin/la
make generate   # regenerate src/ffi-*.lisp, constants.lisp from the installed headers
```

MIT licensed; see [LICENSE](LICENSE).
