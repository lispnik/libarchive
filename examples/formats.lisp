;;; Formats, filters and options: what can be written, and how a reader is told
;;; what to accept.
;;;
;;;   make example NAME=formats
;;;
;;; Everything here is in memory (WITH-ARCHIVE-TO-OCTETS, and vectors as reader
;;; sources), so it is also a tour of what the installed libarchive was built with:
;;; a format or filter it lacks shows up as "not available" rather than an error.

(defpackage #:libarchive-examples/formats
  (:use #:cl #:libarchive))

(in-package #:libarchive-examples/formats)

(defparameter *files*
  '(("doc/readme.txt" . "Read me.
")
    ("doc/data.csv" . "a,b,c
1,2,3
")))

(defun archive-of (&rest writer-keys)
  "The sample files as an archive written with WRITER-KEYS, or NIL if this
libarchive cannot write that combination."
  (handler-case
      (let ((w (apply #'open-archive-writer :octets writer-keys)))
        (unwind-protect
             (loop for (name . text) in *files*
                   do (add-entry w name :data text))
          (close-archive w))
        (writer-octets w))
    (archive-error () nil)))

(defun read-back (octets &rest reader-keys)
  "((name . text) ...) and the detected format and filters."
  ;; WITH-ARCHIVE-READER takes its keys literally; with a list of them in hand,
  ;; OPEN-ARCHIVE-READER and CLOSE-ARCHIVE are the way.
  (let ((r (apply #'open-archive-reader octets reader-keys)))
    (unwind-protect
         (let ((files (loop for e = (next-entry r)
                            while e
                            collect (cons (entry-pathname e) (read-entry-string r)))))
           (values files (archive-format-name r) (archive-filter-names r)))
      (close-archive r))))

(defun main ()
  ;; Every write format, uncompressed.
  (format t "~&~16A ~8@A  ~A~%" "format" "bytes" "read back as")
  (dolist (format '(:pax-restricted :pax :ustar :gnutar :v7tar :zip :7zip
                    :cpio :cpio-newc :cpio-odc :iso9660 :xar :warc))
    (let ((octets (archive-of :format format)))
      (if (null octets)
          (format t "~(~16A~) ~8@A~%" format "not available")
          (multiple-value-bind (files format-name) (read-back octets)
            (format t "~(~16A~) ~8D  ~A~%" format (length octets) (or format-name "(unnamed)"))
            ;; iso9660 adds "." and 7-Zip may reorder; the data is what matters.
            (loop for (name . text) in *files*
                  do (assert (equal text (cdr (assoc name files :test #'string=)))))))))

  ;; Formats that are not general containers.
  ;; ar: flat file names only, no directories. raw: exactly one entry, no name.
  (let ((ar (with-archive-to-octets (w :format :ar-bsd)
              (add-entry w "readme.txt" :data "Read me."))))
    (assert (equal '("readme.txt") (archive-entry-names ar))))
  (let ((raw (with-archive-to-octets (w :format :raw :filters :gzip)
               (add-entry w "ignored" :data "just the bytes"))))
    ;; A gzip'd raw "archive" is simply a .gz file; :raw must be asked for by name.
    (with-archive-reader (r raw :formats '(:raw))
      (next-entry r)
      (assert (string= "just the bytes" (read-entry-string r)))))
  ;; mtree and shar are metadata and shell-script formats: written, not read back here.
  (let ((mtree (with-archive-to-octets (w :format :mtree)
                 (add-entry w "doc/readme.txt" :data "Read me."))))
    (format t "~%mtree manifest:~%~A" (babel:octets-to-string mtree)))

  ;; Every filter, on a tar.
  (format t "~%~16A ~8@A  ~A~%" "filter" "bytes" "detected")
  (dolist (filter '(nil :gzip :bzip2 :xz :lzma :zstd :lz4 :lzip :compress :uuencode :base64))
    (let ((octets (archive-of :format :ustar :filters filter)))
      (if (null octets)
          (format t "~(~16A~) ~8@A~%" (or filter "none") "not available")
          (multiple-value-bind (files format-name filters) (read-back octets)
            (declare (ignore format-name))
            (format t "~(~16A~) ~8D  ~{~A~^ + ~}~%" (or filter "none") (length octets) filters)
            (assert (= (length files) (length *files*)))))))

  ;; Filters stack: the first in the list is applied first, so it ends up
  ;; innermost. ARCHIVE-FILTER-NAMES reports them in the same order.
  (let ((octets (archive-of :format :ustar :filters '(:zstd :base64))))
    (multiple-value-bind (files format-name filters) (read-back octets)
      (declare (ignore format-name))
      (format t "~%Stacked: ~{~A~^ inside ~}, ~D files~%" filters (length files))
      ;; Read back, base64 is detected as libarchive's "uu" decoder.
      (assert (equal filters '("zstd" "uu")))))

  ;; Format and filters from a file name. Which names libarchive knows depends
  ;; on its version: 3.8.9 has no .tar.zst, 3.8.10 does.
  (dolist (name '("x.tar.gz" "x.tgz" "x.tar.xz" "x.zip" "x.7z" "x.cpio" "x.tar.zst"))
    (let ((path (merge-pathnames name (uiop:temporary-directory))))
      (unwind-protect
           (handler-case
               (progn
                 (with-archive-writer (w path :format :by-extension)
                   (add-entry w "a.txt" :data "a"))
                 (with-archive-reader (r path)
                   (next-entry r)
                   (format t "~&~12A -> ~A~@[ + ~{~A~^, ~}~]~%"
                           name (archive-format-name r) (archive-filter-names r))))
             (archive-error (c)
               (format t "~&~12A -> not known to this libarchive (~A)~%"
                       name (archive-condition-message c))))
        (uiop:delete-file-if-exists path))))

  ;; Options: libarchive's "module:option=value" text, or an alist of the same.
  ;; T means the bare option, NIL its negation. Compression levels need data
  ;; worth compressing, so these use a larger, repetitive file.
  (let ((*files* (list (cons "big.txt" (format nil "~{~A~%~}"
                                               (loop for i below 2000
                                                     collect (format nil "line ~D of 2000" i)))))))
    (let ((stored (archive-of :format :zip :options '(("zip:compression" . "store"))))
          (deflated (archive-of :format :zip
                                :options "zip:compression=deflate,zip:compression-level=9"))
          (gz1 (archive-of :format :ustar :filters :gzip
                           :options '(("gzip:compression-level" . 1))))
          (gz9 (archive-of :format :ustar :filters :gzip
                           :options '(("gzip:compression-level" . 9) ("gzip:timestamp" . nil)))))
      (format t "~%zip stored ~D bytes, deflated ~D; gzip -1 ~D bytes, -9 ~D~%"
              (length stored) (length deflated) (length gz1) (length gz9))
      (assert (> (length stored) (length deflated)))
      (assert (> (length gz1) (length gz9)))))

  ;; Blocking. Two small files are 2 x (512 header + 512 data) + a 1024-byte
  ;; trailer = 3072 bytes, which uncompressed tar pads to a whole 10240-byte
  ;; block by default. BYTES-PER-BLOCK changes the block, and
  ;; BYTES-IN-LAST-BLOCK 1 turns the padding off.
  (assert (= 10240 (length (archive-of :format :ustar))))
  (assert (= 4096 (length (archive-of :format :ustar :bytes-per-block 2048))))
  (assert (= 3072 (length (archive-of :format :ustar :bytes-in-last-block 1))))

  ;; Reading with an allow-list: a zip offered to a tar-only reader is refused.
  (let ((zip (archive-of :format :zip)))
    (assert (= 2 (length (read-back zip :formats '(:zip)))))
    (handler-case (progn (read-back zip :formats '(:tar)) (error "should have been refused"))
      (archive-error (c)
        (format t "~%tar-only reader on a zip: ~A~%" (archive-condition-message c)))))
  (let ((tgz (archive-of :format :ustar :filters :gzip)))
    (assert (= 2 (length (read-back tgz :formats '(:tar) :filters '(:gzip)))))
    (handler-case (progn (read-back tgz :formats '(:tar) :filters '(:none))
                         (error "should have been refused"))
      (archive-error (c)
        (format t "uncompressed-only reader on a .tar.gz: ~A~%" (archive-condition-message c))))))

(main)
