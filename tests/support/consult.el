;;; consult.el --- Test stub for Consult -*- lexical-binding: t; -*-

;;; Code:

(defvar consult-fontify-preserve t
  "Stubbed Consult option.
Non-nil copies buffer text properties onto completion candidates.")

(defvar consult-after-jump-hook (list #'recenter)
  "Stubbed Consult hook, run after a jump and after each preview.")

(provide 'consult)

;;; consult.el ends here
