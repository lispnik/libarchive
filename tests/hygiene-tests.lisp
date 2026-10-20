(in-package #:libarchive/tests)

(def-suite libarchive-hygiene :in libarchive-all)
(in-suite libarchive-hygiene)

(test nothing-left-registered
  ;; Every handle the suites above opened has been closed, including those
  ;; abandoned by errors inside callbacks.
  (is (zerop (libarchive::registry-count))
      "~D handles still registered" (libarchive::registry-count)))
