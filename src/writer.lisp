;;; Writing archives.

(in-package #:libarchive)

(defparameter *blocked-formats*
  '(:pax-restricted :pax :ustar :gnutar :v7tar :cpio :cpio-newc :cpio-odc :cpio-bin :cpio-pwb))

(defun blocked-format-p (format)
  (member format *blocked-formats*))

(defun open-archive-writer (target &key (format :pax-restricted) filters options
                                     passphrase bytes-per-block bytes-in-last-block)
  "Open TARGET for writing and return an ARCHIVE-WRITER. Close it with
CLOSE-ARCHIVE (which writes the trailer), or use WITH-ARCHIVE-WRITER.

TARGET is a pathname or namestring, a binary output stream, or :OCTETS, in
which case the archive is collected in memory and WRITER-OCTETS returns it
once the writer is closed (see also WITH-ARCHIVE-TO-OCTETS).

FORMAT is a keyword or libarchive format name: :pax-restricted (the default),
:pax, :ustar, :gnutar, :v7tar, :zip, :7zip, :cpio, :cpio-newc, :iso9660, :xar,
:ar-bsd, :ar-svr4, :shar, :mtree, :raw, :warc, ... or :BY-EXTENSION, which takes
format and filter from TARGET's file name (\"x.tar.gz\", \"x.zip\", ...).

FILTERS is a keyword or a list of them: :gzip :bzip2 :xz :lzma :zstd :lz4
:lzip :compress :uuencode :base64 ...

PASSPHRASE (for zip and 7z encryption) is a string or a function of no
arguments; encryption itself is chosen with OPTIONS, e.g.
'((\"zip:encryption\" . \"aes256\")). OPTIONS is a libarchive option string or
an alist.

BYTES-PER-BLOCK and BYTES-IN-LAST-BLOCK are libarchive's blocking settings. By
default uncompressed tar and cpio are padded to whole 10240-byte blocks, as
tape-era readers expect, and everything else is not padded at all."
  (load-libraries)
  (let ((h (make-handle 'archive-writer (%archive-write-new))))
    (call-with-cleanup-on-error
     h
     (lambda ()
       (let ((code (if (eq format :by-extension)
                       (%archive-write-set-format-filter-by-ext
                        (live-pointer h)
                        (etypecase target
                          ((or string pathname) (file-namestring target))))
                       (%archive-write-set-format-by-name
                        (live-pointer h) (libarchive-name format *write-format-aliases*)))))
         ;; From a format setter, WARN means "not supported in this build"
         ;; (xar without libxml2, say) and no format has been set.
         (check-result h (if (= code +archive-warn+) +archive-failed+ code) "set format"))
       (dolist (f (if (listp filters) filters (list filters)))
         (checked h (%archive-write-add-filter-by-name
                     (libarchive-name f *write-filter-aliases*))))
       (when options
         (checked h (%archive-write-set-options (options-string options))))
       (etypecase passphrase
         (null)
         (string (checked h (%archive-write-set-passphrase passphrase)))
         ((or function symbol)
          (install-passphrase-function h passphrase #'%archive-write-set-passphrase-callback)))
       (when bytes-per-block
         (checked h (%archive-write-set-bytes-per-block bytes-per-block)))
       ;; libarchive pads the last block to the full block size -- *after*
       ;; compression -- unless told otherwise; only open_filename adjusts this
       ;; itself. Zeros after a gzip or zstd stream, or after a zip's central
       ;; directory, are garbage to every other reader, so follow bsdtar: pad
       ;; only uncompressed tar and cpio.
       (checked h (%archive-write-set-bytes-in-last-block
                   (or bytes-in-last-block
                       (if (and (null filters) (blocked-format-p format)) 0 1))))
       (open-writer-target h target)
       h))))

(defgeneric open-writer-target (handle target))

(defmethod open-writer-target (h (target pathname))
  (checked h (%archive-write-open-filename (uiop:native-namestring (merge-pathnames target)))))

(defmethod open-writer-target (h (target string))
  (open-writer-target h (uiop:parse-native-namestring target)))

(defmethod open-writer-target (h (target stream))
  (install-stream-sink h target)
  (checked h (%archive-write-open (handle-key h) (cffi:null-pointer)
                                  (cffi:callback write-callback) (cffi:null-pointer))))

(defmethod open-writer-target (h (target (eql :octets)))
  (install-octet-sink h)
  (checked h (%archive-write-open (handle-key h) (cffi:null-pointer)
                                  (cffi:callback write-callback) (cffi:null-pointer))))

(defun writer-octets (writer)
  "The archive written by a closed :OCTETS writer."
  (when (archive-open-p writer)
    (error "~S is still open; its octets are complete only once it is closed." writer))
  (%writer-octets writer))

;;; Entries.

(defun write-data (writer octets &key (start 0) (end (length octets)))
  (cffi:with-pointer-to-vector-data (p octets)
    (loop while (< start end)
          do (let ((n (%archive-write-data (live-pointer writer)
                                           (cffi:inc-pointer p start) (- end start))))
               (when (< n 0) (check-result writer n "archive_write_data"))
               (when (zerop n) (return))
               (incf start n)))))

(defun write-entry (writer entry &optional data)
  "Write ENTRY's header and then DATA, which is an octet vector, a string
(written as UTF-8), a pathname (the file's contents), a binary input stream, or
NIL. If ENTRY has no size set and DATA is given, its size is set from DATA."
  (flet ((header ()
           (checked writer (%archive-write-header (entry-pointer entry))))
         (finish ()
           (checked writer (%archive-write-finish-entry))))
    (etypecase data
      (null
       ;; No data is zero bytes of it; cpio, for one, refuses an entry with
       ;; no size at all, even a directory.
       (unless (entry-size-set-p entry) (setf (entry-size entry) 0))
       (header))
      ((or string vector)
       (let ((octets (ensure-octets data)))
         (unless (entry-size-set-p entry) (setf (entry-size entry) (length octets)))
         (header)
         (write-data writer octets)))
      (pathname
       (with-open-file (in data :element-type '(unsigned-byte 8))
         (unless (entry-size-set-p entry) (setf (entry-size entry) (file-length in)))
         (header)
         (copy-stream-to-writer writer in)))
      (stream
       (if (entry-size-set-p entry)
           (progn (header) (copy-stream-to-writer writer data))
           ;; Tar and cpio need the size before the data, and an arbitrary
           ;; stream cannot say: read it all first.
           (return-from write-entry (write-entry writer entry (slurp-stream data))))))
    (finish)
    nil))

(defun transfer-entry (reader writer &optional (entry (reader-current-entry reader)))
  "Write READER's current entry ENTRY to WRITER, data and all, streamed rather
than read into memory. ENTRY is written as it stands, so it can be renamed or
otherwise changed first. Returns the number of data bytes copied."
  (flet ((stream-data ()
           (checked writer (%archive-write-header (entry-pointer entry)))
           (let ((buffer (make-array +default-block-size+ :element-type '(unsigned-byte 8)))
                 (total 0))
             (loop for n = (read-entry-data-into reader buffer)
                   until (zerop n)
                   do (write-data writer buffer :end n)
                      (incf total n))
             (checked writer (%archive-write-finish-entry))
             total)))
    (cond ((not (eq (entry-type entry) :regular))
           ;; Only files have data to copy. A zip stores a symlink's target as
           ;; its data, but the entry already says where it points.
           (setf (entry-size entry) 0)
           (write-entry writer entry)
           0)
          ((or (entry-size-set-p entry)
               ;; A compressed file read as :raw has no size, and raw output
               ;; needs none.
               (= (archive-format-code writer) +archive-format-raw+))
           (stream-data))
          (t
           ;; Zip read from a stream may not know the size until after the
           ;; data, and tar must write it first.
           (let ((data (read-entry-data reader)))
             (write-entry writer entry (and (plusp (length data)) data))
             (length data))))))

(defun copy-stream-to-writer (writer stream)
  (let ((buffer (make-array +default-block-size+ :element-type '(unsigned-byte 8))))
    (loop for n = (read-sequence buffer stream)
          until (zerop n)
          do (write-data writer buffer :end n))))

(defun slurp-stream (stream)
  (let ((chunks '()))
    (loop for buffer = (make-array +default-block-size+ :element-type '(unsigned-byte 8))
          for n = (read-sequence buffer stream)
          until (zerop n)
          do (push (if (= n (length buffer)) buffer (subseq buffer 0 n)) chunks))
    (let ((out (make-array (reduce #'+ chunks :key #'length) :element-type '(unsigned-byte 8)))
          (i 0))
      (dolist (c (nreverse chunks) out)
        (replace out c :start1 i)
        (incf i (length c))))))

(defun add-entry (writer pathname &rest keys &key data &allow-other-keys)
  "Write one entry named PATHNAME with DATA, building the entry from KEYS as
MAKE-ENTRY does (TYPE, PERM, MTIME, UID, UNAME, SYMLINK, ...). MTIME defaults
to now."
  (let ((keys (loop for (k v) on keys by #'cddr unless (eq k :data) append (list k v))))
    (let ((e (apply #'make-entry :pathname pathname keys)))
      (unwind-protect
           (progn
             (unless (getf keys :mtime) (setf (entry-mtime e) (get-universal-time)))
             (write-entry writer e data))
        (free-entry e)))))
