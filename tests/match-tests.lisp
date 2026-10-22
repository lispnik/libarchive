(in-package #:libarchive/tests)

(def-suite libarchive-match :in libarchive-all)
(in-suite libarchive-match)

(defconstant +old+ (encode-universal-time 0 0 0 1 6 2020 0))
(defconstant +new+ (encode-universal-time 0 0 0 1 6 2025 0))

(defparameter *match-names*
  `(("src/" . ,+old+) ("src/a.c" . ,+new+) ("src/a.o" . ,+old+) ("build/x.o" . ,+new+)
    ("lib/build/y" . ,+new+) ("README" . ,+old+)))

(defun call-with-match (match-keys function)
  (let ((m (apply #'make-archive-match match-keys)))
    (unwind-protect (funcall function m)
      (close-archive m))))

(defun last-char-p (string char)
  (eql (last-char string) char))

(defun chosen-names (&rest match-keys)
  "The names of *MATCH-NAMES* a matcher made from MATCH-KEYS chooses, and its
unmatched inclusions."
  (call-with-match
   match-keys
   (lambda (m)
    (values (loop for (name . mtime) in *match-names*
                  when (with-entry (e :pathname name :mtime mtime)
                         (entry-matches-p m e))
                    collect name)
            (archive-match-unmatched m)))))

(defun chosen (&rest match-keys)
  (values (apply #'chosen-names match-keys)))

(test match-by-name
  ;; Exclusions match at any directory boundary, and take what is under a
  ;; directory with them.
  (is (equal '("src/" "src/a.c" "lib/build/y" "README") (chosen :exclude "*.o")))
  (is (equal '("src/" "src/a.c" "src/a.o" "README") (chosen :exclude '("build"))))
  ;; Inclusions take everything under a directory, and say which never matched.
  (multiple-value-bind (names unmatched) (chosen-names :include '("src" "nothing"))
    (is (equal '("src/" "src/a.c" "src/a.o") names))
    (is (equal '("nothing") unmatched)))
  (is (equal '("src/") (chosen :include "src" :recursive nil)))
  (is (equal '("src/a.c") (chosen :include "src" :exclude "*.o" :newer +old+))))

(test match-by-time
  (let ((mid (encode-universal-time 0 0 0 1 1 2023 0)))
    (is (equal '("src/a.c" "build/x.o" "lib/build/y") (chosen :newer mid)))
    (is (equal '("src/" "src/a.o" "README") (chosen :older mid)))
    ;; Strictly: neither newer nor older than itself.
    (is (equal '() (chosen :newer +new+ :older +old+)))
    (is (equal '("src/a.c" "build/x.o" "lib/build/y") (chosen :newer "2023-01-01")))
    (is (equal '() (chosen :newer "1 day ago")))
    ;; A pathname is a file whose own time is the limit.
    (with-temp-directory (dir)
      (let ((stamp (merge-pathnames "stamp" dir)))
        (extract-archive (with-archive-to-octets (w :format :pax-restricted)
                           (add-entry w "stamp" :data "" :mtime mid))
                         dir)
        (is (equal '("src/" "src/a.o" "README") (chosen :older stamp)))))
    (signals archive-error (make-archive-match :newer "not a date at all"))
    (signals error (make-archive-match :newer mid :time :atime))))

(test match-by-owner
  (with-archive-match (m :unames '("alice"))
    (with-entry (e :pathname "a" :uname "alice")
      (is-true (entry-matches-p m e)))
    (with-entry (e :pathname "b" :uname "bob")
      (is-false (entry-matches-p m e)))))

(test extract-with-match
  (let ((archive (with-archive-to-octets (w :format :pax-restricted)
                   (loop for (name . mtime) in *match-names*
                         do (if (last-char-p name #\/)
                                (add-entry w name :mtime mtime)
                                (add-entry w name :data name :mtime mtime))))))
    (with-temp-directory (dir)
      (with-archive-match (m :exclude "*.o" :newer "2023-01-01")
        ;; src/ is too old to be extracted itself, but src/a.c still is.
        (is (equal '("src/a.c" "lib/build/y")
                   (extract-archive archive dir :match m))))
      (is-true (probe-file (merge-pathnames "src/a.c" dir)))
      (is-false (probe-file (merge-pathnames "src/a.o" dir))))))

(test archive-directory-with-match
  ;; An old directory with a new file in it, and an old file: by time, the
  ;; directory is left out but not what is in it; by name, a directory takes
  ;; its contents with it.
  (with-temp-directory (dir)
    (extract-archive (with-archive-to-octets (w :format :pax-restricted)
                       (add-entry w "tree/" :mtime +old+)
                       (add-entry w "tree/sub/" :mtime +old+)
                       (add-entry w "tree/sub/new.txt" :data "new" :mtime +new+)
                       (add-entry w "tree/old.txt" :data "old" :mtime +old+)
                       (add-entry w "tree/new.txt" :data "new" :mtime +new+))
                     dir)
    (flet ((stored (&rest match-keys)
             (let ((reported '()))
               (call-with-match
                match-keys
                (lambda (m)
                 (let ((octets (with-archive-to-octets (w :format :pax-restricted)
                                 (archive-directory (merge-pathnames "tree/" dir) w
                                                    :name "tree" :match m
                                                    :report (lambda (name) (push name reported))))))
                   (let ((names (sort (archive-entry-names octets) #'string<)))
                     ;; REPORT saw exactly what was written.
                     (is (equal names (sort (mapcar (lambda (n)
                                                      (if (member n '("tree" "tree/sub") :test #'string=)
                                                          (concatenate 'string n "/")
                                                          n))
                                                    reported)
                                            #'string<)))
                     names)))))))
      (is (equal '("tree/new.txt" "tree/sub/new.txt") (stored :newer "2023-01-01")))
      (is (equal '("tree/" "tree/old.txt" "tree/sub/") (stored :older "2023-01-01")))
      (is (equal '("tree/" "tree/new.txt" "tree/old.txt") (stored :exclude "sub"))))))

(test transfer-entry-streams-into-raw
  ;; A compressed file read as :raw has no size; a raw writer needs none, so
  ;; recompressing is streamed.
  (let* ((data (random-octets 300000))
         (gz (with-archive-to-octets (w :format :raw :filters '(:gzip))
               (add-entry w "data" :data data)))
         (xz (with-archive-reader (r gz :formats '(:raw))
               (with-archive-to-octets (w :format :raw :filters '(:xz))
                 (let ((e (next-entry r)))
                   (is-false (entry-size-set-p e))
                   (is (= (length data) (transfer-entry r w e))))))))
    (with-archive-reader (r xz :formats '(:raw))
      (next-entry r)
      (is (equal '("xz") (archive-filter-names r)))
      (is (octets= data (read-entry-data r))))))
