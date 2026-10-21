;;; Errors: what goes wrong, which condition says so, and what state things are
;;; left in.
;;;
;;;   make example NAME=errors
;;;
;;; libarchive's return codes become a condition hierarchy:
;;;
;;;   ARCHIVE-CONDITION                 code, errno, message, operation
;;;     ARCHIVE-WARNING  (warning)      ARCHIVE_WARN: it worked, with a diagnostic
;;;     ARCHIVE-ERROR    (error)        ARCHIVE_FAILED: this call failed, carry on
;;;       ARCHIVE-RETRY                 ARCHIVE_RETRY: try that again
;;;       ARCHIVE-FATAL-ERROR           ARCHIVE_FATAL: only CLOSE-ARCHIVE is left

;;; Gray streams are not in the standard; trivial-gray-streams papers over
;;; the differences between implementations.
(asdf:load-system :trivial-gray-streams)

(defpackage #:libarchive-examples/errors
  (:use #:cl #:libarchive))

(in-package #:libarchive-examples/errors)

(defun show (label condition)
  (format t "~&~A~%  ~S~%  message: ~A~%  operation: ~A, code: ~A, errno: ~A~%"
          label (type-of condition)
          (archive-condition-message condition) (archive-condition-operation condition)
          (archive-condition-code condition) (archive-condition-errno condition)))

(defmacro expecting ((type label) &body body)
  "Run BODY, which must signal TYPE; describe the condition."
  `(handler-case (progn ,@body (error "~A: no ~S was signalled" ,label ',type))
     (,type (c) (show ,label c))))

;;; A stream that breaks after N bytes, like a dropped connection.
(define-condition connection-lost (error) ()
  (:report "the connection was lost"))

(defclass flaky-stream (trivial-gray-streams:fundamental-binary-input-stream)
  ((data :initarg :data) (position :initform 0) (fail-at :initarg :fail-at)))

(defmethod stream-element-type ((s flaky-stream)) '(unsigned-byte 8))

(defmethod trivial-gray-streams:stream-read-sequence ((s flaky-stream) seq start end &key)
  (with-slots (data position fail-at) s
    (when (>= position fail-at) (error 'connection-lost))
    (let ((n (min 4096 (- (or end (length seq)) start) (- (length data) position))))
      (replace seq data :start1 start :end1 (+ start n) :start2 position)
      (incf position n)
      (+ start n))))

(defun sample (&rest keys)
  (let ((w (apply #'open-archive-writer :octets keys)))
    (add-entry w "a.txt" :data (make-string 50000 :initial-element #\a))
    (add-entry w "b.txt" :data "b")
    (close-archive w)
    (writer-octets w)))

(defun main ()
  ;; Not an archive at all.
  (expecting (archive-fatal-error "Garbage in:")
    (archive-entry-names (babel:string-to-octets "this is not an archive, just text")))

  ;; An archive cut short: the headers read, the data is not there.
  (let ((tgz (sample :format :ustar :filters :gzip)))
    (expecting (archive-error "Truncated .tar.gz:")
      (with-archive-reader (r (subseq tgz 0 (floor (length tgz) 2)))
        (do-archive-entries (e r) (read-entry-data r)))))

  ;; A missing file: errno is the system's.
  (expecting (archive-fatal-error "No such file:")
    (archive-entry-names #p"/nonexistent/archive.tar"))

  ;; Asking for something libarchive does not have.
  (expecting (archive-error "Unknown format name:")
    (open-archive-writer :octets :format "no-such-format"))

  ;; Misspelt keywords are caught on the Lisp side, before libarchive sees them.
  (handler-case (open-archive-reader (sample :format :zip) :formats '(:zipp))
    (error (c) (format t "~&Misspelt keyword:~%  ~A~%" c)))

  ;; An error raised by *your* code inside a callback -- here, a stream's
  ;; READ-SEQUENCE -- comes back as itself, not as "read callback failed".
  (handler-case (with-archive-reader (r (make-instance 'flaky-stream
                                                       :data (sample :format :ustar)
                                                       :fail-at 8192))
                  (do-archive-entries (e r) (read-entry-data r)))
    (connection-lost (c) (format t "~&From inside a callback:~%  ~S: ~A~%" (type-of c) c)))

  ;; Warnings: the operation worked. Here a 300-character name in plain ustar,
  ;; which can only store 255, is a failure; pax stores it with a warning-free
  ;; extended header. Watch for warnings with HANDLER-BIND, muffle if you like.
  (let ((long-name (format nil "~{~A~^/~}" (loop repeat 30 collect "directory"))))
    (expecting (archive-error "Name too long for ustar:")
      (with-archive-to-octets (w :format :ustar) (add-entry w long-name :data "x")))
    (let ((warnings 0))
      (handler-bind ((archive-warning (lambda (c) (incf warnings) (muffle-warning c))))
        (assert (equal (list long-name)
                       (archive-entry-names
                        (with-archive-to-octets (w :format :pax)
                          (add-entry w long-name :data "x"))))))
      (format t "~&pax stored the ~D-character name with ~D warnings~%"
              (length long-name) warnings)))

  ;; A non-local exit from WITH-ARCHIVE-WRITER aborts the writer: no trailer is
  ;; written, so the half-made archive cannot pass for a complete one.
  (let ((path (merge-pathnames "aborted.tar" (uiop:temporary-directory))))
    (unwind-protect
         (progn
           (ignore-errors
            (with-archive-writer (w path :format :ustar)
              (add-entry w "first.txt" :data "written")
              (error "something went wrong half-way")))
           (with-open-file (in path :element-type '(unsigned-byte 8) :if-does-not-exist nil)
             (format t "~&Aborted writer left ~:[no file~;~:*~D bytes, without a trailer~]~%"
                     (and in (file-length in)))))
      (uiop:delete-file-if-exists path)))

  ;; Closing twice is fine; using a closed handle is an error.
  (let ((r (open-archive-reader (sample :format :zip))))
    (close-archive r)
    (close-archive r)
    (assert (not (archive-open-p r)))
    (handler-case (next-entry r)
      (error (c) (format t "~&After close:~%  ~A~%" c)))))

(main)
