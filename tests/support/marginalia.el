;;; marginalia.el --- Test stub for marginalia -*- lexical-binding: t; -*-

;;; Commentary:

;; `marginalia--fields' and `marginalia--field' are macros, and they
;; expand where this package is compiled.  A simplified stand-in would
;; therefore be frozen into the compiled files, and every annotation
;; would lose its truncation, its faces and the marker marginalia aligns
;; by, even for users with the real package installed.  Both macros below
;; expand exactly as marginalia's own do, so the compiled output calls
;; real marginalia at run time.  Keep them in step with upstream.

;;; Code:

(require 'cl-lib)
(require 'mule-util)
(require 'subr-x)

(defface marginalia-type '((t :inherit font-lock-type-face)) "Stub.")
(defface marginalia-value '((t :inherit font-lock-variable-name-face)) "Stub.")
(defface marginalia-mode '((t :inherit font-lock-doc-face)) "Stub.")
(defface marginalia-documentation '((t :inherit font-lock-doc-face)) "Stub.")
(defface marginalia-file-name '((t :inherit font-lock-string-face)) "Stub.")

(defvar marginalia-annotators nil "Stub.")

(defvar marginalia-field-width 80 "Stub.")

(defvar marginalia-separator "  " "Stub.")

(defun marginalia--truncate (string width)
  "Truncate STRING to WIDTH, a column count or a field-width fraction."
  (when (floatp width)
    (setq width (round (* width marginalia-field-width))))
  (when-let* ((newline (string-search "\n" string)))
    (setq string (substring string 0 newline)))
  (if (< width 0)
      (nreverse
       (truncate-string-to-width (reverse string) (- width) 0 ?\s "…"))
    (truncate-string-to-width string width 0 ?\s "…")))

(cl-defmacro marginalia--field (field &key truncate face width format)
  "Format FIELD as marginalia's own field macro does.
TRUNCATE is a truncation width, WIDTH a field width, FORMAT a format
string, and FACE the face to propertize the result with."
  (setq field (if format `(format ,format ,field) `(or ,field "")))
  (when width (setq field `(format ,(format "%%%ds" (- width)) ,field)))
  (when truncate (setq field `(marginalia--truncate ,field ,truncate)))
  (when face
    (setq field (if (or format width truncate)
                    (cl-with-gensyms (formatted)
                      `(let ((,formatted ,field))
                         (put-text-property
                          0 (length ,formatted) 'face ,face ,formatted)
                         ,formatted))
                  `(propertize ,field 'face ,face))))
  field)

(defmacro marginalia--fields (&rest fields)
  "Format annotation FIELDS as marginalia's own fields macro does."
  (let ((left t))
    (cons 'concat
          (mapcan
           (lambda (field)
             (if (not (eq (car field) :left))
                 `(,@(when left
                       (setq left nil)
                       `(#(" " 0 1 (marginalia--align t))))
                   marginalia-separator (marginalia--field ,@field))
               (unless left (error "Left fields must come first"))
               `((marginalia--field ,@(cdr field)))))
           fields))))

(defun marginalia-annotate-imenu (candidate)
  "Stub for marginalia's own imenu annotator.  Annotates CANDIDATE."
  (concat " " candidate " (builtin imenu annotation)"))

(defun marginalia--time (time)
  "Stub for marginalia--time.  Formats TIME as an absolute age."
  (format-time-string "%b %d %H:%M" time))

(defun marginalia--time-relative (time)
  "Stub for marginalia--time-relative.  Formats TIME as a relative age."
  (format "%s ago" (seconds-to-string (float-time (time-since time)))))

(provide 'marginalia)

;;; marginalia.el ends here
