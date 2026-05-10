;;; agent-shell-vertico.el --- Vertico session switcher for agent-shell -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Bill and contributors

;; Author: Bill
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (agent-shell "0"))
;; Keywords: convenience, tools
;; URL: https://github.com/liaowang11/agent-shell-vertico

;;; Commentary:

;; Vertico-friendly completion commands for switching between agent-shell
;; sessions, with optional Embark actions.

;;; Code:

(require 'agent-shell)
(require 'cl-lib)
(require 'map)
(require 'seq)
(require 'subr-x)

(defvar agent-shell-agent-configs nil)
(defvar embark-keymap-alist nil)

(defgroup agent-shell-vertico nil
  "Vertico helpers for `agent-shell'."
  :group 'agent-shell)

(defvar agent-shell-vertico-history nil
  "Minibuffer history for `agent-shell-vertico' commands.")

(defvar-keymap agent-shell-vertico-embark-map
  :doc "Embark actions for `agent-shell-vertico' sessions."
  "c" #'agent-shell-vertico-new-shell
  "k" #'agent-shell-vertico-kill-session
  "r" #'agent-shell-vertico-restart-session
  "i" #'agent-shell-vertico-interrupt-session
  "m" #'agent-shell-vertico-set-session-mode
  "M" #'agent-shell-vertico-set-session-model
  "l" #'agent-shell-vertico-toggle-logging
  "t" #'agent-shell-vertico-view-traffic
  "T" #'agent-shell-vertico-open-transcript)

(defun agent-shell-vertico--buffers (scope)
  "Return candidate buffers for SCOPE."
  (pcase scope
    ('project (agent-shell-project-buffers))
    (_ (agent-shell-buffers))))

(defun agent-shell-vertico--state (buffer)
  "Return the `agent-shell' state for BUFFER."
  (with-current-buffer buffer
    (and (boundp 'agent-shell--state)
         agent-shell--state)))

(defun agent-shell-vertico--session-field (buffer field)
  "Return session FIELD from BUFFER."
  (map-nested-elt (agent-shell-vertico--state buffer)
                  `(:session ,field)))

(defun agent-shell-vertico--lookup-name (id items id-key)
  "Resolve ID in ITEMS using ID-KEY."
  (when id
    (when-let ((item (seq-find
                      (lambda (candidate)
                        (equal id (map-elt candidate id-key)))
                      (append items nil))))
      (or (map-elt item :name) id))))

(defun agent-shell-vertico--mode-name (buffer)
  "Return current session mode name for BUFFER."
  (let ((mode-id (agent-shell-vertico--session-field buffer :mode-id)))
    (or (agent-shell-vertico--lookup-name
         mode-id
         (agent-shell-vertico--session-field buffer :modes)
         :id)
        mode-id
        "-")))

(defun agent-shell-vertico--model-name (buffer)
  "Return current session model name for BUFFER."
  (let ((model-id (agent-shell-vertico--session-field buffer :model-id)))
    (or (agent-shell-vertico--lookup-name
         model-id
         (agent-shell-vertico--session-field buffer :models)
         :model-id)
        model-id
        "-")))

(defun agent-shell-vertico--status (buffer)
  "Return a short status string for BUFFER."
  (with-current-buffer buffer
    (let ((state (agent-shell-vertico--state buffer)))
      (cond
       ((and (fboundp 'shell-maker-busy)
             (condition-case nil
                 (shell-maker-busy)
               (error nil)))
        "Working")
       ((map-nested-elt state '(:session :id)) "Ready")
       ((not (map-elt state :initialized)) "Starting")
       (t "-")))))

(defun agent-shell-vertico--title (buffer)
  "Return the session title for BUFFER."
  (or (agent-shell-vertico--session-field buffer :title) "-"))

(defun agent-shell-vertico--path (buffer)
  "Return a display path for BUFFER."
  (with-current-buffer buffer
    (abbreviate-file-name default-directory)))

(defun agent-shell-vertico--candidate-annotation (buffer widths)
  "Return annotation text for BUFFER using WIDTHS."
  (format (concat "  %-" (number-to-string (alist-get 'status widths)) "s"
                  "  %-" (number-to-string (alist-get 'model widths)) "s"
                  "  %-" (number-to-string (alist-get 'mode widths)) "s"
                  "  %s  %s")
          (agent-shell-vertico--status buffer)
          (agent-shell-vertico--model-name buffer)
          (agent-shell-vertico--mode-name buffer)
          (agent-shell-vertico--title buffer)
          (agent-shell-vertico--path buffer)))

(defun agent-shell-vertico--annotation-widths (buffers)
  "Compute annotation widths for BUFFERS."
  (list
   (cons 'status (max 8 (apply #'max 0 (mapcar (lambda (buffer)
                                                 (string-width
                                                  (agent-shell-vertico--status buffer)))
                                               buffers))))
   (cons 'model (max 5 (apply #'max 0 (mapcar (lambda (buffer)
                                                (string-width
                                                 (agent-shell-vertico--model-name buffer)))
                                              buffers))))
   (cons 'mode (max 4 (apply #'max 0 (mapcar (lambda (buffer)
                                               (string-width
                                                (agent-shell-vertico--mode-name buffer)))
                                             buffers))))))

(defun agent-shell-vertico--affixation-function (buffers)
  "Build an affixation function for BUFFERS."
  (let ((widths (agent-shell-vertico--annotation-widths buffers)))
    (lambda (candidates)
      (mapcar
       (lambda (candidate)
         (let ((buffer (get-buffer candidate)))
           (list candidate
                 ""
                 (if (buffer-live-p buffer)
                     (agent-shell-vertico--candidate-annotation buffer widths)
                   ""))))
       candidates))))

(defun agent-shell-vertico--completion-table (scope)
  "Return a completion table for SCOPE."
  (lambda (string pred action)
    (let ((buffers (seq-filter #'buffer-live-p
                               (agent-shell-vertico--buffers scope))))
      (if (eq action 'metadata)
          `(metadata
            (category . agent-shell-session)
            (display-sort-function . identity)
            (cycle-sort-function . identity)
            (affixation-function . ,(agent-shell-vertico--affixation-function buffers)))
        (complete-with-action action
                              (mapcar #'buffer-name buffers)
                              string pred)))))

(defun agent-shell-vertico--read-session (prompt scope)
  "Read an agent shell session with PROMPT for SCOPE."
  (completing-read prompt (agent-shell-vertico--completion-table scope)
                   nil t nil 'agent-shell-vertico-history))

(defun agent-shell-vertico--session-buffer (buffer)
  "Resolve BUFFER to a live `agent-shell' buffer."
  (or (get-buffer buffer)
      (user-error "No live agent-shell buffer named %s" buffer)))

(defun agent-shell-vertico--ensure-shell-buffer (buffer)
  "Return BUFFER after validating it is an `agent-shell' buffer."
  (unless (buffer-live-p buffer)
    (user-error "Buffer no longer exists"))
  (with-current-buffer buffer
    (unless (derived-mode-p 'agent-shell-mode)
      (user-error "Not an agent-shell buffer")))
  buffer)

(defun agent-shell-vertico--buffer-config (buffer)
  "Return the matching `agent-shell' config for BUFFER, if any."
  (with-current-buffer (agent-shell-vertico--ensure-shell-buffer buffer)
    (let ((buffer-name-prefix
           (replace-regexp-in-string " Agent @ .*$" "" (buffer-name))))
      (seq-find (lambda (config)
                  (string= buffer-name-prefix (map-elt config :buffer-name)))
                agent-shell-agent-configs))))

;;;###autoload
(defun agent-shell-vertico-switch ()
  "Switch to an `agent-shell' buffer."
  (interactive)
  (switch-to-buffer
   (agent-shell-vertico--read-session "Agent shell: " 'all)))

;;;###autoload
(defun agent-shell-vertico-switch-project ()
  "Switch to an `agent-shell' buffer in the current project."
  (interactive)
  (switch-to-buffer
   (agent-shell-vertico--read-session "Project agent shell: " 'project)))

;;;###autoload
(defun agent-shell-vertico-setup-embark ()
  "Register `agent-shell-vertico' actions with Embark."
  (interactive)
  (unless (boundp 'embark-keymap-alist)
    (setq embark-keymap-alist nil))
  (add-to-list 'embark-keymap-alist
               '(agent-shell-session
                 agent-shell-vertico-embark-map
                 embark-buffer-map)))

(defun agent-shell-vertico-new-shell ()
  "Start a new `agent-shell' session."
  (interactive)
  (call-interactively #'agent-shell-new-shell))

(defun agent-shell-vertico-kill-session (buffer)
  "Kill the process for BUFFER."
  (interactive (list (read-buffer "Agent shell: ")))
  (setq buffer (agent-shell-vertico--ensure-shell-buffer
                (agent-shell-vertico--session-buffer buffer)))
  (when (yes-or-no-p (format "Kill agent-shell process in %s? " (buffer-name buffer)))
    (with-current-buffer buffer
      (when-let ((proc (map-nested-elt agent-shell--state '(:client :process))))
        (when (process-live-p proc)
          (comint-send-eof))))))

(defun agent-shell-vertico-restart-session (buffer)
  "Restart BUFFER, reusing its config when available."
  (interactive (list (read-buffer "Agent shell: ")))
  (setq buffer (agent-shell-vertico--ensure-shell-buffer
                (agent-shell-vertico--session-buffer buffer)))
  (let ((config (agent-shell-vertico--buffer-config buffer))
        (buffer-name (buffer-name buffer)))
    (when (yes-or-no-p (format "Restart agent-shell %s? " buffer-name))
      (with-current-buffer buffer
        (when-let ((proc (map-nested-elt agent-shell--state '(:client :process))))
          (when (process-live-p proc)
            (kill-process proc))))
      (kill-buffer buffer)
      (if config
          (agent-shell-start :config config)
        (call-interactively #'agent-shell-new-shell)))))

(defun agent-shell-vertico-open-transcript (buffer)
  "Open transcript for BUFFER."
  (interactive (list (read-buffer "Agent shell: ")))
  (with-current-buffer (agent-shell-vertico--ensure-shell-buffer
                        (agent-shell-vertico--session-buffer buffer))
    (call-interactively #'agent-shell-open-transcript)))

(defun agent-shell-vertico-view-traffic (buffer)
  "View traffic for BUFFER."
  (interactive (list (read-buffer "Agent shell: ")))
  (with-current-buffer (agent-shell-vertico--ensure-shell-buffer
                        (agent-shell-vertico--session-buffer buffer))
    (call-interactively #'agent-shell-view-traffic)))

(defun agent-shell-vertico-toggle-logging (buffer)
  "Toggle logging for BUFFER."
  (interactive (list (read-buffer "Agent shell: ")))
  (with-current-buffer (agent-shell-vertico--ensure-shell-buffer
                        (agent-shell-vertico--session-buffer buffer))
    (call-interactively #'agent-shell-toggle-logging)))

(defun agent-shell-vertico-interrupt-session (buffer)
  "Interrupt BUFFER."
  (interactive (list (read-buffer "Agent shell: ")))
  (with-current-buffer (agent-shell-vertico--ensure-shell-buffer
                        (agent-shell-vertico--session-buffer buffer))
    (call-interactively #'agent-shell-interrupt)))

(defun agent-shell-vertico-set-session-mode (buffer)
  "Set session mode for BUFFER."
  (interactive (list (read-buffer "Agent shell: ")))
  (with-current-buffer (agent-shell-vertico--ensure-shell-buffer
                        (agent-shell-vertico--session-buffer buffer))
    (call-interactively #'agent-shell-set-session-mode)))

(defun agent-shell-vertico-set-session-model (buffer)
  "Set session model for BUFFER."
  (interactive (list (read-buffer "Agent shell: ")))
  (with-current-buffer (agent-shell-vertico--ensure-shell-buffer
                        (agent-shell-vertico--session-buffer buffer))
    (call-interactively #'agent-shell-set-session-model)))

(provide 'agent-shell-vertico)

;;; agent-shell-vertico.el ends here
