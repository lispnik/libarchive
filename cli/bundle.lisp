;;; The release binaries carry their own libarchive (built by
;;; ci/build-libarchive.sh), so they need none installed. A process can only
;;; dlopen a file, so MAIN writes the library out once, to the user's cache
;;; directory, and opens it from there; it is checked against the copy in the
;;; image every time. A fixed path matters on macOS, which vets every library
;;; file it has not seen before: about 120 ms a run with a fresh temporary file.
;;; If the cache will not do, a private temporary file is used and deleted
;;; again at once (the mapping outlives the name).

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

(defun fnv-1a (octets)
  "A 32-bit FNV-1a hash of OCTETS, to tell one bundled library from another."
  (let ((h 2166136261))
    (declare (type (unsigned-byte 32) h))
    (loop for b across octets
          do (setf h (ldb (byte 32 0) (* (logxor h b) 16777619))))
    h))

(defvar *bundled-libarchive-id*
  (and *bundled-libarchive* (format nil "~8,'0X" (fnv-1a *bundled-libarchive*))))

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

(defun file-holds-p (path octets)
  "True if the file PATH holds exactly OCTETS."
  (with-open-file (in path :element-type '(unsigned-byte 8) :if-does-not-exist nil)
    (and in
         (= (file-length in) (length octets))
         (let ((buffer (make-array (length octets) :element-type '(unsigned-byte 8))))
           (and (= (read-sequence buffer in) (length octets))
                (not (mismatch buffer octets)))))))

(defun open-cached ()
  "Open the bundled library from the cache directory, writing it there first
if it is missing or not the same. True on success; signals an error otherwise."
  (let* ((directory (uiop:xdg-cache-home "la/"))
         (path (merge-pathnames (format nil "libarchive-~A.~A" *bundled-libarchive-id*
                                        #+darwin "dylib" #-darwin "so")
                                directory)))
    (unless (file-holds-p path *bundled-libarchive*)
      (ensure-directories-exist directory)
      ;; Written aside and renamed into place, so that a concurrent la never
      ;; opens a half-written file.
      (multiple-value-bind (fd name)
          (sb-posix:mkstemp (concatenate 'string (uiop:native-namestring directory) ".libarchive-XXXXXX"))
        (handler-bind ((error (lambda (c) (declare (ignore c)) (ignore-errors (sb-posix:unlink name)))))
          (with-open-stream (out (sb-sys:make-fd-stream fd :output t :element-type '(unsigned-byte 8)
                                                           :buffering :full))
            (write-sequence *bundled-libarchive* out))
          (sb-posix:rename name (uiop:native-namestring path)))
        ;; Copies from other versions of la are not needed any more.
        (dolist (old (directory (merge-pathnames "libarchive-*.*" directory)))
          (unless (equal (file-namestring old) (file-namestring path))
            (ignore-errors (delete-file old))))))
    (let ((*library-pathname* (uiop:native-namestring path)))
      (load-libraries))
    t))

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
             (dolist (try (list #'open-cached
                                (lambda () (open-bundled-in (uiop:temporary-directory))))
                          (warn-user "cannot use the bundled libarchive (~{~A~^; ~}); ~
                                      looking for an installed one" (nreverse reasons)))
               (handler-case (when (funcall try)
                               (setf *libarchive-origin* "bundled")
                               (return))
                 (error (c) (push (princ-to-string c) reasons)))))))))
