;;; agent-shell-vertico-transcript.el --- Transcript recall for agent-shell -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Bill and contributors

;; Author: Bill
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (agent-shell "0") (agent-shell-vertico "0.1.0"))
;; Keywords: convenience, tools
;; URL: https://github.com/liaowang11/agent-shell-vertico

;;; Commentary:

;; Project-aware browsing, search, and restoration of `agent-shell'
;; transcripts without a persistent transcript index.

;;; Code:

(require 'agent-shell)
(require 'agent-shell-vertico)
(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'subr-x)

(defvar agent-shell-dot-subdir-function)
(defvar projectile-current-project-on-switch)
(defvar projectile-mode)

(declare-function projectile-project-root "projectile" (&optional dir))
(declare-function projectile-relevant-known-projects "projectile" ())

(defun agent-shell-vertico-transcript--normalize-directory (directory)
  "Return DIRECTORY expanded and terminated with a slash."
  (file-name-as-directory (expand-file-name directory)))

(defun agent-shell-vertico-transcript--current-project-root ()
  "Return the current Projectile or project.el root, or nil."
  (cond
   ((and (bound-and-true-p projectile-mode)
         (fboundp 'projectile-project-root))
    (when-let* ((root (projectile-project-root)))
      (agent-shell-vertico-transcript--normalize-directory root)))
   ((fboundp 'project-current)
    (when-let* ((project (project-current))
                (root (project-root project)))
      (agent-shell-vertico-transcript--normalize-directory root)))))

(defun agent-shell-vertico-transcript--project-roots ()
  "Return known local project roots, with the current project first."
  (let* ((current (agent-shell-vertico-transcript--current-project-root))
         (known
          (cond
           ((and (bound-and-true-p projectile-mode)
                 (fboundp 'projectile-relevant-known-projects))
            (let ((projectile-current-project-on-switch 'keep))
              (projectile-relevant-known-projects)))
           ((fboundp 'project-known-project-roots)
            (project-known-project-roots))))
         roots)
    (dolist (root (cons current known))
      (when (and root (not (file-remote-p root)))
        (setq root
              (agent-shell-vertico-transcript--normalize-directory root))
        (unless (member root roots)
          (setq roots (append roots (list root))))))
    roots))

(defun agent-shell-vertico-transcript--directory (project-root)
  "Return the transcript directory configured for PROJECT-ROOT.

Resolve the path through `agent-shell-dot-subdir-function' without
creating the directory."
  (unless (functionp agent-shell-dot-subdir-function)
    (user-error "`agent-shell-dot-subdir-function' is not a function"))
  (let* ((default-directory
          (agent-shell-vertico-transcript--normalize-directory project-root))
         (directory (funcall agent-shell-dot-subdir-function "transcripts")))
    (unless (and (stringp directory)
                 (not (string-empty-p (string-trim directory))))
      (user-error "Could not resolve transcript directory for %s"
                  project-root))
    (expand-file-name directory default-directory)))

(provide 'agent-shell-vertico-transcript)

;;; agent-shell-vertico-transcript.el ends here
