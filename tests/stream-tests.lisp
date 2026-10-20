(in-package #:libarchive/tests)

(def-suite libarchive-streams :in libarchive-all)
(in-suite libarchive-streams)

(test write-to-and-read-from-unseekable-streams
  (let ((out (make-octet-output-stream)))
    (with-archive-writer (w out :format :pax-restricted :filters :gzip)
      (add-entry w "x/big" :data (random-octets 200000))
      (add-entry w "x/small" :data "small"))
    (let ((got (entries-alist (make-octet-input-stream (stream-octets out)))))
      (is (equal '("x/big" "x/small") (mapcar #'car got)))
      (is (octets= (random-octets 200000) (cdr (first got)))))))

(test stream-output-matches-octet-output
  ;; Same archive, two sinks: the callback path must not alter a byte.
  (flet ((build (w) (add-entry w "f" :data (every-byte) :mtime +sample-mtime+)))
    (let ((out (make-octet-output-stream)))
      (with-archive-writer (w out :format :ustar) (build w))
      (is (octets= (with-archive-to-octets (w :format :ustar) (build w))
                   (stream-octets out))))))

(test seekable-file-stream-source
  ;; The seek callback: zip read from a file stream takes the seeking reader,
  ;; which uses the central directory at the end of the file.
  (with-temp-directory (dir)
    (let ((path (write-file (merge-pathnames "s.zip" dir)
                            (sample-archive :format :zip))))
      (with-open-file (in path :element-type '(unsigned-byte 8))
        (is (equal '("top/" "top/a.txt" "top/b.bin" "top/link")
                   (archive-entry-names in)))))))

(test seven-zip-needs-a-seekable-source
  (let ((seven (sample-archive :format :7zip)))
    (with-temp-directory (dir)
      (with-open-file (in (write-file (merge-pathnames "s.7z" dir) seven)
                          :element-type '(unsigned-byte 8))
        (is (= 4 (length (entries-alist in))))))))

(test skip-callback-on-seekable-stream
  (with-temp-directory (dir)
    (let ((path (write-file (merge-pathnames "s.tar" dir)
                            (with-archive-to-octets (w :format :ustar)
                              (add-entry w "skipped" :data (random-octets 500000))
                              (add-entry w "read" :data "tail")))))
      (with-open-file (in path :element-type '(unsigned-byte 8))
        (with-archive-reader (r in)
          (next-entry r)
          (skip-entry-data r)
          (next-entry r)
          (is (string= "tail" (read-entry-string r))))))))

(test copy-entry-data-to-stream
  (with-archive-reader (r (sample-archive))
    (loop for e = (next-entry r)
          until (string= "top/b.bin" (entry-pathname e)))
    (let ((out (make-octet-output-stream)))
      (is (= 256 (copy-entry-data r out)))
      (is (octets= (every-byte) (stream-octets out))))))

(test pathname-source-and-target
  (with-temp-directory (dir)
    (let ((path (merge-pathnames "p.tar.xz" dir)))
      (with-archive-writer (w path :format :by-extension)
        (add-entry w "hello" :data "world"))
      (with-archive-reader (r (namestring path))
        (next-entry r)
        (is (equal '("xz") (archive-filter-names r)))
        (is (string= "world" (read-entry-string r)))))))

(test system-tar-reads-our-archive
  (if (not (program-available-p "tar"))
      (skip "no tar on PATH")
      (with-temp-directory (dir)
        (let ((path (merge-pathnames "t.tar.gz" dir)))
          (write-file path (sample-archive :format :pax-restricted :filters :gzip))
          (is (equal '("top/" "top/a.txt" "top/b.bin" "top/link")
                     (uiop:split-string (string-right-trim '(#\Newline)
                                                           (run-command "tar" "-tzf" (uiop:native-namestring path)))
                                        :separator '(#\Newline))))))))

(test we-read-the-system-zip
  (if (not (program-available-p "zip"))
      (skip "no zip on PATH")
      (with-temp-directory (dir)
        (write-file (merge-pathnames "in/one.txt" dir) "one")
        (write-file (merge-pathnames "in/two.bin" dir) (every-byte))
        (uiop:run-program (list "zip" "-qr" "../z.zip" ".")
                          :directory (merge-pathnames "in/" dir))
        (let ((got (entries-alist (merge-pathnames "z.zip" dir))))
          (is (octets= (babel:string-to-octets "one")
                       (cdr (assoc "one.txt" got :test #'string=))))
          (is (octets= (every-byte) (cdr (assoc "two.bin" got :test #'string=))))))))
