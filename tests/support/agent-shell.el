;;; agent-shell.el --- Test stub for agent-shell -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'map)

(defconst agent-shell-test-stub-p t
  "Non-nil when the agent-shell test stub is loaded.")

(defvar agent-shell-test-buffers nil)
(defvar agent-shell-test-project-buffers nil)
(defvar agent-shell-test-last-command nil)
(defvar agent-shell-test-last-buffer nil)
(defvar agent-shell-test-last-args nil)
(defvar agent-shell-agent-configs nil)
(defvar agent-shell-test-statuses nil)
(defvar agent-shell-test-subscriptions nil)
(defvar agent-shell-dot-subdir-function nil)
(defvar agent-shell-show-config-icons nil)
(defvar agent-shell-prefer-viewport-interaction nil)
(defvar agent-shell-transcript-file-path-function nil)

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

(cl-defun agent-shell-status (&key shell-buffer)
  "Return the stubbed status for SHELL-BUFFER."
  (or (cdr (assq (or shell-buffer (current-buffer))
                 agent-shell-test-statuses))
      'ready))

(cl-defun agent-shell-subscribe-to (&key shell-buffer event on-event)
  "Record a subscription for SHELL-BUFFER, EVENT, and ON-EVENT."
  (let ((subscription (list shell-buffer event on-event)))
    (push subscription agent-shell-test-subscriptions)
    subscription))

(cl-defun agent-shell-unsubscribe (&key subscription)
  "Remove stubbed SUBSCRIPTION."
  (setq agent-shell-test-subscriptions
        (delq subscription agent-shell-test-subscriptions)))

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

(defun agent-shell-resume-session (session-id)
  "Record a resume action for SESSION-ID."
  (setq agent-shell-test-last-command 'agent-shell-resume-session
        agent-shell-test-last-args (list session-id)))

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

(defvar agent-shell-test-opened-link nil
  "Stub: last URL passed to `agent-shell-markdown--open-link'.")

(defun agent-shell-markdown-link-url-at-point (&optional pos)
  "Stub: return the `agent-shell-markdown-url' text property at POS."
  (get-text-property (or pos (point)) 'agent-shell-markdown-url))

(defun agent-shell-markdown--open-link (url)
  "Stub: record URL and route it through `find-file'.
The real opener sends local file links through `find-file'; mirroring
that lets tests observe which `find-file' variant an action rebinds."
  (setq agent-shell-test-opened-link url)
  (find-file url))

(provide 'agent-shell)

;;; agent-shell.el ends here
