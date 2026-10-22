(in-package #:libarchive/tests)

(def-suite libarchive-symbols :in libarchive-all)
(in-suite libarchive-symbols)

(test every-bound-function-resolves
  (load-libraries)
  (let ((missing (remove-if #'foreign-function-available-p *foreign-function-names* :key #'car)))
    ;; Against an older libarchive some newer entry points are legitimately
    ;; absent; against the version the headers came from, none may be.
    (if (>= (version-number) *header-version-number*)
        (is (null missing) "Unresolved: ~S" missing)
        (skip "libarchive ~A is older than the headers; ~D functions absent"
              (version-number) (length missing)))))

(test every-raw-function-is-exported-and-fbound
  (let ((bad (loop for (nil . sym) in *foreign-function-names*
                   unless (and (fboundp sym)
                               (eq :external (nth-value 1 (find-symbol (symbol-name sym) :libarchive))))
                     collect sym)))
    (is (null bad) "~S" bad)))

(test every-constant-is-exported-and-bound
  (is (< 150 (length *constant-names*)))
  (let ((bad (loop for (nil . sym) in *constant-names*
                   unless (and (boundp sym)
                               (eq :external (nth-value 1 (find-symbol (symbol-name sym) :libarchive))))
                     collect sym)))
    (is (null bad) "~S" bad)))

(test constants-match-the-header
  ;; Spot checks against values copied from archive.h by hand, so that a
  ;; generator bug in expression evaluation (|, <<, octal, casts) shows up.
  (is (= 0 +archive-ok+))
  (is (= 1 +archive-eof+))
  (is (= -10 +archive-retry+))
  (is (= -20 +archive-warn+))
  (is (= -25 +archive-failed+))
  (is (= -30 +archive-fatal+))
  (is (= #x30003 +archive-format-tar-pax-restricted+))
  (is (= #x100000 +archive-format-rar-v5+))
  (is (= 14 +archive-filter-zstd+))
  (is (= #o100000 +ae-ifreg+))
  (is (= #o040000 +ae-ifdir+))
  (is (= #o120000 +ae-iflnk+))
  (is (= #x40000 +archive-extract-safe-writes+))
  (is (= (logior #x400 #x800 #x1000 #x2000) +archive-entry-acl-type-nfs4+)))

(test version
  (is (>= (version-number) 3000000))
  (is (search "libarchive" (version-string)))
  (is (search (version-string) (version-details))))

(test raw-layer-is-callable
  ;; The raw layer on its own, no ergonomic layer involved.
  (load-libraries)
  (let ((a (%archive-write-new)))
    (unwind-protect
         (progn
           (is (= +archive-ok+ (%archive-write-set-format-ustar a)))
           (is (= +archive-format-tar-ustar+ (%archive-format a))))
      (%archive-write-free a))))
