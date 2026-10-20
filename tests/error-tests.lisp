(in-package #:libarchive/tests)

(def-suite libarchive-errors :in libarchive-all)
(in-suite libarchive-errors)

(test garbage-is-not-an-archive
  (handler-case (progn (archive-entry-names (random-octets 5000)) (fail "no error"))
    (archive-fatal-error (c)
      (is (stringp (archive-condition-message c)))
      (is (search "nrecognized" (archive-condition-message c))))))

(test missing-file-reports-errno
  (handler-case (progn (open-archive-reader #p"/nonexistent/x.tar") (fail "no error"))
    (archive-error (c)
      (is (= 2 (archive-condition-errno c)))    ; ENOENT
      (is (search "/nonexistent/x.tar" (princ-to-string c))))))

(test truncated-data-is-an-error
  (let* ((full (with-archive-to-octets (w :format :ustar :filters :gzip)
                 (add-entry w "big" :data (random-octets 100000))))
         (cut (subseq full 0 (floor (length full) 2))))
    (signals archive-error
      (with-archive-reader (r cut)
        (next-entry r)
        (read-entry-data r)))))

(test return-codes-become-conditions
  (load-libraries)
  (let ((r (open-archive-reader (sample-archive))))
    (unwind-protect
         (progn
           (is (= 0 (libarchive::check-result r +archive-ok+ "t")))
           (is (= 1 (libarchive::check-result r +archive-eof+ "t")))
           (is (= 42 (libarchive::check-result r 42 "t")))
           (signals archive-warning (libarchive::check-result r +archive-warn+ "t"))
           (is (= +archive-warn+ (handler-bind ((warning #'muffle-warning))
                                   (libarchive::check-result r +archive-warn+ "t"))))
           (signals archive-retry (libarchive::check-result r +archive-retry+ "t"))
           (handler-case (libarchive::check-result r +archive-failed+ "t")
             (archive-fatal-error () (fail "FAILED is not fatal"))
             (archive-error (c) (is (= +archive-failed+ (archive-condition-code c)))))
           (signals archive-fatal-error (libarchive::check-result r +archive-fatal+ "t")))
      (close-archive r))))

(test unknown-keywords-are-rejected
  (signals error (open-archive-reader (sample-archive) :formats '(:no-such-format)))
  (signals error (open-archive-reader (sample-archive) :filters :no-such-filter))
  (signals archive-error (open-archive-writer :octets :format :no-such-format))
  (signals archive-error (open-archive-writer :octets :filters :no-such-filter))
  (signals error (make-entry :pathname "x" :type :no-such-type))
  (signals error (extract-archive (sample-archive) "/tmp/" :flags '(:no-such-flag))))

(test closed-handles-refuse-work
  (let ((r (open-archive-reader (sample-archive))))
    (close-archive r)
    (close-archive r)                   ; idempotent
    (is (not (archive-open-p r)))
    (signals error (next-entry r)))
  (let ((w (open-archive-writer :octets)))
    (signals error (writer-octets w))
    (close-archive w)
    (signals error (add-entry w "x" :data "x"))))

(test ustar-name-too-long
  ;; ustar cannot store a 300-byte name; libarchive refuses that entry only.
  (signals archive-error
    (with-archive-to-octets (w :format :ustar)
      (add-entry w (make-string 300 :initial-element #\n) :data "x"))))

(test aborted-writer-leaves-no-trailer
  (let ((out (make-octet-output-stream)))
    (ignore-errors
     (with-archive-writer (w out :format :ustar)
       (add-entry w "f" :data "x")
       (error "abandon")))
    ;; Nothing reached the stream: the only block was still buffered.
    (is (zerop (length (stream-octets out))))))

(test foreign-function-probe
  (is-true (foreign-function-available-p "archive_read_new"))
  (is-false (foreign-function-available-p "archive_no_such_function")))
