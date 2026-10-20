;;; Lisp handles around struct archive *, and the return-code check.
;;;
;;;   archive-handle
;;;     archive-reader   archive_read_new
;;;       disk-reader    archive_read_disk_new: walks a directory tree, and is
;;;                      read with the same NEXT-ENTRY / READ-ENTRY-DATA
;;;     archive-writer   archive_write_new
;;;       disk-writer    archive_write_disk_new: WRITE-ENTRY creates files
;;;
;;; libarchive's own read/write split is mirrored exactly, because it is the
;;; split that decides which close and free functions apply.

(in-package #:libarchive)

(defclass archive-handle ()
  ((pointer       :initarg :pointer :accessor handle-pointer)
   ;; Our registry key, passed to libarchive as every callback's client data.
   (key           :initform nil :accessor handle-key)
   ;; The first Lisp error raised inside one of our callbacks, waiting to be
   ;; re-signalled once control is back on the Lisp side of the C call.
   (pending-error :initform nil :accessor handle-pending-error)
   ;; Foreign memory this handle owns, freed after the archive is.
   (allocations   :initform nil :accessor handle-allocations)
   ;; Thunks run after the archive is freed, in the order they were added.
   (cleanups      :initform nil :accessor handle-cleanups)
   ;; The Lisp side of the callbacks; see callbacks.lisp.
   (read-function       :initform nil :accessor handle-read-function)
   (skip-function       :initform nil :accessor handle-skip-function)
   (seek-function       :initform nil :accessor handle-seek-function)
   (write-function      :initform nil :accessor handle-write-function)
   (passphrase-function :initform nil :accessor handle-passphrase-function)
   (passphrase-buffer   :initform nil :accessor handle-passphrase-buffer)
   (progress-function   :initform nil :accessor handle-progress-function)
   (filter-function     :initform nil :accessor handle-filter-function)))

(defclass archive-reader (archive-handle)
  ;; next_header2 fills an entry we own, so its lifetime is ours to define:
  ;; it lives as long as the reader, and the Lisp ENTRY that views it is
  ;; invalidated by the next NEXT-ENTRY.
  ((native-entry  :initform nil :accessor reader-native-entry)
   (current-entry :initform nil :accessor reader-current-entry)))

(defclass disk-reader (archive-reader) ())

(defclass archive-writer (archive-handle)
  ((octets :initform nil :accessor %writer-octets)))

(defclass disk-writer (archive-writer) ())

(defmethod print-object ((h archive-handle) stream)
  (print-unreadable-object (h stream :type t :identity t)
    (unless (archive-open-p h) (write-string "closed" stream))))

(defun archive-open-p (handle)
  (not (cffi:null-pointer-p (handle-pointer handle))))

(defun live-pointer (handle)
  (let ((p (handle-pointer handle)))
    (when (cffi:null-pointer-p p)
      (error "~S has been closed." handle))
    p))

(defun make-handle (class pointer)
  (when (cffi:null-pointer-p pointer)
    (error 'archive-fatal-error :message "allocation failed" :operation "new"))
  (let ((h (make-instance class :pointer pointer)))
    (setf (handle-key h) (register-object h))
    h))

(defun foreign-buffer (handle size)
  "SIZE bytes of foreign memory, freed when HANDLE is closed."
  (let ((p (cffi:foreign-alloc :uint8 :count size)))
    (push p (handle-allocations handle))
    p))

(defun add-cleanup (handle thunk)
  (setf (handle-cleanups handle) (append (handle-cleanups handle) (list thunk))))

;;; Return codes.

(defun check-result (handle code operation)
  "Return CODE if it is not an error, else signal the matching condition.

A Lisp error raised inside one of HANDLE's callbacks takes precedence: it is
re-signalled as itself, since libarchive's report of it (\"read callback
failed\") would only hide it."
  (let ((pending (handle-pending-error handle)))
    (when pending
      (setf (handle-pending-error handle) nil)
      (error pending)))
  (if (>= code 0)
      code
      (let* ((p (handle-pointer handle))
             (args (list :code code :operation operation
                         :errno (%archive-errno p) :message (%archive-error-string p))))
        (cond ((= code +archive-warn+)
               (apply #'warn 'archive-warning args)
               code)
              ((= code +archive-retry+) (apply #'error 'archive-retry args))
              ((= code +archive-failed+) (apply #'error 'archive-error args))
              (t (apply #'error 'archive-fatal-error args))))))

(defmacro checked (handle (function &rest args))
  "Call raw FUNCTION on HANDLE's pointer and ARGS, then CHECK-RESULT."
  (let ((h (gensym "HANDLE")))
    `(let ((,h ,handle))
       (check-result ,h (,function (live-pointer ,h) ,@args)
                     ,(substitute #\_ #\- (string-downcase (subseq (symbol-name function) 1)))))))

;;; Closing.

(defgeneric close-foreign (handle pointer abort)
  (:documentation "Close the libarchive object; return its code."))

(defgeneric free-foreign (handle pointer))

(defmethod close-foreign ((h archive-reader) p abort)
  (declare (ignore abort))
  (%archive-read-close p))

(defmethod free-foreign ((h archive-reader) p)
  (%archive-read-free p))

(defmethod close-foreign ((h archive-writer) p abort)
  (if abort
      ;; Marks the archive fatal, so the free below writes no trailer.
      (progn (%archive-write-fail p) +archive-ok+)
      (%archive-write-close p)))

(defmethod free-foreign ((h archive-writer) p)
  (%archive-write-free p))

(defgeneric close-archive (handle &key abort)
  (:documentation "Close and free HANDLE. Idempotent.

For a writer this flushes the last block and the archive trailer, and errors in
doing so are signalled. With ABORT true, a writer is discarded instead: no
trailer is written, which is what to do after an error part-way through."))

(defmethod close-archive ((h archive-handle) &key abort)
  (let ((p (handle-pointer h)))
    (unless (cffi:null-pointer-p p)
      (unwind-protect
           (check-result h (close-foreign h p abort) "close")
        (free-foreign h p)
        (setf (handle-pointer h) (cffi:null-pointer))
        (unregister-object (handle-key h))
        (mapc #'cffi:foreign-free (handle-allocations h))
        (setf (handle-allocations h) nil)
        (let ((buffer (handle-passphrase-buffer h)))
          (when buffer
            (cffi:foreign-string-free buffer)
            (setf (handle-passphrase-buffer h) nil)))
        (mapc #'funcall (shiftf (handle-cleanups h) nil))))
    nil))

;;; Introspection valid on any open handle.

(defun archive-format-name (handle)
  "The name of the archive format, e.g. \"POSIX pax interchange format\"."
  (%archive-format-name (live-pointer handle)))

(defun archive-format-code (handle)
  "The ARCHIVE_FORMAT_* code."
  (%archive-format (live-pointer handle)))

(defun archive-filter-names (handle)
  "Names of the filters (compressions) in effect, excluding \"none\": the one
nearest the archive format first, the outermost last. For a .tar.gz.b64 that is
(\"gzip\" \"uu\"), the order :FILTERS takes them in."
  (let ((p (live-pointer handle)))
    (loop for i below (%archive-filter-count p)
          for name = (%archive-filter-name p i)
          unless (or (null name) (string= name "none"))
            collect name)))

(defun archive-file-count (handle)
  "How many entries have been read or written so far."
  (%archive-file-count (live-pointer handle)))
