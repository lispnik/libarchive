;;; la: a general-purpose archive tool on top of the libarchive binding.
;;;
;;;   la x ARCHIVE            extract (into a new directory if it has several roots)
;;;   la a ARCHIVE FILE...    create, format and compression from the file name
;;;   la l ARCHIVE            list          la t ARCHIVE   test (read everything)
;;;   la i ARCHIVE            describe
;;;
;;; One interface for every format libarchive reads or writes. Each subcommand
;;; lives in its own file and registers itself (REGISTER-COMMAND), as in ud18's
;;; CLI. RUN takes argv and returns an exit code without exiting, so the tests
;;; drive the tool in-process; MAIN is the binary's entry point.

(defpackage #:libarchive/cli
  (:use #:cl #:libarchive)
  (:export #:main #:run #:cli-error
           ;; formats.lisp, for the tests
           #:archive-kind #:archive-stem))
