;;; The test suites.
;;;
;;;   LIBARCHIVE-SYMBOLS     the raw layer resolves against the loaded library
;;;   LIBARCHIVE-ENTRIES     entry accessors and lifetimes
;;;   LIBARCHIVE-ROUNDTRIP   write then read, in memory, across formats and filters
;;;   LIBARCHIVE-STREAMS     Lisp streams as sources and sinks (the callback path),
;;;                          and files cross-checked with the system's tar and zip
;;;   LIBARCHIVE-CALLBACKS   error containment, demultiplexing, threads
;;;   LIBARCHIVE-ENCRYPTION  zip passphrases, every way they can be supplied
;;;   LIBARCHIVE-DISK        extraction and archiving of real directory trees
;;;   LIBARCHIVE-ERRORS      return codes become the right conditions
;;;   LIBARCHIVE-HYGIENE     runs last: nothing the suites above opened is left open
;;;
;;; FiveAM has no teardown hook, so every resource is acquired by a macro with an
;;; UNWIND-PROTECT in it, and the hygiene suite turns a leak into a failure.

(defpackage #:libarchive/tests
  (:use #:cl #:fiveam #:libarchive)
  (:shadowing-import-from #:fiveam #:test)
  (:export #:run-tests #:libarchive-all))

(in-package #:libarchive/tests)

(def-suite libarchive-all :description "Every libarchive suite.")
