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
(declare-function agent-shell-subscribe-to "agent-shell"
                  (&key shell-buffer event on-event))
(declare-function agent-shell-unsubscribe "agent-shell" (&key subscription))
(declare-function evil-local-set-key "evil" (state key def))
(declare-function evil-get-auxiliary-keymap "evil"
                  (map state &optional create ignore-parent))
(declare-function evil-next-line "evil" ())
(declare-function evil-previous-line "evil" ())

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
ready, and starting sessions.  `activity' uses the latest agent event,
`recency' uses the last display time, `status' uses only status, and `name'
sorts by session title."
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
compact row.  Available symbols are `status', `activity', `project',
`model', `mode', and `last-user-message'.  The latter shows the latest
submitted prompt and is omitted by default."
  :type '(repeat (choice (const :tag "Status" status)
                         (const :tag "Activity age" activity)
                         (const :tag "Project" project)
                         (const :tag "Model" model)
                         (const :tag "Mode" mode)
                         (const :tag "Last user message" last-user-message)))
  :group 'agent-shell-vertico-sidebar)

(defvar agent-shell-vertico-sidebar--attention (make-hash-table :test #'eq)
  "Buffer to attention metadata.

Values are plists with `:kind' (`blocked', `done', or `error') and
`:time'.")

(defvar agent-shell-vertico-sidebar--activity (make-hash-table :test #'eq)
  "Buffer to the latest observed agent activity timestamp.")

(defvar agent-shell-vertico-sidebar--subscriptions (make-hash-table :test #'eq)
  "Buffer to its agent-shell event subscription token.")

(defvar agent-shell-vertico-sidebar--refresh-timer nil
  "Pending debounced sidebar refresh timer.")

(defvar agent-shell-vertico-sidebar--age-refresh-timer nil
  "Timer that keeps visible activity ages current.")

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
  (with-current-buffer buffer
    (file-name-as-directory
     (expand-file-name
      (condition-case nil
          (agent-shell-cwd)
        (error default-directory))))))

(defun agent-shell-vertico-sidebar--project-name (root)
  "Return a compact display name for project ROOT."
  (let ((name (file-name-nondirectory (directory-file-name root))))
    (if (string-empty-p name) root name)))

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
  (or (when (fboundp 'agent-shell-status)
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
  (or (gethash buffer agent-shell-vertico-sidebar--attention)
      (when (eq (agent-shell-vertico-sidebar--raw-status buffer) 'blocked)
        (list :kind 'blocked
              :time (or (gethash buffer agent-shell-vertico-sidebar--activity)
                        (when-let ((time (buffer-local-value
                                          'buffer-display-time buffer)))
                          (float-time time))
                        0.0)))))

(defun agent-shell-vertico-sidebar--status-name (buffer)
  "Return a display status name for BUFFER."
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
       (_ "Unknown")))))

(defun agent-shell-vertico-sidebar--status-rank (buffer)
  "Return a status rank for BUFFER.  Lower ranks sort first."
  (cond
   ((agent-shell-vertico-sidebar--attention buffer) 0)
   ((eq (agent-shell-vertico-sidebar--raw-status buffer) 'busy) 1)
   ((eq (agent-shell-vertico-sidebar--raw-status buffer) 'ready) 2)
   (t 3)))

(defun agent-shell-vertico-sidebar--status-sort-rank (buffer)
  "Return the raw status rank for BUFFER.  Lower ranks sort first.

Unlike `agent-shell-vertico-sidebar--status-rank', this deliberately
ignores attention metadata; attention is the concern of `priority'."
  (pcase (agent-shell-vertico-sidebar--raw-status buffer)
    ('blocked 0)
    ('busy 1)
    ('ready 2)
    ('starting 3)
    (_ 4)))

(defun agent-shell-vertico-sidebar--activity-time (buffer)
  "Return latest observed activity time for BUFFER."
  (or (gethash buffer agent-shell-vertico-sidebar--activity)
      (when-let ((time (buffer-local-value 'buffer-display-time buffer)))
        (float-time time))
      0.0))

(defun agent-shell-vertico-sidebar--attention-time (buffer)
  "Return the timestamp relevant to attention sorting for BUFFER."
  (or (plist-get (agent-shell-vertico-sidebar--attention buffer) :time)
      (agent-shell-vertico-sidebar--activity-time buffer)))

(defun agent-shell-vertico-sidebar--title (buffer)
  "Return a compact title for BUFFER."
  (let ((title (agent-shell-vertico--title buffer)))
    (if (or (null title) (string= title "-"))
        (let ((name (buffer-name buffer)))
          (if (string-match " Agent @ \\(.*\\)\\'" name)
              (match-string 1 name)
            name))
      title)))

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
       ((< seconds 1) "now")
       ((< seconds 60) (format "%ds" (floor seconds)))
       ((< seconds 3600) (format "%dm" (floor (/ seconds 60))))
       ((< seconds 86400) (format "%dh" (floor (/ seconds 3600))))
       (t (format "%dd" (floor (/ seconds 86400))))))))

(defun agent-shell-vertico-sidebar--extra-info-lines (buffer root width)
  "Return selected metadata lines for BUFFER at WIDTH under ROOT.

  Values follow `agent-shell-vertico-sidebar-extra-info' and are packed two
  per row to keep the sidebar compact."
  (let* ((last-message
          (when (memq 'last-user-message
                      agent-shell-vertico-sidebar-extra-info)
            (agent-shell-vertico-sidebar--last-user-message buffer)))
         (values `((status . ,(agent-shell-vertico-sidebar--status-name buffer))
                   (activity . ,(agent-shell-vertico-sidebar--relative-time
                                 (agent-shell-vertico-sidebar--activity-time
                                  buffer)))
                   (project . ,(agent-shell-vertico-sidebar--project-name root))
                   (model . ,(agent-shell-vertico--model-name buffer))
                   (mode . ,(agent-shell-vertico--mode-name buffer))
                   (last-user-message
                    . ,(when last-message
                         (concat "↳ " last-message)))))
         fields)
    (dolist (field agent-shell-vertico-sidebar-extra-info)
      (when-let ((value (alist-get field values)))
        (push value fields)))
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

(defun agent-shell-vertico-sidebar--any-session-details-visible-p ()
  "Return non-nil when any live session has visible detail lines."
  (seq-some #'agent-shell-vertico-sidebar--session-details-expanded-p
            (seq-filter #'buffer-live-p (agent-shell-buffers))))

(defun agent-shell-vertico-sidebar--join (fields)
  "Join non-empty strings in FIELDS with a middle dot."
  (string-join (seq-filter (lambda (field)
                             (and field (not (string-empty-p field))))
                           fields)
               " · "))

(defun agent-shell-vertico-sidebar--title-display-text (title)
  "Truncate TITLE to the configured display character limit."
  (let* ((limit (max 1 agent-shell-vertico-sidebar-title-max-length))
         (title (or title "")))
    (if (> (length title) limit)
        (concat (substring title 0 (max 0 (1- limit))) "…")
      title)))

(defun agent-shell-vertico-sidebar--wrap-text (text width)
  "Wrap TEXT to WIDTH columns, preserving words where possible.

Right-align a terminal ellipsis on the final line when present."
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
    (let ((result (nreverse (cons remaining lines))))
      (when-let ((tail (and (string-suffix-p "…" (car (last result)))
                            (last result))))
        (let* ((line (car tail))
               (prefix (substring line 0 -1))
               (prefix-width (max 0 (1- width)))
               (prefix (truncate-string-to-width
                        prefix prefix-width 0 nil nil))
               (padding (make-string
                         (max 0 (- prefix-width (string-width prefix)))
                         ?\s)))
          (setcar tail (concat prefix padding "…"))))
      result)))

(defun agent-shell-vertico-sidebar--fit (string width)
  "Fit STRING to WIDTH columns, adding an ellipsis when needed."
  (truncate-string-to-width (or string "") (max 1 width) 0 nil "…"))

(defun agent-shell-vertico-sidebar--icon (buffer)
  "Return the status icon for BUFFER."
  (pcase (agent-shell-vertico-sidebar--status-rank buffer)
    (0 "▲")
    (1 "◆")
    (2 "✓")
    (_ "○")))

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
                       (agent-shell-vertico-sidebar--attention-time left))
                      ('activity
                       (agent-shell-vertico-sidebar--activity-time left))
                      ('recency (or (when-let ((time (buffer-local-value
                                                       'buffer-display-time
                                                       left)))
                                      (float-time time))
                                    0.0))
                      (_ 0.0)))
         (right-time (pcase sort-by
                       ('priority
                        (agent-shell-vertico-sidebar--attention-time right))
                       ('activity
                        (agent-shell-vertico-sidebar--activity-time right))
                       ('recency (or (when-let ((time (buffer-local-value
                                                        'buffer-display-time
                                                        right)))
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
                          (string-lessp (car left) (car right))
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
  (let* ((content-width (- width (if nested 4 2)))
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
         (detail-lines
          (when details-visible
            (agent-shell-vertico-sidebar--extra-info-lines
             buffer root content-width))))
    (setq title-lines
          (cons (concat icon " " (car title-lines))
                (cdr title-lines)))
    (append (mapcar (lambda (line) (cons line nil)) title-lines)
            detail-lines)))

(defun agent-shell-vertico-sidebar--insert-row (lines kind node &optional nested)
  "Insert session LINES with KIND and NODE text properties.

NESTED adds the visual indentation used for sessions below a project
header; flat rows keep their status icon at column zero."
  (let ((start (point))
        (first-prefix (if nested "  " ""))
        (continuation-prefix (if nested "    " "  "))
        (first t))
    (dolist (line lines)
      (insert (if first first-prefix continuation-prefix))
      (let ((line-start (line-beginning-position)))
        (insert (car line))
        (when (cdr line)
          (add-text-properties
           line-start (point)
           (list 'face (cdr line)))))
      (insert "\n")
      (setq first nil))
    (add-text-properties
     start (1- (point))
     (list 'agent-shell-vertico-sidebar-node node
           'agent-shell-vertico-sidebar-node-kind kind
           'mouse-face 'highlight
           'help-echo (buffer-name node)))))

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
                       (agent-shell-vertico-sidebar--project-name root)
                       summary))
         (start (point)))
    (insert (agent-shell-vertico-sidebar--fit line width) "\n")
    (add-text-properties
     start (1- (point))
     (list 'face 'agent-shell-vertico-sidebar-project
           'agent-shell-vertico-sidebar-node root
           'agent-shell-vertico-sidebar-node-kind 'project
           'mouse-face 'highlight
           'help-echo "TAB/RET/mouse-1: toggle project"))
    (when expanded
      (dolist (buffer buffers)
        (agent-shell-vertico-sidebar--insert-row
         (agent-shell-vertico-sidebar--session-lines buffer root width t)
         'session buffer t)))))

(defun agent-shell-vertico-sidebar--render ()
  "Render the current sidebar buffer."
  (let* ((buffers (seq-filter #'buffer-live-p (agent-shell-buffers)))
         (width (or (when-let ((window (get-buffer-window (current-buffer))))
                      (window-width window))
                    agent-shell-vertico-sidebar-width))
         (point-node (agent-shell-vertico-sidebar--point-node))
         (inhibit-read-only t))
    (agent-shell-vertico-sidebar--watch-existing)
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
            buffer (agent-shell-vertico-sidebar--project-root buffer) width)
           'session buffer))))
    (goto-char (point-min))
    (when (and point-node (agent-shell-vertico-sidebar--goto-node point-node))
      (beginning-of-line))
    (agent-shell-vertico-sidebar--ensure-age-refresh)))

(defun agent-shell-vertico-sidebar--sidebar-buffer ()
  "Return the sidebar buffer, creating it when necessary."
  (get-buffer-create "*Agent Shell Sessions*"))

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

(defun agent-shell-vertico-sidebar--ensure-age-refresh ()
  "Keep activity ages current while the sidebar is visible."
  (when-let ((buffer (get-buffer "*Agent Shell Sessions*")))
    (cond
     ((and (agent-shell-vertico-sidebar--any-session-details-visible-p)
           (get-buffer-window buffer 'visible)
           (not (timerp agent-shell-vertico-sidebar--age-refresh-timer)))
      (setq agent-shell-vertico-sidebar--age-refresh-timer
            (run-with-timer
             1 1
             (lambda ()
               (if-let ((sidebar (get-buffer "*Agent Shell Sessions*")))
                   (if (get-buffer-window sidebar 'visible)
                       (agent-shell-vertico-sidebar-refresh)
                     (agent-shell-vertico-sidebar--cancel-age-refresh))
                 (agent-shell-vertico-sidebar--cancel-age-refresh))))))
     ((or (not (agent-shell-vertico-sidebar--any-session-details-visible-p))
          (not (get-buffer-window buffer 'visible)))
      (agent-shell-vertico-sidebar--cancel-age-refresh)))))

(defun agent-shell-vertico-sidebar--schedule-refresh (&rest _args)
  "Schedule a debounced refresh when the sidebar exists."
  (when-let ((buffer (get-buffer "*Agent Shell Sessions*")))
    (agent-shell-vertico-sidebar--cancel-refresh)
    (setq agent-shell-vertico-sidebar--refresh-timer
          (run-with-idle-timer
           0.2 nil
           (lambda ()
             (setq agent-shell-vertico-sidebar--refresh-timer nil)
             (agent-shell-vertico-sidebar-refresh))))))

(defun agent-shell-vertico-sidebar--handle-event (buffer event)
  "Update sidebar metadata for BUFFER after agent EVENT."
  (let ((kind (map-elt event :event))
        (now (float-time)))
    (puthash buffer now agent-shell-vertico-sidebar--activity)
    (pcase kind
      ('permission-request
       (puthash buffer (list :kind 'blocked :time now)
                agent-shell-vertico-sidebar--attention))
      ('error
       (puthash buffer (list :kind 'error :time now)
                agent-shell-vertico-sidebar--attention))
      ('turn-complete
       (if (get-buffer-window buffer 'visible)
           (remhash buffer agent-shell-vertico-sidebar--attention)
         (puthash buffer (list :kind 'done :time now)
                  agent-shell-vertico-sidebar--attention)))
      ('input-submitted
       (when (eq (plist-get (gethash buffer
                                    agent-shell-vertico-sidebar--attention)
                            :kind)
                 'done)
         (remhash buffer agent-shell-vertico-sidebar--attention)))
      ('permission-response
       (unless (eq (agent-shell-vertico-sidebar--raw-status buffer) 'blocked)
         (remhash buffer agent-shell-vertico-sidebar--attention)))
      ('clean-up
       (remhash buffer agent-shell-vertico-sidebar--attention)
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
    (remhash (current-buffer) agent-shell-vertico-sidebar--activity)
    (agent-shell-vertico-sidebar--schedule-refresh)))

(defun agent-shell-vertico-sidebar--watch-buffer (&optional buffer)
  "Subscribe to events from BUFFER when supported by agent-shell."
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
    (agent-shell-vertico-sidebar--schedule-refresh)))

(defun agent-shell-vertico-sidebar--watch-existing ()
  "Subscribe to all currently live agent-shell buffers."
  (let (dead)
    (maphash (lambda (buffer _subscription)
               (unless (buffer-live-p buffer)
                 (push buffer dead)))
             agent-shell-vertico-sidebar--subscriptions)
    (dolist (buffer dead)
      (remhash buffer agent-shell-vertico-sidebar--subscriptions)
      (remhash buffer agent-shell-vertico-sidebar--attention)
      (remhash buffer agent-shell-vertico-sidebar--activity)))
  (dolist (buffer (agent-shell-buffers))
    (agent-shell-vertico-sidebar--watch-buffer buffer)))

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

(defvar agent-shell-vertico-sidebar-action-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "o") #'agent-shell-vertico-sidebar-open)
    (define-key map (kbd "O") #'agent-shell-vertico-sidebar-open-other-window)
    (define-key map (kbd "G") #'agent-shell-vertico-sidebar-toggle-grouping)
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
    (define-key map (kbd "q") #'quit-window)
    map)
  "Prefix map for sidebar actions that conflict with Evil keys.")

(defvar agent-shell-vertico-sidebar-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "RET") #'agent-shell-vertico-sidebar-open)
    (define-key map (kbd "<return>") #'agent-shell-vertico-sidebar-open)
    (define-key map (kbd "o") #'agent-shell-vertico-sidebar-open)
    (define-key map (kbd "O") #'agent-shell-vertico-sidebar-open-other-window)
    (define-key map (kbd "TAB") #'agent-shell-vertico-sidebar-toggle-at-point)
    (define-key map (kbd "<tab>") #'agent-shell-vertico-sidebar-toggle-at-point)
    (define-key map (kbd "S-TAB") #'agent-shell-vertico-sidebar-toggle-details)
    (define-key map (kbd "<backtab>")
                #'agent-shell-vertico-sidebar-toggle-details)
    (define-key map (kbd "G") #'agent-shell-vertico-sidebar-toggle-grouping)
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
    (define-key map [mouse-1] #'agent-shell-vertico-sidebar-open)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "C-c") agent-shell-vertico-sidebar-action-map)
    map)
  "Keymap for `agent-shell-vertico-sidebar-mode'.")

(defconst agent-shell-vertico-sidebar--evil-bindings
  '(("j" . evil-next-line)
    ("k" . evil-previous-line)
    ("RET" . agent-shell-vertico-sidebar-open)
    ("<return>" . agent-shell-vertico-sidebar-open)
    ("TAB" . agent-shell-vertico-sidebar-toggle-at-point)
    ("<tab>" . agent-shell-vertico-sidebar-toggle-at-point)
    ("<mouse-1>" . agent-shell-vertico-sidebar-open)
    ("o" . agent-shell-vertico-sidebar-open)
    ("O" . agent-shell-vertico-sidebar-open-other-window)
    ("S-TAB" . agent-shell-vertico-sidebar-toggle-details)
    ("<backtab>" . agent-shell-vertico-sidebar-toggle-details)
    ("G" . agent-shell-vertico-sidebar-toggle-grouping)
    ("s" . agent-shell-vertico-sidebar-set-sort)
    ("g" . agent-shell-vertico-sidebar-refresh)
    ("c" . agent-shell-vertico-sidebar-new)
    ("D" . agent-shell-vertico-sidebar-kill)
    ("r" . agent-shell-vertico-sidebar-restart)
    ("i" . agent-shell-vertico-sidebar-interrupt)
    ("m" . agent-shell-vertico-sidebar-set-mode)
    ("M" . agent-shell-vertico-sidebar-set-model)
    ("t" . agent-shell-vertico-sidebar-view-traffic)
    ("T" . agent-shell-vertico-sidebar-open-transcript)
    ("q" . quit-window))
  "Dired-style direct bindings for Evil sidebar states.

The explicit `j'/`k' entries keep vertical navigation intact; `D' is the
destructive session action so `k' never kills a session.  Other mnemonic
actions intentionally take precedence over their generic Evil commands in
this read-only sidebar.")

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
      (dolist (binding agent-shell-vertico-sidebar--evil-bindings)
        (evil-local-set-key state (kbd (car binding)) (cdr binding)))
      (dolist (key '("o" "O" "G" "s" "g" "c" "k" "r"
                     "i" "m" "M" "t" "T" "q"))
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
              header-line-format
              '((:eval (agent-shell-vertico-sidebar--header-line))))
  (setq-local agent-shell-vertico-sidebar--expanded-projects
              (make-hash-table :test #'equal))
  (setq-local agent-shell-vertico-sidebar--expanded-sessions
              (make-hash-table :test #'eq))
  (add-hook 'kill-buffer-hook
            #'agent-shell-vertico-sidebar--cancel-refresh nil t)
  (add-hook 'kill-buffer-hook
            #'agent-shell-vertico-sidebar--cancel-age-refresh nil t)
  (local-set-key (kbd "TAB") #'agent-shell-vertico-sidebar-toggle-at-point)
  (local-set-key (kbd "<tab>") #'agent-shell-vertico-sidebar-toggle-at-point)
  (local-set-key (kbd "S-TAB") #'agent-shell-vertico-sidebar-toggle-details)
  (local-set-key (kbd "<backtab>") #'agent-shell-vertico-sidebar-toggle-details)
  (local-set-key (kbd "C-c") agent-shell-vertico-sidebar-action-map)
  (agent-shell-vertico-sidebar--bind-evil-keys)
  (agent-shell-vertico-sidebar--watch-existing)
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
      (unless (derived-mode-p 'agent-shell-vertico-sidebar-mode)
        (agent-shell-vertico-sidebar-mode))
      (agent-shell-vertico-sidebar--render))
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
  (select-window (or (get-buffer-window "*Agent Shell Sessions*")
                     (agent-shell-vertico-sidebar--display-buffer))))

(add-hook 'agent-shell-mode-hook
          #'agent-shell-vertico-sidebar--watch-buffer)
(add-hook 'window-selection-change-functions
          #'agent-shell-vertico-sidebar--window-selection-change)

(provide 'agent-shell-vertico-sidebar)

;;; agent-shell-vertico-sidebar.el ends here
