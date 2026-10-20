;;; Extracting to disk and archiving from disk.

(in-package #:libarchive)

(defparameter *default-extract-flags*
  '(:time :perm :secure-symlinks :secure-nodotdot)
  "EXTRACT-ARCHIVE's default flags: restore modes and times, and refuse to
write through symlinks or above the target directory.")

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

(defun extract-archive (source directory &key (flags *default-extract-flags*)
                                             (formats :all) (filters :all)
                                             passphrase options filter progress)
  "Extract the archive SOURCE (anything OPEN-ARCHIVE-READER accepts, or an open
ARCHIVE-READER) into DIRECTORY, creating it if need be. Returns the list of
entry names extracted.

FLAGS is a list of keywords from *EXTRACT-FLAGS* (:owner :perm :time :acl
:xattr :fflags :no-overwrite :unlink :secure-symlinks :secure-nodotdot ...).
Entries with absolute names or .. components are always refused.

FILTER, if given, is called with each entry and extracts it only if it returns
true. PROGRESS, if given, is called periodically during extraction with the
number of (compressed) bytes consumed so far.

Each refused or failed entry signals an ARCHIVE-ERROR with a SKIP-ENTRY restart."
  (let ((root (uiop:native-namestring
               (truename (ensure-directories-exist (uiop:ensure-directory-pathname directory)))))
        (extracted '()))
    (flet ((run (reader)
             (let ((disk (make-disk-writer flags)))
               (unwind-protect
                    (progn
                      (when progress
                        (setf (handle-progress-function reader)
                              (lambda ()
                                (funcall progress (%archive-filter-bytes (live-pointer reader) -1))))
                        (%archive-read-extract-set-progress-callback
                         (live-pointer reader) (cffi:callback progress-callback) (handle-key reader)))
                      (loop for e = (next-entry reader)
                            while e
                            do (restart-case
                                   (let ((name (entry-pathname e))
                                         (link (entry-hardlink e)))
                                     (when (or (null filter) (funcall filter e))
                                       (check-extract-name name)
                                       (when link (check-extract-name link))
                                       (setf (entry-pathname e) (concatenate 'string root name))
                                       (when link
                                         (setf (entry-hardlink e) (concatenate 'string root link)))
                                       (check-result reader
                                                     (%archive-read-extract2 (live-pointer reader)
                                                                             (entry-pointer e)
                                                                             (live-pointer disk))
                                                     "archive_read_extract2")
                                       (push name extracted)))
                                 (skip-entry ()
                                   :report "Skip this entry and go on to the next."
                                   nil)))
                      ;; Closing the disk writer is what applies deferred
                      ;; directory permissions and times, so its errors count.
                      (close-archive disk))
                 (close-archive disk :abort t)
                 (when progress
                   (%archive-read-extract-set-progress-callback
                    (live-pointer reader) (cffi:null-pointer) (cffi:null-pointer)))))))
      (if (typep source 'archive-reader)
          (run source)
          (let ((reader (open-archive-reader source :formats formats :filters filters
                                                    :passphrase passphrase :options options)))
            (unwind-protect (run reader)
              (close-archive reader)))))
    (nreverse extracted)))

(defun archive-directory (directory target &rest writer-keys
                          &key filter (read-disk-flags '()) &allow-other-keys)
  "Archive the contents of DIRECTORY into TARGET, with entry names relative to
DIRECTORY. TARGET is an open ARCHIVE-WRITER (left open), or anything
OPEN-ARCHIVE-WRITER accepts, in which case WRITER-KEYS (:FORMAT, :FILTERS,
:OPTIONS, :PASSPHRASE) are passed to it and the writer is closed. Returns the
number of entries written.

FILTER, if given, is called with each entry found on disk (its pathname is
absolute here) and the entry -- and, for a directory, everything below it -- is
skipped unless it returns true. READ-DISK-FLAGS are keywords from
*READ-DISK-FLAGS*, e.g. :no-xattr. Hard links are archived as separate copies."
  (let* ((root (string-right-trim "/" (uiop:native-namestring
                                       (truename (uiop:ensure-directory-pathname directory)))))
         (prefix (concatenate 'string root "/"))
         (count 0))
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
                              do (unless (zerop (%archive-read-disk-can-descend (live-pointer disk)))
                                   (checked disk (%archive-read-disk-descend)))
                                 (let ((name (entry-pathname e)))
                                   (when (and (> (length name) (length prefix))
                                              (string= prefix name :end2 (length prefix)))
                                     (setf (entry-pathname e) (subseq name (length prefix)))
                                     (checked writer (%archive-write-header (entry-pointer e)))
                                     (when (eq (entry-type e) :regular)
                                       (loop for n = (read-entry-data-into disk buffer)
                                             until (zerop n)
                                             do (write-data writer buffer :end n)))
                                     (checked writer (%archive-write-finish-entry))
                                     (incf count)))))
                   (close-archive disk)))))
      (if (typep target 'archive-writer)
          (walk target)
          (let ((writer (apply #'open-archive-writer target
                               (loop for (k v) on writer-keys by #'cddr
                                     unless (member k '(:filter :read-disk-flags))
                                       append (list k v))))
                (ok nil))
            (unwind-protect (progn (walk writer) (setf ok t))
              (close-archive writer :abort (not ok))))))
    count))
