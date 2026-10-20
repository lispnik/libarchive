;;; The condition hierarchy.
;;;
;;; libarchive's return codes become conditions as follows:
;;;
;;;   ARCHIVE_OK, ARCHIVE_EOF   no condition
;;;   ARCHIVE_WARN              ARCHIVE-WARNING, signalled with WARN; the
;;;                             operation succeeded
;;;   ARCHIVE_RETRY             ARCHIVE-RETRY; the operation may succeed if
;;;                             tried again
;;;   ARCHIVE_FAILED            ARCHIVE-ERROR; this operation failed, but the
;;;                             archive can still be used (e.g. go on to the
;;;                             next entry)
;;;   ARCHIVE_FATAL             ARCHIVE-FATAL-ERROR; the archive cannot be used
;;;                             again, only closed
;;;
;;; These live in the raw system so both layers share one root, and so a raw
;;; caller can signal them too.

(in-package #:libarchive)

(define-condition archive-condition (condition)
  ((code      :initarg :code      :initform nil :reader archive-condition-code)
   (errno     :initarg :errno     :initform nil :reader archive-condition-errno)
   (message   :initarg :message   :initform nil :reader archive-condition-message)
   (operation :initarg :operation :initform nil :reader archive-condition-operation))
  (:report (lambda (c s)
             (format s "libarchive~@[ ~A~]: ~A~@[ (errno ~D)~]"
                     (archive-condition-operation c)
                     (or (archive-condition-message c)
                         (format nil "return code ~A" (archive-condition-code c)))
                     (let ((e (archive-condition-errno c)))
                       (and e (plusp e) e))))))

(define-condition archive-error (archive-condition error) ()
  (:documentation "An operation failed (ARCHIVE_FAILED); the archive is still usable."))

(define-condition archive-fatal-error (archive-error) ()
  (:documentation "ARCHIVE_FATAL: the archive can only be closed now."))

(define-condition archive-retry (archive-error) ()
  (:documentation "ARCHIVE_RETRY: the operation may succeed if repeated."))

(define-condition archive-warning (archive-condition warning) ()
  (:documentation "ARCHIVE_WARN: the operation succeeded, but with a diagnostic."))

(define-condition unsupported-function (error)
  ((name :initarg :name :reader unsupported-function-name))
  (:report (lambda (c s)
             (format s "The loaded libarchive does not export ~A."
                     (unsupported-function-name c)))))
