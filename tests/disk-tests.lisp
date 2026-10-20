(in-package #:libarchive/tests)

(def-suite libarchive-disk :in libarchive-all)
(in-suite libarchive-disk)

(defun stat-mode (path)
  (multiple-value-bind (ok dev ino mode) (sb-unix:unix-lstat (uiop:native-namestring path))
    (declare (ignore dev ino))
    (and ok mode)))

(defun symlink-target (path)
  (sb-unix:unix-readlink (uiop:native-namestring path)))

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
      (is (string= "konnichiwa"
                   (uiop:read-file-string (merge-pathnames "Grüße/日本語.txt" out))))
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
