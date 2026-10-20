;;; la l: list.  la t: test.  la i: describe.

(in-package #:libarchive/cli)

(defun reader-for (archive cmd name)
  (open-archive-reader archive :formats '(:all :raw)
                               :passphrase (reader-passphrase
                                            (passphrase-source cmd (display-name name)))))

(defun one-archive (cmd verb)
  (let ((args (clingon:command-arguments cmd)))
    (unless (= 1 (length args))
      (usage-error "~A takes one archive (see la ~A --help)" verb verb))
    (first args)))

;;; list

(defun long-line (e)
  (format nil "~A ~8A ~8A ~12@A ~A ~A~@[ -> ~A~]~@[ link to ~A~]"
          (entry-strmode e)
          (or (entry-uname e) (entry-uid e)) (or (entry-gname e) (entry-gid e))
          (or (entry-size e) "-") (iso-time (entry-mtime e)) (entry-pathname e)
          (entry-symlink e) (entry-hardlink e)))

(defun list/handler (cmd)
  (let ((name (one-archive cmd "l"))
        (long (clingon:getopt cmd :long)))
    (call-with-input-archive
     name
     (lambda (archive)
       (let ((r (reader-for archive cmd name)))
         (unwind-protect
              (do-archive-entries (e r)
                (write-line (if long (long-line e) (entry-pathname e))))
           (close-archive r)))))
    0))

;;; test

(defun test/handler (cmd)
  (let ((name (one-archive cmd "t"))
        (*quiet* (clingon:getopt cmd :quiet))
        (verbose (clingon:getopt cmd :verbose))
        (entries 0) (bytes 0) (bad 0))
    (call-with-input-archive
     name
     (lambda (archive)
       (let ((r (reader-for archive cmd name))
             (buffer (make-array 65536 :element-type '(unsigned-byte 8))))
         (unwind-protect
              (do-archive-entries (e r)
                (incf entries)
                (handler-case
                    (progn
                      (loop for n = (read-entry-data-into r buffer)
                            until (zerop n)
                            do (incf bytes n))
                      (when verbose (format t "ok  ~A~%" (entry-pathname e))))
                  (archive-fatal-error (c) (error c))
                  (archive-error (c)
                    (incf bad)
                    (format t "BAD ~A: ~A~%" (entry-pathname e)
                            (or (archive-condition-message c) c)))))
           (close-archive r)))))
    (if (zerop bad)
        (note "~A: OK, ~D entr~:@P, ~A" (display-name name) entries (human-size bytes))
        (warn-user "~A: ~D of ~D entr~:@P damaged" (display-name name) bad entries))
    (if (zerop bad) 0 1)))

;;; info

(defun info/handler (cmd)
  (let ((name (one-archive cmd "i")))
    (call-with-input-archive
     name
     (lambda (archive)
       (let ((r (reader-for archive cmd name))
             (counts '()) (total 0) (unknown-sizes 0) (roots '()) (encrypted nil))
         (unwind-protect
              (progn
                (do-archive-entries (e r)
                  (let ((type (cond ((entry-hardlink e) :hardlink)
                                    ((entry-type e))
                                    (t :other))))
                    (incf (getf counts type 0)))
                  (let ((size (entry-size e)))
                    (if size (incf total size) (incf unknown-sizes)))
                  (when (or (entry-data-encrypted-p e) (entry-metadata-encrypted-p e))
                    (setf encrypted t))
                  (let ((root (entry-root (entry-pathname e))))
                    (when root (pushnew root roots :test #'string=))))
                (let ((archive-size (with-open-file (in archive :element-type '(unsigned-byte 8))
                                      (file-length in))))
                  (format t "~&Archive:     ~A~%" (display-name name))
                  (format t "Format:      ~A~%" (or (archive-format-name r) "unknown"))
                  (format t "Compression: ~:[none~;~:*~{~A~^ + ~}~]~%" (archive-filter-names r))
                  (format t "Entries:     ~D~@[ (~{~D ~(~A~)~^, ~})~]~%"
                          (archive-file-count r)
                          (loop for (type n) on counts by #'cddr
                                append (list n (if (= n 1) type
                                                   (case type
                                                     (:directory "directories")
                                                     (t (format nil "~(~A~)s" type)))))))
                  (format t "Top level:   ~D~@[ (~{~A~^, ~})~]~%" (length roots)
                          (and (<= (length roots) 5) roots))
                  (format t "Contents:    ~A~@[ (~D entries of unknown size)~]~%"
                          (human-size total) (and (plusp unknown-sizes) unknown-sizes))
                  (format t "On disk:     ~A~@[ (~,1F%)~]~%" (human-size archive-size)
                          (and (plusp total) (* 100.0 (/ archive-size total))))
                  (format t "Encrypted:   ~:[no~;yes~]~%" encrypted)))
           (close-archive r)))))
    0))

(register-command
 "list"
 (lambda ()
   (clingon:make-command
    :name "list" :aliases '("l" "ls")
    :usage "[options] ARCHIVE"
    :description "list the entries of an archive"
    :options (list (clingon:make-option :flag :short-name #\l :long-name "long" :key :long
                                              :description "mode, owner, size, time and links too")
                   (clingon:make-option :string :short-name #\p :long-name "passphrase"
                                                :key :passphrase :parameter "PASS"
                                                :description "passphrase, if the names are encrypted"))
    :handler #'list/handler)))

(register-command
 "test"
 (lambda ()
   (clingon:make-command
    :name "test" :aliases '("t")
    :usage "[options] ARCHIVE"
    :description "read every entry, checking checksums and decryption"
    :options (list (clingon:make-option :string :short-name #\p :long-name "passphrase"
                                                :key :passphrase :parameter "PASS"
                                                :description "passphrase for encrypted entries")
                   (clingon:make-option :flag :short-name #\v :long-name "verbose" :key :verbose
                                              :description "print each entry checked")
                   (clingon:make-option :flag :short-name #\q :long-name "quiet" :key :quiet
                                              :description "no summary line"))
    :handler #'test/handler)))

(register-command
 "info"
 (lambda ()
   (clingon:make-command
    :name "info" :aliases '("i")
    :usage "[options] ARCHIVE"
    :description "show an archive's format, compression and sizes"
    :options (list (clingon:make-option :string :short-name #\p :long-name "passphrase"
                                                :key :passphrase :parameter "PASS"
                                                :description "passphrase, if the names are encrypted"))
    :handler #'info/handler)))
