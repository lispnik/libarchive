(in-package #:libarchive/tests)

(def-suite libarchive-callbacks :in libarchive-all)
(in-suite libarchive-callbacks)

;;; A Lisp error inside a callback must come out as itself, once libarchive has
;;; returned, and must leave nothing registered.

(test read-callback-error-is-resignalled
  (let ((baseline (libarchive::registry-count))
        (archive (with-archive-to-octets (w :format :ustar)
                   (add-entry w "big" :data (random-octets 100000)))))
    (signals test-stream-error
      (with-archive-reader (r (make-octet-input-stream archive :fail-after 20000))
        (next-entry r)
        (read-entry-data r)))
    (is (= baseline (libarchive::registry-count)))))

(test read-callback-error-during-open
  (signals test-stream-error
    (open-archive-reader (make-octet-input-stream (sample-archive) :fail-after 0))))

(test write-callback-error-is-resignalled
  (let ((baseline (libarchive::registry-count)))
    (signals test-stream-error
      (with-archive-writer (w (make-octet-output-stream :fail-after 10000) :format :ustar)
        (add-entry w "big" :data (random-octets 100000))))
    (is (= baseline (libarchive::registry-count)))))

(test write-callback-error-at-close
  ;; Small enough to sit in libarchive's buffer until the trailer is flushed.
  (signals test-stream-error
    (with-archive-writer (w (make-octet-output-stream :fail-after 0) :format :ustar)
      (add-entry w "small" :data "x"))))

(test unknown-client-data-fails-safely
  ;; libarchive would only ever pass back a key we gave it, but a stale or bogus
  ;; key must still mean failure, not a crash.
  (cffi:with-foreign-object (buf :pointer)
    (is (= +archive-fatal+
           (cffi:foreign-funcall-pointer (cffi:callback libarchive::read-callback) ()
                                         :pointer (cffi:null-pointer)
                                         :pointer (cffi:make-pointer 987654321)
                                         :pointer buf :ssize)))))

(test interleaved-readers-are-demultiplexed
  (let* ((a (with-archive-to-octets (w :format :ustar) (add-entry w "a" :data (random-octets 50000 1))))
         (b (with-archive-to-octets (w :format :ustar) (add-entry w "b" :data (random-octets 50000 2))))
         (ra (open-archive-reader (make-octet-input-stream a)))
         (rb (open-archive-reader (make-octet-input-stream b))))
    (unwind-protect
         (progn
           (is (string= "b" (entry-pathname (next-entry rb))))
           (is (string= "a" (entry-pathname (next-entry ra))))
           (let ((ba (make-array 1000 :element-type '(unsigned-byte 8)))
                 (bb (make-array 1000 :element-type '(unsigned-byte 8))))
             ;; Alternate small reads so both readers' callbacks run in turn.
             (loop repeat 50
                   do (read-entry-data-into ra ba)
                      (read-entry-data-into rb bb))
             (is (octets= (subseq (random-octets 50000 1) 49000) ba))
             (is (octets= (subseq (random-octets 50000 2) 49000) bb))))
      (close-archive ra)
      (close-archive rb))))

(test readers-in-threads
  (let* ((archives (loop for i from 1 to 8
                         collect (let ((i i))
                                   (with-archive-to-octets (w :format :pax-restricted :filters :gzip)
                                     (add-entry w (format nil "f~D" i) :data (random-octets 80000 i))))))
         (threads (loop for archive in archives
                        for i from 1
                        collect (let ((archive archive) (i i))
                                  (bt:make-thread
                                   (lambda ()
                                     (let ((got (entries-alist (make-octet-input-stream archive))))
                                       (and (string= (format nil "f~D" i) (car (first got)))
                                            (octets= (random-octets 80000 i) (cdr (first got)))))))))))
    (is (every #'identity (mapcar #'bt:join-thread threads)))))

(test passphrase-function-error-is-resignalled
  (let ((zip (with-archive-to-octets (w :format :zip :passphrase "pw"
                                        :options '(("zip:encryption" . "traditional")))
               (add-entry w "secret" :data "s"))))
    (signals test-stream-error
      (with-archive-reader (r zip :passphrase (lambda () (error 'test-stream-error)))
        (next-entry r)
        (read-entry-data r)))))

(test filter-function-error-is-resignalled
  (with-temp-directory (dir)
    (write-file (merge-pathnames "a" dir) "a")
    (signals test-stream-error
      (archive-directory dir :octets :filter (lambda (e) (declare (ignore e))
                                               (error 'test-stream-error))))))
