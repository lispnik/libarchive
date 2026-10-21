;;; Encryption: password-protected zip archives, written and read.
;;;
;;;   make example NAME=encryption
;;;
;;; libarchive writes encrypted zip (traditional PKWARE "ZipCrypto", and WinZip AES)
;;; and reads it, plus encrypted 7z and RAR. Which algorithms are there depends on
;;; the crypto library it was built with; the example skips what is missing.

(defpackage #:libarchive-examples/encryption
  (:use #:cl #:libarchive))

(in-package #:libarchive-examples/encryption)

(defun encrypted-zip (passphrase encryption)
  "A zip of two files encrypted with ENCRYPTION, or NIL if this build lacks it."
  (handler-case
      (with-archive-to-octets (w :format :zip
                                 :passphrase passphrase
                                 :options `(("zip:encryption" . ,encryption)))
        (add-entry w "secret.txt" :data "The treasure is under the third palm tree.")
        (add-entry w "also-secret.txt" :data "So is the map."))
    (archive-error (c)
      (format t "~&~A encryption is not available: ~A~%" encryption (archive-condition-message c))
      nil)))

(defun read-all (zip &rest reader-keys)
  "((name . text) ...) from ZIP, opened with READER-KEYS."
  (let ((r (apply #'open-archive-reader zip reader-keys)))
    (unwind-protect
         (loop for e = (next-entry r)
               while e
               collect (cons (entry-pathname e) (read-entry-string r)))
      (close-archive r))))

(defun main ()
  (dolist (encryption '("zipcrypt" "aes128" "aes256"))
    (let ((zip (encrypted-zip "hunter2" encryption)))
      (when zip
        (format t "~&~%~A: ~D bytes~%" encryption (length zip))

        ;; Metadata is not encrypted in zip, so names can be listed without a
        ;; passphrase, and each entry says whether its data is encrypted.
        (with-archive-reader (r zip)
          (do-archive-entries (e r)
            (format t "  ~A  data encrypted: ~A~%" (entry-pathname e) (entry-data-encrypted-p e))
            (assert (entry-data-encrypted-p e)))
          (format t "  archive has encrypted entries: ~S~%" (archive-has-encrypted-entries r)))

        ;; One passphrase.
        (assert (search "palm tree" (cdr (first (read-all zip :passphrase "hunter2")))))

        ;; Wrong passphrases. ZipCrypto checks a passphrase against one byte of
        ;; a random header, so about one wrong passphrase in 256 gets past the
        ;; check and fails later, in decompression, instead of being passed over.
        ;; AES has a 2-byte check and an HMAC. So these are shown with AES only.
        (unless (string= encryption "zipcrypt")
          ;; Several, tried in turn until one works.
          (assert (= 2 (length (read-all zip :passphrase '("password" "letmein" "hunter2")))))

          ;; A function, called each time libarchive needs another one; NIL means
          ;; "no more". This is where to prompt a user.
          (let ((asked 0))
            (read-all zip :passphrase (lambda ()
                                        (incf asked)
                                        (case asked (1 "wrong") (2 "hunter2") (t nil))))
            (format t "  the passphrase function was asked ~D times~%" asked))

          ;; The wrong passphrase: the names are there, the data is not.
          (handler-case (progn (read-all zip :passphrase "wrong") (error "decrypted with the wrong passphrase"))
            (archive-error (c) (format t "  wrong passphrase: ~A~%" (archive-condition-message c)))))

        ;; No passphrase at all.
        (handler-case (progn (read-all zip) (error "decrypted without a passphrase"))
          (archive-error (c) (format t "  no passphrase: ~A~%" (archive-condition-message c)))))))

  ;; A writer can take a function too, called once when the passphrase is needed.
  (let ((zip (with-archive-to-octets (w :format :zip
                                        :passphrase (lambda () "from a function")
                                        :options '(("zip:encryption" . "zipcrypt")))
               (add-entry w "x.txt" :data "x"))))
    (assert (equal '(("x.txt" . "x")) (read-all zip :passphrase "from a function"))))

  ;; An unencrypted archive says so.
  (with-archive-reader (r (with-archive-to-octets (w :format :zip) (add-entry w "plain" :data "p")))
    (next-entry r)
    (format t "~&~%Plain zip has encrypted entries: ~S~%" (archive-has-encrypted-entries r))
    (assert (null (archive-has-encrypted-entries r)))))

(main)
