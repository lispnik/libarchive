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

(defun strip-components (name count)
  "NAME without its first COUNT directories, like tar --strip-components; NIL if
nothing is left. A trailing / stays."
  (if (zerop count)
      name
      (let* ((name (strip-dot-slash name))
             (parts (remove "" (uiop:split-string name :separator "/") :test #'string=)))
        (and (> (length parts) count)
             (format nil "~{~A~^/~}~:[~;/~]" (nthcdr count parts)
                     (char= #\/ (char name (1- (length name)))))))))

(defun clean-name (name)
  (string-right-trim "/" (strip-dot-slash name)))

(defun selects-p (pattern name)
  "True if PATTERN, a glob, names NAME or a directory NAME is under:
\"src\" and \"s*c\" select src/main.c, as do \"src/*.c\" and \"*.c\"."
  (let ((pattern (clean-name pattern))
        (name (clean-name name)))
    (or (glob-match-p pattern name)
        (loop for i = (position #\/ name) then (position #\/ name :start (1+ i))
              while i
              thereis (glob-match-p pattern (subseq name 0 i))))))

(defun make-selector (patterns)
  "A function of an entry name: true if PATTERNS is empty or one of them
selects it. Each use is noted, so UNUSED-PATTERNS can say which never matched."
  (let ((used '()))
    (values (lambda (name)
              (or (null patterns)
                  (let ((hit (find-if (lambda (p) (selects-p p name)) patterns)))
                    (when hit (pushnew hit used :test #'string=))
                    hit)))
            (lambda () (remove-if (lambda (p) (member p used :test #'string=)) patterns)))))

(defun match-options ()
  "-x, --newer and --older, for the commands that read archives: see
CALL-WITH-ENTRY-MATCH."
  (list (clingon:make-option :list :short-name #\x :long-name "exclude" :key :exclude
                                   :parameter "GLOB"
                                   :description "leave out matching entries (repeatable)")
        (newer-option) (older-option)))

(defun newer-option ()
  (clingon:make-option :string :long-name "newer" :key :newer :parameter "WHEN"
                               :description "only what was modified after WHEN, a date or a file"))

(defun older-option ()
  (clingon:make-option :string :long-name "older" :key :older :parameter "WHEN"
                               :description "only what was modified before WHEN, a date or a file"))

(defun time-limit (cmd key)
  "The --newer or --older value as MAKE-ARCHIVE-MATCH takes it: a file's own
time if it names one, else a date for libarchive to read (\"2024-06-01\",
\"2024-06-01 14:00\", \"3 days ago\")."
  (let ((value (clingon:getopt cmd key)))
    (when value
      (let ((limit (if (lexists-p (user-file value)) (user-file value) value)))
        ;; Tried alone, so that the error names the option.
        (handler-case (close-archive (make-archive-match key limit))
          (archive-error ()
            (usage-error "--~(~A~): ~S is neither a date nor a file" key value)))
        limit))))

(defun call-with-entry-match (cmd function &key (exclude (clingon:getopt cmd :exclude)))
  "Call FUNCTION with an ARCHIVE-MATCH made from -x, --newer and --older, or
with NIL when none of them was given."
  (let ((newer (time-limit cmd :newer))
        (older (time-limit cmd :older)))
    (if (or exclude newer older)
        (with-archive-match (m :exclude exclude :newer newer :older older)
          (funcall function m))
        (funcall function nil))))

(defun entry-chooser (selected match)
  "A function of an entry: true if SELECTED (from MAKE-SELECTOR) is true of its
name and MATCH, if any, chooses it."
  (lambda (e)
    (and (funcall selected (entry-pathname e))
         (or (null match) (entry-matches-p match e)))))

(defun survey (archive passphrase strip &optional (chosen (constantly t)))
  "The archive's top-level names, and whether it is a bare compressed file."
  (with-archive-reader (r archive :formats '(:all :raw) :passphrase (reader-passphrase passphrase))
    (let ((roots '())
          ;; A hash table, not PUSHNEW: an archive of a million top-level
          ;; files is a few megabytes, and a list makes that quadratic.
          (seen (make-hash-table :test #'equal)))
      (do-archive-entries (e r)
        (let* ((name (and (funcall chosen e)
                          (strip-components (entry-pathname e) strip)))
               (root (and name (entry-root name))))
          (when (and root (not (gethash root seen)))
            (setf (gethash root seen) t)
            (push root roots))))
      (values (nreverse roots)
              (equal (archive-format-name r) "raw")
              (archive-filter-names r)))))

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

(defvar *max-size* nil
  "--max-size in bytes: the most la x may write, or NIL for no limit.")

(defun over-the-limit (what)
  (fail "~A: stopped, as it would write more than --max-size ~A ~
         (it may be a decompression bomb)" what (human-size *max-size*)))

(defun extract-raw (archive name destination passphrase overwrite)
  "Decompress a bare compressed file to DESTINATION/<name without the suffix>."
  (let ((out (merge-pathnames (uiop:parse-native-namestring
                               (if (stdio-p name) "data" (archive-stem name)))
                              destination)))
    (when (and (lexists-p out) (not overwrite))
      (fail "~A already exists, not overwritten (use --overwrite)" (relative-display out)))
    (ensure-directories-exist out)
    (with-archive-reader (r archive :formats '(:raw) :passphrase (reader-passphrase passphrase))
      (next-entry r)
      (handler-case
          (with-open-file (s out :direction :output :element-type '(unsigned-byte 8)
                                 :if-exists :supersede)
            (let ((buffer (make-array 65536 :element-type '(unsigned-byte 8)))
                  (total 0))
              (loop for n = (read-entry-data-into r buffer)
                    until (zerop n)
                    do (incf total n)
                       (when (and *max-size* (> total *max-size*))
                         (close s :abort t)
                         (ignore-errors (delete-file out))
                         (over-the-limit (display-name name)))
                       (write-sequence buffer s :end n))))
        ((or stream-error file-error) (c)
          (ignore-errors (delete-file out))
          (fail "~A: cannot write: ~A" (relative-display out) (os-reason c)))))
    (note "~A: decompressed to ~A" (display-name name) (relative-display out))
    0))

(defun extract/handler (cmd)
  (let ((args (clingon:command-arguments cmd))
        (*quiet* (clingon:getopt cmd :quiet))
        (verbose (clingon:getopt cmd :verbose))
        (overwrite (clingon:getopt cmd :overwrite))
        (strip (or (clingon:getopt cmd :strip-components) 0))
        (destination (user-directory (or (clingon:getopt cmd :directory) "."))))
    (when (null args)
      (usage-error "x takes an archive, and optionally the entries to extract (see la x --help)"))
    (when (minusp strip) (usage-error "--strip-components takes a count of 0 or more"))
    (setf *max-size* (let ((size (clingon:getopt cmd :max-size)))
                       (and size (parse-size size "--max-size"))))
    (destructuring-bind (name &rest patterns) args
      (let ((passphrase (passphrase-source cmd (display-name name))))
        (flet ((raw (archive)
                 (when patterns
                   (usage-error "~A is a compressed file, not an archive: there are no entries to choose"
                                (display-name name)))
                 (extract-raw archive name destination passphrase overwrite)))
          (call-with-input-archive
           name
           (lambda (archive)
             (if (eq :raw (archive-kind name))
                 ;; x.txt.gz is a compressed file, by its name. Do not let
                 ;; libarchive guess: a one-line text file looks enough like an
                 ;; mtree manifest that format detection takes it for one.
                 (raw archive)
                 (multiple-value-bind (selected unused) (make-selector patterns)
                   (call-with-entry-match
                    cmd
                    (lambda (match)
                      (let ((chosen (entry-chooser selected match)))
                        (multiple-value-bind (roots raw filters) (survey archive passphrase strip chosen)
                          (cond ((and raw filters) (raw archive))
                                (raw (fail "~A is not an archive" (display-name name)))
                                (t
                                 (let ((missing (funcall unused)))
                                   (when missing
                                     (fail "~{~A~^, ~}: not in ~A" missing (display-name name))))
                                 (extract-into archive name destination roots passphrase overwrite
                                               verbose strip chosen
                                               (clingon:getopt cmd :same-permissions)))))))))))))))))

(defun real-directory-p (path)
  "True if PATH is a directory, and not a symlink to one."
  (handler-case (sb-posix:s-isdir (sb-posix:stat-mode
                                   (sb-posix:lstat (lstat-name path))))
    (sb-posix:syscall-error () nil)))

(defun extract-flags (overwrite same-permissions)
  "libarchive's flags for la x. As tar does, modes are restored in full only for
root or with --same-permissions; otherwise the umask applies, so that an
archive cannot leave world-writable files behind. Owners are never restored,
so neither are setuid and setgid bits (libarchive keeps them only with the
owner)."
  (append (if overwrite '(:unlink) '())
          (if (or same-permissions (zerop (sb-posix:geteuid)))
              '(:perm)
              '())
          *default-extract-flags*))

(defun extract-into (archive name destination roots passphrase overwrite verbose strip
                     &optional (chosen (constantly t)) same-permissions)
  (let* ((target (if (> (length roots) 1)
                     (fresh-directory destination (if (stdio-p name) "archive" (archive-stem name)))
                     destination))
         (skipped 0)
         (failed 0)
         (current nil)                  ; the entry being extracted, for messages
         (current-file nil)             ; ...and the file it creates, if it is new
         (partial '())                  ; files to remove: failed, and new
         (extracted
          (handler-case
          (unwind-protect
           (handler-bind ((extraction-limit-exceeded
                            (lambda (c)
                              (declare (ignore c))
                              (when current-file (push current-file partial))))
                          (archive-error
                            (lambda (c)
                              (let ((restart (find-restart 'skip-entry c))
                                    (message (archive-message c)))
                                (when restart
                                  (warn-user "~@[~A: ~]~A~:[~; (give it with -p or LA_PASSPHRASE)~]"
                                             ;; Refusals already name the entry.
                                             (and current (not (search current message)) current)
                                             message
                                             (and (search "assphrase" message)
                                                  (null (passphrase-source-given passphrase))))
                                  (incf failed)
                                  ;; Do not leave behind an empty or partial file
                                  ;; that was not there before. Removed once
                                  ;; extraction is over: until libarchive is
                                  ;; closed, it may still set the file's times.
                                  (when current-file
                                    (push current-file partial)
                                    (setf current-file nil))
                                  (invoke-restart restart))))))
             (extract-archive
              archive target
              :passphrase (reader-passphrase passphrase)
              :flags (extract-flags overwrite same-permissions)
              :max-size *max-size*
              :filter (lambda (e)
                        (setf current nil current-file nil)
                        (let* ((original (entry-pathname e))
                               (stored (and (funcall chosen e)
                                            (strip-components original strip)))
                               (link (and stored (entry-hardlink e)
                                          (strip-components (entry-hardlink e) strip)))
                               (path (and stored
                                          (merge-pathnames
                                           (uiop:parse-native-namestring (strip-dot-slash stored))
                                           target))))
                          (when (and stored (plusp strip))
                            (setf (entry-pathname e) stored)
                            (when (entry-hardlink e)
                              (setf (entry-hardlink e) (or link ""))))
                          (cond ((null stored) nil)  ; not chosen, or stripped away entirely
                                ((and (not overwrite)
                                      (lexists-p path)
                                      ;; A directory merges with one already
                                      ;; there, but replaces nothing else (a
                                      ;; symlink, say) unless asked to.
                                      (not (and (eq (entry-type e) :directory)
                                                (real-directory-p path))))
                                 (warn-user "~A: already exists, not overwritten (use --overwrite)"
                                            (entry-pathname e))
                                 (incf skipped)
                                 nil)
                                (t
                                 (setf current (entry-pathname e))
                                 (when (and (eq (entry-type e) :regular) (not (lexists-p path)))
                                   (setf current-file path))
                                 (when verbose (say "~A" current))
                                 t))))))
            (dolist (file partial)
              (ignore-errors (delete-file file))))
            (extraction-limit-exceeded (c)
              (over-the-limit (extraction-limit-entry c))))))
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
    :usage "[options] ARCHIVE [ENTRY...]"
    :description "extract an archive"
    :long-description "An archive with several top-level entries is extracted into a new directory named after it. With ENTRYs, only those: each is a name or a glob (* and ?), and a directory brings everything under it. -x leaves out what matches, at any depth (-x '*.o', -x build); --newer and --older choose by modification time."
    :options (list* (clingon:make-option :string :short-name #\C :long-name "directory"
                                                :key :directory :parameter "DIR"
                                                :description "extract under DIR instead of here")
                   (clingon:make-option :string :short-name #\p :long-name "passphrase"
                                                :key :passphrase :parameter "PASS"
                                                :description "passphrase for encrypted entries")
                   (clingon:make-option :integer :long-name "strip-components" :key :strip-components
                                                 :parameter "N"
                                                 :description "drop the first N directories of every name")
                   (clingon:make-option :flag :long-name "overwrite" :key :overwrite
                                              :description "replace files that already exist")
                   (clingon:make-option :string :long-name "max-size" :key :max-size :parameter "SIZE"
                                                :description "write no more than SIZE in all (500M, 10G): stops a bomb")
                   (clingon:make-option :flag :long-name "same-permissions" :key :same-permissions
                                              :description "modes exactly as archived, not less the umask (root: always)")
                   (clingon:make-option :flag :short-name #\v :long-name "verbose" :key :verbose
                                              :description "print each name as it is extracted")
                   (clingon:make-option :flag :short-name #\q :long-name "quiet" :key :quiet
                                              :description "no summary line")
                   (match-options))
    :handler #'extract/handler)))
