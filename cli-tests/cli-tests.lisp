(in-package #:libarchive/cli/tests)

(in-suite la)

;;; Fixtures.

(defmacro in-scratch-directory (&body body)
  "Run BODY with *DEFAULT-PATHNAME-DEFAULTS* a fresh, empty directory."
  (let ((dir (gensym "DIR")))
    `(let ((,dir (uiop:ensure-directory-pathname
                  (format nil "~Ala-test-~36R/"
                          (uiop:native-namestring (uiop:temporary-directory))
                          (random (expt 36 8) (make-random-state t))))))
       (ensure-directories-exist ,dir)
       (let ((*default-pathname-defaults* (truename ,dir)))
         (unwind-protect (progn ,@body)
           ;; An extracted iso9660 can leave directories without write permission.
           (uiop:run-program (list "chmod" "-R" "u+w" (uiop:native-namestring ,dir))
                             :ignore-error-status t)
           (uiop:delete-directory-tree ,dir :validate t :if-does-not-exist :ignore))))))

(defun la (&rest args)
  "Run la with ARGS; return its exit code, standard output and standard error."
  (let ((out (make-string-output-stream))
        (err (make-string-output-stream)))
    (let ((code (let ((*standard-output* out) (*error-output* err)
                      ;; Never stop to ask at the terminal from a test.
                      (libarchive/cli::*prompt-for-passphrase* nil))
                  (libarchive/cli:run args))))
      (values code (get-output-stream-string out) (get-output-stream-string err)))))

(defmacro la-ok (&rest args)
  "Run la, asserting it succeeds; return its standard output."
  (let ((code (gensym)) (out (gensym)) (err (gensym)))
    `(multiple-value-bind (,code ,out ,err) (la ,@args)
       (is (eql 0 ,code) "la ~{~A~^ ~} exited ~A~%~A" (list ,@args) ,code ,err)
       ,out)))

(defun write-file (name contents)
  (let ((path (merge-pathnames name)))
    (ensure-directories-exist path)
    (with-open-file (s path :direction :output :if-exists :supersede)
      (write-string contents s))
    path))

(defun read-file (name)
  (uiop:read-file-string (merge-pathnames name)))

(defun exists (name) (probe-file (merge-pathnames name)))

(defun lines (string)
  (remove "" (uiop:split-string string :separator '(#\Newline)) :test #'string=))

(defun make-project ()
  (write-file "proj/README" "read me")
  (write-file "proj/src/main.c" "int main(void) { return 0; }")
  (write-file "proj/src/main.o" "object code")
  (write-file "loose.txt" "loose"))

(defun format-writable-p (format)
  (handler-case
      (progn (libarchive:close-archive (libarchive:open-archive-writer :octets :format format)) t)
    (libarchive:archive-error () nil)))

;;; The extension table.

(test extensions
  (is (equal '(:pax-restricted (:gzip) ".tar.gz") (multiple-value-list (archive-kind "x.tar.gz"))))
  (is (eq :pax-restricted (archive-kind "X.TGZ")))
  (is (equal '(:zstd) (nth-value 1 (archive-kind "a.b.tar.zst"))))
  (is (eq :zip (archive-kind "lib.jar")))
  (is (eq :raw (archive-kind "notes.txt.gz")))
  (is (eq :compress (first (nth-value 1 (archive-kind "old.tar.Z")))))
  (is (null (archive-kind "README")))
  (is (string= "src-1.2" (archive-stem "/tmp/src-1.2.tar.gz")))
  (is (string= "notes.txt" (archive-stem "notes.txt.gz")))
  (is (string= "data" (archive-stem "data.unknown")))
  (is (string= "archive" (archive-stem ".tar"))))

;;; a and x.

(test single-root-extracts-in-place
  (in-scratch-directory
    (make-project)
    (la-ok "a" "p.tar.gz" "proj")
    (uiop:delete-directory-tree (merge-pathnames "proj/") :validate t)
    (la-ok "x" "p.tar.gz")
    ;; One root, so no extra directory: proj/ lands here, as itself.
    (is (string= "read me" (read-file "proj/README")))
    (is (not (exists "p/")))))

(test several-roots-get-a-directory
  (in-scratch-directory
    (make-project)
    (la-ok "a" "both.zip" "proj" "loose.txt")
    (multiple-value-bind (code out err) (la "x" "both.zip" "-C" "out")
      (declare (ignore out))
      (is (eql 0 code))
      (is (search "into" err)))
    (is (string= "loose" (read-file "out/both/loose.txt")))
    (is (string= "read me" (read-file "out/both/proj/README")))
    ;; Again: the directory exists, so the next is both-1.
    (la-ok "x" "both.zip" "-C" "out")
    (is (exists "out/both-1/loose.txt"))))

(test a-single-file-archive-extracts-in-place
  (in-scratch-directory
    (write-file "only.txt" "just me")
    (la-ok "a" "one.7z" "only.txt")
    (delete-file (merge-pathnames "only.txt"))
    (la-ok "x" "one.7z")
    (is (string= "just me" (read-file "only.txt")))))

(test bare-compressed-files
  (in-scratch-directory
    (write-file "notes.txt" "compressed, not archived")
    (dolist (ext '("gz" "bz2" "xz" "zst" "lz4"))
      (let ((name (format nil "notes.txt.~A" ext)))
        (la-ok "a" name "notes.txt")
        (la-ok "x" name "-C" ext)
        (is (string= "compressed, not archived" (read-file (format nil "~A/notes.txt" ext)))
            "~A" ext)))
    ;; One short line of text is enough for libarchive's format detection
    ;; to call it an mtree manifest; the .gz name has to win.
    (write-file "line.txt" "loose
")
    (la-ok "a" "line.txt.gz" "line.txt")
    (la-ok "x" "line.txt.gz" "-C" "line")
    (is (string= "loose
" (read-file "line/line.txt")))
    ;; A compressed file holds one file, not a tree.
    (write-file "two.txt" "2")
    (is (eql 2 (la "a" "many.gz" "notes.txt" "two.txt")))))

(test round-trip-every-writable-format
  (in-scratch-directory
    (make-project)
    (dolist (name '("p.tar" "p.tar.gz" "p.tgz" "p.tar.bz2" "p.tar.xz" "p.tar.zst" "p.tar.lz4"
                    "p.tar.lz" "p.tar.lzma" "p.tar.Z" "p.zip" "p.7z" "p.cpio" "p.iso" "p.xar"
                    "p.warc"))
      (when (format-writable-p (archive-kind name))
        (la-ok "a" name "proj")
        (la-ok "x" name "-C" (format nil "out-~A" name))
        (is (string= "int main(void) { return 0; }"
                     (read-file (format nil "out-~A/proj/src/main.c" name)))
            "~A" name)))))

(test formats-without-directories
  (in-scratch-directory
    (make-project)
    ;; warc and ar store files only; the directories are left out, not refused.
    (la-ok "a" "p.warc" "proj")
    (is (equal '("proj/README" "proj/src/main.c" "proj/src/main.o")
               (sort (lines (la-ok "l" "p.warc")) #'string<)))
    (la-ok "a" "p.a" "proj/README" "loose.txt")
    (is (= 2 (length (lines (la-ok "l" "p.a")))))))

(test format-and-compression-options
  (in-scratch-directory
    (make-project)
    ;; No extension to go on: -F names the format, -z the compression.
    (la-ok "a" "-F" "zip" "bundle" "proj")
    (is (search "ZIP" (la-ok "i" "bundle")))
    (la-ok "a" "-F" "tar" "-z" "xz" "-l" "9" "bundle.dat" "proj")
    (is (search "xz" (la-ok "i" "bundle.dat")))
    ;; -z overrides the extension; "none" drops it.
    (la-ok "a" "-z" "none" "plain.tar.gz" "proj")
    (is (search "none" (la-ok "i" "plain.tar.gz")))
    (is (eql 2 (la "a" "unknown.ext" "proj")))
    (is (eql 2 (la "a" "-z" "nope" "x.tar" "proj")))
    (is (eql 2 (la "a" "-l" "5" "x.tar" "proj")))))

(test names-are-stored-like-tar
  (in-scratch-directory
    (make-project)
    (la-ok "a" "rel.tar" "proj/src")
    (is (equal '("proj/src/" "proj/src/main.c" "proj/src/main.o")
               (sort (lines (la-ok "l" "rel.tar")) #'string<)))
    ;; Absolute and .. paths are stored under their last component.
    (la-ok "a" "abs.tar" (uiop:native-namestring (merge-pathnames "proj/src/")))
    (is (member "src/main.c" (lines (la-ok "l" "abs.tar")) :test #'string=))
    (la-ok "a" "-C" "proj/src" "up.tar" "../README")
    (is (equal '("README") (lines (la-ok "l" "up.tar"))))
    ;; . is the directory's contents at the top level.
    (la-ok "a" "-C" "proj" "dot.tar" ".")
    (is (member "src/main.c" (lines (la-ok "l" "dot.tar")) :test #'string=))))

(test exclude
  (in-scratch-directory
    (make-project)
    (la-ok "a" "-x" "*.o" "--exclude" "README" "e.tar" "proj")
    (is (equal '("proj/" "proj/src/" "proj/src/main.c")
               (sort (lines (la-ok "l" "e.tar")) #'string<)))))

(test overwriting
  (in-scratch-directory
    (make-project)
    (la-ok "a" "p.tar" "proj")
    ;; The archive exists: refuse, unless -f.
    (is (eql 1 (la "a" "p.tar" "loose.txt")))
    (la-ok "a" "-f" "p.tar" "proj")
    ;; Extracting over existing files: refused and reported, unless --overwrite.
    (write-file "proj/README" "changed")
    (multiple-value-bind (code out err) (la "x" "p.tar")
      (declare (ignore out))
      (is (eql 1 code))
      (is (search "proj/README: already exists" err)))
    (is (string= "changed" (read-file "proj/README")))
    (la-ok "x" "--overwrite" "p.tar")
    (is (string= "read me" (read-file "proj/README")))))

(test hostile-archives
  (in-scratch-directory
    (let ((evil (libarchive:with-archive-to-octets (w :format :ustar)
                  (libarchive:add-entry w "fine.txt" :data "ok")
                  (libarchive:add-entry w "../escape.txt" :data "no"))))
      (with-open-file (s (merge-pathnames "evil.tar") :direction :output
                                                      :element-type '(unsigned-byte 8))
        (write-sequence evil s)))
    (multiple-value-bind (code out err) (la "x" "evil.tar" "-C" "in")
      (declare (ignore out))
      (is (eql 1 code))
      (is (search "refusing" err)))
    ;; Two roots ("fine.txt" and ".."), so it went in a directory of its own.
    (is (exists "in/evil/fine.txt"))
    (is (not (exists "in/escape.txt")))
    (is (not (exists "escape.txt")))))

(test encryption
  (in-scratch-directory
    (make-project)
    (la-ok "a" "-p" "s3cret" "secret.zip" "proj")
    (is (search "Encrypted:   yes" (la-ok "i" "secret.zip")))
    (is (eql 1 (la "t" "-q" "secret.zip")))
    (la-ok "t" "-p" "s3cret" "secret.zip")
    (la-ok "x" "-p" "s3cret" "secret.zip" "-C" "out")
    (is (string= "read me" (read-file "out/proj/README")))
    ;; Only zip can be encrypted when writing.
    (is (eql 2 (la "a" "-p" "x" "secret.tar" "proj")))))

(test list-test-info
  (in-scratch-directory
    (make-project)
    (la-ok "a" "p.tar.gz" "proj")
    (let ((long (la-ok "l" "-l" "p.tar.gz")))
      (is (search "-rw-r--r--" long))
      (is (search "proj/src/main.c" long)))
    (is (search "OK, 5 entries" (nth-value 2 (la "t" "p.tar.gz"))))
    (let ((info (la-ok "i" "p.tar.gz")))
      (is (search "gzip" info))
      (is (search "Top level:   1 (proj)" info)))))

(test damaged-and-missing
  (in-scratch-directory
    (make-project)
    (la-ok "a" "p.tar.gz" "proj")
    (let* ((path (merge-pathnames "p.tar.gz"))
           (octets (with-open-file (s path :element-type '(unsigned-byte 8))
                     (let ((v (make-array (file-length s) :element-type '(unsigned-byte 8))))
                       (read-sequence v s) v))))
      (with-open-file (s (merge-pathnames "cut.tar.gz") :direction :output
                                                        :element-type '(unsigned-byte 8))
        (write-sequence octets s :end (floor (length octets) 2))))
    (is (eql 1 (la "t" "cut.tar.gz")))
    (is (eql 1 (la "x" "missing.zip")))
    (is (eql 1 (la "x" "loose.txt")))         ; not an archive
    (is (eql 2 (la "x")))
    (is (eql 2 (la "x" "--bogus" "p.tar.gz")))
    (is (eql 0 (la "--help")))))

(test strip-components
  (in-scratch-directory
    (make-project)
    (la-ok "a" "p.tar" "proj")
    ;; proj/README and proj/src/ become README and src/: two roots now, so
    ;; they get a directory of their own.
    (la-ok "x" "--strip-components" "1" "p.tar" "-C" "s1")
    (is (string= "read me" (read-file "s1/p/README")))
    (is (exists "s1/p/src/main.c"))
    ;; Strip two: only src's files are left, one root each.
    (la-ok "x" "--strip-components" "2" "p.tar" "-C" "s2")
    (is (exists "s2/p/main.c"))
    (is (not (exists "s2/p/README")))
    (is (eql 2 (la "x" "--strip-components" "-1" "p.tar")))))

(test failed-entries-leave-no-files
  (in-scratch-directory
    (make-project)
    ;; Encrypted with no passphrase: each file is created, then fails.
    (la-ok "a" "-p" "pw" "s.zip" "proj")
    (is (eql 1 (la "x" "s.zip" "-C" "out")))
    (is (not (exists "out/proj/README")))
    (is (not (exists "out/proj/src/main.c")))))

(test symlink-arguments-are-stored-as-symlinks
  (in-scratch-directory
    (make-project)
    (uiop:run-program (list "ln" "-s" "proj/README"
                            (uiop:native-namestring (merge-pathnames "readme-link"))))
    (la-ok "a" "l.tar" "readme-link")
    (let ((long (la-ok "l" "-l" "l.tar")))
      (is (search "readme-link -> proj/README" long) "~A" long))))

(test passphrase-typed-once-is-remembered
  ;; la x reads the archive twice; a passphrase given at the prompt for the
  ;; first pass is tried first in the second, so it is asked for only once.
  (in-scratch-directory
    (make-project)
    (la-ok "a" "-p" "pw" "s.zip" "proj")
    (let ((asked 0))
      (flet ((answer (label) (declare (ignore label)) (incf asked) "pw"))
        (let ((libarchive/cli::*prompt-for-passphrase* t))
          (sb-int:encapsulate 'libarchive/cli::read-passphrase-from-terminal 'test
                              (lambda (f label) (declare (ignore f)) (answer label)))
          (sb-int:encapsulate 'libarchive/cli::terminal-available-p 'test
                              (lambda (f) (declare (ignore f)) t))
          (unwind-protect
               (let ((code (let ((*standard-output* (make-broadcast-stream))
                                 (*error-output* (make-broadcast-stream)))
                             (libarchive/cli:run (list "x" "s.zip" "-C" "out")))))
                 (is (eql 0 code)))
            (sb-int:unencapsulate 'libarchive/cli::read-passphrase-from-terminal 'test)
            (sb-int:unencapsulate 'libarchive/cli::terminal-available-p 'test)))
        (is (string= "read me" (read-file "out/proj/README")))
        (is (= 1 asked) "asked ~D times" asked)))))

;;; x with entries chosen.

(test extract-chosen-entries
  (in-scratch-directory
    (make-project)
    (la-ok "a" "-q" "p.tar" "proj" "loose.txt")
    ;; A glob; a directory brings what is under it; * crosses /.
    (la-ok "x" "-q" "p.tar" "-C" "o1" "proj/src/*.c")
    (is-true (exists "o1/proj/src/main.c"))
    (is-false (exists "o1/proj/src/main.o"))
    (is-false (exists "o1/proj/README"))
    (la-ok "x" "-q" "p.tar" "-C" "o2" "proj/src")
    (is-true (exists "o2/proj/src/main.o"))
    (is-false (exists "o2/proj/README"))
    (la-ok "x" "-q" "p.tar" "-C" "o3" "*.o")
    (is-true (exists "o3/proj/src/main.o"))
    (is-false (exists "o3/proj/src/main.c"))
    ;; The top level is what was chosen: one root extracts in place,
    ;; several get a directory.
    (la-ok "x" "-q" "p.tar" "-C" "o4" "loose.txt")
    (is-true (exists "o4/loose.txt"))
    (la-ok "x" "-q" "p.tar" "-C" "o5" "loose.txt" "proj/README")
    (is-true (exists "o5/p/loose.txt"))
    (is-true (exists "o5/p/proj/README"))
    ;; A name that matches nothing fails, before anything is written.
    (multiple-value-bind (code out err) (la "x" "p.tar" "-C" "o6" "proj/README" "nothere")
      (declare (ignore out))
      (is (= 1 code))
      (is-true (search "nothere" err))
      (is-false (exists "o6/")))
    (la-ok "a" "-q" "l.txt.gz" "loose.txt")
    (is (= 2 (la "x" "l.txt.gz" "loose.txt")))))

;;; a -r.

(defun dot-la-files ()
  (remove-if-not (lambda (p) (search ".la-" (file-namestring p)))
                 (uiop:directory-files *default-pathname-defaults*)))

(test append-replaces-and-keeps
  (in-scratch-directory
    (make-project)
    (la-ok "a" "-q" "p.tar.gz" "proj")
    (write-file "proj/README" "new readme")
    (write-file "extra.txt" "extra")
    (la-ok "a" "-r" "-q" "p.tar.gz" "proj/README" "extra.txt")
    (let ((names (lines (la-ok "l" "p.tar.gz"))))
      (is (equal '("extra.txt" "proj/" "proj/README" "proj/src/" "proj/src/main.c" "proj/src/main.o")
                 (sort (copy-list names) #'string<))))
    ;; Still a gzipped tar, and the new README replaced the old.
    (libarchive:with-archive-reader (r (merge-pathnames "p.tar.gz"))
      (libarchive:next-entry r)
      (is (equal '("gzip") (libarchive:archive-filter-names r))))
    (la-ok "x" "-q" "p.tar.gz" "-C" "o")
    (is (string= "new readme" (read-file "o/p/proj/README")))
    (is (string= "int main(void) { return 0; }" (read-file "o/p/proj/src/main.c")))
    (is (null (dot-la-files)))))

(test append-refusals
  (in-scratch-directory
    (make-project)
    ;; -r on a missing archive makes it.
    (la-ok "a" "-r" "-q" "new.zip" "loose.txt")
    (is (equal '("loose.txt") (lines (la-ok "l" "new.zip"))))
    ;; Without -r an existing archive is not touched.
    (is (= 1 (la "a" "new.zip" "proj")))
    (is (equal '("loose.txt") (lines (la-ok "l" "new.zip"))))
    (la-ok "a" "-q" "l.txt.gz" "loose.txt")
    (is (= 2 (la "a" "-r" "l.txt.gz" "loose.txt")))
    ;; Encrypted entries are not copied out in the clear.
    (la-ok "a" "-q" "-p" "pw" "s.zip" "proj")
    (let ((before (alexandria:read-file-into-byte-vector (merge-pathnames "s.zip"))))
      (multiple-value-bind (code out err) (la "a" "-r" "s.zip" "loose.txt")
        (declare (ignore out))
        (is (= 1 code))
        (is-true (search "-p" err)))
      (is (equalp before (alexandria:read-file-into-byte-vector (merge-pathnames "s.zip")))))
    (la-ok "a" "-r" "-q" "-p" "pw" "s.zip" "loose.txt")
    (la-ok "t" "-q" "-p" "pw" "s.zip")
    (is (= 6 (length (lines (la-ok "l" "s.zip")))))  ; proj/ and its 4, and loose.txt
    (is (null (dot-la-files)))))

;;; diff.

(test diff-against-disk
  (in-scratch-directory
    (make-project)
    (la-ok "a" "-q" "p.tar" "proj")
    (is (string= "" (la-ok "diff" "p.tar")))
    (la-ok "x" "-q" "p.tar" "-C" "copy")
    (is (string= "" (la-ok "diff" "p.tar" "-C" "copy")))
    (write-file "proj/README" "changed")
    (delete-file (merge-pathnames "proj/src/main.o"))
    (write-file "proj/src/new.c" "new")
    (delete-file (merge-pathnames "proj/src/main.c"))
    (ensure-directories-exist (merge-pathnames "proj/src/main.c/"))
    (multiple-value-bind (code out) (la "diff" "p.tar")
      (is (= 1 code))
      (is (equal '("only in archive: proj/src/main.o"
                   "only on disk: proj/src/new.c"
                   "proj/README: contents differ"
                   "proj/src/main.c: a directory on disk, a file in the archive")
                 (sort (lines out) #'string<))))
    (multiple-value-bind (code out) (la "diff" "-q" "p.tar")
      (is (= 1 code))
      (is (string= "" out)))))

;;; cat.

(defun la-cat (&rest args)
  "Run la cat with ARGS; return the exit code and what it wrote, as a string."
  (let ((path (merge-pathnames "cat.out")))
    (let ((code (with-open-file (out path :direction :output :element-type '(unsigned-byte 8)
                                          :if-exists :supersede)
                  (let ((libarchive/cli::*cat-output* out))
                    (apply #'la "cat" args)))))
      (values code (prog1 (read-file "cat.out") (delete-file path))))))

(test cat-writes-entries
  (in-scratch-directory
    (make-project)
    (la-ok "a" "-q" "p.tar" "proj" "loose.txt")
    (is (equal '(0 "read me") (multiple-value-list (la-cat "p.tar" "proj/README"))))
    ;; Archive order, not the order asked for.
    (is (equal '(0 "read meloose") (multiple-value-list (la-cat "p.tar" "loose.txt" "proj/README"))))
    ;; A directory brings its files; no ENTRY, every file, in archive order.
    (is (equal '(0 "int main(void) { return 0; }") (multiple-value-list (la-cat "p.tar" "*.c"))))
    (is (= (+ (length "int main(void) { return 0; }") (length "object code"))
           (length (nth-value 1 (la-cat "p.tar" "proj/src")))))
    (let ((all (nth-value 1 (la-cat "p.tar"))))
      (dolist (part '("read me" "object code" "int main" "loose"))
        (is-true (search part all))))
    (is (= 1 (la-cat "p.tar" "nothere")))
    ;; A compressed file comes out decompressed.
    (la-ok "a" "-q" "l.txt.xz" "loose.txt")
    (is (equal '(0 "loose") (multiple-value-list (la-cat "l.txt.xz"))))
    (is (= 2 (la-cat "l.txt.xz" "loose.txt")))))

;;; rm.

(test remove-entries
  (in-scratch-directory
    (make-project)
    (la-ok "a" "-q" "p.tar.bz2" "proj" "loose.txt")
    (la-ok "rm" "-q" "p.tar.bz2" "proj/src" "loose.txt")
    (is (equal '("proj/" "proj/README") (sort (lines (la-ok "l" "p.tar.bz2")) #'string<)))
    (libarchive:with-archive-reader (r (merge-pathnames "p.tar.bz2"))
      (libarchive:next-entry r)
      (is (equal '("bzip2") (libarchive:archive-filter-names r))))
    ;; A name that matches nothing changes nothing.
    (multiple-value-bind (code out err) (la "rm" "p.tar.bz2" "proj/README" "nothere")
      (declare (ignore out))
      (is (= 1 code))
      (is-true (search "nothere" err)))
    (is (= 2 (length (lines (la-ok "l" "p.tar.bz2")))))
    (is (= 2 (la "rm" "p.tar.bz2")))
    (is (null (dot-la-files)))))

;;; -T.

(test compression-threads
  (in-scratch-directory
    (make-project)
    (la-ok "a" "-q" "-T" "0" "p.tar.zst" "proj")
    (la-ok "a" "-q" "-T" "2" "p.tar.xz" "proj")
    (la-ok "t" "-q" "p.tar.zst")
    (la-ok "t" "-q" "p.tar.xz")
    (is (= 2 (la "a" "-T" "2" "p.tar.gz" "proj")))
    (is (= 2 (la "a" "-T" "-1" "q.tar.zst" "proj")))))

;;; The man page and completions.

(test generated-docs
  (in-scratch-directory
    (libarchive/cli::write-docs *default-pathname-defaults*)
    (let ((man (read-file "la.1"))
          (zsh (read-file "_la")))
      (is-true (search ".Sh COMMANDS" man))
      (dolist (command '("extract" "add" "remove" "convert" "list" "cat" "test" "info" "diff"))
        (is-true (search (format nil ".Ss ~A" command) man) "~A not in la.1" command)
        (is-true (search (format nil "'~A[" command) zsh) "~A not in _la" command))
      (is-true (search "#compdef la" zsh))
      (is-true (search "complete -o bashdefault" (read-file "la.bash"))))))

;;; convert.

(defun names-in (archive)
  (sort (mapcar (lambda (n) (string-right-trim "/" n)) (lines (la-ok "l" archive))) #'string<))

(test convert-between-formats
  (in-scratch-directory
    (make-project)
    (la-ok "a" "-q" "p.tar.gz" "proj" "loose.txt")
    (let ((names (names-in "p.tar.gz")))
      (dolist (out '("p.zip" "p.7z" "p.tar.xz" "p.cpio" "p.tar"))
        (la-ok "convert" "-q" "p.tar.gz" out)
        (is (equal names (names-in out)) "~A has other names" out)
        (is (equal '(0 "read me") (multiple-value-list (la-cat out "proj/README")))))
      ;; Compression and format come from the name, as for la a.
      (libarchive:with-archive-reader (r (merge-pathnames "p.tar.xz"))
        (libarchive:next-entry r)
        (is (equal '("xz") (libarchive:archive-filter-names r))))
      ;; -x leaves things out.
      (la-ok "convert" "-q" "-x" "*.o" "p.zip" "small.tar.zst")
      (is (equal (remove "proj/src/main.o" names :test #'string=) (names-in "small.tar.zst"))))
    ;; OUT exists: -f, which also recompresses in place.
    (is (= 1 (la "convert" "p.zip" "p.7z")))
    (la-ok "convert" "-q" "-f" "-l" "9" "p.tar.gz" "p.tar.gz")
    (la-ok "t" "-q" "p.tar.gz")
    (is (null (dot-la-files)))
    (is (= 2 (la "convert" "p.zip")))
    (is (= 2 (la "convert" "p.zip" "p.unknown")))))

(test convert-compressed-files
  (in-scratch-directory
    (write-file "notes.txt" "some notes")
    (la-ok "a" "-q" "notes.txt.gz" "notes.txt")
    ;; Another compression, then into an archive under its own name...
    (la-ok "convert" "-q" "notes.txt.gz" "notes.txt.xz")
    (is (equal '(0 "some notes") (multiple-value-list (la-cat "notes.txt.xz"))))
    (la-ok "convert" "-q" "notes.txt.xz" "n.tar.zst")
    (is (equal '("notes.txt") (names-in "n.tar.zst")))
    (is (equal '(0 "some notes") (multiple-value-list (la-cat "n.tar.zst" "notes.txt"))))
    ;; ...and an archive of one file back to a compressed file.
    (la-ok "convert" "-q" "n.tar.zst" "again.lz4")
    (is (equal '(0 "some notes") (multiple-value-list (la-cat "again.lz4"))))
    (make-project)
    (la-ok "a" "-q" "p.zip" "proj")
    (multiple-value-bind (code out err) (la "convert" "p.zip" "p.gz")
      (declare (ignore out))
      (is (= 1 code))
      (is-true (search "more than one file" err)))
    (is (not (exists "p.gz")))))

(test convert-encrypted
  (in-scratch-directory
    (make-project)
    (la-ok "a" "-q" "-p" "pw" "secret.zip" "proj")
    ;; Zip to zip stays encrypted, with the same passphrase.
    (la-ok "convert" "-q" "-p" "pw" "secret.zip" "again.zip")
    (is (= 1 (la "t" "-q" "again.zip")))
    (la-ok "t" "-q" "-p" "pw" "again.zip")
    ;; Anything else is written decrypted, and says so.
    (multiple-value-bind (code out err) (la "convert" "-p" "pw" "secret.zip" "open.tar")
      (declare (ignore out))
      (is (= 0 code))
      (is-true (search "not encrypted" err)))
    (is (equal '(0 "read me") (multiple-value-list (la-cat "open.tar" "proj/README"))))
    (is (= 1 (la "convert" "-q" "secret.zip" "nopass.tar")))
    (is (not (exists "nopass.tar")))
    (is (null (dot-la-files)))))

;;; l --json.

(test list-json
  (in-scratch-directory
    (write-file "d/say \"hi\".txt" "x")
    (write-file "d/plain" "yz")
    (sb-posix:symlink "plain" (uiop:native-namestring (merge-pathnames "d/link")))
    (la-ok "a" "-q" "d.tar" "d")
    (let* ((json (la-ok "l" "--json" "d.tar"))
           (rows (remove-if-not (lambda (l) (search "{" l)) (lines json))))
      (is (char= #\[ (char json 0)))
      (is (string= "]" (car (last (lines json)))))
      (is (= 4 (length rows)))
      ;; One object per line, commas between them but not after the last.
      (is (= 3 (count-if (lambda (r) (last-char-is r #\,)) rows)))
      (is-true (search "\"name\": \"d/say \\\"hi\\\".txt\"" json))
      (is-true (search "\"type\": \"symlink\"" json))
      (is-true (search "\"link\": \"plain\"" json))
      (is-true (search "\"type\": \"file\", \"size\": 2, \"mode\": \"0644\"" json))
      (is-true (search "\"type\": \"directory\"" json))
      (is-true (search "\"encrypted\": false" json)))
    (is (string= (format nil "[]~%") (la-ok "l" "--json" "-x" "d" "d.tar")))
    (is (= 2 (la "l" "--json" "-l" "d.tar")))))

(defun last-char-is (string char)
  (and (plusp (length string)) (char= char (char string (1- (length string))))))

;;; -x, --newer and --older.

(defun set-mtime (name universal-time)
  (let ((unix (- universal-time (encode-universal-time 0 0 0 1 1 1970 0))))
    (sb-posix:utimes (uiop:native-namestring (merge-pathnames name)) unix unix)))

(test choosing-by-name-and-time
  (in-scratch-directory
    (make-project)
    (let ((old (encode-universal-time 0 0 0 1 1 2020 0))
          (mid (encode-universal-time 0 0 0 1 1 2023 0)))
      (set-mtime "proj/src/main.o" old)
      (set-mtime "proj/README" old)
      (write-file "stamp" "")
      (set-mtime "stamp" mid)
      ;; la a: by time, through a directory left out for its own time.
      (set-mtime "proj/src" old)
      (la-ok "a" "-q" "--newer" "stamp" "new.tar" "proj")
      (is (equal '("proj" "proj/src/main.c") (names-in "new.tar")))
      (la-ok "a" "-q" "--older" "2023-01-01" "old.tar" "proj")
      (is (equal '("proj/README" "proj/src" "proj/src/main.o") (names-in "old.tar")))
      (la-ok "a" "-q" "all.tar" "proj")
      ;; la l, x and cat.
      (is (equal '("proj" "proj/README" "proj/src" "proj/src/main.c")
                 (sort (mapcar (lambda (n) (string-right-trim "/" n))
                               (lines (la-ok "l" "-x" "*.o" "all.tar")))
                       #'string<)))
      (is (equal '("proj/README" "proj/src/" "proj/src/main.o")
                 (sort (lines (la-ok "l" "--older" "stamp" "all.tar")) #'string<)))
      ;; Excluding a directory takes what is under it.
      (is (equal '("proj/README")
                 (lines (la-ok "l" "--older" "stamp" "-x" "proj/src" "all.tar"))))
      (la-ok "x" "-q" "-C" "out" "-x" "src" "all.tar")
      (is (exists "out/proj/README"))
      (is (not (exists "out/proj/src/")))
      (la-ok "x" "-q" "-C" "out2" "--newer" "stamp" "all.tar")
      (is (exists "out2/proj/src/main.c"))
      (is (not (exists "out2/proj/README")))
      (is (equal '(0 "read me") (multiple-value-list (la-cat "all.tar" "--older" "stamp" "-x" "*.o"))))
      ;; A date that is not one.
      (multiple-value-bind (code out err) (la "l" "--newer" "someday" "all.tar")
        (declare (ignore out))
        (is (= 2 code))
        (is-true (search "--newer" err))))))

;;; Attacks other extractors have fallen to (the library's own refusals are
;;; tested in its suite).

(defun write-archive (name octets)
  (with-open-file (s (merge-pathnames name) :direction :output :element-type '(unsigned-byte 8)
                                            :if-exists :supersede)
    (write-sequence octets s)))

(defun mode-of (name)
  (logand #o7777 (sb-posix:stat-mode (sb-posix:lstat (uiop:native-namestring (merge-pathnames name))))))

(test refused-entries-are-failures
  (in-scratch-directory
    (write-file "outside/victim" "original")
    (write-archive "evil.tar" (libarchive:with-archive-to-octets (w :format :pax)
                                (libarchive:add-entry w "a" :symlink "../outside")
                                (libarchive:add-entry w "a/pwned" :data "x")))
    (multiple-value-bind (code out err) (la "x" "evil.tar" "-C" "in")
      (declare (ignore out))
      (is (= 1 code))
      (is-true (search "symlink" err))
      (is-true (search "1 failed" err)))
    (is (not (exists "outside/pwned")))))

(test existing-symlinks-are-not-replaced
  (in-scratch-directory
    (ensure-directories-exist (merge-pathnames "in/"))
    (sb-posix:symlink "elsewhere" (uiop:native-namestring (merge-pathnames "in/x")))
    (write-archive "d.tar" (libarchive:with-archive-to-octets (w :format :pax)
                             (libarchive:add-entry w "x/")
                             (libarchive:add-entry w "x/f" :data "y")))
    (is (= 1 (la "x" "-q" "d.tar" "-C" "in")))
    (is (string= "elsewhere" (sb-posix:readlink (uiop:native-namestring (merge-pathnames "in/x")))))
    (la-ok "x" "-q" "--overwrite" "d.tar" "-C" "in")
    (is (string= "y" (read-file "in/x/f")))))

(test modes-are-masked-by-the-umask
  (in-scratch-directory
    (write-archive "m.tar" (libarchive:with-archive-to-octets (w :format :pax)
                             (libarchive:add-entry w "m/")
                             (libarchive:add-entry w "m/open" :data "x" :perm #o777)
                             (libarchive:add-entry w "m/suid" :data "x" :perm #o4755)
                             (libarchive:add-entry w "m/dir/" :perm #o777)))
    (let ((umask (let ((u (sb-posix:umask 0))) (sb-posix:umask u) u)))
      (la-ok "x" "-q" "m.tar" "-C" "a")
      (unless (zerop (sb-posix:geteuid))
        (is (= (logandc2 #o777 umask) (mode-of "a/m/open")))
        (is (= (logandc2 #o777 umask) (mode-of "a/m/dir"))))
      (la-ok "x" "-q" "--same-permissions" "m.tar" "-C" "b")
      (is (= #o777 (mode-of "b/m/open")))
      ;; Owners are not restored, and so neither is setuid.
      (is (= #o755 (mode-of "b/m/suid"))))))

(test names-cannot-reach-the-terminal
  (in-scratch-directory
    (let ((name (format nil "evil~C]0;owned~C~Cfake line\\x" (code-char 27) (code-char 7) #\Newline)))
      (write-archive "e.tar" (libarchive:with-archive-to-octets (w :format :pax)
                               (libarchive:add-entry w name :data "x")
                               (libarchive:add-entry w (concatenate 'string "../" name) :data "x")))
      (flet ((clean-p (s) (notany (lambda (c) (member (char-code c) '(7 27))) s)))
        (let ((listing (la-ok "l" "e.tar")))
          (is-true (clean-p listing))
          (is (= 2 (length (lines listing))))
          (is-true (search "evil\\033]0;owned\\007\\nfake line\\\\x" listing)))
        (multiple-value-bind (code out err) (la "x" "-v" "e.tar" "-C" "in")
          (is (= 1 code))
          (is-true (clean-p out))
          (is-true (clean-p err))
          ;; As tar's -v: each name as it is tried, the refused one too.
          (is (= 2 (length (lines out)))))
        ;; JSON has escapes of its own.
        (is-true (search "\\u001B]0;owned\\u0007\\nfake line\\\\x" (la-ok "l" "--json" "e.tar")))))))
