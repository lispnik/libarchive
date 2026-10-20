;;; Tests for la, run in-process: LIBARCHIVE/CLI:RUN takes argv and returns
;;; the exit code. Each test works in a fresh directory bound as
;;; *DEFAULT-PATHNAME-DEFAULTS*, which is all la ever resolves paths against.
;;; Standard input and output (the - archive) need a real process and are
;;; covered by ci/cli-smoke.sh against the built binary instead.

(defpackage #:libarchive/cli/tests
  (:use #:cl #:fiveam)
  (:import-from #:libarchive/cli #:archive-kind #:archive-stem)
  (:export #:run-tests))

(in-package #:libarchive/cli/tests)

(def-suite la :description "The la command-line tool.")

(defun run-tests ()
  (let ((*print-names* t))
    (run! 'la)))
