;;; agent-shell-vertico.el --- Vertico session switcher for agent-shell -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Bill and contributors

;; Author: Bill
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (agent-shell "0") (marginalia "1.0"))
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
(require 'seq)
(require 'subr-x)
(require 'text-property-search)

(declare-function agent-shell--config-icon "agent-shell")
(declare-function agent-shell--display-buffer "agent-shell")
(declare-function agent-shell-viewport--buffer "agent-shell-viewport")
(declare-function agent-shell-attention--clear-buffer "agent-shell-attention")
(declare-function agent-shell-attention--permission-pending-p "agent-shell-attention")

(defvar agent-shell-agent-configs)
(defvar agent-shell-prefer-viewport-interaction)
(defvar agent-shell-show-config-icons)
(defvar consult-imenu-config)
(defvar embark-default-action-overrides)
(defvar embark-keymap-alist)
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
  "Marginalia annotator for CAND in category `agent-shell-session'."
  (when-let ((buf (get-buffer cand)))
    (marginalia--fields
     ((agent-shell-vertico--status buf) :truncate 10 :face 'marginalia-type)
     ((agent-shell-vertico--model-name buf) :truncate 20 :face 'marginalia-value)
     ((agent-shell-vertico--mode-name buf) :truncate 15 :face 'marginalia-mode)
     ((agent-shell-vertico--title buf) :truncate 30 :face 'marginalia-documentation)
     ((agent-shell-vertico--path buf) :truncate -0.5 :face 'marginalia-file-name))))

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

(defun agent-shell-vertico--completion-table (scope)
  "Return a completion table for SCOPE."
  (lambda (string pred action)
    (let ((buffers (seq-filter #'buffer-live-p
                               (agent-shell-vertico--buffers scope))))
      (if (eq action 'metadata)
          `(metadata
            (category . agent-shell-session)
            (affixation-function . ,#'agent-shell-vertico--affixate)
            (display-sort-function . ,#'agent-shell-vertico--sort-candidates)
            (cycle-sort-function . ,#'agent-shell-vertico--sort-candidates))
        (complete-with-action action
                              (mapcar #'buffer-name buffers)
                              string pred)))))

(defun agent-shell-vertico--read-session (prompt scope)
  "Read an agent shell session with PROMPT for SCOPE."
  (completing-read prompt (agent-shell-vertico--completion-table scope)
                   nil t nil 'agent-shell-vertico-history))

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
                agent-shell-agent-configs))))

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
   (list (agent-shell-vertico--read-session "Agent shell: " 'all)))
  (agent-shell-vertico--display-session-other-window buffer-name))

;;;###autoload
(defun agent-shell-vertico-switch-project ()
  "Switch to an `agent-shell' buffer in the current project."
  (interactive)
  (agent-shell-vertico--display-session
   (agent-shell-vertico--read-session "Project agent shell: " 'project)))

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
               '(agent-shell-session . agent-shell-vertico--display-session)))

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
;; Internal (thinking, tool calls, plans, and the agent's intermediate
;; narration — the work it does on the way to an answer), and Response
;; (the final agent message of each interaction).
;;
;; Agents differ in how they stream prose: some emit a single message at
;; the end, others narrate between tool calls as a series of message
;; chunks.  Only the last message chunk of an interaction is its Response;
;; earlier chunks are intermediate narration and join Internal.

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
    (if (<= (length string) width)
        string
      (let* ((cut (substring string 0 width))
             (space (string-match "[ \t][^ \t]*\\'" cut)))
        (concat (string-trim-right (if (and space (> space (/ width 2)))
                                       (substring cut 0 space)
                                     cut))
                "…")))))

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

(defun agent-shell-vertico--imenu-fragment-groups ()
  "Return the Internal and Response imenu groups for the current buffer.
Walk each `agent-shell-ui-state' block once, in buffer order, recording
which message chunk is the last of its interaction.  Every indexed block
joins Internal except those final message chunks, which form Response."
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
                 (qualified-id (map-elt state :qualified-id)))
            (goto-char (prop-match-end match))
            (when (and (not (gethash qualified-id seen))
                       (agent-shell-vertico--imenu-included-p
                        qualified-id (map-elt state :navigatable)))
              (puthash qualified-id t seen)
              (when (agent-shell-vertico--imenu-message-p qualified-id)
                ;; Buffer order means the last chunk seen wins.
                (puthash (agent-shell-vertico--imenu-interaction qualified-id)
                         start final-message))
              (push (cons qualified-id (agent-shell-vertico--imenu-item start))
                    collected))))))
    (let (internal response)
      (dolist (block (nreverse collected))
        (let ((qualified-id (car block))
              (item (cdr block)))
          (if (and (agent-shell-vertico--imenu-message-p qualified-id)
                   (= (cdr item)
                      (gethash (agent-shell-vertico--imenu-interaction qualified-id)
                               final-message)))
              (push item response)
            (push item internal))))
      (append
       (when internal (list (cons "Internal" (nreverse internal))))
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
Grouped as Request (shell only), Internal (thinking, tool calls, and
plans), and Response (the agent's messages).  Suitable as an
`imenu-create-index-function' in both `agent-shell-mode' and
`agent-shell-viewport-view-mode' buffers."
  (append
   (agent-shell-vertico--imenu-requests)
   (agent-shell-vertico--imenu-fragment-groups)))

(defun agent-shell-vertico--imenu-annotation (candidate)
  "Marginalia annotator for an `imenu' CANDIDATE created by this package.
Shows the item's status label (e.g. a tool's completion state).  Returns
nil for imenu candidates from other modes, so the annotator can be
registered against the shared `imenu' category without affecting
unrelated buffers."
  (when-let* ((pos (text-property-not-all 0 (length candidate)
                                          'agent-shell-vertico--imenu nil
                                          candidate))
              (status (get-text-property pos 'agent-shell-vertico--imenu
                                         candidate)))
    (marginalia--fields
     (status :truncate 30 :face 'marginalia-type))))

(defun agent-shell-vertico--imenu-setup ()
  "Install the agent-shell imenu index in the current buffer."
  (setq-local imenu-create-index-function #'agent-shell-vertico--imenu-index)
  (setq-local imenu-auto-rescan t)
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
  (add-to-list 'marginalia-annotators
               '(imenu agent-shell-vertico--imenu-annotation builtin none))
  (with-eval-after-load 'consult-imenu
    (dolist (mode '(agent-shell-mode agent-shell-viewport-view-mode))
      (add-to-list 'consult-imenu-config
                   `(,mode :types ((?r "Request" font-lock-keyword-face)
                                   (?i "Internal" font-lock-function-name-face)
                                   (?p "Response" font-lock-string-face)))))))

(provide 'agent-shell-vertico)

;;; agent-shell-vertico.el ends here
