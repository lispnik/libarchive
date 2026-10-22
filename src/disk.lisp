;;; Extracting to disk and archiving from disk.

(in-package #:libarchive)

(defparameter *default-extract-flags*
  '(:time :secure-symlinks :secure-nodotdot)
  "EXTRACT-ARCHIVE's default flags: restore times, and refuse to write through
symlinks or above the target directory. Modes are restored less the umask, as
tar does for anyone but root, so that an archive cannot leave world-writable
files behind; add :perm to restore them exactly (and :owner for owners, and
with them setuid and setgid bits).")

(defun attach-native-entry (reader)
  (let ((e (%archive-entry-new2 (live-pointer reader))))
    (setf (reader-native-entry reader) e)
    (add-cleanup reader (lambda () (%archive-entry-free e)))))

(defun make-disk-writer (flags)
  (load-libraries)
  (let ((h (make-handle 'disk-writer (%archive-write-disk-new))))
    (call-with-cleanup-on-error
     h
     (lambda ()
       (checked h (%archive-write-disk-set-options (flags-value flags *extract-flags* "extract")))
       (checked h (%archive-write-disk-set-standard-lookup))
       h))))

(defun check-extract-name (name)
  "Refuse names that would land outside the target directory.

EXTRACT-ARCHIVE roots every entry by prefixing the target directory, so the
paths libarchive sees are absolute and its own SECURE_NOABSOLUTEPATHS check
cannot be used; this check is done on the names as they are in the archive."
  (flet ((refuse (why)
           (error 'archive-error :operation "extract" :code +archive-failed+
                                 :message (format nil "refusing to extract ~S: ~A" name why))))
    (cond ((zerop (length name)) (refuse "empty name"))
          ((char= #\/ (char name 0)) (refuse "absolute path"))
          ((member ".." (uiop:split-string name :separator "/") :test #'string=)
           (refuse "contains a .. component")))))

(defun names-target-itself-p (name)
  "True for \".\", \"./\", \"././\" and the like: the directory being extracted into."
  (every (lambda (part) (member part '("" ".") :test #'string=))
         (uiop:split-string name :separator "/")))

(define-condition extraction-limit-exceeded (error)
  ((limit :initarg :limit :reader extraction-limit)
   (entry :initarg :entry :reader extraction-limit-entry))
  (:report (lambda (c s)
             (format s "Extracting ~A would write more than the limit of ~:D bytes."
                     (extraction-limit-entry c) (extraction-limit c))))
  (:documentation "Signalled by EXTRACT-ARCHIVE when its :MAX-SIZE would be passed.
Not an ARCHIVE-ERROR, so that a handler skipping failed entries does not carry
on past it: extraction stops."))

(defun spend (budget bytes entry)
  "Take BYTES from BUDGET, (bytes still allowed . the limit), or NIL for no
limit; signal EXTRACTION-LIMIT-EXCEEDED if there are not that many."
  (when budget
    (when (> bytes (car budget))
      (error 'extraction-limit-exceeded :limit (cdr budget) :entry entry))
    (decf (car budget) bytes)))

(defun extract-entry (reader disk entry progress &optional budget (name (entry-pathname entry)))
  "Write ENTRY, READER's current one, to the disk writer DISK, data and all.

This is archive_read_extract2, but with libarchive's own result codes: that
function reports every entry it could not create (one refused by the symlink
checks, say) as a mere ARCHIVE_WARN, after which the entry is easily taken for
extracted. Here a header that fails is an ARCHIVE-ERROR, and so is a data write
that fails, which libarchive also calls a warning."
  (let ((d (live-pointer disk)))
    ;; A declared size over the limit stops before anything is written. The
    ;; data is still counted as it comes: sizes can be missing, or lie.
    (when (and budget (entry-size-set-p entry) (> (entry-size entry) (car budget)))
      (error 'extraction-limit-exceeded :limit (cdr budget) :entry name))
    (handler-case
        (progn
          (check-result disk (%archive-write-header d (entry-pointer entry)) "archive_write_header")
          (when (or (not (entry-size-set-p entry)) (plusp (entry-size entry)))
            (cffi:with-foreign-objects ((buffer :pointer) (size :size) (offset :int64))
              (loop for code = (checked reader (%archive-read-data-block buffer size offset))
                    until (= code +archive-eof+)
                    do (spend budget (cffi:mem-ref size :size) name)
                       (let ((written (%archive-write-data-block
                                       d (cffi:mem-ref buffer :pointer)
                                       (cffi:mem-ref size :size) (cffi:mem-ref offset :int64))))
                         ;; A failed write (a full disk) is only ARCHIVE_WARN
                         ;; to libarchive, but the file is not what the
                         ;; archive holds: it is an error.
                         (when (minusp written)
                           (check-result disk (min written +archive-failed+)
                                         "archive_write_data_block")))
                       (when progress
                         (funcall progress (%archive-filter-bytes (live-pointer reader) -1)))))))
      (error (c)
        ;; Finish the entry before anyone hears of the failure, so that the
        ;; disk writer is ready for the next one and does not later try to
        ;; set the times of a file the handler may have removed.
        (%archive-write-finish-entry d)
        (error c)))
    (check-result disk (%archive-write-finish-entry d) "archive_write_finish_entry")))

(defun extract-archive (source directory &key (flags *default-extract-flags*)
                                             (formats :all) (filters :all)
                                             passphrase options filter match progress
                                             max-size)
  "Extract the archive SOURCE (anything OPEN-ARCHIVE-READER accepts, or an open
ARCHIVE-READER) into DIRECTORY, creating it if need be. Returns the list of
entry names extracted.

FLAGS is a list of keywords from *EXTRACT-FLAGS* (:owner :perm :time :acl
:xattr :fflags :no-overwrite :unlink :secure-symlinks :secure-nodotdot ...).
Entries with absolute names or .. components are always refused. An entry for
the target directory itself (\"./\", as `tar cf x.tar .' makes) is skipped,
so that an archive cannot change DIRECTORY's permissions, owner or times.

MATCH, an ARCHIVE-MATCH, chooses entries by their names (as stored), times and
owners. FILTER, if given, is then called with each entry and extracts it only
if it returns true. It may also change the entry's pathname (and hardlink) to extract it
under another name; the safety checks apply to the new names. PROGRESS, if
given, is called as data is written with the number of (compressed) bytes
consumed so far.

MAX-SIZE, if given, limits the data written in all, in bytes: a defence against
decompression bombs. An entry that would pass it signals
EXTRACTION-LIMIT-EXCEEDED, before anything is written if its size says so, and
extraction stops; what was written of it is left for the caller to remove.

Each refused or failed entry signals an ARCHIVE-ERROR with a SKIP-ENTRY restart:
those that would escape DIRECTORY, those libarchive refuses (a path through a
symlink, with :secure-symlinks), and those that cannot be written."
  (let ((root (uiop:native-namestring
               (truename (ensure-directories-exist (uiop:ensure-directory-pathname directory)))))
        (extracted '())
        ;; (bytes still allowed . the limit)
        (budget (and max-size (cons max-size max-size))))
    (flet ((run (reader)
             (let ((disk (make-disk-writer flags)))
               (unwind-protect
                    (progn
                      (loop for e = (next-entry reader)
                            while e
                            do (restart-case
                                   ;; The filter may rename the entry (strip a leading
                                   ;; directory, say), so its names are read after it.
                                   (when (and (or (null match) (entry-matches-p match e))
                                              (or (null filter) (funcall filter e)))
                                     (let ((name (entry-pathname e))
                                           (link (entry-hardlink e)))
                                       (check-extract-name name)
                                       (when link (check-extract-name link))
                                       (unless (names-target-itself-p name)
                                         (setf (entry-pathname e) (concatenate 'string root name))
                                         (when link
                                           (setf (entry-hardlink e) (concatenate 'string root link)))
                                         (extract-entry reader disk e progress budget name)
                                         (push name extracted))))
                                 (skip-entry ()
                                   :report "Skip this entry and go on to the next."
                                   nil)))
                      ;; Closing the disk writer is what applies deferred
                      ;; directory permissions and times, so its errors count.
                      (close-archive disk))
                 (close-archive disk :abort t)))))
      (if (typep source 'archive-reader)
          (run source)
          (let ((reader (open-archive-reader source :formats formats :filters filters
                                                    :passphrase passphrase :options options)))
            (unwind-protect (run reader)
              (close-archive reader)))))
    (nreverse extracted)))

(defun archive-directory (directory target &rest writer-keys
                          &key filter match report (read-disk-flags '()) name (directories t)
                          &allow-other-keys)
  "Archive the contents of DIRECTORY into TARGET, with entry names relative to
DIRECTORY. TARGET is an open ARCHIVE-WRITER (left open), or anything
OPEN-ARCHIVE-WRITER accepts, in which case WRITER-KEYS (:FORMAT, :FILTERS,
:OPTIONS, :PASSPHRASE) are passed to it and the writer is closed. Returns the
number of entries written.

NAME, if given, roots the entries there instead: the directory itself is
stored as NAME and its contents as NAME/..., the way tar stores a directory
named on its command line. DIRECTORY may also be a plain file, which is stored
as NAME (by default its file name).

FILTER, if given, is called with each entry found on disk (its pathname is
absolute here) and the entry -- and, for a directory, everything below it -- is
skipped unless it returns true. READ-DISK-FLAGS are keywords from
*READ-DISK-FLAGS*, e.g. :no-xattr. MATCH, an ARCHIVE-MATCH, sees the paths as they
are on disk (absolute). A directory it leaves out by name is not descended
into; one left out by its time or owner is, and its contents are matched in
turn. REPORT, if given, is called with the name of each entry as it is stored,
after it is written. Hard links are archived as separate copies.
DIRECTORIES NIL leaves directory entries out (their contents still go in), for
formats such as warc and ar that cannot store a directory."
  (let* ((directory-p (uiop:directory-exists-p directory))
         (root (if directory-p
                   (string-right-trim "/" (uiop:native-namestring
                                           (truename (uiop:ensure-directory-pathname directory))))
                   (uiop:native-namestring
                    (or (probe-file directory)
                        (error 'archive-error :operation "archive-directory"
                                              :code +archive-failed+
                                              :message (format nil "~A does not exist" directory))))))
         (name (or name (unless directory-p (file-namestring root))))
         ;; Names read back are NFC on macOS (see NATIVE-STRING), so compare in NFC.
         (prefix (concatenate 'string (native-string root) "/"))
         (count 0))
    (flet ((archive-name (disk-name)
             ;; The name to store for what read_disk calls DISK-NAME, or NIL to
             ;; leave it out (the root itself, when it has no name of its own).
             (cond ((string= disk-name (native-string root)) name)
                   ((and (> (length disk-name) (length prefix))
                         (string= prefix disk-name :end2 (length prefix)))
                    (let ((relative (subseq disk-name (length prefix))))
                      (if name (concatenate 'string name "/" relative) relative))))))
    (labels ((walk (writer)
               (load-libraries)
               (let ((disk (make-handle 'disk-reader (%archive-read-disk-new)))
                     (buffer (make-array +default-block-size+ :element-type '(unsigned-byte 8))))
                 (unwind-protect
                      (progn
                        (attach-native-entry disk)
                        (checked disk (%archive-read-disk-set-standard-lookup))
                        (checked disk (%archive-read-disk-set-behavior
                                       (flags-value read-disk-flags *read-disk-flags* "read-disk")))
                        (when filter
                          (setf (handle-filter-function disk) filter)
                          (checked disk (%archive-read-disk-set-metadata-filter-callback
                                         (cffi:callback metadata-filter-callback) (handle-key disk))))
                        (checked disk (%archive-read-disk-open root))
                        (loop for e = (next-entry disk)
                              while e
                              do (let ((pruned (and match (path-excluded-p match e))))
                                   ;; A directory left out by name takes its
                                   ;; contents with it; one left out by time
                                   ;; or owner does not.
                                   (unless (or pruned
                                               (zerop (%archive-read-disk-can-descend
                                                       (live-pointer disk))))
                                     (checked disk (%archive-read-disk-descend)))
                                 (let ((stored (and (not pruned)
                                                    (or (null match) (entry-matches-p match e))
                                                    (archive-name (entry-pathname e)))))
                                   (when (and stored
                                              (or directories (not (eq (entry-type e) :directory))))
                                     (setf (entry-pathname e) stored)
                                     (checked writer (%archive-write-header (entry-pointer e)))
                                     (when (eq (entry-type e) :regular)
                                       (loop for n = (read-entry-data-into disk buffer)
                                             until (zerop n)
                                             do (write-data writer buffer :end n)))
                                     (checked writer (%archive-write-finish-entry))
                                     (when report (funcall report stored))
                                     (incf count))))))
                   (close-archive disk)))))
      (if (typep target 'archive-writer)
          (walk target)
          (let ((writer (apply #'open-archive-writer target
                               (loop for (k v) on writer-keys by #'cddr
                                     unless (member k '(:filter :match :report :read-disk-flags :name
                                                         :directories))
                                       append (list k v))))
                (ok nil))
            (unwind-protect (progn (walk writer) (setf ok t))
              (close-archive writer :abort (not ok)))))))
    count))
