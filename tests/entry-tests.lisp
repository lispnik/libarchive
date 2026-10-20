(in-package #:libarchive/tests)

(def-suite libarchive-entries :in libarchive-all)
(in-suite libarchive-entries)

(test make-entry-defaults
  (with-entry (e :pathname "f")
    (is (eq :regular (entry-type e)))
    (is (= #o644 (entry-perm e)))
    (is (null (entry-size e)))
    (is (null (entry-mtime e))))
  (with-entry (e :pathname "d/")
    (is (eq :directory (entry-type e)))
    (is (= #o755 (entry-perm e))))
  (with-entry (e :pathname "l" :symlink "target")
    (is (eq :symlink (entry-type e)))
    (is (string= "target" (entry-symlink e)))))

(test entry-accessors-round-trip
  (with-entry (e)
    (setf (entry-pathname e) "Grüße/日本語.txt")
    (is (string= "Grüße/日本語.txt" (entry-pathname e)))
    (setf (entry-type e) :fifo)
    (is (eq :fifo (entry-type e)))
    (setf (entry-type e) :regular
          (entry-perm e) #o751
          (entry-size e) 12345678901)
    (is (= #o751 (entry-perm e)))
    (is (= (logior +ae-ifreg+ #o751) (entry-mode e)))
    (is (= 12345678901 (entry-size e)))
    (setf (entry-size e) nil)
    (is (not (entry-size-set-p e)))
    (setf (entry-uid e) 501 (entry-gid e) 20
          (entry-uname e) "ünïcode" (entry-gname e) "staff")
    (is (equal '(501 20 "ünïcode" "staff")
               (list (entry-uid e) (entry-gid e) (entry-uname e) (entry-gname e))))
    (let ((now (get-universal-time)))
      (setf (entry-mtime e) now (entry-atime e) (- now 10))
      (is (= now (entry-mtime e)))
      (is (= (- now 10) (entry-atime e)))
      (setf (entry-mtime e) nil)
      (is (null (entry-mtime e))))
    (is (string= "-rwxr-x--x " (entry-strmode e)))))

(test entry-xattrs
  (with-entry (e :pathname "x")
    (is (null (entry-xattrs e)))
    (entry-add-xattr e "user.one" "1")
    (entry-add-xattr e "user.bin" (every-byte))
    (let ((x (entry-xattrs e)))
      (is (= 2 (length x)))
      (is (octets= (octets 49) (cdr (assoc "user.one" x :test #'string=))))
      (is (octets= (every-byte) (cdr (assoc "user.bin" x :test #'string=)))))
    (entry-clear-xattrs e)
    (is (null (entry-xattrs e)))))

(test copy-entry-is-independent
  (with-entry (e :pathname "a" :size 1)
    (let ((c (copy-entry e)))
      (unwind-protect
           (progn
             (setf (entry-pathname e) "b")
             (is (string= "a" (entry-pathname c)))
             (is (= 1 (entry-size c))))
        (free-entry c)))))

(test freed-entry-is-invalid
  (let ((e (make-entry :pathname "a")))
    (is (entry-valid-p e))
    (free-entry e)
    (is (not (entry-valid-p e)))
    (free-entry e)                      ; idempotent
    (signals error (entry-pathname e))))

(test borrowed-entry-is-invalidated-by-next-entry-and-close
  (with-archive-reader (r (sample-archive))
    (let* ((first (next-entry r))
           (kept (copy-entry first)))
      (unwind-protect
           (progn
             (is (string= "top/" (entry-pathname first)))
             (let ((second (next-entry r)))
               (is (not (entry-valid-p first)))
               (signals error (entry-pathname first))
               (is (string= "top/a.txt" (entry-pathname second)))
               (is (string= "top/" (entry-pathname kept)))
               (close-archive r)
               (is (not (entry-valid-p second)))))
        (free-entry kept)))))

(test entry-from-archive-has-metadata
  (with-archive-reader (r (sample-archive))
    (do-archive-entries (e r)
      (is (= +sample-mtime+ (entry-mtime e)))
      (cond ((string= "top/b.bin" (entry-pathname e))
             (is (= #o600 (entry-perm e)))
             (is (= 256 (entry-size e))))
            ((string= "top/link" (entry-pathname e))
             (is (eq :symlink (entry-type e)))
             (is (string= "a.txt" (entry-symlink e))))))))
