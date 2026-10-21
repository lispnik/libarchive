;;; One package for both layers.
;;;
;;; The raw layer's exports are not listed here: there are some 450 functions
;;; and 170 constants, all generated, and listing them by hand would be a second
;;; copy of the headers to keep in sync. raw-exports.lisp exports them from the
;;; generated name tables instead. The ergonomic layer declares its own exports
;;; in api-package.lisp, so each system advertises only what it provides.

(defpackage #:libarchive
  (:use #:cl)
  (:export
   ;; library.lisp
   #:*library-directories* #:*library-pathname* #:load-libraries #:*ensure-utf-8-locale*
   ;; types.lisp
   #:archive #:archive-entry #:mode-t #:dev-t #:time-t
   ;; conditions.lisp
   #:archive-condition #:archive-condition-code #:archive-condition-errno
   #:archive-condition-message #:archive-condition-operation
   #:archive-error #:archive-fatal-error #:archive-retry #:archive-warning
   #:unsupported-function #:unsupported-function-name
   ;; raw-exports.lisp
   #:*foreign-function-names* #:*constant-names*
   #:foreign-function-available-p))
