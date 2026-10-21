;;; The top-level command, dispatch, and turning conditions into exit codes.

(in-package #:libarchive/cli)

(defparameter *version* "0.2.0")

;;; Each command file calls REGISTER-COMMAND with a function that makes its
;;; clingon command. The top-level command is built afresh on every RUN, so the
;;; files can load in any order and nothing is computed at load time.

(defvar *command-makers* '())

(defun register-command (name maker)
  (setf *command-makers*
        (append (remove name *command-makers* :key #'car :test #'string=)
                (list (cons name maker)))))

(defparameter *command-order* '("extract" "add" "list" "test" "info" "diff"))

(defun top-level-command ()
  (clingon:make-command
   :name "la"
   :version (format nil "~A~%~A (~A)" *version* (version-details) *libarchive-origin*)
   :description "extract, create, list and test archives of every kind libarchive knows"
   :long-description
   "la x ARCHIVE [ENTRY...]  extract (several roots: into a new directory)
la a ARCHIVE FILE...     create; the format comes from the name
la a -r ARCHIVE FILE...  add to it, replacing entries of the same name
la l ARCHIVE             list (-l for the long form)
la t ARCHIVE             read everything, checking the data
la i ARCHIVE             format, compression and sizes
la diff ARCHIVE          compare with the files here (-C DIR: there)

Writes tar (pax, ustar, gnu, v7), zip, 7z, cpio, iso9660, xar,
ar, shar, mtree and warc; reads those and rar, cab and lha too.
Compression: gzip, bzip2, xz, lzma, zstd, lz4, lzip, compress.
A compressed file that is not an archive (x.txt.gz) extracts
to x.txt, and `la a x.txt.gz x.txt' makes one.

ARCHIVE may be - for standard input, or standard output with -F.
LA_PASSPHRASE is used when -p is not given."
   :sub-commands (loop for name in *command-order*
                       for maker = (cdr (assoc name *command-makers* :test #'string=))
                       when maker collect (funcall maker))
   :handler (lambda (cmd)
              (clingon:print-usage cmd *error-output*)
              2)))

(defun report (control &rest args)
  (format *error-output* "~&la: ~?~%" control args))

(defun option-name (option)
  (string-trim " " (clingon:option-usage-details :default option)))

(defun run (arguments)
  "Run la with ARGUMENTS (argv without the program name); return the exit code.
Never exits, so tests can call it."
  (handler-bind ((archive-warning (lambda (c)
                                    (report "warning: ~A" (or (archive-condition-message c) c))
                                    (muffle-warning c)))
                 (error (lambda (c)
                          (declare (ignore c))
                          ;; LA_DEBUG=1 for a backtrace on unexpected errors.
                          (when (uiop:getenv "LA_DEBUG")
                            (sb-debug:print-backtrace :stream *error-output* :count 40)))))
    (handler-case
        (let* ((cmd (clingon:parse-command-line (top-level-command) arguments))
               (result (funcall (clingon:command-handler cmd) cmd)))
          (if (integerp result) result 0))
      (clingon:exit-error (c) (clingon:exit-error-code c))
      (clingon:unknown-option (c)
        (report "unknown option ~A (see la --help)" (clingon:unknown-option-name c))
        2)
      (clingon:missing-option-argument (c)
        (report "~A needs a value" (option-name (clingon:missing-option-argument-item c)))
        2)
      (clingon:invalid-option (c)
        (report "~A" c)
        2)
      (cli-error (c)
        (report "~A" c)
        (cli-error-code c))
      (archive-error (c)
        (report "~A" (or (archive-condition-message c) c))
        1)
      (sb-int:broken-pipe () 0)
      (sb-sys:interactive-interrupt () 130)
      (error (c)
        (report "~A" c)
        1))))

(defun main ()
  "The la binary's entry point."
  (choose-libarchive)
  (let ((code (run (uiop:command-line-arguments))))
    ;; Output is buffered, so `la l x.tar | head' finds the pipe closed here,
    ;; after RUN. That is how the listing was meant to end, not an error.
    (handler-case (progn (finish-output *standard-output*) (finish-output *error-output*))
      (stream-error () nil))
    (sb-ext:exit :code code :abort t)))
