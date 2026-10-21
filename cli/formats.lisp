;;; File names to formats and filters, and back to a name without them.
;;;
;;; One table serves both directions: `la a x.tar.zst ...' looks up how to write,
;;; and `la x x.tar.zst' looks up what to strip to name the directory it makes.

(in-package #:libarchive/cli)

(defparameter *ar-format* #+darwin :ar-bsd #-darwin :ar-svr4
  "BSD ar on BSD-derived systems, System V (GNU) ar elsewhere: what the local ar reads.")

(defparameter *extensions*
  `((".tar" :pax-restricted)
    (".tar.gz" :pax-restricted :gzip)       (".tgz" :pax-restricted :gzip)
    (".tar.bz2" :pax-restricted :bzip2)     (".tbz2" :pax-restricted :bzip2)
    (".tbz" :pax-restricted :bzip2)
    (".tar.xz" :pax-restricted :xz)         (".txz" :pax-restricted :xz)
    (".tar.zst" :pax-restricted :zstd)      (".tzst" :pax-restricted :zstd)
    (".tar.lz4" :pax-restricted :lz4)
    (".tar.lz" :pax-restricted :lzip)
    (".tar.lzma" :pax-restricted :lzma)     (".tlz" :pax-restricted :lzma)
    (".tar.Z" :pax-restricted :compress)    (".taz" :pax-restricted :compress)
    (".zip" :zip) (".jar" :zip)
    (".7z" :7zip)
    (".cpio" :cpio-newc)
    (".iso" :iso9660)
    (".xar" :xar)
    (".a" ,*ar-format*) (".ar" ,*ar-format*)
    (".shar" :shar)
    (".mtree" :mtree)
    (".warc" :warc)
    ;; A compressor alone: one file, no archive around it.
    (".gz" :raw :gzip) (".bz2" :raw :bzip2) (".xz" :raw :xz) (".zst" :raw :zstd)
    (".lz4" :raw :lz4) (".lz" :raw :lzip) (".lzma" :raw :lzma) (".Z" :raw :compress))
  "(suffix format . filters), matched case-insensitively, longest suffix first.")

(defun suffix-entry (filename)
  (let ((name (file-namestring filename)))
    (loop for entry in (sort (copy-list *extensions*) #'> :key (lambda (e) (length (first e))))
          for suffix = (first entry)
          when (and (>= (length name) (length suffix))
                    (string-equal suffix name :start2 (- (length name) (length suffix))))
            return entry)))

(defun archive-kind (filename)
  "The format and filters FILENAME's extension calls for, or NIL if it names none."
  (let ((entry (suffix-entry filename)))
    (and entry (values (second entry) (cddr entry) (first entry)))))

(defun archive-stem (filename)
  "FILENAME without its directory and its archive extension: \"src-1.2.tar.gz\"
=> \"src-1.2\". An unknown extension is dropped as one; a name that would be
empty becomes \"archive\"."
  (let* ((name (file-namestring filename))
         (entry (suffix-entry name))
         (stem (cond (entry (subseq name 0 (- (length name) (length (first entry)))))
                     ((position #\. name :start 1)
                      (subseq name 0 (position #\. name :from-end t)))
                     (t name))))
    (if (plusp (length stem)) stem "archive")))

;;; Names given on the command line with -F and -z.

(defparameter *format-names*
  `(("tar" . :pax-restricted) ("pax" . :pax) ("ustar" . :ustar) ("gnutar" . :gnutar)
    ("v7" . :v7tar) ("zip" . :zip) ("7z" . :7zip) ("7zip" . :7zip) ("cpio" . :cpio-newc)
    ("odc" . :cpio-odc) ("iso" . :iso9660) ("iso9660" . :iso9660) ("xar" . :xar)
    ("ar" . ,*ar-format*) ("shar" . :shar) ("mtree" . :mtree) ("warc" . :warc)
    ("raw" . :raw)))

(defparameter *filter-names*
  '(("gzip" . :gzip) ("gz" . :gzip) ("bzip2" . :bzip2) ("bz2" . :bzip2) ("xz" . :xz)
    ("zstd" . :zstd) ("zst" . :zstd) ("lz4" . :lz4) ("lzip" . :lzip) ("lz" . :lzip)
    ("lzma" . :lzma) ("compress" . :compress) ("Z" . :compress) ("uuencode" . :uuencode)
    ("base64" . :base64)))

(defun parse-format (name)
  (or (cdr (assoc name *format-names* :test #'string-equal))
      ;; Anything else goes to libarchive by name, e.g. "paxr" or "newc".
      name))

(defun parse-filter (name)
  (or (cdr (assoc name *filter-names* :test #'string-equal))
      (usage-error "unknown compression ~S; expected one of ~{~A~^, ~}"
                   name (remove-duplicates (mapcar #'car *filter-names*) :test #'string=
                                                                          :from-end t))))

;;; Compression levels: the filters that take one, by libarchive module name.
(defparameter *thread-modules*
  '((:zstd . "zstd") (:xz . "xz"))
  "Filters with a threads option: the libarchive module that takes it.")

(defparameter *level-modules*
  '((:gzip . "gzip") (:bzip2 . "bzip2") (:xz . "xz") (:lzma . "lzma") (:lzip . "lzip")
    (:zstd . "zstd") (:lz4 . "lz4")))

(defparameter *formats-without-directories* '(:warc :ar-bsd :ar-svr4 :raw)
  "Formats that cannot store a directory entry: la a stores only the files.")
