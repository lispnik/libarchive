;;; Threads: one handle per thread, as many threads as you like.
;;;
;;;   make example NAME=threads
;;;
;;; A handle (reader or writer) must not be shared between threads, but separate
;;; handles in separate threads are independent -- including their callbacks,
;;; which find their own handle through the client-data registry. Here eight
;;; threads each build and verify an archive in a different format at once.

(defpackage #:libarchive-examples/threads
  (:use #:cl #:libarchive))

(in-package #:libarchive-examples/threads)

(defparameter *jobs*
  '((:ustar :gzip) (:pax :xz) (:zip nil) (:7zip nil)
    (:cpio-newc :bzip2) (:gnutar :zstd) (:pax-restricted :lz4) (:zip nil)))

(defun job (format filter seed)
  "Write SEED's files as FORMAT + FILTER, read them back, return a summary."
  (let* ((files (loop for i below 20
                      collect (cons (format nil "thread-~D/file-~2,'0D.txt" seed i)
                                    (format nil "~D:~D ~A" seed i
                                            (make-string (* 100 i) :initial-element #\x)))))
         (archive (with-archive-to-octets (w :format format :filters filter)
                    (loop for (name . text) in files do (add-entry w name :data text))))
         (read (with-archive-reader (r archive)
                 (loop for e = (next-entry r)
                       while e
                       collect (cons (entry-pathname e) (read-entry-string r))))))
    (assert (equal (sort (copy-list files) #'string< :key #'car)
                   (sort read #'string< :key #'car)))
    (format nil "~(~A~@[+~A~]~): ~D entries, ~D bytes" format filter (length read) (length archive))))

(defun main ()
  (let* ((threads (loop for (format filter) in *jobs*
                        for seed from 0
                        collect (let ((format format) (filter filter) (seed seed))
                                  (bt:make-thread (lambda () (job format filter seed))
                                                  :name (format nil "archiver ~D" seed)))))
         (results (mapcar #'bt:join-thread threads)))
    (format t "~{~A~%~}" results)
    (assert (= (length results) (length *jobs*)))))

(main)
