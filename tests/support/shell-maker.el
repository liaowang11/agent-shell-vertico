;;; shell-maker.el --- Test stub for shell-maker -*- lexical-binding: t; -*-

;;; Commentary:

;; Only the parts `agent-shell-vertico' reads are stubbed.  The two
;; searchers keep shell-maker's own rules for what counts as a real
;; prompt and a real marker, because those rules are what separate a
;; page boundary from text an agent happened to print.

;;; Code:

(require 'cl-lib)

(defvar-local shell-maker--config nil
  "Stub: the shell-maker configuration of the current shell.")

(defvar agent-shell-test-prompt-regexp "^> "
  "Stub: regexp `shell-maker-prompt-regexp' reports.")

(defvar agent-shell-test-history nil
  "Stub: history `shell-maker-history' returns.")

(defun shell-maker-prompt-regexp (_config)
  "Stub: return the prompt regexp of the current shell."
  agent-shell-test-prompt-regexp)

(defun shell-maker-history ()
  "Stub: return the current shell's history."
  agent-shell-test-history)

(defun shell-maker--re-search-forward-prompt (prompt-regexp &optional bound)
  "Search forward for a real prompt matching PROMPT-REGEXP before BOUND.

Mirrors shell-maker: a match only counts when it carries the
`comint-highlight-prompt' face, which is how a prompt is told apart from
the same text inside a response."
  (let (found)
    (while (and (not found)
                (re-search-forward prompt-regexp bound t))
      (when (memq 'comint-highlight-prompt
                  (ensure-list
                   (get-text-property (match-beginning 0) 'font-lock-face)))
        (setq found t)))
    found))

(cl-defun shell-maker--find-marker (marker bound &key (propertized t))
  "Find MARKER before BOUND, returning its (START . END) or nil.

Mirrors shell-maker: with PROPERTIZED non-nil, only text carrying the
`shell-maker--marker' property counts, so identical text in a response
is ignored."
  (save-excursion
    (let (found)
      (while (and (not found)
                  (search-forward marker bound t))
        (when (or (not propertized)
                  (get-text-property (match-beginning 0)
                                     'shell-maker--marker))
          (setq found (cons (match-beginning 0) (match-end 0)))))
      found)))

(provide 'shell-maker)

;;; shell-maker.el ends here
