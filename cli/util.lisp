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

(defun warn-user (control &rest args)
  "A diagnostic on standard error that does not stop the command."
  (format *error-output* "~&la: ~?~%" control args))

(defun note (control &rest args)
  "A summary line on standard error, unless --quiet."
  (unless *quiet*
    (format *error-output* "~&~?~%" control args)))

;;; Paths. Every path the user gives is merged with *DEFAULT-PATHNAME-DEFAULTS*
;;; and the process never changes directory, so the tests can bind it.

(defun user-file (string)
  (merge-pathnames (uiop:parse-native-namestring string)))

(defun user-directory (string)
  (merge-pathnames (uiop:ensure-directory-pathname (uiop:parse-native-namestring string))))

(defun stdio-p (name) (string= name "-"))

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

;;; Passphrases: the option, else the environment, else none.

(defun passphrase-from (cmd)
  (or (clingon:getopt cmd :passphrase)
      (let ((env (uiop:getenv "LA_PASSPHRASE")))
        (and env (plusp (length env)) env))))

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
