;;; marginalia.el --- Test stub for marginalia -*- lexical-binding: t; -*-

;;; Code:

(defface marginalia-type '((t :inherit font-lock-type-face)) "Stub.")
(defface marginalia-value '((t :inherit font-lock-variable-name-face)) "Stub.")
(defface marginalia-mode '((t :inherit font-lock-doc-face)) "Stub.")
(defface marginalia-documentation '((t :inherit font-lock-doc-face)) "Stub.")
(defface marginalia-file-name '((t :inherit font-lock-string-face)) "Stub.")

(defvar marginalia-annotators nil "Stub.")

(defmacro marginalia--fields (&rest fields)
  "Stub for marginalia--fields. Concatenates field values with spaces."
  `(string-join (list ,@(mapcar (lambda (f) (car f)) fields)) " "))

(provide 'marginalia)

;;; marginalia.el ends here
