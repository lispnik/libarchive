;;; The release binaries carry their own libarchive (built by
;;; ci/build-libarchive.sh), so they need none installed. A process can only
;;; dlopen a file, so MAIN writes the library to a private temporary file,
;;; opens it and deletes it again: the mapping outlives the name.

(in-package #:libarchive/cli)

(defun read-file-octets (path)
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let ((octets (make-array (file-length in) :element-type '(unsigned-byte 8))))
      (read-sequence octets in)
      octets)))

(defvar *bundled-libarchive*
  (let ((path (uiop:getenv "LA_BUNDLE_LIBARCHIVE")))
    (and path (plusp (length path)) (read-file-octets path)))
  "The bytes of the libarchive shared library built into this image, or NIL.
Captured from the file named by LA_BUNDLE_LIBARCHIVE when the system loads,
which for a release build is just before the image is dumped.")

(defvar *libarchive-origin* "system"
  "Where the libarchive in use came from, for --version.")

(defun open-bundled-in (directory)
  "Write the bundled library into DIRECTORY, open it and delete the file.
True on success; signals an error otherwise."
  (ensure-directories-exist directory)
  (multiple-value-bind (fd name)
      (sb-posix:mkstemp (concatenate 'string (uiop:native-namestring directory)
                                     "la-libarchive-XXXXXX"))
    (unwind-protect
         (progn
           (with-open-stream (out (sb-sys:make-fd-stream fd :output t :element-type '(unsigned-byte 8)
                                                            :buffering :full))
             (write-sequence *bundled-libarchive* out))
           (let ((*library-pathname* name))
             (load-libraries))
           t)
      (ignore-errors (sb-posix:unlink name)))))

(defun choose-libarchive ()
  "Before the first call into libarchive: the bundled library, unless
LA_LIBARCHIVE says `system' or names a file to use instead."
  (let ((choice (uiop:getenv "LA_LIBARCHIVE")))
    (cond ((equal choice "system"))
          ((and choice (plusp (length choice)))
           (setf *library-pathname* choice
                 *libarchive-origin* choice))
          (*bundled-libarchive*
           (let ((reasons '()))
             ;; The temporary directory first; some mount it noexec, so the
             ;; cache directory too.
             (dolist (directory (list (uiop:temporary-directory) (uiop:xdg-cache-home "la/"))
                             (warn-user "cannot use the bundled libarchive (~{~A~^; ~}); ~
                                         looking for an installed one" (nreverse reasons)))
               (handler-case (when (open-bundled-in directory)
                               (setf *libarchive-origin* "bundled")
                               (return))
                 (error (c) (push (princ-to-string c) reasons)))))))))
