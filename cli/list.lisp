;;; la l: list.  la t: test.  la i: describe.

(in-package #:libarchive/cli)

(defun reader-for (archive cmd name)
  ;; A bare compressed file is one by its name, as for la x: decompressed
  ;; zeros, say, would otherwise read as an empty tar.
  (open-archive-reader archive :formats (if (eq :raw (archive-kind name)) '(:raw) '(:all :raw))
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

(defun json-string (string stream)
  (write-char #\" stream)
  (loop for c across string
        do (case c
             (#\" (write-string "\\\"" stream))
             (#\\ (write-string "\\\\" stream))
             (#\Newline (write-string "\\n" stream))
             (#\Return (write-string "\\r" stream))
             (#\Tab (write-string "\\t" stream))
             (t (if (< (char-code c) 32)
                    (format stream "\\u~4,'0X" (char-code c))
                    (write-char c stream)))))
  (write-char #\" stream))

(defun json-object (pairs stream)
  "Write PAIRS, a plist of keyword and value, as a JSON object. A value is a
string, an integer, T or :FALSE, or NIL for null."
  (write-char #\{ stream)
  (loop for (key value) on pairs by #'cddr
        for first = t then nil
        do (unless first (write-string ", " stream))
           (json-string (string-downcase (substitute #\_ #\- (symbol-name key))) stream)
           (write-string ": " stream)
           (cond ((null value) (write-string "null" stream))
                 ((eq value t) (write-string "true" stream))
                 ((eq value :false) (write-string "false" stream))
                 ((stringp value) (json-string value stream))
                 (t (format stream "~D" value))))
  (write-char #\} stream))

(defun json-time (universal-time)
  (and universal-time
       (multiple-value-bind (sec min hour day month year) (decode-universal-time universal-time 0)
         (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ" year month day hour min sec))))

(defun entry-json (e stream)
  (json-object
   (list :name (entry-pathname e)
         :type (cond ((entry-hardlink e) "hardlink")
                     ((eq (entry-type e) :regular) "file")
                     ((entry-type e) (string-downcase (entry-type e)))
                     (t nil))
         :size (entry-size e)
         :mode (format nil "~4,'0O" (logand #o7777 (entry-perm e)))
         :mtime (json-time (entry-mtime e))
         :uid (entry-uid e) :gid (entry-gid e)
         :uname (entry-uname e) :gname (entry-gname e)
         :link (or (entry-symlink e) (entry-hardlink e))
         :encrypted (if (entry-data-encrypted-p e) t :false))
   stream))

(defun list/handler (cmd)
  (let ((name (one-archive cmd "l"))
        (long (clingon:getopt cmd :long))
        (json (clingon:getopt cmd :json))
        (count 0))
    (when (and long json) (usage-error "-l and --json do not go together"))
    (call-with-input-archive
     name
     (lambda (archive)
       (call-with-entry-match
        cmd
        (lambda (match)
          (let ((r (reader-for archive cmd name)))
            (unwind-protect
                 (progn
                   (when json (write-string "[" *standard-output*))
                   (do-archive-entries (e r)
                     (when (or (null match) (entry-matches-p match e))
                       (cond (json
                              (format t "~:[,~;~]~%  " (zerop count))
                              (entry-json e *standard-output*))
                             (long (say "~A" (long-line e)))
                             (t (say "~A" (entry-pathname e))))
                       (incf count)))
                   (when json (format t "~:[~%~;~]]~%" (zerop count))))
              (close-archive r)))))))
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
                      (when verbose (say "ok  ~A" (entry-pathname e))))
                  (archive-fatal-error (c) (error c))
                  (archive-error (c)
                    (incf bad)
                    (say "BAD ~A: ~A" (entry-pathname e)
                            (archive-message c)))))
           (close-archive r)))))
    (if (zerop bad)
        (note "~A: OK, ~D entr~:@P, ~A" (display-name name) entries (human-size bytes))
        (warn-user "~A: ~D of ~D entr~:@P damaged" (display-name name) bad entries))
    (if (zerop bad) 0 1)))

;;; cat

(defvar *cat-output* nil
  "Where la cat writes, a binary output stream; NIL for standard output.")

(defun cat/handler (cmd)
  (let ((args (clingon:command-arguments cmd)))
    (when (null args)
      (usage-error "cat takes an archive, and optionally the entries to print (see la cat --help)"))
    (destructuring-bind (name &rest patterns) args
      (let ((out (or *cat-output* (stdout-octets)))
            (passphrase (passphrase-source cmd (display-name name))))
        (multiple-value-bind (selected unused) (make-selector patterns)
          (unwind-protect
               (call-with-input-archive
                name
                (lambda (archive)
                  (call-with-entry-match
                   cmd
                   (lambda (match)
                     ;; A bare compressed file, by its name (see la x) or as
                     ;; read, is printed decompressed.
                     (let ((raw-by-name (eq :raw (archive-kind name)))
                           (chosen (entry-chooser selected match)))
                       (with-archive-reader (r archive :formats (if raw-by-name '(:raw) '(:all :raw))
                                                       :passphrase (reader-passphrase passphrase))
                         (do-archive-entries (e r)
                           (cond ((equal (archive-format-name r) "raw")
                                  (when patterns
                                    (usage-error "~A is a compressed file, not an archive: there ~
                                                  are no entries to choose" (display-name name)))
                                  (copy-entry-data r out))
                                 ((and (eq (entry-type e) :regular) (funcall chosen e))
                                  (copy-entry-data r out))))))))))
            (finish-output out))
          (let ((missing (funcall unused)))
            (when missing
              (fail "~{~A~^, ~}: not in ~A" missing (display-name name)))))
        0))))

;;; info

(defun info/handler (cmd)
  (let ((name (one-archive cmd "i")))
    (call-with-input-archive
     name
     (lambda (archive)
       (let ((r (reader-for archive cmd name))
             (counts '()) (total 0) (unknown-sizes 0) (roots '()) (encrypted nil)
             (seen (make-hash-table :test #'equal)))
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
                    (when (and root (not (gethash root seen)))
                      (setf (gethash root seen) t)
                      (push root roots))))
                (let ((archive-size (with-open-file (in archive :element-type '(unsigned-byte 8))
                                      (file-length in))))
                  (say "Archive:     ~A" (display-name name))
                  (format t "Format:      ~A~%" (or (archive-format-name r) "unknown"))
                  (format t "Compression: ~:[none~;~:*~{~A~^ + ~}~]~%" (archive-filter-names r))
                  (format t "Entries:     ~D~@[ (~{~D ~(~A~)~^, ~})~]~%"
                          (archive-file-count r)
                          (loop for (type n) on counts by #'cddr
                                append (list n (if (= n 1) type
                                                   (case type
                                                     (:directory "directories")
                                                     (t (format nil "~(~A~)s" type)))))))
                  (say "Top level:   ~D~@[ (~{~A~^, ~})~]" (length roots)
                          (and (<= (length roots) 5) roots))
                  (format t "Contents:    ~A~@[ (~D entr~:@P of unknown size)~]~%"
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
    :long-description "--json writes a JSON array with an object for each entry: name, type (file, directory, symlink, hardlink, ...), size, mode (octal), mtime (UTC, ISO 8601), uid, gid, uname, gname, link (a symlink's or hard link's target) and encrypted. A value libarchive does not have is null."
    :options (list* (clingon:make-option :flag :short-name #\l :long-name "long" :key :long
                                               :description "mode, owner, size, time and links too")
                    (clingon:make-option :flag :long-name "json" :key :json
                                               :description "JSON, for programs")
                    (clingon:make-option :string :short-name #\p :long-name "passphrase"
                                                 :key :passphrase :parameter "PASS"
                                                 :description "passphrase, if the names are encrypted")
                    (match-options))
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
 "cat"
 (lambda ()
   (clingon:make-command
    :name "cat"
    :usage "[options] ARCHIVE [ENTRY...]"
    :description "write files from an archive to standard output"
    :long-description "In archive order: those ENTRYs name (names or globs; a directory brings what is under it), or all of them. A compressed file (x.txt.gz) is written decompressed."
    :options (list* (clingon:make-option :string :short-name #\p :long-name "passphrase"
                                                 :key :passphrase :parameter "PASS"
                                                 :description "passphrase for encrypted entries")
                    (match-options))
    :handler #'cat/handler)))

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
