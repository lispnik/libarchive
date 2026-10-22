;;; Match: choose entries by name, time and owner, with libarchive's own matcher.
;;;
;;;   make example NAME=match
;;;
;;; An ARCHIVE-MATCH holds include and exclude globs, time limits and owners.
;;; ENTRY-MATCHES-P asks it about one entry; EXTRACT-ARCHIVE and
;;; ARCHIVE-DIRECTORY take it as :MATCH. It is a handle like a reader: close it,
;;; or use WITH-ARCHIVE-MATCH.

(defpackage #:libarchive-examples/match
  (:use #:cl #:libarchive))

(in-package #:libarchive-examples/match)

(defparameter *last-year* (encode-universal-time 0 0 0 1 6 2024 0))
(defparameter *this-year* (encode-universal-time 0 0 0 1 6 2025 0))

(defun sample ()
  "A release tree: sources, objects, docs, and an old changelog."
  (with-archive-to-octets (w :format :pax-restricted)
    (add-entry w "pkg/" :mtime *last-year*)
    (add-entry w "pkg/main.c" :data "int main;" :mtime *this-year* :uname "dev")
    (add-entry w "pkg/main.o" :data "object" :mtime *this-year* :uname "dev")
    (add-entry w "pkg/doc/guide.txt" :data "guide" :mtime *this-year* :uname "writer")
    (add-entry w "pkg/ChangeLog" :data "old news" :mtime *last-year* :uname "dev")))

(defun names (archive match)
  (with-archive-reader (r archive)
    (let ((out '()))
      (do-archive-entries (e r (nreverse out))
        (when (entry-matches-p match e)
          (push (entry-pathname e) out))))))

(defun main ()
  (let ((archive (sample)))

    ;; Excludes match at any directory boundary: "*.o" anywhere, "doc" and all
    ;; under it.
    (with-archive-match (m :exclude '("*.o" "doc"))
      (let ((chosen (names archive m)))
        (format t "Without objects and docs: ~S~%" chosen)
        (assert (equal chosen '("pkg/" "pkg/main.c" "pkg/ChangeLog")))))

    ;; Includes take whole directories, and remember which never matched:
    ;; the way to tell a user "x: not in the archive".
    (with-archive-match (m :include '("pkg/doc" "pkg/missing"))
      (let ((chosen (names archive m)))
        (format t "Only the docs: ~S; never matched: ~S~%" chosen (archive-match-unmatched m))
        (assert (equal chosen '("pkg/doc/guide.txt")))
        (assert (equal (archive-match-unmatched m) '("pkg/missing")))))

    ;; Time limits are strict, and take a universal time, a file (its own
    ;; mtime), or a date libarchive parses: "2025-01-01", "2 weeks ago".
    (with-archive-match (m :newer "2025-01-01")
      (let ((chosen (names archive m)))
        (format t "Changed this year: ~S~%" chosen)
        (assert (equal chosen '("pkg/main.c" "pkg/main.o" "pkg/doc/guide.txt")))))

    ;; Owners, and everything together: all conditions must hold.
    (with-archive-match (m :unames '("dev") :exclude "*.o" :older *this-year*)
      (let ((chosen (names archive m)))
        (format t "dev's, not objects, from before this year: ~S~%" chosen)
        (assert (equal chosen '("pkg/ChangeLog")))))

    ;; EXTRACT-ARCHIVE takes a matcher too. A directory the time limit leaves
    ;; out is not created as an entry, but its files still are.
    (let ((dir (uiop:ensure-directory-pathname
                (format nil "~Alibarchive-example-~36R/"
                        (uiop:native-namestring (uiop:temporary-directory))
                        (random (expt 36 8) (make-random-state t))))))
      (unwind-protect
           (with-archive-match (m :newer "2025-01-01" :exclude "*.o")
             (let ((extracted (extract-archive archive dir :match m)))
               (format t "Extracted: ~S~%" extracted)
               (assert (equal extracted '("pkg/main.c" "pkg/doc/guide.txt")))
               (assert (probe-file (merge-pathnames "pkg/doc/guide.txt" dir)))))
        (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore)))))

(main)
