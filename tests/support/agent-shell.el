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
(defvar agent-shell-test-last-target nil
  "Shell buffer the last recorded command resolved through agent-shell.")
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

(defvar-local agent-shell--transcript-file nil
  "Stub: path to the shell's transcript file.")

(defvar agent-shell-test-toggle-fragment-count 0)
(defvar agent-shell-test-group-collapse-calls nil)

(defvar-local agent-shell-ui-mode nil
  "Stubbed agent-shell fold minor mode.")

(defun agent-shell-ui-toggle-fragment ()
  "Record a fold toggle instead of folding."
  (cl-incf agent-shell-test-toggle-fragment-count))

(defun agent-shell-ui--set-group-collapsed (group-qualified-id collapsed)
  "Record a group fold change and reveal its children when expanded.
This mirrors the part of the real private API used by the package: group
children lose their `invisible' property when COLLAPSED is nil."
  (push (list group-qualified-id collapsed)
        agent-shell-test-group-collapse-calls)
  (save-excursion
    (goto-char (point-min))
    (while (< (point) (point-max))
      (let* ((start (point))
             (state (get-text-property start 'agent-shell-ui-state))
             (next (or (next-single-property-change
                        start 'agent-shell-ui-state nil (point-max))
                       (point-max))))
        (when (and state
                   (equal (map-elt state :qualified-id)
                          group-qualified-id))
          (map-put! state :collapsed collapsed)
          (put-text-property start next 'agent-shell-ui-state state))
        (when (and (not collapsed)
                   state
                   (equal (map-elt state :group-id) group-qualified-id)
                   (not (map-elt state :collapsed)))
          (put-text-property start next 'invisible nil))
        (if (> next start)
            (goto-char next)
          (goto-char (point-max)))))))

(defun agent-shell-buffers ()
  "Return stubbed agent shell buffers."
  (cl-incf agent-shell-test-buffer-query-count)
  agent-shell-test-buffers)

(defun agent-shell-project-buffers ()
  "Return stubbed project agent shell buffers."
  agent-shell-test-project-buffers)

(cl-defun agent-shell--read-shell-buffer (&key prompt buffers force-short-names)
  "Read one shell buffer among BUFFERS with PROMPT.

Stands in for the reader `agent-shell' uses for every command that asks
which shell to act on.  Like the real one, it completes over buffer
names, returns the chosen buffer, and refuses a call with no shells to
offer or no shell chosen.  FORCE-SHORT-NAMES is accepted and ignored:
the stub does not shorten names."
  (ignore force-short-names)
  (let* ((candidates (or buffers
                         (agent-shell-buffers)
                         (user-error "No agent-shell buffers")))
         (selection (completing-read (or prompt "Agent shell buffer: ")
                                     (mapcar #'buffer-name candidates)
                                     nil t)))
    (or (get-buffer selection)
        (user-error "Nothing selected"))))

(cl-defun agent-shell--shell-buffer (&key viewport-buffer no-error no-create)
  "Return the stubbed shell buffer for the current project.

Mirrors the real resolver closely enough for callers to observe it: the
first project shell wins, VIEWPORT-BUFFER is ignored, and with none to
find NO-CREATE reports it (or returns nil under NO-ERROR) while the
creating path returns `agent-shell-test-start-buffer'."
  (ignore viewport-buffer)
  (or (seq-first (agent-shell-project-buffers))
      (if no-create
          (unless no-error
            (user-error "No agent shell buffers available for current project"))
        (setq agent-shell-test-last-command 'agent-shell--shell-buffer-created)
        agent-shell-test-start-buffer)))

(defun agent-shell-test--record-send (command &rest args)
  "Record COMMAND and ARGS, resolving the shell the way the real one does."
  (setq agent-shell-test-last-command command
        agent-shell-test-last-args args
        agent-shell-test-last-target (agent-shell--shell-buffer)))

(defun agent-shell-send-region (&optional pick-shell)
  "Record a send region action for PICK-SHELL."
  (interactive)
  (agent-shell-test--record-send 'agent-shell-send-region pick-shell))

(defun agent-shell-send-file (&optional prompt-for-file pick-shell)
  "Record a send file action for PROMPT-FOR-FILE and PICK-SHELL."
  (interactive "P")
  (agent-shell-test--record-send 'agent-shell-send-file
                                 prompt-for-file pick-shell))

(defun agent-shell-send-screenshot (&optional pick-shell)
  "Record a send screenshot action for PICK-SHELL."
  (interactive)
  (agent-shell-test--record-send 'agent-shell-send-screenshot pick-shell))

(defun agent-shell-send-clipboard-image (&optional pick-shell)
  "Record a send clipboard image action for PICK-SHELL."
  (interactive)
  (agent-shell-test--record-send 'agent-shell-send-clipboard-image pick-shell))

(defun agent-shell-prompt-send-dwim (&optional arg)
  "Record a prompt send action for ARG."
  (interactive "P")
  (agent-shell-test--record-send 'agent-shell-prompt-send-dwim arg))

(defun agent-shell-prompt-queue-dwim (&optional arg)
  "Record a prompt queue action for ARG."
  (interactive "P")
  (agent-shell-test--record-send 'agent-shell-prompt-queue-dwim arg))

(defun agent-shell-prompt-steer-dwim (&optional arg)
  "Record a prompt steer action for ARG."
  (interactive "P")
  (agent-shell-test--record-send 'agent-shell-prompt-steer-dwim arg))

(defun agent-shell-prompt-compose ()
  "Record a compose action."
  (interactive)
  (agent-shell-test--record-send 'agent-shell-prompt-compose))

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

(defvar agent-shell-session-choices-function nil)

(defun agent-shell--apply-session-choices (choices)
  "Apply `agent-shell-session-choices-function' to CHOICES.
Mirrors the real validation: the function must return a non-empty list
of choices whose tokens were all offered."
  (if agent-shell-session-choices-function
      (let ((result (funcall agent-shell-session-choices-function choices)))
        (unless (listp result)
          (user-error "Session choices function must return a list, got: %S"
                      result))
        (unless result
          (user-error "Session choices function returned no choices"))
        (let ((tokens (mapcar #'cdr choices)))
          (dolist (choice result)
            (unless (member (cdr choice) tokens)
              (user-error "Session choices returned an unknown token: %S"
                          (cdr choice)))))
        result)
    choices))

(cl-defun agent-shell--session-choice-label (&key acp-session max-widths)
  "Return the picker label for ACP-SESSION.
MAX-WIDTHS pads the columns in the real builder; the stub keeps the
column order and the separator that matter to callers."
  (ignore max-widths)
  (format "%s  %s  %s"
          (file-name-nondirectory
           (directory-file-name (or (map-elt acp-session (quote cwd)) "")))
          (or (map-elt acp-session (quote title)) "Untitled")
          (or (map-elt acp-session (quote updatedAt))
              (map-elt acp-session (quote createdAt))
              "unknown-time")))

(defun agent-shell--prompt-select-session (acp-sessions)
  "Prompt to choose one of ACP-SESSIONS, or nil to start a new shell.
Mirrors the real picker: choices pass through the choices function, a
`completing-read' names one of them, and the label maps back to its
token."
  (let* ((choices (agent-shell--apply-session-choices
                   (append (list (cons "New shell" :new-shell))
                           (mapcar (lambda (acp-session)
                                     (cons (agent-shell--session-choice-label
                                            :acp-session acp-session)
                                           acp-session))
                                   acp-sessions))))
         (selection (completing-read "Start shell: " choices nil t nil nil
                                     (caar choices))))
    (pcase (map-elt choices selection)
      (:new-shell nil)
      (acp-session acp-session))))

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
  "Record a start action with ARGS.
Returns the stubbed shell buffer, as the real command does."
  (setq agent-shell-test-last-command 'agent-shell-start
        agent-shell-test-last-args args)
  (or agent-shell-test-start-buffer (current-buffer)))

(defun agent-shell-resume-session (session-id)
  "Record a resume action for SESSION-ID.
Returns the stubbed shell buffer, as the real command does."
  (setq agent-shell-test-last-command 'agent-shell-resume-session
        agent-shell-test-last-args (list session-id))
  (or agent-shell-test-start-buffer (current-buffer)))

(defvar agent-shell-test-start-buffer nil
  "Stub: buffer returned by `agent-shell--start'.")

(cl-defun agent-shell--initiate-new-session (&rest args)
  "Record a private new-session action with ARGS.
Exists as an advice target for strict resume tests."
  (setq agent-shell-test-last-command 'agent-shell--initiate-new-session
        agent-shell-test-last-args args))

(cl-defun agent-shell--new-shell (&rest args)
  "Record a private new-shell action with ARGS.
Mirrors upstream `agent-shell--new-shell', which takes `:location',
`:config', and `:no-display', starts a shell, and returns its buffer."
  (setq agent-shell-test-last-command 'agent-shell--new-shell
        agent-shell-test-last-args args)
  (or agent-shell-test-start-buffer (current-buffer)))

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

(defun agent-shell--current-shell ()
  "Stub: current shell for a viewport or shell buffer.
Mirrors the real resolver: an `agent-shell-mode' buffer is its own
shell, a viewport buffer resolves to the shell it was created from, and
anything else resolves to nil."
  (cond ((derived-mode-p 'agent-shell-mode)
         (current-buffer))
        ((or (derived-mode-p 'agent-shell-viewport-view-mode)
             (derived-mode-p 'agent-shell-viewport-edit-mode))
         (agent-shell-viewport--shell-buffer))))

(defun agent-shell--get-available-modes (state)
  "Return available modes from STATE, preferring config options."
  (if-let* ((option (agent-shell--config-option-by-category state "mode")))
      (agent-shell--config-option-as-modes option)
    (map-nested-elt state '(:session :modes))))

(cl-defun agent-shell--shell-buffer (&key viewport-buffer no-error no-create)
  "Stub: resolve the shell buffer the way the real resolver does.
A viewport buffer resolves to its shell, an `agent-shell-mode' buffer to
itself, and anything else to the first project shell.  NO-CREATE and
NO-ERROR only cover the no-shell case, which is all this package asks
of it."
  (or (agent-shell-viewport--shell-buffer
       (or viewport-buffer (current-buffer)))
      (if (derived-mode-p 'agent-shell-mode)
          (current-buffer)
        (seq-first (agent-shell-project-buffers)))
      (progn
        (unless (or no-error (not no-create))
          (user-error "No agent shell buffers available for current project"))
        nil)))

(defun agent-shell-prompt-queue-edit (index)
  "Record an edit action for the pending prompt at INDEX."
  (interactive (list 0))
  (setq agent-shell-test-last-command 'agent-shell-prompt-queue-edit
        agent-shell-test-last-buffer (current-buffer)
        agent-shell-test-last-args (list index)))

(defun agent-shell-prompt-queue-remove (&optional remove-index)
  "Record a remove action for REMOVE-INDEX, or for the whole queue."
  (interactive (list nil))
  (setq agent-shell-test-last-command 'agent-shell-prompt-queue-remove
        agent-shell-test-last-buffer (current-buffer)
        agent-shell-test-last-args (list remove-index)))

(defun agent-shell-prompt-queue-steer (index)
  "Record a steer action for the pending prompt at INDEX."
  (interactive (list 0))
  (setq agent-shell-test-last-command 'agent-shell-prompt-queue-steer
        agent-shell-test-last-buffer (current-buffer)
        agent-shell-test-last-args (list index)))

(defun agent-shell-prompt-queue-resume ()
  "Record a resume action for the pending prompt queue."
  (interactive)
  (setq agent-shell-test-last-command 'agent-shell-prompt-queue-resume
        agent-shell-test-last-buffer (current-buffer)
        agent-shell-test-last-args nil))

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

(defconst agent-shell-viewport--suffix " [viewport]"
  "Stub: suffix distinguishing viewport buffers from shell buffers.")

(define-derived-mode agent-shell-viewport-view-mode fundamental-mode
  "Agent Shell Viewport (View)"
  "Stub of the viewport view mode.")

(define-derived-mode agent-shell-viewport-edit-mode fundamental-mode
  "Agent Shell Viewport (Edit)"
  "Stub of the viewport edit mode.")

(cl-defun agent-shell-viewport--shell-buffer (&optional viewport-buffer)
  "Stub: derive the shell buffer for VIEWPORT-BUFFER by name.
Mirrors the real resolver: the viewport buffer name is the shell
buffer name plus the viewport suffix."
  (when-let* ((viewport-name
               (buffer-name (or viewport-buffer (current-buffer))))
              ((string-suffix-p agent-shell-viewport--suffix
                                viewport-name))
              (shell-name
               (substring
                viewport-name 0
                (- (length viewport-name)
                   (length agent-shell-viewport--suffix)))))
    (get-buffer shell-name)))

(cl-defun agent-shell-viewport--buffer (&key shell-buffer existing-only)
  "Stub: return `agent-shell-test-viewport-buffer' or SHELL-BUFFER.

`agent-shell-test-viewport-buffer' stands in for a viewport that already
exists.  With EXISTING-ONLY, return nil when there is none, as the real
resolver does instead of creating one."
  (or agent-shell-test-viewport-buffer
      (unless existing-only shell-buffer)))

(defvar agent-shell-test-opened-link nil
  "Stub: last URL passed to `agent-shell-markdown--open-link'.")

(defvar agent-shell-test-file-display-action nil
  "Stub: `agent-shell-file-display-action' seen by the last open-link call.")

(defcustom agent-shell-file-display-action
  '((display-buffer-reuse-window display-buffer-same-window))
  "Stub: mirrors the real defcustom of the same name."
  :type '(cons (repeat function) alist))

(defun agent-shell-markdown-link-url-at-point (&optional pos)
  "Stub: return the `agent-shell-markdown-url' text property at POS."
  (get-text-property (or pos (point)) 'agent-shell-markdown-url))

(defun agent-shell-markdown--parse-local-link (url)
  "Stub: parse URL as a local file link, like the real parser does.
Strips a `file://' or `file:' prefix and a trailing `#Lnnn' or `:nnn'
line part, and returns nil unless the remaining path names an existing
file.  Like the real parser, `file:' takes only a relative path: an
absolute one must be written `file://'."
  (let ((path url)
        (line nil))
    (cond ((string-prefix-p "file://" path)
           (setq path (substring path (length "file://"))))
          ((string-match "\\`file:\\([^/]\\)" path)
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
  "Stub: record URL and the active `agent-shell-file-display-action'.
The real opener sends local file links through `display-buffer' using
that variable; mirroring that lets tests observe which display action
an action binds."
  (setq agent-shell-test-opened-link url
        agent-shell-test-file-display-action agent-shell-file-display-action))

(provide 'agent-shell)

;;; agent-shell.el ends here
