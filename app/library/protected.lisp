;;; Mimicks the ProtectedModel in Turtl's JS app...provides tie-ins to standard
;;; encryption/decryption when serializing/deserializing models.

(in-package :turtl-core)

(defclass protected (model)
  ((key :accessor key :initform nil)
   (body-key :accessor body-key :initform "body")
   (public-fields :accessor public-fields :initform '("id"))
   (private-fields :accessor private-fields :initform nil)
   (raw-data :accessor raw-data :initform nil))
  (:documentation
    "Wraps an MVC model and provides easy tie-ins to encryption/decryption via
     the model's serialization methods."))

(defgeneric mdeserialize (model body data)
  (:documentation
    "Deserializes a model from a hash object (async, returns a future)."))

(defgeneric process-body (model data)
  (:documentation
    "Processes a model's data's body key, turning an encrypted block into mset-
     able data (a hash, for example)."))

(defgeneric find-key (model keydata)
  (:documentation
    "Find the appropriate key for this model."))

(defgeneric ensure-key-exists (model data)
  (:documentation
    "Make this the given model has a key avialable."))

(defun format-data (data)
  "Format data before passing it into crypto functions. Detects the version 0
   serialization format and acts accordingly."
  (if (cl-ppcre:scan ":i[0-9a-f]{32}$" data)
      (babel:string-to-octets data)
      (from-base64 data)))

(defmethod mdeserialize ((model protected) body data)
  (declare (ignorable data))
  (let ((future (make-future))
        (raw (format-data body)))
    ;; queue the decryption to happen in the background, finishing our returned
    ;; future once done. if we happen to catch any errors, signal them on the
    ;; future.
    (vom:debug2 "protected: deserialize: ~a bytes" (length body))
    (work (decrypted (handler-case (decrypt (key model) raw) (t (e) e)))
      (if (typep decrypted 'error)
          (signal-error future decrypted)
          (finish future decrypted)))
    future))

(defmethod find-key ((model protected) keydata)
  )

(defmethod ensure-key-exists ((model protected) data)
  (let ((key (key model)))
    (when key (return-from ensure-key-exists key))
    (setf key (find-key model (gethash "keys" data)))
    (when key
      (setf (key model) key)
      key)))

(defmethod process-body ((model protected) data)
  "Process a model's body key, deserializing it into usable data."
  (vom:debug2 "protected: process-body (has body: ~a): ~a" (nth-value 1 (gethash (body-key model) data)) data)
  (let ((future (make-future))
        (body (gethash (body-key model) data)))
    (when body
      (unless (ensure-key-exists model data)
        (return-from process-body))
      (when (stringp body)
        (future-handler-case
          (alet* ((deserialized (mdeserialize model body data))
                  (object (yason:parse (babel:octets-to-string deserialized))))
            (mset model object)
            (finish future object model))
          (t (e) (signal-error future e))))
      future)))

(defmethod mset ((model protected) data)
  (if (raw-data model)
      (call-next-method)
      (let* ((body-key (body-key model))
             (data (if (hash-table-p data)
                       ;; already a hash table
                       data
                       ;; convert from plist to hash
                       (let ((hash (make-hash-table :test #'equal)))
                         (loop for (k v) on data by #'cddr do
                           (setf (gethash k hash) v))
                         hash)))
             (body (gethash body-key data)))
        ;; make sure the default mset doesn't bother with the body
        (remhash body-key data)
        (call-next-method)
        (when body
          (setf (gethash body-key data) body)
          (process-body model data)))))

