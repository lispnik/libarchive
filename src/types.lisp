;;; Foreign types the headers use.
;;;
;;; mode_t and dev_t differ by platform, and getting them wrong is silent:
;;; mode_t is 16 bits on Darwin and the BSDs and 32 bits on Linux, and dev_t is
;;; 32 bits on Darwin and 64 bits elsewhere. They are spelled out per platform
;;; rather than groveled, so building the library needs no C compiler.

(in-package #:libarchive)

(cffi:defctype archive :pointer "A struct archive *.")
(cffi:defctype archive-entry :pointer "A struct archive_entry *.")

(cffi:defctype mode-t
    #+(or darwin freebsd openbsd netbsd) :uint16
    #-(or darwin freebsd openbsd netbsd) :uint32)

(cffi:defctype dev-t
    #+darwin :int32
    #-darwin :uint64)

;;; time_t is long on every LP64 platform this binding targets.
(cffi:defctype time-t :long)

;;; Strings libarchive returns: names, error messages. An archive's names are
;;; whatever bytes its writer stored, often not UTF-8 (old tarballs are full
;;; of Latin-1), and a strict :string would signal a decoding error on them
;;; instead of returning a name. So: UTF-8 if the bytes are UTF-8, else
;;; Latin-1, which maps each byte to one character and never fails.
(cffi:define-foreign-type c-string-type ()
  ()
  (:actual-type :pointer)
  (:simple-parser c-string))

(defun decode-c-string (pointer)
  (unless (cffi:null-pointer-p pointer)
    (handler-case (cffi:foreign-string-to-lisp pointer :encoding :utf-8)
      (babel-encodings:character-decoding-error ()
        (cffi:foreign-string-to-lisp pointer :encoding :latin-1)))))

(defmethod cffi:translate-from-foreign (pointer (type c-string-type))
  (decode-c-string pointer))

;;; Used to move bytes between foreign buffers and pinned Lisp vectors.
(cffi:defcfun ("memcpy" %memcpy) :pointer
  (dest :pointer) (src :pointer) (n :size))
