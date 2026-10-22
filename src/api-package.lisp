;;; Exports of the ergonomic layer (system #:libarchive).

(in-package #:libarchive)

(export
 '(;; core.lisp
   version-number version-string version-details
   ;; handle.lisp
   archive-handle archive-reader archive-writer disk-reader disk-writer
   close-archive archive-open-p
   archive-format-name archive-format-code archive-filter-names archive-file-count
   ;; entry.lisp
   entry make-entry free-entry copy-entry entry-valid-p
   entry-pathname entry-size entry-size-set-p entry-type entry-perm entry-mode
   entry-uid entry-gid entry-uname entry-gname entry-symlink entry-hardlink
   entry-mtime entry-mtime-nsec entry-atime entry-ctime entry-birthtime
   entry-nlink entry-strmode entry-fflags-text entry-data-encrypted-p
   entry-metadata-encrypted-p entry-xattrs entry-add-xattr entry-clear-xattrs
   ;; reader.lisp
   open-archive-reader next-entry read-entry-data read-entry-string
   read-entry-data-into copy-entry-data skip-entry-data archive-has-encrypted-entries
   ;; writer.lisp
   open-archive-writer write-entry add-entry transfer-entry writer-octets
   ;; match.lisp
   archive-match make-archive-match with-archive-match entry-matches-p
   archive-match-unmatched
   ;; disk.lisp
   extract-archive archive-directory *default-extract-flags* skip-entry
   extraction-limit-exceeded extraction-limit extraction-limit-entry
   *extract-flags* *read-disk-flags* *read-formats* *read-filters*
   ;; with.lisp
   with-archive-reader with-archive-writer with-archive-to-octets
   do-archive-entries with-entry archive-entry-names))
