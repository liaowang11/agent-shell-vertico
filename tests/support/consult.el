;;; consult.el --- Test stub for Consult -*- lexical-binding: t; -*-

;;; Code:

(defvar consult-fontify-preserve t
  "Stubbed Consult option.
Non-nil copies buffer text properties onto completion candidates.")

;; Consult defines this with the same default.  It is a plain `defvar',
;; not a `defcustom', so a value here cannot keep the real package from
;; installing its own.
(defvar consult--buffer-display #'switch-to-buffer
  "Stubbed Consult option.
Function used to display a buffer, which preview reads on each call.")

(defun consult--buffer-preview ()
  "Stub of Consult's buffer preview state function.

Mirrors the real one where tests depend on it: the buffer showing in the
original window is remembered, `preview' displays the candidate buffer
through `consult--buffer-display', and `preview' with no candidate
restores the remembered buffer.  A candidate may be a buffer or a buffer
name, as `consult--buffer-preview' accepts both."
  (let ((original-buffer (window-buffer (selected-window)))
        (other-window nil))
    (lambda (action candidate)
      (when (eq action 'preview)
        (when (and (eq consult--buffer-display #'switch-to-buffer-other-window)
                   (not other-window))
          (switch-to-buffer-other-window original-buffer 'norecord)
          (setq other-window (selected-window)))
        (let ((window (or other-window (selected-window)))
              (buffer (or (and candidate (get-buffer candidate))
                          original-buffer)))
          (when (and (window-live-p window) (buffer-live-p buffer))
            (with-selected-window window
              (switch-to-buffer buffer 'norecord))))))))

(defvar consult-after-jump-hook (list #'recenter)
  "Stubbed Consult hook, run after a jump and after each preview.")

(provide 'consult)

;;; consult.el ends here
