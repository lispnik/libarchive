;;; la rm: remove entries from an archive.
;;;
;;; libarchive cannot edit an archive in place, so this writes a new one
;;; without the entries named, in the same format, compression and encryption,
;;; and renames it over the original (REWRITE-ARCHIVE, as la a -r does).

(in-package #:libarchive/cli)

(defun remove/handler (cmd)
  (let ((args (clingon:command-arguments cmd))
        (*quiet* (clingon:getopt cmd :quiet))
        (verbose (clingon:getopt cmd :verbose)))
    (when (< (length args) 2)
      (usage-error "rm takes an archive and the entries to remove (see la rm --help)"))
    (destructuring-bind (archive-name &rest patterns) args
      (when (stdio-p archive-name)
        (usage-error "rm needs an archive file, not standard input"))
      (unless (lexists-p (user-file archive-name))
        (fail "~A: no such file" archive-name))
      (multiple-value-bind (format filters options passphrase) (writer-settings cmd archive-name)
        (when (eq format :raw)
          (usage-error "~A is a compressed file, not an archive: there are no entries to remove"
                       archive-name))
        ;; Every name must match something before anything is rewritten.
        (multiple-value-bind (selected unused) (make-selector patterns)
          (with-archive-reader (r (user-file archive-name)
                                :passphrase (reader-passphrase (passphrase-source cmd archive-name)))
            (do-archive-entries (e r)
              (funcall selected (entry-pathname e))))
          (let ((missing (funcall unused)))
            (when missing
              (fail "~{~A~^, ~}: not in ~A" missing archive-name))))
        (multiple-value-bind (kept removed)
            (rewrite-archive cmd archive-name
                             (list :format format :filters filters :options options
                                   :passphrase passphrase)
                             :keep (lambda (name)
                                     (let ((drop (some (lambda (p) (selects-p p name)) patterns)))
                                       (when (and drop verbose) (say "~A" name))
                                       (not drop))))
          (note "~A: ~D entr~:@P removed, ~D kept, ~A" archive-name removed kept
                (human-size (file-size (user-file archive-name))))
          0)))))

(register-command
 "remove"
 (lambda ()
   (clingon:make-command
    :name "remove"
    :aliases '("rm")
    :usage "[options] ARCHIVE ENTRY..."
    :description "remove entries from an archive"
    :long-description "Each ENTRY is a name or a glob, and a directory takes everything under it. The archive is rewritten in its format, which comes from its name unless -F says otherwise."
    :options (list (clingon:make-option :string :short-name #\F :long-name "format" :key :format
                                                :parameter "FORMAT"
                                                :description "the archive's format, if its name does not say")
                   (clingon:make-option :list :short-name #\z :long-name "compression"
                                              :key :compression :parameter "FILTER"
                                              :description "its compression, with -F (repeatable)")
                   (clingon:make-option :string :short-name #\p :long-name "passphrase"
                                                :key :passphrase :parameter "PASS"
                                                :description "passphrase of an encrypted zip (it stays encrypted)")
                   (clingon:make-option :flag :short-name #\v :long-name "verbose" :key :verbose
                                              :description "print each name removed")
                   (clingon:make-option :flag :short-name #\q :long-name "quiet" :key :quiet
                                              :description "no summary line"))
    :handler #'remove/handler)))
