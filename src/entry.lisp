;;; ENTRY: a Lisp view of a struct archive_entry *.
;;;
;;; Two kinds, with different lifetimes:
;;;
;;;   owned     made by MAKE-ENTRY or COPY-ENTRY. Freed by FREE-ENTRY, or by the
;;;             GC if you forget.
;;;   borrowed  returned by NEXT-ENTRY. The struct belongs to the reader and is
;;;             reused, so the Lisp object is invalidated by the next
;;;             NEXT-ENTRY and by closing the reader; touching it afterwards
;;;             signals an error instead of reading another entry's fields.
;;;             COPY-ENTRY it to keep it.
;;;
;;; Strings go through libarchive's _utf8 accessors, so results do not depend on
;;; the process locale. Times are universal times.

(in-package #:libarchive)

(defclass entry ()
  ((pointer :initarg :pointer :accessor %entry-pointer)
   ;; NIL when we own the struct, else the handle that does.
   (owner   :initarg :owner :initform nil :reader entry-owner)))

(defun entry-valid-p (entry)
  (not (cffi:null-pointer-p (%entry-pointer entry))))

(defun entry-pointer (entry)
  (let ((p (%entry-pointer entry)))
    (when (cffi:null-pointer-p p)
      (error "~S is no longer valid: it was borrowed from a reader that has moved ~
              on or closed. Use COPY-ENTRY to keep an entry." entry))
    p))

(defmethod print-object ((e entry) stream)
  (print-unreadable-object (e stream :type t :identity t)
    (if (entry-valid-p e)
        (format stream "~S ~(~A~)" (entry-pathname e) (entry-type e))
        (write-string "invalid" stream))))

(defun make-borrowed-entry (pointer owner)
  (make-instance 'entry :pointer pointer :owner owner))

(defun invalidate-entry (entry)
  (setf (%entry-pointer entry) (cffi:null-pointer)))

(defun wrap-owned-entry (pointer)
  (when (cffi:null-pointer-p pointer)
    (error 'archive-fatal-error :message "allocation failed" :operation "archive_entry_new"))
  (let ((e (make-instance 'entry :pointer pointer)))
    (tg:finalize e (lambda () (%archive-entry-free pointer)))
    e))

(defun free-entry (entry)
  "Free an entry made by MAKE-ENTRY or COPY-ENTRY. Idempotent."
  (when (and (null (entry-owner entry)) (entry-valid-p entry))
    (tg:cancel-finalization entry)
    (%archive-entry-free (%entry-pointer entry))
    (invalidate-entry entry))
  nil)

(defun copy-entry (entry)
  "An owned copy of ENTRY, valid until FREE-ENTRY."
  (wrap-owned-entry (%archive-entry-clone (entry-pointer entry))))

;;; File types.

(defparameter *entry-types*
  `((:regular . ,+ae-ifreg+)
    (:directory . ,+ae-ifdir+)
    (:symlink . ,+ae-iflnk+)
    (:fifo . ,+ae-ififo+)
    (:socket . ,+ae-ifsock+)
    (:character-device . ,+ae-ifchr+)
    (:block-device . ,+ae-ifblk+)))

(defun entry-type (entry)
  "One of :REGULAR :DIRECTORY :SYMLINK :FIFO :SOCKET :CHARACTER-DEVICE
:BLOCK-DEVICE, or NIL if unset."
  (car (rassoc (%archive-entry-filetype (entry-pointer entry)) *entry-types*)))

(defun (setf entry-type) (type entry)
  (%archive-entry-set-filetype (entry-pointer entry)
                               (or (cdr (assoc type *entry-types*))
                                   (error "Unknown entry type ~S; expected one of ~S."
                                          type (mapcar #'car *entry-types*))))
  type)

;;; Strings.

(declaim (inline native-string))
(defun native-string (string)
  "STRING as read from libarchive, in NFC on macOS.

On Apple platforms libarchive converts every name it reads to the locale's
charset in Unicode normalization form D, the form HFS+ used, so \"Grüße\"
written comes back as \"Gru\\u0308ße\". Elsewhere it does no normalization.
Recomposing makes a name read back equal to the name written, and the same on
every platform; APFS is normalization-insensitive, so nothing on disk changes."
  #+darwin (if (and string (find-if (lambda (c) (> (char-code c) 127)) string))
               #+sbcl (sb-unicode:normalize-string string :nfc)
               #-sbcl (uax-15:normalize string :nfc)
               string)
  #-darwin string)

(defmacro define-string-accessor (name getter setter &optional fallback)
  "NAME reads with GETTER (a _utf8 accessor); if that cannot convert, FALLBACK,
the locale-encoded accessor, is tried. (SETF NAME) writes with SETTER."
  `(progn
     (defun ,name (entry)
       (let ((p (entry-pointer entry)))
         (native-string
          (or (,getter p)
              ,@(when fallback `((ignore-errors (,fallback p))))))))
     (defun (setf ,name) (value entry)
       (,setter (entry-pointer entry) value)
       value)))

(define-string-accessor entry-pathname
  %archive-entry-pathname-utf8 %archive-entry-set-pathname-utf8 %archive-entry-pathname)
(define-string-accessor entry-uname
  %archive-entry-uname-utf8 %archive-entry-set-uname-utf8 %archive-entry-uname)
(define-string-accessor entry-gname
  %archive-entry-gname-utf8 %archive-entry-set-gname-utf8 %archive-entry-gname)
(define-string-accessor entry-symlink
  %archive-entry-symlink-utf8 %archive-entry-set-symlink-utf8 %archive-entry-symlink)
(define-string-accessor entry-hardlink
  %archive-entry-hardlink-utf8 %archive-entry-set-hardlink-utf8 %archive-entry-hardlink)

(defun entry-strmode (entry)
  "ls-style mode string, e.g. \"-rw-r--r-- \"."
  (%archive-entry-strmode (entry-pointer entry)))

(defun entry-fflags-text (entry)
  (%archive-entry-fflags-text (entry-pointer entry)))

;;; Integers.

(defun entry-size (entry)
  "Data size in bytes, or NIL if the archive does not record it (e.g. streamed zip)."
  (let ((p (entry-pointer entry)))
    (and (/= 0 (%archive-entry-size-is-set p)) (%archive-entry-size p))))

(defun (setf entry-size) (size entry)
  (if size
      (%archive-entry-set-size (entry-pointer entry) size)
      (%archive-entry-unset-size (entry-pointer entry)))
  size)

(defun entry-size-set-p (entry)
  (/= 0 (%archive-entry-size-is-set (entry-pointer entry))))

(defmacro define-integer-accessor (name getter setter)
  `(progn
     (defun ,name (entry) (,getter (entry-pointer entry)))
     (defun (setf ,name) (value entry)
       (,setter (entry-pointer entry) value)
       value)))

(define-integer-accessor entry-perm %archive-entry-perm %archive-entry-set-perm)
(define-integer-accessor entry-mode %archive-entry-mode %archive-entry-set-mode)
(define-integer-accessor entry-uid %archive-entry-uid %archive-entry-set-uid)
(define-integer-accessor entry-gid %archive-entry-gid %archive-entry-set-gid)
(define-integer-accessor entry-nlink %archive-entry-nlink %archive-entry-set-nlink)

(defun entry-data-encrypted-p (entry)
  (/= 0 (%archive-entry-is-data-encrypted (entry-pointer entry))))

(defun entry-metadata-encrypted-p (entry)
  (/= 0 (%archive-entry-is-metadata-encrypted (entry-pointer entry))))

;;; Times, as universal times (NIL when unset).

(defmacro define-time-accessor (name getter is-set setter unsetter)
  `(progn
     (defun ,name (entry)
       (let ((p (entry-pointer entry)))
         (and (/= 0 (,is-set p)) (unix->universal (,getter p)))))
     (defun (setf ,name) (time entry)
       (if time
           (,setter (entry-pointer entry) (universal->unix time) 0)
           (,unsetter (entry-pointer entry)))
       time)))

(define-time-accessor entry-mtime %archive-entry-mtime %archive-entry-mtime-is-set
  %archive-entry-set-mtime %archive-entry-unset-mtime)
(define-time-accessor entry-atime %archive-entry-atime %archive-entry-atime-is-set
  %archive-entry-set-atime %archive-entry-unset-atime)
(define-time-accessor entry-ctime %archive-entry-ctime %archive-entry-ctime-is-set
  %archive-entry-set-ctime %archive-entry-unset-ctime)
(define-time-accessor entry-birthtime %archive-entry-birthtime %archive-entry-birthtime-is-set
  %archive-entry-set-birthtime %archive-entry-unset-birthtime)

(defun entry-mtime-nsec (entry)
  (%archive-entry-mtime-nsec (entry-pointer entry)))

;;; Extended attributes, as an alist of (name . octets).

(defun entry-xattrs (entry)
  "ENTRY's extended attributes, an alist of (name . octets), each name once.

The pax writer records every attribute twice, as LIBARCHIVE.xattr.* and as
SCHILY.xattr.* for other tars, and libarchive's pax reader adds both to the
entry; only the first of each name is kept."
  (remove-duplicates (entry-xattrs-raw entry) :key #'car :test #'string= :from-end t))

(defun entry-xattrs-raw (entry)
  (let ((p (entry-pointer entry)))
    (%archive-entry-xattr-reset p)
    (cffi:with-foreign-objects ((name :pointer) (value :pointer) (size :size))
      (loop while (= +archive-ok+ (%archive-entry-xattr-next p name value size))
            collect (let* ((n (cffi:mem-ref size :size))
                           (octets (make-array n :element-type '(unsigned-byte 8))))
                      (copy-from-foreign (cffi:mem-ref value :pointer) octets 0 n)
                      (cons (cffi:foreign-string-to-lisp (cffi:mem-ref name :pointer))
                            octets))))))

(defun entry-add-xattr (entry name value)
  (let ((octets (ensure-octets value)))
    (cffi:with-pointer-to-vector-data (p octets)
      (%archive-entry-xattr-add-entry (entry-pointer entry) name p (length octets))))
  value)

(defun entry-clear-xattrs (entry)
  (%archive-entry-xattr-clear (entry-pointer entry)))

;;; Construction.

(defun make-entry (&key pathname type (perm nil perm-p) size mtime atime ctime
                     uid gid uname gname symlink hardlink)
  "A new owned entry. TYPE defaults to :DIRECTORY for a PATHNAME ending in /,
else :REGULAR; PERM defaults to #o755 for directories and #o644 otherwise.
Times are universal times. Free it with FREE-ENTRY (or WITH-ENTRY)."
  (load-libraries)
  (let* ((e (wrap-owned-entry (%archive-entry-new)))
         (type (or type
                   (cond (symlink :symlink)
                         ((and pathname (plusp (length pathname))
                               (char= #\/ (char pathname (1- (length pathname)))))
                          :directory)
                         (t :regular)))))
    (when pathname (setf (entry-pathname e) pathname))
    (setf (entry-type e) type)
    (setf (entry-perm e) (if perm-p perm (if (eq type :directory) #o755 #o644)))
    (when size (setf (entry-size e) size))
    (when mtime (setf (entry-mtime e) mtime))
    (when atime (setf (entry-atime e) atime))
    (when ctime (setf (entry-ctime e) ctime))
    (when uid (setf (entry-uid e) uid))
    (when gid (setf (entry-gid e) gid))
    (when uname (setf (entry-uname e) uname))
    (when gname (setf (entry-gname e) gname))
    (when symlink (setf (entry-symlink e) symlink))
    (when hardlink (setf (entry-hardlink e) hardlink))
    e))
