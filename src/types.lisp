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

;;; Used to move bytes between foreign buffers and pinned Lisp vectors.
(cffi:defcfun ("memcpy" %memcpy) :pointer
  (dest :pointer) (src :pointer) (n :size))
