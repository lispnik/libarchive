;;; Library version, and the small conversions every other file uses.

(in-package #:libarchive)

(defun version-number ()
  "libarchive's version as an integer, e.g. 3008009 for 3.8.9."
  (load-libraries)
  (%archive-version-number))

(defun version-string ()
  "e.g. \"libarchive 3.8.9\"."
  (load-libraries)
  (%archive-version-string))

(defun version-details ()
  "The version string plus the compression and crypto libraries libarchive was built with."
  (load-libraries)
  (%archive-version-details))

;;; Unix time <-> universal time. libarchive speaks the former, Lisp the latter.
(defconstant +unix-epoch+ (encode-universal-time 0 0 0 1 1 1970 0))

(declaim (inline unix->universal universal->unix))
(defun unix->universal (seconds) (+ seconds +unix-epoch+))
(defun universal->unix (time) (- time +unix-epoch+))

(defun flags-value (flags table what)
  "OR together the values of the keywords in FLAGS (a list, a keyword, or an
integer passed through) as looked up in the alist TABLE."
  (etypecase flags
    (integer flags)
    (null 0)
    (keyword (flags-value (list flags) table what))
    (list (reduce #'logior flags
                  :key (lambda (k)
                         (or (cdr (assoc k table))
                             (error "Unknown ~A flag ~S; expected one of ~S."
                                    what k (mapcar #'car table))))))))

(deftype octets () '(simple-array (unsigned-byte 8) (*)))

(defun ensure-octets (data)
  "DATA as a simple octet vector: strings are encoded as UTF-8."
  (etypecase data
    (octets data)
    (string (babel:string-to-octets data :encoding :utf-8))
    (vector (coerce data 'octets))))
