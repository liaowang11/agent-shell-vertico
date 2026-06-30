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
(defvar agent-shell-prefer-viewport-interaction nil)

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

(defvar agent-shell-test-viewport-buffer nil
  "Stub: viewport buffer to return from `agent-shell-viewport--buffer'.")

(defvar agent-shell-test-displayed-buffer nil
  "Stub: last buffer passed to `agent-shell--display-buffer'.")

(defun agent-shell--display-buffer (buffer)
  "Stub: record BUFFER as the displayed buffer."
  (setq agent-shell-test-displayed-buffer buffer)
  buffer)

(cl-defun agent-shell-viewport--buffer (&key shell-buffer _existing-only)
  "Stub: return `agent-shell-test-viewport-buffer' or SHELL-BUFFER."
  (or agent-shell-test-viewport-buffer shell-buffer))

(provide 'agent-shell)

;;; agent-shell.el ends here
