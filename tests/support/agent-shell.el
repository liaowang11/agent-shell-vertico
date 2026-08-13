;;; agent-shell.el --- Test stub for agent-shell -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'map)
(require 'seq)

(defconst agent-shell-test-stub-p t
  "Non-nil when the agent-shell test stub is loaded.")

(defvar agent-shell-test-buffers nil)
(defvar agent-shell-test-project-buffers nil)
(defvar agent-shell-test-last-command nil)
(defvar agent-shell-test-last-buffer nil)
(defvar agent-shell-test-last-args nil)
(defvar agent-shell-agent-configs nil)
(defvar agent-shell-test-statuses nil)
(defvar agent-shell-test-project-names nil)
(defvar agent-shell-test-buffer-query-count 0)
(defvar agent-shell-test-status-query-count 0)
(defvar agent-shell-test-subscriptions nil)
(defvar agent-shell-dot-subdir-function nil)
(defvar agent-shell-show-config-icons nil)
(defvar agent-shell-prefer-viewport-interaction nil)
(defvar agent-shell-transcript-file-path-function nil)

(define-derived-mode agent-shell-mode fundamental-mode "Agent-Shell")

(defun agent-shell-buffers ()
  "Return stubbed agent shell buffers."
  (cl-incf agent-shell-test-buffer-query-count)
  agent-shell-test-buffers)

(defun agent-shell-project-buffers ()
  "Return stubbed project agent shell buffers."
  agent-shell-test-project-buffers)

(defun agent-shell-cwd ()
  "Return the current buffer directory."
  default-directory)

(defun agent-shell--project-name ()
  "Return the configured project name for the current buffer."
  (or (cdr (assq (current-buffer) agent-shell-test-project-names))
      (file-name-nondirectory
       (directory-file-name default-directory))))

(cl-defun agent-shell-status (&key shell-buffer)
  "Return the stubbed status for SHELL-BUFFER."
  (cl-incf agent-shell-test-status-query-count)
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

(defvar agent-shell-test-start-buffer nil
  "Stub: buffer returned by `agent-shell--start'.")

(cl-defun agent-shell--start (&rest args)
  "Record a private start action with ARGS."
  (setq agent-shell-test-last-command 'agent-shell--start
        agent-shell-test-last-args args)
  (or agent-shell-test-start-buffer (current-buffer)))

(defun agent-shell--resolved-agent-configs ()
  "Return `agent-shell-agent-configs' with maker entries realized.
Mirrors the real accessor: the variable may be a function returning the
list, and each entry may be a function returning a configuration."
  (mapcar (lambda (entry)
            (if (functionp entry)
                (funcall entry)
              entry))
          (if (functionp agent-shell-agent-configs)
              (funcall agent-shell-agent-configs)
            agent-shell-agent-configs)))

(defun agent-shell--auto-preferred-config ()
  "Return the stubbed preferred config."
  (car (agent-shell--resolved-agent-configs)))

(cl-defun agent-shell-select-config (&key _prompt)
  "Return the stubbed selected config."
  (car agent-shell-agent-configs))

(cl-defun agent-shell--display-viewport-when-ready (&rest args)
  "Record a viewport display request with ARGS."
  (setq agent-shell-test-last-command
        'agent-shell--display-viewport-when-ready
        agent-shell-test-last-args args))

(defun agent-shell--config-icon (&rest _args)
  "Return a stub icon string."
  "[#]")

;; Session config options.  These mirror the real accessors in
;; agent-shell-config.el, which agents such as Claude Code rely on: they
;; advertise the current model only through `configOptions', leaving the
;; session's :model-id and :models fields nil.

(defun agent-shell--config-options (state)
  "Return current config options from STATE."
  (or (map-nested-elt state '(:session :config-options))
      (map-elt state :config-options)))

(defun agent-shell--config-option-by-category (state category)
  "Return a config option in STATE matching CATEGORY, or nil.
Prefers the option whose `:id' equals CATEGORY, as several options may
share a category."
  (let ((matches (seq-filter (lambda (option)
                               (equal category (map-elt option :category)))
                             (agent-shell--config-options state))))
    (or (seq-find (lambda (option)
                    (equal category (map-elt option :id)))
                  matches)
        (car matches))))

(defun agent-shell--config-option-as-models (option)
  "Convert OPTION values to legacy model display shape."
  (mapcar (lambda (value)
            `((:model-id . ,(map-elt value :value))
              (:name . ,(map-elt value :name))
              (:description . ,(map-elt value :description))))
          (map-elt option :options)))

(defun agent-shell--config-option-as-modes (option)
  "Convert OPTION values to legacy mode display shape."
  (mapcar (lambda (value)
            `((:id . ,(map-elt value :value))
              (:name . ,(map-elt value :name))
              (:description . ,(map-elt value :description))))
          (map-elt option :options)))

(defun agent-shell--current-model-id (state)
  "Return current model ID from STATE.
Prefers the \"model\" config option, falls back to session :model-id."
  (or (map-elt (agent-shell--config-option-by-category state "model")
               :current-value)
      (map-nested-elt state '(:session :model-id))))

(defun agent-shell--current-mode-id (state)
  "Return current mode ID from STATE.
Prefers the \"mode\" config option, falls back to session :mode-id."
  (or (map-elt (agent-shell--config-option-by-category state "mode")
               :current-value)
      (map-nested-elt state '(:session :mode-id))))

(defun agent-shell--get-available-models (state)
  "Return available models from STATE, preferring config options."
  (if-let* ((option (agent-shell--config-option-by-category state "model")))
      (agent-shell--config-option-as-models option)
    (map-nested-elt state '(:session :models))))

(defun agent-shell--get-available-modes (state)
  "Return available modes from STATE, preferring config options."
  (if-let* ((option (agent-shell--config-option-by-category state "mode")))
      (agent-shell--config-option-as-modes option)
    (map-nested-elt state '(:session :modes))))

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

(defun agent-shell-markdown--parse-local-link (url)
  "Stub: parse URL as a local file link, like the real parser does.
Strips a `file://' or `file:' prefix and a trailing `#Lnnn' or `:nnn'
line part, and returns nil unless the remaining path names an existing
file."
  (let ((path url)
        (line nil))
    (cond ((string-prefix-p "file://" path)
           (setq path (substring path (length "file://"))))
          ((string-prefix-p "file:" path)
           (setq path (substring path (length "file:")))))
    (when (string-match "\\(?:#L\\|:\\)\\([0-9]+\\)\\(?:-L?\\([0-9]+\\)\\)?\\'"
                        path)
      (setq line (cons (string-to-number (match-string 1 path))
                       (when (match-string 2 path)
                         (string-to-number (match-string 2 path))))
            path (substring path 0 (match-beginning 0))))
    (setq path (expand-file-name path))
    (when (file-exists-p path)
      (list (cons :file path)
            (cons :line-start (car line))
            (cons :line-end (cdr line))))))

(defun agent-shell-markdown--open-link (url)
  "Stub: record URL and route it through `find-file'.
The real opener sends local file links through `find-file'; mirroring
that lets tests observe which `find-file' variant an action rebinds."
  (setq agent-shell-test-opened-link url)
  (find-file url))

(provide 'agent-shell)

;;; agent-shell.el ends here
