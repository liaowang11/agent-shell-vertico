;;; agent-shell.el --- Test stub for agent-shell -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'map)

(defvar agent-shell-test-buffers nil)
(defvar agent-shell-test-project-buffers nil)
(defvar agent-shell-test-last-command nil)
(defvar agent-shell-test-last-buffer nil)
(defvar agent-shell-test-last-args nil)
(defvar agent-shell-agent-configs nil)
(defvar agent-shell-show-config-icons nil)

(define-derived-mode agent-shell-mode fundamental-mode "Agent-Shell")

(defun agent-shell-buffers ()
  "Return stubbed agent shell buffers."
  agent-shell-test-buffers)

(defun agent-shell-project-buffers ()
  "Return stubbed project agent shell buffers."
  agent-shell-test-project-buffers)

(defun agent-shell-cwd ()
  "Return the current buffer directory."
  default-directory)

(defun agent-shell-open-transcript ()
  "Record an open transcript action."
  (interactive)
  (setq agent-shell-test-last-command 'agent-shell-open-transcript
        agent-shell-test-last-buffer (current-buffer)))

(defun agent-shell-view-traffic ()
  "Record a traffic action."
  (interactive)
  (setq agent-shell-test-last-command 'agent-shell-view-traffic
        agent-shell-test-last-buffer (current-buffer)))

(defun agent-shell-toggle-logging ()
  "Record a toggle logging action."
  (interactive)
  (setq agent-shell-test-last-command 'agent-shell-toggle-logging
        agent-shell-test-last-buffer (current-buffer)))

(defun agent-shell-interrupt ()
  "Record an interrupt action."
  (interactive)
  (setq agent-shell-test-last-command 'agent-shell-interrupt
        agent-shell-test-last-buffer (current-buffer)))

(defun agent-shell-set-session-mode ()
  "Record a set session mode action."
  (interactive)
  (setq agent-shell-test-last-command 'agent-shell-set-session-mode
        agent-shell-test-last-buffer (current-buffer)))

(defun agent-shell-set-session-model ()
  "Record a set session model action."
  (interactive)
  (setq agent-shell-test-last-command 'agent-shell-set-session-model
        agent-shell-test-last-buffer (current-buffer)))

(defun agent-shell-start (&rest args)
  "Record a start action with ARGS."
  (setq agent-shell-test-last-command 'agent-shell-start
        agent-shell-test-last-args args))

(defun agent-shell--config-icon (&rest _args)
  "Return a stub icon string."
  "[#]")

(defun agent-shell-restart (&rest args)
  "Record a restart action with ARGS."
  (interactive)
  (setq agent-shell-test-last-command 'agent-shell-restart
        agent-shell-test-last-buffer (current-buffer)
        agent-shell-test-last-args args))

(defun agent-shell-new-shell ()
  "Record a new shell action."
  (interactive)
  (setq agent-shell-test-last-command 'agent-shell-new-shell))

(provide 'agent-shell)

;;; agent-shell.el ends here
