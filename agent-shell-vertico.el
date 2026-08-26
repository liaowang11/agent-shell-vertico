;;; agent-shell-vertico.el --- Vertico session switcher for agent-shell -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Bill and contributors

;; Author: Bill
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (agent-shell "0.63.5") (marginalia "2.1"))
;; Keywords: convenience, tools
;; URL: https://github.com/liaowang11/agent-shell-vertico

;;; Commentary:

;; Vertico-friendly completion commands for switching between agent-shell
;; sessions, with optional Embark actions.

;;; Code:

(require 'agent-shell)
(require 'cl-lib)
(require 'imenu)
(require 'map)
(require 'marginalia)
(require 'mule-util)
(require 'seq)
(require 'subr-x)
(require 'text-property-search)

(declare-function agent-shell--config-icon "agent-shell")
(declare-function agent-shell--current-mode-id "agent-shell-config")
(declare-function agent-shell--current-model-id "agent-shell-config")
(declare-function agent-shell--get-available-models "agent-shell-config")
(declare-function agent-shell--get-available-modes "agent-shell")
(declare-function agent-shell--auto-preferred-config "agent-shell" ())
(declare-function agent-shell--display-viewport-when-ready
                  "agent-shell" (&rest arguments))
(declare-function agent-shell--resolved-agent-configs "agent-shell" ())
(declare-function agent-shell--display-buffer "agent-shell")
(declare-function agent-shell--start "agent-shell" (&rest arguments))
(declare-function agent-shell-resume-session "agent-shell" (session-id))
(declare-function agent-shell-select-config "agent-shell" (&rest arguments))
(declare-function agent-shell-viewport--buffer "agent-shell-viewport")
(declare-function agent-shell-attention--clear-buffer "agent-shell-attention")
(declare-function agent-shell-attention--permission-pending-p "agent-shell-attention")
(declare-function agent-shell-markdown-link-url-at-point "agent-shell-markdown")
(declare-function agent-shell-markdown--open-link "agent-shell-markdown")
(declare-function agent-shell-markdown--parse-local-link "agent-shell-markdown")
(declare-function agent-shell-ui--set-group-collapsed "agent-shell-ui"
                  (group-qualified-id collapsed))
(declare-function agent-shell-ui-toggle-fragment "agent-shell-ui" ())
(declare-function embark-open-externally "embark")
(declare-function comint-send-eof "comint" ())

(defvar agent-shell--state)
(defvar agent-shell-agent-configs)
(defvar agent-shell-prefer-viewport-interaction)
(defvar agent-shell-preferred-agent-config)
(defvar agent-shell-show-config-icons)
(defvar consult-imenu-config)
(defvar embark-default-action-overrides)
(defvar embark-keymap-alist)
(defvar embark-target-finders)
(defvar marginalia-annotators)

(defgroup agent-shell-vertico nil
  "Vertico helpers for `agent-shell'."
  :group 'agent-shell)

(defcustom agent-shell-vertico-sort-by 'recency
  "Sort criterion for session candidates.
Must be one of `recency', `creation', or `status'.

- `recency' sorts most recently displayed sessions first.
- `creation' sorts sessions alphabetically by buffer name.
- `status' sorts sessions with Ready status first, then Working,
  Starting, and other states."
  :type '(choice (const recency) (const creation) (const status))
  :group 'agent-shell-vertico)

(defcustom agent-shell-vertico-imenu-name-width 80
  "Maximum width of an imenu item name before truncation.
Longer names are truncated on a word boundary with a trailing
ellipsis.  Keep this comfortably below your completion window's width
so the ellipsis stays visible and item annotations are not crowded."
  :type 'integer
  :group 'agent-shell-vertico)

(defvar agent-shell-vertico-history nil
  "Minibuffer history for `agent-shell-vertico' commands.")

(defvar agent-shell-vertico-read-session-function
  #'agent-shell-vertico--completing-read-session
  "Function used to read a live agent-shell session.

It receives a prompt, the completion table of sessions to offer, and an
optional OTHER-WINDOW flag saying where the caller will display the
chosen session.  The core implementation reads with `completing-read';
loading `agent-shell-vertico-consult' replaces it with a reader that
previews the session under point.")

(defvar agent-shell-vertico--imenu-fallback-annotator
  #'marginalia-annotate-imenu
  "Annotator used for imenu candidates not created by this package.")

(defvar-keymap agent-shell-vertico-embark-map
  :doc "Embark actions for `agent-shell-vertico' sessions."
  "o" #'agent-shell-vertico-switch-other-window
  "c" #'agent-shell-vertico-new-shell
  "k" #'agent-shell-vertico-kill-session
  "r" #'agent-shell-vertico-restart-session
  "i" #'agent-shell-vertico-interrupt-session
  "m" #'agent-shell-vertico-set-session-mode
  "M" #'agent-shell-vertico-set-session-model
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

;; Mode and model are resolved through agent-shell's own accessors, which
;; prefer the session config option and fall back to the session `:mode-id'
;; and `:model-id' fields.  Reading those fields directly is not enough:
;; agents such as Claude Code advertise the model only as a config option,
;; leaving `:model-id' and `:models' nil, and a mode changed through a config
;; option leaves `:mode-id' stale.

(defun agent-shell-vertico--mode-name (buffer)
  "Return current session mode name for BUFFER."
  (let* ((state (agent-shell-vertico--state buffer))
         (mode-id (agent-shell--current-mode-id state)))
    (or (agent-shell-vertico--lookup-name
         mode-id
         (agent-shell--get-available-modes state)
         :id)
        mode-id
        "-")))

(defun agent-shell-vertico--model-name (buffer)
  "Return current session model name for BUFFER."
  (let* ((state (agent-shell-vertico--state buffer))
         (model-id (agent-shell--current-model-id state)))
    (or (agent-shell-vertico--lookup-name
         model-id
         (agent-shell--get-available-models state)
         :model-id)
        model-id
        "-")))

(defun agent-shell-vertico--agent-name (buffer)
  "Return the agent display name for BUFFER, or nil.

Mirrors the choice `agent-shell' itself makes for its mode line: the
configuration's `:mode-line-name' when set, otherwise its `:buffer-name'."
  (let ((state (agent-shell-vertico--state buffer)))
    (or (map-nested-elt state '(:agent-config :mode-line-name))
        (map-nested-elt state '(:agent-config :buffer-name)))))

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

(defun agent-shell-vertico--suffix (buffer)
  "Return annotation suffix for BUFFER."
  (when (buffer-live-p buffer)
    (marginalia--fields
     ((agent-shell-vertico--status buffer) :truncate 10 :face 'marginalia-type)
     ((agent-shell-vertico--model-name buffer) :truncate 20 :face 'marginalia-value)
     ((agent-shell-vertico--mode-name buffer) :truncate 15 :face 'marginalia-mode)
     ((agent-shell-vertico--title buffer) :truncate 30 :face 'marginalia-documentation)
     ((agent-shell-vertico--path buffer) :truncate -0.5 :face 'marginalia-file-name))))

(defun agent-shell-vertico--icon-prefix (buffer)
  "Return icon image string for BUFFER, or empty string."
  (if-let* ((agent-shell-show-config-icons)
            (state (agent-shell-vertico--state buffer))
            (config (map-elt state :agent-config))
            (icon-str (agent-shell--config-icon :config config)))
      (concat icon-str " ")
    ""))

(defun agent-shell-vertico--affixate (candidates)
  "Add annotation suffix to CANDIDATES."
  (mapcar (lambda (cand)
            (let ((buf (get-buffer cand)))
              (list cand
                    ""
                    (or (and buf (agent-shell-vertico--suffix buf)) ""))))
          candidates))

(defun agent-shell-vertico--annotate (cand)
  "Marginalia annotator for CAND in category `agent-shell-session'.

Renders through `agent-shell-vertico--suffix', which the completion
table's affixation function also uses, so the two cannot drift apart."
  (when-let ((buf (get-buffer cand)))
    (agent-shell-vertico--suffix buf)))

(with-eval-after-load 'nerd-icons-completion
  (cl-defmethod nerd-icons-completion-get-icon (cand (_cat (eql agent-shell-session)))
    "Return the icon for CAND of category `agent-shell-session'."
    (if-let* ((buf (get-buffer cand)))
        (agent-shell-vertico--icon-prefix buf)
      "")))

(add-to-list 'marginalia-annotators
             '(agent-shell-session agent-shell-vertico--annotate none))

(defun agent-shell-vertico--status-priority (status)
  "Return numeric priority for STATUS.  Lower means higher priority."
  (pcase status
    ("Ready" 0)
    ("Working" 1)
    ("Starting" 2)
    (_ 3)))

(defun agent-shell-vertico--sort-candidates (candidates)
  "Sort CANDIDATES according to `agent-shell-vertico-sort-by'."
  (pcase agent-shell-vertico-sort-by
    ('recency
     (cl-sort (copy-sequence candidates) #'>
              :key (lambda (name)
                     (if-let ((buf (get-buffer name))
                              (time (buffer-local-value 'buffer-display-time buf)))
                         (float-time time)
                       0.0))))
    ('creation
     (cl-sort (copy-sequence candidates) #'string<))
    ('status
     (cl-sort (copy-sequence candidates) #'<
              :key (lambda (name)
                     (if-let ((buf (get-buffer name)))
                         (agent-shell-vertico--status-priority
                          (agent-shell-vertico--status buf))
                       3))))
    (_ candidates)))

(defconst agent-shell-vertico--key-char #x100000
  "First character of the private-use range used to key candidates.")

(defconst agent-shell-vertico--key-range #xfffe
  "Number of characters one candidate key character can encode.")

(defun agent-shell-vertico--candidate-key (index)
  "Return an invisible completion key for INDEX.

Completion collapses candidates with equal text, so two candidates that
display the same way would leave one of them unreachable.  The key is
private-use characters carrying `invisible', the approach Consult uses
for repeated lines: candidates stay distinct while the minibuffer shows
the text alone."
  (let ((key nil)
        (remaining index))
    (while (progn
             (setq key
                   (concat
                    (char-to-string
                     (+ agent-shell-vertico--key-char
                        (% remaining agent-shell-vertico--key-range)))
                    key))
             (and (>= remaining agent-shell-vertico--key-range)
                  (setq remaining
                        (/ remaining agent-shell-vertico--key-range)))))
    (propertize key 'invisible t)))

(defun agent-shell-vertico--table (buffers-function)
  "Return a completion table over the buffers BUFFERS-FUNCTION returns.

BUFFERS-FUNCTION is called on each completion request, so a session that
dies while the prompt is open leaves the list."
  (lambda (string pred action)
    (let ((buffers (seq-filter #'buffer-live-p (funcall buffers-function))))
      (if (eq action 'metadata)
          `(metadata
            (category . agent-shell-session)
            (affixation-function . ,#'agent-shell-vertico--affixate)
            (display-sort-function . ,#'agent-shell-vertico--sort-candidates)
            (cycle-sort-function . ,#'agent-shell-vertico--sort-candidates))
        (complete-with-action action
                              (mapcar #'buffer-name buffers)
                              string pred)))))

(defun agent-shell-vertico--completion-table (scope)
  "Return a completion table for SCOPE."
  (agent-shell-vertico--table
   (lambda () (agent-shell-vertico--buffers scope))))

(defun agent-shell-vertico--completing-read-session
    (prompt table &optional _other-window)
  "Read a live session with PROMPT from TABLE.

The reader interface passes OTHER-WINDOW so a previewing reader knows
where the session will be displayed.  This reader only returns a
candidate, so it ignores it."
  (completing-read prompt table nil t nil 'agent-shell-vertico-history))

(defun agent-shell-vertico--read-session (prompt scope &optional other-window)
  "Read an agent shell session with PROMPT for SCOPE.

OTHER-WINDOW tells a previewing reader where the selected session will
be displayed.  It does not affect the returned candidate."
  (funcall agent-shell-vertico-read-session-function
           prompt
           (agent-shell-vertico--completion-table scope)
           other-window))

(defun agent-shell-vertico--read-session-buffers
    (prompt buffers &optional other-window)
  "Read a live session with PROMPT from BUFFERS.

BUFFERS is the caller's own set of choices rather than a scope.  Dead
buffers still drop out whenever the table is queried, so a session that
dies while the prompt is open leaves the list."
  (funcall agent-shell-vertico-read-session-function
           prompt
           (agent-shell-vertico--table (lambda () buffers))
           other-window))

(defun agent-shell-vertico--maybe-resolve-viewport (buffer)
  "Return viewport buffer for BUFFER when viewport is preferred.
When `agent-shell-prefer-viewport-interaction' is nil, return
BUFFER unchanged."
  (if agent-shell-prefer-viewport-interaction
      (agent-shell-viewport--buffer :shell-buffer buffer)
    buffer))

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
                (agent-shell--resolved-agent-configs)))))

(defun agent-shell-vertico--clear-attention (shell-buffer)
  "Clear `agent-shell-attention' pending state for SHELL-BUFFER.
Does nothing unless `agent-shell-attention' is loaded.  Mirrors that
package's own jump: a buffer awaiting a permission decision keeps its
pending mark.  The pending mark is keyed on the shell buffer, so this
clears it whether the shell or its viewport is the buffer displayed."
  (when (and (buffer-live-p shell-buffer)
             (fboundp 'agent-shell-attention--clear-buffer)
             (fboundp 'agent-shell-attention--permission-pending-p)
             (not (agent-shell-attention--permission-pending-p shell-buffer)))
    (agent-shell-attention--clear-buffer shell-buffer)))

(defun agent-shell-vertico--display-session (buffer-name)
  "Display agent shell session for BUFFER-NAME.
Uses `agent-shell--display-buffer', resolving viewport when
`agent-shell-prefer-viewport-interaction' is non-nil."
  (let ((shell-buffer (agent-shell-vertico--ensure-shell-buffer
                       (agent-shell-vertico--session-buffer buffer-name))))
    (agent-shell-vertico--clear-attention shell-buffer)
    (agent-shell--display-buffer
     (agent-shell-vertico--maybe-resolve-viewport shell-buffer))))

(defun agent-shell-vertico--display-session-other-window (buffer-name)
  "Display agent shell session for BUFFER-NAME in another window.
Respects `agent-shell-prefer-viewport-interaction'."
  (let ((shell-buffer (agent-shell-vertico--ensure-shell-buffer
                       (agent-shell-vertico--session-buffer buffer-name))))
    (agent-shell-vertico--clear-attention shell-buffer)
    (switch-to-buffer-other-window
     (agent-shell-vertico--maybe-resolve-viewport shell-buffer))))

(defun agent-shell-vertico--live-session-buffer (session-id)
  "Return the live `agent-shell' buffer for SESSION-ID, or nil.
Matches a session still resuming through its `:resume-session-id',
since the active `:session :id' is stamped only once the
asynchronous resume finishes."
  (when session-id
    (seq-find
     (lambda (buffer)
       (and
        (buffer-live-p buffer)
        (with-current-buffer buffer
          (and
           (boundp 'agent-shell--state)
           (or
            (equal
             session-id
             (map-nested-elt agent-shell--state '(:session :id)))
            (equal
             session-id
             (map-elt agent-shell--state :resume-session-id)))))))
     (agent-shell-buffers))))

(defun agent-shell-vertico--resume-session (session-id &optional config)
  "Resume SESSION-ID with CONFIG, the agent that issued it.

A session ID only means something to the agent that created it, so a
session is resumed with its own agent rather than with the preferred
one.  CONFIG is nil when the agent that issued the session is no
longer configured; the preferred agent is then used.

Also respects `agent-shell-prefer-viewport-interaction'.
`agent-shell-resume-session' displays the shell buffer itself, so a
resumed session lands in `agent-shell-mode' even for users who interact
through viewports.  When viewport interaction is preferred, start the
shell without focus and let `agent-shell' display the viewport once the
session is selected, which is what `agent-shell' does when it starts a
shell for a viewport."
  (if (not agent-shell-prefer-viewport-interaction)
      ;; `agent-shell-resume-session' takes no configuration and reads the
      ;; preference itself, so pass CONFIG by binding the preference.
      (let ((agent-shell-preferred-agent-config
             (or config
                 (bound-and-true-p agent-shell-preferred-agent-config))))
        (agent-shell-resume-session session-id))
    (let ((shell-buffer
           (agent-shell--start
            :config (or config
                        (agent-shell--auto-preferred-config)
                        (agent-shell-select-config
                         :prompt "Resume with agent: ")
                        (error "No agent config found"))
            :session-id session-id
            :new-session t
            :no-focus t)))
      (agent-shell--display-viewport-when-ready :shell-buffer shell-buffer)
      shell-buffer)))

;;;###autoload
(defun agent-shell-vertico-switch ()
  "Switch to an `agent-shell' buffer."
  (interactive)
  (agent-shell-vertico--display-session
   (agent-shell-vertico--read-session "Agent shell: " 'all)))

;;;###autoload
(defun agent-shell-vertico-switch-other-window (buffer-name)
  "Switch to agent shell session BUFFER-NAME in another window."
  (interactive
   (list (agent-shell-vertico--read-session "Agent shell: " 'all t)))
  (agent-shell-vertico--display-session-other-window buffer-name))

;;;###autoload
(defun agent-shell-vertico-switch-project ()
  "Switch to an `agent-shell' buffer in the current project."
  (interactive)
  (agent-shell-vertico--display-session
   (agent-shell-vertico--read-session "Project agent shell: " 'project)))

;;; Shell buffer picker
;;
;; Every `agent-shell' command that asks which shell to act on reads through
;; one function: `agent-shell-send-region' and the other senders under a prefix
;; argument, `agent-shell-switch-buffer', the DWIM commands asked to pick a
;; shell, and the session picker's other-shell branch.  That reader builds its
;; own padded columns and declares no completion category, so those prompts
;; show neither the annotations nor the Embark actions the switch commands
;; have.  Reading them through the table above gives every one of them the
;; same list.

(cl-defun agent-shell-vertico--read-shell-buffer
    (&key prompt buffers force-short-names)
  "Read one `agent-shell' buffer, annotated as the switch commands are.

PROMPT and BUFFERS keep the meaning they have in the `agent-shell'
reader this replaces: PROMPT is the prompt string, and BUFFERS the
shells to choose from, defaulting to `agent-shell-buffers'.

FORCE-SHORT-NAMES is accepted and ignored.  Candidates are whole buffer
names, the names `agent-shell-vertico-switch' shows, so a shell reads the
same wherever it is picked.

Returns the chosen buffer.  Signals a `user-error' when there is no
shell to offer or none was chosen, as the reader it replaces does."
  (ignore force-short-names)
  (let* ((candidates (or (seq-filter #'buffer-live-p
                                     (or buffers (agent-shell-buffers)))
                         (user-error "No agent-shell buffers")))
         (selection
          (agent-shell-vertico--read-session-buffers
           (or prompt "Agent shell buffer: ") candidates)))
    (or (get-buffer (substring-no-properties selection))
        (user-error "Nothing selected"))))

;;;###autoload
(defun agent-shell-vertico-setup-shell-buffer-picker ()
  "Annotate every `agent-shell' prompt asking which shell to act on.

The reader those prompts share offers no way in, so this advises it."
  (interactive)
  (advice-add 'agent-shell--read-shell-buffer :override
              #'agent-shell-vertico--read-shell-buffer))


;;; Project-scoped shell commands
;;
;; `agent-shell' asks which shell to act on in two steps: a command such as
;; `agent-shell-send-region' takes the first shell in the current project, and
;; a second command (`agent-shell-send-region-to') or a prefix argument reads
;; one instead.  Choosing between the two before every send is work, and the
;; silent branch picks arbitrarily when a project holds several shells.
;;
;; These commands make one binding decide: the project's only shell is used,
;; several mean a prompt, and a prefix argument reads from every shell,
;; whatever project it belongs to.  The shell at point is deliberately not
;; preferred, so a region in one session can be sent to another.
;;
;; Each command resolves the shell, pins `agent-shell' resolution to it, and
;; then calls the `agent-shell' command, which keeps owning what is sent, how
;; a busy shell is handled, and whether a viewport composes it.

(defun agent-shell-vertico--target-shell (&optional all)
  "Return the `agent-shell' buffer to act on, or nil to leave it open.

With ALL non-nil, read from every live shell.  Otherwise take the
current project's only shell, or read one of them when it has several.

Returns nil when there is nothing to offer, which leaves the choice to
the `agent-shell' command being run: it creates a shell, or reports that
the project has none, exactly as it does when called on its own."
  (if all
      (when (agent-shell-buffers)
        (agent-shell-vertico--session-buffer
         (agent-shell-vertico--read-session "Agent shell: " 'all)))
    (let ((project-shells (seq-filter #'buffer-live-p
                                      (agent-shell-project-buffers))))
      (pcase (length project-shells)
        (0 nil)
        (1 (car project-shells))
        (_ (agent-shell-vertico--session-buffer
            (agent-shell-vertico--read-session
             "Project agent shell: " 'project)))))))

(defmacro agent-shell-vertico--with-target-shell (all &rest body)
  "Run BODY with `agent-shell' resolution pinned to the target shell.

ALL is passed to `agent-shell-vertico--target-shell'.  BODY is an
`agent-shell' command, which resolves the shell it acts on through
`agent-shell--shell-buffer'; pinning that is what carries the answer in,
without BODY having to accept one.

With no shell to pin, BODY runs untouched and resolves as it would on
its own."
  (declare (indent 1) (debug t))
  `(let ((target (agent-shell-vertico--target-shell ,all)))
     (if (not target)
         (progn ,@body)
       (cl-letf (((symbol-function 'agent-shell--shell-buffer)
                  (lambda (&rest _) target)))
         ,@body))))

(defmacro agent-shell-vertico--define-shell-command (name docstring &rest body)
  "Define command NAME running BODY against the project's shell.

DOCSTRING documents what BODY sends; how the shell is chosen is the same
for every one of these commands and is appended to it."
  (declare (indent 2) (doc-string 2) (debug t))
  `(defun ,name (&optional all)
     ,(concat docstring "

Sends to the current project's shell, asking which one when the project
has several.  With a prefix argument ALL, asks across every shell,
whatever project it belongs to.")
     (interactive "P")
     (agent-shell-vertico--with-target-shell all
       ,@body)))

;;;###autoload (autoload 'agent-shell-vertico-send-region "agent-shell-vertico" nil t)
(agent-shell-vertico--define-shell-command agent-shell-vertico-send-region
    "Send the region to an `agent-shell'."
  (agent-shell-send-region))

;;;###autoload (autoload 'agent-shell-vertico-send-file "agent-shell-vertico" nil t)
(agent-shell-vertico--define-shell-command agent-shell-vertico-send-file
    "Send the current file, or the files at point, to an `agent-shell'."
  (agent-shell-send-file nil nil))

;;;###autoload (autoload 'agent-shell-vertico-send-other-file "agent-shell-vertico" nil t)
(agent-shell-vertico--define-shell-command agent-shell-vertico-send-other-file
    "Select a project file and send it to an `agent-shell'."
  (agent-shell-send-file t nil))

;;;###autoload (autoload 'agent-shell-vertico-send-screenshot "agent-shell-vertico" nil t)
(agent-shell-vertico--define-shell-command agent-shell-vertico-send-screenshot
    "Capture a screenshot and send it to an `agent-shell'."
  (agent-shell-send-screenshot))

;;;###autoload (autoload 'agent-shell-vertico-send-clipboard-image "agent-shell-vertico" nil t)
(agent-shell-vertico--define-shell-command agent-shell-vertico-send-clipboard-image
    "Send the clipboard image to an `agent-shell'."
  (agent-shell-send-clipboard-image))

;;;###autoload (autoload 'agent-shell-vertico-send-prompt "agent-shell-vertico" nil t)
(agent-shell-vertico--define-shell-command agent-shell-vertico-send-prompt
    "Read a prompt with the context at point and send it to an `agent-shell'."
  (agent-shell-prompt-send-dwim nil))

;;;###autoload (autoload 'agent-shell-vertico-queue-prompt "agent-shell-vertico" nil t)
(agent-shell-vertico--define-shell-command agent-shell-vertico-queue-prompt
    "Read a prompt with the context at point and queue it for an `agent-shell'."
  (agent-shell-prompt-queue-dwim nil))

;;;###autoload (autoload 'agent-shell-vertico-inject-prompt "agent-shell-vertico" nil t)
(agent-shell-vertico--define-shell-command agent-shell-vertico-inject-prompt
    "Read a prompt with the context at point and inject it into a running turn."
  (agent-shell-prompt-inject-dwim nil))

;;;###autoload (autoload 'agent-shell-vertico-compose "agent-shell-vertico" nil t)
(agent-shell-vertico--define-shell-command agent-shell-vertico-compose
    "Compose a prompt for an `agent-shell' in its own buffer."
  (agent-shell-prompt-compose))


;;; Markdown links
;;
;; `agent-shell' renders `[title](url)' Markdown links, stamping each link's
;; target on the `agent-shell-markdown-url' text property (the `(url)' markup
;; is gone from the buffer).  These give Embark an in-buffer target on those
;; links and actions that reuse agent-shell's own opener, which handles local
;; files, `#Lnnn' line jumps, a binary "open externally" prompt, and a
;; `browse-url' fallback for everything else.  One action steps around that
;; opener to send any link straight to an external program.

(defun agent-shell-vertico--markdown-link-target ()
  "Return the Embark target for the rendered Markdown link at point.
The target is `(agent-shell-url URL BEG . END)' spanning the link's
`agent-shell-markdown-url' property, or nil when point is not on a
rendered link.  Suitable for `embark-target-finders'."
  (when-let* ((url (agent-shell-markdown-link-url-at-point)))
    `(agent-shell-url
      ,url
      ,(or (previous-single-property-change
            (min (1+ (point)) (point-max)) 'agent-shell-markdown-url)
           (point-min))
      . ,(or (next-single-property-change (point) 'agent-shell-markdown-url)
             (point-max)))))

(defun agent-shell-vertico-open-markdown-link (url)
  "Open the rendered agent-shell Markdown link URL.
Uses agent-shell's opener: local files (jumping to any `#Lnnn' line)
open in Emacs, binaries prompt to open externally, and anything else
goes to `browse-url'."
  (interactive "sLink: ")
  (agent-shell-markdown--open-link url))

(defun agent-shell-vertico-open-markdown-link-other-window (url)
  "Open the rendered agent-shell Markdown link URL, files in another window.
Like `agent-shell-vertico-open-markdown-link', but file links open in
another window so the agent buffer stays put."
  (interactive "sLink: ")
  (let ((agent-shell-file-display-action '(display-buffer-pop-up-window)))
    (agent-shell-markdown--open-link url)))

(defun agent-shell-vertico-open-markdown-link-externally (url)
  "Open the rendered agent-shell Markdown link URL outside Emacs.
Hands the link to `embark-open-externally', which runs the operating
system's default program for it.  A link to an existing local file is
resolved to its path first, dropping any `#Lnnn' line, because a
`file:foo.el#L10' link is not something that program understands.

Requires Embark, like every other action in this map."
  (interactive "sLink: ")
  (embark-open-externally
   (if-let* ((parsed (agent-shell-markdown--parse-local-link url)))
       (map-elt parsed :file)
     url)))

(defun agent-shell-vertico-copy-markdown-link (url)
  "Copy the rendered agent-shell Markdown link URL to the kill ring."
  (interactive "sLink: ")
  (kill-new url))

(defvar-keymap agent-shell-vertico-markdown-link-map
  :doc "Embark actions on agent-shell rendered Markdown links."
  "o" #'agent-shell-vertico-open-markdown-link-other-window
  "x" #'agent-shell-vertico-open-markdown-link-externally
  "w" #'agent-shell-vertico-copy-markdown-link)

;;;###autoload
(defun agent-shell-vertico-setup-embark ()
  "Register `agent-shell-vertico' actions with Embark.
Call this only after Embark is loaded."
  (interactive)
  (add-to-list 'embark-keymap-alist
               '(agent-shell-session
                 agent-shell-vertico-embark-map
                 embark-buffer-map))
  (add-to-list 'embark-default-action-overrides
               '(agent-shell-session . agent-shell-vertico--display-session))
  ;; In-buffer rendered Markdown links.
  (add-to-list 'embark-keymap-alist
               '(agent-shell-url agent-shell-vertico-markdown-link-map))
  (add-to-list 'embark-default-action-overrides
               '(agent-shell-url . agent-shell-vertico-open-markdown-link))
  (add-to-list 'embark-target-finders
               #'agent-shell-vertico--markdown-link-target))

(defun agent-shell-vertico-new-shell ()
  "Start a new `agent-shell' session."
  (interactive)
  (call-interactively #'agent-shell-new-shell))

(defun agent-shell-vertico-kill-session (buffer)
  "Kill the process and buffer for BUFFER."
  (interactive (list (read-buffer "Agent shell: ")))
  (setq buffer (agent-shell-vertico--ensure-shell-buffer
                (agent-shell-vertico--session-buffer buffer)))
  (when (yes-or-no-p (format "Kill agent-shell session %s? " (buffer-name buffer)))
    (with-current-buffer buffer
      (when-let ((proc (map-nested-elt agent-shell--state '(:client :process))))
        (when (process-live-p proc)
          (comint-send-eof))))
    (kill-buffer buffer)))

(defun agent-shell-vertico-restart-session (buffer)
  "Restart BUFFER."
  (interactive (list (read-buffer "Agent shell: ")))
  (setq buffer (agent-shell-vertico--ensure-shell-buffer
                (agent-shell-vertico--session-buffer buffer)))
  (with-current-buffer buffer
    (call-interactively #'agent-shell-restart)))

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

;;; Imenu
;;
;; Both `agent-shell-mode' and `agent-shell-viewport-view-mode' render
;; conversation items as fragments carrying an `agent-shell-ui-state'
;; text property.  A single walk of those fragments therefore works in
;; either mode.  Items are grouped as Request (the user's prompts, shell
;; only — read from comint via shell-maker's own `imenu-generic-expression'),
;; Activity (thinking, tool calls, plans, and the agent's intermediate
;; narration — the work it does on the way to an answer), and Response
;; (the final agent message of each interaction).
;;
;; Agents differ in how they stream prose: some emit a single message at
;; the end, others narrate between tool calls as a series of message
;; chunks.  Only the last message chunk of an interaction is its Response;
;; earlier chunks are intermediate narration and join Activity.
;;
;; A run of consecutive tool calls and thoughts renders under one
;; collapsible activity-group header (e.g. "✓ Tool calls 2/2").  That
;; header is its own fragment (`:kind' `group'); its members carry the
;; header's qualified-id in `:group-id'.  Activity keeps the header and
;; members as one ordered, selectable stream, prefixing members with `↳'.

(defun agent-shell-vertico--imenu-message-p (qualified-id)
  "Return non-nil when QUALIFIED-ID names an agent message chunk."
  (string-suffix-p "-agent_message_chunk" qualified-id))

(defun agent-shell-vertico--imenu-interaction (qualified-id)
  "Return the interaction id encoded at the front of QUALIFIED-ID."
  (car (split-string qualified-id "-")))

(defun agent-shell-vertico--imenu-included-p (qualified-id navigatable)
  "Return non-nil when a fragment should appear in the index.
Agent message chunks are always included; any other fragment must be
navigatable and not an infrastructure or error block."
  (or (agent-shell-vertico--imenu-message-p qualified-id)
      (and navigatable
           (not (string-prefix-p "bootstrapping-" qualified-id))
           (not (string-suffix-p "-unhandled-notification" qualified-id)))))

(defun agent-shell-vertico--imenu-block-end (start qualified-id)
  "Return the end of the `agent-shell-ui-state' block at START.
The block is the contiguous run whose state shares QUALIFIED-ID.
Streaming updates re-apply the property as fresh objects, so the run
may be split into sub-runs with equal ids; this stitches them back."
  (let ((pos start))
    (catch 'done
      (while t
        (let ((next (next-single-property-change pos 'agent-shell-ui-state)))
          (cond
           ((null next) (throw 'done (point-max)))
           ((equal qualified-id
                   (map-elt (get-text-property next 'agent-shell-ui-state)
                            :qualified-id))
            (setq pos next))
           (t (throw 'done next))))))))

(defun agent-shell-vertico--imenu-section (start end section)
  "Return trimmed text of the first SECTION region within \[START, END).
SECTION is an `agent-shell-ui-section' value such as `label-left',
`label-right', or `body'.  Return nil when absent or empty."
  (let ((pos start) found)
    (while (and (< pos end) (not found))
      (if (eq (get-text-property pos 'agent-shell-ui-section) section)
          (setq found pos)
        (setq pos (or (next-single-property-change
                       pos 'agent-shell-ui-section nil end)
                      end))))
    (when found
      (let* ((section-end (or (text-property-not-all
                               found end 'agent-shell-ui-section section)
                              end))
             (text (string-trim
                    (buffer-substring-no-properties found section-end))))
        (unless (string-empty-p text) text)))))

(defun agent-shell-vertico--imenu-first-line (text)
  "Return the first non-blank line of TEXT, trimmed, or nil."
  (when-let* ((text)
              (line (seq-find (lambda (l) (not (string-blank-p l)))
                              (split-string text "\n"))))
    (string-trim line)))

(defun agent-shell-vertico--imenu-truncate (string)
  "Truncate STRING to `agent-shell-vertico-imenu-name-width' columns.
Break on a word boundary where possible, marking truncation with a
trailing ellipsis; fall back to a hard cut for a single long word."
  (let ((width agent-shell-vertico-imenu-name-width))
    (if (<= (string-width string) width)
        string
      ;; Measured in columns, not characters: a title of CJK text occupies
      ;; two columns per character and would otherwise be left at twice the
      ;; width the option promises.
      (let* ((cut (truncate-string-to-width string width 0 nil "…"))
             (space (string-match "[ \t][^ \t]*\\'" cut)))
        (if (and space
                 (> (string-width (substring cut 0 space)) (/ width 2)))
            (concat (string-trim-right (substring cut 0 space)) "…")
          cut)))))

(defun agent-shell-vertico--imenu-candidate (name status)
  "Return NAME, truncated and stamped with its STATUS for annotation.
The stamp is read back by `agent-shell-vertico--imenu-annotation'."
  (let ((candidate (copy-sequence (agent-shell-vertico--imenu-truncate name))))
    (when status
      (put-text-property 0 (length candidate)
                         'agent-shell-vertico--imenu status candidate))
    candidate))

(defun agent-shell-vertico--imenu-item (start)
  "Return (CANDIDATE . START) for the fragment block at START.
CANDIDATE is the item name — the tool title, else the first body line,
else the left label — stamped with its status label for annotation."
  (let* ((qualified-id (map-elt (get-text-property start 'agent-shell-ui-state)
                                :qualified-id))
         (end (agent-shell-vertico--imenu-block-end start qualified-id))
         (label-left (agent-shell-vertico--imenu-section start end 'label-left))
         (name (or (agent-shell-vertico--imenu-section start end 'label-right)
                   (agent-shell-vertico--imenu-first-line
                    (agent-shell-vertico--imenu-section start end 'body))
                   label-left
                   "Item")))
    (cons (agent-shell-vertico--imenu-candidate name label-left) start)))

(defun agent-shell-vertico--imenu-group-title (start)
  "Return the truncated activity-group header label at START.
The header carries its summary (e.g. \"✓ Tool calls 2/2\") in its
`label-left' section and has no body of its own.  Return an imenu item
whose position is the header's own buffer position."
  (let* ((qualified-id (map-elt (get-text-property start 'agent-shell-ui-state)
                                :qualified-id))
         (end (agent-shell-vertico--imenu-block-end start qualified-id)))
    (cons
     (agent-shell-vertico--imenu-truncate
      (or (agent-shell-vertico--imenu-section start end 'label-left)
          "Activity"))
     start)))

(defun agent-shell-vertico--imenu-fragment-stream ()
  "Return the Activity and Response imenu groups for the current buffer.
Walk each `agent-shell-ui-state' block once, in buffer order, recording
which message chunk is the last of its interaction.  Activity-group
headers (`:kind' `group') and their members (`:group-id') remain in one
ordered Activity stream.  Members are prefixed with `↳' so the source
hierarchy remains visible while every entry stays selectable.  Every
other indexed block joins Activity, except final message chunks, which
form Response."
  (let ((seen (make-hash-table :test #'equal))
        (final-message (make-hash-table :test #'equal))
        collected)
    (save-excursion
      (goto-char (point-min))
      ;; `not-current' is nil so a block starting at `point-min' is not
      ;; skipped; advancing to `prop-match-end' each iteration guarantees
      ;; termination, and the per-id dedup keeps the earliest start.
      (let (match)
        (while (setq match (text-property-search-forward
                            'agent-shell-ui-state nil
                            (lambda (_ state) (map-elt state :qualified-id))))
          (let* ((start (prop-match-beginning match))
                 (state (get-text-property start 'agent-shell-ui-state))
                 (qualified-id (map-elt state :qualified-id))
                 (kind (map-elt state :kind)))
            (goto-char (prop-match-end match))
            (when (and (not (gethash qualified-id seen))
                       (or (eq kind 'group)
                           (agent-shell-vertico--imenu-included-p
                            qualified-id (map-elt state :navigatable))))
              (puthash qualified-id t seen)
              (when (and (not (eq kind 'group))
                         (agent-shell-vertico--imenu-message-p qualified-id))
                ;; Buffer order means the last chunk seen wins.
                (puthash (agent-shell-vertico--imenu-interaction qualified-id)
                         start final-message))
              (push (list qualified-id kind (map-elt state :group-id)
                          (if (eq kind 'group)
                              (agent-shell-vertico--imenu-group-title start)
                            (agent-shell-vertico--imenu-item start)))
                    collected))))))
    (let* ((blocks (nreverse collected))
           (groups (make-hash-table :test #'equal))
           (group-member-count (make-hash-table :test #'equal))
           activity response)
      ;; Record headers and the indexed members they own before rendering.
      ;; This lets an empty header disappear without changing the order of
      ;; any non-empty group, even if a stream update arrives out of order.
      (dolist (block blocks)
        (let ((qualified-id (nth 0 block))
              (kind (nth 1 block))
              (group-id (nth 2 block)))
          (if (eq kind 'group)
              (puthash qualified-id t groups)
            (when group-id
              (puthash group-id
                       (1+ (gethash group-id group-member-count 0))
                       group-member-count)))))
      (dolist (block blocks)
        (let ((qualified-id (nth 0 block))
              (kind (nth 1 block))
              (group-id (nth 2 block))
              (item (nth 3 block)))
          (cond
           ;; Keep a group header selectable at its own buffer position.
           ((eq kind 'group)
            (when (> (gethash qualified-id group-member-count 0) 0)
              (push item activity)))
           ;; The final message chunk of its interaction is the Response.
           ((and (agent-shell-vertico--imenu-message-p qualified-id)
                 (= (cdr item)
                    (gethash (agent-shell-vertico--imenu-interaction qualified-id)
                             final-message)))
            (push item response))
           (t
            ;; A member stays in source order beside its header.  The arrow
            ;; distinguishes it from ungrouped activity without hiding its
            ;; status text property.
            (when (and group-id
                       (gethash group-id groups)
                       (> (gethash group-id group-member-count 0) 0))
              (setcar item (concat "↳ " (car item))))
            (push item activity)))))
      (append
       (when activity (list (cons "Activity" (nreverse activity))))
       (when response (list (cons "Response" (nreverse response))))))))

(defun agent-shell-vertico--imenu-requests ()
  "Return the Request imenu group for an `agent-shell' buffer, if any.
Reuses shell-maker's own `imenu-generic-expression', which indexes the
comint prompt lines.  The viewport has no such expression, so requests
are naturally absent there."
  (when (and (derived-mode-p 'agent-shell-mode)
             imenu-generic-expression)
    (when-let* ((items (imenu--generic-function imenu-generic-expression)))
      (list (cons "Request" items)))))

(defun agent-shell-vertico--imenu-index ()
  "Build a nested imenu index of `agent-shell' session items.
Grouped as Request (shell only), Activity (thinking, tool calls, and
plans), and Response (the agent's messages).  Suitable as an
`imenu-create-index-function' in both `agent-shell-mode' and
`agent-shell-viewport-view-mode' buffers."
  (append
   (agent-shell-vertico--imenu-requests)
   (agent-shell-vertico--imenu-fragment-stream)))

(defun agent-shell-vertico--imenu-annotation (candidate)
  "Marginalia annotator for an `imenu' CANDIDATE created by this package.
Shows the item's status label (e.g. a tool's completion state).

This annotator is registered against the shared `imenu' category, and
marginalia consults only the first annotator registered for a category.
Candidates from other modes are therefore passed to
`marginalia-annotate-imenu', which would otherwise be shadowed and every
other mode's imenu would lose its annotations."
  (if-let* ((pos (text-property-not-all 0 (length candidate)
                                        'agent-shell-vertico--imenu nil
                                        candidate))
            (status (get-text-property pos 'agent-shell-vertico--imenu
                                       candidate)))
      (marginalia--fields
       (status :truncate 30 :face 'marginalia-type))
    (pcase agent-shell-vertico--imenu-fallback-annotator
      ('builtin (marginalia-annotate-imenu candidate))
      ('none nil)
      ((and annotator (pred functionp)) (funcall annotator candidate))
      (_ (marginalia-annotate-imenu candidate)))))

(defun agent-shell-vertico--imenu-reveal-at-point ()
  "Reveal the activity group and fragment at point when they are hidden.
The imenu and Consult jump hooks land inside the selected text.  A hidden
activity member first needs its parent group expanded; if its own fragment
is collapsed, expand that fragment as well."
  (when (and (bound-and-true-p agent-shell-ui-mode)
             (invisible-p (point)))
    (let* ((state (get-text-property (point) 'agent-shell-ui-state))
           (group-id (map-elt state :group-id)))
      (when group-id
        (agent-shell-ui--set-group-collapsed group-id nil))
      (when (and (invisible-p (point))
                 (map-elt (get-text-property (point) 'agent-shell-ui-state)
                          :collapsed))
        (agent-shell-ui-toggle-fragment)))))

(defun agent-shell-vertico--imenu-setup ()
  "Install the agent-shell imenu index in the current buffer."
  (setq-local imenu-create-index-function #'agent-shell-vertico--imenu-index)
  (setq-local imenu-auto-rescan t)
  (add-hook 'imenu-after-jump-hook
            #'agent-shell-vertico--imenu-reveal-at-point nil t)
  ;; This package truncates names itself, on a word boundary and with an
  ;; ellipsis, via `agent-shell-vertico-imenu-name-width'.  Disable imenu's
  ;; own hard cut (`imenu-max-item-length', applied by `consult-imenu') so it
  ;; cannot re-truncate names without an ellipsis.
  (setq-local imenu-max-item-length nil))

;;;###autoload
(defun agent-shell-vertico-setup-imenu ()
  "Enable agent-shell session imenu in shell and viewport buffers.
Installs an `imenu-create-index-function' via `agent-shell-mode' and
`agent-shell-viewport-view-mode' hooks, registers a Marginalia
annotator, and configures `consult-imenu' narrowing groups.  Takes
effect for buffers created afterwards."
  (interactive)
  (add-hook 'agent-shell-mode-hook #'agent-shell-vertico--imenu-setup)
  (add-hook 'agent-shell-viewport-view-mode-hook
            #'agent-shell-vertico--imenu-setup)
  (if-let ((entry (assq 'imenu marginalia-annotators)))
      (unless (eq (cadr entry) #'agent-shell-vertico--imenu-annotation)
        (setq agent-shell-vertico--imenu-fallback-annotator (cadr entry))
        (setq marginalia-annotators
              (cons
               (cons 'imenu
                     (cons #'agent-shell-vertico--imenu-annotation
                           (cdr entry)))
               (seq-remove (lambda (item) (eq (car item) 'imenu))
                           marginalia-annotators))))
    (setq agent-shell-vertico--imenu-fallback-annotator 'builtin)
    (push '(imenu agent-shell-vertico--imenu-annotation builtin none)
          marginalia-annotators))
  (with-eval-after-load 'consult-imenu
    (dolist (mode '(agent-shell-mode agent-shell-viewport-view-mode))
      (add-to-list 'consult-imenu-config
                   `(,mode :types ((?r "Request" font-lock-keyword-face)
                                   (?a "Activity" font-lock-function-name-face)
                                   (?p "Response" font-lock-string-face)))))))

(provide 'agent-shell-vertico)

;;; agent-shell-vertico.el ends here
