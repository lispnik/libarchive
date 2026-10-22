;;; la convert: the same entries in another format or compression.
;;;
;;; Every entry is copied with TRANSFER-ENTRY, so nothing goes through the
;;; disk: names, modes, times, owners, links and extended attributes come
;;; across as the output format can hold them. The new archive is written
;;; beside OUT and renamed into place, so OUT may be IN (recompressing in place).

(in-package #:libarchive/cli)

(defun convert-raw-input (r w e in-name archive)
  "Write the decompressed contents of a bare compressed file, the reader R's
one entry E, to W as a file named after IN-NAME."
  (let ((name (if (stdio-p in-name) "data" (archive-stem in-name)))
        (mtime (or (entry-mtime e)
                   (and (not (stdio-p in-name)) (file-write-date archive))
                   (get-universal-time))))
    (setf (entry-pathname e) name
          (entry-mtime e) mtime)
    (if (= (archive-format-code w) +archive-format-raw+)
        (transfer-entry r w e)
        ;; Archive formats want the size first, and a compressed file does not
        ;; say how big it is: decompress it to a temporary file to find out.
        (uiop:with-temporary-file (:pathname spool :type "la" :element-type '(unsigned-byte 8)
                                   :stream s)
          (copy-entry-data r s)
          :close-stream
          (add-entry w name :data spool :mtime mtime :perm #o644)))
    name))

(defun convert-entries (archive in-name out-name output writer-keys source match verbose)
  "Copy the entries of ARCHIVE to a new archive on OUTPUT. Returns the number of
entries written and whether any of them were encrypted in the original."
  (let ((format (getf writer-keys :format))
        (count 0) (files 0) (encrypted nil))
    (with-archive-reader (r archive :formats (if (eq :raw (archive-kind in-name)) '(:raw) '(:all :raw))
                                    :passphrase (reader-passphrase source))
      (call-with-writer
       output writer-keys
       (lambda (w)
         (do-archive-entries (e r)
           (let ((name
                   (cond ((equal (archive-format-name r) "raw")
                          (incf files)
                          (convert-raw-input r w e in-name archive))
                         ((and match (not (entry-matches-p match e))) nil)
                         ;; What the output cannot hold is left out: directories
                         ;; for warc and ar (their files still go in), and
                         ;; everything but the file for a bare compressed file.
                         ((and (eq (entry-type e) :directory)
                               (member format *formats-without-directories*))
                          nil)
                         ((and (eq format :raw) (not (eq (entry-type e) :regular))) nil)
                         (t
                          (when (eq (entry-type e) :regular)
                            (incf files)
                            (when (and (eq format :raw) (> files 1))
                              (fail "~A holds more than one file; a compressed file holds just ~
                                     one (name the output .tar~A, say)"
                                    (display-name in-name)
                                    (or (nth-value 2 (archive-kind out-name)) ".gz"))))
                          (when (entry-data-encrypted-p e) (setf encrypted t))
                          (prog1 (entry-pathname e)
                            (transfer-entry r w e))))))
             (when name
               (incf count)
               (when verbose (say "~A" name)))))
         (when (and (eq format :raw) (zerop files))
           (fail "~A has no file in it to compress" (display-name in-name))))))
    (values count encrypted)))

(defun convert/handler (cmd)
  (let ((args (clingon:command-arguments cmd))
        (*quiet* (clingon:getopt cmd :quiet))
        (verbose (clingon:getopt cmd :verbose)))
    (unless (= 2 (length args))
      (usage-error "convert takes an archive and the name of the one to make from it ~
                    (see la convert --help)"))
    (destructuring-bind (in-name out-name) args
      ;; -p reads IN. OUT is encrypted with it too if it is a zip, the one
      ;; format libarchive encrypts; otherwise it is written decrypted.
      (multiple-value-bind (format filters options) (writer-settings cmd out-name :passphrase nil)
        (let* ((given (passphrase-from cmd))
               (encrypt (and given (eq format :zip)))
               (writer-keys (list :format format :filters filters
                                  :options (if encrypt
                                               (append options '(("zip:encryption" . "aes256")))
                                               options)
                                  :passphrase (and encrypt given)))
               (target (unless (stdio-p out-name) (user-file out-name)))
               (source (passphrase-source cmd (display-name in-name))))
          (when (and target (lexists-p target) (not (clingon:getopt cmd :force)))
            (fail "~A already exists (use -f to replace it)" out-name))
          (when (and target (uiop:directory-exists-p target))
            (fail "~A is a directory" out-name))
          (call-with-input-archive
           in-name
           (lambda (archive)
             (call-with-entry-match
              cmd
              (lambda (match)
                (flet ((convert (output)
                         (convert-entries archive in-name out-name output writer-keys
                                          source match verbose)))
                  (multiple-value-bind (count encrypted)
                      (if target
                          (call-with-replacement target #'convert)
                          (let ((out (stdout-octets)))
                            (multiple-value-prog1 (convert out) (finish-output out))))
                    (when (and encrypted (not encrypt))
                      (warn-user "~A is not encrypted~:[; only zip can be (with -p)~;~]"
                                 (display-name out-name) (eq format :zip)))
                    (note "~A: ~D entr~:@P~@[, ~A~]" (if target out-name "standard output") count
                          (and target (human-size (file-size target))))))))))
          0)))))

(register-command
 "convert"
 (lambda ()
   (clingon:make-command
    :name "convert"
    :aliases '("cv")
    :usage "[options] IN OUT"
    :description "copy an archive into another format or compression"
    :long-description "OUT's name picks its format and compression, as for la a, unless -F says otherwise. Entries come across as they are, with their names, modes, times, owners and links, as far as OUT's format can store them. OUT may be IN itself (la convert -f -l 19 x.tar.zst x.tar.zst), since it is written beside OUT and renamed into place. A compressed file converts to another compression (x.gz to x.xz), or into an archive holding it, and an archive with one file in it to a compressed file. With -p, an encrypted IN is read, and OUT is encrypted with the same passphrase if it is a zip; any other format is written decrypted."
    :options (list* (clingon:make-option :string :short-name #\F :long-name "format" :key :format
                                                 :parameter "FORMAT"
                                                 :description "OUT's format (see la a --help)")
                    (clingon:make-option :list :short-name #\z :long-name "compression"
                                               :key :compression :parameter "FILTER"
                                               :description "OUT's compression, none for none (repeatable)")
                    (clingon:make-option :integer :short-name #\l :long-name "level" :key :level
                                                  :parameter "N" :description "compression level")
                    (clingon:make-option :integer :short-name #\T :long-name "threads" :key :threads
                                                  :parameter "N"
                                                  :description "compress with N threads (zstd, xz; 0: one per CPU)")
                    (clingon:make-option :string :short-name #\p :long-name "passphrase"
                                                 :key :passphrase :parameter "PASS"
                                                 :description "IN's passphrase (and OUT's, for a zip)")
                    (clingon:make-option :flag :short-name #\f :long-name "force" :key :force
                                               :description "replace OUT if it exists")
                    (clingon:make-option :flag :short-name #\v :long-name "verbose" :key :verbose
                                               :description "print each name as it is copied")
                    (clingon:make-option :flag :short-name #\q :long-name "quiet" :key :quiet
                                               :description "no summary line")
                    (match-options))
    :handler #'convert/handler)))
