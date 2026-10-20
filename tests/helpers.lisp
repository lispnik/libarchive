(in-package #:libarchive/tests)

(defun run-tests ()
  "Run every suite; true if all passed."
  (run! 'libarchive-all))

(defun octets (&rest bytes)
  (make-array (length bytes) :element-type '(unsigned-byte 8) :initial-contents bytes))

(defun random-octets (n &optional (seed 42))
  "N pseudo-random bytes, the same every run. Incompressible, so blocks really fill."
  (let ((v (make-array n :element-type '(unsigned-byte 8)))
        (x seed))
    (dotimes (i n v)
      (setf x (mod (+ (* x 1103515245) 12345) (expt 2 31)))
      (setf (aref v i) (ldb (byte 8 16) x)))))

(defun every-byte ()
  (let ((v (make-array 256 :element-type '(unsigned-byte 8))))
    (dotimes (i 256 v) (setf (aref v i) i))))

(defun octets= (a b)
  (and (= (length a) (length b)) (every #'= a b)))

(defvar *temp-counter* 0)

(defun call-with-temp-directory (function)
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames (format nil "libarchive-test-~D-~D-~D"
                                       (random 1000000 (make-random-state t)) (get-universal-time)
                                       (incf *temp-counter*))
                               (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    (unwind-protect (funcall function (truename dir))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(defmacro with-temp-directory ((var) &body body)
  `(call-with-temp-directory (lambda (,var) ,@body)))

(defun write-file (path data)
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :element-type '(unsigned-byte 8)
                            :if-exists :supersede)
    (write-sequence (libarchive::ensure-octets data) out))
  path)

(defun read-file (path)
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let ((v (make-array (file-length in) :element-type '(unsigned-byte 8))))
      (read-sequence v in)
      v)))

(defconstant +sample-mtime+ 3900000000)

(defun sample-archive (&rest writer-keys)
  "A small archive in memory: a directory, two files, a symlink."
  (let ((w (apply #'open-archive-writer :octets writer-keys)))
    (unwind-protect
         (progn
           (add-entry w "top/" :mtime +sample-mtime+)
           (add-entry w "top/a.txt" :data "alpha" :mtime +sample-mtime+)
           (add-entry w "top/b.bin" :data (every-byte) :perm #o600 :mtime +sample-mtime+)
           (add-entry w "top/link" :symlink "a.txt" :mtime +sample-mtime+))
      (close-archive w))
    (writer-octets w)))

(defun entries-alist (source &rest reader-keys)
  "((name . data-octets) ...) for every entry of SOURCE."
  (let ((r (apply #'open-archive-reader source reader-keys)))
    (unwind-protect
         (let ((out '()))
           (do-archive-entries (e r (nreverse out))
             (push (cons (entry-pathname e) (read-entry-data r)) out)))
      (close-archive r))))

(defun program-available-p (name)
  (ignore-errors
   (zerop (nth-value 2 (uiop:run-program (list "/bin/sh" "-c" (format nil "command -v ~A" name))
                                         :ignore-error-status t)))))

(defun run-command (&rest args)
  "Run ARGS, return stdout as a string; signal on failure."
  (uiop:run-program args :output :string :error-output :string))

;;; In-memory Gray streams. Neither answers FILE-LENGTH, so to the library they
;;; are unseekable: the stream path that has to work without skip or seek.
;;; FAIL-AFTER makes them signal TEST-STREAM-ERROR once that many bytes have
;;; passed, to drive the callback error path.

(define-condition test-stream-error (error) ()
  (:report "deliberate test stream failure"))

(defclass octet-input-stream (sb-gray:fundamental-binary-input-stream)
  ((data :initarg :data)
   (pos :initform 0)
   (fail-after :initarg :fail-after :initform nil)))

(defun make-octet-input-stream (data &key fail-after)
  (make-instance 'octet-input-stream :data data :fail-after fail-after))

(defmethod stream-element-type ((s octet-input-stream)) '(unsigned-byte 8))

(defmethod sb-gray:stream-read-byte ((s octet-input-stream))
  (with-slots (data pos) s
    (if (< pos (length data)) (prog1 (aref data pos) (incf pos)) :eof)))

(defmethod sb-gray:stream-read-sequence ((s octet-input-stream) seq &optional (start 0) end)
  (with-slots (data pos fail-after) s
    (when (and fail-after (>= pos fail-after))
      (error 'test-stream-error))
    (let* ((end (or end (length seq)))
           (n (min (- end start) (- (length data) pos)
                   ;; Short reads, to exercise more callback calls.
                   4096)))
      (replace seq data :start1 start :end1 (+ start n) :start2 pos)
      (incf pos n)
      (+ start n))))

(defclass octet-output-stream (sb-gray:fundamental-binary-output-stream)
  ((data :initform (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)
         :reader octet-output-stream-data)
   (fail-after :initarg :fail-after :initform nil)))

(defun make-octet-output-stream (&key fail-after)
  (make-instance 'octet-output-stream :fail-after fail-after))

(defmethod stream-element-type ((s octet-output-stream)) '(unsigned-byte 8))

(defmethod sb-gray:stream-write-byte ((s octet-output-stream) byte)
  (vector-push-extend byte (slot-value s 'data))
  byte)

(defmethod sb-gray:stream-write-sequence ((s octet-output-stream) seq &optional (start 0) end)
  (with-slots (data fail-after) s
    (when (and fail-after (>= (length data) fail-after))
      (error 'test-stream-error))
    (loop for i from start below (or end (length seq))
          do (vector-push-extend (aref seq i) data))
    seq))

(defun stream-octets (s)
  (coerce (octet-output-stream-data s) '(simple-array (unsigned-byte 8) (*))))

(defun last-char (string)
  (and (plusp (length string)) (char string (1- (length string)))))
