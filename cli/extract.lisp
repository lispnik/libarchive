;;; la x: extract.
;;;
;;; An archive with one top-level entry ("project/...", or a single file) is
;;; extracted where it is asked to be. One with several -- a tarball made with
;;; `tar cf x.tar *' -- would scatter them, so it gets a directory of its own
;;; named after the archive. That takes two passes: one to read the names, one
;;; to extract.

(in-package #:libarchive/cli)

(defun strip-dot-slash (name)
  (loop while (and (>= (length name) 2) (string= "./" name :end2 2))
        do (setf name (subseq name 2)))
  name)

(defun entry-root (name)
  "The first path component of NAME, or NIL for \".\" and the like."
  (let* ((name (string-left-trim "/" (strip-dot-slash name)))
         (root (subseq name 0 (position #\/ name))))
    (and (plusp (length root)) (string/= root ".") root)))

(defun survey (archive passphrase)
  "The archive's top-level names, and whether it is a bare compressed file."
  (with-archive-reader (r archive :formats '(:all :raw) :passphrase passphrase)
    (let ((roots '()))
      (do-archive-entries (e r)
        (let ((root (entry-root (entry-pathname e))))
          (when root (pushnew root roots :test #'string=))))
      (values (nreverse roots)
              (equal (archive-format-name r) "raw")
              (archive-filter-names r)))))

(defun lexists-p (path)
  "True if PATH exists, as a dangling symlink too."
  (handler-case (progn (sb-posix:lstat (uiop:native-namestring path)) t)
    (sb-posix:syscall-error () nil)))

(defun fresh-directory (parent stem)
  "PARENT/STEM/, or PARENT/STEM-1/, -2, ... whichever does not exist yet."
  (loop for i from 0
        for name = (if (zerop i) stem (format nil "~A-~D" stem i))
        for dir = (merge-pathnames (uiop:ensure-directory-pathname (uiop:parse-native-namestring name))
                                   parent)
        unless (lexists-p dir) return dir))

(defun relative-display (path)
  (let ((here (uiop:native-namestring (truename *default-pathname-defaults*)))
        (there (uiop:native-namestring path)))
    (if (and (> (length there) (length here)) (string= here there :end2 (length here)))
        (subseq there (length here))
        there)))

(defun extract-raw (archive name destination passphrase overwrite)
  "Decompress a bare compressed file to DESTINATION/<name without the suffix>."
  (let ((out (merge-pathnames (uiop:parse-native-namestring
                               (if (stdio-p name) "data" (archive-stem name)))
                              destination)))
    (when (and (lexists-p out) (not overwrite))
      (fail "~A already exists, not overwritten (use --overwrite)" (relative-display out)))
    (ensure-directories-exist out)
    (with-archive-reader (r archive :formats '(:raw) :passphrase passphrase)
      (next-entry r)
      (with-open-file (s out :direction :output :element-type '(unsigned-byte 8)
                             :if-exists :supersede)
        (copy-entry-data r s)))
    (note "~A: decompressed to ~A" (display-name name) (relative-display out))
    0))

(defun extract/handler (cmd)
  (let ((args (clingon:command-arguments cmd))
        (*quiet* (clingon:getopt cmd :quiet))
        (verbose (clingon:getopt cmd :verbose))
        (overwrite (clingon:getopt cmd :overwrite))
        (passphrase (passphrase-from cmd))
        (destination (user-directory (or (clingon:getopt cmd :directory) "."))))
    (unless (= 1 (length args))
      (usage-error "x takes one archive (see la x --help)"))
    (let ((name (first args)))
      (call-with-input-archive
       name
       (lambda (archive)
         (if (eq :raw (archive-kind name))
             ;; x.txt.gz is a compressed file, by its name. Do not let
             ;; libarchive guess: a one-line text file looks enough like an
             ;; mtree manifest that format detection takes it for one.
             (extract-raw archive name destination passphrase overwrite)
             (multiple-value-bind (roots raw filters) (survey archive passphrase)
               (cond ((and raw filters)
                      (extract-raw archive name destination passphrase overwrite))
                     (raw (fail "~A is not an archive" (display-name name)))
                     (t (extract-into archive name destination roots passphrase overwrite
                                      verbose))))))))))

(defun extract-into (archive name destination roots passphrase overwrite verbose)
  (let* ((target (if (> (length roots) 1)
                     (fresh-directory destination (if (stdio-p name) "archive" (archive-stem name)))
                     destination))
         (skipped 0)
         (failed 0)
         (current nil)                  ; the entry being extracted, for messages
         (extracted
           (handler-bind ((archive-error
                            (lambda (c)
                              (let ((restart (find-restart 'skip-entry c))
                                    (message (or (archive-condition-message c) (princ-to-string c))))
                                (when restart
                                  (warn-user "~@[~A: ~]~A~:[~; (give it with -p or LA_PASSPHRASE)~]"
                                             ;; Refusals already name the entry.
                                             (and current (not (search current message)) current)
                                             message
                                             (and (search "assphrase" message) (null passphrase)))
                                  (incf failed)
                                  (invoke-restart restart))))))
             (extract-archive
              archive target
              :passphrase passphrase
              :flags (append (if overwrite '(:unlink) '()) *default-extract-flags*)
              :filter (lambda (e)
                        (let ((path (merge-pathnames
                                     (uiop:parse-native-namestring (strip-dot-slash (entry-pathname e)))
                                     target)))
                          (cond ((and (not overwrite)
                                      (not (eq (entry-type e) :directory))
                                      (lexists-p path))
                                 (warn-user "~A: already exists, not overwritten (use --overwrite)"
                                            (entry-pathname e))
                                 (incf skipped)
                                 nil)
                                (t
                                 (setf current (entry-pathname e))
                                 (when verbose (format t "~A~%" current))
                                 t))))))))
    (note "~A: ~D entr~:@P extracted~@[ into ~A~]~@[, ~D skipped~]~@[, ~D failed~]"
          (display-name name) (length extracted)
          (and (> (length roots) 1) (relative-display target))
          (and (plusp skipped) skipped) (and (plusp failed) failed))
    (if (plusp (+ skipped failed)) 1 0)))

(register-command
 "extract"
 (lambda ()
   (clingon:make-command
    :name "extract"
    :aliases '("x")
    :usage "[options] ARCHIVE"
    :description "extract an archive (several top-level entries: into a new directory)"
    :options (list (clingon:make-option :string :short-name #\C :long-name "directory"
                                                :key :directory :parameter "DIR"
                                                :description "extract under DIR instead of here")
                   (clingon:make-option :string :short-name #\p :long-name "passphrase"
                                                :key :passphrase :parameter "PASS"
                                                :description "passphrase for encrypted entries")
                   (clingon:make-option :flag :long-name "overwrite" :key :overwrite
                                              :description "replace files that already exist")
                   (clingon:make-option :flag :short-name #\v :long-name "verbose" :key :verbose
                                              :description "print each name as it is extracted")
                   (clingon:make-option :flag :short-name #\q :long-name "quiet" :key :quiet
                                              :description "no summary line"))
    :handler #'extract/handler)))
