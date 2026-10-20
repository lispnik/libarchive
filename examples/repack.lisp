;;; Repack: convert an archive from one format to another, entry by entry, in a
;;; single pass with nothing extracted to disk. Here a zip becomes a .tar.zst.
;;;
;;;   make example NAME=repack
;;;
;;; This is what `bsdtar -cf out.tar.zst @in.zip` does: a borrowed entry from the
;;; reader goes straight to WRITE-ENTRY, so every piece of metadata the two formats
;;; share (names, modes, times, owners, links) carries over.

(defpackage #:libarchive-examples/repack
  (:use #:cl #:libarchive))

(in-package #:libarchive-examples/repack)

(defun copy-entries (reader writer &key (rename #'identity) (keep (constantly t)))
  "Copy every entry of READER for which KEEP returns true to WRITER, renaming
each with RENAME. Returns the number of entries copied."
  (let ((copied 0))
    (do-archive-entries (e reader copied)
      (when (funcall keep e)
        (setf (entry-pathname e) (funcall rename (entry-pathname e)))
        ;; Zip often records no size up front; WRITE-ENTRY sets it from the
        ;; data, as tar needs. Directories and links have no data.
        (write-entry writer e (if (eq (entry-type e) :regular) (read-entry-data reader) nil))
        (incf copied)))))

(defun repack (source target &rest writer-keys)
  "Repack the archive SOURCE as a new archive at TARGET, written with WRITER-KEYS."
  (with-archive-reader (in source)
    ;; As WITH-ARCHIVE-WRITER would, abort the output if copying fails
    ;; part-way, so that a half-written archive never gets a trailer.
    (let ((out (apply #'open-archive-writer target writer-keys))
          (ok nil))
      (unwind-protect
           (multiple-value-prog1 (copy-entries in out) (setf ok t))
        (close-archive out :abort (not ok))))))

(defun main ()
  (let* ((zip (with-archive-to-octets (w :format :zip)
                (add-entry w "site/" :mtime (encode-universal-time 0 0 0 1 1 2025 0))
                (add-entry w "site/index.html" :data "<h1>Hello</h1>" :perm #o644)
                (add-entry w "site/build.sh" :data "#!/bin/sh
echo hi
" :perm #o755)
                (add-entry w "site/.DS_Store" :data "junk")
                (add-entry w "site/current" :symlink "index.html")))
         ;; The whole archive, as is, to a file:
         (path (merge-pathnames "site.tar.zst" (uiop:temporary-directory)))
         ;; Or chosen entries, renamed, into a writer you already have:
         (tar (with-archive-to-octets (w :format :pax-restricted :filters :zstd)
                (with-archive-reader (r zip)
                  (format t "Copied ~D entries~%"
                          (copy-entries r w
                                        :keep (lambda (e)
                                                (not (search ".DS_Store" (entry-pathname e))))
                                        :rename (lambda (name)
                                                  (concatenate 'string "www/" name))))))))
    (unwind-protect
         (progn
           (format t "Repacked ~D entries to ~A~%"
                   (repack zip path :format :pax-restricted :filters :zstd) (file-namestring path))
           (assert (= 5 (length (archive-entry-names path)))))
      (uiop:delete-file-if-exists path))
    (with-archive-reader (r tar)
      (do-archive-entries (e r)
        (format t "  ~A ~A~@[ -> ~A~]~%" (entry-strmode e) (entry-pathname e) (entry-symlink e)))
      (assert (equal (archive-filter-names r) '("zstd"))))
    (assert (equal (archive-entry-names tar)
                   '("www/site/" "www/site/index.html" "www/site/build.sh" "www/site/current")))
    ;; The executable bit survived the trip.
    (with-archive-reader (r tar)
      (do-archive-entries (e r)
        (when (search "build.sh" (entry-pathname e))
          (assert (= #o755 (entry-perm e))))))))

(main)
