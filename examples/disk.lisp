;;; Disk: archive a directory tree, and extract an archive into one -- safely.
;;;
;;;   make example NAME=disk
;;;
;;; ARCHIVE-DIRECTORY walks a tree the way bsdtar -c does (modes, times, owners,
;;; symlinks, extended attributes); EXTRACT-ARCHIVE recreates one the way bsdtar -x
;;; does, refusing entries that would escape the target directory.

(defpackage #:libarchive-examples/disk
  (:use #:cl #:libarchive))

(in-package #:libarchive-examples/disk)

(defmacro with-scratch-directory ((var) &body body)
  `(let ((,var (uiop:ensure-directory-pathname
                (format nil "~Alibarchive-example-~36R/"
                        (uiop:native-namestring (uiop:temporary-directory))
                        (random (expt 36 8) (make-random-state t))))))
     (ensure-directories-exist ,var)
     (unwind-protect (progn ,@body)
       (uiop:delete-directory-tree ,var :validate t :if-does-not-exist :ignore))))

(defun write-file (path text)
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :if-exists :supersede)
    (write-string text out)))

(defun make-project (root)
  (write-file (merge-pathnames "README.md" root) "# Project
")
  (write-file (merge-pathnames "src/main.lisp" root) "(print :hello)
")
  (write-file (merge-pathnames "src/util.lisp" root) "(defun id (x) x)
")
  (write-file (merge-pathnames "build/main.fasl" root) "not really a fasl")
  (write-file (merge-pathnames ".git/HEAD" root) "ref: refs/heads/main
")
  (uiop:run-program (list "ln" "-s" "src/main.lisp"
                          (uiop:native-namestring (merge-pathnames "entry-point" root))))
  root)

(defun main ()
  (with-scratch-directory (dir)
    (let* ((project (make-project (merge-pathnames "project/" dir)))
           (archive (merge-pathnames "project.tar.gz" dir)))

      ;; Archive the tree. Names are relative to the directory given. The filter
      ;; sees each entry with its absolute name, and returning NIL for a directory
      ;; prunes everything beneath it. :NO-XATTR leaves out extended attributes
      ;; (macOS tags downloaded and copied files with some).
      (let ((count (archive-directory project archive
                                      :format :pax-restricted :filters :gzip
                                      :read-disk-flags '(:no-xattr)
                                      :filter (lambda (e)
                                                (let ((name (entry-pathname e)))
                                                  (not (or (search "/.git" name)
                                                           (search "/build" name))))))))
        (format t "Archived ~D entries:~%" count))
      (let ((names (sort (archive-entry-names archive) #'string<)))
        (format t "~{  ~A~%~}" names)
        (assert (equal names '("README.md" "entry-point" "src/" "src/main.lisp" "src/util.lisp"))))

      ;; Several trees into one archive: give ARCHIVE-DIRECTORY an open writer,
      ;; and add entries of your own alongside.
      (let ((combined (with-archive-to-octets (w :format :zip)
                        (archive-directory (merge-pathnames "src/" project) w)
                        (add-entry w "VERSION" :data "1.0"))))
        (format t "~&Combined zip: ~S~%" (archive-entry-names combined)))

      ;; Extract. The default flags restore permissions and times and refuse to
      ;; write through symlinks or above the target; PROGRESS is called with the
      ;; compressed bytes consumed so far.
      (format t "~&Default extract flags: ~S~%" *default-extract-flags*)
      (let* ((out (merge-pathnames "restored/" dir))
             (calls 0)
             (names (extract-archive archive out
                                     :progress (lambda (bytes) (declare (ignore bytes)) (incf calls)))))
        (format t "Extracted ~D entries; progress called ~D times~%" (length names) calls)
        (assert (string= "(print :hello)
" (uiop:read-file-string (merge-pathnames "src/main.lisp" out))))
        ;; The symlink is a symlink again.
        (assert (equal (truename (merge-pathnames "entry-point" out))
                       (truename (merge-pathnames "src/main.lisp" out)))))

      ;; Extract only some entries, with other flags. Every flag name is in
      ;; *EXTRACT-FLAGS*. :NO-OVERWRITE leaves existing files alone -- silently:
      ;; libarchive reports success for the entry it skipped, so check the disk
      ;; first if you need to know.
      (let ((out (merge-pathnames "sources-only/" dir)))
        (write-file (merge-pathnames "src/main.lisp" out) "keep me")
        (extract-archive archive out
                         :flags '(:no-overwrite :secure-symlinks :secure-nodotdot)
                         :filter (lambda (e) (search ".lisp" (entry-pathname e))))
        (assert (string= "keep me" (uiop:read-file-string (merge-pathnames "src/main.lisp" out))))
        (assert (probe-file (merge-pathnames "src/util.lisp" out)))
        (assert (not (probe-file (merge-pathnames "README.md" out)))))
      (format t "Extract flags available: ~{~(~A~)~^ ~}~%" (mapcar #'car *extract-flags*))

      ;; A hostile archive: absolute paths and .. components are refused, always.
      ;; Each refusal is an ARCHIVE-ERROR with a SKIP-ENTRY restart, so a
      ;; handler decides whether to carry on.
      (let ((evil (with-archive-to-octets (w :format :ustar)
                    (add-entry w "fine.txt" :data "ok")
                    (add-entry w "../../escaped.txt" :data "gotcha")
                    (add-entry w "/etc/not-yours" :data "gotcha")))
            (out (merge-pathnames "untrusted/" dir)))
        (let ((names (handler-bind ((archive-error
                                      (lambda (c)
                                        (format t "~&  refused: ~A~%" (archive-condition-message c))
                                        (invoke-restart 'skip-entry))))
                       (extract-archive evil out))))
          (assert (equal names '("fine.txt")))
          (assert (not (probe-file (merge-pathnames "escaped.txt" dir)))))
        ;; Without a handler the first refusal is an error, and extraction stops.
        (handler-case (extract-archive evil (merge-pathnames "untrusted-2/" dir))
          (archive-error (c) (format t "Without a handler: ~A~%" c)))))))

(main)
