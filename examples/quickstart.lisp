;;; Quickstart: write a .tar.gz, list it, read it back, extract it.
;;;
;;; Every example in this directory runs the same way, from the project root:
;;;
;;;   make examples                     # all of them
;;;   make example NAME=quickstart      # just this one
;;;
;;; or at a REPL where the libarchive system is loaded: (load "examples/quickstart.lisp").
;;; Each one works in a scratch directory it deletes afterwards, and checks what it
;;; prints with ASSERT, so a broken binding fails loudly instead of printing nonsense.

(defpackage #:libarchive-examples/quickstart
  (:use #:cl #:libarchive))

(in-package #:libarchive-examples/quickstart)

(defmacro with-scratch-directory ((var) &body body)
  `(let ((,var (uiop:ensure-directory-pathname
                (format nil "~Alibarchive-example-~36R/"
                        (uiop:native-namestring (uiop:temporary-directory))
                        (random (expt 36 8) (make-random-state t))))))
     (ensure-directories-exist ,var)
     (unwind-protect (progn ,@body)
       (uiop:delete-directory-tree ,var :validate t :if-does-not-exist :ignore))))

(defun main ()
  (format t "~A~%~%" (version-string))
  (with-scratch-directory (dir)
    (let ((archive (merge-pathnames "hello.tar.gz" dir)))
      ;; Write. The writer is closed on normal exit, which writes the trailer.
      (with-archive-writer (w archive :format :pax-restricted :filters :gzip)
        (add-entry w "hello/")
        (add-entry w "hello/greeting.txt" :data "Hello, world!
")
        (add-entry w "hello/numbers.bin"
                   :data (coerce (loop for i below 256 collect i) '(vector (unsigned-byte 8)))
                   :perm #o600)
        (add-entry w "hello/latest" :symlink "greeting.txt"))

      ;; List: names only.
      (let ((names (archive-entry-names archive)))
        (format t "Entries: ~{~A~^, ~}~%" names)
        (assert (equal names '("hello/" "hello/greeting.txt" "hello/numbers.bin" "hello/latest"))))

      ;; Read: format and compression are detected; entries come with their data.
      (with-archive-reader (r archive)
        (do-archive-entries (e r)
          (format t "  ~A ~8D  ~A~@[ -> ~A~]~%"
                  (entry-strmode e) (or (entry-size e) 0) (entry-pathname e) (entry-symlink e))
          (when (string= (entry-pathname e) "hello/greeting.txt")
            (assert (string= (read-entry-string r) "Hello, world!
"))))
        (format t "Format: ~A; filters: ~{~A~^, ~}~%"
                (archive-format-name r) (archive-filter-names r))
        (assert (equal (archive-filter-names r) '("gzip"))))

      ;; Extract, and look at what landed on disk.
      (let* ((out (merge-pathnames "out/" dir))
             (extracted (extract-archive archive out)))
        (format t "Extracted ~D entries into ~A~%" (length extracted) out)
        (assert (= 4 (length extracted)))
        (assert (string= (uiop:read-file-string (merge-pathnames "hello/greeting.txt" out))
                         "Hello, world!
"))))))

(main)
