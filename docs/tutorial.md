# libarchive for Common Lisp: a tutorial

This walks through the ergonomic API one task at a time, from listing a tarball to
extracting untrusted archives safely. Every section has a runnable program in
[`examples/`](../examples/) that does what the section describes and checks the
result. Run them all with `make examples`, or one with `make example NAME=disk`.

Everything here is in the `libarchive` package:

```lisp
(asdf:load-system :libarchive)
(use-package :libarchive)
```

There's also a raw layer: every C function as `%archive-…`, and every constant as
`+archive-…+`. This tutorial doesn't use it.

## 1. Reading an archive

Name a file, and libarchive detects the format and any compression itself:

```lisp
(archive-entry-names #p"release.tar.gz")
;; => ("release/" "release/README" "release/bin/tool")
```

To get at contents, open a reader and step through its entries:

```lisp
(with-archive-reader (r #p"release.tar.gz")
  (do-archive-entries (e r)
    (format t "~A ~8D ~A~%" (entry-strmode e) (entry-size e) (entry-pathname e))
    (when (string= (entry-pathname e) "release/README")
      (write-string (read-entry-string r)))))
```

An entry's data is read while the reader is on that entry. Any data you don't read
is skipped when you move on. The data comes in several forms:

| call | gives |
|------|-------|
| `(read-entry-data r)` | all of it, as an octet vector |
| `(read-entry-string r :encoding :latin-1)` | decoded text (UTF-8 by default) |
| `(copy-entry-data r stream)` | copied to a binary output stream; returns the byte count |
| `(read-entry-data-into r buffer)` | the next piece into your buffer, like `read-sequence` |
| `(skip-entry-data r)` | nothing; skips it explicitly |

Once the reader is open, `archive-format-name`, `archive-filter-names` and
`archive-file-count` describe what it found.

→ [`examples/quickstart.lisp`](../examples/quickstart.lisp)

## 2. Writing an archive

```lisp
(with-archive-writer (w #p"site.tar.gz" :format :pax-restricted :filters :gzip)
  (add-entry w "site/")                                  ; trailing / makes a directory
  (add-entry w "site/index.html" :data "<h1>Hi</h1>")    ; a string is written as UTF-8
  (add-entry w "site/logo.png" :data #p"logo.png")       ; a file's contents
  (add-entry w "site/run.sh" :data script :perm #o755)
  (add-entry w "site/current" :symlink "index.html"))
```

`:data` can be an octet vector, a string, a pathname, or a binary input stream.
Leaving a writer normally writes the archive's trailer. Leaving it through an error
*aborts* it instead, so a half-written archive never looks finished.

→ [`examples/quickstart.lisp`](../examples/quickstart.lisp)

## 3. Entries

`add-entry` is a shortcut. For full control, build an entry, set its fields, and
write it:

```lisp
(with-entry (e :pathname "data/report.csv" :uname "alice" :uid 501 :perm #o640)
  (setf (entry-mtime e) (encode-universal-time 0 0 12 1 6 2024 0))
  (entry-add-xattr e "user.origin" "nightly job")
  (write-entry w e csv-octets))     ; the size is filled in from the data
```

Every accessor is `setf`-able:
- `entry-pathname`, `entry-type`, `entry-perm` and `entry-mode`
- `entry-size`
- `entry-uid`, `entry-gid`, `entry-uname` and `entry-gname`
- `entry-symlink` and `entry-hardlink`
- `entry-mtime`, `entry-atime`, `entry-ctime` and `entry-birthtime`

Times are universal times, and NIL means unset. Names are Lisp strings: UTF-8 in the
archive, whatever the process locale.

**Lifetimes.** An entry from `next-entry` or `do-archive-entries` is *borrowed*.
libarchive reuses it, so it stops being valid at the next entry or when the reader
closes. After that, using it signals an error rather than quietly returning some
other entry's fields. `copy-entry` gives you one you own. `make-entry` and
`with-entry` create owned entries, and `free-entry` releases them. `entry-valid-p`
tells you which you have.

**Things formats do to entries:**
- A hard link read from a tar has `entry-type` NIL. libarchive records it as a link
  with no file type, so check `entry-hardlink` before `entry-type`.
- A tar header has no way to say "no mtime". An unset mtime is written as 0 and
  reads back as the Unix epoch.
- zip often records sizes only after the data, so `entry-size` can be NIL when
  reading a zip from a stream that can't seek. File types are recorded only in
  the zip's central directory at the end, so read that way a symlink comes back as
  a regular file whose data is its target.

→ [`examples/entries.lisp`](../examples/entries.lisp)

## 4. Memory and streams

Readers and writers don't need named files:

```lisp
;; Build an archive in memory, then read it back from the vector.
(let ((zip (with-archive-to-octets (w :format :zip)
             (add-entry w "hello.txt" :data "hello"))))
  (archive-entry-names zip))                    ; => ("hello.txt")

;; Any binary stream works: a socket, a pipe, or your own Gray stream.
(with-archive-writer (w socket-stream :format :ustar :filters :zstd) ...)
(with-archive-reader (r socket-stream) ...)
```

A stream is *seekable* if `file-position` and `file-length` work on it. With a
seekable stream libarchive can skip data without reading it, and it can read zip and
7z archives that need their central directory. A stream that can't seek is read
straight through, which suits tar and most other formats.

A tar header has to give the entry size before the data. So when `:data` is a
stream and you pass no `:size`, `add-entry` reads the whole stream into memory
first. Pass `:size` when you know it.

To copy entries from one archive into another, `transfer-entry` writes the reader's
current entry to a writer and streams its data across, so nothing is held in
memory. Change the entry first (rename it, say) and the change is what gets written:

```lisp
(with-archive-writer (w #p"site.tar.zst" :format :pax-restricted :filters :zstd)
  (with-archive-reader (r #p"site.zip")
    (do-archive-entries (e r)
      (setf (entry-pathname e) (concatenate 'string "www/" (entry-pathname e)))
      (transfer-entry r w))))
```

→ [`examples/streams.lisp`](../examples/streams.lisp), and
[`examples/repack.lisp`](../examples/repack.lisp) for zip → tar.zst conversion in one
pass with no temporary files

## 5. Formats, filters and options

**Formats.**
- `:format` values:
  - tar family: `:pax-restricted` (the default, like bsdtar), `:pax`, `:ustar`,
    `:gnutar`, `:v7tar`
  - others: `:zip`, `:7zip`, `:cpio`, `:cpio-newc`, `:iso9660`, `:xar`, `:ar-bsd`,
    `:mtree`, `:shar`, `:warc`, `:raw`
- `:by-extension` picks the format and filters from the target's file name.

**Filters.** `:filters` takes one keyword or a list, applied in order, so the first
in the list ends up innermost: `:gzip`, `:bzip2`, `:xz`, `:lzma`, `:zstd`, `:lz4`,
`:lzip`, `:compress`, `:uuencode`, `:base64`.

**Options.** These are libarchive's own options, as an alist or as its
`"module:option=value"` text. T sets a bare option and NIL negates it:

```lisp
(open-archive-writer path :format :ustar :filters :gzip
                          :options '(("gzip:compression-level" . 9)
                                     ("gzip:timestamp" . nil)))
```

**Reading.** A reader accepts everything by default. `:formats` and `:filters`
restrict it, for example `:formats '(:zip)` refuses anything that isn't a zip.
The `:raw` format reads a bare compressed file (`x.gz`) as a single entry, but only
when you ask for it by name.

**Blocking.** Uncompressed tar and cpio are padded to 10240-byte blocks, as tape-era
readers expect. Everything else is unpadded. `:bytes-per-block` and
`:bytes-in-last-block` override this.

What's available depends on how libarchive was built. For example, xar needs
libxml2, and Homebrew's libarchive is built without it. `version-details` lists the
compression and crypto libraries in this build.

→ [`examples/formats.lisp`](../examples/formats.lisp)

## 6. Encryption

zip archives can be encrypted with ZipCrypto or AES. Reading them works the same
way for 7z and RAR:

```lisp
(with-archive-writer (w #p"secret.zip" :format :zip :passphrase "hunter2"
                                       :options '(("zip:encryption" . "aes256")))
  (add-entry w "plans.txt" :data "..."))

(with-archive-reader (r #p"secret.zip" :passphrase "hunter2") ...)
(with-archive-reader (r #p"secret.zip" :passphrase '("old" "hunter2")) ...)  ; tried in turn
(with-archive-reader (r #p"secret.zip" :passphrase #'ask-the-user) ...)       ; NIL = give up
```

Zip encrypts data but not names, so you can list an encrypted zip without the
passphrase. `entry-data-encrypted-p` and `archive-has-encrypted-entries` say what
needs one. A wrong or missing passphrase signals an `archive-error` when the data
is read.

→ [`examples/encryption.lisp`](../examples/encryption.lisp)

## 7. Disk: archiving and extracting trees

```lisp
(archive-directory #p"project/" #p"project.tar.zst" :format :pax-restricted :filters :zstd
                   :read-disk-flags '(:no-xattr)
                   :filter (lambda (e) (not (search "/.git" (entry-pathname e)))))

(extract-archive #p"project.tar.zst" #p"restored/")   ; => names extracted
```

**`archive-directory`** stores names relative to the directory, and keeps modes,
times, owners, symlinks and extended attributes. Its filter sees absolute names, and
rejecting a directory prunes everything under it. You can also hand it an open writer,
to combine several trees or add entries of your own alongside.

- **`:name`** stores the tree under a name of its own, as tar stores a directory
  named on its command line: `(archive-directory #p"~/src/app/" w :name "app")`
  gives `app/`, `app/main.lisp` and so on. The path can also be a single file.
- **`:directories nil`** leaves directory entries out but keeps their contents. Use
  it for warc and ar, which can't store directories.

**`extract-archive`** by default restores permissions and times
(`*default-extract-flags*`) and refuses to write through symlinks. `:flags` takes
any of the keywords in `*extract-flags*`, `:filter` chooses entries, and `:progress`
reports bytes consumed.

**Untrusted archives.** Entries with absolute names or `..` components are always
refused, whatever the flags. Each refusal signals an `archive-error` with a
`skip-entry` restart, so you decide whether to carry on:

```lisp
(handler-bind ((archive-error (lambda (c) (warn "~A" c) (invoke-restart 'skip-entry))))
  (extract-archive download #p"unpacked/"))
```

`:no-overwrite` skips existing files *silently*. libarchive reports success for the
entry it didn't write.

→ [`examples/disk.lisp`](../examples/disk.lisp)

## 8. Errors

| libarchive | condition | meaning |
|---|---|---|
| `ARCHIVE_WARN` | `archive-warning` (a `warning`) | it worked, with a diagnostic |
| `ARCHIVE_FAILED` | `archive-error` | this call failed; the archive is still usable |
| `ARCHIVE_RETRY` | `archive-retry` | try again |
| `ARCHIVE_FATAL` | `archive-fatal-error` | only `close-archive` is left |

Each condition carries `archive-condition-message`, `-errno`, `-code` and
`-operation`. When *your* code fails inside a callback, the original condition is
re-signalled after libarchive returns, never "read callback failed". That covers a
stream's `read-sequence`, a passphrase function and a filter. Misspelt keywords are
caught before libarchive is called. `close-archive` can be called twice. Using a
closed handle signals an error.

→ [`examples/errors.lisp`](../examples/errors.lisp)

## 9. Threads

A handle belongs to one thread at a time. Separate handles in separate threads are
independent, and the first call is safe from any number of threads at once.

→ [`examples/threads.lisp`](../examples/threads.lisp)

## 10. What the binding does to the process

- **Locale.** libarchive converts names through the C locale, which a Lisp process
  generally never sets. In the default "C" locale, non-ASCII names are corrupted, refused, or
  crash the pax writer. So the first call into libarchive switches `LC_CTYPE`, and
  only `LC_CTYPE`, to a UTF-8 locale if it isn't one already. Set
  `*ensure-utf-8-locale*` to NIL beforehand to leave the locale alone.
- **Unicode normalization (macOS).** libarchive on Apple platforms decomposes every
  name it reads (NFD). The binding recomposes names to NFC, so the name you read
  back is the name you wrote, on every platform.
- **Library search.** Homebrew's libarchive is keg-only, so its directories are
  searched before the system's old copy. `*library-directories*` holds the list, and
  `*library-pathname*`, if set before the first call, names the file to open instead.

## 11. Further: the `la` tool

[`cli/`](../cli/) is a complete program built only on what this tutorial covers: a
general-purpose archiver, `la` (`make la`; see the README). It's a worked example of
putting the pieces together:
- `archive-directory :name` stores each command-line argument the way tar does.
- `extract-archive` with a filter and the `skip-entry` restart produces per-entry
  reports.
- `:formats '(:raw)` handles bare compressed files.
- Spooling standard input lets an archive be read twice.
- `la a -r` rewrites an archive with `transfer-entry`, and `la diff` compares entries
  with the disk as they are read.
