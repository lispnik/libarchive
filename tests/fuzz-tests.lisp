(in-package #:libarchive/tests)

;;; Damaged archives must fail as ARCHIVE-CONDITIONs: never as a Lisp type or
;;; decoding error, never by unwinding through a callback, never by leaking a
;;; handle (the hygiene suite checks that afterwards).
;;;
;;; Small valid archives of each format are mutated -- bits flipped, cut short,
;;; a run overwritten, a chunk repeated -- and each mutant is read to the end,
;;; entries, metadata and data, from memory and through an unseekable stream.
;;; The mutations are deterministic: a failure names the seed that makes it.
;;; LIBARCHIVE_FUZZ_ITERATIONS sets how many mutants per format (`make fuzz'
;;; runs many more than the suite's default).

(def-suite libarchive-fuzz :in libarchive-all)
(in-suite libarchive-fuzz)

(defun fuzz-iterations ()
  (or (ignore-errors (parse-integer (uiop:getenv "LIBARCHIVE_FUZZ_ITERATIONS"))) 40))

;;; A small PRNG of our own, so that a seed means the same mutant on every Lisp.
(defstruct (prng (:constructor make-prng (state)))
  (state 0 :type (unsigned-byte 64)))

(defun next-random (prng limit)
  "A pseudo-random integer in [0, LIMIT)."
  (let ((x (prng-state prng)))
    ;; xorshift64*
    (setf x (logxor x (ash x -12))
          x (logand (logxor x (ash x 25)) #xFFFFFFFFFFFFFFFF)
          x (logxor x (ash x -27)))
    (setf (prng-state prng) x)
    (mod (ash (logand (* x #x2545F4914F6CDD1D) #xFFFFFFFFFFFFFFFF) -11) (max limit 1))))

(defun mutate (octets seed)
  "A damaged copy of OCTETS, and what was done to it."
  (let* ((rng (make-prng (logior 1 (logand (* (1+ seed) #x9E3779B97F4A7C15)
                                                   #xFFFFFFFFFFFFFFFF))))
         (n (length octets))
         (copy (copy-seq octets)))
    (ecase (next-random rng 4)
      (0 (loop repeat (1+ (next-random rng 8))
               do (let ((i (next-random rng n)))
                    (setf (aref copy i) (logxor (aref copy i) (ash 1 (next-random rng 8))))))
         (values copy "bits flipped"))
      (1 (values (subseq copy 0 (next-random rng n)) "truncated"))
      (2 (let* ((start (next-random rng n))
                (end (min n (+ start 1 (next-random rng 64)))))
           (loop for i from start below end do (setf (aref copy i) (next-random rng 256)))
           (values copy "run overwritten")))
      (3 (let* ((start (next-random rng n))
                (end (min n (+ start 1 (next-random rng 512))))
                (chunk (subseq copy start end)))
           (values (coerce (concatenate 'vector (subseq copy 0 end) chunk (subseq copy end))
                           '(simple-array (unsigned-byte 8) (*)))
                   "chunk repeated"))))))

(defun fuzz-seed-archive (format filters &rest writer-keys)
  "A small archive with a bit of everything entries can carry."
  (let* ((w (apply #'open-archive-writer :octets :format format :filters filters writer-keys))
         ;; ar holds no directories and no / in names; warc no directories.
         (flat (member format '(:ar-bsd :ar-svr4 :warc)))
         (dir (if flat "" "dir/")))
    (flet ((add (name &rest keys)
             (apply #'add-entry w (concatenate 'string dir name) :mtime +sample-mtime+ keys)))
      (unwind-protect
           (if (eq format :raw)
               (add-entry w "data" :data (random-octets 3000 7))
               (progn
                 (unless flat (add-entry w dir :mtime +sample-mtime+))
                 (add "text.txt" :data (format nil "~{line ~D~%~}" (loop for i below 40 collect i))
                                 :uname "user" :gname "group")
                 (add "bytes.bin" :data (random-octets 3000 7) :perm #o600)
                 (add (format nil "caf~C ~C.txt" (code-char #xE9) (code-char #x2603))
                      :data "unicode name")
                 (unless (member format '(:ar-bsd :ar-svr4 :warc :shar))
                   (add "link" :symlink "text.txt"))))
        (close-archive w)))
    (writer-octets w)))

(defparameter *fuzz-formats*
  '(("tar" :pax-restricted ())
    ("ustar.gz" :ustar (:gzip))
    ("gnutar.bz2" :gnutar (:bzip2))
    ("tar.xz" :pax-restricted (:xz))
    ("tar.zst" :pax-restricted (:zstd))
    ("tar.lz4" :pax-restricted (:lz4))
    ("zip" :zip ())
    ("zip stored" :zip () :options (("zip:compression" . "store")))
    ("zip aes" :zip () :options (("zip:encryption" . "aes256")) :passphrase "secret")
    ("7z" :7zip ())
    ("cpio" :cpio-newc ())
    ("iso9660" :iso9660 ())
    ("ar" :ar-svr4 ())
    ("warc" :warc ())
    ("mtree" :mtree ())
    ("xar" :xar ())
    ("raw gz" :raw (:gzip))))

(defun read-everything (source &key passphrase)
  "Read SOURCE to the end as an archive, touching every entry's metadata and
data. Stops at an ARCHIVE-CONDITION, which is the expected way to fail."
  (let ((buffer (make-array 8192 :element-type '(unsigned-byte 8))))
    (handler-case
        (handler-bind ((archive-warning #'muffle-warning))
          (with-archive-reader (r source :formats '(:all :raw) :passphrase passphrase)
            (loop for e = (next-entry r)
                  for count from 0
                  ;; Bounds, in case damage makes a format loop or inflate.
                  while (and e (< count 1000))
                  do (list (entry-pathname e) (entry-size e) (entry-type e) (entry-mode e)
                           (entry-mtime e) (entry-uname e) (entry-gname e) (entry-symlink e)
                           (entry-hardlink e) (entry-xattrs e) (entry-strmode e)
                           (entry-data-encrypted-p e))
                     (loop for total = 0 then (+ total n)
                           for n = (read-entry-data-into r buffer)
                           until (or (zerop n) (> total 50000000))))
            (list (archive-format-name r) (archive-filter-names r))))
      (archive-condition () nil))))

(defun fuzz-format (label format filters &rest writer-keys)
  "Read the mutants of one seed archive; return a list of failures."
  (let* ((passphrase (getf writer-keys :passphrase))
         (seed-archive (handler-case (apply #'fuzz-seed-archive format filters writer-keys)
                         ;; Not in this build (xar without libxml2, say).
                         (archive-error () (return-from fuzz-format :skipped))))
         (failures '()))
    (dotimes (seed (fuzz-iterations) (nreverse failures))
      (multiple-value-bind (mutant how) (mutate seed-archive seed)
        (dolist (via '(:memory :stream))
          (handler-case
              (read-everything (if (eq via :memory) mutant (make-octet-input-stream mutant))
                               :passphrase passphrase)
            (error (c)
              (push (format nil "~A seed ~D (~A, from ~(~A~)): ~S ~A"
                            label seed how via (type-of c) c)
                    failures))))))))

(test damaged-archives-fail-cleanly
  (dolist (spec *fuzz-formats*)
    (destructuring-bind (label format filters &rest keys) spec
      (let ((failures (apply #'fuzz-format label format filters keys)))
        (if (eq failures :skipped)
            (skip "~A: not supported by this libarchive" label)
            (is (null failures) "~{~A~^~%~}" (subseq failures 0 (min 10 (length failures)))))))))

(test undamaged-seeds-read
  ;; The fuzzing proves nothing if the seeds themselves do not read.
  (dolist (spec *fuzz-formats*)
    (destructuring-bind (label format filters &rest keys) spec
      (let ((archive (handler-case (apply #'fuzz-seed-archive format filters keys)
                       (archive-error () nil))))
        (when archive
          (is (consp (read-everything archive :passphrase (getf keys :passphrase)))
              "~A: the undamaged archive did not read" label))))))
