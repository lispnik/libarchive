;;; Reading archives.

(in-package #:libarchive)

(defconstant +default-block-size+ 65536)

(defun call-with-cleanup-on-error (handle thunk)
  "Run THUNK; if it exits non-locally, close HANDLE (discarding it) first."
  (let ((ok nil))
    (unwind-protect (multiple-value-prog1 (funcall thunk) (setf ok t))
      (unless ok (ignore-errors (close-archive handle :abort t))))))

(defun install-read-passphrases (handle passphrase)
  (etypecase passphrase
    (null)
    (string (checked handle (%archive-read-add-passphrase passphrase)))
    (cons (dolist (p passphrase)
            (checked handle (%archive-read-add-passphrase p))))
    ((or function symbol)
     (install-passphrase-function handle passphrase #'%archive-read-set-passphrase-callback))))

(defun open-archive-reader (source &key (formats :all) (filters :all) passphrase
                                     options (block-size +default-block-size+))
  "Open SOURCE for reading and return an ARCHIVE-READER. Close it with
CLOSE-ARCHIVE, or use WITH-ARCHIVE-READER.

SOURCE is a pathname or namestring (read by libarchive directly), an octet
vector (read in memory), or a binary input stream (read through callbacks;
seeking is used if the stream supports FILE-POSITION and FILE-LENGTH, which
zip and 7z need for some archives).

FORMATS and FILTERS are :ALL (the default) or a list of keywords, e.g.
:FORMATS '(:tar :zip) :FILTERS '(:gzip). PASSPHRASE is a string, a list of
strings to try in turn, or a function of no arguments returning the next
passphrase to try or NIL. OPTIONS is a libarchive option string or an alist,
see OPTIONS-STRING."
  (load-libraries)
  (let ((h (make-handle 'archive-reader (%archive-read-new))))
    (call-with-cleanup-on-error
     h
     (lambda ()
       (enable-read-support h formats *read-formats* "format")
       (enable-read-support h filters *read-filters* "filter")
       (when options
         (checked h (%archive-read-set-options (options-string options))))
       (install-read-passphrases h passphrase)
       (setf (reader-native-entry h) (%archive-entry-new2 (live-pointer h)))
       (add-cleanup h (let ((e (reader-native-entry h))) (lambda () (%archive-entry-free e))))
       (open-reader-source h source block-size)
       h))))

(defgeneric open-reader-source (handle source block-size))

(defmethod open-reader-source (h (source pathname) block-size)
  (checked h (%archive-read-open-filename (uiop:native-namestring (merge-pathnames source))
                                          block-size)))

(defmethod open-reader-source (h (source string) block-size)
  (open-reader-source h (uiop:parse-native-namestring source) block-size))

(defmethod open-reader-source (h (source vector) block-size)
  (declare (ignore block-size))
  ;; Copied out of the Lisp heap: libarchive keeps reading from the buffer long
  ;; after this call returns, and the GC may move the vector in the meantime.
  (let* ((octets (ensure-octets source))
         (n (length octets))
         (foreign (foreign-buffer h (max n 1))))
    (copy-into-foreign octets foreign n)
    (checked h (%archive-read-open-memory foreign n))))

(defmethod open-reader-source (h (source stream) block-size)
  (install-stream-source h source block-size)
  (let ((p (live-pointer h)))
    (%archive-read-set-read-callback p (cffi:callback read-callback))
    (%archive-read-set-skip-callback p (cffi:callback skip-callback))
    (when (handle-seek-function h)
      (%archive-read-set-seek-callback p (cffi:callback seek-callback)))
    (%archive-read-set-callback-data p (handle-key h))
    (checked h (%archive-read-open1))))

;;; Entries.

(defun next-entry (reader)
  "Advance to the next entry and return it, or NIL at the end of the archive.

The entry is borrowed from READER: it is invalidated by the next call and by
closing READER. Its data is read with READ-ENTRY-DATA and friends before the
next call; data not read is skipped."
  (let ((old (reader-current-entry reader)))
    (when old
      (invalidate-entry old)
      (setf (reader-current-entry reader) nil)))
  (let ((native (reader-native-entry reader)))
    (when (= +archive-eof+
             (checked reader (%archive-read-next-header2 native)))
      (return-from next-entry nil))
    (setf (reader-current-entry reader) (make-borrowed-entry native reader))))

(defmethod close-archive :before ((h archive-reader) &key abort)
  (declare (ignore abort))
  (let ((e (reader-current-entry h)))
    (when e (invalidate-entry e))))

(defun read-entry-data-into (reader buffer &key (start 0) end)
  "Read the current entry's data into BUFFER, an octet vector, like
READ-SEQUENCE: return the index of the first element not written. Returns START
at the end of the data."
  (let* ((end (or end (length buffer)))
         (count (- end start)))
    (if (zerop count)
        start
        (let ((n (if (typep buffer 'octets)
                     (cffi:with-pointer-to-vector-data (p buffer)
                       (%archive-read-data (live-pointer reader) (cffi:inc-pointer p start) count))
                     (let ((tmp (make-array count :element-type '(unsigned-byte 8))))
                       (prog1 (read-entry-data-into reader tmp)
                         (replace buffer tmp :start1 start))))))
          (when (< n 0) (check-result reader n "archive_read_data"))
          (+ start n)))))

(defun read-entry-data (reader)
  "All of the current entry's (remaining) data, as an octet vector."
  (let* ((size (let ((e (reader-current-entry reader)))
                 (and e (entry-size e))))
         (buffer (make-array (max 1 (min (or size +default-block-size+) (ash 1 30)))
                             :element-type '(unsigned-byte 8)))
         (scratch nil)
         (fill 0))
    (loop
      (if (< fill (length buffer))
          (let ((next (read-entry-data-into reader buffer :start fill)))
            (when (= next fill)
              (return (subseq buffer 0 fill)))
            (setf fill next))
          ;; Full: the recorded size was right (the usual case) unless a probe
          ;; read finds more, so only grow once there is something to put there.
          (let ((n (read-entry-data-into
                    reader (or scratch (setf scratch (make-array +default-block-size+
                                                                 :element-type '(unsigned-byte 8)))))))
            (when (zerop n)
              (return buffer))
            (let ((new (make-array (max (* 2 (length buffer)) (+ fill n))
                                   :element-type '(unsigned-byte 8))))
              (replace new buffer)
              (replace new scratch :start1 fill :end2 n)
              (setf buffer new
                    fill (+ fill n))))))))

(defun read-entry-string (reader &key (encoding :utf-8))
  "The current entry's data decoded as text."
  (babel:octets-to-string (read-entry-data reader) :encoding encoding))

(defun copy-entry-data (reader stream &key (buffer-size +default-block-size+))
  "Copy the current entry's data to the binary output STREAM; return the byte count."
  (let ((buffer (make-array buffer-size :element-type '(unsigned-byte 8))))
    (loop for n = (read-entry-data-into reader buffer)
          until (zerop n)
          do (write-sequence buffer stream :end n)
          sum n)))

(defun skip-entry-data (reader)
  "Skip the rest of the current entry's data."
  (checked reader (%archive-read-data-skip))
  nil)

(defun archive-has-encrypted-entries (reader)
  "T, NIL, or :UNKNOWN (the format can tell only once entries have been read)."
  (let ((v (%archive-read-has-encrypted-entries (live-pointer reader))))
    (cond ((= v +archive-read-format-encryption-dont-know+) :unknown)
          ((= v +archive-read-format-encryption-unsupported+) nil)
          (t (plusp v)))))
