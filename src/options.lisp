;;; Formats, filters, flags and option strings: keywords to libarchive.

(in-package #:libarchive)

;;; Reading: each format or filter is enabled with its own function.

(defparameter *read-formats*
  `((:all . %archive-read-support-format-all)
    (:7zip . %archive-read-support-format-7zip)
    (:ar . %archive-read-support-format-ar)
    (:cab . %archive-read-support-format-cab)
    (:cpio . %archive-read-support-format-cpio)
    (:empty . %archive-read-support-format-empty)
    (:gnutar . %archive-read-support-format-gnutar)
    (:iso9660 . %archive-read-support-format-iso9660)
    (:lha . %archive-read-support-format-lha)
    (:mtree . %archive-read-support-format-mtree)
    (:rar . %archive-read-support-format-rar)
    (:rar5 . %archive-read-support-format-rar5)
    (:raw . %archive-read-support-format-raw)
    (:tar . %archive-read-support-format-tar)
    (:warc . %archive-read-support-format-warc)
    (:xar . %archive-read-support-format-xar)
    (:zip . %archive-read-support-format-zip)
    (:zip-streamable . %archive-read-support-format-zip-streamable)
    (:zip-seekable . %archive-read-support-format-zip-seekable)))

(defparameter *read-filters*
  `((:all . %archive-read-support-filter-all)
    (:none . %archive-read-support-filter-none)
    (:bzip2 . %archive-read-support-filter-bzip2)
    (:compress . %archive-read-support-filter-compress)
    (:grzip . %archive-read-support-filter-grzip)
    (:gzip . %archive-read-support-filter-gzip)
    (:lrzip . %archive-read-support-filter-lrzip)
    (:lz4 . %archive-read-support-filter-lz4)
    (:lzip . %archive-read-support-filter-lzip)
    (:lzma . %archive-read-support-filter-lzma)
    (:lzop . %archive-read-support-filter-lzop)
    (:rpm . %archive-read-support-filter-rpm)
    (:uu . %archive-read-support-filter-uu)
    (:xz . %archive-read-support-filter-xz)
    (:zstd . %archive-read-support-filter-zstd)))

(defun enable-read-support (handle what table kind)
  (dolist (k (if (listp what) what (list what)))
    (let ((f (or (cdr (assoc k table))
                 (error "Unknown read ~A ~S; expected one of ~S." kind k (mapcar #'car table)))))
      ;; ARCHIVE_WARN here means "supported, but through an external program";
      ;; that is not worth a warning.
      (let ((code (funcall f (live-pointer handle))))
        (unless (= code +archive-warn+)
          (check-result handle code (format nil "enable ~(~A~) ~A" k kind)))))))

;;; Writing: libarchive's by-name setters, so the keyword is the name
;;; downcased except where libarchive's name is cryptic.

(defparameter *write-format-aliases*
  '((:pax-restricted . "paxr") (:ar-bsd . "arbsd") (:ar-svr4 . "arsvr4")
    (:cpio-newc . "newc") (:cpio-odc . "odc") (:cpio-bin . "bin") (:cpio-pwb . "pwb")
    (:shar-dump . "shardump") (:mtree-classic . "mtree-classic")))

(defparameter *write-filter-aliases*
  '((:uuencode . "uuencode") (:base64 . "b64encode")))

(defun libarchive-name (thing aliases)
  (etypecase thing
    (string thing)
    (keyword (or (cdr (assoc thing aliases)) (string-downcase thing)))))

;;; Option strings: libarchive takes "module:option=value,..." text. Accept that
;;; text, or an alist of (option . value) where option is a string such as
;;; "zip:compression", value T means "option", NIL its negation ("!option", or
;;; "module:!option" -- libarchive wants the ! after the module), and anything else
;;; "option=value".

(defun options-string (options)
  (etypecase options
    (string options)
    (list (format nil "~{~A~^,~}"
                  (loop for (key . value) in options
                        for name = (if (stringp key) key (string-downcase key))
                        collect (cond ((eq value t) name)
                                      ((null value)
                                       (let ((colon (position #\: name)))
                                         (if colon
                                             (format nil "~A!~A" (subseq name 0 (1+ colon))
                                                     (subseq name (1+ colon)))
                                             (format nil "!~A" name))))
                                      (t (format nil "~A=~A" name
                                                 (if (keywordp value)
                                                     (string-downcase value)
                                                     value)))))))))

;;; Flags.

(defparameter *extract-flags*
  `((:owner . ,+archive-extract-owner+)
    (:perm . ,+archive-extract-perm+)
    (:time . ,+archive-extract-time+)
    (:no-overwrite . ,+archive-extract-no-overwrite+)
    (:unlink . ,+archive-extract-unlink+)
    (:acl . ,+archive-extract-acl+)
    (:fflags . ,+archive-extract-fflags+)
    (:xattr . ,+archive-extract-xattr+)
    (:secure-symlinks . ,+archive-extract-secure-symlinks+)
    (:secure-nodotdot . ,+archive-extract-secure-nodotdot+)
    (:no-autodir . ,+archive-extract-no-autodir+)
    (:no-overwrite-newer . ,+archive-extract-no-overwrite-newer+)
    (:sparse . ,+archive-extract-sparse+)
    (:mac-metadata . ,+archive-extract-mac-metadata+)
    (:no-hfs-compression . ,+archive-extract-no-hfs-compression+)
    (:hfs-compression-forced . ,+archive-extract-hfs-compression-forced+)
    (:secure-noabsolutepaths . ,+archive-extract-secure-noabsolutepaths+)
    (:clear-nochange-fflags . ,+archive-extract-clear-nochange-fflags+)
    (:safe-writes . ,+archive-extract-safe-writes+)))

(defparameter *read-disk-flags*
  `((:restore-atime . ,+archive-readdisk-restore-atime+)
    (:honor-nodump . ,+archive-readdisk-honor-nodump+)
    (:mac-copyfile . ,+archive-readdisk-mac-copyfile+)
    (:no-traverse-mounts . ,+archive-readdisk-no-traverse-mounts+)
    (:no-xattr . ,+archive-readdisk-no-xattr+)
    (:no-acl . ,+archive-readdisk-no-acl+)
    (:no-fflags . ,+archive-readdisk-no-fflags+)
    (:no-sparse . ,+archive-readdisk-no-sparse+)))

(defun install-passphrase-function (handle function setter)
  (setf (handle-passphrase-function handle) function)
  (check-result handle
                (funcall setter (live-pointer handle) (handle-key handle)
                         (cffi:callback passphrase-callback))
                "set passphrase callback"))
