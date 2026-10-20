;;; la a: create an archive.
;;;
;;; Names are stored the way tar stores them: a relative argument as given
;;; ("src" stores src/...), anything else -- absolute, or climbing out with ..
;;; -- under its last component, so that the archive extracts safely anywhere.

(in-package #:libarchive/cli)

(defun stored-name (argument)
  "What to call ARGUMENT inside the archive; NIL for \".\" (its contents go in
at the top level)."
  (let ((name (string-right-trim "/" (strip-dot-slash argument))))
    (cond ((or (string= name "") (string= name ".")) nil)
          ((or (char= #\/ (char argument 0))
               (member ".." (uiop:split-string name :separator "/") :test #'string=))
           (let ((last (car (last (remove "" (uiop:split-string name :separator "/")
                                          :test #'string=)))))
             (if (or (null last) (string= last "..") (string= last ".")) nil last)))
          (t name))))

(defun writer-settings (cmd archive-name)
  "FORMAT, FILTERS and libarchive OPTIONS for the archive, from the options and
ARCHIVE-NAME's extension."
  (let ((format-option (clingon:getopt cmd :format))
        (filter-options (clingon:getopt cmd :compression))
        (level (clingon:getopt cmd :level))
        (passphrase (passphrase-from cmd)))
    (multiple-value-bind (format filters)
        (cond (format-option
               (values (parse-format format-option)
                       (remove :none (mapcar #'parse-filter
                                             (remove "none" filter-options :test #'string-equal)))))
              ((stdio-p archive-name)
               (usage-error "writing to standard output needs -F FORMAT"))
              (t
               (multiple-value-bind (format filters) (archive-kind archive-name)
                 (unless format
                   (usage-error "can't tell the format from ~S; name it .tar.gz, .zip, ... ~
                                 or give -F FORMAT" archive-name))
                 (values format
                         (if filter-options
                             (mapcar #'parse-filter
                                     (remove "none" filter-options :test #'string-equal))
                             filters)))))
      (let ((options '()))
        (when level
          (let ((modules (or (loop for f in filters
                                   for module = (cdr (assoc f *level-modules*))
                                   when module collect module)
                             (case format (:zip '("zip")) (:7zip '("7zip"))))))
            (unless modules
              (usage-error "-l has nothing to set: ~(~A~)~@[ with ~{~(~A~)~^+~}~] has no compression level"
                           format filters))
            (dolist (m modules)
              (push (cons (format nil "~A:compression-level" m) level) options))))
        (when passphrase
          (unless (eq format :zip)
            (usage-error "only zip archives can be encrypted when writing (-p)"))
          (push '("zip:encryption" . "aes256") options))
        (values format filters (nreverse options) passphrase)))))

(defun add/handler (cmd)
  (let* ((args (clingon:command-arguments cmd))
         (*quiet* (clingon:getopt cmd :quiet))
         (verbose (clingon:getopt cmd :verbose))
         (excludes (clingon:getopt cmd :exclude))
         (read-disk-flags (if (clingon:getopt cmd :no-xattrs) '(:no-xattr) '()))
         (base (user-directory (or (clingon:getopt cmd :directory) "."))))
    (when (< (length args) 2)
      (usage-error "a takes an archive and at least one file (see la a --help)"))
    (destructuring-bind (archive-name &rest inputs) args
      (multiple-value-bind (format filters options passphrase) (writer-settings cmd archive-name)
        (let ((disk-paths (loop for input in inputs
                                for path = (merge-pathnames (uiop:parse-native-namestring input) base)
                                do (unless (lexists-p path) (fail "~A: no such file or directory" input))
                                collect path))
              (target (unless (stdio-p archive-name) (user-file archive-name))))
          (when (eq format :raw)
            (unless (and (= 1 (length inputs)) (not (uiop:directory-exists-p (first disk-paths))))
              (usage-error "~A is a compressed file, not an archive: give exactly one file, ~
                            or name it .tar~A" archive-name
                            (nth-value 2 (archive-kind archive-name)))))
          (when (and target (lexists-p target) (not (clingon:getopt cmd :force)))
            (fail "~A already exists (use -f to replace it)" archive-name))
          (let ((count 0) (ok nil))
            (unwind-protect
                 (progn
                   (with-archive-writer (w (or target (stdout-octets))
                                           :format format :filters filters
                                           :options options :passphrase passphrase)
                     (let ((self (and target (uiop:native-namestring (truename target)))))
                       (loop for input in inputs
                             for disk in disk-paths
                             for name = (stored-name input)
                             do (cond
                                  ((eq format :raw)
                                   (add-entry w (or name (file-namestring disk)) :data disk)
                                   (incf count))
                                  ;; A symlink named on the command line is stored as
                                  ;; a symlink, as tar does, not as what it points to.
                                  ((symlink-p disk)
                                   (let ((stat (sb-posix:lstat (uiop:native-namestring disk))))
                                     (add-entry w (or name (file-namestring disk))
                                                :symlink (sb-posix:readlink (uiop:native-namestring disk))
                                                :mtime (+ (sb-posix:stat-mtime stat)
                                                          (encode-universal-time 0 0 0 1 1 1970 0))))
                                   (when verbose (format t "~A~%" (or name (file-namestring disk))))
                                   (incf count))
                                  (t
                                    (incf count
                                          (archive-directory
                                           disk w :name name :read-disk-flags read-disk-flags
                                           :directories (not (member format *formats-without-directories*))
                                           :filter (entry-filter disk name self excludes verbose))))))))
                   (setf ok t))
              ;; A failed archive is removed rather than left half-written.
              (when (and target (not ok))
                (ignore-errors (delete-file target))))
            (when target
              (note "~A: ~D entr~:@P, ~A" archive-name count
                    (human-size (with-open-file (in target :element-type '(unsigned-byte 8))
                                  (file-length in)))))
            0))))))

(defun entry-filter (disk name self excludes verbose)
  "ARCHIVE-DIRECTORY's filter for the input DISK stored as NAME: leaves out the
archive being written, and anything --exclude matches; prints names if VERBOSE."
  (let ((root (string-right-trim "/" (uiop:native-namestring (truename disk)))))
    (lambda (e)
      (let* ((path (entry-pathname e))
             (stored (cond ((string= path root) name)
                           ((> (length path) (length root))
                            (let ((rest (subseq path (1+ (length root)))))
                              (if name (format nil "~A/~A" name rest) rest))))))
        (cond ((and self (string= path self)) nil)
              ((and stored (some (lambda (p) (path-matches-p p stored)) excludes)) nil)
              (t (when (and verbose stored) (format t "~A~%" stored))
                 t))))))

(register-command
 "add"
 (lambda ()
   (clingon:make-command
    :name "add"
    :aliases '("a" "c" "create")
    :usage "[options] ARCHIVE FILE..."
    :description "create ARCHIVE from files and directories; its name picks the format"
    :options (list (clingon:make-option :string :short-name #\F :long-name "format" :key :format
                                                :parameter "FORMAT"
                                                :description "tar, pax, ustar, gnutar, zip, 7z, cpio, iso, xar, ar, shar, mtree, warc, raw")
                   (clingon:make-option :list :short-name #\z :long-name "compression"
                                              :key :compression :parameter "FILTER"
                                              :description "gzip, bzip2, xz, zstd, lz4, lzip, lzma, compress, none (repeatable)")
                   (clingon:make-option :integer :short-name #\l :long-name "level" :key :level
                                                 :parameter "N" :description "compression level")
                   (clingon:make-option :string :short-name #\p :long-name "passphrase"
                                                :key :passphrase :parameter "PASS"
                                                :description "encrypt (zip, AES-256)")
                   (clingon:make-option :string :short-name #\C :long-name "directory"
                                                :key :directory :parameter "DIR"
                                                :description "FILEs are relative to DIR")
                   (clingon:make-option :list :short-name #\x :long-name "exclude" :key :exclude
                                              :parameter "GLOB"
                                              :description "leave out matching paths (repeatable)")
                   (clingon:make-option :flag :long-name "no-xattrs" :key :no-xattrs
                                              :description "do not store extended attributes")
                   (clingon:make-option :flag :short-name #\f :long-name "force" :key :force
                                              :description "replace ARCHIVE if it exists")
                   (clingon:make-option :flag :short-name #\v :long-name "verbose" :key :verbose
                                              :description "print each name as it is added")
                   (clingon:make-option :flag :short-name #\q :long-name "quiet" :key :quiet
                                              :description "no summary line"))
    :handler #'add/handler)))
