;;; Export the generated raw layer, from the generated tables.

(in-package #:libarchive)

(export (mapcar #'cdr *foreign-function-names*))
(export (mapcar #'cdr *constant-names*))

(defun foreign-function-available-p (c-name)
  "True if the loaded libarchive exports C-NAME.

This is how to probe for entry points newer than the library at hand: which
binary is loaded is a run-time fact, so it is checked at run time and not with a
read-time feature."
  (load-libraries)
  (and (cffi:foreign-symbol-pointer c-name) t))
