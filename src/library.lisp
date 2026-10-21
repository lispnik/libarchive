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

(defvar *library-pathname* nil
  "If non-NIL, the libarchive shared library file to open, instead of searching
for one. Set it before the first call into libarchive.")

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defparameter *default-library-spec*
    ;; Soname first: the bare libarchive.so is in the -dev package, so a machine
    ;; with only the runtime installed has libarchive.so.13 and nothing else.
    ;; libarchive.2.dylib is the copy macOS ships in the dyld shared cache. It is
    ;; old and last, a fallback rather than the target.
    '((:darwin (:or "libarchive.13.dylib" "libarchive.dylib" "libarchive.2.dylib"))
      (:unix   (:or "libarchive.so.13" "libarchive.so"))
      (:windows (:or "archive.dll" "libarchive.dll"))
      (t (:default "libarchive")))))

(defun define-libarchive ()
  "(Re)define the LIBARCHIVE foreign library from *LIBRARY-PATHNAME*. Defined,
not loaded as an anonymous library, because every DEFCFUN names LIBARCHIVE."
  (eval `(cffi:define-foreign-library libarchive
           ,@(if *library-pathname*
                 `((t ,(uiop:native-namestring *library-pathname*)))
                 *default-library-spec*))))

(macrolet ((define () `(cffi:define-foreign-library libarchive ,@*default-library-spec*)))
  (define))

;;; The C locale.
;;;
;;; libarchive converts every name between the archive's charset and the
;;; *process locale's* multibyte encoding, and SBCL never calls setlocale, so a
;;; Lisp process runs in the "C" locale, where nothing outside ASCII converts.
;;; Under it a name like "café" is broken in every writer: pax dereferences the
;;; failed conversion's NULL and takes the process down, ustar and gnutar
;;; silently write an empty name, 7-Zip writes a damaged archive, cpio refuses
;;; the entry, and extraction cannot create the file. bsdtar avoids all of this
;;; by calling setlocale(LC_ALL, "") first thing; this does the same for
;;; LC_CTYPE alone, which is the only category libarchive's conversions use.

(defvar *ensure-utf-8-locale* t
  "If true (the default), LOAD-LIBRARIES makes sure the process's LC_CTYPE has a
UTF-8 codeset, switching it if need be: first to the environment's own locale
(LC_ALL, LC_CTYPE, LANG), then to C.UTF-8 or en_US.UTF-8. libarchive cannot
handle non-ASCII names otherwise. Only LC_CTYPE is changed, and SBCL's own
streams do not depend on it. Bind or set this to NIL before the first call
into libarchive to leave the locale alone.")

(defconstant +lc-ctype+ #+linux 0 #-linux 2
  "LC_CTYPE: 0 in glibc and musl, 2 in macOS and the BSDs.")

(defun utf-8-locale-name-p (name)
  (and name
       (or (search "UTF-8" name :test #'char-equal)
           (search "UTF8" name :test #'char-equal))
       t))

(defun setlocale-ctype (name)
  "setlocale(LC_CTYPE, NAME), NAME NIL to query; the resulting locale name or NIL."
  (if name
      (cffi:foreign-funcall "setlocale" :int +lc-ctype+ :string name :string)
      (cffi:foreign-funcall "setlocale" :int +lc-ctype+ :pointer (cffi:null-pointer) :string)))

(defun ensure-utf-8-locale ()
  "Give LC_CTYPE a UTF-8 codeset if it lacks one; return the locale name in effect."
  (let ((current (setlocale-ctype nil)))
    (if (utf-8-locale-name-p current)
        current
        (or (loop for candidate in '("" "C.UTF-8" "en_US.UTF-8" "UTF-8")
                  for set = (setlocale-ctype candidate)
                  when (utf-8-locale-name-p set)
                    return set)
            (progn
              (setlocale-ctype current)
              (warn "No UTF-8 locale is available, so libarchive will mangle or ~
                     refuse names outside ASCII. LC_CTYPE is ~S." current)
              current)))))

(defvar *libraries-loaded* nil)

;;; Several threads may make their first libarchive call at the same moment, and
;;; loading is not something to do twice at once: two concurrent dlopens and
;;; setlocales crashed in archive_write_new. The flag is checked again under the
;;; lock, so once loaded the common path takes no lock at all.
(defvar *load-lock* (bt:make-lock "libarchive load-libraries"))

(defun load-libraries ()
  "Open libarchive if it is not already open, and see *ENSURE-UTF-8-LOCALE*.
Idempotent and thread-safe; returns T."
  (unless *libraries-loaded*
    (bt:with-lock-held (*load-lock*)
      (unless *libraries-loaded*
        (define-libarchive)
        (let ((cffi:*foreign-library-directories*
                (append *library-directories* cffi:*foreign-library-directories*)))
          (cffi:load-foreign-library 'libarchive))
        (when *ensure-utf-8-locale*
          (ensure-utf-8-locale))
        (setf *libraries-loaded* t))))
  t)

;;; A restored image must not trust the flag it was dumped with.
;;; ASDF's program-op restores through UIOP's hooks on every implementation;
;;; SBCL's own hook also covers a plain SAVE-LISP-AND-DIE.
(defun forget-loaded-libraries () (setf *libraries-loaded* nil))
(uiop:register-image-restore-hook 'forget-loaded-libraries nil)
#+sbcl (pushnew 'forget-loaded-libraries sb-ext:*init-hooks*)
