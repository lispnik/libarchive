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
    (let ((code (let ((*standard-output* out) (*error-output* err))
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
