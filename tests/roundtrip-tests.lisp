(in-package #:libarchive/tests)

(def-suite libarchive-roundtrip :in libarchive-all)
(in-suite libarchive-roundtrip)

(defparameter *payloads*
  `(("empty" . ,(octets))
    ("bytes" . ,(every-byte))
    ;; Bigger than any block size in play, so data crosses block boundaries.
    ("big" . ,(random-octets 300000))
    ("text.txt" . ,(babel:string-to-octets "naïve café ☕
" :encoding :utf-8))))

(defun round-trip (&rest writer-keys)
  (let ((archive (let ((w (apply #'open-archive-writer :octets writer-keys)))
                   (unwind-protect
                        (loop for (name . data) in *payloads*
                              do (add-entry w (concatenate 'string "d/" name) :data data))
                     (close-archive w))
                   (writer-octets w))))
    (entries-alist archive)))

(defun check-round-trip (&rest writer-keys)
  (let ((got (apply #'round-trip writer-keys)))
    ;; By name, not position: the 7z writer puts empty files last.
    (is (equal (sort (mapcar (lambda (p) (concatenate 'string "d/" (car p))) *payloads*) #'string<)
               (sort (mapcar #'car got) #'string<))
        "~S: names ~S" writer-keys (mapcar #'car got))
    (loop for (name . data) in *payloads*
          for read = (cdr (assoc (concatenate 'string "d/" name) got :test #'string=))
          do (is (and read (octets= data read)) "~S: ~A differs" writer-keys name))))

(defun format-supported-p (format)
  (handler-case (progn (close-archive (open-archive-writer :octets :format format)) t)
    (archive-error () nil)))

(test tar-family-formats
  (dolist (format '(:pax-restricted :pax :ustar :gnutar :v7tar))
    (check-round-trip :format format)))

(test cpio-formats
  (dolist (format '(:cpio :cpio-newc :cpio-odc))
    (check-round-trip :format format)))

(test container-formats
  (dolist (format '(:zip :7zip))
    (check-round-trip :format format)))

(test xar-if-supported
  ;; Writing xar needs libxml2, which not every libarchive build has.
  (if (format-supported-p :xar)
      (check-round-trip :format :xar)
      (skip "this libarchive cannot write xar")))

(test filters
  (dolist (filter '(:gzip :bzip2 :xz :lzma :zstd :lz4 :lzip :compress :uuencode :base64))
    (check-round-trip :format :pax-restricted :filters filter)))

(test stacked-filters
  (check-round-trip :format :ustar :filters '(:gzip :base64)))

(test reader-reports-format-and-filters
  (with-archive-reader (r (sample-archive :format :ustar :filters :xz))
    (next-entry r)
    (is (= +archive-format-tar-ustar+ (logand (archive-format-code r) #xff0003)))
    (is (equal '("xz") (archive-filter-names r)))))

(test restricted-read-formats
  ;; A zip offered to a tar-only reader is not recognised.
  (let ((zip (sample-archive :format :zip)))
    (is (= 4 (length (archive-entry-names zip :formats '(:zip)))))
    (signals archive-fatal-error (archive-entry-names zip :formats '(:tar)))))

(test empty-archive
  (let ((o (with-archive-to-octets (w :format :ustar))))
    (is (plusp (length o)))
    (is (null (archive-entry-names o)))))

(test file-count
  (with-archive-reader (r (sample-archive))
    (do-archive-entries (e r) (skip-entry-data r))
    (is (= 4 (archive-file-count r)))))

(test chunked-reads
  (let ((archive (with-archive-to-octets (w :format :zip)
                   (add-entry w "big" :data (random-octets 100000)))))
    (with-archive-reader (r archive)
      (next-entry r)
      (let ((buffer (make-array 777 :element-type '(unsigned-byte 8)))
            (out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
        (loop for n = (read-entry-data-into r buffer :start 7)
              until (= n 7)
              do (loop for i from 7 below n do (vector-push-extend (aref buffer i) out)))
        (is (octets= (random-octets 100000) out))))))

(test options-are-applied
  ;; zip "store" leaves the data visible; deflate does not.
  (let* ((text (make-string 5000 :initial-element #\z))
         (stored (with-archive-to-octets (w :format :zip :options '(("zip:compression" . "store")))
                   (add-entry w "z" :data text)))
         (deflated (with-archive-to-octets (w :format :zip :options "zip:compression=deflate")
                     (add-entry w "z" :data text))))
    (is (> (length stored) 5000))
    (is (< (length deflated) 1000))
    (is (string= text (cdr (first (mapcar (lambda (p) (cons (car p) (babel:octets-to-string (cdr p))))
                                         (entries-alist stored))))))))

(test stream-data-without-size-is-buffered
  (let ((archive (with-archive-to-octets (w :format :ustar)
                   (with-entry (e :pathname "s")
                     (write-entry w e (make-octet-input-stream (babel:string-to-octets "streamed")))))))
    (is (string= "streamed" (babel:octets-to-string (cdr (first (entries-alist archive))))))))

(test non-ascii-names-in-every-format
  ;; libarchive converts names through the process locale, which in SBCL is "C"
  ;; unless LOAD-LIBRARIES fixes it: then pax crashed outright, ustar wrote an
  ;; empty name, 7z a damaged archive and cpio refused the entry.
  (flet ((normalize (names format)
           ;; iso9660 and xar list directories without the slash; iso9660 adds ".".
           (sort (loop for n in names
                       unless (string= n ".")
                         collect (if (member format '(:iso9660 :xar)) (string-right-trim "/" n) n))
                 #'string<)))
    (dolist (format '(:pax-restricted :pax :ustar :gnutar :zip :7zip :cpio-newc :cpio-odc
                      :ar-bsd :iso9660 :xar))
      (when (format-supported-p format)
        (let* ((names (if (eq format :ar-bsd)
                          ;; ar has no directories, only file names.
                          '("日本語.txt" "naïve café ☕.txt")
                          '("Grüße/" "Grüße/日本語.txt" "naïve café ☕.txt")))
               (archive (with-archive-to-octets (w :format format)
                          (dolist (n names)
                            (add-entry w n :data (if (eql #\/ (last-char n)) nil n))))))
          (is (equal (normalize names format) (normalize (archive-entry-names archive) format))
              "~S: ~S" format (archive-entry-names archive)))))))

(test locale-has-a-utf-8-codeset
  (load-libraries)
  (is (libarchive::utf-8-locale-name-p (libarchive::setlocale-ctype nil))))

(defun transfer-all (source &rest writer-keys)
  "Every entry of SOURCE through TRANSFER-ENTRY, renamed under copy/; returns the
new archive's octets and the bytes copied."
  (let ((bytes 0))
    (values (apply #'call-with-octets-writer
                   (lambda (w)
                     (with-archive-reader (r source)
                       (do-archive-entries (e r)
                         (setf (entry-pathname e) (format nil "copy/~A" (entry-pathname e)))
                         (incf bytes (transfer-entry r w)))))
                   writer-keys)
            bytes)))

(defun call-with-octets-writer (function &rest writer-keys)
  (let ((w (apply #'open-archive-writer :octets writer-keys)))
    (funcall function w)
    (close-archive w)
    (writer-octets w)))

(test transfer-entry-streams-every-kind-of-entry
  (let* ((big (let ((v (make-array 300000 :element-type '(unsigned-byte 8))))
                (dotimes (i (length v) v) (setf (aref v i) (mod (* 31 i) 256)))))
         (zip (with-archive-to-octets (w :format :zip)
                (add-entry w "d/")
                (add-entry w "d/big" :data big)
                (add-entry w "d/empty" :data "")
                (add-entry w "d/link" :symlink "big"))))
    ;; From a seekable source, and from a stream that cannot seek, where zip
    ;; may not know an entry's size before its data. Nor its type: that is in
    ;; the central directory at the end, so streamed, the symlink is a file
    ;; holding its target.
    (loop for source in (list zip (make-octet-input-stream zip))
          for streamed in '(nil t) do
      (multiple-value-bind (tar bytes) (transfer-all source :format :pax-restricted :filters :zstd)
        (is (= (+ (length big) (if streamed 3 0)) bytes))
        (with-archive-reader (r tar)
          (let ((seen '()))
            (do-archive-entries (e r)
              (push (entry-pathname e) seen)
              (cond ((string= (entry-pathname e) "copy/d/big")
                     (is (octets= big (read-entry-data r))))
                    ((string= (entry-pathname e) "copy/d/link")
                     (if streamed
                         (is (string= "big" (read-entry-string r)))
                         (is (string= "big" (entry-symlink e)))))
                    ((string= (entry-pathname e) "copy/d/empty")
                     (is (zerop (length (read-entry-data r)))))))
            (is (equal '("copy/d/" "copy/d/big" "copy/d/empty" "copy/d/link")
                       (sort seen #'string<)))))))))
