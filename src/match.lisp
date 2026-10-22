;;; Choosing entries: libarchive's archive_match, by name, time and owner.
;;;
;;; An ARCHIVE-MATCH is a handle like the readers and writers (it is a struct
;;; archive * in libarchive too), closed with CLOSE-ARCHIVE. EXTRACT-ARCHIVE and
;;; ARCHIVE-DIRECTORY take one as :MATCH; anything else can ask
;;; ENTRY-MATCHES-P of each entry it reads.

(in-package #:libarchive)

(defclass archive-match (archive-handle) ())

(defmethod close-foreign ((h archive-match) p abort)
  (declare (ignore p abort))
  +archive-ok+)

(defmethod free-foreign ((h archive-match) p)
  (%archive-match-free p))

(defparameter *match-times*
  `((:mtime . ,+archive-match-mtime+) (:ctime . ,+archive-match-ctime+)))

(defun add-time-limit (match direction limit time)
  "Include only entries whose TIME (:mtime or :ctime) is DIRECTION (:newer or
:older) than LIMIT: a universal time, a date string libarchive parses
(\"2024-06-01\", \"2024-06-01 12:00 UTC\", \"3 days ago\"), or a pathname,
whose file's own time is the limit."
  (let ((flag (logior (or (cdr (assoc time *match-times*))
                          (error "Unknown match time ~S; expected :MTIME or :CTIME." time))
                      (ecase direction
                        (:newer +archive-match-newer+)
                        (:older +archive-match-older+)))))
    (etypecase limit
      (integer
       (checked match (%archive-match-include-time flag (universal->unix limit) 0)))
      (pathname
       (checked match (%archive-match-include-file-time flag (uiop:native-namestring limit))))
      (string
       (checked match (%archive-match-include-date flag limit))))))

(defun make-archive-match (&key include exclude newer older (time :mtime)
                                uids gids unames gnames (recursive t))
  "A matcher for ENTRY-MATCHES-P, and EXTRACT-ARCHIVE's and ARCHIVE-DIRECTORY's
:MATCH. Close it with CLOSE-ARCHIVE, or use WITH-ARCHIVE-MATCH.

INCLUDE and EXCLUDE are lists of glob patterns (*, ?, [...]) on entry names. An
entry is chosen if it matches some INCLUDE pattern, or there are none, and no
EXCLUDE pattern. An INCLUDE pattern takes everything under a directory it
names unless RECURSIVE is NIL; an EXCLUDE pattern matches at any directory
boundary (\"*.o\" and \"build\" exclude a/build/x.o).

NEWER and OLDER limit entries by TIME, :MTIME or :CTIME, strictly: each is a
universal time, a pathname (that file's time), or a date string libarchive
parses, e.g. \"2024-06-01\" or \"2 weeks ago\".

UIDS, GIDS, UNAMES and GNAMES, if given, include only entries owned by one of
them."
  (load-libraries)
  (let ((h (make-handle 'archive-match (%archive-match-new))))
    (call-with-cleanup-on-error
     h
     (lambda ()
       (checked h (%archive-match-set-inclusion-recursion (if recursive 1 0)))
       (dolist (p (uiop:ensure-list include))
         (checked h (%archive-match-include-pattern p)))
       (dolist (p (uiop:ensure-list exclude))
         (checked h (%archive-match-exclude-pattern p)))
       (when newer (add-time-limit h :newer newer time))
       (when older (add-time-limit h :older older time))
       (dolist (id (uiop:ensure-list uids)) (checked h (%archive-match-include-uid id)))
       (dolist (id (uiop:ensure-list gids)) (checked h (%archive-match-include-gid id)))
       (dolist (n (uiop:ensure-list unames)) (checked h (%archive-match-include-uname n)))
       (dolist (n (uiop:ensure-list gnames)) (checked h (%archive-match-include-gname n)))
       h))))

(defmacro with-archive-match ((var &rest keys) &body body)
  "Bind VAR to (MAKE-ARCHIVE-MATCH . KEYS) for BODY, then close it."
  `(let ((,var (make-archive-match ,@keys)))
     (unwind-protect (progn ,@body)
       (close-archive ,var))))

(defun entry-matches-p (match entry)
  "True if MATCH chooses ENTRY: by its name, times and owner. A name that
matches an INCLUDE pattern counts towards ARCHIVE-MATCH-UNMATCHED."
  (zerop (checked match (%archive-match-excluded (entry-pointer entry)))))

(defun path-excluded-p (match entry)
  "True if MATCH's patterns alone leave ENTRY out."
  (plusp (checked match (%archive-match-path-excluded (entry-pointer entry)))))

(defun archive-match-unmatched (match)
  "The INCLUDE patterns no entry has matched so far."
  (cffi:with-foreign-object (p :pointer)
    (loop while (= +archive-ok+
                   (checked match (%archive-match-path-unmatched-inclusions-next p)))
          collect (cffi:foreign-string-to-lisp (cffi:mem-ref p :pointer) :encoding :utf-8))))
