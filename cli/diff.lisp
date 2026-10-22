;;; la diff: compare an archive with the files on disk.
;;;
;;; Every entry is looked for under the directory (default: here) by its name
;;; in the archive, the way `la x' would put it there, and its type, contents,
;;; link target and permissions are compared. Inside the directories the
;;; archive covers, files it does not have are reported too. Exit 0 if nothing
;;; differs, 1 if something does.

(in-package #:libarchive/cli)

(defun disk-kind (stat)
  (let ((mode (sb-posix:stat-mode stat)))
    (cond ((sb-posix:s-isreg mode) :regular)
          ((sb-posix:s-isdir mode) :directory)
          ((sb-posix:s-islnk mode) :symlink)
          (t :other))))

(defun lstat-or-nil (path)
  (handler-case (sb-posix:lstat path)
    (sb-posix:syscall-error () nil)))

(defun same-contents-p (reader path)
  "True if the reader's current entry data is exactly the contents of PATH."
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let ((a (make-array 65536 :element-type '(unsigned-byte 8)))
          (b (make-array 65536 :element-type '(unsigned-byte 8))))
      (loop
        (let ((n (read-entry-data-into reader a)))
          (when (zerop n)
            (return (zerop (read-sequence b in :end 1))))
          (let ((m (read-sequence b in :end n)))
            (when (or (/= n m) (mismatch a b :end1 n :end2 n))
              (return nil))))))))

(defun directory-children (path)
  "The names in the directory PATH, dangling symlinks too; NIL if unreadable."
  (handler-case
      (let ((dir (sb-posix:opendir path))
            (names '()))
        (unwind-protect
             (loop for entry = (sb-posix:readdir dir)
                   until (sb-alien:null-alien entry)
                   do (let ((name (sb-posix:dirent-name entry)))
                        (unless (member name '("." "..") :test #'string=)
                          (push name names))))
          (sb-posix:closedir dir))
        names)
    (sb-posix:syscall-error () nil)))

(defun parent-names (name)
  "\"a/b/c\" => (\"a\" \"a/b\")."
  (loop for i = (position #\/ name) then (position #\/ name :start (1+ i))
        while i
        collect (subseq name 0 i)))

(defun kind-name (kind)
  (case kind
    (:regular "a file") (:directory "a directory") (:symlink "a symlink")
    ((nil) "a hard link") (t (format nil "a ~(~A~)" kind))))

(defun diff/handler (cmd)
  (let* ((args (clingon:command-arguments cmd))
         (*quiet* (clingon:getopt cmd :quiet))
         (times (clingon:getopt cmd :times))
         (base (user-directory (or (clingon:getopt cmd :directory) ".")))
         (root (uiop:native-namestring base))
         (differences 0)
         (entries 0))
    (unless (= 1 (length args))
      (usage-error "diff takes one archive (see la diff --help)"))
    (unless (uiop:directory-exists-p base)
      (fail "~A: no such directory" (or (clingon:getopt cmd :directory) ".")))
    (let ((name (first args))
          (in-archive (make-hash-table :test #'equal))
          (directories (make-hash-table :test #'equal)))
      (flet ((differ (control &rest args)
               (incf differences)
               (unless *quiet* (apply #'say control args))))
        (call-with-input-archive
         name
         (lambda (archive)
           (with-archive-reader (r archive :passphrase (reader-passphrase
                                                        (passphrase-source cmd (display-name name))))
             (do-archive-entries (e r)
               (let* ((entry-name (clean-name (entry-pathname e)))
                      (path (concatenate 'string root entry-name))
                      (kind (if (entry-hardlink e) nil (entry-type e)))
                      (stat (lstat-or-nil path)))
                 (unless (member entry-name '("" ".") :test #'string=)
                   (incf entries)
                   (setf (gethash entry-name in-archive) t)
                   (dolist (parent (parent-names entry-name))
                     (setf (gethash parent directories) t))
                   (when (eq kind :directory)
                     (setf (gethash entry-name directories) t))
                   (cond
                     ((null stat)
                      (differ "only in archive: ~A" (entry-pathname e)))
                     ;; A hard link's data is its target's, compared there.
                     ((null kind)
                      (unless (eq (disk-kind stat) :regular)
                        (differ "~A: ~A on disk, a hard link in the archive"
                                entry-name (kind-name (disk-kind stat)))))
                     ((not (eq kind (disk-kind stat)))
                      (differ "~A: ~A on disk, ~A in the archive"
                              entry-name (kind-name (disk-kind stat)) (kind-name kind)))
                     ((eq kind :symlink)
                      (let ((target (handler-case (sb-posix:readlink path)
                                      (sb-posix:syscall-error () nil))))
                        (unless (equal target (entry-symlink e))
                          (differ "~A: links to ~A on disk, ~A in the archive"
                                  entry-name target (entry-symlink e)))))
                     (t
                      (when (and (eq kind :regular)
                                 (or (and (entry-size e) (/= (entry-size e) (sb-posix:stat-size stat)))
                                     (not (same-contents-p r path))))
                        (differ "~A: contents differ" entry-name))
                      (let ((archive-perm (entry-perm e))
                            (disk-perm (logand #o7777 (sb-posix:stat-mode stat))))
                        ;; Zero is a format with no permissions to compare.
                        (when (and archive-perm (plusp archive-perm) (/= archive-perm disk-perm))
                          (differ "~A: mode ~O on disk, ~O in the archive"
                                  entry-name disk-perm archive-perm)))
                      (when (and times (eq kind :regular) (entry-mtime e))
                        (let ((disk-mtime (+ (sb-posix:stat-mtime stat)
                                             (encode-universal-time 0 0 0 1 1 1970 0))))
                          (unless (= disk-mtime (entry-mtime e))
                            (differ "~A: modified ~A on disk, ~A in the archive" entry-name
                                    (iso-time disk-mtime) (iso-time (entry-mtime e))))))))))))))
        ;; What is on disk, inside the directories the archive has, but not in it.
        (let ((extra '()))
          (maphash (lambda (dir v)
                     (declare (ignore v))
                     (dolist (child (directory-children (concatenate 'string root dir)))
                       (let ((child-name (format nil "~A/~A" dir child)))
                         (unless (or (gethash child-name in-archive) (gethash child-name directories))
                           (push child-name extra)))))
                   directories)
          (dolist (child-name (sort extra #'string<))
            (let ((stat (lstat-or-nil (concatenate 'string root child-name))))
              (differ "only on disk: ~A~:[~;/~]" child-name
                      (and stat (eq (disk-kind stat) :directory))))))
        (if (zerop differences)
            (note "~A: no differences in ~D entr~:@P" (display-name name) entries)
            (note "~A: ~D difference~:P" (display-name name) differences))
        (if (zerop differences) 0 1)))))

(register-command
 "diff"
 (lambda ()
   (clingon:make-command
    :name "diff"
    :aliases '("d")
    :usage "[options] ARCHIVE"
    :description "compare an archive with the files on disk"
    :long-description "Types, contents, symlink targets and permissions are compared, and files the archive does not have, in the directories it covers, are listed."
    :options (list (clingon:make-option :string :short-name #\C :long-name "directory"
                                                :key :directory :parameter "DIR"
                                                :description "compare with DIR instead of here")
                   (clingon:make-option :string :short-name #\p :long-name "passphrase"
                                                :key :passphrase :parameter "PASS"
                                                :description "passphrase for encrypted entries")
                   (clingon:make-option :flag :short-name #\t :long-name "times" :key :times
                                              :description "compare modification times too")
                   (clingon:make-option :flag :short-name #\q :long-name "quiet" :key :quiet
                                              :description "print nothing; the exit status says"))
    :handler #'diff/handler)))
