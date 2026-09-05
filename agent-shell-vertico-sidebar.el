;;; agent-shell-vertico-sidebar.el --- Compact agent-shell sidebar -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Bill and contributors

;; Author: Bill
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (agent-shell "0.60.2"))
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
(declare-function agent-shell--new-shell "agent-shell"
                  (&key location config no-display))
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
  "Maximum initial width of the agent-shell sidebar in columns."
  :type 'integer
  :group 'agent-shell-vertico-sidebar)

(defcustom agent-shell-vertico-sidebar-max-width-fraction 0.3
  "Largest share of the frame's columns the sidebar may take.

`agent-shell-vertico-sidebar-width' is what the sidebar asks for; on a
frame too narrow for that many columns, this fraction caps it, down to a
floor of 16 columns.  Nil disables the cap, leaving the configured width
as the target.

The resulting width is what an open sidebar is held at: a resize timer
puts a side window that has drifted from it back, in either direction.
This means a sidebar resized by hand does not keep that width."
  :type '(choice (const :tag "No cap" nil)
                 (float :tag "Fraction of the frame width"))
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
ready, and starting sessions.  Attention and working sessions order
oldest first, so the top of the list is the session that has waited
longest and the one `agent-shell-vertico-sidebar-jump' visits.  Ready
and starting sessions order by their latest activity, newest first, so
a session
read or finished recently stays above stale idle ones.  `activity' uses
the latest agent event, `recency' uses the last display time, `status'
uses only status, and `name' sorts by session title."
  :type '(choice (const priority) (const activity) (const recency)
                 (const status) (const name))
  :group 'agent-shell-vertico-sidebar)

(defcustom agent-shell-vertico-sidebar-show-details nil
  "Default visibility for session metadata lines.

The fields themselves are selected with
`agent-shell-vertico-sidebar-extra-info'.  `TAB' overrides this default for
the session at point; `S-TAB' cycles every row through the sidebar's fold
levels and sets this default to the level it reaches."
  :type 'boolean
  :group 'agent-shell-vertico-sidebar)

(defcustom agent-shell-vertico-sidebar-extra-info
    '(agent project model mode activity)
  "Ordered extra information shown for expanded sessions.

Each selected symbol contributes one value, and values are packed two per
compact row.  In flat mode, `project' is also shown as the session's compact
working-directory context line.  Available symbols are `agent', `status',
`activity', `project', `model', `mode', and `last-user-message'.

The agent value names the configuration the session runs; activating it
starts a new session with that agent in this session's project.  `status'
and `last-user-message' are left out of the default: the row's icon already
carries the status, and a prompt is usually visible in the session itself."
  :type '(repeat (choice (const :tag "Agent" agent)
                         (const :tag "Status" status)
                         (const :tag "Activity age" activity)
                         (const :tag "Project" project)
                         (const :tag "Model" model)
                         (const :tag "Mode" mode)
                         (const :tag "Last user message" last-user-message)))
  :group 'agent-shell-vertico-sidebar)

(defcustom agent-shell-vertico-sidebar-use-nerd-icons 'auto
  "Whether the sidebar draws its status marks with nerd-icons.

`auto' uses icons when the `nerd-icons' package can be loaded and the
plain characters otherwise.  `t' always asks nerd-icons to draw them, and
nil always uses the characters.  Project folds keep their characters
either way."
  :type '(choice (const :tag "When nerd-icons is available" auto)
                 (const :tag "Always" t)
                 (const :tag "Never" nil))
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

(defcustom agent-shell-vertico-sidebar-notify-function nil
  "Function called when a session starts needing attention.

It is called with the keyword arguments `:buffer', the session buffer;
`:agent', the agent's display name; `:status', the wording the sidebar
shows for the session, one of \"Waiting\", \"Failed\", \"Working\",
\"Ready\" or \"Starting\"; `:unread', non-nil when the session holds
output nobody has read; and `:last-message', the agent's newest message
as it arrived, or nil.

Status and unread are separate because they answer different questions:
a finished turn leaves an ordinary `Ready' session holding unread
output, and a failed one leaves a `Failed' session that stays failed
after it is read.

Nothing is reported for a session the reader is already looking at, and
the message text is passed unshortened, since how to fit it belongs to
whichever channel shows it."
  :type '(choice (const :tag "Do not notify" nil) function)
  :group 'agent-shell-vertico-sidebar)

(defvar agent-shell-vertico-sidebar--unread (make-hash-table :test #'eq)
  "Buffer to the time its unread output arrived.

Presence is the whole record: a session either holds output nobody has
read or it does not.  The time orders the attention tier oldest first,
so the session that has waited longest is the one
`agent-shell-vertico-sidebar-jump' visits.")

(defvar agent-shell-vertico-sidebar--failed (make-hash-table :test #'eq)
  "Buffers whose last turn ended in an error.

agent-shell reports what a session is doing, not how its last turn
ended, so a failed session answers `ready' like any other idle one.  The
sidebar remembers the failure until a new turn starts, which is what
makes `failed' a status the reader can see rather than a notification
they had to catch.")

(defvar agent-shell-vertico-sidebar--activity (make-hash-table :test #'eq)
  "Buffer to the latest observed agent activity timestamp.")

(defvar agent-shell-vertico-sidebar--busy-since-times
  (make-hash-table :test #'eq)
  "Buffer to the timestamp when its current busy turn started.")

(defvar agent-shell-vertico-sidebar--subscriptions (make-hash-table :test #'eq)
  "Buffer to its agent-shell event subscription token.")

(defvar agent-shell-vertico-sidebar--out-of-turn (make-hash-table :test #'eq)
  "Buffer to the out-of-turn burst streaming into it.

An agent can stream output with no turn in flight: background tasks such
as subagents continue after the turn ended, and a prompt steered in too late
makes the agent start a turn of its own.  Neither is reported busy and
neither ends with `turn-complete', so the burst is tracked here instead.

Values are plists with `:timer', the timer that ends the burst after a
quiet period, and `:time', when the burst's latest update arrived.")

(defvar agent-shell-vertico-sidebar--messages (make-hash-table :test #'eq)
  "Buffer to the newest agent message streamed into it.

Values are plists with `:chunks', the message text in reverse arrival
order, and `:open', whether the next chunk continues that message or
starts a new one.")

(defvar agent-shell-vertico-sidebar--current-session nil
  "Live session buffer the reader is currently in, or nil.

Tracks the session, or its viewport, most recently shown in a selected
and focused window, so the sidebar can still mark that one row once the
reader has moved on to the sidebar itself or to an unrelated buffer.")

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
  "Face for a session holding output nobody has read."
  :group 'agent-shell-vertico-sidebar)

(defface agent-shell-vertico-sidebar-unresolved
  '((t :inherit warning))
  "Face for a session the reader has seen and not finished with.

A permission request still waiting for its answer, or a failed turn
nobody has started again."
  :group 'agent-shell-vertico-sidebar)

(defface agent-shell-vertico-sidebar-working
  '((t :inherit font-lock-function-name-face :weight bold))
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

(defface agent-shell-vertico-sidebar-current-session
  '((t :inherit outline-1 :height reset))
  "Face for the fringe marker on the session the reader is currently in."
  :group 'agent-shell-vertico-sidebar)

;; A short bar, `gptel-highlight-fringe' style: `center' positions it on
;; the row without needing the row's exact pixel height, so one definition
;; works across fonts and text scales.
(define-fringe-bitmap 'agent-shell-vertico-sidebar-current-session-fringe
  (make-vector 28 #b01100000)
  nil nil 'center)

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
  "Return non-nil when project ROOT should show its sessions.

The override table is buffer-local to the sidebar, so outside it there
are no overrides and the customizable default decides."
  (let ((unset (make-symbol "unset")))
    (if (hash-table-p agent-shell-vertico-sidebar--expanded-projects)
        (let ((value (gethash root
                              agent-shell-vertico-sidebar--expanded-projects
                              unset)))
          (if (eq value unset)
              agent-shell-vertico-sidebar-expand-by-default
            value))
      agent-shell-vertico-sidebar-expand-by-default)))

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

(defun agent-shell-vertico-sidebar--live-status (buffer)
  "Return the status agent-shell itself reports for BUFFER.

This answers `ready' during an out-of-turn burst, because agent-shell
reports whether a turn is in flight and a burst has none.  Use it to ask
what the session is doing apart from any burst; use
`agent-shell-vertico-sidebar--raw-status' to describe it to the reader."
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

(defun agent-shell-vertico-sidebar--raw-status (buffer)
  "Return the status symbol the sidebar shows for BUFFER.

Two things agent-shell does not report are added to what it does.  The
agent is working during an out-of-turn burst whether or not a turn asked
for the work, so say so; and a session whose last turn failed is failed
until a new turn starts, though agent-shell calls it idle.  Both only
apply to an otherwise idle session: a live `busy' or `blocked' means a
real turn owns the session and wins."
  (or (agent-shell-vertico-sidebar--snapshot-field buffer :status)
      (let ((status (agent-shell-vertico-sidebar--live-status buffer)))
        (cond
         ((not (eq status 'ready)) status)
         ((gethash buffer agent-shell-vertico-sidebar--out-of-turn) 'busy)
         ((gethash buffer agent-shell-vertico-sidebar--failed) 'failed)
         (t status)))))

(defun agent-shell-vertico-sidebar--unread-time (buffer)
  "Return when BUFFER's unread output arrived, or nil when it has none."
  (or (agent-shell-vertico-sidebar--snapshot-field buffer :unread)
      (gethash buffer agent-shell-vertico-sidebar--unread)))

(defun agent-shell-vertico-sidebar--unread-p (buffer)
  "Return non-nil when BUFFER holds output nobody has read."
  (and (agent-shell-vertico-sidebar--unread-time buffer) t))

(defun agent-shell-vertico-sidebar--mark-unread-at (buffer time)
  "Record that BUFFER holds output nobody has read, arriving at TIME."
  (puthash buffer time agent-shell-vertico-sidebar--unread))

(defun agent-shell-vertico-sidebar--needs-attention-p (buffer)
  "Return non-nil when BUFFER is waiting on the reader.

Two things ask for the reader, and they are asked differently.  Unread
output is recorded, because nothing about a session says whether anyone
has looked at it.  A pending permission decision is not: the session
reports itself blocked for as long as it waits, so reading the status is
the whole answer and no record can go stale."
  (or (agent-shell-vertico-sidebar--unread-p buffer)
      (eq (agent-shell-vertico-sidebar--raw-status buffer) 'blocked)))

(defun agent-shell-vertico-sidebar--status-name (buffer)
  "Return a display status name for BUFFER.

The name says what the session is, never whether anyone has read it:
a finished turn leaves a session `Ready'."
  (or (agent-shell-vertico-sidebar--snapshot-field buffer :status-name)
      (agent-shell-vertico-sidebar--status-name-for
       buffer (agent-shell-vertico-sidebar--raw-status buffer))))

(defun agent-shell-vertico-sidebar--status-rank (buffer)
  "Return a status rank for BUFFER.  Lower ranks sort first."
  (or (agent-shell-vertico-sidebar--snapshot-field buffer :status-rank)
      (agent-shell-vertico-sidebar--status-rank-for
       (agent-shell-vertico-sidebar--raw-status buffer)
       (agent-shell-vertico-sidebar--needs-attention-p buffer))))

(defun agent-shell-vertico-sidebar--status-sort-rank (buffer)
  "Return the raw status rank for BUFFER.  Lower ranks sort first.

Unlike `agent-shell-vertico-sidebar--status-rank', this deliberately
ignores attention metadata; attention is the concern of `priority'."
  (or (agent-shell-vertico-sidebar--snapshot-field buffer :raw-status-rank)
      (agent-shell-vertico-sidebar--status-sort-rank-for
       (agent-shell-vertico-sidebar--raw-status buffer))))

(defun agent-shell-vertico-sidebar--status-rank-for (status attention)
  "Return the priority rank for STATUS, given ATTENTION.

A session nobody is waiting on ranks by what it is doing.  A failed one
that has been read ranks last with the sessions that can do nothing:
it has already said all it has to say."
  (cond
   (attention 0)
   ((eq status 'busy) 1)
   ((eq status 'ready) 2)
   (t 3)))

(defun agent-shell-vertico-sidebar--status-sort-rank-for (status)
  "Return the raw status rank for STATUS."
  (pcase status
    ('blocked 0)
    ('failed 1)
    ('busy 2)
    ('ready 3)
    ('starting 4)
    (_ 5)))

(defun agent-shell-vertico-sidebar--status-name-for (buffer status)
  "Return a display status for BUFFER from STATUS."
  (pcase status
    ('blocked "Waiting")
    ('failed "Failed")
    ('busy "Working")
    ('ready (if (agent-shell-vertico--session-field buffer :id)
                "Ready"
              "Starting"))
    ('starting "Starting")
    (_ "Unknown")))

(defun agent-shell-vertico-sidebar--session-snapshot (buffer)
  "Return one render snapshot for live session BUFFER.

The snapshot deliberately reads the live status once.  Sorting, grouping,
header statistics, and row rendering consume the resulting plist instead of
repeating those queries during one redisplay."
  (let* ((status (agent-shell-vertico-sidebar--raw-status buffer))
         (activity-time (agent-shell-vertico-sidebar--activity-time buffer))
         (unread (gethash buffer agent-shell-vertico-sidebar--unread))
         (attention (or (and unread t) (eq status 'blocked)))
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
          (agent-shell-vertico-sidebar--status-name-for buffer status)
          :status-rank (agent-shell-vertico-sidebar--status-rank-for
                        status attention)
          :mark (agent-shell-vertico-sidebar--mark-for status unread)
          :raw-status-rank
          (agent-shell-vertico-sidebar--status-sort-rank-for status)
          :unread unread
          :activity-time activity-time
          :busy-since-time busy-since-time
          :recency-time recency-time
          :model (agent-shell-vertico--model-name buffer)
          :mode (agent-shell-vertico--mode-name buffer)
          :agent (agent-shell-vertico--agent-name buffer)
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

Unread timestamps order sessions waiting for user action.  Working
sessions use the time their current turn entered the busy state; streamed
activity is deliberately not a priority tie-breaker.  Every other session
uses its latest activity, so one read or finished recently stays above
stale idle sessions instead of dropping to its alphabetical slot."
  (or (agent-shell-vertico-sidebar--unread-time buffer)
      (agent-shell-vertico-sidebar--snapshot-field buffer :busy-since-time)
      (gethash buffer agent-shell-vertico-sidebar--busy-since-times)
      (when (eq (agent-shell-vertico-sidebar--raw-status buffer) 'busy)
        (puthash buffer (float-time)
                 agent-shell-vertico-sidebar--busy-since-times))
      (agent-shell-vertico-sidebar--activity-time buffer)))

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

(defun agent-shell-vertico-sidebar--text-lessp (left right)
  "Return non-nil when display string LEFT sorts before RIGHT.

Case never decides the order, whatever the locale is: comparing the folded
strings keeps \"apple\" ahead of \"Zebra\" where byte order would not, and
strings differing only in case fall back to byte order so the comparison
stays total and deterministic."
  (let ((fold-left (downcase left))
        (fold-right (downcase right)))
    (if (string= fold-left fold-right)
        (string-lessp left right)
      (string-lessp fold-left fold-right))))

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
    ('agent "RET/mouse-1: new session with this agent")
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
           (cons 'agent
                 (agent-shell-vertico-sidebar--field-text
                  'agent
                  (or (agent-shell-vertico-sidebar--snapshot-field
                       buffer :agent)
                      (agent-shell-vertico--agent-name buffer))))
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
                    (concat (agent-shell-vertico-sidebar--slot-icon 'message)
                            (agent-shell-vertico-sidebar--icon-gap)
                            last-message))))))
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
            (concat (agent-shell-vertico-sidebar--slot-icon 'project)
                    (agent-shell-vertico-sidebar--icon-gap)
                    (agent-shell-vertico-sidebar--project-name root buffer))
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

(defun agent-shell-vertico-sidebar--any-project-expanded-p ()
  "Return non-nil when any project with live sessions shows them."
  (seq-some (lambda (buffer)
              (agent-shell-vertico-sidebar--project-expanded-p
               (agent-shell-vertico-sidebar--project-root buffer)))
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

(defconst agent-shell-vertico-sidebar--status-icons
  '((failed   "nf-md-close_circle"
              "nf-md-close_circle_outline"  "✖")
    (blocked  "nf-md-help_circle"
              "nf-md-help_circle_outline"   "?")
    (busy     "nf-md-dots_circle"
              "nf-md-dots_circle"           "◆")
    (ready    "nf-md-check_circle"
              "nf-md-check_circle_outline"  "✓")
    (starting "nf-md-circle_outline"
              "nf-md-circle_outline"        "○"))
  "Status, filled and outline nerd-icons names, and plain character.

One glyph per status, so a mark says what the session is: an empty
circle has produced nothing yet, dots are working, a check has finished,
a question mark is asking the reader something, and a cross failed.  The
filled variant marks unread output, which the colour says too.  A
terminal has no filled twin for a check or a question mark, so its plain
character is the same read or unread and the colour carries it alone.
Working and starting have nothing to have missed — a session still
running or not yet begun has produced nothing a reader could be behind
on — so their filled and outline names are the same glyph and the colour
is the only thing that ever changes.")

(defconst agent-shell-vertico-sidebar--status-order
  '(failed blocked busy ready starting)
  "Order in which status counts appear in headers.")

(defconst agent-shell-vertico-sidebar--icons
  '((project   "nf-cod-root_folder"       "⌂")
    (message   "nf-cod-arrow_small_right" "↳")
    (sessions  "nf-cod-layers"            "⧉")
    (expanded  nil                        "▼")
    (collapsed nil                        "▶"))
  "Slot, nerd-icons name, and plain character for each mark that is not
a status.

Slots with no nerd-icons name always draw their character.  The
`sessions' layers mark stands for the total count in a header.  The fold
triangles match the ones `agent-shell' uses for its own collapsible
fragments.")

(defvar agent-shell-vertico-sidebar--nerd-icons-available 'unknown
  "Whether the `nerd-icons' package could be loaded.

`unknown' until the first look, so a missing package is searched for once
rather than on every drawn icon.")

(defun agent-shell-vertico-sidebar--nerd-icons-p ()
  "Return non-nil when the sidebar should draw nerd-icons glyphs."
  (pcase agent-shell-vertico-sidebar-use-nerd-icons
    ('auto (when (eq agent-shell-vertico-sidebar--nerd-icons-available
                     'unknown)
             (setq agent-shell-vertico-sidebar--nerd-icons-available
                   (and (require 'nerd-icons nil t) t)))
           agent-shell-vertico-sidebar--nerd-icons-available)
    (value value)))

(defun agent-shell-vertico-sidebar--draw-icon (name text &optional face)
  "Return NAME's nerd-icons glyph, or TEXT without them, drawn in FACE."
  (let ((drawer (when name
                  (if (string-prefix-p "nf-md-" name)
                      'nerd-icons-mdicon
                    'nerd-icons-codicon))))
    (if (and drawer
             (agent-shell-vertico-sidebar--nerd-icons-p)
             (fboundp drawer))
        (if face
            (funcall drawer name :face face)
          (funcall drawer name))
      (if face (propertize text 'face face) text))))

(defun agent-shell-vertico-sidebar--slot-icon (slot &optional face)
  "Return the mark for SLOT, drawn in FACE."
  (pcase-let ((`(,_ ,name ,text) (assq slot
                                       agent-shell-vertico-sidebar--icons)))
    (agent-shell-vertico-sidebar--draw-icon name text face)))

(defun agent-shell-vertico-sidebar--status-icon (status unread &optional face)
  "Return the mark for STATUS, filled when UNREAD, drawn in FACE."
  (pcase-let ((`(,_ ,filled ,outline ,text)
               (or (assq status agent-shell-vertico-sidebar--status-icons)
                   (assq 'starting
                         agent-shell-vertico-sidebar--status-icons))))
    (agent-shell-vertico-sidebar--draw-icon
     (if unread filled outline) text face)))

(defun agent-shell-vertico-sidebar--icon-frame ()
  "Return the frame showing the sidebar, or nil for the selected frame."
  (when-let ((window (get-buffer-window
                      (or (get-buffer "*Agent Shell Sessions*")
                          (current-buffer))
                      t)))
    (window-frame window)))

(defun agent-shell-vertico-sidebar--icon-gap ()
  "Return the spacing between a mark and the text after it.

Nerd-icons glyphs fill their cell, so they need more room than a plain
character does.  A terminal can only widen the gap by whole columns; a
graphical frame takes a fraction of one instead."
  (cond
   ((not (agent-shell-vertico-sidebar--nerd-icons-p)) " ")
   ((display-graphic-p (agent-shell-vertico-sidebar--icon-frame))
    (concat " " (propertize " " 'display '(space :width 0.5))))
   (t "  ")))

(defun agent-shell-vertico-sidebar--count-text (mark count &optional face)
  "Return COUNT preceded by MARK, both drawn in FACE.

MARK is a status mark, a status and whether it is unread, or one of the
slots that is not a status.  The mark and the number are separated the
same way a mark and a title are, so a glyph that fills its cell does not
touch the digits after it."
  (concat (if (consp mark)
              (agent-shell-vertico-sidebar--mark-icon mark face)
            (agent-shell-vertico-sidebar--slot-icon mark face))
          (agent-shell-vertico-sidebar--icon-gap)
          (let ((count (number-to-string count)))
            (if face (propertize count 'face face) count))))

(defun agent-shell-vertico-sidebar--content-width (width nested)
  "Return the columns left for text on a session row of WIDTH.

NESTED rows are indented below a project header."
  (max 1 (- width
            (if nested 2 0)
            1
            (string-width (agent-shell-vertico-sidebar--icon-gap)))))

(defun agent-shell-vertico-sidebar--mark-for (status unread)
  "Return the mark a session in STATUS gets, given UNREAD.

A mark is the pair the sidebar draws from: the status picks the glyph
and the colour family, unread fills the glyph and turns it red."
  (cons status (and unread t)))

(defun agent-shell-vertico-sidebar--mark (buffer)
  "Return the mark drawn for BUFFER."
  (or (agent-shell-vertico-sidebar--snapshot-field buffer :mark)
      (agent-shell-vertico-sidebar--mark-for
       (agent-shell-vertico-sidebar--raw-status buffer)
       (agent-shell-vertico-sidebar--unread-p buffer))))

(defun agent-shell-vertico-sidebar--mark-icon (mark &optional face)
  "Return MARK's glyph, drawn in FACE."
  (agent-shell-vertico-sidebar--status-icon (car mark) (cdr mark) face))

(defun agent-shell-vertico-sidebar--mark-face (mark)
  "Return the face MARK is drawn in.

Red is what nobody has read.  Yellow is what the reader has seen and
still owes something: a permission decision, or a failure they have not
started again.  Everything else is drawn in its status colour."
  (cond
   ((cdr mark) 'agent-shell-vertico-sidebar-attention)
   ((memq (car mark) '(blocked failed))
    'agent-shell-vertico-sidebar-unresolved)
   ((eq (car mark) 'busy) 'agent-shell-vertico-sidebar-working)
   ((eq (car mark) 'ready) 'agent-shell-vertico-sidebar-ready)
   (t 'agent-shell-vertico-sidebar-detail)))

(defun agent-shell-vertico-sidebar--mark-counts (marks)
  "Return an alist of mark to count for MARKS, in display order.

Unread marks come first, so a header reads what wants the reader before
what does not.  Marks with no sessions are left out."
  (let (counts)
    (dolist (unread '(t nil))
      (dolist (status agent-shell-vertico-sidebar--status-order)
        (let* ((mark (agent-shell-vertico-sidebar--mark-for status unread))
               (count (seq-count (lambda (other) (equal other mark)) marks)))
          (when (> count 0)
            (push (cons mark count) counts)))))
    (nreverse counts)))

(defun agent-shell-vertico-sidebar--icon (buffer)
  "Return the mark for BUFFER, drawn in its own face."
  (let ((mark (agent-shell-vertico-sidebar--mark buffer)))
    (agent-shell-vertico-sidebar--mark-icon
     mark (agent-shell-vertico-sidebar--mark-face mark))))

(defun agent-shell-vertico-sidebar--compare-buffers (left right sort-by)
  "Return non-nil when LEFT sorts before RIGHT by SORT-BY.

Under `priority' the attention and working tiers order oldest first,
so the sidebar's first session is the one
`agent-shell-vertico-sidebar-jump' visits; the remaining tiers order
newest first so a session that was read or finished recently stays near
the top of its tier."
  (let* ((left-title (agent-shell-vertico-sidebar--title left))
         (right-title (agent-shell-vertico-sidebar--title right))
         (left-rank (when (memq sort-by '(status priority))
                      (if (eq sort-by 'status)
                          (agent-shell-vertico-sidebar--status-sort-rank left)
                        (agent-shell-vertico-sidebar--status-rank left))))
         (right-rank (when (memq sort-by '(status priority))
                       (if (eq sort-by 'status)
                           (agent-shell-vertico-sidebar--status-sort-rank right)
                         (agent-shell-vertico-sidebar--status-rank right))))
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
     ((eq sort-by 'name)
      (agent-shell-vertico-sidebar--text-lessp left-title right-title))
     ((and (eq sort-by 'status) (/= left-rank right-rank))
      (< left-rank right-rank))
     ((and (eq sort-by 'priority) (/= left-rank right-rank))
      (< left-rank right-rank))
     ((and (eq sort-by 'priority) (/= left-time right-time))
      ;; Ranks are equal here, so LEFT's rank picks the tier's direction.
      (if (<= left-rank 1)
          (< left-time right-time)
        (> left-time right-time)))
     ((/= left-time right-time) (> left-time right-time))
     ((not (string= left-title right-title))
      (agent-shell-vertico-sidebar--text-lessp left-title right-title))
     (t (agent-shell-vertico-sidebar--text-lessp
         (buffer-name left) (buffer-name right))))))

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
                          (agent-shell-vertico-sidebar--text-lessp
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
  "Move point to NODE, returning non-nil when found.

Point does not move when NODE is absent: the search walks to the end of
the buffer, and leaving point on the empty last line would make the next
key report that there is no session at point."
  (when (cdr node)
    (let ((position
           (save-excursion
             (goto-char (point-min))
             (let (found)
               (while (and (not found) (not (eobp)))
                 (if (and
                      (eq (car node)
                          (agent-shell-vertico-sidebar--node-kind-at-point))
                      (equal (cdr node)
                             (agent-shell-vertico-sidebar--node-at-point)))
                     (setq found (point))
                   (forward-line 1)))
               found))))
      (when position
        (goto-char position))
      position)))

(defun agent-shell-vertico-sidebar--node-positions ()
  "Return selectable nodes and their first buffer positions in display order."
  (save-excursion
    (goto-char (point-min))
    (let (last-node positions)
      (while (not (eobp))
        (let ((node (agent-shell-vertico-sidebar--point-node)))
          (when (and (cdr node) (not (equal node last-node)))
            (push (cons node (point)) positions))
          (setq last-node node))
        (forward-line 1))
      (nreverse positions))))

(defun agent-shell-vertico-sidebar--preceding-node-entry
    (position node-positions)
  "Return the last NODE-POSITIONS entry starting at or before POSITION.
NODE-POSITIONS is in display order, so the first match from the end is the
node POSITION sits under."
  (seq-find (lambda (entry) (<= (cdr entry) position))
            (reverse node-positions)))

(defun agent-shell-vertico-sidebar--view-anchor (position node-positions)
  "Capture a simple view anchor at POSITION among NODE-POSITIONS.
The anchor records POSITION's logical line within its node so a render can
restore a surviving title, context, or detail line."
  (save-excursion
    (goto-char position)
    (let* ((node (agent-shell-vertico-sidebar--point-node))
           (node-position (cdr (assoc node node-positions)))
           (index (or (cl-position node node-positions
                                   :key #'car :test #'equal)
                      0)))
      (list :node node
            :index index
            :line-offset
            (when node-position
              (count-lines node-position (line-beginning-position)))))))

(defun agent-shell-vertico-sidebar--anchor-position (anchor node-positions)
  "Resolve ANCHOR against NODE-POSITIONS after a render.

The offset is only honoured when it reaches the beginning of a line that
still belongs to the node.  Walking past the last line of the list leaves
point at the end of it instead, which is a column the anchor never
recorded, so a node whose lines were removed falls back to its first."
  (let* ((node (plist-get anchor :node))
         (node-position (cdr (assoc node node-positions))))
    (or (when node-position
          (save-excursion
            (goto-char node-position)
            (forward-line (or (plist-get anchor :line-offset) 0))
            (if (and (bolp)
                     (equal node (agent-shell-vertico-sidebar--point-node)))
                (point)
              node-position)))
        (when node-positions
          (cdr (nth (min (plist-get anchor :index)
                         (1- (length node-positions)))
                    node-positions)))
        (point-min))))

(defun agent-shell-vertico-sidebar--filled-window-start (window start)
  "Return START pulled up until WINDOW keeps no blank rows below the list.
A render can shrink the content under a scrolled START, or WINDOW may have
grown; either would show blank rows while sessions sit hidden above the
start."
  (min start
       (save-excursion
         (goto-char (point-max))
         (vertical-motion (- (1- (window-body-height window))) window)
         (point))))

(defun agent-shell-vertico-sidebar--restore-window-anchor
    (anchor node-positions)
  "Restore one displayed window from ANCHOR using NODE-POSITIONS.
ANCHOR holds the window and one view anchor each for its start and its
point.  Anchoring the start at its own node keeps the row at the top of
the window stable without any screen-row arithmetic."
  (let ((window (plist-get anchor :window)))
    (when (and (window-live-p window)
               (eq (window-buffer window) (current-buffer)))
      (let ((start (agent-shell-vertico-sidebar--anchor-position
                    (plist-get anchor :start) node-positions))
            (position (agent-shell-vertico-sidebar--anchor-position
                       (plist-get anchor :point) node-positions)))
        (set-window-start
         window
         (agent-shell-vertico-sidebar--filled-window-start window start)
         t)
        (set-window-point window position)))))

(defun agent-shell-vertico-sidebar--session-lines (buffer root width &optional nested)
  "Return rendered session lines for BUFFER at WIDTH under ROOT."
  (let* ((content-width
          (agent-shell-vertico-sidebar--content-width width nested))
         (title (agent-shell-vertico-sidebar--title buffer))
         (icon (agent-shell-vertico-sidebar--icon buffer))
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
          (cons (concat icon (agent-shell-vertico-sidebar--icon-gap)
                        (car title-lines))
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

(defun agent-shell-vertico-sidebar--current-session-marker ()
  "Return a zero-width fringe marker for the current session's row.

The marker is a `display' spec on one space, so it costs no columns in
the text area: Emacs draws the fringe bitmap in its place instead of the
space, the same idiom `gptel-highlight-mode' uses for its response
markers."
  (propertize " " 'display
              '(left-fringe
                agent-shell-vertico-sidebar-current-session-fringe
                agent-shell-vertico-sidebar-current-session)))

(defun agent-shell-vertico-sidebar--insert-row (lines kind node &optional nested)
  "Insert session LINES with KIND and NODE text properties.

NESTED reserves the two columns a project header spends on its fold
triangle, so a session icon lines up under the project name; flat rows
keep their status icon at column zero.

Indentation is a `line-prefix' display property rather than inserted
spaces, as `agent-shell' does for its own fragments: the columns are
visual only, so copied rows carry no leading whitespace and point at the
beginning of a line is already on the row's first real character.  The
row for the current session gets the same treatment for its fringe
marker, prepended to whichever indentation prefix already applies, so it
adds no columns of its own either."
  (let* ((marker (and (eq kind 'session)
                      (eq node agent-shell-vertico-sidebar--current-session)
                      (agent-shell-vertico-sidebar--current-session-marker)))
         (start (point))
         (first-prefix (concat marker (and nested "  ")))
         (continuation-prefix (concat marker (if nested "    " "  ")))
         (title-end nil)
         (first t))
    (dolist (line lines)
      (let ((line-start (line-beginning-position))
            (prefix (if first first-prefix continuation-prefix)))
        (insert (car line))
        (unless (string-empty-p prefix)
          (add-text-properties line-start (point)
                               (list 'line-prefix prefix
                                     'wrap-prefix prefix)))
        (when (cdr line)
          ;; Merge rather than set: an icon carries its own font family in
          ;; its face, and replacing that face would leave the glyph with
          ;; no font to draw it.
          (add-face-text-property line-start (point) (cdr line))))
      (when (null (cdr line))
        (setq title-end (point)))
      (insert "\n")
      (setq first nil))
    (add-text-properties
     start (1- (point))
     (list 'agent-shell-vertico-sidebar-node node
           'agent-shell-vertico-sidebar-node-kind kind))
    (when title-end
      ;; `title-end' is already before the newline, unlike the node span
      ;; below, which ends after the row's last one.
      (add-text-properties
       start title-end
       (list 'mouse-face 'highlight
             'help-echo (buffer-name node)
             'kbd-help "RET/mouse-1: open session")))
    (agent-shell-vertico-sidebar--restore-field-properties
     start (1- (point)))))

(defun agent-shell-vertico-sidebar--project-summary (buffers)
  "Return the count shown at the right of a project header for BUFFERS.

Only the most pressing mark that asks for the reader is counted, and a
project with nothing waiting on the reader gets no count at all.  The
session total is the whole sidebar's header, and every other status is
on the session row that has it, so a project header states only what
asks for a reply."
  (when-let ((urgent
              (seq-find
               (lambda (entry)
                 (let ((mark (car entry)))
                   (or (cdr mark) (eq (car mark) 'blocked))))
               (agent-shell-vertico-sidebar--mark-counts
                (mapcar #'agent-shell-vertico-sidebar--mark buffers)))))
    (agent-shell-vertico-sidebar--count-text
     (car urgent) (cdr urgent)
     (agent-shell-vertico-sidebar--mark-face (car urgent)))))

(defun agent-shell-vertico-sidebar--project-header-line
    (indicator name summary width)
  "Return a project header of WIDTH holding INDICATOR, NAME, and SUMMARY.

SUMMARY, when there is one, keeps the right edge of the row, so a NAME too
long for the remaining columns is the part that gets shortened.  A drawn
glyph is wider than the one column it counts as, so a row using icons keeps
a column of slack rather than pushing its count past the window edge."
  (let* ((slack (if (and summary (agent-shell-vertico-sidebar--nerd-icons-p))
                    1
                  0))
         (reserved (if summary (+ 2 (string-width summary) slack) 0))
         (name (agent-shell-vertico-sidebar--fit
                name
                (max 1 (- width (string-width indicator) 1 reserved)))))
    (concat indicator " " name
            (when summary
              (concat (make-string
                       (max 2 (- width (string-width indicator) 1
                                 (string-width name) (string-width summary)
                                 slack))
                       ?\s)
                      summary)))))

(defun agent-shell-vertico-sidebar--insert-project (root buffers width)
  "Insert project header ROOT and its BUFFERS at WIDTH."
  (let* ((expanded
          (agent-shell-vertico-sidebar--project-expanded-p root))
         (indicator (agent-shell-vertico-sidebar--slot-icon
                     (if expanded 'expanded 'collapsed)))
         (line (agent-shell-vertico-sidebar--project-header-line
                indicator
                (agent-shell-vertico-sidebar--project-name
                 root (car buffers))
                (agent-shell-vertico-sidebar--project-summary buffers)
                width))
         (start (point)))
    (insert (agent-shell-vertico-sidebar--fit line width) "\n")
    ;; Merged, so the summary icons keep the font family in their own face.
    (add-face-text-property start (1- (point))
                            'agent-shell-vertico-sidebar-project)
    (add-text-properties
     start (1- (point))
     (list 'agent-shell-vertico-sidebar-node root
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
  (unless (derived-mode-p 'agent-shell-vertico-sidebar-mode)
    (user-error "The named sidebar buffer is not an agent-shell sidebar"))
  (let* ((buffers (seq-filter #'buffer-live-p (agent-shell-buffers)))
         (snapshots (mapcar #'agent-shell-vertico-sidebar--session-snapshot
                            buffers))
         (snapshot-table (make-hash-table :test #'eq))
         ;; Any visible frame, matching the check that lets an event-driven
         ;; refresh through: looking only at the selected frame would render
         ;; a sidebar on another frame at the fallback width.
         (width (or (when-let ((window (get-buffer-window (current-buffer)
                                                          'visible)))
                      (window-body-width window))
                    agent-shell-vertico-sidebar-width))
         ;; `erase-buffer' invalidates raw positions.  Keep only the stable
         ;; node, its line offset and ordinal fallback, for point and for
         ;; each window's start and point.
         (node-positions (agent-shell-vertico-sidebar--node-positions))
         (point-anchor
          (agent-shell-vertico-sidebar--view-anchor (point) node-positions))
         (window-anchors
          (mapcar
           (lambda (window)
             (list :window window
                   :start (agent-shell-vertico-sidebar--view-anchor
                           (window-start window) node-positions)
                   :point (agent-shell-vertico-sidebar--view-anchor
                           (window-point window) node-positions)))
           (get-buffer-window-list (current-buffer) nil t)))
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
          ;; Every row is inserted with a closing newline, so the buffer
          ;; would end on a blank line carrying no session.  Point left
          ;; there, by a key at the end of the list or a click in the empty
          ;; area under it, reports no session at point.
          (goto-char (point-max))
          (when (eq (char-before) ?\n)
            (delete-char -1))
          (let ((node-positions
                 (agent-shell-vertico-sidebar--node-positions)))
            (goto-char
             (agent-shell-vertico-sidebar--anchor-position
              point-anchor node-positions))
            (dolist (anchor window-anchors)
              (agent-shell-vertico-sidebar--restore-window-anchor
               anchor node-positions)))
          (agent-shell-vertico-sidebar--ensure-age-refresh snapshots t))
      (setq agent-shell-vertico-sidebar--render-snapshots nil))))

(defun agent-shell-vertico-sidebar--clamp-width (width frame-width)
  "Cap WIDTH to the configured share of FRAME-WIDTH's columns.
The cap stops at 16 columns, below which the list is unreadable, and
never returns more than WIDTH.  A nil
`agent-shell-vertico-sidebar-max-width-fraction' returns WIDTH as is."
  (if agent-shell-vertico-sidebar-max-width-fraction
      (min width
           (max 16
                (floor (* agent-shell-vertico-sidebar-max-width-fraction
                          frame-width))))
    width))

(defun agent-shell-vertico-sidebar--target-width (window)
  "Return the width in columns WINDOW's sidebar should have.
That is the configured width, capped against WINDOW's frame."
  (agent-shell-vertico-sidebar--clamp-width
   agent-shell-vertico-sidebar-width
   (frame-width (window-frame window))))

(defun agent-shell-vertico-sidebar--width-drifted-p (window)
  "Return non-nil when side WINDOW is not at its target width.
Only side windows count: the width must never be forced on a normal
window that happens to show the sidebar buffer."
  (when (window-parameter window 'window-side)
    (/= (window-total-width window)
        (agent-shell-vertico-sidebar--target-width window))))

(defun agent-shell-vertico-sidebar--enforce-window-width (window)
  "Resize side WINDOW to its target width when it has drifted from it.
Width preservation is released around the resize and restored after it,
so the pinned width follows the target instead of fighting it.

The resize goes both ways.  Restoring a window configuration, which is
how workspace packages switch layouts, recreates the sidebar window from
a saved proportion of the frame and drops the preserved size that held
its width, so a sidebar comes back too narrow as often as too wide."
  (when (agent-shell-vertico-sidebar--width-drifted-p window)
    (let ((target (agent-shell-vertico-sidebar--target-width window)))
      (window-preserve-size window t nil)
      (ignore-errors
        (window-resize window (- target (window-total-width window)) t))
      (window-preserve-size window t t))))

(defun agent-shell-vertico-sidebar--window-size-change (&optional frame)
  "Coalesce a visible sidebar re-render after FRAME's windows resize.
The idle callback also puts a sidebar back at its target width, which a
narrowing frame and a restored window configuration both move it away
from."
  (when-let ((sidebar (get-buffer "*Agent Shell Sessions*")))
    (when-let ((window (get-buffer-window sidebar frame)))
      (with-current-buffer sidebar
        (let ((width (window-body-width window)))
          (when (and (derived-mode-p 'agent-shell-vertico-sidebar-mode)
                     (or (not (equal
                               width
                               agent-shell-vertico-sidebar--last-rendered-width))
                         (agent-shell-vertico-sidebar--width-drifted-p
                          window))
                     (not (timerp agent-shell-vertico-sidebar--resize-timer)))
            (setq agent-shell-vertico-sidebar--resize-timer
                  (run-with-idle-timer
                   0.1 nil
                   (lambda ()
                     (when (buffer-live-p sidebar)
                       (with-current-buffer sidebar
                         (setq agent-shell-vertico-sidebar--resize-timer nil)
                         (when-let ((window (get-buffer-window sidebar frame)))
                           (agent-shell-vertico-sidebar--enforce-window-width
                            window)
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
  (if-let ((buffer (get-buffer "*Agent Shell Sessions*")))
      (if (with-current-buffer buffer
            (derived-mode-p 'agent-shell-vertico-sidebar-mode))
          buffer
        (user-error "The named sidebar buffer is not an agent-shell sidebar"))
    (get-buffer-create "*Agent Shell Sessions*")))

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

(defconst agent-shell-vertico-sidebar--out-of-turn-events
  '(agent-message-chunk tool-call-update)
  "Events that carry agent output rather than turn bookkeeping.

These are the public events agent-shell emits for the `session/update'
notifications it treats as belonging to a turn, so one arriving with no
turn in flight is what identifies an out-of-turn burst.")

(defconst agent-shell-vertico-sidebar--out-of-turn-settle-margin 0.5
  "Seconds added to agent-shell's quiet period before a burst is settled.

Settling after agent-shell has dropped its own busy indicator keeps the
sidebar from calling a session done while the shell still shows it
working.")

(defun agent-shell-vertico-sidebar--out-of-turn-settle-seconds ()
  "Return the quiet period, in seconds, that ends an out-of-turn burst.

Follows agent-shell's own debounce when that is available, so the two
agree on when a burst has stopped."
  (+ (if (boundp 'agent-shell--out-of-turn-idle-seconds)
         (symbol-value 'agent-shell--out-of-turn-idle-seconds)
       2.0)
     agent-shell-vertico-sidebar--out-of-turn-settle-margin))

(defun agent-shell-vertico-sidebar--out-of-turn-p (buffer kind)
  "Return non-nil when a KIND event in BUFFER is out-of-turn output.

Requires agent output with no request of any kind in flight.  Checking
the status alone is not enough: a steered prompt's own request is
tracked while `agent-shell-status' still answers `ready', and the updates
arriving during that round trip belong to the turn it is joining."
  (and (memq kind agent-shell-vertico-sidebar--out-of-turn-events)
       (not (memq (agent-shell-vertico-sidebar--live-status buffer)
                  '(busy blocked)))
       (not (map-elt (agent-shell-vertico--state buffer) :active-requests))))

(defun agent-shell-vertico-sidebar--cancel-out-of-turn (buffer)
  "Drop any pending out-of-turn settle timer for BUFFER."
  (when-let* ((burst (gethash buffer agent-shell-vertico-sidebar--out-of-turn))
              (timer (plist-get burst :timer))
              ((timerp timer)))
    (cancel-timer timer))
  (remhash buffer agent-shell-vertico-sidebar--out-of-turn))

(defun agent-shell-vertico-sidebar--note-out-of-turn (buffer time)
  "Record out-of-turn output in BUFFER at TIME and rearm its settle timer.

The burst keeps the time of its first update as its working age, so a
long burst rises through the working tier instead of restarting at every
chunk."
  (agent-shell-vertico-sidebar--cancel-out-of-turn buffer)
  (unless (gethash buffer agent-shell-vertico-sidebar--busy-since-times)
    (puthash buffer time agent-shell-vertico-sidebar--busy-since-times))
  (puthash buffer
           (list :timer
                 (run-at-time
                  (agent-shell-vertico-sidebar--out-of-turn-settle-seconds)
                  nil
                  #'agent-shell-vertico-sidebar--out-of-turn-settled
                  buffer)
                 :time time)
           agent-shell-vertico-sidebar--out-of-turn))

(defun agent-shell-vertico-sidebar--out-of-turn-settled (buffer)
  "Mark BUFFER's finished out-of-turn output as unread.

A burst carries no completion event, so it counts as finished once it has
been quiet for `agent-shell-vertico-sidebar--out-of-turn-settle-seconds'.
A pause longer than that mid-burst settles early; the next update starts
a fresh burst and finds this mark already in place, so the reader still
sees one mark rather than a flicker."
  (let ((burst (gethash buffer agent-shell-vertico-sidebar--out-of-turn)))
    (agent-shell-vertico-sidebar--cancel-out-of-turn buffer)
    (remhash buffer agent-shell-vertico-sidebar--busy-since-times)
    (when (and (buffer-live-p buffer)
               ;; A real turn started meanwhile and owns the session now.
               (not (memq (agent-shell-vertico-sidebar--live-status buffer)
                          '(busy blocked)))
               ;; An earlier unread mark keeps its own time, so the
               ;; attention tier still orders oldest first.
               (not (gethash buffer agent-shell-vertico-sidebar--unread))
               (not (agent-shell-vertico-sidebar--session-focused-p buffer)))
      (puthash buffer
               (or (plist-get burst :time) (float-time))
               agent-shell-vertico-sidebar--unread)
      (agent-shell-vertico-sidebar--notify buffer))
    (agent-shell-vertico-sidebar--schedule-refresh)))

(defun agent-shell-vertico-sidebar--record-message-chunk (buffer event)
  "Accumulate the agent message BUFFER is streaming in EVENT.

agent-shell emits one event per streamed chunk and accumulates none of
them, so the sidebar keeps the newest message for a notification to
carry.  Any other event ends the message, which is agent-shell's own
message boundary."
  (let ((entry (gethash buffer agent-shell-vertico-sidebar--messages)))
    (if (not (eq (map-elt event :event) 'agent-message-chunk))
        (when entry
          (puthash buffer (plist-put entry :open nil)
                   agent-shell-vertico-sidebar--messages))
      (unless (plist-get entry :open)
        (setq entry (list :chunks nil :open t)))
      (when-let* ((chunk (map-nested-elt event '(:data :text-chunk))))
        (setq entry (plist-put entry :chunks
                               (cons chunk (plist-get entry :chunks)))))
      (puthash buffer entry agent-shell-vertico-sidebar--messages))))

(defun agent-shell-vertico-sidebar--last-message (buffer)
  "Return the newest agent message streamed into BUFFER, or nil."
  (when-let* ((chunks (plist-get
                       (gethash buffer
                                agent-shell-vertico-sidebar--messages)
                       :chunks)))
    (apply #'concat (reverse chunks))))

(defun agent-shell-vertico-sidebar--notify (buffer)
  "Report that BUFFER now needs attention.

The report goes to `agent-shell-vertico-sidebar-notify-function'.  Call
this after the unread mark and the status are in place, since both are
read back from the session."
  (when (and agent-shell-vertico-sidebar-notify-function
             (buffer-live-p buffer)
             (not (agent-shell-vertico-sidebar--session-focused-p buffer)))
    (funcall agent-shell-vertico-sidebar-notify-function
             :buffer buffer
             :agent (agent-shell-vertico--agent-name buffer)
             :status (agent-shell-vertico-sidebar--status-name buffer)
             :unread (agent-shell-vertico-sidebar--unread-p buffer)
             :last-message (agent-shell-vertico-sidebar--last-message buffer))))

(defun agent-shell-vertico-sidebar--handle-event (buffer event)
  "Update sidebar metadata for BUFFER after agent EVENT."
  (let ((kind (map-elt event :event))
        (now (float-time)))
    (agent-shell-vertico-sidebar--record-message-chunk buffer event)
    (puthash buffer now agent-shell-vertico-sidebar--activity)
    (pcase kind
      ('permission-request
       (agent-shell-vertico-sidebar--cancel-out-of-turn buffer)
       (remhash buffer agent-shell-vertico-sidebar--busy-since-times)
       ;; The request itself is news; the session reports itself blocked
       ;; for as long as it waits, so nothing records that part.
       (agent-shell-vertico-sidebar--mark-unread-at buffer now)
       (agent-shell-vertico-sidebar--notify buffer))
      ('error
       (agent-shell-vertico-sidebar--cancel-out-of-turn buffer)
       (remhash buffer agent-shell-vertico-sidebar--busy-since-times)
       (puthash buffer t agent-shell-vertico-sidebar--failed)
       (agent-shell-vertico-sidebar--mark-unread-at buffer now)
       (agent-shell-vertico-sidebar--notify buffer))
      ('turn-complete
       (agent-shell-vertico-sidebar--cancel-out-of-turn buffer)
       (remhash buffer agent-shell-vertico-sidebar--busy-since-times)
       (if (agent-shell-vertico-sidebar--session-focused-p buffer)
           (remhash buffer agent-shell-vertico-sidebar--unread)
         (agent-shell-vertico-sidebar--mark-unread-at buffer now)
         (agent-shell-vertico-sidebar--notify buffer)))
      ('input-submitted
       (agent-shell-vertico-sidebar--cancel-out-of-turn buffer)
       (puthash buffer now agent-shell-vertico-sidebar--busy-since-times)
       ;; Submitting a new prompt means the user has seen whatever the
       ;; previous turn produced, and starts a turn of their own, so how
       ;; the last one ended stops being what the session is.
       (remhash buffer agent-shell-vertico-sidebar--unread)
       (remhash buffer agent-shell-vertico-sidebar--failed))
      ('permission-response
       ;; Answering a request is reading it, whether or not another one
       ;; is already pending behind it.
       (remhash buffer agent-shell-vertico-sidebar--unread)
       (when (eq (agent-shell-vertico-sidebar--live-status buffer) 'busy)
         (puthash buffer now agent-shell-vertico-sidebar--busy-since-times)))
      ('idle
       (remhash buffer agent-shell-vertico-sidebar--busy-since-times))
      ('clean-up
       (agent-shell-vertico-sidebar--cancel-out-of-turn buffer)
       (remhash buffer agent-shell-vertico-sidebar--messages)
       (remhash buffer agent-shell-vertico-sidebar--unread)
       (remhash buffer agent-shell-vertico-sidebar--failed)
       (remhash buffer agent-shell-vertico-sidebar--busy-since-times)
       (remhash buffer agent-shell-vertico-sidebar--activity))
      (_ nil))
    (when (agent-shell-vertico-sidebar--out-of-turn-p buffer kind)
      (agent-shell-vertico-sidebar--note-out-of-turn buffer now))
    (agent-shell-vertico-sidebar--schedule-refresh)))

(defconst agent-shell-vertico-sidebar--subscription-refused 'refused
  "Marker recorded for a session that would not take a subscription.")

(defun agent-shell-vertico-sidebar--unwatch-buffer ()
  "Remove the event subscription for the current agent-shell buffer."
  (let ((subscription (gethash (current-buffer)
                               agent-shell-vertico-sidebar--subscriptions)))
    (when (and subscription
               (not (eq subscription
                        agent-shell-vertico-sidebar--subscription-refused))
               (fboundp 'agent-shell-unsubscribe))
      (ignore-errors (agent-shell-unsubscribe :subscription subscription)))
    (agent-shell-vertico-sidebar--cancel-out-of-turn (current-buffer))
    (remhash (current-buffer) agent-shell-vertico-sidebar--subscriptions)
    (remhash (current-buffer) agent-shell-vertico-sidebar--messages)
    (remhash (current-buffer) agent-shell-vertico-sidebar--unread)
    (remhash (current-buffer) agent-shell-vertico-sidebar--failed)
    (remhash (current-buffer)
             agent-shell-vertico-sidebar--busy-since-times)
    (remhash (current-buffer) agent-shell-vertico-sidebar--activity)
    (when (eq (current-buffer) agent-shell-vertico-sidebar--current-session)
      (setq agent-shell-vertico-sidebar--current-session nil))
    (agent-shell-vertico-sidebar--schedule-refresh)))

(defun agent-shell-vertico-sidebar--watch-buffer (&optional buffer schedule)
  "Subscribe to events from BUFFER when supported by agent-shell.

When SCHEDULE is non-nil, mark the sidebar dirty after subscribing.

A session can refuse the subscription: `agent-shell-subscribe-to' extends
the session's own state alist with `map-put!', which signals
`map-not-inplace' when that alist carries no `:event-subscriptions' key,
as an agent-shell buffer built before that key existed does.  The sidebar
renders such a session without live event updates rather than letting one
bad session abort the whole render.  The refusal is recorded so later
renders neither retry it nor report it again."
  (setq buffer (or buffer (current-buffer)))
  (when (and (buffer-live-p buffer)
             (with-current-buffer buffer
               (derived-mode-p 'agent-shell-mode))
             (fboundp 'agent-shell-subscribe-to)
             (not (gethash buffer agent-shell-vertico-sidebar--subscriptions)))
    (let ((subscription
           (condition-case error
               (agent-shell-subscribe-to
                :shell-buffer buffer
                :on-event (lambda (event)
                            (agent-shell-vertico-sidebar--handle-event
                             buffer event)))
             (error
              (message "agent-shell-vertico: %s takes no events (%s)"
                       (buffer-name buffer) (error-message-string error))
              agent-shell-vertico-sidebar--subscription-refused))))
      (puthash buffer subscription
               agent-shell-vertico-sidebar--subscriptions))
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
      (agent-shell-vertico-sidebar--cancel-out-of-turn buffer)
      (remhash buffer agent-shell-vertico-sidebar--subscriptions)
      (remhash buffer agent-shell-vertico-sidebar--messages)
      (remhash buffer agent-shell-vertico-sidebar--unread)
      (remhash buffer agent-shell-vertico-sidebar--failed)
      (remhash buffer agent-shell-vertico-sidebar--busy-since-times)
      (remhash buffer agent-shell-vertico-sidebar--activity)))
  (dolist (buffer (if buffers-supplied buffers (agent-shell-buffers)))
    (agent-shell-vertico-sidebar--watch-buffer buffer schedule)))

(defun agent-shell-vertico-sidebar--viewport-buffer (buffer)
  "Return the existing viewport buffer showing session BUFFER, or nil.

Never creates one: a session the reader has not viewed this way should
not gain a viewport because the sidebar asked about it."
  (when (fboundp 'agent-shell-viewport--buffer)
    (when-let ((viewport (ignore-errors
                           (agent-shell-viewport--buffer
                            :shell-buffer buffer :existing-only t))))
      (and (buffer-live-p viewport)
           (not (eq viewport buffer))
           viewport))))

(defun agent-shell-vertico-sidebar--frame-focused-p (frame)
  "Return non-nil unless FRAME is known to have lost input focus.

Only graphical frames report focus.  A terminal frame answers nil
whether or not the reader is looking at it, so it counts as focused and
window selection alone decides what has been read."
  (or (not (display-graphic-p frame))
      (not (null (frame-focus-state frame)))))

(defun agent-shell-vertico-sidebar--session-focused-p (buffer)
  "Return non-nil when the reader is looking at session BUFFER.

Being on screen is not the same as being read.  A session in a window
the reader has not selected, or on a frame Emacs has lost focus in,
holds output nobody has seen yet.  The viewport counts as its session:
readers who set `agent-shell-prefer-viewport-interaction' never display
the shell buffer itself, and for them every finished turn would
otherwise be unread."
  (let* ((window (selected-window))
         (shown (window-buffer window)))
    (and (agent-shell-vertico-sidebar--frame-focused-p (window-frame window))
         (or (eq shown buffer)
             (eq shown (agent-shell-vertico-sidebar--viewport-buffer
                        buffer))))))

(defun agent-shell-vertico-sidebar--session-for-buffer (buffer)
  "Return the session BUFFER belongs to, or nil.

A session buffer stands for itself; a viewport stands for the session it
shows."
  (when (buffer-live-p buffer)
    (if (with-current-buffer buffer (derived-mode-p 'agent-shell-mode))
        buffer
      (seq-find (lambda (session)
                  (eq buffer
                      (agent-shell-vertico-sidebar--viewport-buffer session)))
                (seq-filter #'buffer-live-p (agent-shell-buffers))))))

(defun agent-shell-vertico-sidebar--mark-seen (buffer)
  "Mark unread output in BUFFER as seen.

Reading settles what the session has said, not what it is waiting for:
a blocked session still needs its permission decision afterwards, and a
failed one is still failed."
  (when (gethash buffer agent-shell-vertico-sidebar--unread)
    (remhash buffer agent-shell-vertico-sidebar--unread)
    (agent-shell-vertico-sidebar--schedule-refresh)))

(defun agent-shell-vertico-sidebar--mark-selected-seen (frame-or-window)
  "Mark the session shown in FRAME-OR-WINDOW as seen and current.

A window stands for itself, a frame for its selected window, and nil for
the current buffer.  A viewport counts as the session it shows."
  (let ((buffer (cond ((window-live-p frame-or-window)
                       (window-buffer frame-or-window))
                      ((frame-live-p frame-or-window)
                       (window-buffer
                        (frame-selected-window frame-or-window)))
                      (t (current-buffer)))))
    (when-let ((session (and (buffer-live-p buffer)
                             (agent-shell-vertico-sidebar--session-for-buffer
                              buffer))))
      (agent-shell-vertico-sidebar--mark-seen session)
      (unless (eq session agent-shell-vertico-sidebar--current-session)
        (setq agent-shell-vertico-sidebar--current-session session)
        (agent-shell-vertico-sidebar--schedule-refresh)))))

(defun agent-shell-vertico-sidebar--window-selection-change
    (&optional frame-or-window)
  "Mark a session seen when its window, or its viewport's, is selected.

Emacs passes the frame whose selected window changed, because this runs
from the default value of `window-selection-change-functions'.  Reading
the current buffer instead would clear the mark of whichever session
happens to be current, which is the wrong session once a second frame is
involved."
  (agent-shell-vertico-sidebar--mark-selected-seen frame-or-window))

(defun agent-shell-vertico-sidebar--focus-change ()
  "Mark the session in a refocused graphical frame as seen.

A turn that finishes while Emacs has no input focus stays unread, so
returning to a frame is the moment its selected session has been read.
No window is selected then, so `window-selection-change-functions' does
not run for it.  Terminal frames do not report a useful focus state, so
their selected windows are handled only by
`window-selection-change-functions'."
  (dolist (frame (frame-list))
    (when (and (frame-live-p frame)
               (display-graphic-p frame)
               (eq (frame-focus-state frame) t))
      (agent-shell-vertico-sidebar--mark-selected-seen frame))))

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

(defun agent-shell-vertico-sidebar--row-start (node-positions)
  "Return the first position of the row point sits in, using NODE-POSITIONS.

Context and detail lines carry their session's node, so a row is left from
its own first line however deep in it point started."
  (or (cdr (or (assoc (agent-shell-vertico-sidebar--point-node)
                      node-positions)
               (agent-shell-vertico-sidebar--preceding-node-entry
                (line-beginning-position) node-positions)))
      (line-beginning-position)))

(defun agent-shell-vertico-sidebar--move-to-row (backward)
  "Move point to the row after the current one, or BACKWARD of it.

Every project header and every session is a stop, and the current row's own
context and detail lines are not, so each key lands on one row's first line
and the two directions undo each other.  Point does not move at the ends of
the list."
  (let* ((node-positions (agent-shell-vertico-sidebar--node-positions))
         (start (agent-shell-vertico-sidebar--row-start node-positions))
         (rows (mapcar #'cdr node-positions))
         (position (seq-find (if backward
                                 (lambda (position) (< position start))
                               (lambda (position) (> position start)))
                             (if backward (reverse rows) rows))))
    (unless position
      (user-error "No %s row in the agent-shell sidebar"
                  (if backward "previous" "next")))
    (goto-char position)))

(defun agent-shell-vertico-sidebar-next-row ()
  "Move point to the first line of the next session or project row."
  (interactive)
  (agent-shell-vertico-sidebar--move-to-row nil))

(defun agent-shell-vertico-sidebar-previous-row ()
  "Move point to the first line of the previous session or project row."
  (interactive)
  (agent-shell-vertico-sidebar--move-to-row t))

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
    ('agent (agent-shell-vertico-sidebar-new-with-agent))
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

(defun agent-shell-vertico-sidebar-new-with-agent ()
  "Start a session with the agent of the session at point.

The new session shares the selected session's project and agent
configuration, so it runs alongside it rather than replacing it."
  (interactive)
  (let* ((buffer (agent-shell-vertico-sidebar--session-at-point))
         (config (map-elt (agent-shell-vertico--state buffer) :agent-config)))
    (unless config
      (user-error "Session %s has no agent configuration" (buffer-name buffer)))
    (agent-shell--new-shell
     :location (agent-shell-vertico-sidebar--project-root buffer)
     :config config)
    (agent-shell-vertico-sidebar-refresh)))

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

(defun agent-shell-vertico-sidebar--view-level ()
  "Return the fold level the whole sidebar currently shows.

`projects' shows project headers only, `sessions' adds their session rows,
and `details' adds each session's metadata lines.  A flat list has no
project level, so it never returns `projects'."
  (cond
   ((and agent-shell-vertico-sidebar-group-by
         (not (agent-shell-vertico-sidebar--any-project-expanded-p)))
    'projects)
   ((agent-shell-vertico-sidebar--any-session-details-visible-p) 'details)
   (t 'sessions)))

(defun agent-shell-vertico-sidebar--set-view-level (level)
  "Show every row at fold LEVEL, discarding per-row fold overrides."
  (when agent-shell-vertico-sidebar-group-by
    (setq agent-shell-vertico-sidebar-expand-by-default
          (not (eq level 'projects)))
    (when (hash-table-p agent-shell-vertico-sidebar--expanded-projects)
      (clrhash agent-shell-vertico-sidebar--expanded-projects)))
  (setq agent-shell-vertico-sidebar-show-details (eq level 'details))
  (when (hash-table-p agent-shell-vertico-sidebar--expanded-sessions)
    (clrhash agent-shell-vertico-sidebar--expanded-sessions)))

(defun agent-shell-vertico-sidebar-cycle-global-view ()
  "Cycle the whole sidebar to its next fold level.

With project grouping the levels are project headers alone, then their
session rows, then each session's metadata lines, then back to the headers.
A flat list has no project level, so it alternates between hiding and
showing the metadata lines.

Every per-project and per-session fold made with `TAB' is discarded, so the
sidebar reaches the chosen level as a whole.

The fold state and the rendering are both the sidebar buffer's own, so
the whole command runs there however it was called."
  (interactive)
  (let ((sidebar (if (derived-mode-p 'agent-shell-vertico-sidebar-mode)
                     (current-buffer)
                   (or (get-buffer "*Agent Shell Sessions*")
                       (user-error "The agent-shell sidebar is not open")))))
    (with-current-buffer sidebar
      (agent-shell-vertico-sidebar--set-view-level
       (pcase (agent-shell-vertico-sidebar--view-level)
         ('projects 'sessions)
         ('sessions 'details)
         (_ (if agent-shell-vertico-sidebar-group-by 'projects 'sessions))))
      (agent-shell-vertico-sidebar--render))))

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

(defconst agent-shell-vertico-sidebar--status-labels
  '((failed . "failed")
    (blocked . "waiting")
    (busy . "working")
    (ready . "ready")
    (starting . "starting"))
  "Tooltip wording for each status counted in a header.

The marks replace the words, so the wording moves to the tooltip.")

(defun agent-shell-vertico-sidebar--mark-label (mark)
  "Return the tooltip wording for MARK.

Two counts can share a glyph, one unread and one read, so the wording
says which this one is."
  (let ((status (or (alist-get (car mark)
                               agent-shell-vertico-sidebar--status-labels)
                    "unknown")))
    (if (cdr mark)
        (concat status ", unread")
      status)))

(defun agent-shell-vertico-sidebar--header-stat (count mark)
  "Return compact COUNT text for MARK, drawn and named as MARK."
  (when (> count 0)
    (propertize (agent-shell-vertico-sidebar--count-text
                 mark count (agent-shell-vertico-sidebar--mark-face mark))
                'help-echo (agent-shell-vertico-sidebar--mark-label mark))))

(defun agent-shell-vertico-sidebar--header-line-for (marks)
  "Return the header line counting MARKS, one segment per occupied mark.

A colon separates the total from the marks it breaks down into; the
marks themselves are separated by the lighter middle dot.  A status with
both read and unread sessions is counted twice, since read and unread
are what the reader is looking for."
  (let ((total (propertize
                (agent-shell-vertico-sidebar--count-text
                 'sessions (length marks))
                'help-echo "sessions"))
        parts)
    (dolist (entry (agent-shell-vertico-sidebar--mark-counts marks))
      (pcase-let ((`(,mark . ,count) entry))
        (when-let ((text (agent-shell-vertico-sidebar--header-stat
                          count mark)))
          (push text parts))))
    (concat " " total
            (when parts
              (concat " : " (string-join (nreverse parts) " · "))))))

(defun agent-shell-vertico-sidebar--header-line-from-snapshots (snapshots)
  "Return a cached header string for SNAPSHOTS."
  (agent-shell-vertico-sidebar--header-line-for
   (mapcar (lambda (snapshot) (plist-get snapshot :mark)) snapshots)))

(defun agent-shell-vertico-sidebar--header-line ()
  "Return the sidebar header with live session statistics."
  (agent-shell-vertico-sidebar--header-line-for
   (mapcar #'agent-shell-vertico-sidebar--mark
           (seq-filter #'buffer-live-p (agent-shell-buffers)))))

(defconst agent-shell-vertico-sidebar--help-buffer
  "*Agent Shell Sidebar Help*"
  "Buffer used by `agent-shell-vertico-sidebar-help'.")

(defun agent-shell-vertico-sidebar--help-text ()
  "Return the key reference shown by `agent-shell-vertico-sidebar-help'."
  (concat
   "Agent Shell Sidebar\n"
   "===================\n\n"
   "Navigation\n"
   "  j / k       Move down or up one line\n"
   "  C-j / C-k   Move to the next or previous row\n"
   "  RET         Activate the row or metadata field\n"
   "  mouse-1     Activate at the clicked position\n"
   "  TAB         Toggle a project or current session details\n"
   "  S-TAB       Cycle all rows: projects, sessions, details\n\n"
   "Actions\n"
   "  o / O       Open here / open in another window\n"
   "  =           Toggle flat or project-grouped view\n"
   "  s           Choose the sort criterion\n"
   "  g (gr)      Refresh (regular / Evil state)\n"
   "  c           Create a new session\n"
   "  m / M       Set mode / model\n"
   "  t / T       Traffic / transcript (regular); reverse in Evil\n"
   "  k / r / i   Kill / restart / interrupt (regular state)\n"
   "  u / !       Mark the session unread again / read\n"
   "  D / R / I   Kill / restart / interrupt (Evil state)\n"
   "  q           Close the sidebar\n\n"
   "Metadata values are individually clickable.  Project values open their\n"
   "working directory; model and mode values open their selectors; agent\n"
   "values start a new session with that agent.\n"
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
    (define-key map (kbd "u") #'agent-shell-vertico-sidebar-mark-unread)
    (define-key map (kbd "!") #'agent-shell-vertico-sidebar-mark-read)
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
    (define-key map (kbd "C-j") #'agent-shell-vertico-sidebar-next-row)
    (define-key map (kbd "C-k") #'agent-shell-vertico-sidebar-previous-row)
    (define-key map (kbd "TAB") #'agent-shell-vertico-sidebar-toggle-at-point)
    (define-key map (kbd "<tab>") #'agent-shell-vertico-sidebar-toggle-at-point)
    (define-key map (kbd "S-TAB")
                #'agent-shell-vertico-sidebar-cycle-global-view)
    (define-key map (kbd "<backtab>")
                #'agent-shell-vertico-sidebar-cycle-global-view)
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
    (define-key map (kbd "u") #'agent-shell-vertico-sidebar-mark-unread)
    (define-key map (kbd "!") #'agent-shell-vertico-sidebar-mark-read)
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
    ("C-j" . agent-shell-vertico-sidebar-next-row)
    ("C-k" . agent-shell-vertico-sidebar-previous-row)
    ("RET" . agent-shell-vertico-sidebar-activate)
    ("<return>" . agent-shell-vertico-sidebar-activate)
    ("TAB" . agent-shell-vertico-sidebar-toggle-at-point)
    ("<tab>" . agent-shell-vertico-sidebar-toggle-at-point)
    ("<mouse-1>" . agent-shell-vertico-sidebar-activate)
    ("o" . agent-shell-vertico-sidebar-open)
    ("O" . agent-shell-vertico-sidebar-open-other-window)
    ("S-TAB" . agent-shell-vertico-sidebar-cycle-global-view)
    ("<backtab>" . agent-shell-vertico-sidebar-cycle-global-view)
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
    ("u" . agent-shell-vertico-sidebar-mark-unread)
    ("!" . agent-shell-vertico-sidebar-mark-read)
    ("?" . agent-shell-vertico-sidebar-help)
    ("q" . quit-window))
  "Dired-style direct bindings for Evil sidebar states.

The explicit `j'/`k' entries keep vertical navigation intact, and `C-j'/`C-k'
move a whole row at a time; `D'/`R'/`I' are the destructive session
actions so navigation and lowercase mnemonics remain available.  Refresh is
`gr', and the other mnemonic actions intentionally take precedence over
their generic Evil commands in this read-only sidebar.")

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
                     "i" "m" "M" "t" "T" "u" "!" "?" "q"))
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
  (local-set-key (kbd "S-TAB")
                 #'agent-shell-vertico-sidebar-cycle-global-view)
  (local-set-key (kbd "<backtab>")
                 #'agent-shell-vertico-sidebar-cycle-global-view)
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
                    (window-width . ,(agent-shell-vertico-sidebar--clamp-width
                                      agent-shell-vertico-sidebar-width
                                      (frame-width)))
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

(defun agent-shell-vertico-sidebar--attention-sessions ()
  "Return live sessions needing attention, the most pressing first.

The order is the sidebar's own `priority' order, whose attention tier
runs oldest first, so the head of this list is the session that has
been waiting longest."
  (seq-filter #'agent-shell-vertico-sidebar--needs-attention-p
              (agent-shell-vertico-sidebar--sort-buffers
               (seq-filter #'buffer-live-p (agent-shell-buffers))
               'priority)))

(defun agent-shell-vertico-sidebar--no-attention-message ()
  "Return what to report when no session needs attention.

Counting the sessions still working separates a quiet moment in a busy
run from nothing running at all."
  (let ((working (aref (agent-shell-vertico-sidebar--session-statistics) 1)))
    (if (> working 0)
        (format "No session needs attention, %d working" working)
      "No session needs attention")))

(defun agent-shell-vertico-sidebar--attention-target ()
  "Return the session the attention marking commands act on.

In the sidebar the row at point names the session.  Anywhere else the
current buffer does, which is a session buffer or a viewport showing
one, so the command works from the session the reader walked into."
  (if (derived-mode-p 'agent-shell-vertico-sidebar-mode)
      (agent-shell-vertico-sidebar--session-at-point)
    (or (agent-shell-vertico-sidebar--session-for-buffer (current-buffer))
        (user-error "No agent-shell session here"))))

;;;###autoload
(defun agent-shell-vertico-sidebar-mark-unread ()
  "Mark the session at point, or the current session, as unread.

Displaying a session counts as reading it, so opening one by mistake
drops the mark that said its output was still owed to the reader.  This
puts that mark back: the session returns to the head of the sidebar's
`priority' order, and `agent-shell-vertico-sidebar-jump' visits it
again.

The mark carries the session's last activity time rather than now, so
the attention tier still runs oldest first and a session marked by hand
does not jump ahead of one that has waited longer.

A working session is refused, because nothing has finished for the
reader to have missed, and the turn marks itself unread when it
completes away from the reader.

Leave the session after marking it.  The mark is cleared again as soon
as the reader is seen looking at the session, which includes staying in
it until Emacs regains input focus."
  (interactive)
  (let* ((buffer (agent-shell-vertico-sidebar--attention-target))
         (status (agent-shell-vertico-sidebar--raw-status buffer)))
    (cond
     ((eq status 'busy)
      (user-error "Session %s is still working" (buffer-name buffer)))
     ((agent-shell-vertico-sidebar--unread-p buffer)
      (message "Session %s is already unread" (buffer-name buffer)))
     (t
      (agent-shell-vertico-sidebar--mark-unread-at
       buffer (or (gethash buffer agent-shell-vertico-sidebar--activity)
                  (float-time)))
      (agent-shell-vertico-sidebar-refresh)
      (message "Session %s marked unread" (buffer-name buffer))))))

;;;###autoload
(defun agent-shell-vertico-sidebar-mark-read ()
  "Mark the session at point, or the current session, as read.

The sidebar clears the unread mark when it sees the reader looking at
the session, which means visiting a session is otherwise the only way to
stop it being listed first.  This drops the mark without visiting: a
failure already dealt with elsewhere, or a finished turn read in the
sidebar itself, stops holding the head of the `priority' order and
`agent-shell-vertico-sidebar-jump' moves on to the next session.

Only the unread mark goes.  A session waiting for a permission decision
keeps its place through its status, which no command can mark away, and
a failed session stays failed until a new turn starts.

New output marks the session again, which includes a turn that finishes
after this and a background stream that goes quiet after this."
  (interactive)
  (let ((buffer (agent-shell-vertico-sidebar--attention-target)))
    (if (not (agent-shell-vertico-sidebar--unread-p buffer))
        (message "Session %s has nothing unread" (buffer-name buffer))
      (remhash buffer agent-shell-vertico-sidebar--unread)
      (agent-shell-vertico-sidebar-refresh)
      (message "Session %s marked read" (buffer-name buffer)))))

;;;###autoload
(defun agent-shell-vertico-sidebar-jump (&optional read)
  "Jump to the session most in need of attention.

A session needs attention when it finished a turn nobody has read, asked
for a permission decision, or failed.  The one waiting longest wins,
which is the session the sidebar lists first under `priority' sorting.

With prefix argument READ, choose the session instead.  Reading covers
every live session, not only the ones needing attention."
  (interactive "P")
  (if read
      (agent-shell-vertico--display-session
       (agent-shell-vertico--read-session "Agent shell: " 'all))
    (if-let* ((buffer (car (agent-shell-vertico-sidebar--attention-sessions))))
        (progn
          ;; Visiting reads whatever the session had to say.  A
          ;; permission decision is still owed afterwards, and the
          ;; blocked status keeps the session in place for it.
          (agent-shell-vertico-sidebar--mark-seen buffer)
          (agent-shell-vertico--display-session (buffer-name buffer)))
      (message "%s" (agent-shell-vertico-sidebar--no-attention-message)))))

;;;###autoload
(defun agent-shell-vertico-sidebar-toggle ()
  "Show or close the compact agent-shell session sidebar.
Show it without selecting its window, or close it when it is visible."
  (interactive)
  (let* ((buffer (get-buffer "*Agent Shell Sessions*"))
         (window (and buffer (get-buffer-window buffer))))
    (if (window-live-p window)
        (delete-window window)
      (save-selected-window
        (agent-shell-vertico-sidebar--display-buffer)))))

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
(add-function :after after-focus-change-function
              #'agent-shell-vertico-sidebar--focus-change)
(add-hook 'window-size-change-functions
          #'agent-shell-vertico-sidebar--window-size-change)
(add-hook 'window-configuration-change-hook
          #'agent-shell-vertico-sidebar--window-configuration-change)

(provide 'agent-shell-vertico-sidebar)

;;; agent-shell-vertico-sidebar.el ends here
