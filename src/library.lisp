;;; Finding and opening libarchive.
;;;
;;; Loaded lazily, at run time, never at load time:
;;;
;;;   - A dumped image must not carry a foreign library handle from the machine
;;;     that dumped it. Every ergonomic entry point that can be the first one
;;;     called goes through LOAD-LIBRARIES, so a restored image opens whatever
;;;     the new machine has.
;;;   - CFFI resolves a DEFCFUN when it is first called, not when it is defined,
;;;     so libarchive/ffi compiles and loads on a machine with no libarchive at
;;;     all.

(in-package #:libarchive)

(defvar *library-directories*
  (list #+darwin #p"/opt/homebrew/opt/libarchive/lib/"
        #+darwin #p"/usr/local/opt/libarchive/lib/"
        #+darwin #p"/opt/homebrew/lib/"
        #p"/usr/local/lib/"
        #-darwin #p"/usr/lib/")
  "Extra directories searched for the libarchive shared library.

Homebrew's libarchive is keg-only: it is never linked into /opt/homebrew/lib,
because macOS ships an older libarchive of its own. The keg directories come
first so that the Homebrew build wins over the system one.")

(cffi:define-foreign-library libarchive
  ;; Soname first: the bare libarchive.so is in the -dev package, so a machine
  ;; with only the runtime installed has libarchive.so.13 and nothing else.
  ;; libarchive.2.dylib is the copy macOS ships in the dyld shared cache. It is
  ;; old and last, a fallback rather than the target.
  (:darwin (:or "libarchive.13.dylib" "libarchive.dylib" "libarchive.2.dylib"))
  (:unix   (:or "libarchive.so.13" "libarchive.so"))
  (:windows (:or "archive.dll" "libarchive.dll"))
  (t (:default "libarchive")))

(defvar *libraries-loaded* nil)

(defun load-libraries ()
  "Open libarchive if it is not already open. Idempotent; returns T."
  (unless *libraries-loaded*
    (let ((cffi:*foreign-library-directories*
            (append *library-directories* cffi:*foreign-library-directories*)))
      (cffi:load-foreign-library 'libarchive))
    (setf *libraries-loaded* t))
  t)

;;; A restored image must not trust the flag it was dumped with.
#+sbcl
(pushnew (lambda () (setf *libraries-loaded* nil)) sb-ext:*init-hooks*)
