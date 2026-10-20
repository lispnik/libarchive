;;; The callbacks: one DEFCALLBACK per libarchive callback type.
;;;
;;; Each looks its handle up from the client data (registry.lisp) and calls the
;;; Lisp function stored in the matching slot. The body is guarded: a Lisp
;;; condition never unwinds through libarchive's C frames. It is caught, kept
;;; on the handle as its pending error, reported to libarchive via
;;; archive_set_error, and the callback returns failure. The C call then
;;; returns an error code, and CHECK-RESULT re-signals the original condition.

(in-package #:libarchive)

(defun note-callback-error (handle archive condition)
  (unless (handle-pending-error handle)
    (setf (handle-pending-error handle) condition))
  (when (and archive (not (cffi:null-pointer-p archive)))
    (%archive-set-error archive -1 "%s"
                        :string (or (ignore-errors (princ-to-string condition))
                                    "error in Lisp callback"))))

(defmacro define-guarded-callback (name return-type (archive data &rest args)
                                   failure &body body)
  "Define callback NAME whose BODY runs with HANDLE bound to the registered
handle. If there is no such handle, or BODY signals, return FAILURE."
  `(cffi:defcallback ,name ,return-type ((,archive :pointer) (,data :pointer) ,@args)
     (let ((handle (find-registered ,data)))
       (if (null handle)
           ,failure
           (handler-case (progn ,@body)
             (serious-condition (c)
               (note-callback-error handle ,archive c)
               ,failure))))))

;;; Reading.

(define-guarded-callback read-callback :ssize (a data (buffer :pointer))
    +archive-fatal+
  ;; Returns (values foreign-pointer byte-count); 0 bytes is end of input.
  (multiple-value-bind (pointer count) (funcall (handle-read-function handle))
    (setf (cffi:mem-ref buffer :pointer) pointer)
    count))

(define-guarded-callback skip-callback :int64 (a data (request :int64))
    ;; Skipping zero bytes tells libarchive to read and discard instead.
    0
  (let ((f (handle-skip-function handle)))
    (if f (funcall f request) 0)))

(define-guarded-callback seek-callback :int64 (a data (offset :int64) (whence :int))
    +archive-fatal+
  (funcall (handle-seek-function handle) offset whence))

;;; Writing.

(define-guarded-callback write-callback :ssize (a data (buffer :pointer) (length :size))
    -1
  (funcall (handle-write-function handle) buffer length))

;;; Passphrases. The returned string must outlive the call, so it is kept on
;;; the handle until the next call or until the handle is closed.

(define-guarded-callback passphrase-callback :pointer (a data)
    (cffi:null-pointer)
  (let ((old (handle-passphrase-buffer handle)))
    (when old
      (setf (handle-passphrase-buffer handle) nil)
      (cffi:foreign-string-free old)))
  (let ((passphrase (funcall (handle-passphrase-function handle))))
    (if passphrase
        (setf (handle-passphrase-buffer handle)
              (cffi:foreign-string-alloc passphrase :encoding :utf-8))
        (cffi:null-pointer))))

;;; Extraction progress: the only callback with no struct archive argument.

(cffi:defcallback progress-callback :void ((data :pointer))
  (let ((handle (find-registered data)))
    (when handle
      (handler-case (funcall (handle-progress-function handle))
        (serious-condition (c)
          (note-callback-error handle nil c))))))

;;; Disk traversal: return 1 to keep the entry, 0 to skip it.

(define-guarded-callback metadata-filter-callback :int (a data (entry :pointer))
    0
  ;; The entry is libarchive's and only valid for this call.
  (let ((e (make-borrowed-entry entry handle)))
    (unwind-protect
         (if (funcall (handle-filter-function handle) e) 1 0)
      (invalidate-entry e))))

;;; Lisp-side sources and sinks.

(defun copy-into-foreign (vector foreign count)
  (cffi:with-pointer-to-vector-data (p vector)
    (%memcpy foreign p count)))

(defun copy-from-foreign (foreign vector start count)
  (cffi:with-pointer-to-vector-data (p vector)
    (%memcpy (cffi:inc-pointer p start) foreign count)))

(defun stream-seekable-p (stream)
  (ignore-errors (and (file-position stream) (file-length stream) t)))

(defun install-stream-source (handle stream block-size)
  "Have HANDLE's read callbacks read from the binary input STREAM."
  (let ((foreign (foreign-buffer handle block-size))
        (chunk (make-array block-size :element-type '(unsigned-byte 8))))
    (setf (handle-read-function handle)
          (lambda ()
            (let ((n (read-sequence chunk stream)))
              (copy-into-foreign chunk foreign n)
              (values foreign n))))
    (when (stream-seekable-p stream)
      (setf (handle-skip-function handle)
            (lambda (request)
              (let* ((here (file-position stream))
                     (n (max 0 (min request (- (file-length stream) here)))))
                (file-position stream (+ here n))
                n))
            (handle-seek-function handle)
            (lambda (offset whence)
              (let ((target (ecase whence
                              (0 offset)
                              (1 (+ (file-position stream) offset))
                              (2 (+ (file-length stream) offset)))))
                (if (file-position stream target)
                    target
                    +archive-fatal+)))))))

(defun install-stream-sink (handle stream)
  "Have HANDLE's write callback write to the binary output STREAM."
  (let ((chunk (make-array 0 :element-type '(unsigned-byte 8))))
    (setf (handle-write-function handle)
          (lambda (buffer length)
            (when (< (length chunk) length)
              (setf chunk (make-array length :element-type '(unsigned-byte 8))))
            (copy-from-foreign buffer chunk 0 length)
            (write-sequence chunk stream :end length)
            length))
    (add-cleanup handle (lambda () (finish-output stream)))))

(defun install-octet-sink (handle)
  "Have HANDLE's write callback accumulate into a vector, kept on close."
  (let ((buffer (make-array 16384 :element-type '(unsigned-byte 8)))
        (fill 0))
    (setf (handle-write-function handle)
          (lambda (foreign length)
            (when (> (+ fill length) (length buffer))
              (let ((new (make-array (max (* 2 (length buffer)) (+ fill length))
                                     :element-type '(unsigned-byte 8))))
                (replace new buffer :end2 fill)
                (setf buffer new)))
            (copy-from-foreign foreign buffer fill length)
            (incf fill length)
            length))
    (add-cleanup handle (lambda () (setf (%writer-octets handle) (subseq buffer 0 fill))))))
