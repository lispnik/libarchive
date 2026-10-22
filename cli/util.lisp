;;; Errors, paths, standard streams and glob matching.

(in-package #:libarchive/cli)

;;; Errors. A CLI-ERROR is a message for the user, not a bug: RUN prints it
;;; after "la: " and exits with its code (1, or 2 for a usage error).

(define-condition cli-error (error)
  ((message :initarg :message :reader cli-error-message)
   (code :initarg :code :initform 1 :reader cli-error-code))
  (:report (lambda (c s) (write-string (cli-error-message c) s))))

(defun fail (control &rest args)
  (error 'cli-error :message (apply #'format nil control args)))

(defun usage-error (control &rest args)
  (error 'cli-error :code 2 :message (apply #'format nil control args)))

(defvar *quiet* nil "Suppress the summary lines on standard error.")

;;; Everything la prints goes through PRINTABLE. Names come from archives, and
;;; an archive can hold a name with a newline in it (a fake line of output) or
;;; a terminal escape sequence (which retitles the window, or worse, when it
;;; reaches a terminal). As GNU tar does, control characters and backslashes
;;; are written as C escapes; --json escapes them its own way.

(defun unprintable-p (char)
  (let ((code (char-code char)))
    (or (< code 32) (<= 127 code 159) (char= char #\\))))

(defun printable (string)
  "STRING with control characters and backslashes escaped: \\n, \\t, \\\\, \\033."
  (if (notany #'unprintable-p string)
      string
      (with-output-to-string (out)
        (loop for c across string
              do (case c
                   (#\\ (write-string "\\\\" out))
                   (#\Newline (write-string "\\n" out))
                   (#\Tab (write-string "\\t" out))
                   (#\Return (write-string "\\r" out))
                   (t (if (unprintable-p c)
                          (format out "\\~3,'0O" (char-code c))
                          (write-char c out))))))))

(defun os-reason (condition)
  "The last line of an SBCL stream or file error: the system's reason, such as
\"No space left on device\"."
  (let ((text (string-trim '(#\Space #\Newline) (princ-to-string condition))))
    (string-trim " " (subseq text (1+ (or (position #\Newline text :from-end t) -1))))))

(defparameter *errnos-worth-naming*
  (list sb-posix:enospc sb-posix:edquot sb-posix:eio sb-posix:eacces sb-posix:erofs
        sb-posix:efbig sb-posix:enametoolong)
  "errnos whose description says more than libarchive's message (\"Write failed\").")

(defun archive-message (condition)
  "An ARCHIVE-CONDITION's message, with the system's reason when it adds one."
  (let ((message (or (archive-condition-message condition) (princ-to-string condition)))
        (errno (archive-condition-errno condition)))
    (if (and errno (member errno *errnos-worth-naming*))
        (format nil "~A (~A)" message (sb-int:strerror errno))
        message)))

(defun say (control &rest args)
  "A line on standard output, made printable."
  (write-line (printable (format nil "~?" control args))))

(defun warn-user (control &rest args)
  "A diagnostic on standard error that does not stop the command."
  (format *error-output* "~&la: ~A~%" (printable (format nil "~?" control args))))

(defun note (control &rest args)
  "A summary line on standard error, unless --quiet."
  (unless *quiet*
    (format *error-output* "~&~A~%" (printable (format nil "~?" control args)))))

;;; Paths. Every path the user gives is merged with *DEFAULT-PATHNAME-DEFAULTS*
;;; and the process never changes directory, so the tests can bind it.

(defun user-file (string)
  (merge-pathnames (uiop:parse-native-namestring string)))

(defun user-directory (string)
  (merge-pathnames (uiop:ensure-directory-pathname (uiop:parse-native-namestring string))))

(defun stdio-p (name) (string= name "-"))

(defun lstat-name (path)
  "PATH as lstat should see it: without a trailing /, which would make it look
through a symlink at the end."
  (let ((name (uiop:native-namestring path)))
    (if (> (length name) 1) (string-right-trim "/" name) name)))

(defun lexists-p (path)
  "True if PATH exists, as a dangling symlink too."
  (handler-case (progn (sb-posix:lstat (lstat-name path)) t)
    (sb-posix:syscall-error () nil)))

(defun symlink-p (path)
  (handler-case (sb-posix:s-islnk (sb-posix:stat-mode (sb-posix:lstat (uiop:native-namestring path))))
    (sb-posix:syscall-error () nil)))

(defun display-name (name)
  (if (stdio-p name) "standard input" name))

;;; Standard input and output as octet streams. SBCL's *STANDARD-INPUT* and
;;; *STANDARD-OUTPUT* are character streams.

(defun stdin-octets ()
  (sb-sys:make-fd-stream 0 :input t :element-type '(unsigned-byte 8) :buffering :full))

(defun stdout-octets ()
  (sb-sys:make-fd-stream 1 :output t :element-type '(unsigned-byte 8) :buffering :full))

(defun call-with-input-archive (name function)
  "Call FUNCTION with something OPEN-ARCHIVE-READER accepts for NAME.

Standard input is spooled to a temporary file first: extraction reads an
archive twice (once to find its top-level names), and zip and 7z want to seek."
  (if (stdio-p name)
      (uiop:with-temporary-file (:pathname spool :type "la" :element-type '(unsigned-byte 8)
                                 :stream out)
        (uiop:copy-stream-to-stream (stdin-octets) out :element-type '(unsigned-byte 8))
        :close-stream
        (funcall function spool))
      (let ((path (user-file name)))
        (unless (probe-file path)
          (fail "~A: no such file" name))
        (when (uiop:directory-exists-p path)
          (fail "~A is a directory, not an archive" name))
        (funcall function path))))

;;; Passphrases: -p, else LA_PASSPHRASE, else -- for reading -- a prompt on the
;;; terminal. A PASSPHRASE-SOURCE outlives the readers of one command: `la x'
;;; opens the archive twice, and the passphrase typed for the first is tried
;;; first by the second, so it is asked for once.

(defvar *prompt-for-passphrase* t
  "Whether to ask on /dev/tty when an archive needs a passphrase and none was
given. The tests turn it off; without a terminal there is nobody to ask anyway.")

(defun passphrase-from (cmd)
  "The passphrase given with -p or LA_PASSPHRASE, or NIL."
  (or (clingon:getopt cmd :passphrase)
      (let ((env (uiop:getenv "LA_PASSPHRASE")))
        (and env (plusp (length env)) env))))

(defstruct (passphrase-source (:constructor %make-passphrase-source))
  given                                 ; -p or LA_PASSPHRASE
  remembered                            ; the last one typed at the prompt
  label)                                ; what to call the archive when asking

(defun passphrase-source (cmd label)
  (%make-passphrase-source :given (passphrase-from cmd) :label label))

(defun terminal-available-p ()
  (ignore-errors (with-open-file (tty "/dev/tty") (declare (ignorable tty)) t)))

(defun read-passphrase-from-terminal (label)
  "Ask on /dev/tty, without echo. NIL if the answer is empty."
  (with-open-file (tty "/dev/tty" :direction :io :if-exists :append)
    (format tty "Passphrase for ~A: " (printable label))
    (finish-output tty)
    (flet ((stty (arg) (ignore-errors (uiop:run-program (list "stty" arg) :input #p"/dev/tty"))))
      (stty "-echo")
      (unwind-protect
           (let ((line (read-line tty nil "")))
             (terpri tty)
             (and (plusp (length line)) line))
        (stty "echo")))))

(defun reader-passphrase (source)
  "What to give OPEN-ARCHIVE-READER as :PASSPHRASE for one more reader."
  (cond ((null source) nil)
        ((passphrase-source-given source))
        ((and *prompt-for-passphrase* (terminal-available-p))
         ;; libarchive calls this each time it needs another passphrase to try:
         ;; first the one already typed, then up to three asked for.
         (let ((calls 0))
           (lambda ()
             (incf calls)
             (let ((remembered (passphrase-source-remembered source)))
               (cond ((and (= calls 1) remembered))
                     ((> calls (if remembered 4 3)) nil)
                     (t (setf (passphrase-source-remembered source)
                              (read-passphrase-from-terminal
                               (passphrase-source-label source)))))))))))

;;; Globs, for --exclude: * matches any run of characters (including /), ?
;;; any one character. A pattern matches a path if it matches the whole path or
;;; any tail of it that starts after a /, so "*.o", ".git", "build/*" and
;;; "src/*.tmp" all mean what they would to tar.

(defun glob-match-p (pattern string &key (p 0) (s 0))
  (loop
    (cond ((= p (length pattern)) (return (= s (length string))))
          ((char= (char pattern p) #\*)
           (return (loop for i from s to (length string)
                         thereis (glob-match-p pattern string :p (1+ p) :s i))))
          ((= s (length string)) (return nil))
          ((or (char= (char pattern p) #\?) (char= (char pattern p) (char string s)))
           (incf p) (incf s))
          (t (return nil)))))

(defun path-matches-p (pattern path)
  (let ((path (string-right-trim "/" path)))
    (or (glob-match-p pattern path)
        (loop for i = (position #\/ path) then (position #\/ path :start (1+ i))
              while i
              thereis (glob-match-p pattern path :s (1+ i))))))

;;; Output helpers.

(defun human-size (bytes)
  (if (< bytes 1024)
      (format nil "~D B" bytes)
      (loop for unit in '("KiB" "MiB" "GiB" "TiB")
            for value = (/ bytes 1024.0) then (/ value 1024.0)
            when (or (< value 1024) (string= unit "TiB"))
              return (format nil "~,1F ~A" value unit))))

(defun iso-time (universal-time)
  (if universal-time
      (multiple-value-bind (sec min hour day month year) (decode-universal-time universal-time)
        (declare (ignore sec))
        (format nil "~4,'0D-~2,'0D-~2,'0D ~2,'0D:~2,'0D" year month day hour min))
      "                "))
