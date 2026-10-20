;;; Scoped acquisition, iteration and one-call conveniences.

(in-package #:libarchive)

(defmacro with-archive-reader ((var source &rest keys) &body body)
  "Bind VAR to (OPEN-ARCHIVE-READER SOURCE . KEYS) for BODY, then close it."
  `(let ((,var (open-archive-reader ,source ,@keys)))
     (unwind-protect (progn ,@body)
       (close-archive ,var))))

(defmacro with-archive-writer ((var target &rest keys) &body body)
  "Bind VAR to (OPEN-ARCHIVE-WRITER TARGET . KEYS) for BODY. On normal exit the
writer is closed, which writes the trailer; on a non-local exit it is aborted."
  (let ((ok (gensym "OK")))
    `(let ((,var (open-archive-writer ,target ,@keys))
           (,ok nil))
       (unwind-protect (multiple-value-prog1 (progn ,@body) (setf ,ok t))
         (close-archive ,var :abort (not ,ok))))))

(defmacro with-archive-to-octets ((var &rest keys) &body body)
  "Write an archive in memory with VAR bound to the writer; return its octets."
  (let ((writer (gensym "WRITER")))
    `(let ((,writer nil))
       (with-archive-writer (,var :octets ,@keys)
         (setf ,writer ,var)
         ,@body)
       (writer-octets ,writer))))

(defmacro do-archive-entries ((entry reader &optional result) &body body)
  "Run BODY with ENTRY bound to each entry of READER in turn. Each entry is
valid only during its iteration."
  (let ((r (gensym "READER")))
    `(let ((,r ,reader))
       (loop for ,entry = (next-entry ,r)
             while ,entry
             do (progn ,@body)
             finally (return ,result)))))

(defmacro with-entry ((var &rest initargs) &body body)
  "Bind VAR to (MAKE-ENTRY . INITARGS) for BODY, then free it."
  `(let ((,var (make-entry ,@initargs)))
     (unwind-protect (progn ,@body)
       (free-entry ,var))))

(defun archive-entry-names (source &rest reader-keys)
  "The entry names in SOURCE, in archive order."
  (let ((r (apply #'open-archive-reader source reader-keys))
        (names '()))
    (unwind-protect
         (do-archive-entries (e r (nreverse names))
           (push (entry-pathname e) names))
      (close-archive r))))
