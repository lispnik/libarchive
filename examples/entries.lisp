;;; Entries: building them by hand, every accessor, and the borrowed/owned lifetimes.
;;;
;;;   make example NAME=entries
;;;
;;; ADD-ENTRY is the shortcut; this is the long way round, for when an entry's
;;; metadata matters: owners, times, links, special files, extended attributes.

(defpackage #:libarchive-examples/entries
  (:use #:cl #:libarchive))

(in-package #:libarchive-examples/entries)

(defparameter *when* (encode-universal-time 0 30 12 1 6 2024 0)
  "A fixed time, so the output is the same on every run.")

(defun describe-entry (e)
  (format t "  ~A ~A~%" (entry-strmode e) (entry-pathname e))
  (format t "      type ~(~A~), perm ~3,'0O, mode ~6,'0O, size ~A, nlink ~D~%"
          (entry-type e) (entry-perm e) (entry-mode e) (entry-size e) (entry-nlink e))
  (format t "      owner ~A/~A (~D/~D)~%"
          (entry-uname e) (entry-gname e) (entry-uid e) (entry-gid e))
  (format t "      mtime ~A (+~Dns), atime ~A, ctime ~A, birthtime ~A~%"
          (entry-mtime e) (entry-mtime-nsec e) (entry-atime e) (entry-ctime e)
          (entry-birthtime e))
  (when (entry-symlink e) (format t "      symlink -> ~A~%" (entry-symlink e)))
  (when (entry-hardlink e) (format t "      hardlink to ~A~%" (entry-hardlink e)))
  (when (entry-fflags-text e) (format t "      fflags ~A~%" (entry-fflags-text e)))
  (loop for (name . value) in (entry-xattrs e)
        do (format t "      xattr ~A = ~S~%" name (babel:octets-to-string value))))

(defun build-archive ()
  (with-archive-to-octets (w :format :pax)
    ;; MAKE-ENTRY takes the common fields as keywords; WITH-ENTRY frees the entry.
    (with-entry (e :pathname "project/" :mtime *when* :uname "alice" :gname "staff"
                   :uid 501 :gid 20)
      (write-entry w e))

    ;; Every field is also SETF-able. Strings are UTF-8 whatever the locale is.
    (with-entry (e)
      (setf (entry-pathname e) "project/naïve résumé.txt"
            (entry-type e) :regular
            (entry-perm e) #o640
            (entry-uid e) 501 (entry-gid e) 20
            (entry-uname e) "alice" (entry-gname e) "staff"
            (entry-mtime e) *when*
            (entry-atime e) (+ *when* 60)
            (entry-ctime e) (+ *when* 120)
            (entry-birthtime e) (- *when* 3600))
      ;; pax keeps extended attributes; values are octets or strings.
      (entry-add-xattr e "user.comment" "written by entries.lisp")
      (entry-add-xattr e "user.scratch" "about to be cleared")
      (entry-clear-xattrs e)
      (entry-add-xattr e "user.comment" "written by entries.lisp")
      ;; WRITE-ENTRY sets the size from the data when the entry has none.
      (assert (not (entry-size-set-p e)))
      (write-entry w e "Données accentuées.
"))

    ;; Links and special files carry no data.
    (with-entry (e :pathname "project/current" :symlink "naïve résumé.txt" :mtime *when*)
      (write-entry w e))
    (with-entry (e :pathname "project/also-the-resume.txt"
                   :hardlink "project/naïve résumé.txt" :mtime *when*)
      (write-entry w e))
    (with-entry (e :pathname "project/pipe" :type :fifo :perm #o600 :mtime *when*)
      (write-entry w e))

    ;; Unsetting: NIL clears a time. A tar header has no "unset", though, so
    ;; it is written as 0 and comes back as the Unix epoch.
    (with-entry (e :pathname "project/timeless" :mtime *when*)
      (setf (entry-mtime e) nil)
      (assert (null (entry-mtime e)))
      (write-entry w e ""))))

(defun main ()
  (let ((archive (build-archive))
        (kept nil))
    (format t "Wrote a ~D-byte pax archive.~%~%" (length archive))
    (with-archive-reader (r archive)
      (do-archive-entries (e r)
        (describe-entry e)
        ;; A borrowed entry is only good until the next NEXT-ENTRY. COPY-ENTRY
        ;; makes an owned one that outlives the reader.
        (when (eq (entry-type e) :regular)
          (push (copy-entry e) kept))
        (let ((name (entry-pathname e)))
          (cond ((string= name "project/naïve résumé.txt")
                 (assert (= #o640 (entry-perm e)))
                 (assert (string= "alice" (entry-uname e)))
                 (assert (= (+ *when* 60) (entry-atime e)))
                 (assert (equal '("user.comment") (mapcar #'car (entry-xattrs e))))
                 (assert (string= (read-entry-string r) "Données accentuées.
")))
                ((string= name "project/current")
                 (assert (eq :symlink (entry-type e))))
                ((string= name "project/also-the-resume.txt")
                 (assert (string= "project/naïve résumé.txt" (entry-hardlink e))))
                ((string= name "project/pipe")
                 (assert (eq :fifo (entry-type e))))
                ((string= name "project/timeless")
                 (assert (= (entry-mtime e) (encode-universal-time 0 0 0 1 1 1970 0))))))))

    ;; The reader is closed: the borrowed entries are invalid, the copies are not.
    (format t "~%Kept after closing the reader:~%")
    (dolist (e (reverse kept))
      (format t "  ~A~%" e)
      (assert (entry-valid-p e))
      (free-entry e)
      (assert (not (entry-valid-p e))))

    ;; Touching a borrowed entry after its reader has moved on is an error, not
    ;; a read of whatever entry is in the struct now.
    (let ((stale nil))
      (with-archive-reader (r archive)
        (setf stale (next-entry r))
        (next-entry r))
      (assert (not (entry-valid-p stale)))
      (handler-case (progn (entry-pathname stale) (error "stale entry was readable"))
        (error (c) (format t "~%Using a stale entry: ~A~%" c))))))

(main)
