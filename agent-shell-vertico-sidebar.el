;;; agent-shell-vertico-sidebar.el --- Compact agent-shell sidebar -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Bill and contributors

;; Author: Bill
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (agent-shell "0"))
;; Keywords: convenience, tools
;; URL: https://github.com/liaowang11/agent-shell-vertico

;;; Commentary:

;; A compact, foldable sidebar for live `agent-shell' sessions.  Session
;; blocks use a vertical layout so the sidebar remains useful at a narrow
;; side-window width.  The sidebar can show a flat list or sessions grouped
;; by their agent-shell working directory.

;;; Code:

(require 'agent-shell)
(require 'agent-shell-vertico)
(require 'cl-lib)
(require 'map)
(require 'seq)
(require 'subr-x)

(declare-function agent-shell-status "agent-shell" (&key shell-buffer))
(declare-function agent-shell-cwd "agent-shell-project")
(declare-function agent-shell--project-name "agent-shell" ())
(declare-function agent-shell-subscribe-to "agent-shell"
                  (&key shell-buffer event on-event))
(declare-function agent-shell-unsubscribe "agent-shell" (&key subscription))
(declare-function evil-local-set-key "evil" (state key def))
(declare-function evil-get-auxiliary-keymap "evil"
                  (map state &optional create ignore-parent))
(declare-function evil-next-line "evil" ())
(declare-function evil-previous-line "evil" ())
(declare-function dired-other-window "dired" (dirname))

(defgroup agent-shell-vertico-sidebar nil
  "Compact sidebar for `agent-shell' sessions."
  :group 'agent-shell-vertico)

(defcustom agent-shell-vertico-sidebar-side 'left
  "Side on which to display the agent-shell sidebar."
  :type '(choice (const :tag "Left" left)
                 (const :tag "Right" right))
  :group 'agent-shell-vertico-sidebar)

(defcustom agent-shell-vertico-sidebar-width 40
  "Initial width of the agent-shell sidebar in columns."
  :type 'integer
  :group 'agent-shell-vertico-sidebar)

(defcustom agent-shell-vertico-sidebar-title-max-length 80
  "Maximum number of characters shown for a session title.

Titles up to this limit can wrap over multiple sidebar lines."
  :type 'integer
  :group 'agent-shell-vertico-sidebar)

(defcustom agent-shell-vertico-sidebar-expand-by-default nil
  "Whether project groups start expanded.

An explicit fold or expand action always overrides this default for the
current sidebar buffer."
  :type 'boolean
  :group 'agent-shell-vertico-sidebar)

(defcustom agent-shell-vertico-sidebar-group-by nil
  "Grouping used by the agent-shell sidebar.

`project' renders foldable project headers.  Nil renders one flat list."
  :type '(choice (const :tag "Project" project)
                 (const :tag "Flat" nil))
  :group 'agent-shell-vertico-sidebar)

(defcustom agent-shell-vertico-sidebar-sort-by 'priority
  "Sort criterion used by the agent-shell sidebar.

`priority' puts sessions needing attention first, followed by working,
ready, and starting sessions.  Within a priority tier, attention uses its
entry time and working uses the start of its current busy turn; streamed
activity does not reorder those sessions.  `activity' uses the latest agent
event, `recency' uses the last display time, `status' uses only status, and
`name' sorts by session title."
  :type '(choice (const priority) (const activity) (const recency)
                 (const status) (const name))
  :group 'agent-shell-vertico-sidebar)

(defcustom agent-shell-vertico-sidebar-show-details nil
  "Default visibility for session metadata lines.

The fields themselves are selected with
`agent-shell-vertico-sidebar-extra-info'.  `TAB' overrides this default for
the session at point; `S-TAB' toggles the default for all sessions."
  :type 'boolean
  :group 'agent-shell-vertico-sidebar)

(defcustom agent-shell-vertico-sidebar-extra-info
    '(status project model mode activity)
  "Ordered extra information shown for expanded sessions.

Each selected symbol contributes one value, and values are packed two per
compact row.  In flat mode, `project' is also shown as the session's compact
working-directory context line.  Available symbols are `status', `activity',
`project', `model', `mode', and `last-user-message'.  The latter shows the
latest submitted prompt and is omitted by default."
  :type '(repeat (choice (const :tag "Status" status)
                         (const :tag "Activity age" activity)
                         (const :tag "Project" project)
                         (const :tag "Model" model)
                         (const :tag "Mode" mode)
                         (const :tag "Last user message" last-user-message)))
  :group 'agent-shell-vertico-sidebar)

(defcustom agent-shell-vertico-sidebar-follow-workspaces t
  "Whether the sidebar reopens itself after a workspace switch.

Workspace packages such as persp-mode, used by Doom Emacs, save one window
layout per workspace and restore it on every switch.  A layout saved before
the sidebar existed has no sidebar window, so switching into that workspace
removes the sidebar.  When this is non-nil, a sidebar that was visible
before the switch is reopened right after it."
  :type 'boolean
  :group 'agent-shell-vertico-sidebar)

(defvar agent-shell-vertico-sidebar--attention (make-hash-table :test #'eq)
  "Buffer to attention metadata.

Values are plists with `:kind' (`blocked', `done', or `error') and
`:time'.")

(defvar agent-shell-vertico-sidebar--activity (make-hash-table :test #'eq)
  "Buffer to the latest observed agent activity timestamp.")

(defvar agent-shell-vertico-sidebar--busy-since-times
  (make-hash-table :test #'eq)
  "Buffer to the timestamp when its current busy turn started.")

(defvar agent-shell-vertico-sidebar--subscriptions (make-hash-table :test #'eq)
  "Buffer to its agent-shell event subscription token.")

(defvar-local agent-shell-vertico-sidebar--refresh-timer nil
  "Pending idle sidebar refresh timer.")

(defvar-local agent-shell-vertico-sidebar--age-refresh-timer nil
  "Timer that keeps visible activity ages current.")

(defvar-local agent-shell-vertico-sidebar--resize-timer nil
  "Pending idle sidebar resize timer.")

(defvar-local agent-shell-vertico-sidebar--dirty nil
  "Non-nil when an event changed the sidebar's rendered state.")

(defvar-local agent-shell-vertico-sidebar--last-rendered-width nil
  "Body width used by the most recent sidebar render.")

(defvar-local agent-shell-vertico-sidebar--render-snapshots nil
  "Buffer-to-snapshot table used during one sidebar render.")

(defvar-local agent-shell-vertico-sidebar--expanded-projects nil
  "Hash table of expanded project roots in the current sidebar buffer.")

(defvar-local agent-shell-vertico-sidebar--expanded-sessions nil
  "Hash table of session detail overrides in the current sidebar buffer.

An absent entry follows `agent-shell-vertico-sidebar-show-details'.")

(defface agent-shell-vertico-sidebar-project
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for project headers."
  :group 'agent-shell-vertico-sidebar)

(defface agent-shell-vertico-sidebar-attention
  '((t :inherit error :weight bold))
  "Face for sessions needing attention."
  :group 'agent-shell-vertico-sidebar)

(defface agent-shell-vertico-sidebar-working
  '((t :inherit warning :weight bold))
  "Face for working sessions."
  :group 'agent-shell-vertico-sidebar)

(defface agent-shell-vertico-sidebar-ready
  '((t :inherit success))
  "Face for ready sessions."
  :group 'agent-shell-vertico-sidebar)

(defface agent-shell-vertico-sidebar-detail
  '((t :inherit shadow))
  "Face for secondary session details."
  :group 'agent-shell-vertico-sidebar)

(defun agent-shell-vertico-sidebar--project-root (buffer)
  "Return the normalized project root for BUFFER."
  (or (agent-shell-vertico-sidebar--snapshot-field buffer :root)
      (with-current-buffer buffer
        (file-name-as-directory
         (expand-file-name
          (condition-case nil
              (agent-shell-cwd)
            (error default-directory)))))))

(defun agent-shell-vertico-sidebar--fallback-project-name (root)
  "Return the directory basename for project ROOT."
  (let ((name (file-name-nondirectory (directory-file-name root))))
    (if (string-empty-p name) root name)))

(defun agent-shell-vertico-sidebar--project-name-from-buffer (buffer root)
  "Return agent-shell's project name for BUFFER, falling back to ROOT."
  (or (when (and (buffer-live-p buffer)
                 (fboundp 'agent-shell--project-name))
        (with-current-buffer buffer
          (condition-case nil
              (let ((name (agent-shell--project-name)))
                (and (stringp name)
                     (let ((name (string-trim name)))
                       (unless (string-empty-p name) name))))
            (error nil))))
      (agent-shell-vertico-sidebar--fallback-project-name root)))

(defun agent-shell-vertico-sidebar--project-name (root &optional buffer)
  "Return a compact display name for project ROOT and optional BUFFER."
  (or (and buffer
           (agent-shell-vertico-sidebar--snapshot-field buffer :project-name))
      (and buffer
           (agent-shell-vertico-sidebar--project-name-from-buffer buffer root))
      (agent-shell-vertico-sidebar--fallback-project-name root)))

(defun agent-shell-vertico-sidebar--project-expanded-p (root)
  "Return non-nil when project ROOT should show its sessions."
  (let* ((unset (make-symbol "unset"))
         (value (gethash root agent-shell-vertico-sidebar--expanded-projects
                         unset)))
    (if (eq value unset)
        agent-shell-vertico-sidebar-expand-by-default
      value)))

(defun agent-shell-vertico-sidebar--group-buffers (buffers)
  "Group BUFFERS by normalized project root.

Return an alist whose keys are roots and whose values are buffer lists."
  (let ((groups (make-hash-table :test #'equal))
        roots)
    (dolist (buffer buffers)
      (when (buffer-live-p buffer)
        (let ((root (agent-shell-vertico-sidebar--project-root buffer)))
          (unless (gethash root groups)
            (push root roots))
          (puthash root (cons buffer (gethash root groups)) groups))))
    (mapcar (lambda (root)
              (cons root (nreverse (gethash root groups))))
            (nreverse roots))))

(defun agent-shell-vertico-sidebar--raw-status (buffer)
  "Return the raw status symbol for BUFFER."
  (or (agent-shell-vertico-sidebar--snapshot-field buffer :status)
      (when (fboundp 'agent-shell-status)
        (condition-case nil
            (agent-shell-status :shell-buffer buffer)
          (error nil)))
      (with-current-buffer buffer
        (pcase (agent-shell-vertico--status buffer)
          ("Working" 'busy)
          ("Ready" 'ready)
          ("Starting" 'starting)
          (_ 'unknown)))))

(defun agent-shell-vertico-sidebar--attention (buffer)
  "Return attention metadata for BUFFER, or nil."
  (or (agent-shell-vertico-sidebar--snapshot-field buffer :attention)
      (gethash buffer agent-shell-vertico-sidebar--attention)
      (when (eq (agent-shell-vertico-sidebar--raw-status buffer) 'blocked)
        (list :kind 'blocked
              :time (or (gethash buffer agent-shell-vertico-sidebar--activity)
                        (when-let ((time (buffer-local-value
                                          'buffer-display-time buffer)))
                          (float-time time))
                        0.0)))))

(defun agent-shell-vertico-sidebar--status-name (buffer)
  "Return a display status name for BUFFER."
  (or (agent-shell-vertico-sidebar--snapshot-field buffer :status-name)
      (pcase (plist-get (agent-shell-vertico-sidebar--attention buffer) :kind)
        ('blocked "Waiting")
        ('done "Done")
        ('error "Error")
        (_
         (pcase (agent-shell-vertico-sidebar--raw-status buffer)
           ('busy "Working")
           ('ready (if (agent-shell-vertico--session-field buffer :id)
                       "Ready"
                     "Starting"))
           ('starting "Starting")
           (_ "Unknown"))))))

(defun agent-shell-vertico-sidebar--status-rank (buffer)
  "Return a status rank for BUFFER.  Lower ranks sort first."
  (or (agent-shell-vertico-sidebar--snapshot-field buffer :status-rank)
      (cond
       ((agent-shell-vertico-sidebar--attention buffer) 0)
       ((eq (agent-shell-vertico-sidebar--raw-status buffer) 'busy) 1)
       ((eq (agent-shell-vertico-sidebar--raw-status buffer) 'ready) 2)
       (t 3))))

(defun agent-shell-vertico-sidebar--status-sort-rank (buffer)
  "Return the raw status rank for BUFFER.  Lower ranks sort first.

Unlike `agent-shell-vertico-sidebar--status-rank', this deliberately
ignores attention metadata; attention is the concern of `priority'."
  (or (agent-shell-vertico-sidebar--snapshot-field buffer :raw-status-rank)
      (pcase (agent-shell-vertico-sidebar--raw-status buffer)
        ('blocked 0)
        ('busy 1)
        ('ready 2)
        ('starting 3)
        (_ 4))))

(defun agent-shell-vertico-sidebar--status-rank-for (status attention)
  "Return the priority rank for STATUS and ATTENTION metadata."
  (cond
   (attention 0)
   ((eq status 'busy) 1)
   ((eq status 'ready) 2)
   (t 3)))

(defun agent-shell-vertico-sidebar--status-sort-rank-for (status)
  "Return the raw status rank for STATUS."
  (pcase status
    ('blocked 0)
    ('busy 1)
    ('ready 2)
    ('starting 3)
    (_ 4)))

(defun agent-shell-vertico-sidebar--status-name-for (buffer status attention)
  "Return a display status for BUFFER from STATUS and ATTENTION."
  (pcase (plist-get attention :kind)
    ('blocked "Waiting")
    ('done "Done")
    ('error "Error")
    (_
     (pcase status
       ('busy "Working")
       ('ready (if (agent-shell-vertico--session-field buffer :id)
                   "Ready"
                 "Starting"))
       ('starting "Starting")
       (_ "Unknown")))))

(defun agent-shell-vertico-sidebar--session-snapshot (buffer)
  "Return one render snapshot for live session BUFFER.

The snapshot deliberately reads the live status once.  Sorting, grouping,
header statistics, and row rendering consume the resulting plist instead of
repeating those queries during one redisplay."
  (let* ((status (agent-shell-vertico-sidebar--raw-status buffer))
         (activity-time (agent-shell-vertico-sidebar--activity-time buffer))
         (attention (or (gethash buffer
                                  agent-shell-vertico-sidebar--attention)
                        (when (eq status 'blocked)
                          (list :kind 'blocked :time activity-time))))
         (busy-since-time
          (if (eq status 'busy)
              (or (gethash buffer agent-shell-vertico-sidebar--busy-since-times)
                  (puthash buffer (float-time)
                           agent-shell-vertico-sidebar--busy-since-times))
            (remhash buffer agent-shell-vertico-sidebar--busy-since-times)
            nil))
         (root (agent-shell-vertico-sidebar--project-root buffer))
         (project-name
          (agent-shell-vertico-sidebar--project-name-from-buffer buffer root))
         (recency-time (or (when-let ((time (buffer-local-value
                                             'buffer-display-time buffer)))
                             (float-time time))
                           0.0)))
    (list :buffer buffer
          :root root
          :project-name project-name
          :title (agent-shell-vertico-sidebar--title buffer)
          :status status
          :status-name
          (agent-shell-vertico-sidebar--status-name-for
           buffer status attention)
          :status-rank (agent-shell-vertico-sidebar--status-rank-for
                        status attention)
          :raw-status-rank
          (agent-shell-vertico-sidebar--status-sort-rank-for status)
          :attention attention
          :activity-time activity-time
          :busy-since-time busy-since-time
          :recency-time recency-time
          :model (agent-shell-vertico--model-name buffer)
          :mode (agent-shell-vertico--mode-name buffer)
          :details-visible
          (agent-shell-vertico-sidebar--session-details-expanded-p buffer))))

(defun agent-shell-vertico-sidebar--snapshot-field (buffer field)
  "Return FIELD from BUFFER's current render snapshot, when available."
  (when-let ((snapshot
              (and (hash-table-p agent-shell-vertico-sidebar--render-snapshots)
                   (gethash buffer agent-shell-vertico-sidebar--render-snapshots))))
    (plist-get snapshot field)))

(defun agent-shell-vertico-sidebar--activity-time (buffer)
  "Return latest observed activity time for BUFFER."
  (or (agent-shell-vertico-sidebar--snapshot-field buffer :activity-time)
      (gethash buffer agent-shell-vertico-sidebar--activity)
      (when-let ((time (buffer-local-value 'buffer-display-time buffer)))
        (float-time time))
      0.0))

(defun agent-shell-vertico-sidebar--priority-time (buffer)
  "Return the timestamp used to order BUFFER by priority.

Attention timestamps order sessions waiting for user action.  Working
sessions use the time their current turn entered the busy state; streamed
activity is deliberately not a priority tie-breaker."
  (or (plist-get (agent-shell-vertico-sidebar--attention buffer) :time)
      (agent-shell-vertico-sidebar--snapshot-field buffer :busy-since-time)
      (gethash buffer agent-shell-vertico-sidebar--busy-since-times)
      (when (eq (agent-shell-vertico-sidebar--raw-status buffer) 'busy)
        (puthash buffer (float-time)
                 agent-shell-vertico-sidebar--busy-since-times))
      0.0))

(defun agent-shell-vertico-sidebar--title (buffer)
  "Return a compact title for BUFFER."
  (or (agent-shell-vertico-sidebar--snapshot-field buffer :title)
      (let ((title (agent-shell-vertico--title buffer)))
        (if (or (null title) (string= title "-"))
            (let ((name (buffer-name buffer)))
              (if (string-match " Agent @ \\(.*\\)\\'" name)
                  (match-string 1 name)
                name))
          title))))

(defun agent-shell-vertico-sidebar--last-user-message (buffer)
  "Return the latest submitted user message for BUFFER, or nil."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((start (and (boundp 'comint-last-input-start)
                        (markerp comint-last-input-start)
                        (marker-position comint-last-input-start)))
            (end (and (boundp 'comint-last-input-end)
                      (markerp comint-last-input-end)
                      (marker-position comint-last-input-end))))
        (when (and start end (< start end))
          (let ((message
                 (string-trim
                  (replace-regexp-in-string
                   "[[:space:]]+" " "
                   (buffer-substring-no-properties start end)))))
            (unless (string-empty-p message)
              message)))))))

(defun agent-shell-vertico-sidebar--relative-time (time)
  "Return a compact relative representation of TIME."
  (when (> time 0)
    (let ((seconds (max 0 (- (float-time) time))))
      (cond
       ((< seconds 60) "now")
       ((< seconds 3600) (format "%dm" (floor (/ seconds 60))))
       ((< seconds 86400) (format "%dh" (floor (/ seconds 3600))))
       (t (format "%dd" (floor (/ seconds 86400))))))))

(defun agent-shell-vertico-sidebar--field-help-echo (field)
  "Return the activation hint for metadata FIELD."
  (pcase field
    ('project "RET/mouse-1: open project")
    ('model "RET/mouse-1: set model")
    ('mode "RET/mouse-1: set mode")
    (_ "RET/mouse-1: open session")))

(defun agent-shell-vertico-sidebar--field-text (field text &optional help-echo)
  "Propertize metadata TEXT as FIELD with optional HELP-ECHO."
  (when text
    (let ((help-echo (or help-echo
                         (agent-shell-vertico-sidebar--field-help-echo field))))
      (propertize text
                  'agent-shell-vertico-sidebar-field field
                  'agent-shell-vertico-sidebar-field-help-echo help-echo
                  'mouse-face 'highlight
                  'help-echo help-echo
                  'kbd-help help-echo))))

(defun agent-shell-vertico-sidebar--extra-info-lines
    (buffer root width &optional omit-project)
  "Return selected metadata lines for BUFFER at WIDTH under ROOT.

  Values follow `agent-shell-vertico-sidebar-extra-info' and are packed two
  per row to keep the sidebar compact.  When OMIT-PROJECT is non-nil, the
  project value is omitted because flat rows render it as a context line."
  (let* ((last-message
          (when (memq 'last-user-message
                      agent-shell-vertico-sidebar-extra-info)
            (agent-shell-vertico-sidebar--last-user-message buffer)))
         (values
          (list
           (cons 'status
                 (agent-shell-vertico-sidebar--field-text
                  'status
                  (agent-shell-vertico-sidebar--status-name buffer)))
           (cons 'activity
                 (agent-shell-vertico-sidebar--field-text
                  'activity
                  (agent-shell-vertico-sidebar--relative-time
                   (agent-shell-vertico-sidebar--activity-time buffer))))
           (cons 'project
                 (agent-shell-vertico-sidebar--field-text
                  'project
                  (agent-shell-vertico-sidebar--project-name root buffer)))
           (cons 'model
                 (agent-shell-vertico-sidebar--field-text
                  'model
                  (or (agent-shell-vertico-sidebar--snapshot-field
                       buffer :model)
                      (agent-shell-vertico--model-name buffer))))
           (cons 'mode
                 (agent-shell-vertico-sidebar--field-text
                  'mode
                  (or (agent-shell-vertico-sidebar--snapshot-field
                       buffer :mode)
                      (agent-shell-vertico--mode-name buffer))))
           (cons 'last-user-message
                 (agent-shell-vertico-sidebar--field-text
                  'last-user-message
                  (when last-message
                    (concat "↳ " last-message))))))
         fields)
    (dolist (field agent-shell-vertico-sidebar-extra-info)
      (unless (and omit-project (eq field 'project))
        (when-let ((value (alist-get field values)))
          (push value fields))))
    (setq fields (nreverse fields))
    (let (lines)
      (while fields
        (let ((row (list (pop fields))))
          (when fields
            (setq row (append row (list (pop fields)))))
          (push (cons (agent-shell-vertico-sidebar--fit
                       (agent-shell-vertico-sidebar--join row)
                       width)
                      'agent-shell-vertico-sidebar-detail)
                lines)))
      (nreverse lines))))

(defun agent-shell-vertico-sidebar--flat-project-line (buffer root width)
  "Return the compact flat-row context line for ROOT at WIDTH."
  (when (memq 'project agent-shell-vertico-sidebar-extra-info)
    (cons (agent-shell-vertico-sidebar--field-text
           'project
           (agent-shell-vertico-sidebar--fit
            (concat "⌂ " (agent-shell-vertico-sidebar--project-name
                            root buffer))
            width)
           root)
          'agent-shell-vertico-sidebar-detail)))

(defun agent-shell-vertico-sidebar--session-details-expanded-p (buffer)
  "Return non-nil when BUFFER's detail lines should be shown.

An explicit per-session override takes precedence over the customizable
default in `agent-shell-vertico-sidebar-show-details'."
  (let ((unset (make-symbol "unset")))
    (if (hash-table-p agent-shell-vertico-sidebar--expanded-sessions)
        (let ((value (gethash buffer
                              agent-shell-vertico-sidebar--expanded-sessions
                              unset)))
          (if (eq value unset)
              agent-shell-vertico-sidebar-show-details
            value))
      agent-shell-vertico-sidebar-show-details)))

(defun agent-shell-vertico-sidebar--any-session-details-visible-p
    (&optional buffers)
  "Return non-nil when any live session has visible detail lines."
  (seq-some #'agent-shell-vertico-sidebar--session-details-expanded-p
            (seq-filter #'buffer-live-p
                        (or buffers (agent-shell-buffers)))))

(defun agent-shell-vertico-sidebar--join (fields)
  "Join non-empty strings in FIELDS with a middle dot."
  (string-join (seq-filter (lambda (field)
                             (and field (not (string-empty-p field))))
                           fields)
               " · "))

(defun agent-shell-vertico-sidebar--title-display-text (title)
  "Truncate TITLE to the configured display character limit."
  (let* ((limit (max 1 agent-shell-vertico-sidebar-title-max-length))
         (title (string-trim
                 (replace-regexp-in-string "[[:space:]]+" " "
                                           (or title "")))))
    (if (> (length title) limit)
        (concat (substring title 0 (max 0 (1- limit))) "…")
      title)))

(defun agent-shell-vertico-sidebar--wrap-text (text width)
  "Wrap TEXT to WIDTH columns, preserving words where possible."
  (let ((remaining (string-trim (or text "")))
        (width (max 1 width))
        lines)
    (while (> (string-width remaining) width)
      (let* ((piece (truncate-string-to-width remaining width 0 nil nil))
             (cut (max 1 (length piece)))
             (break (and (< cut (length remaining))
                         (string-match "[[:space:]][^[:space:]]*\\'"
                                       piece))))
        (when (and break (> break 0))
          (setq cut break))
        (push (string-trim-right (substring remaining 0 cut)) lines)
        (setq remaining
              (string-trim-left
               (substring remaining
                          (if (and break (> break 0)) (1+ break) cut))))))
    (nreverse (cons remaining lines))))

(defun agent-shell-vertico-sidebar--fit (string width)
  "Fit STRING to WIDTH columns, adding an ellipsis when needed."
  (truncate-string-to-width (or string "") (max 1 width) 0 nil "…"))

(defun agent-shell-vertico-sidebar--icon (buffer)
  "Return the status icon for BUFFER.

A failed request gets its own icon so it is distinguishable from a session
waiting for a permission response or holding unseen output."
  (if (eq (plist-get (agent-shell-vertico-sidebar--attention buffer) :kind)
          'error)
      "✖"
    (pcase (agent-shell-vertico-sidebar--status-rank buffer)
      (0 "▲")
      (1 "◆")
      (2 "✓")
      (_ "○"))))

(defun agent-shell-vertico-sidebar--status-face (buffer)
  "Return the status face for BUFFER."
  (pcase (agent-shell-vertico-sidebar--status-rank buffer)
    (0 'agent-shell-vertico-sidebar-attention)
    (1 'agent-shell-vertico-sidebar-working)
    (2 'agent-shell-vertico-sidebar-ready)
    (_ 'agent-shell-vertico-sidebar-detail)))

(defun agent-shell-vertico-sidebar--compare-buffers (left right sort-by)
  "Return non-nil when LEFT sorts before RIGHT by SORT-BY."
  (let* ((left-title (agent-shell-vertico-sidebar--title left))
         (right-title (agent-shell-vertico-sidebar--title right))
         (left-rank (if (eq sort-by 'status)
                        (agent-shell-vertico-sidebar--status-sort-rank left)
                      (agent-shell-vertico-sidebar--status-rank left)))
         (right-rank (if (eq sort-by 'status)
                         (agent-shell-vertico-sidebar--status-sort-rank right)
                       (agent-shell-vertico-sidebar--status-rank right)))
         (left-time (pcase sort-by
                      ('priority
                       (agent-shell-vertico-sidebar--priority-time left))
                      ('activity
                       (agent-shell-vertico-sidebar--activity-time left))
                      ('recency (or (agent-shell-vertico-sidebar--snapshot-field
                                     left :recency-time)
                                    (when-let ((time (buffer-local-value
                                                       'buffer-display-time left)))
                                      (float-time time))
                                    0.0))
                      (_ 0.0)))
         (right-time (pcase sort-by
                       ('priority
                        (agent-shell-vertico-sidebar--priority-time right))
                       ('activity
                        (agent-shell-vertico-sidebar--activity-time right))
                       ('recency (or (agent-shell-vertico-sidebar--snapshot-field
                                      right :recency-time)
                                     (when-let ((time (buffer-local-value
                                                        'buffer-display-time right)))
                                       (float-time time))
                                     0.0))
                       (_ 0.0))))
    (cond
     ((eq sort-by 'name) (string-lessp left-title right-title))
     ((and (eq sort-by 'status) (/= left-rank right-rank))
      (< left-rank right-rank))
     ((and (eq sort-by 'priority) (/= left-rank right-rank))
      (< left-rank right-rank))
     ((/= left-time right-time) (> left-time right-time))
     ((not (string= left-title right-title))
      (string-lessp left-title right-title))
     (t (string-lessp (buffer-name left) (buffer-name right))))))

(defun agent-shell-vertico-sidebar--sort-buffers (buffers sort-by)
  "Return BUFFERS sorted by SORT-BY."
  (cl-stable-sort (copy-sequence buffers)
                  (lambda (left right)
                    (agent-shell-vertico-sidebar--compare-buffers
                     left right sort-by))))

(defun agent-shell-vertico-sidebar--sort-groups (groups sort-by)
  "Sort grouped BUFFERS GROUPS by SORT-BY."
  (let ((groups
         (mapcar (lambda (group)
                   (cons (car group)
                         (agent-shell-vertico-sidebar--sort-buffers
                          (cdr group) sort-by)))
                 groups)))
    (cl-stable-sort groups
                    (lambda (left right)
                      (if (eq sort-by 'name)
                          (string-lessp
                           (agent-shell-vertico-sidebar--project-name
                            (car left) (cadr left))
                           (agent-shell-vertico-sidebar--project-name
                            (car right) (cadr right)))
                        (agent-shell-vertico-sidebar--compare-buffers
                         (cadr left) (cadr right) sort-by))))))

(defun agent-shell-vertico-sidebar--node-at-point ()
  "Return the node object at point, or nil."
  (get-text-property (line-beginning-position)
                     'agent-shell-vertico-sidebar-node))

(defun agent-shell-vertico-sidebar--node-kind-at-point ()
  "Return the node kind at point, or nil."
  (get-text-property (line-beginning-position)
                     'agent-shell-vertico-sidebar-node-kind))

(defun agent-shell-vertico-sidebar--field-at-point ()
  "Return the metadata field at point, or nil."
  (or (get-text-property (point) 'agent-shell-vertico-sidebar-field)
      (and (> (point) (point-min))
           (get-text-property (1- (point))
                              'agent-shell-vertico-sidebar-field))))

(defun agent-shell-vertico-sidebar--point-node ()
  "Return the node at point as a kind/object cons."
  (cons (agent-shell-vertico-sidebar--node-kind-at-point)
        (agent-shell-vertico-sidebar--node-at-point)))

(defun agent-shell-vertico-sidebar--goto-node (node)
  "Move point to NODE, returning non-nil when found."
  (when (cdr node)
    (goto-char (point-min))
    (let (found)
      (while (and (not found) (not (eobp)))
        (if (and
             (eq (car node) (agent-shell-vertico-sidebar--node-kind-at-point))
             (equal (cdr node) (agent-shell-vertico-sidebar--node-at-point)))
            (setq found t)
          (forward-line 1)))
      found)))

(defun agent-shell-vertico-sidebar--session-lines (buffer root width &optional nested)
  "Return rendered session lines for BUFFER at WIDTH under ROOT."
  (let* ((content-width
          (max 1 (- width (if nested 4 2))))
         (title (agent-shell-vertico-sidebar--title buffer))
         (icon (propertize
                (agent-shell-vertico-sidebar--icon buffer)
                'face (agent-shell-vertico-sidebar--status-face buffer)))
         (details-visible
          (agent-shell-vertico-sidebar--session-details-expanded-p buffer))
         (title-lines
          (agent-shell-vertico-sidebar--wrap-text
           (agent-shell-vertico-sidebar--title-display-text title)
           content-width))
         (project-line
          (when (not nested)
            (agent-shell-vertico-sidebar--flat-project-line
             buffer root content-width)))
         (detail-lines
          (when details-visible
            (agent-shell-vertico-sidebar--extra-info-lines
             buffer root content-width (not nested)))))
    (setq title-lines
          (cons (concat icon " " (car title-lines))
                (cdr title-lines)))
    (append (mapcar (lambda (line) (cons line nil)) title-lines)
            (when project-line (list project-line))
            detail-lines)))

(defun agent-shell-vertico-sidebar--restore-field-properties (start end)
  "Restore field-specific hover properties between START and END."
  (let ((position start))
    (while (< position end)
      (let ((next (or (next-single-property-change
                      position 'agent-shell-vertico-sidebar-field nil end)
                      end)))
        (when-let ((help-echo
                    (get-text-property
                     position 'agent-shell-vertico-sidebar-field-help-echo)))
          (add-text-properties position next
                               (list 'mouse-face 'highlight
                                     'help-echo help-echo)))
        (setq position next)))))

(defun agent-shell-vertico-sidebar--insert-row (lines kind node &optional nested)
  "Insert session LINES with KIND and NODE text properties.

NESTED adds the visual indentation used for sessions below a project
header; flat rows keep their status icon at column zero."
  (let ((start (point))
        (first-prefix (if nested "  " ""))
        (continuation-prefix (if nested "    " "  "))
        (title-end nil)
        (first t))
    (dolist (line lines)
      (insert (if first first-prefix continuation-prefix))
      (let ((line-start (line-beginning-position)))
        (insert (car line))
        (when (cdr line)
          (add-text-properties
           line-start (point)
           (list 'face (cdr line)))))
      (when (null (cdr line))
        (setq title-end (point)))
      (insert "\n")
      (setq first nil))
    (add-text-properties
     start (1- (point))
     (list 'agent-shell-vertico-sidebar-node node
           'agent-shell-vertico-sidebar-node-kind kind))
    (when title-end
      (add-text-properties
       start (1- title-end)
       (list 'mouse-face 'highlight
             'help-echo (buffer-name node)
             'kbd-help "RET/mouse-1: open session")))
    (agent-shell-vertico-sidebar--restore-field-properties
     start (1- (point)))))

(defun agent-shell-vertico-sidebar--insert-project (root buffers width)
  "Insert project header ROOT and its BUFFERS at WIDTH."
  (let* ((expanded
          (agent-shell-vertico-sidebar--project-expanded-p root))
         (attention
          (seq-count #'agent-shell-vertico-sidebar--attention buffers))
         (indicator (if expanded "▾" "▸"))
         (summary (format "%d%s" (length buffers)
                         (if (> attention 0) (format " ▲%d" attention) "")))
         (line (format "%s %s  %s" indicator
                       (agent-shell-vertico-sidebar--project-name
                        root (car buffers))
                       summary))
         (start (point)))
    (insert (agent-shell-vertico-sidebar--fit line width) "\n")
    (add-text-properties
     start (1- (point))
     (list 'face 'agent-shell-vertico-sidebar-project
           'agent-shell-vertico-sidebar-node root
           'agent-shell-vertico-sidebar-node-kind 'project
           'mouse-face 'highlight
           'help-echo "TAB/RET/mouse-1: toggle project"
           'kbd-help "TAB/RET/mouse-1: toggle project"))
    (when expanded
      (dolist (buffer buffers)
        (agent-shell-vertico-sidebar--insert-row
         (agent-shell-vertico-sidebar--session-lines buffer root width t)
         'session buffer t)))))

(defun agent-shell-vertico-sidebar--render ()
  "Render the current sidebar buffer."
  (let* ((buffers (seq-filter #'buffer-live-p (agent-shell-buffers)))
         (snapshots (mapcar #'agent-shell-vertico-sidebar--session-snapshot
                            buffers))
         (snapshot-table (make-hash-table :test #'eq))
         (width (or (when-let ((window (get-buffer-window (current-buffer))))
                      (window-body-width window))
                    agent-shell-vertico-sidebar-width))
         (point-node (agent-shell-vertico-sidebar--point-node))
         (inhibit-read-only t))
    (dolist (snapshot snapshots)
      (puthash (plist-get snapshot :buffer) snapshot snapshot-table))
    (setq-local agent-shell-vertico-sidebar--render-snapshots snapshot-table)
    (unwind-protect
        (progn
          (agent-shell-vertico-sidebar--cancel-refresh)
          (agent-shell-vertico-sidebar--cancel-resize)
          (setq agent-shell-vertico-sidebar--dirty nil
                agent-shell-vertico-sidebar--last-rendered-width width
                header-line-format
                (agent-shell-vertico-sidebar--header-line-from-snapshots
                 snapshots))
          (agent-shell-vertico-sidebar--watch-existing buffers nil t)
          (erase-buffer)
          (if (null buffers)
              (insert (propertize "  No agent-shell sessions\n"
                                  'face 'agent-shell-vertico-sidebar-detail))
            (if agent-shell-vertico-sidebar-group-by
                (dolist (group
                         (agent-shell-vertico-sidebar--sort-groups
                          (agent-shell-vertico-sidebar--group-buffers buffers)
                          agent-shell-vertico-sidebar-sort-by))
                  (agent-shell-vertico-sidebar--insert-project
                   (car group) (cdr group) width))
              (dolist (buffer
                       (agent-shell-vertico-sidebar--sort-buffers
                        buffers agent-shell-vertico-sidebar-sort-by))
                (agent-shell-vertico-sidebar--insert-row
                 (agent-shell-vertico-sidebar--session-lines
                  buffer (agent-shell-vertico-sidebar--project-root buffer)
                  width)
                 'session buffer))))
          (goto-char (point-min))
          (when (and point-node
                     (agent-shell-vertico-sidebar--goto-node point-node))
            (beginning-of-line))
          (agent-shell-vertico-sidebar--ensure-age-refresh snapshots t))
      (setq agent-shell-vertico-sidebar--render-snapshots nil))))

(defun agent-shell-vertico-sidebar--window-size-change (&optional frame)
  "Coalesce a visible sidebar re-render after FRAME's windows resize."
  (when-let ((sidebar (get-buffer "*Agent Shell Sessions*")))
    (when-let ((window (get-buffer-window sidebar frame)))
      (with-current-buffer sidebar
        (let ((width (window-body-width window)))
          (when (and (derived-mode-p 'agent-shell-vertico-sidebar-mode)
                     (not (equal width
                                 agent-shell-vertico-sidebar--last-rendered-width))
                     (not (timerp agent-shell-vertico-sidebar--resize-timer)))
            (setq agent-shell-vertico-sidebar--resize-timer
                  (run-with-idle-timer
                   0.1 nil
                   (lambda ()
                     (when (buffer-live-p sidebar)
                       (with-current-buffer sidebar
                         (setq agent-shell-vertico-sidebar--resize-timer nil)
                         (when-let ((window (get-buffer-window sidebar frame)))
                           (let ((width (window-body-width window)))
                             (when (and
                                    (derived-mode-p
                                     'agent-shell-vertico-sidebar-mode)
                                    (not (equal
                                          width
                                          agent-shell-vertico-sidebar--last-rendered-width)))
                               (setq agent-shell-vertico-sidebar--last-rendered-width
                                     width)
                               (agent-shell-vertico-sidebar--render)))))))))))))))

(defun agent-shell-vertico-sidebar--sidebar-buffer ()
  "Return the sidebar buffer, creating it when necessary."
  (get-buffer-create "*Agent Shell Sessions*"))

(defun agent-shell-vertico-sidebar--sidebar-visible-p (&optional buffer)
  "Return non-nil when BUFFER, or the named sidebar, is visible."
  (when-let ((sidebar (or buffer (get-buffer "*Agent Shell Sessions*"))))
    (get-buffer-window sidebar 'visible)))

(defun agent-shell-vertico-sidebar--cancel-refresh ()
  "Cancel the pending sidebar refresh timer."
  (when (timerp agent-shell-vertico-sidebar--refresh-timer)
    (cancel-timer agent-shell-vertico-sidebar--refresh-timer)
    (setq agent-shell-vertico-sidebar--refresh-timer nil)))

(defun agent-shell-vertico-sidebar--cancel-age-refresh ()
  "Cancel the repeating activity-age refresh timer."
  (when (timerp agent-shell-vertico-sidebar--age-refresh-timer)
    (cancel-timer agent-shell-vertico-sidebar--age-refresh-timer)
    (setq agent-shell-vertico-sidebar--age-refresh-timer nil)))

(defun agent-shell-vertico-sidebar--cancel-resize ()
  "Cancel the pending sidebar resize timer."
  (when (timerp agent-shell-vertico-sidebar--resize-timer)
    (cancel-timer agent-shell-vertico-sidebar--resize-timer)
    (setq agent-shell-vertico-sidebar--resize-timer nil)))

(defun agent-shell-vertico-sidebar--ensure-age-refresh
    (&optional snapshots snapshots-supplied)
  "Keep visible activity ages current while details are displayed.

SNAPSHOTS, when supplied by the current render, avoids rediscovering live
sessions just to decide whether an age timer is needed."
  (let ((sidebar (or (and (derived-mode-p 'agent-shell-vertico-sidebar-mode)
                          (current-buffer))
                     (get-buffer "*Agent Shell Sessions*"))))
    (when sidebar
      (with-current-buffer sidebar
        (let* ((visible (agent-shell-vertico-sidebar--sidebar-visible-p
                         sidebar))
               (activity-configured
                (memq 'activity agent-shell-vertico-sidebar-extra-info))
               (details-visible
                (if snapshots-supplied
                    (seq-some (lambda (snapshot)
                                (plist-get snapshot :details-visible))
                              snapshots)
                  (agent-shell-vertico-sidebar--any-session-details-visible-p)))
               (needed (and visible activity-configured details-visible)))
          (cond
           ((and needed
                 (not (timerp agent-shell-vertico-sidebar--age-refresh-timer)))
            (setq agent-shell-vertico-sidebar--age-refresh-timer
                  (run-with-timer
                   60 60
                   (lambda ()
                     (if (and (buffer-live-p sidebar)
                              (with-current-buffer sidebar
                                (and
                                 (agent-shell-vertico-sidebar--sidebar-visible-p
                                  sidebar)
                                 (memq 'activity
                                       agent-shell-vertico-sidebar-extra-info))))
                         (agent-shell-vertico-sidebar-refresh)
                       (when (buffer-live-p sidebar)
                         (with-current-buffer sidebar
                           (agent-shell-vertico-sidebar--cancel-age-refresh))))))))
           ((not needed)
            (agent-shell-vertico-sidebar--cancel-age-refresh))))))))

(defun agent-shell-vertico-sidebar--schedule-refresh (&rest _args)
  "Mark the sidebar dirty and schedule one idle refresh when visible."
  (when-let ((sidebar (get-buffer "*Agent Shell Sessions*")))
    (with-current-buffer sidebar
      (setq agent-shell-vertico-sidebar--dirty t)
      (if (and (derived-mode-p 'agent-shell-vertico-sidebar-mode)
               (agent-shell-vertico-sidebar--sidebar-visible-p sidebar))
          (when (not (timerp agent-shell-vertico-sidebar--refresh-timer))
            (setq agent-shell-vertico-sidebar--refresh-timer
                  (run-with-idle-timer
                   0.5 nil
                   (lambda ()
                     (when (buffer-live-p sidebar)
                       (with-current-buffer sidebar
                         (setq agent-shell-vertico-sidebar--refresh-timer nil)
                         (when (and agent-shell-vertico-sidebar--dirty
                                    (agent-shell-vertico-sidebar--sidebar-visible-p
                                     sidebar))
                           (agent-shell-vertico-sidebar--render))))))))
        (agent-shell-vertico-sidebar--cancel-refresh)
        (agent-shell-vertico-sidebar--cancel-resize)
        (agent-shell-vertico-sidebar--cancel-age-refresh)))))

(defun agent-shell-vertico-sidebar--handle-event (buffer event)
  "Update sidebar metadata for BUFFER after agent EVENT."
  (let ((kind (map-elt event :event))
        (now (float-time)))
    (puthash buffer now agent-shell-vertico-sidebar--activity)
    (pcase kind
      ('permission-request
       (remhash buffer agent-shell-vertico-sidebar--busy-since-times)
       (puthash buffer (list :kind 'blocked :time now)
                agent-shell-vertico-sidebar--attention))
      ('error
       (remhash buffer agent-shell-vertico-sidebar--busy-since-times)
       (puthash buffer (list :kind 'error :time now)
                agent-shell-vertico-sidebar--attention))
      ('turn-complete
       (remhash buffer agent-shell-vertico-sidebar--busy-since-times)
       (if (get-buffer-window buffer 'visible)
           (remhash buffer agent-shell-vertico-sidebar--attention)
         (puthash buffer (list :kind 'done :time now)
                  agent-shell-vertico-sidebar--attention)))
      ('input-submitted
       (puthash buffer now agent-shell-vertico-sidebar--busy-since-times)
       ;; Submitting a new prompt means the user has seen whatever the
       ;; previous turn produced, so the new turn starts unmarked.  A
       ;; permission request that is still pending is re-derived from the
       ;; live status.
       (remhash buffer agent-shell-vertico-sidebar--attention))
      ('permission-response
       (let ((status (agent-shell-vertico-sidebar--raw-status buffer)))
         (unless (eq status 'blocked)
           (remhash buffer agent-shell-vertico-sidebar--attention))
         (when (eq status 'busy)
           (puthash buffer now agent-shell-vertico-sidebar--busy-since-times))))
      ('idle
       (remhash buffer agent-shell-vertico-sidebar--busy-since-times))
      ('clean-up
       (remhash buffer agent-shell-vertico-sidebar--attention)
       (remhash buffer agent-shell-vertico-sidebar--busy-since-times)
       (remhash buffer agent-shell-vertico-sidebar--activity))
      (_ nil))
    (agent-shell-vertico-sidebar--schedule-refresh)))

(defun agent-shell-vertico-sidebar--unwatch-buffer ()
  "Remove the event subscription for the current agent-shell buffer."
  (let ((subscription (gethash (current-buffer)
                               agent-shell-vertico-sidebar--subscriptions)))
    (when (and subscription (fboundp 'agent-shell-unsubscribe))
      (ignore-errors (agent-shell-unsubscribe :subscription subscription)))
    (remhash (current-buffer) agent-shell-vertico-sidebar--subscriptions)
    (remhash (current-buffer) agent-shell-vertico-sidebar--attention)
    (remhash (current-buffer)
             agent-shell-vertico-sidebar--busy-since-times)
    (remhash (current-buffer) agent-shell-vertico-sidebar--activity)
    (agent-shell-vertico-sidebar--schedule-refresh)))

(defun agent-shell-vertico-sidebar--watch-buffer (&optional buffer schedule)
  "Subscribe to events from BUFFER when supported by agent-shell.

When SCHEDULE is non-nil, mark the sidebar dirty after subscribing."
  (setq buffer (or buffer (current-buffer)))
  (when (and (buffer-live-p buffer)
             (with-current-buffer buffer
               (derived-mode-p 'agent-shell-mode))
             (fboundp 'agent-shell-subscribe-to)
             (not (gethash buffer agent-shell-vertico-sidebar--subscriptions)))
    (puthash buffer
             (agent-shell-subscribe-to
              :shell-buffer buffer
              :on-event (lambda (event)
                          (agent-shell-vertico-sidebar--handle-event
                           buffer event)))
             agent-shell-vertico-sidebar--subscriptions)
    (with-current-buffer buffer
      (add-hook 'kill-buffer-hook
                #'agent-shell-vertico-sidebar--unwatch-buffer nil t))
    (when schedule
      (agent-shell-vertico-sidebar--schedule-refresh))))

(defun agent-shell-vertico-sidebar--watch-buffer-on-mode-hook ()
  "Subscribe the current agent-shell buffer and mark the sidebar dirty."
  (agent-shell-vertico-sidebar--watch-buffer (current-buffer) t))

(defun agent-shell-vertico-sidebar--watch-existing
    (&optional buffers schedule buffers-supplied)
  "Subscribe to currently live agent-shell BUFFERS.

When BUFFERS-SUPPLIED is nil, BUFFERS is queried once.  When SCHEDULE is
non-nil, newly subscribed buffers mark the sidebar dirty."
  (let (dead)
    (maphash (lambda (buffer _subscription)
               (unless (buffer-live-p buffer)
                 (push buffer dead)))
             agent-shell-vertico-sidebar--subscriptions)
    (dolist (buffer dead)
      (remhash buffer agent-shell-vertico-sidebar--subscriptions)
      (remhash buffer agent-shell-vertico-sidebar--attention)
      (remhash buffer agent-shell-vertico-sidebar--busy-since-times)
      (remhash buffer agent-shell-vertico-sidebar--activity)))
  (dolist (buffer (if buffers-supplied buffers (agent-shell-buffers)))
    (agent-shell-vertico-sidebar--watch-buffer buffer schedule)))

(defun agent-shell-vertico-sidebar--mark-seen (buffer)
  "Mark completed output in BUFFER as seen."
  (when (eq (plist-get (gethash buffer agent-shell-vertico-sidebar--attention)
                       :kind)
            'done)
    (remhash buffer agent-shell-vertico-sidebar--attention)
    (agent-shell-vertico-sidebar--schedule-refresh)))

(defun agent-shell-vertico-sidebar--window-selection-change
    (&optional _frame window)
  "Mark an agent-shell buffer seen when its window is selected."
  (let ((buffer (if (window-live-p window)
                    (window-buffer window)
                  (current-buffer))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (derived-mode-p 'agent-shell-mode)
          (agent-shell-vertico-sidebar--mark-seen buffer))))))

(defun agent-shell-vertico-sidebar--session-at-point ()
  "Return the live session buffer at point, or signal a user error."
  (let ((buffer (agent-shell-vertico-sidebar--node-at-point)))
    (unless (and (eq (agent-shell-vertico-sidebar--node-kind-at-point) 'session)
                 (buffer-live-p buffer))
      (user-error "No live agent-shell session at point"))
    buffer))

(defun agent-shell-vertico-sidebar--project-at-point ()
  "Return the project root at point, or nil."
  (when (eq (agent-shell-vertico-sidebar--node-kind-at-point) 'project)
    (agent-shell-vertico-sidebar--node-at-point)))

(defun agent-shell-vertico-sidebar-toggle-project ()
  "Toggle the project fold at point."
  (interactive)
  (let ((root (agent-shell-vertico-sidebar--project-at-point)))
    (unless root
      (user-error "Point is not on a project header"))
    (puthash root
             (not (agent-shell-vertico-sidebar--project-expanded-p root))
             agent-shell-vertico-sidebar--expanded-projects)
    (agent-shell-vertico-sidebar--render)))

(defun agent-shell-vertico-sidebar-open ()
  "Open the session or toggle the project at point."
  (interactive)
  (if (agent-shell-vertico-sidebar--project-at-point)
      (agent-shell-vertico-sidebar-toggle-project)
    (let ((buffer (agent-shell-vertico-sidebar--session-at-point)))
      (agent-shell-vertico-sidebar--mark-seen buffer)
      (agent-shell-vertico--display-session (buffer-name buffer))
      (agent-shell-vertico-sidebar-refresh))))

(defun agent-shell-vertico-sidebar-open-other-window ()
  "Open the session at point in another window."
  (interactive)
  (let ((buffer (agent-shell-vertico-sidebar--session-at-point)))
    (agent-shell-vertico-sidebar--mark-seen buffer)
    (agent-shell-vertico--display-session-other-window (buffer-name buffer))
    (agent-shell-vertico-sidebar-refresh)))

(defun agent-shell-vertico-sidebar-open-project ()
  "Open the session project at point in another window."
  (interactive)
  (let* ((buffer (agent-shell-vertico-sidebar--session-at-point))
         (root (agent-shell-vertico-sidebar--project-root buffer)))
    (dired-other-window root)
    (agent-shell-vertico-sidebar-refresh)))

(defun agent-shell-vertico-sidebar--activate-at-point ()
  "Activate the row or metadata field at point."
  (pcase (agent-shell-vertico-sidebar--field-at-point)
    ('model (agent-shell-vertico-sidebar-set-model))
    ('mode (agent-shell-vertico-sidebar-set-mode))
    ('project (agent-shell-vertico-sidebar-open-project))
    (_ (agent-shell-vertico-sidebar-open))))

(defun agent-shell-vertico-sidebar-activate (&optional event)
  "Activate the row or metadata field at point.

With a mouse EVENT, move to the clicked position before dispatching."
  (interactive
   (list (and (mouse-event-p last-input-event) last-input-event)))
  (if event
      (let* ((position (event-end event))
             (window (posn-window position))
             (point (posn-point position)))
        (unless (and (window-live-p window)
                     (integer-or-marker-p point))
          (user-error "Cannot determine sidebar click position"))
        (select-window window)
        (with-current-buffer (window-buffer window)
          (goto-char point)
          (agent-shell-vertico-sidebar--activate-at-point)))
    (agent-shell-vertico-sidebar--activate-at-point)))

(defun agent-shell-vertico-sidebar--call-session-action (function)
  "Call session action FUNCTION for the session at point."
  (let ((buffer (agent-shell-vertico-sidebar--session-at-point)))
    (funcall function (buffer-name buffer))
    (agent-shell-vertico-sidebar-refresh)))

(defun agent-shell-vertico-sidebar-kill ()
  "Kill the session at point."
  (interactive)
  (agent-shell-vertico-sidebar--call-session-action
   #'agent-shell-vertico-kill-session))

(defun agent-shell-vertico-sidebar-restart ()
  "Restart the session at point."
  (interactive)
  (agent-shell-vertico-sidebar--call-session-action
   #'agent-shell-vertico-restart-session))

(defun agent-shell-vertico-sidebar-interrupt ()
  "Interrupt the session at point."
  (interactive)
  (agent-shell-vertico-sidebar--call-session-action
   #'agent-shell-vertico-interrupt-session))

(defun agent-shell-vertico-sidebar-set-mode ()
  "Set the session mode at point."
  (interactive)
  (agent-shell-vertico-sidebar--call-session-action
   #'agent-shell-vertico-set-session-mode))

(defun agent-shell-vertico-sidebar-set-model ()
  "Set the session model at point."
  (interactive)
  (agent-shell-vertico-sidebar--call-session-action
   #'agent-shell-vertico-set-session-model))

(defun agent-shell-vertico-sidebar-view-traffic ()
  "View traffic for the session at point."
  (interactive)
  (agent-shell-vertico-sidebar--call-session-action
   #'agent-shell-vertico-view-traffic))

(defun agent-shell-vertico-sidebar-open-transcript ()
  "Open the transcript for the session at point."
  (interactive)
  (agent-shell-vertico-sidebar--call-session-action
   #'agent-shell-vertico-open-transcript))

(defun agent-shell-vertico-sidebar-new ()
  "Create a new agent-shell session."
  (interactive)
  (agent-shell-vertico-new-shell)
  (agent-shell-vertico-sidebar-refresh))

(defun agent-shell-vertico-sidebar-set-sort ()
  "Choose the sidebar sorting criterion."
  (interactive)
  (let* ((choices '(("Priority" . priority)
                    ("Activity" . activity)
                    ("Recency" . recency)
                    ("Status" . status)
                    ("Name" . name)))
         (choice (completing-read "Sort sessions by: " choices nil t))
         (sort-by (cdr (assoc choice choices))))
    (setq agent-shell-vertico-sidebar-sort-by sort-by)
    (agent-shell-vertico-sidebar-refresh)))

(defun agent-shell-vertico-sidebar-toggle-grouping ()
  "Toggle between project-grouped and flat session views."
  (interactive)
  (setq agent-shell-vertico-sidebar-group-by
        (unless agent-shell-vertico-sidebar-group-by 'project))
  (agent-shell-vertico-sidebar-refresh))

(defun agent-shell-vertico-sidebar-toggle-details ()
  "Toggle the default metadata view for all session rows.

This resets any per-session `TAB' overrides so every row follows the new
default."
  (interactive)
  (setq agent-shell-vertico-sidebar-show-details
        (not agent-shell-vertico-sidebar-show-details))
  (when (hash-table-p agent-shell-vertico-sidebar--expanded-sessions)
    (clrhash agent-shell-vertico-sidebar--expanded-sessions))
  (agent-shell-vertico-sidebar-refresh))

(defun agent-shell-vertico-sidebar-toggle-session-details ()
  "Toggle metadata lines for the session at point."
  (interactive)
  (let ((buffer (agent-shell-vertico-sidebar--session-at-point)))
    (unless (hash-table-p agent-shell-vertico-sidebar--expanded-sessions)
      (setq agent-shell-vertico-sidebar--expanded-sessions
            (make-hash-table :test #'eq)))
    (puthash buffer
             (not (agent-shell-vertico-sidebar--session-details-expanded-p
                   buffer))
             agent-shell-vertico-sidebar--expanded-sessions)
    (agent-shell-vertico-sidebar--render)))

(defun agent-shell-vertico-sidebar-toggle-at-point ()
  "Toggle the project or session detail at point."
  (interactive)
  (pcase (agent-shell-vertico-sidebar--node-kind-at-point)
    ('project (agent-shell-vertico-sidebar-toggle-project))
    ('session (agent-shell-vertico-sidebar-toggle-session-details))
    (_ (user-error "Point is not on a project or session row"))))

(defun agent-shell-vertico-sidebar-refresh ()
  "Refresh the visible agent-shell sidebar."
  (interactive)
  (when-let ((buffer (get-buffer "*Agent Shell Sessions*")))
    (with-current-buffer buffer
      (agent-shell-vertico-sidebar--render))))

(defun agent-shell-vertico-sidebar--session-statistics ()
  "Return status counts for live agent-shell sessions.

The returned vector contains attention, working, ready, and starting counts
in that order."
  (let ((counts (make-vector 4 0)))
    (dolist (buffer (seq-filter #'buffer-live-p (agent-shell-buffers)))
      (cl-incf (aref counts
                     (agent-shell-vertico-sidebar--status-rank buffer))))
    counts))

(defun agent-shell-vertico-sidebar--header-stat (count icon label face)
  "Return compact COUNT status text using ICON, LABEL, and FACE."
  (when (> count 0)
    (propertize (format "%s%d" icon count)
                'face face
                'help-echo label)))

(defun agent-shell-vertico-sidebar--header-line-from-snapshots (snapshots)
  "Return a cached header string for SNAPSHOTS."
  (let ((counts (make-vector 4 0))
        (parts (list (format "%d session%s"
                            (length snapshots)
                            (if (= (length snapshots) 1) "" "s")))))
    (dolist (snapshot snapshots)
      (cl-incf (aref counts (plist-get snapshot :status-rank))))
    (dolist (stat `((0 "▲" "attention" agent-shell-vertico-sidebar-attention)
                    (1 "◆" "working" agent-shell-vertico-sidebar-working)
                    (2 "✓" "ready" agent-shell-vertico-sidebar-ready)
                    (3 "○" "starting" agent-shell-vertico-sidebar-detail)))
      (pcase-let ((`(,index ,icon ,label ,face) stat))
        (when-let ((text (agent-shell-vertico-sidebar--header-stat
                          (aref counts index) icon label face)))
          (setq parts (append parts (list text))))))
    (concat " " (string-join parts " · "))))

(defun agent-shell-vertico-sidebar--header-line ()
  "Return the sidebar header with live session statistics."
  (let* ((buffers (seq-filter #'buffer-live-p (agent-shell-buffers)))
         (counts (agent-shell-vertico-sidebar--session-statistics))
         (parts (list (format "%d session%s"
                              (length buffers)
                              (if (= (length buffers) 1) "" "s")))))
    (dolist (stat `((0 "▲" "attention" agent-shell-vertico-sidebar-attention)
                    (1 "◆" "working" agent-shell-vertico-sidebar-working)
                    (2 "✓" "ready" agent-shell-vertico-sidebar-ready)
                    (3 "○" "starting" agent-shell-vertico-sidebar-detail)))
      (pcase-let ((`(,index ,icon ,label ,face) stat))
        (when-let ((text (agent-shell-vertico-sidebar--header-stat
                          (aref counts index) icon label face)))
          (setq parts (append parts (list text))))))
    (concat " " (string-join parts " · "))))

(defconst agent-shell-vertico-sidebar--help-buffer
  "*Agent Shell Sidebar Help*"
  "Buffer used by `agent-shell-vertico-sidebar-help'.")

(defun agent-shell-vertico-sidebar--help-text ()
  "Return the key reference shown by `agent-shell-vertico-sidebar-help'."
  (concat
   "Agent Shell Sidebar\n"
   "===================\n\n"
   "Navigation\n"
   "  j / k       Move to the next or previous row\n"
   "  RET         Activate the row or metadata field\n"
   "  mouse-1     Activate at the clicked position\n"
   "  TAB         Toggle a project or current session details\n"
   "  S-TAB       Toggle the details default for all sessions\n\n"
   "Actions\n"
   "  o / O       Open here / open in another window\n"
   "  =           Toggle flat or project-grouped view\n"
   "  s           Choose the sort criterion\n"
   "  g (gr)      Refresh (regular / Evil state)\n"
   "  c           Create a new session\n"
   "  m / M       Set mode / model\n"
   "  t / T       Traffic / transcript (regular); reverse in Evil\n"
   "  k / r / i   Kill / restart / interrupt (regular state)\n"
   "  D / R / I   Kill / restart / interrupt (Evil state)\n"
   "  q           Close the sidebar\n\n"
   "Metadata values are individually clickable.  Project values open their\n"
   "working directory; model and mode values open their selectors.\n"
   "Press ? in the sidebar to show this help again.\n"))

(defun agent-shell-vertico-sidebar-help ()
  "Display the agent-shell sidebar key reference."
  (interactive)
  (require 'help-mode)
  (with-help-window (get-buffer-create
                     agent-shell-vertico-sidebar--help-buffer)
    (insert (agent-shell-vertico-sidebar--help-text))))

(defvar agent-shell-vertico-sidebar-action-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "o") #'agent-shell-vertico-sidebar-open)
    (define-key map (kbd "O") #'agent-shell-vertico-sidebar-open-other-window)
    (define-key map (kbd "=") #'agent-shell-vertico-sidebar-toggle-grouping)
    (define-key map (kbd "s") #'agent-shell-vertico-sidebar-set-sort)
    (define-key map (kbd "g") #'agent-shell-vertico-sidebar-refresh)
    (define-key map (kbd "c") #'agent-shell-vertico-sidebar-new)
    (define-key map (kbd "k") #'agent-shell-vertico-sidebar-kill)
    (define-key map (kbd "r") #'agent-shell-vertico-sidebar-restart)
    (define-key map (kbd "i") #'agent-shell-vertico-sidebar-interrupt)
    (define-key map (kbd "m") #'agent-shell-vertico-sidebar-set-mode)
    (define-key map (kbd "M") #'agent-shell-vertico-sidebar-set-model)
    (define-key map (kbd "t") #'agent-shell-vertico-sidebar-view-traffic)
    (define-key map (kbd "T") #'agent-shell-vertico-sidebar-open-transcript)
    (define-key map (kbd "?") #'agent-shell-vertico-sidebar-help)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Prefix map for sidebar actions that conflict with Evil keys.")

(defvar agent-shell-vertico-sidebar-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "RET") #'agent-shell-vertico-sidebar-activate)
    (define-key map (kbd "<return>") #'agent-shell-vertico-sidebar-activate)
    (define-key map (kbd "o") #'agent-shell-vertico-sidebar-open)
    (define-key map (kbd "O") #'agent-shell-vertico-sidebar-open-other-window)
    (define-key map (kbd "TAB") #'agent-shell-vertico-sidebar-toggle-at-point)
    (define-key map (kbd "<tab>") #'agent-shell-vertico-sidebar-toggle-at-point)
    (define-key map (kbd "S-TAB") #'agent-shell-vertico-sidebar-toggle-details)
    (define-key map (kbd "<backtab>")
                #'agent-shell-vertico-sidebar-toggle-details)
    (define-key map (kbd "=") #'agent-shell-vertico-sidebar-toggle-grouping)
    (define-key map (kbd "s") #'agent-shell-vertico-sidebar-set-sort)
    (define-key map (kbd "g") #'agent-shell-vertico-sidebar-refresh)
    (define-key map (kbd "c") #'agent-shell-vertico-sidebar-new)
    (define-key map (kbd "k") #'agent-shell-vertico-sidebar-kill)
    (define-key map (kbd "r") #'agent-shell-vertico-sidebar-restart)
    (define-key map (kbd "i") #'agent-shell-vertico-sidebar-interrupt)
    (define-key map (kbd "m") #'agent-shell-vertico-sidebar-set-mode)
    (define-key map (kbd "M") #'agent-shell-vertico-sidebar-set-model)
    (define-key map (kbd "t") #'agent-shell-vertico-sidebar-view-traffic)
    (define-key map (kbd "T") #'agent-shell-vertico-sidebar-open-transcript)
    (define-key map (kbd "?") #'agent-shell-vertico-sidebar-help)
    (define-key map [mouse-1] #'agent-shell-vertico-sidebar-activate)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "C-c") agent-shell-vertico-sidebar-action-map)
    map)
  "Keymap for `agent-shell-vertico-sidebar-mode'.")

(defconst agent-shell-vertico-sidebar--evil-g-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "r") #'agent-shell-vertico-sidebar-refresh)
    map)
  "Prefix map for the Evil `gr' refresh binding.")

(defconst agent-shell-vertico-sidebar--evil-bindings
  '(("j" . evil-next-line)
    ("k" . evil-previous-line)
    ("RET" . agent-shell-vertico-sidebar-activate)
    ("<return>" . agent-shell-vertico-sidebar-activate)
    ("TAB" . agent-shell-vertico-sidebar-toggle-at-point)
    ("<tab>" . agent-shell-vertico-sidebar-toggle-at-point)
    ("<mouse-1>" . agent-shell-vertico-sidebar-activate)
    ("o" . agent-shell-vertico-sidebar-open)
    ("O" . agent-shell-vertico-sidebar-open-other-window)
    ("S-TAB" . agent-shell-vertico-sidebar-toggle-details)
    ("<backtab>" . agent-shell-vertico-sidebar-toggle-details)
    ("=" . agent-shell-vertico-sidebar-toggle-grouping)
    ("s" . agent-shell-vertico-sidebar-set-sort)
    ("gr" . agent-shell-vertico-sidebar-refresh)
    ("c" . agent-shell-vertico-sidebar-new)
    ("D" . agent-shell-vertico-sidebar-kill)
    ("R" . agent-shell-vertico-sidebar-restart)
    ("I" . agent-shell-vertico-sidebar-interrupt)
    ("m" . agent-shell-vertico-sidebar-set-mode)
    ("M" . agent-shell-vertico-sidebar-set-model)
    ("t" . agent-shell-vertico-sidebar-open-transcript)
    ("T" . agent-shell-vertico-sidebar-view-traffic)
    ("?" . agent-shell-vertico-sidebar-help)
    ("q" . quit-window))
  "Dired-style direct bindings for Evil sidebar states.

The explicit `j'/`k' entries keep vertical navigation intact; `D'/`R'/`I'
are the destructive session actions so navigation and lowercase mnemonics
remain available.  Refresh is `gr', and the other mnemonic actions
intentionally take precedence over their generic Evil commands in this
read-only sidebar.")

(defun agent-shell-vertico-sidebar--bind-evil-keys ()
  "Install direct Dired-style bindings for Evil sidebar states.

The local `C-c' action prefix remains available as a discoverable fallback,
while normal and motion states get the same direct mnemonic commands."
  (when (fboundp #'evil-local-set-key)
    ;; Remove the old global-details binding when this file is reloaded into
    ;; an existing Emacs session.
    (define-key agent-shell-vertico-sidebar-mode-map (kbd "v") nil)
    (define-key agent-shell-vertico-sidebar-action-map (kbd "v") nil)
    (dolist (state '(normal motion))
      (when-let ((auxiliary (evil-get-auxiliary-keymap
                             (current-local-map) state)))
        (define-key auxiliary (kbd "v") nil)
        (define-key auxiliary (kbd "C-c v") nil))
      (evil-local-set-key state (kbd "v") nil)
      (evil-local-set-key state (kbd "C-c v") nil)
      (evil-local-set-key state (kbd "g")
                          agent-shell-vertico-sidebar--evil-g-map)
      (dolist (binding agent-shell-vertico-sidebar--evil-bindings)
        (unless (equal (car binding) "gr")
          (evil-local-set-key state (kbd (car binding)) (cdr binding))))
      (dolist (key '("o" "O" "=" "s" "g" "c" "k" "r"
                     "i" "m" "M" "t" "T" "?" "q"))
        (when-let ((command (lookup-key
                             agent-shell-vertico-sidebar-action-map
                             (kbd key))))
          (evil-local-set-key state (kbd (concat "C-c " key)) command))))))

(define-derived-mode agent-shell-vertico-sidebar-mode special-mode
  "Agent-Shell-Sidebar"
  "Major mode for the compact agent-shell session sidebar."
  (setq-local truncate-lines t
              buffer-read-only t
              cursor-type nil
              mode-line-format nil
              header-line-format nil
              agent-shell-vertico-sidebar--refresh-timer nil
              agent-shell-vertico-sidebar--age-refresh-timer nil
              agent-shell-vertico-sidebar--resize-timer nil
              agent-shell-vertico-sidebar--dirty nil
              agent-shell-vertico-sidebar--last-rendered-width nil)
  (setq-local agent-shell-vertico-sidebar--expanded-projects
              (make-hash-table :test #'equal))
  (setq-local agent-shell-vertico-sidebar--expanded-sessions
              (make-hash-table :test #'eq))
  (add-hook 'kill-buffer-hook
            #'agent-shell-vertico-sidebar--cancel-refresh nil t)
  (add-hook 'kill-buffer-hook
            #'agent-shell-vertico-sidebar--cancel-age-refresh nil t)
  (add-hook 'kill-buffer-hook
            #'agent-shell-vertico-sidebar--cancel-resize nil t)
  (local-set-key (kbd "TAB") #'agent-shell-vertico-sidebar-toggle-at-point)
  (local-set-key (kbd "<tab>") #'agent-shell-vertico-sidebar-toggle-at-point)
  (local-set-key (kbd "S-TAB") #'agent-shell-vertico-sidebar-toggle-details)
  (local-set-key (kbd "<backtab>") #'agent-shell-vertico-sidebar-toggle-details)
  (local-set-key (kbd "C-c") agent-shell-vertico-sidebar-action-map)
  (agent-shell-vertico-sidebar--bind-evil-keys)
  (agent-shell-vertico-sidebar--render))

(defun agent-shell-vertico-sidebar--display-buffer ()
  "Display and return the sidebar window."
  (let* ((buffer (agent-shell-vertico-sidebar--sidebar-buffer))
         (window (display-buffer-in-side-window
                  buffer
                  `((side . ,agent-shell-vertico-sidebar-side)
                    (slot . 0)
                    (window-width . ,agent-shell-vertico-sidebar-width)
                    (preserve-size . (t . nil))
                    (window-parameters
                     . ((no-delete-other-windows . t)
                        (no-other-window . nil)))))))
    (set-window-dedicated-p window t)
    (with-current-buffer buffer
      (if (derived-mode-p 'agent-shell-vertico-sidebar-mode)
          (agent-shell-vertico-sidebar--render)
        (agent-shell-vertico-sidebar-mode)))
    window))

;;;###autoload
(defun agent-shell-vertico-sidebar-toggle ()
  "Toggle the compact agent-shell session sidebar."
  (interactive)
  (let* ((buffer (get-buffer "*Agent Shell Sessions*"))
         (window (and buffer (get-buffer-window buffer))))
    (if (window-live-p window)
        (delete-window window)
      (select-window (agent-shell-vertico-sidebar--display-buffer)))))

;;;###autoload
(defun agent-shell-vertico-sidebar-focus ()
  "Focus the visible sidebar, opening it when necessary."
  (interactive)
  (let* ((buffer (get-buffer "*Agent Shell Sessions*"))
         (existing-window (and buffer (get-buffer-window buffer)))
         (window (or existing-window
                     (agent-shell-vertico-sidebar--display-buffer))))
    (when (and existing-window (window-live-p window))
      (with-current-buffer buffer
        (when (derived-mode-p 'agent-shell-vertico-sidebar-mode)
          (agent-shell-vertico-sidebar--render))))
    (select-window window)))

(defun agent-shell-vertico-sidebar--window-configuration-change
    (&optional _frame)
  "Cancel sidebar timers when its window is no longer visible."
  (when-let ((sidebar (get-buffer "*Agent Shell Sessions*")))
    (with-current-buffer sidebar
      (if (agent-shell-vertico-sidebar--sidebar-visible-p sidebar)
          (agent-shell-vertico-sidebar--ensure-age-refresh)
        (agent-shell-vertico-sidebar--cancel-refresh)
        (agent-shell-vertico-sidebar--cancel-resize)
        (agent-shell-vertico-sidebar--cancel-age-refresh)))))

(defvar agent-shell-vertico-sidebar--visible-before-workspace-switch nil
  "Whether the sidebar was visible in the workspace being left.")

(defun agent-shell-vertico-sidebar--selected-frame-window ()
  "Return the sidebar window on the selected frame, or nil."
  (when-let ((sidebar (get-buffer "*Agent Shell Sessions*")))
    (get-buffer-window sidebar)))

(defun agent-shell-vertico-sidebar--save-workspace-visibility
    (&optional scope)
  "Record whether the sidebar is visible in the workspace being left.

SCOPE is persp-mode's activation scope.  Only `frame' saves and restores a
window layout, so only `frame' can lose the sidebar's side window."
  (when (eq scope 'frame)
    (setq agent-shell-vertico-sidebar--visible-before-workspace-switch
          (and (agent-shell-vertico-sidebar--selected-frame-window) t))))

(defun agent-shell-vertico-sidebar--restore-workspace-visibility
    (&optional scope)
  "Give the new workspace the sidebar visibility of the one being left.

The restored layout of a workspace last left with the sidebar open brings
that window back, so a sidebar hidden before the switch is closed again,
just as a visible one is reopened.

SCOPE is persp-mode's activation scope, as for
`agent-shell-vertico-sidebar--save-workspace-visibility'."
  (when (and (eq scope 'frame)
             agent-shell-vertico-sidebar-follow-workspaces)
    (let ((window (agent-shell-vertico-sidebar--selected-frame-window))
          (visible
           agent-shell-vertico-sidebar--visible-before-workspace-switch))
      (cond ((and visible (not window))
             (save-selected-window
               (agent-shell-vertico-sidebar--display-buffer)))
            ((and (not visible) (window-live-p window))
             (delete-window window))))))

(defun agent-shell-vertico-sidebar--install-workspace-hooks ()
  "Make the sidebar survive persp-mode workspace switches."
  (add-hook 'persp-before-deactivate-functions
            #'agent-shell-vertico-sidebar--save-workspace-visibility)
  (add-hook 'persp-activated-functions
            #'agent-shell-vertico-sidebar--restore-workspace-visibility))

;; `window-state-get' and `window-state-put', which persp-mode uses to save
;; and restore each workspace layout, only carry window parameters marked
;; writable.  Without this, a restored sidebar window loses its no-delete
;; parameter and `delete-other-windows' removes it.  `window-side' and
;; `window-slot' are registered the same way by `display-buffer-in-side-window'.
(add-to-list 'window-persistent-parameters
             '(no-delete-other-windows . writable))

(with-eval-after-load 'persp-mode
  (agent-shell-vertico-sidebar--install-workspace-hooks))

(add-hook 'agent-shell-mode-hook
          #'agent-shell-vertico-sidebar--watch-buffer-on-mode-hook)
(add-hook 'window-selection-change-functions
          #'agent-shell-vertico-sidebar--window-selection-change)
(add-hook 'window-size-change-functions
          #'agent-shell-vertico-sidebar--window-size-change)
(add-hook 'window-configuration-change-functions
          #'agent-shell-vertico-sidebar--window-configuration-change)

(provide 'agent-shell-vertico-sidebar)

;;; agent-shell-vertico-sidebar.el ends here
