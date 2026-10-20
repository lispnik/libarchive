(in-package #:libarchive/tests)

(def-suite libarchive-encryption :in libarchive-all)
(in-suite libarchive-encryption)

(defun encrypted-zip (encryption &optional (passphrase "correct horse"))
  (with-archive-to-octets (w :format :zip :passphrase passphrase
                             :options `(("zip:encryption" . ,encryption)))
    (add-entry w "secret.txt" :data "the secret")))

(defun read-secret (zip &rest reader-keys)
  (let ((r (apply #'open-archive-reader zip reader-keys)))
    (unwind-protect
         (let ((e (next-entry r)))
           (values (read-entry-string r) (entry-data-encrypted-p e)
                   (archive-has-encrypted-entries r)))
      (close-archive r))))

(test traditional-zip-encryption
  (let ((zip (encrypted-zip "traditional")))
    (is (null (search (babel:string-to-octets "the secret") zip)))
    (multiple-value-bind (text encrypted has) (read-secret zip :passphrase "correct horse")
      (is (string= "the secret" text))
      (is-true encrypted)
      (is (eq t has)))))

(test aes-zip-encryption
  (handler-case (encrypted-zip "aes256")
    (archive-error ()
      (skip "this libarchive was built without AES support"))
    (:no-error (zip)
      (is (string= "the secret" (read-secret zip :passphrase "correct horse"))))))

(test passphrase-list-is-tried-in-turn
  (is (string= "the secret" (read-secret (encrypted-zip "traditional")
                                         :passphrase '("wrong" "also wrong" "correct horse")))))

(test passphrase-function-is-asked-until-nil
  (let ((offered '("wrong" "correct horse"))
        (asked 0))
    (is (string= "the secret"
                 (read-secret (encrypted-zip "traditional")
                              :passphrase (lambda () (incf asked) (pop offered)))))
    (is (<= 2 asked))))

(test write-passphrase-function
  (let ((zip (with-archive-to-octets (w :format :zip :passphrase (lambda () "from fn")
                                        :options "zip:encryption=traditional")
               (add-entry w "s" :data "data"))))
    (is (string= "data" (read-secret zip :passphrase "from fn")))))

(test missing-or-wrong-passphrase-is-an-error
  (let ((zip (encrypted-zip "traditional")))
    (signals archive-error (read-secret zip))
    (signals archive-error (read-secret zip :passphrase "wrong"))))

(test unencrypted-archive-reports-no-encryption
  (multiple-value-bind (text encrypted) (read-secret (with-archive-to-octets (w :format :zip)
                                                       (add-entry w "p" :data "plain")))
    (is (string= "plain" text))
    (is-false encrypted)))
