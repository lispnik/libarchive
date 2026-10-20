;;; The client-data registry.
;;;
;;; Every callback libarchive invokes is handed back a void* that we supplied
;;; when installing it. We never give libarchive a pointer to Lisp memory (the
;;; GC moves objects); instead the void* is a small integer key into this table,
;;; and the one DEFCALLBACK per callback type looks the Lisp handle up from it.
;;; That is the whole reason this binding needs no runtime-minted closures.
;;;
;;; The table also keeps registered handles alive: libarchive holds their key,
;;; and nothing else may hold the object.

(in-package #:libarchive)

(defvar *registry* (make-hash-table))
(defvar *registry-lock* (bt:make-lock "libarchive client-data registry"))
(defvar *registry-next-id* 0)

(defun register-object (object)
  "Register OBJECT and return its key as a foreign pointer. Never the null pointer."
  (bt:with-lock-held (*registry-lock*)
    (let ((id (loop (setf *registry-next-id*
                          (if (>= *registry-next-id* most-positive-fixnum)
                              1
                              (1+ *registry-next-id*)))
                    (unless (nth-value 1 (gethash *registry-next-id* *registry*))
                      (return *registry-next-id*)))))
      (setf (gethash id *registry*) object)
      (cffi:make-pointer id))))

(defun unregister-object (key)
  (bt:with-lock-held (*registry-lock*)
    (remhash (cffi:pointer-address key) *registry*)))

(defun find-registered (key)
  "The object registered under the foreign pointer KEY, or NIL."
  (and key (not (cffi:null-pointer-p key))
       (bt:with-lock-held (*registry-lock*)
         (values (gethash (cffi:pointer-address key) *registry*)))))

(defun registry-count ()
  "How many objects are registered. Zero when no archive is open."
  (bt:with-lock-held (*registry-lock*)
    (hash-table-count *registry*)))
