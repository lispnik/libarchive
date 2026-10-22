(in-package #:libarchive/tests)

(def-suite libarchive-disk :in libarchive-all)
(in-suite libarchive-disk)

(defun lstat-entry (path)
  "The mode and symlink target of PATH, not following a symlink: libarchive's
own lstat, so the tests need nothing implementation-specific."
  (load-libraries)
  (let ((a (%archive-read-disk-new)))
    (unwind-protect
         (with-entry (e :pathname (uiop:native-namestring path))
           (assert (<= 0 (%archive-read-disk-entry-from-file a (libarchive::entry-pointer e) -1
                                                             (cffi:null-pointer))))
           (values (entry-mode e) (entry-symlink e)))
      (%archive-read-free a))))

(defun stat-mode (path) (values (lstat-entry path)))

(defun symlink-target (path) (nth-value 1 (lstat-entry path)))

(test extract-sample-archive
  (with-temp-directory (dir)
    (is (equal '("top/" "top/a.txt" "top/b.bin" "top/link")
               (extract-archive (sample-archive) dir)))
    (is (octets= (babel:string-to-octets "alpha") (read-file (merge-pathnames "top/a.txt" dir))))
    (is (octets= (every-byte) (read-file (merge-pathnames "top/b.bin" dir))))
    (is (= #o600 (logand #o777 (stat-mode (merge-pathnames "top/b.bin" dir)))))
    (is (string= "a.txt" (symlink-target (merge-pathnames "top/link" dir))))
    ;; :time is in the default flags.
    (is (= +sample-mtime+ (file-write-date (merge-pathnames "top/a.txt" dir))))))

(test extract-refuses-escaping-names
  (let ((evil (with-archive-to-octets (w :format :pax-restricted)
                (add-entry w "../escaped" :data "x")
                (add-entry w "/tmp/absolute" :data "x")
                (add-entry w "fine" :data "ok"))))
    (with-temp-directory (dir)
      (let ((extract-dir (merge-pathnames "out/" dir)))
        (signals archive-error (extract-archive evil extract-dir))
        ;; With the restart, the bad entries are skipped and the rest extracted.
        (is (equal '("fine")
                   (handler-bind ((archive-error (lambda (c) (declare (ignore c))
                                                   (invoke-restart 'skip-entry))))
                     (extract-archive evil extract-dir))))
        (is (not (probe-file (merge-pathnames "escaped" dir))))
        (is (probe-file (merge-pathnames "fine" extract-dir)))))))

(test extract-with-filter
  (with-temp-directory (dir)
    (is (equal '("top/a.txt")
               (extract-archive (sample-archive) dir
                                :filter (lambda (e) (string= "top/a.txt" (entry-pathname e))))))
    (is (probe-file (merge-pathnames "top/a.txt" dir)))
    (is (not (probe-file (merge-pathnames "top/b.bin" dir))))))

(test extract-progress-is-reported
  (let ((archive (with-archive-to-octets (w :format :ustar)
                   (add-entry w "big" :data (random-octets 2000000))))
        (reports '()))
    (with-temp-directory (dir)
      (extract-archive archive dir :progress (lambda (bytes) (push bytes reports))))
    (is (plusp (length reports)))
    (is (every #'integerp reports))))

(test extract-from-open-reader-and-encrypted
  (let ((zip (with-archive-to-octets (w :format :zip :passphrase "pw"
                                        :options "zip:encryption=traditional")
               (add-entry w "s.txt" :data "secret"))))
    (with-temp-directory (dir)
      (extract-archive zip dir :passphrase "pw")
      (is (octets= (babel:string-to-octets "secret") (read-file (merge-pathnames "s.txt" dir)))))
    (with-temp-directory (dir)
      (with-archive-reader (r zip :passphrase "pw")
        (extract-archive r dir)
        (is (not (archive-open-p (make-instance 'archive-reader :pointer (cffi:null-pointer)))))
        (is (archive-open-p r))))))

(defun make-tree (dir)
  (write-file (merge-pathnames "tree/a.txt" dir) "a")
  (write-file (merge-pathnames "tree/sub/b.bin" dir) (every-byte))
  (write-file (merge-pathnames "tree/sub/deeper/c" dir) (random-octets 100000))
  (write-file (merge-pathnames "tree/skip/ignored" dir) "no")
  (merge-pathnames "tree/" dir))

(test archive-directory-then-extract
  (with-temp-directory (dir)
    (let* ((tree (make-tree dir))
           (archive (with-archive-to-octets (w :format :pax-restricted :filters :zstd)
                      (archive-directory tree w)))
           (names (sort (archive-entry-names archive) #'string<)))
      (is (equal '("a.txt" "skip/" "skip/ignored" "sub/" "sub/b.bin" "sub/deeper/" "sub/deeper/c")
                 names))
      (let ((out (merge-pathnames "out/" dir)))
        (extract-archive archive out)
        (is (octets= (every-byte) (read-file (merge-pathnames "sub/b.bin" out))))
        (is (octets= (random-octets 100000) (read-file (merge-pathnames "sub/deeper/c" out))))))))

(test archive-directory-to-file-with-filter
  (with-temp-directory (dir)
    (let ((tree (make-tree dir))
          (path (merge-pathnames "t.tgz" dir)))
      (is (= 5 (archive-directory tree path :format :ustar :filters :gzip
                                            :filter (lambda (e)
                                                      (not (search "/skip" (entry-pathname e)))))))
      (is (equal '("a.txt" "sub/" "sub/b.bin" "sub/deeper/" "sub/deeper/c")
                 (sort (archive-entry-names path) #'string<)))
      (when (program-available-p "tar")
        (is (search "sub/deeper/c" (run-command "tar" "-tzf" (uiop:native-namestring path))))))))

(test write-entries-directly-to-disk
  (with-temp-directory (dir)
    (let ((disk (libarchive::make-disk-writer '(:time))))
      (unwind-protect
           (add-entry disk (uiop:native-namestring (merge-pathnames "direct/file" dir))
                      :data "direct" :mtime +sample-mtime+)
        (close-archive disk)))
    (is (octets= (babel:string-to-octets "direct")
                 (read-file (merge-pathnames "direct/file" dir))))
    (is (= +sample-mtime+ (file-write-date (merge-pathnames "direct/file" dir))))))

(test non-ascii-names-on-disk
  ;; Extraction and read_disk both go through the locale conversion too.
  (with-temp-directory (dir)
    (let* ((archive (with-archive-to-octets (w :format :pax-restricted :filters :gzip)
                      (add-entry w "Grüße/日本語.txt" :data "konnichiwa")))
           (out (merge-pathnames "out/" dir)))
      (is (equal '("Grüße/日本語.txt") (extract-archive archive out)))
      ;; Read back by Lisp, where Lisp can name the file: ECL before 23
      ;; accepts no file name outside Latin-1.
      (if (ignore-errors (probe-file (merge-pathnames "日本語" dir)) t)
          (is (string= "konnichiwa"
                       (uiop:read-file-string (merge-pathnames "Grüße/日本語.txt" out))))
          (skip "~A cannot open a file named outside Latin-1" (lisp-implementation-type)))
      (let ((again (with-archive-to-octets (w :format :zip)
                     (archive-directory out w))))
        (is (equal '("Grüße/" "Grüße/日本語.txt")
                   (sort (archive-entry-names again) #'string<)))))))

(test archive-directory-with-a-name
  (with-temp-directory (dir)
    (let ((tree (make-tree dir)))
      ;; A directory under a name of its own, the way `tar cf x.tar tree' stores it.
      (let ((archive (with-archive-to-octets (w :format :ustar)
                       (archive-directory tree w :name "proj"))))
        (is (equal '("proj/" "proj/a.txt" "proj/skip/" "proj/skip/ignored" "proj/sub/"
                     "proj/sub/b.bin" "proj/sub/deeper/" "proj/sub/deeper/c")
                   (sort (archive-entry-names archive) #'string<))))
      ;; A single file: stored under its file name, or the name given.
      (let ((file (merge-pathnames "a.txt" tree)))
        (is (equal '("a.txt" "notes/alpha.txt")
                   (archive-entry-names
                    (with-archive-to-octets (w :format :ustar)
                      (archive-directory file w)
                      (archive-directory file w :name "notes/alpha.txt")))))
        (is (equal '(("a.txt" . "a"))
                   (mapcar (lambda (p) (cons (car p) (babel:octets-to-string (cdr p))))
                           (entries-alist (with-archive-to-octets (w :format :zip)
                                            (archive-directory file w))))))))))

(test archive-directory-of-a-missing-path
  (signals archive-error
    (with-archive-to-octets (w :format :ustar)
      (archive-directory #p"/nonexistent/path/" w))))

(test archive-directory-without-directory-entries
  (with-temp-directory (dir)
    (let ((tree (make-tree dir)))
      (is (equal '("a.txt" "skip/ignored" "sub/b.bin" "sub/deeper/c")
                 (sort (archive-entry-names
                        (with-archive-to-octets (w :format :warc)
                          (archive-directory tree w :directories nil)))
                       #'string<))))))

(test extract-filter-can-rename
  (with-temp-directory (dir)
    (let ((archive (with-archive-to-octets (w :format :ustar)
                     (add-entry w "pkg-1.0/")
                     (add-entry w "pkg-1.0/README" :data "r")
                     (add-entry w "pkg-1.0/../../out" :data "x")))
          (out (merge-pathnames "out/" dir)))
      (let ((names (handler-bind ((archive-error (lambda (c) (invoke-restart (find-restart 'skip-entry c)))))
                     (extract-archive archive out
                                      :filter (lambda (e)
                                                (let ((n (entry-pathname e)))
                                                  (when (> (length n) 8)
                                                    (setf (entry-pathname e) (subseq n 8))
                                                    t)))))))
        ;; Renamed, and the renamed ../out is still refused.
        (is (equal '("README") names))
        (is (string= "r" (uiop:read-file-string (merge-pathnames "README" out))))))))

;;; Attacks other extractors have fallen to. Each archive tries to reach
;;; OUTSIDE, a sibling of the target directory.

(defun outside-untouched-p (outside)
  (and (equal (mapcar #'file-namestring (uiop:directory-files outside)) '("victim"))
       (null (uiop:subdirectories outside))
       (octets= (babel:string-to-octets "original") (read-file (merge-pathnames "victim" outside)))))

(defmacro with-victim ((dest outside) &body body)
  (let ((dir (gensym)))
    `(with-temp-directory (,dir)
       (let ((,dest (merge-pathnames "dest/" ,dir))
             (,outside (merge-pathnames "outside/" ,dir)))
         (write-file (merge-pathnames "victim" ,outside) "original")
         (ensure-directories-exist ,dest)
         ,@body))))

(defun extract-skipping (archive dest &rest keys)
  "EXTRACT-ARCHIVE, skipping refused entries; returns what was extracted and
the messages of what was refused."
  (let ((refused '()))
    (values (handler-bind ((archive-error (lambda (c)
                                            (push (archive-condition-message c) refused)
                                            (invoke-restart 'skip-entry))))
              (apply #'extract-archive archive dest keys))
            refused)))

(test extract-refuses-paths-through-symlinks
  ;; libarchive refuses these (SECURE_SYMLINKS), but archive_read_extract2
  ;; reports the refusal as a warning; they must be errors, not "extracted".
  (with-victim (dest outside)
    (dolist (archive (list (with-archive-to-octets (w :format :pax)
                             (add-entry w "a" :symlink (uiop:native-namestring outside))
                             (add-entry w "a/pwned" :data "x"))
                           (with-archive-to-octets (w :format :pax)
                             (add-entry w "b" :symlink "c")
                             (add-entry w "c" :symlink "../outside")
                             (add-entry w "b/pwned" :data "x"))
                           (with-archive-to-octets (w :format :pax)
                             (add-entry w "d" :symlink "../outside")
                             (add-entry w "h" :hardlink "d/victim" :data "pwned"))))
      (signals archive-error (extract-archive archive dest))
      (multiple-value-bind (extracted refused) (extract-skipping archive dest)
        (is (= 1 (length refused)))
        (is (notany (lambda (n) (search "pwned" n)) extracted))
        (is (not (member "h" extracted :test #'string=))))
      (is-true (outside-untouched-p outside)))))

(test extract-leaves-the-target-directory-alone
  ;; `tar cf x.tar .' stores "./": extracted, it would set the target
  ;; directory's own mode and times.
  (with-victim (dest outside)
    (let ((before (stat-mode dest)))
      (is (equal '("./f")
                 (extract-archive (with-archive-to-octets (w :format :pax)
                                    (add-entry w "./" :perm #o777 :mtime 0)
                                    (add-entry w "././" :perm #o777 :mtime 0)
                                    (add-entry w "./f" :data "x"))
                                  dest)))
      (is (= before (stat-mode dest)))
      (is-true (outside-untouched-p outside)))))

(test extract-max-size
  (let ((archive (with-archive-to-octets (w :format :pax)
                   (add-entry w "small" :data (random-octets 1000))
                   (add-entry w "big" :data (random-octets 5000)))))
    (with-temp-directory (dir)
      ;; By the declared size: nothing of "big" is written. Skipping failed
      ;; entries does not carry on past the limit.
      (let ((c (handler-bind ((archive-error (lambda (c) (declare (ignore c))
                                               (invoke-restart 'skip-entry))))
                 (handler-case (extract-archive archive dir :max-size 3000)
                   (extraction-limit-exceeded (c) c)))))
        (is (typep c 'extraction-limit-exceeded))
        (is (string= "big" (extraction-limit-entry c)))
        (is (= 3000 (extraction-limit c))))
      (is-true (probe-file (merge-pathnames "small" dir)))
      (is-false (probe-file (merge-pathnames "big" dir)))
      (is (equal '("small" "big") (extract-archive archive (merge-pathnames "all/" dir)
                                                   :max-size 6000)))))
  ;; A zip read as a stream does not know its sizes: counted as written.
  (let ((zip (with-archive-to-octets (w :format :zip)
               (add-entry w "data" :data (make-array 100000 :element-type '(unsigned-byte 8)
                                                            :initial-element 0)))))
    (with-temp-directory (dir)
      (signals extraction-limit-exceeded
        (extract-archive (make-octet-input-stream zip) dir :max-size 50000)))))

(test extract-applies-the-umask-by-default
  (let ((archive (with-archive-to-octets (w :format :pax)
                   (add-entry w "open" :data "x" :perm #o777)
                   (add-entry w "dir/" :perm #o777)))
        (umask 0))
    (with-temp-directory (dir)
      ;; The umask, portably: what it takes from a new file's rw-rw-rw-.
      (setf umask (logandc2 #o666 (logand #o777 (stat-mode (write-file (merge-pathnames "probe" dir) "")))))
      (extract-archive archive dir)
      (unless (zerop umask)
        (is (= (logandc2 #o777 umask) (logand #o777 (stat-mode (merge-pathnames "open" dir)))))
        (is (= (logandc2 #o777 umask) (logand #o777 (stat-mode (merge-pathnames "dir/" dir))))))
      (extract-archive archive (merge-pathnames "exact/" dir)
                       :flags (cons :perm *default-extract-flags*))
      (is (= #o777 (logand #o777 (stat-mode (merge-pathnames "exact/open" dir))))))))
