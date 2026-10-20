;;; Streams and memory: archives that never touch a named file, and entry data
;;; read in pieces.
;;;
;;;   make example NAME=streams
;;;
;;; A reader's source and a writer's target can each be a pathname, an octet vector
;;; (or :OCTETS for a writer), or any binary Lisp stream -- including one you write
;;; yourself, like the Gray stream below, which libarchive reaches through callbacks.

(defpackage #:libarchive-examples/streams
  (:use #:cl #:libarchive))

(in-package #:libarchive-examples/streams)

(defmacro with-scratch-directory ((var) &body body)
  `(let ((,var (uiop:ensure-directory-pathname
                (format nil "~Alibarchive-example-~36R/"
                        (uiop:native-namestring (uiop:temporary-directory))
                        (random (expt 36 8) (make-random-state t))))))
     (ensure-directories-exist ,var)
     (unwind-protect (progn ,@body)
       (uiop:delete-directory-tree ,var :validate t :if-does-not-exist :ignore))))

;;; A binary input stream that hands out at most CHUNK bytes per read, and
;;; cannot seek: a stand-in for a socket or a pipe.
(defclass trickle-stream (sb-gray:fundamental-binary-input-stream)
  ((data :initarg :data)
   (position :initform 0)
   (chunk :initarg :chunk :initform 1000)
   (reads :initform 0 :reader trickle-reads)))

(defmethod stream-element-type ((s trickle-stream)) '(unsigned-byte 8))

(defmethod sb-gray:stream-read-sequence ((s trickle-stream) seq &optional (start 0) end)
  (with-slots (data position chunk reads) s
    (incf reads)
    (let ((n (min chunk (- (or end (length seq)) start) (- (length data) position))))
      (replace seq data :start1 start :end1 (+ start n) :start2 position)
      (incf position n)
      (+ start n))))

(defun octets-of (string) (babel:string-to-octets string :encoding :utf-8))

(defun main ()
  (with-scratch-directory (dir)
    (let* ((big (let ((v (make-array 200000 :element-type '(unsigned-byte 8))))
                  (dotimes (i (length v) v) (setf (aref v i) (mod (* i 7) 251)))))
           (latin (babel:string-to-octets "Grüße aus Köln" :encoding :latin-1))
           (archive
             ;; 1. Write to a Lisp stream: here a file stream, but a socket works too.
             ;; FILTERS on a stream works exactly as on a file.
             (let ((path (merge-pathnames "via-stream.tar.xz" dir)))
               (with-open-file (out path :direction :output :element-type '(unsigned-byte 8))
                 (with-archive-writer (w out :format :pax-restricted :filters :xz)
                   (add-entry w "big.bin" :data big)
                   (add-entry w "latin1.txt" :data latin)
                   ;; Data from a stream of unknown length: tar needs the size up
                   ;; front, so ADD-ENTRY reads it all first. Give :SIZE to avoid that.
                   (add-entry w "from-stream.txt"
                              :data (make-instance 'trickle-stream :data (octets-of "trickled in")))
                   (add-entry w "sized.txt" :size 5
                              :data (make-instance 'trickle-stream :data (octets-of "sized")))))
               path)))

      ;; 2. Read from a seekable file stream. libarchive is given skip and seek
      ;; callbacks, so skipping big.bin does not read it.
      (with-open-file (in archive :element-type '(unsigned-byte 8))
        (with-archive-reader (r in)
          (do-archive-entries (e r)
            (format t "~&~A (~D bytes)~%" (entry-pathname e) (entry-size e))
            (cond ((string= (entry-pathname e) "big.bin")
                   (skip-entry-data r))
                  ((string= (entry-pathname e) "latin1.txt")
                   ;; Entry data is octets; decode it as whatever it is.
                   (let ((text (read-entry-string r :encoding :latin-1)))
                     (format t "  decoded as Latin-1: ~A~%" text)
                     (assert (string= text "Grüße aus Köln"))))
                  (t (format t "  ~S~%" (read-entry-string r)))))
          (format t "Read ~D entries.~%" (archive-file-count r))))

      ;; 3. Read from an unseekable stream, 1000 bytes at a time.
      (let ((s (make-instance 'trickle-stream
                              :data (with-open-file (in archive :element-type '(unsigned-byte 8))
                                      (let ((v (make-array (file-length in)
                                                           :element-type '(unsigned-byte 8))))
                                        (read-sequence v in)
                                        v)))))
        (with-archive-reader (r s)
          (do-archive-entries (e r)
            (when (string= (entry-pathname e) "big.bin")
              ;; Entry data in pieces, into a buffer you own, like READ-SEQUENCE.
              (let ((buffer (make-array 65536 :element-type '(unsigned-byte 8)))
                    (total 0)
                    (pieces 0))
                (loop for end = (read-entry-data-into r buffer)
                      until (zerop end)
                      do (assert (equalp (subseq buffer 0 end) (subseq big total (+ total end))))
                         (incf total end)
                         (incf pieces))
                (format t "~&big.bin read in ~D pieces, ~D bytes~%" pieces total)
                (assert (= total (length big)))))))
        (format t "The unseekable source was read ~D times.~%" (trickle-reads s)))

      ;; 4. Copy entry data straight to an output stream.
      (let ((copy (merge-pathnames "big.copy" dir)))
        (with-archive-reader (r archive)
          (next-entry r)
          (with-open-file (out copy :direction :output :element-type '(unsigned-byte 8))
            (format t "~&COPY-ENTRY-DATA wrote ~D bytes~%" (copy-entry-data r out))))
        (with-open-file (in copy :element-type '(unsigned-byte 8))
          (assert (= (file-length in) (length big)))))

      ;; 5. Memory to memory: :OCTETS out, a vector back in. WRITER-OCTETS gives
      ;; the result once the writer is closed.
      (let ((w (open-archive-writer :octets :format :zip)))
        (add-entry w "one.txt" :data "one")
        (add-entry w "two.txt" :data "two")
        (close-archive w)
        (let ((zip (writer-octets w)))
          (format t "~&In-memory zip: ~D bytes, entries ~S~%" (length zip) (archive-entry-names zip))
          (with-archive-reader (r zip)
            (next-entry r)
            (assert (equalp (read-entry-data r) (octets-of "one")))))))))

(main)
