;;; consult-imenu.el --- Test stub for Consult Imenu -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'consult)
(require 'imenu)
(require 'seq)

(defvar consult-imenu-config nil
  "Stubbed Consult Imenu configuration.")

(defvar consult-imenu--history nil
  "Stubbed Consult Imenu history.")

(defvar-local consult-imenu--cache nil
  "Stubbed buffer-local cache of `(TICK . ITEMS)'.")

(defface consult-imenu-prefix '((t :inherit shadow))
  "Stubbed Consult Imenu prefix face.")

(defvar agent-shell-test-consult-imenu-calls nil
  "Stub: recorded direct calls to `consult-imenu'.")

(defun consult-imenu--normalize (pos)
  "Stub mirroring `consult-imenu--normalize' for POS."
  (pcase pos
    (`(,pos ,fn . ,args)
     `(,pos ,(lambda (name pos _buf orig-fn &rest orig-args)
               (apply orig-fn name pos orig-args))
            ,(current-buffer) ,fn ,@args))
    (_ (if (integerp pos) (copy-marker pos) pos))))

(defun consult-imenu--flatten (prefix face list types)
  "Stub mirroring `consult-imenu--flatten'."
  (mapcan
   (lambda (item)
     (if (imenu--subalist-p item)
         (let* ((name (concat (car item)))
                (next-prefix name)
                (next-face face))
           (add-face-text-property 0 (length name)
                                   'consult-imenu-prefix 'append name)
           (if prefix
               (setq next-prefix (concat prefix "/" name))
             (when-let* ((type (cdr (assoc name types))))
               (put-text-property 0 (length name) 'consult--type (car type) name)
               (setq next-face (cadr type))))
           (consult-imenu--flatten next-prefix next-face (cdr item) types))
       (list (cons
              (if prefix
                  (let ((key (concat prefix " " (car item))))
                    (add-face-text-property (1+ (length prefix)) (length key)
                                            face 'append key)
                    key)
                (car item))
              (consult-imenu--normalize (cdr item))))))
   list))

(defun consult-imenu--compute ()
  "Stub mirroring `consult-imenu--compute'."
  (let* ((imenu-use-markers t)
         (items (imenu--truncate-items
                 (save-excursion
                   (without-restriction
                     (funcall imenu-create-index-function)))))
         (config (cdr (seq-find (lambda (x) (derived-mode-p (car x)))
                                consult-imenu-config))))
    (when-let* ((toplevel (plist-get config :toplevel)))
      (let ((tops (seq-remove (lambda (x) (listp (cdr x))) items))
            (rest (seq-filter (lambda (x) (listp (cdr x))) items)))
        (setq items (nconc rest (and tops (list (cons toplevel tops)))))))
    (consult-imenu--flatten
     nil nil items
     (mapcar (pcase-lambda (`(,x ,y ,z)) (list y x z))
             (plist-get config :types)))))

(defun consult-imenu--items ()
  "Stub mirroring `consult-imenu--items'."
  (unless (equal (car consult-imenu--cache) (buffer-modified-tick))
    (setq consult-imenu--cache
          (cons (buffer-modified-tick) (consult-imenu--compute))))
  (cdr consult-imenu--cache))

(defun consult-imenu--deduplicate (items)
  "Stub mirroring `consult-imenu--deduplicate'."
  (let ((ht (make-hash-table :test #'equal :size (length items))))
    (dolist (item items)
      (if-let* ((count (gethash (car item) ht)))
          (setcar item (format "%s (%s)" (car item)
                               (puthash (car item) (1+ count) ht)))
        (puthash (car item) 0 ht)))))

(defun consult-imenu--narrow ()
  "Stub mirroring `consult-imenu--narrow'."
  (mapcar (lambda (x) (cons (car x) (cadr x)))
          (plist-get (cdr (seq-find (lambda (x) (derived-mode-p (car x)))
                                    consult-imenu-config))
                     :types)))

(defun consult-imenu--group ()
  "Stub mirroring `consult-imenu--group'."
  (when-let* ((narrow (consult-imenu--narrow)))
    (lambda (cand transform)
      (let ((type (get-text-property 0 'consult--type cand)))
        (cond
         ((and transform type)
          (substring cand (1+ (next-single-property-change
                               0 'consult--type cand))))
         (transform cand)
         (type (alist-get type narrow)))))))

(defun consult-imenu ()
  "Stub for `consult-imenu'."
  (interactive)
  (push (list (current-buffer) current-prefix-arg)
        agent-shell-test-consult-imenu-calls)
  nil)

(provide 'consult-imenu)

;;; consult-imenu.el ends here
