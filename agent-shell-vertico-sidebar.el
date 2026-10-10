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
(require 'ansi-color)
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
(declare-function agent-shell-side-parent-buffer "agent-shell-side"
                  (&optional buffer))
(declare-function agent-shell-side-children "agent-shell-side"
                  (&optional parent-buffer))
(declare-function evil-local-set-key "evil" (state key def))
(declare-function evil-get-auxiliary-keymap "evil"
                  (map state &optional create ignore-parent))
(declare-function evil-next-line "evil" ())
(declare-function evil-previous-line "evil" ())
(declare-function dired-other-window "dired" (dirname))
(declare-function agent-shell-subagents "agent-shell-subagents" ())
(declare-function agent-shell-insert "agent-shell" (&rest args))
(declare-function agent-shell--stop-reason-description "agent-shell"
                  (stop-reason))

;; Bound by agent-shell around the dispatch of a subagent's notification,
;; which is when its event subscribers run.  No value, see CLAUDE.md.
(defvar agent-shell--subagent-group)

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

With `agent-shell-vertico-sidebar-wrap-titles', titles up to this limit
can wrap over multiple sidebar lines."
  :type 'integer
  :group 'agent-shell-vertico-sidebar)

(defcustom agent-shell-vertico-sidebar-wrap-titles nil
  "Whether a long session title wraps over several lines.

Nil keeps every title on one line and cuts it with an ellipsis, as
Claude Code's agent view does, so each row has the same height."
  :type 'boolean
  :group 'agent-shell-vertico-sidebar)

(defcustom agent-shell-vertico-sidebar-stuck-after 900
  "Seconds a working session can go silent before its age turns yellow.

Claude Code calls such a session stuck: it is working and nothing has
arrived from it for this long."
  :type 'number
  :group 'agent-shell-vertico-sidebar)

(defcustom agent-shell-vertico-sidebar-expand-by-default nil
  "Whether project groups start expanded.

An explicit fold or expand action always overrides this default for the
current sidebar buffer."
  :type 'boolean
  :group 'agent-shell-vertico-sidebar)

(defcustom agent-shell-vertico-sidebar-group-by 'state
  "Grouping used by the agent-shell sidebar.

`state' renders a foldable section for each state: Pinned, Needs you,
Working, Idle and Snoozed, the buckets Claude Code's agent view uses.
`project' renders foldable project headers below a Pinned section.  Nil
renders one flat list."
  :type '(choice (const :tag "State" state)
                 (const :tag "Project" project)
                 (const :tag "Flat" nil))
  :group 'agent-shell-vertico-sidebar)

(defcustom agent-shell-vertico-sidebar-folded-sections '(snoozed)
  "State sections that start folded in the state view.

An explicit fold or unfold of a section overrides this for the current
sidebar buffer."
  :type '(set (const :tag "Pinned" pinned)
              (const :tag "Needs you" attention)
              (const :tag "Working" working)
              (const :tag "Idle" idle)
              (const :tag "Snoozed" snoozed))
  :group 'agent-shell-vertico-sidebar)

(defcustom agent-shell-vertico-sidebar-idle-rows 3
  "How many sessions the Idle section shows before a \"more\" row.

The rest are one `RET' away, on the row that counts them.  Nil shows
every idle session."
  :type '(choice (natnum :tag "Rows") (const :tag "All" nil))
  :group 'agent-shell-vertico-sidebar)

(defcustom agent-shell-vertico-sidebar-sort-by 'priority
  "Sort criterion used by the agent-shell sidebar.

`priority' puts sessions needing attention first, followed by working,
idle, and starting sessions.  Attention and working sessions order
oldest first, so the top of the list is the session that has waited
longest and the one `agent-shell-vertico-sidebar-jump' visits.  Idle
and starting sessions order by their latest activity, newest first, so
a session read or finished recently stays above stale idle ones.
`activity' uses the latest agent event, `recency' uses the last display
time, `status' uses only status, and `name' sorts by session title."
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
and `last-user-message' are left out of the default: the mark's colour and
the detail line already carry the status, and the detail line shows the
prompt while the session works on it."
  :type '(repeat (choice (const :tag "Agent" agent)
                         (const :tag "Status" status)
                         (const :tag "Activity age" activity)
                         (const :tag "Project" project)
                         (const :tag "Model" model)
                         (const :tag "Mode" mode)
                         (const :tag "Last user message" last-user-message)))
  :group 'agent-shell-vertico-sidebar)

(defcustom agent-shell-vertico-sidebar-marker-method 'fringe
  "Where the sidebar draws the marker on a session that is on screen.

`fringe' draws a bar in the window's left fringe, `margin' draws one in
its left display margin, and nil draws nothing.  The two markers differ
only in colour whichever is used: the accent face
`agent-shell-vertico-sidebar-focused-session' for the session being
worked in, `agent-shell-vertico-sidebar-current-session' for the rest.

`fringe' is the default.  Graphical sidebar windows reserve at least
eight pixels for it, including after workspace layout restoration.
Wider left fringes and the right fringe's width are left alone.
A terminal frame has no fringes, so it needs `margin', which spends one
column of the sidebar on the bar.  The choice mirrors
`gptel-highlight-methods', which marks its responses the same way and
for the same reason; unlike that one this is a single method rather than
a set, because there is no face tier here to combine with."
  :type '(choice (const :tag "Left fringe" fringe)
                 (const :tag "Left margin" margin)
                 (const :tag "No marker" nil))
  :group 'agent-shell-vertico-sidebar)

(defcustom agent-shell-vertico-sidebar-animate-busy t
  "Whether a working session's mark spins while it works.

The mark is the only place it spins.  The sidebar's header counts in
words or digits, with no glyph to turn, and a project header's `✻ N'
count keeps the still star: a count is a census of what the sidebar
holds rather than a report on any one session."
  :type 'boolean
  :group 'agent-shell-vertico-sidebar)

(defcustom agent-shell-vertico-sidebar-busy-frames
  '("·" "✢" "✳" "✶" "✻" "✽")
  "The one-column characters a working session's mark cycles through.

The default is Claude Code's own spinner, which grows a dot into the
star every other session is drawn with."
  :type '(repeat string)
  :group 'agent-shell-vertico-sidebar)

(defcustom agent-shell-vertico-sidebar-busy-frame-interval 0.1
  "Seconds between frames of a working session's mark.

The default matches `agent-shell''s own busy indicator, so a session
spins at the same rate here as in its shell."
  :type 'number
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
\"Background\", \"Done\", \"Stopped\", \"New\" or \"Starting\";
`:state', how the work stands in Claude Code's terms, one of `working',
`blocked', `done', `failed' or `stopped'; `:needs', what the session asks of the
reader, such as \"Allow: Run make check\", or nil; `:unread', non-nil
when the session holds output nobody has read; and `:last-message', the
agent's newest message as it arrived, or nil.

Status and unread are separate because they answer different questions:
a finished turn leaves an ordinary `Done' session holding unread
output, and a failed one leaves a `Failed' session that stays failed
after it is read.

Nothing is reported for a session the reader is already looking at, or
for one they have snoozed until it asks something new, and the message
text is passed unshortened, since how to fit it belongs to
whichever channel shows it."
  :type '(choice (const :tag "Do not notify" nil) function)
  :group 'agent-shell-vertico-sidebar)

(defcustom agent-shell-vertico-sidebar-jump-keys
  '(?1 ?2 ?3 ?4 ?5 ?6 ?7 ?8 ?9 ?a ?s ?d ?f ?g ?h ?j ?k ?l)
  "Keys `agent-shell-vertico-sidebar-jump-by-key' offers, top row first.

Digits come first because they read as positions in a list; the home
row takes the rows after the ninth.  A session past the last key gets
no label and is reached through `agent-shell-vertico-switch' instead."
  :type '(repeat character)
  :group 'agent-shell-vertico-sidebar)

(cl-defstruct (agent-shell-vertico-sidebar--session
               (:constructor agent-shell-vertico-sidebar--session-create)
               (:copier nil))
  "What the sidebar knows about one session that agent-shell does not keep.

agent-shell reports what a session is doing now; everything here is what
the sidebar has to remember between events to say more than that.  One
record per session buffer, in `agent-shell-vertico-sidebar--sessions'."
  (unread nil :documentation "\
When the session's unread output arrived, or nil.

Presence is the whole record: a session either holds output nobody has
read or it does not.  The time orders the attention tier oldest first,
so the session that has waited longest is the one
`agent-shell-vertico-sidebar-jump' visits.")
  (error nil :documentation "\
Non-nil when the session's last turn ended in an error.

agent-shell reports what a session is doing, not how its last turn
ended, so a failed session answers `ready' like any other idle one.  The
sidebar remembers the failure until a new turn starts, which is what
makes `failed' a status the reader can see rather than a notification
they had to catch.  The value is the error's message, or t.")
  (snoozed nil :documentation "\
When the reader snoozed the session, or nil.

A snooze is the reader putting a session off, which is neither reading
it nor being done with it, so it is a record of its own beside `unread'
and `error' rather than a value of either.  Presence is the whole
record.  The time orders the snoozed tier oldest first, the way the
attention tier is ordered.")
  (pinned nil :documentation "\
When the reader pinned the session, or nil.

A pinned session sorts above every other and has a section of its own
in the state and project views, until the reader unpins it.  Pin and
snooze cancel each other, since one puts a session first and the other
last.")
  (background-since nil :documentation "\
When the sidebar first saw the session working in the background.

agent-shell stamps when a subagent spawned but not when an async task
did, so the sidebar keeps its own time, from the first status it reads
that says `background'.  It orders the background tier oldest first,
and goes as soon as a status says anything else.")
  (background-at-turn-end nil :documentation "\
Non-nil when the last turn ended with background work still running.

Such a turn usually says only that the work has started, and marks the
session unread; the result comes later, as out-of-turn output that
finds the mark in place and would announce nothing.  Presence says the
next burst to settle once the work has ended is that result, so
`agent-shell-vertico-sidebar--out-of-turn-settled' announces it.")
  (state nil :documentation "\
How the session's last turn ended, in Claude Code's words.

`working' from a prompt until its turn ends, then `done', `failed',
`stopped' (the reader cancelled it) or `blocked' (it ended asking a
question).  Nil when the sidebar has seen no turn, which reads as
`done' because nothing says the session was never prompted.  This is
what the turn left behind; what the session does now comes from
agent-shell, and `agent-shell-vertico-sidebar--raw-status' puts the
two together.")
  (needs nil :documentation "\
The question a turn ended on, from its `needs input:' line.")
  (waiting-since nil :documentation "\
When the permission request the session waits on arrived, or nil.

A waiting session's age is how long it has waited, and `unread' cannot
say that: reading the request drops the mark while the session still
waits.  Each request restamps it, since the newest one is what the
session waits on.  A new prompt or the end of a turn clears it, so a
turn that ends asking a question ages from its end instead.")
  (result nil :documentation "\
The headline of the message a turn ended on.

Its `result:' line when it has one, as Claude Code reads it, and its
last non-empty line otherwise.")
  (stop-reason nil :documentation "\
The ACP stop reason the last turn ended with, such as \"end_turn\".")
  (fresh nil :documentation "\
Non-nil when the sidebar saw the session start and nobody has prompted it.

Only a session seen before it had an ACP session can be known to be
unprompted; one already running when the sidebar first saw it may have
any history, and a restored one has some.")
  (created-at nil :documentation "\
When the sidebar first saw the session.")
  (first-terminal-at nil :documentation "\
When a turn of the session first ended.  Set once.")
  (last-terminal-at nil :documentation "\
When the session's latest turn ended.")
  (updated-at nil :documentation "\
When the latest agent event arrived.")
  (busy-since nil :documentation "\
When the session's current busy turn started.")
  (out-of-turn nil :documentation "\
The out-of-turn burst streaming into the session.

An agent can stream output with no turn in flight: background tasks such
as subagents continue after the turn ended, and a prompt steered in too
late makes the agent start a turn of its own.  Neither is reported busy
and neither ends with `turn-complete', so the burst is tracked here.

A plist with `:timer', the timer that ends the burst after a quiet
period, and `:time', when the burst's latest update arrived.")
  (detail nil :documentation "\
The newest entry in the session's transcript, as Claude Code's tail.

A string, \"> \" before the prompt the reader submitted or \"✗ \" before
a tool call that failed, or the symbol `message' when the newest entry
is the agent's message, whose last line is read at render time from
`message'.")
  (message nil :documentation "\
The newest agent message streamed into the session.

A plist with `:chunks', the message text in reverse arrival order, and
`:open', whether the next chunk continues that message or starts a new
one."))

(defvar agent-shell-vertico-sidebar--sessions (make-hash-table :test #'eq)
  "Session buffer to its `agent-shell-vertico-sidebar--session' record.")

(defun agent-shell-vertico-sidebar--record (buffer)
  "Return BUFFER's session record, creating it on first use."
  (or (gethash buffer agent-shell-vertico-sidebar--sessions)
      (puthash buffer (agent-shell-vertico-sidebar--session-create)
               agent-shell-vertico-sidebar--sessions)))

(defun agent-shell-vertico-sidebar--get (buffer slot)
  "Return SLOT of BUFFER's session record, or nil when it has none."
  (when-let* ((record (gethash buffer agent-shell-vertico-sidebar--sessions)))
    (cl-struct-slot-value 'agent-shell-vertico-sidebar--session slot record)))

(defun agent-shell-vertico-sidebar--set (buffer slot value)
  "Set SLOT of BUFFER's session record to VALUE, and return VALUE.

Clearing a slot of a session with no record creates none, so the paths
that tidy up after a killed buffer leave nothing behind."
  (when-let* ((record (if value
                         (agent-shell-vertico-sidebar--record buffer)
                       (gethash buffer agent-shell-vertico-sidebar--sessions))))
    (setf (cl-struct-slot-value 'agent-shell-vertico-sidebar--session slot
                                record)
          value))
  value)

(defun agent-shell-vertico-sidebar--forget (buffer)
  "Drop everything the sidebar recorded about BUFFER."
  (remhash buffer agent-shell-vertico-sidebar--sessions))

(defvar agent-shell-vertico-sidebar--subscriptions (make-hash-table :test #'eq)
  "Buffer to its agent-shell event subscription token.")

(defcustom agent-shell-vertico-sidebar-jump-dispatch-alist
  '((?o agent-shell-vertico-sidebar--jump-display-other-window
        "open in another window")
    (?x agent-shell-vertico-kill-session "kill")
    (?r agent-shell-vertico-restart-session "restart")
    (?i agent-shell-vertico-interrupt-session "interrupt")
    (?m agent-shell-vertico-set-session-mode "set mode")
    (?M agent-shell-vertico-set-session-model "set model")
    (?t agent-shell-vertico-open-transcript "open transcript")
    (?T agent-shell-vertico-view-traffic "view traffic")
    (?u agent-shell-vertico-sidebar--jump-mark-unread "mark unread")
    (?! agent-shell-vertico-sidebar--jump-mark-read "mark read")
    (?z agent-shell-vertico-sidebar--jump-snooze "snooze or wake")
    (?S agent-shell-vertico-sidebar--jump-subagents "list subagents"))
  "Actions a jump can take on a session instead of displaying it.

`agent-shell-vertico-sidebar-jump-by-key' offers these the way
`ace-window' offers `aw-dispatch-alist'.

Each entry is (KEY FUNCTION DESCRIPTION).  Pressing KEY during a jump
leaves the keys drawn and waits for a session key; FUNCTION is then
called with that session's buffer, once the sidebar is back as it was.
DESCRIPTION names the action in the prompt and in the list `?' shows,
and reads after \"Session to\", so word it as a verb.

A session key wins over an action key, so an action whose key is also
in `agent-shell-vertico-sidebar-jump-keys' can never be reached.  `?'
is reserved for the list itself."
  :type '(repeat (list (character :tag "Key")
                       (function :tag "Function")
                       (string :tag "Description")))
  :group 'agent-shell-vertico-sidebar)

(defcustom agent-shell-vertico-sidebar-jump-dim-others t
  "Whether a jump dims what it is not asking the reader to read.

That is the other windows of the frame, so the sidebar is what stands
out while the question is open, and any session row that carries no
key, because such a row is not one of the answers.

The sidebar's own rows keep their contrast.  `ace-window' dims every
window because a window is chosen by where it is; a session is chosen
by reading its title and project, so dimming the list would take away
what the reader is looking at."
  :type 'boolean
  :group 'agent-shell-vertico-sidebar)

(defvar agent-shell-vertico-sidebar--jump-in-progress nil
  "Non-nil while `agent-shell-vertico-sidebar-jump-by-key' reads a key.

A render erases the buffer, which would take the key labels with it, so
`agent-shell-vertico-sidebar--render' only marks the sidebar dirty while
this is set.  The jump renders again once its key is read.")

(defvar-local agent-shell-vertico-sidebar--rendered-current-sessions nil
  "Sessions whose rows the most recent render marked as current.

A cache of what is drawn, never the answer itself: that comes from
`agent-shell-vertico-sidebar--current-sessions' each time.  The selection
hooks compare the two to decide whether the markers need a redraw.")

(defvar-local agent-shell-vertico-sidebar--rendered-focused-session nil
  "Session whose row the most recent render marked as focused.

The same kind of cache as
`agent-shell-vertico-sidebar--rendered-current-sessions', for the second
of the two marker tiers.  The set of sessions on screen can stay the
same while the reader moves between two of them, so this is compared
separately.")

(defvar-local agent-shell-vertico-sidebar--refresh-timer nil
  "Pending idle sidebar refresh timer.")

(defvar-local agent-shell-vertico-sidebar--age-refresh-timer nil
  "Timer that keeps visible activity ages current.")

(defvar-local agent-shell-vertico-sidebar--resize-timer nil
  "Pending idle sidebar resize timer.")

(defvar-local agent-shell-vertico-sidebar--busy-timer nil
  "Repeating timer drawing the next frame of every working mark.")

(defvar-local agent-shell-vertico-sidebar--background-timer nil
  "Repeating timer checking whether background work has changed.")

(defvar-local agent-shell-vertico-sidebar--rendered-background nil
  "What the last render drew as running in each session's background.
See `agent-shell-vertico-sidebar--background-signature'.")

(defconst agent-shell-vertico-sidebar--background-poll-seconds 2
  "Seconds between two checks of the sessions' background work.")

(defvar-local agent-shell-vertico-sidebar--busy-tick 0
  "Which frame the working marks are showing.

One counter for the whole sidebar, so every working mark spins in step.
A session's own phase would have to come from `agent-shell''s heartbeat,
which is its business and not something to read a frame number out of.")

(defvar-local agent-shell-vertico-sidebar--busy-overlays nil
  "Overlays the animation redraws, one per working session's mark.")

(defvar-local agent-shell-vertico-sidebar--dirty nil
  "Non-nil when an event changed the sidebar's rendered state.")

(defvar-local agent-shell-vertico-sidebar--last-rendered-width nil
  "Body width used by the most recent sidebar render.")

(defvar-local agent-shell-vertico-sidebar--render-snapshots nil
  "Buffer-to-snapshot table used during one sidebar render.")

(defvar-local agent-shell-vertico-sidebar--expanded-projects nil
  "Hash table of expanded project roots in the current sidebar buffer.")

(defvar-local agent-shell-vertico-sidebar--section-folds nil
  "Hash table of state sections folded or unfolded in this sidebar.

An absent entry follows `agent-shell-vertico-sidebar-folded-sections'.")

(defvar-local agent-shell-vertico-sidebar--open-tails nil
  "State sections whose rows past the limit this sidebar shows.")

(defvar-local agent-shell-vertico-sidebar--expanded-sessions nil
  "Hash table of session detail overrides in the current sidebar buffer.

An absent entry follows `agent-shell-vertico-sidebar-show-details'.")

(defface agent-shell-vertico-sidebar-project
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for project headers."
  :group 'agent-shell-vertico-sidebar)

(defface agent-shell-vertico-sidebar-section
  '((t :inherit agent-shell-vertico-sidebar-project))
  "Face for state section headers in the agent-shell sidebar."
  :group 'agent-shell-vertico-sidebar)

(defface agent-shell-vertico-sidebar-failed
  '((t :inherit error))
  "Face for the mark of a session whose last turn failed."
  :group 'agent-shell-vertico-sidebar)

(defface agent-shell-vertico-sidebar-blocked
  '((t :inherit warning))
  "Face for a session waiting for the reader.

A permission request still waiting for its answer, or a turn that ended
asking for input."
  :group 'agent-shell-vertico-sidebar)

(defface agent-shell-vertico-sidebar-unread-title
  '((t :inherit bold))
  "Face for the title of a session holding output nobody has read."
  :group 'agent-shell-vertico-sidebar)

(defface agent-shell-vertico-sidebar-snoozed
  '((t :inherit link-visited :underline nil :weight normal))
  "Face for the mark of a session the reader has snoozed.

Every other colour on a mark names a state, and grey is already a
session stopped or not yet prompted, so a snooze takes the one hue
left: the purple a visited link is drawn in, without the link's
underline or weight."
  :group 'agent-shell-vertico-sidebar)

(defface agent-shell-vertico-sidebar-snoozed-title
  '((t :inherit shadow))
  "Face for the title of a session the reader has snoozed.

The row recedes so the sessions still asking for the reader stand out."
  :group 'agent-shell-vertico-sidebar)

(defface agent-shell-vertico-sidebar-snoozed-rule
  '((t :inherit shadow))
  "Face whose colour draws the rule over the first snoozed session.

Only the foreground is read: it becomes the colour of the overline
`agent-shell-vertico-sidebar--insert-sessions' draws, which would
otherwise take each glyph's own colour and change hue along the row."
  :group 'agent-shell-vertico-sidebar)

(defface agent-shell-vertico-sidebar-working
  '((t :inherit ansi-color-blue :background "unspecified-bg"))
  "Face for a working session, or one with work behind a prompt."
  :group 'agent-shell-vertico-sidebar)

(defface agent-shell-vertico-sidebar-ready
  '((t :inherit success))
  "Face for sessions whose last turn finished."
  :group 'agent-shell-vertico-sidebar)

(defface agent-shell-vertico-sidebar-detail
  '((t :inherit shadow))
  "Face for secondary session details."
  :group 'agent-shell-vertico-sidebar)

(defface agent-shell-vertico-sidebar-current-session
  '((t :inherit shadow :height reset))
  "Face for the marker on a session the reader can see.

The weaker of the two markers: this session is on the frame, beside
whatever the reader is working in.  Grey rather than a colour, because
every colour in this sidebar already names a state, blue working, yellow
waiting, red failed, green done, purple snoozed, and a marker that
borrowed one would say something untrue about the session.  `shadow' is
already what this package uses for what is present and not the answer."
  :group 'agent-shell-vertico-sidebar)

(defface agent-shell-vertico-sidebar-focused-session
  '((t :inherit outline-1 :height reset))
  "Face for the marker on the session the reader is working in.

The same question as `agent-shell-vertico-sidebar-current-session'
answered with more force, so it is the same marker in the one accent
that carries no status meaning, rather than a second hue: a different
hue would read as a different kind of fact rather than as more of the
same one.  Colour carries the whole distinction, as it does between
`gptel-response-fringe-highlight' and the `shadow' gptel marks a tool
call with: one bar, two colours.  An earlier version drew this tier on
a thicker bar as well, on the grounds that a bar a pixel or two wide
cannot be relied on to carry a hue difference; a four-pixel bar turned
out to read as a block beside its neighbours rather than as more of the
same mark, which is the fault the second hue was avoided for."
  :group 'agent-shell-vertico-sidebar)

(defface agent-shell-vertico-sidebar-jump-help-key
  '((t :inherit font-lock-builtin-face))
  "Face for a key in the action list a jump shows on `?'.

The label drawn on a row is a highlighted background, which suits one
character standing in for a mark but would be heavy repeated down a
list.  The list colours its keys instead, the way `aw-key-face' does
for `ace-window'."
  :group 'agent-shell-vertico-sidebar)

(defface agent-shell-vertico-sidebar-jump-key
  '((t :inherit (bold error default)))
  "Face for the key drawn over a session's mark while a jump is read.

A coloured character rather than a block of colour, which is how
`ace-window' draws `aw-leading-char-face', and red for the same reason
it is: nothing else in the mark column is red once the rows that carry
no key are dimmed, since a failed session's red star is the character
the key replaces, so red there means a key and only a key.  The
action list keeps its own colour, as `aw-key-face' does, because in the
echo area there is nothing to be confused with.

`default' is inherited last to hand back the ordinary background: the
key is drawn in the frame's own font, at its own size, and coloured
rather than highlighted."
  :group 'agent-shell-vertico-sidebar)

(defface agent-shell-vertico-sidebar-jump-dimmed
  '((t :inherit shadow))
  "Face for what a jump dims while it reads a key.

The other windows of the frame, and any session row without a key."
  :group 'agent-shell-vertico-sidebar)

;; `gptel-highlight-fringe' itself: a solid two-pixel bar, `center'
;; positioned so it sits on the row without needing the row's exact pixel
;; height and one definition works across fonts and text scales.  One
;; bitmap for both tiers, which differ in colour alone; a wider bar for
;; the focused tier read as a block rather than as the same mark drawn
;; harder.  It is solid because a dashed bar at this width is a column of
;; dots, and `center' clips the bitmap to the line, so the dots' phase
;; differed from one marked row to the next and jittered.
(defconst agent-shell-vertico-sidebar--fringe-bitmap-width 8
  "Pixels of left fringe the session marker bitmap needs.
The width of each row of `agent-shell-vertico-sidebar-session-fringe'.")

(define-fringe-bitmap 'agent-shell-vertico-sidebar-session-fringe
  (make-vector 28 #b01100000)
  nil agent-shell-vertico-sidebar--fringe-bitmap-width 'center)

(defconst agent-shell-vertico-sidebar--margin-bar "▎"
  "The bar a margin marker draws, LEFT ONE QUARTER BLOCK (U+258E).

The character `gptel-highlight--margin-prefix' draws by default, picked
from the several bars its own comment lists.  It fills a quarter of the
cell, so a margin marker reads as the fringe bar drawn in a column of
text rather than as a block of colour; a font without it falls back to
whatever Emacs finds, which is why the character is a constant to
rebind rather than something spelled inline.")

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

(defun agent-shell-vertico-sidebar--permission-pending-p (buffer)
  "Return non-nil when BUFFER is waiting on a permission decision.

`agent-shell-status' calls a session blocked only while a turn is also in
flight, so a request from a background task that outlived its turn is
reported as ready.  agent-shell's own question is asked rather than
repeated here, so the sidebar and the shell cannot disagree about what is
pending."
  (and (fboundp 'agent-shell--permission-pending-p)
       (condition-case nil
           (agent-shell--permission-pending-p :shell-buffer buffer)
         (error nil))
       t))

(defun agent-shell-vertico-sidebar--parent-of (buffer)
  "Return BUFFER's live parent session, or nil.

Nil whenever `agent-shell-side' is not loaded, which makes nesting a
silent no-op without it: every session then answers with no parent, so
the whole tree is flat, exactly as before this feature existed."
  (and (fboundp 'agent-shell-side-parent-buffer)
       (agent-shell-side-parent-buffer buffer)))

(defun agent-shell-vertico-sidebar--children-of (buffer)
  "Return BUFFER's live child sessions, or nil.

Nil whenever `agent-shell-side' is not loaded, for the same reason
`--parent-of' is."
  (and (fboundp 'agent-shell-side-children)
       (agent-shell-side-children buffer)))

(defconst agent-shell-vertico-sidebar--async-task-terminal-states
  '("completed" "failed" "stopped")
  "Async task states after which a task no longer runs.
The same list as `agent-shell-subagents--async-task-terminal-states'.")

(defun agent-shell-vertico-sidebar--background-work (buffer)
  "Return BUFFER's running subagents and async tasks as a count cons.

The answer is (SUBAGENTS . TASKS), or nil when neither is running.
agent-shell keeps both in the session's state and emits no event for
either, so this reads the state: a subagent runs until its record gains
`:ended-at', and an async task until its `:state' is terminal.  Both
are agent-shell's internals; a state without them answers nil, which is
a session with nothing in the background."
  (or (agent-shell-vertico-sidebar--snapshot-field buffer :background)
      (let* ((state (agent-shell-vertico--state buffer))
             (subagents
              (seq-count (lambda (entry) (not (map-elt (cdr entry) :ended-at)))
                         (map-elt state :native-subagents)))
             (terminal agent-shell-vertico-sidebar--async-task-terminal-states)
             (tasks
              (seq-count (lambda (entry)
                           (not (member (plist-get (cdr entry) :state)
                                        terminal)))
                         (map-elt state :async-tasks))))
        (unless (and (zerop subagents) (zerop tasks))
          (cons subagents tasks)))))

(defun agent-shell-vertico-sidebar--track-background (buffer status)
  "Record when BUFFER entered the background, given its STATUS.
See the `background-since' slot of `agent-shell-vertico-sidebar--session'."
  (if (eq status 'background)
      (unless (agent-shell-vertico-sidebar--get buffer 'background-since)
        (agent-shell-vertico-sidebar--set buffer 'background-since
                                          (float-time)))
    (agent-shell-vertico-sidebar--set buffer 'background-since nil)))

(defun agent-shell-vertico-sidebar--raw-status (buffer)
  "Return the status symbol the sidebar shows for BUFFER.

The answer is `starting', `new', `busy', `background', `blocked',
`done', `failed' or `stopped', or whatever else agent-shell reports.

agent-shell answers what the session does now, and a live `busy' or
`blocked' means a turn owns the session and wins.  An otherwise idle
session is described by what the sidebar knows and agent-shell does
not, first match first:

- `blocked' while a permission decision waits, which agent-shell calls
  blocked only while a turn is in flight.  It comes first, because a
  burst beside it is work the session does while it waits;
- `busy' during an out-of-turn burst, which no turn asked for;
- `failed' when its last turn failed, until a new turn starts;
- `starting' while it has no ACP session yet;
- `stopped' when the reader cancelled its last turn, and `blocked'
  when that turn ended on a question;
- `new' when the sidebar saw it start and nobody has prompted it;
- `background' with a subagent or an async task still running.  The
  session takes a prompt, which separates it from `busy', but it is not
  done either.  Every running kind counts alike, a dev server with a
  subagent, since a task says nothing about whether it will ever end;
- `done' otherwise: its last turn ended, or nothing says it ran one.

`agent-shell-vertico-sidebar--job-state' gives the same answer in
Claude Code's terms."
  (or (agent-shell-vertico-sidebar--snapshot-field buffer :status)
      (let* ((live (agent-shell-vertico-sidebar--live-status buffer))
             (state (agent-shell-vertico-sidebar--get buffer 'state))
             (status
              (cond
               ((not (eq live 'ready)) live)
               ((agent-shell-vertico-sidebar--permission-pending-p buffer)
                'blocked)
               ((agent-shell-vertico-sidebar--get buffer 'out-of-turn) 'busy)
               ((eq state 'failed) 'failed)
               ((not (agent-shell-vertico--session-field buffer :id))
                'starting)
               ((eq state 'stopped) 'stopped)
               ((eq state 'blocked) 'blocked)
               ((agent-shell-vertico-sidebar--get buffer 'fresh) 'new)
               ((agent-shell-vertico-sidebar--background-work buffer)
                'background)
               (t 'done))))
        (agent-shell-vertico-sidebar--track-background buffer status)
        status)))

(defconst agent-shell-vertico-sidebar--new-needs "Send a prompt to start"
  "What a session nobody has prompted yet is waiting for.")

(defun agent-shell-vertico-sidebar--permission-needs (buffer)
  "Return what BUFFER's pending permission request asks, or nil."
  (when-let* ((call (seq-find (lambda (entry)
                                (map-elt (cdr entry) :permission-request-id))
                              (map-elt (agent-shell-vertico--state buffer)
                                       :tool-calls))))
    (concat "Allow: " (or (map-elt (cdr call) :title) "a tool call"))))

(defun agent-shell-vertico-sidebar--job-state (buffer &optional status)
  "Return (STATE TEMPO NEEDS) for BUFFER, in Claude Code's terms.

STATE is how the work stands: `working', `blocked', `done', `failed' or
`stopped'.  TEMPO is what the session does about it now: `active' while
it works, `blocked' while it waits for the reader, `idle' otherwise.
NEEDS is what the reader is asked for, or nil.  Claude Code keeps these
three fields for every job; here they are read off the status, so the
two can never disagree.  A session nobody has prompted is working and
idle: Claude Code calls it blocked, which would put a shell the reader
has just opened among the sessions waiting for them.

STATUS is BUFFER's `--raw-status' when the caller has already read it."
  (let ((status (or status (agent-shell-vertico-sidebar--raw-status buffer))))
    (pcase status
      ((or 'busy 'starting) (list 'working 'active nil))
      ('background (list 'working 'idle nil))
      ('new (list 'working 'idle agent-shell-vertico-sidebar--new-needs))
      ('blocked
       (list (or (agent-shell-vertico-sidebar--get buffer 'state) 'done)
             'blocked
             (or (agent-shell-vertico-sidebar--permission-needs buffer)
                 (agent-shell-vertico-sidebar--get buffer 'needs))))
      ((or 'done 'failed 'stopped) (list status 'idle nil))
      (_ (list 'working 'idle nil)))))

(defconst agent-shell-vertico-sidebar--sections
  '((pinned . "Pinned") (attention . "Needs you") (working . "Working")
    (idle . "Idle") (snoozed . "Snoozed"))
  "State sections in display order, with their labels.")

(defun agent-shell-vertico-sidebar--band-for (snapshot)
  "Return the band of SNAPSHOT.  The first match wins, as in Claude Code.

Unread output does not change the band: a finished session is idle,
read or not.  A session nobody has prompted is idle too, though it
names what it waits for.  Work behind a prompt, a subagent or a task
still running, is working, as Claude Code files it."
  (let ((tempo (plist-get snapshot :tempo)))
    (cond
     ((and (plist-get snapshot :snoozed) (not (eq tempo 'active))) 'snoozed)
     ((eq tempo 'active) 'working)
     ((eq tempo 'blocked) 'attention)
     ((plist-get snapshot :in-flight) 'working)
     (t 'idle))))

(defun agent-shell-vertico-sidebar--section-for (snapshot)
  "Return the state section SNAPSHOT's own state puts it in.
Its band, unless the reader pinned it.  A root is drawn in its family's
section instead, which `--family-section' answers."
  (if (plist-get snapshot :pinned)
      'pinned
    (plist-get snapshot :band)))

(defun agent-shell-vertico-sidebar--job-fields (buffer status snoozed)
  "Return the job fields of BUFFER in STATUS as a plist.

SNOOZED is the session's snooze time as drawn.  The plist holds
`:state', `:tempo', `:needs', `:in-flight', `:band', `:pinned' and
`:section', the part of a render snapshot that `--band-for' reads."
  (pcase-let* ((`(,state ,tempo ,needs)
                (agent-shell-vertico-sidebar--job-state buffer status))
               (fields (list :state state :tempo tempo :needs needs
                             :in-flight (eq status 'background)))
               (band (agent-shell-vertico-sidebar--band-for
                      (append (list :snoozed snoozed) fields)))
               (pinned (agent-shell-vertico-sidebar--get buffer 'pinned)))
    (append fields
            (list :band band
                  :pinned pinned
                  :section (agent-shell-vertico-sidebar--section-for
                            (list :band band :pinned pinned))))))

(defun agent-shell-vertico-sidebar--job-field (buffer field)
  "Return job FIELD of BUFFER, from the render snapshot when there is one."
  (or (agent-shell-vertico-sidebar--snapshot-field buffer field)
      (let ((status (agent-shell-vertico-sidebar--raw-status buffer)))
        (plist-get (agent-shell-vertico-sidebar--job-fields
                    buffer status
                    (agent-shell-vertico-sidebar--snoozed-for
                     status (agent-shell-vertico-sidebar--get buffer 'snoozed)))
                   field))))

(defun agent-shell-vertico-sidebar--section (buffer)
  "Return the state section BUFFER's own state puts it in.
A root is drawn in its family's section, which `--family-section'
answers."
  (agent-shell-vertico-sidebar--job-field buffer :section))

(defun agent-shell-vertico-sidebar--band (buffer)
  "Return the band BUFFER is counted in, pinned or not."
  (agent-shell-vertico-sidebar--job-field buffer :band))

(defun agent-shell-vertico-sidebar--family (buffer)
  "Return BUFFER and its live descendants, BUFFER first."
  (cons buffer
        (seq-mapcat #'agent-shell-vertico-sidebar--family
                    (agent-shell-vertico-sidebar--children-of buffer))))

(defun agent-shell-vertico-sidebar--family-section (root)
  "Return the state section ROOT and its descendants are drawn in.

A child is drawn under its parent, so the family takes one section: the
Pinned one when ROOT is pinned, and otherwise the earliest in
`--sections' among the bands of ROOT and every live descendant.  A child
waiting on the reader thus draws its idle parent under Needs you, where
the header that counts it says it is."
  (if (eq (agent-shell-vertico-sidebar--section root) 'pinned)
      'pinned
    (let ((bands (mapcar #'agent-shell-vertico-sidebar--band
                         (agent-shell-vertico-sidebar--family root))))
      (seq-find (lambda (section) (memq section bands))
                (mapcar #'car agent-shell-vertico-sidebar--sections)))))

(defun agent-shell-vertico-sidebar--group-by-section (roots)
  "Group ROOTS by the state section of their family, in section order.

Return an alist of each section holding a root and its roots, which
keep the order they had in ROOTS."
  (let ((groups (seq-group-by #'agent-shell-vertico-sidebar--family-section
                              roots)))
    (seq-keep (pcase-lambda (`(,section . ,_))
                (when-let* ((members (alist-get section groups)))
                  (cons section members)))
              agent-shell-vertico-sidebar--sections)))

(defun agent-shell-vertico-sidebar--unread-for (status time)
  "Return TIME when a session in STATUS owes the reader that output.

A working session owes nothing yet: whatever it produced is superseded
by what it is producing now, and the turn or the burst will report
itself when it ends.  The record is only deferred, never dropped, so the
mark comes back with its own age once the session goes quiet.  This is
what `agent-shell-vertico-sidebar-mark-unread' says for the mark a
reader sets by hand, said once for every way a mark is set."
  (unless (eq status 'busy)
    time))

(defun agent-shell-vertico-sidebar--unread-time (buffer)
  "Return when BUFFER's unread output arrived, or nil when it has none."
  (or (agent-shell-vertico-sidebar--snapshot-field buffer :unread)
      (agent-shell-vertico-sidebar--unread-for
       (agent-shell-vertico-sidebar--raw-status buffer)
       (agent-shell-vertico-sidebar--get buffer 'unread))))

(defun agent-shell-vertico-sidebar--unread-p (buffer)
  "Return non-nil when BUFFER holds output nobody has read."
  (and (agent-shell-vertico-sidebar--unread-time buffer) t))

(defun agent-shell-vertico-sidebar--mark-unread-at (buffer time)
  "Record that BUFFER holds output nobody has read, arriving at TIME."
  (agent-shell-vertico-sidebar--set buffer 'unread time))

(defun agent-shell-vertico-sidebar--snoozed-for (status time)
  "Return TIME when a session in STATUS is drawn and ranked as snoozed.

A working session is working, snoozed or not: a burst streaming into a
snoozed session is drawn and ranked with the other working ones, and
the snooze is back once it goes quiet.  The record is kept throughout,
as `agent-shell-vertico-sidebar--unread-for' keeps the unread one."
  (unless (eq status 'busy)
    time))

(defun agent-shell-vertico-sidebar--snoozed-time (buffer)
  "Return when BUFFER was snoozed, or nil when it is not snoozed."
  (or (agent-shell-vertico-sidebar--snapshot-field buffer :snoozed)
      (agent-shell-vertico-sidebar--snoozed-for
       (agent-shell-vertico-sidebar--raw-status buffer)
       (agent-shell-vertico-sidebar--get buffer 'snoozed))))

(defun agent-shell-vertico-sidebar--snoozed-p (buffer)
  "Return non-nil when the reader has put BUFFER off."
  (and (agent-shell-vertico-sidebar--snoozed-time buffer) t))

(defun agent-shell-vertico-sidebar--pinned-p (buffer)
  "Return non-nil when the reader has pinned BUFFER."
  (and (or (agent-shell-vertico-sidebar--snapshot-field buffer :pinned)
           (agent-shell-vertico-sidebar--get buffer 'pinned))
       t))

(defun agent-shell-vertico-sidebar--needs-attention-p (buffer)
  "Return non-nil when BUFFER is waiting on the reader.

Two things ask for the reader, and they are asked differently.  Unread
output is recorded, because nothing about a session says whether anyone
has looked at it.  A pending permission decision is not: the session
reports itself blocked for as long as it waits, so reading the status is
the whole answer and no record can go stale.

A working session asks for nobody, whatever it is holding: see
`agent-shell-vertico-sidebar--unread-for'.  Neither does a snoozed one,
because the reader has said when they will come back to it."
  (and (not (agent-shell-vertico-sidebar--snoozed-p buffer))
       (or (agent-shell-vertico-sidebar--unread-p buffer)
           (eq (agent-shell-vertico-sidebar--raw-status buffer) 'blocked))))

(defun agent-shell-vertico-sidebar--status-name (buffer)
  "Return a display status name for BUFFER.

The name says what the session is, never whether anyone has read it:
a finished turn leaves a session `Done'."
  (or (agent-shell-vertico-sidebar--snapshot-field buffer :status-name)
      (agent-shell-vertico-sidebar--status-name-for
       (agent-shell-vertico-sidebar--raw-status buffer))))

(defun agent-shell-vertico-sidebar--status-rank (buffer)
  "Return a status rank for BUFFER.  Lower ranks sort first."
  (or (agent-shell-vertico-sidebar--snapshot-field buffer :status-rank)
      (agent-shell-vertico-sidebar--status-rank-for
       (agent-shell-vertico-sidebar--raw-status buffer)
       (agent-shell-vertico-sidebar--unread-p buffer)
       (agent-shell-vertico-sidebar--snoozed-p buffer))))

(defun agent-shell-vertico-sidebar--status-sort-rank (buffer)
  "Return the raw status rank for BUFFER.  Lower ranks sort first.

Unlike `agent-shell-vertico-sidebar--status-rank', this deliberately
ignores attention metadata; attention is the concern of `priority'."
  (or (agent-shell-vertico-sidebar--snapshot-field buffer :raw-status-rank)
      (agent-shell-vertico-sidebar--status-sort-rank-for
       (agent-shell-vertico-sidebar--raw-status buffer))))

(defun agent-shell-vertico-sidebar--status-rank-for (status unread
                                                         &optional snoozed)
  "Return the priority rank for STATUS, given UNREAD and SNOOZED.

The attention tier is two ranks, not one, because its two halves ask
for the reader differently.  Unread output ranks first: arriving is
what settles it.  A blocked session the reader has already seen ranks
below it, because the decision is owed wherever the reader stands and
reading the session again does not make it; ranking the two together
by age pinned every jump to the blocked session, whose wait always
began before any turn that has finished since.

A session in the background ranks just below the working ones: it is
working too, though it takes a prompt, and it asks for nobody.

A snoozed session has its own rank, whatever it holds, so the snoozed
sessions run as one queue.  Where the queue sits is not the rank's
business: `agent-shell-vertico-sidebar--compare-buffers' puts every
snoozed session after every other one, whatever the sort.  SNOOZED is the
answer of `agent-shell-vertico-sidebar--snoozed-for', which is already
nil for a working session, so a burst ranks as work.

A session nobody is waiting on ranks by what it is doing.  A failed one
that has been read ranks last with the sessions that can do nothing:
it has already said all it has to say."
  (cond
   (snoozed 4)
   (unread 0)
   ((eq status 'blocked) 1)
   ((eq status 'busy) 2)
   ((eq status 'background) 3)
   ((memq status '(done stopped new)) 5)
   (t 6)))

(defun agent-shell-vertico-sidebar--oldest-first-rank-p (rank)
  "Return non-nil when priority orders the tier at RANK oldest first.

The tiers that are waiting on something — the two attention ranks, the
working and background ones and the snoozed one — lead with whoever has
been waiting longest, which is what makes the sidebar's first session
the one a jump visits and the snoozed tier a queue.  The tiers that are
waiting on nobody lead with whoever was read or finished most recently."
  (<= rank 4))

(defconst agent-shell-vertico-sidebar--statistics-slots [0 0 1 5 4 2 3]
  "Which statistic each status rank is counted in.

The jump reports these when nothing needs attention.  The statistics
keep one attention count, so both attention ranks land in the same
slot.  The snoozed and background counts come last, in the
order they were added, so the slots that were there before them kept
their places.  See
`agent-shell-vertico-sidebar--status-rank-for' for the ranks and
`agent-shell-vertico-sidebar--session-statistics' for the slots.")

(defun agent-shell-vertico-sidebar--status-sort-rank-for (status)
  "Return the raw status rank for STATUS."
  (pcase status
    ('blocked 0)
    ('failed 1)
    ('busy 2)
    ('background 3)
    ((or 'done 'stopped) 4)
    ((or 'new 'starting) 5)
    (_ 6)))

(defun agent-shell-vertico-sidebar--status-name-for (status)
  "Return a display status name for STATUS."
  (pcase status
    ('blocked "Waiting")
    ('failed "Failed")
    ('busy "Working")
    ('background "Background")
    ('done "Done")
    ('stopped "Stopped")
    ('new "New")
    ('starting "Starting")
    (_ "Unknown")))

(defun agent-shell-vertico-sidebar--live-p (buffer)
  "Return nil when BUFFER's agent process has started and is gone.

A session with no client yet, or a client not started yet, is live:
only a process that ran and stopped says the agent is gone."
  (let* ((client (map-elt (agent-shell-vertico--state buffer) :client))
         (process (and client (map-elt client :process))))
    (or (null process) (process-live-p process))))

(defun agent-shell-vertico-sidebar--session-snapshot (buffer)
  "Return one render snapshot for live session BUFFER.

The snapshot deliberately reads the live status once.  Sorting, grouping,
header statistics, and row rendering consume the resulting plist instead of
repeating those queries during one redisplay."
  (let* ((status (agent-shell-vertico-sidebar--raw-status buffer))
         (activity-time (agent-shell-vertico-sidebar--activity-time buffer))
         (unread (agent-shell-vertico-sidebar--unread-for
                  status (agent-shell-vertico-sidebar--get buffer 'unread)))
         (snoozed (agent-shell-vertico-sidebar--snoozed-for
                   status (agent-shell-vertico-sidebar--get buffer 'snoozed)))
         (busy-since-time
          (if (eq status 'busy)
              (or (agent-shell-vertico-sidebar--get buffer 'busy-since)
                  (agent-shell-vertico-sidebar--set buffer 'busy-since
                                                    (float-time)))
            (agent-shell-vertico-sidebar--set buffer 'busy-since nil)
            nil))
         (background (agent-shell-vertico-sidebar--background-work buffer))
         (root (agent-shell-vertico-sidebar--project-root buffer))
         (project-name
          (agent-shell-vertico-sidebar--project-name-from-buffer buffer root))
         (recency-time (or (when-let ((time (buffer-local-value
                                             'buffer-display-time buffer)))
                             (float-time time))
                           0.0)))
    (append
     (list :buffer buffer
           :root root
           :project-name project-name
           :title (agent-shell-vertico-sidebar--title buffer)
           :status status
           :status-name
           (agent-shell-vertico-sidebar--status-name-for status)
           :status-rank (agent-shell-vertico-sidebar--status-rank-for
                         status (and unread t) (and snoozed t))
           :live (agent-shell-vertico-sidebar--live-p buffer)
           :raw-status-rank
           (agent-shell-vertico-sidebar--status-sort-rank-for status)
           :unread unread
           :snoozed snoozed
           :activity-time activity-time
           :busy-since-time busy-since-time
           :background background
           :background-since
           (agent-shell-vertico-sidebar--get buffer 'background-since)
           :recency-time recency-time
           :model (agent-shell-vertico--model-name buffer)
           :mode (agent-shell-vertico--mode-name buffer)
           :agent (agent-shell-vertico--agent-name buffer)
           :details-visible
           (agent-shell-vertico-sidebar--session-details-expanded-p buffer))
     (list :detail (agent-shell-vertico-sidebar--detail-text buffer)
           :result (agent-shell-vertico-sidebar--get buffer 'result)
           :error (agent-shell-vertico-sidebar--get buffer 'error)
           :updated-at (agent-shell-vertico-sidebar--get buffer 'updated-at)
           :created-at (agent-shell-vertico-sidebar--get buffer 'created-at)
           :last-terminal-at
           (agent-shell-vertico-sidebar--get buffer 'last-terminal-at)
           :waiting-since
           (agent-shell-vertico-sidebar--get buffer 'waiting-since))
     (agent-shell-vertico-sidebar--job-fields buffer status snoozed))))

(defun agent-shell-vertico-sidebar--detail-for (snapshot)
  "Return the one-line detail for SNAPSHOT, as Claude Code picks it.

A waiting session says what it waits for and a working one its newest
entry.  A failure says why, and a stopped turn only that it stopped.
Otherwise the turn's `result:' line, else its newest entry; a session
nobody has prompted says what it needs."
  (pcase-let (((map :state :tempo :needs :detail :result :error) snapshot))
    (cond ((eq tempo 'blocked) needs)
          ((eq tempo 'active) detail)
          ((eq state 'failed)
           (if (stringp error) (concat "Failed: " error) "Failed"))
          ((eq state 'stopped) "Stopped")
          (t (or needs result detail)))))

(defun agent-shell-vertico-sidebar--state-since (snapshot)
  "Return when the session in SNAPSHOT entered its band, or nil."
  (pcase-let (((map :band :snoozed :unread :busy-since-time
                    :background-since :last-terminal-at :created-at
                    :waiting-since)
               snapshot))
    (pcase band
      ('snoozed snoozed)
      ('attention (or waiting-since unread last-terminal-at created-at))
      ('working (or busy-since-time background-since created-at))
      (_ (or last-terminal-at created-at)))))

(defun agent-shell-vertico-sidebar--stuck-p (snapshot)
  "Return non-nil when SNAPSHOT works and has been silent too long."
  (and (eq (plist-get snapshot :tempo) 'active)
       (when-let* ((updated (plist-get snapshot :updated-at)))
         (>= (- (float-time) updated)
             agent-shell-vertico-sidebar-stuck-after))))

(defun agent-shell-vertico-sidebar--age-text (snapshot)
  "Return how long SNAPSHOT has been in its band, drawn, or nil."
  (when-let* ((since (agent-shell-vertico-sidebar--state-since snapshot))
              (text (agent-shell-vertico-sidebar--relative-time since)))
    (propertize text 'face (if (agent-shell-vertico-sidebar--stuck-p snapshot)
                               'agent-shell-vertico-sidebar-blocked
                             'agent-shell-vertico-sidebar-detail))))

(defun agent-shell-vertico-sidebar--detail-line (snapshot width)
  "Return the detail line of SNAPSHOT at WIDTH, or nil.

The state view names the state in its section header, so the line is
the detail alone there.  The project and flat views start it with the
status word, drawn in the mark's colour, as Claude Code's directory
mode does."
  (let* ((detail (agent-shell-vertico-sidebar--detail-for snapshot))
         (detail (and detail
                      (propertize detail
                                  'face 'agent-shell-vertico-sidebar-detail)))
         (line (if (eq agent-shell-vertico-sidebar-group-by 'state)
                   detail
                 (concat (propertize
                          (agent-shell-vertico-sidebar--status-name-for
                           (plist-get snapshot :status))
                          'face (agent-shell-vertico-sidebar--mark-face
                                 snapshot))
                         (and detail
                              (propertize
                               " · " 'face 'agent-shell-vertico-sidebar-detail))
                         detail))))
    (when line
      (cons (agent-shell-vertico-sidebar--fit line width) t))))

(defun agent-shell-vertico-sidebar--snapshot-field (buffer field)
  "Return FIELD from BUFFER's current render snapshot, when available."
  (when-let ((snapshot
              (and (hash-table-p agent-shell-vertico-sidebar--render-snapshots)
                   (gethash buffer agent-shell-vertico-sidebar--render-snapshots))))
    (plist-get snapshot field)))

(defun agent-shell-vertico-sidebar--activity-time (buffer)
  "Return latest observed activity time for BUFFER."
  (or (agent-shell-vertico-sidebar--snapshot-field buffer :activity-time)
      (agent-shell-vertico-sidebar--get buffer 'updated-at)
      (when-let ((time (buffer-local-value 'buffer-display-time buffer)))
        (float-time time))
      0.0))

(defun agent-shell-vertico-sidebar--priority-time (buffer)
  "Return the timestamp used to order BUFFER by priority.

Unread timestamps order sessions waiting for user action.  Working
sessions use the time their current turn entered the busy state; streamed
activity is deliberately not a priority tie-breaker.  Every other session
uses its latest activity, so one read or finished recently stays above
stale idle sessions instead of dropping to its alphabetical slot.  A
session in the background uses the time it was first seen there.  A
snoozed session uses the time it was snoozed, whatever it holds, since
that is the order the reader put the sessions off in."
  (or (agent-shell-vertico-sidebar--snoozed-time buffer)
      (agent-shell-vertico-sidebar--unread-time buffer)
      (agent-shell-vertico-sidebar--snapshot-field buffer :busy-since-time)
      (agent-shell-vertico-sidebar--get buffer 'busy-since)
      (when (eq (agent-shell-vertico-sidebar--raw-status buffer) 'busy)
        (agent-shell-vertico-sidebar--set buffer 'busy-since (float-time)))
      (agent-shell-vertico-sidebar--snapshot-field buffer :background-since)
      (agent-shell-vertico-sidebar--get buffer 'background-since)
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
                    (concat (agent-shell-vertico-sidebar--mark-field
                             (agent-shell-vertico-sidebar--slot-icon 'message))
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
            (concat (agent-shell-vertico-sidebar--mark-field
                     (agent-shell-vertico-sidebar--slot-icon 'project))
                    (agent-shell-vertico-sidebar--project-name root buffer))
            width)
           root)
          'agent-shell-vertico-sidebar-detail)))

(defun agent-shell-vertico-sidebar--background-line (buffer width)
  "Return the line saying what runs in BUFFER's background, at WIDTH.

It is drawn whenever something runs, details shown or not, because the
mark alone, a blue star that does not spin, cannot say what the session
is waiting on.  Each kind gets its own icon, so a subagent reads apart
from a shell at a glance."
  (when-let* ((work (agent-shell-vertico-sidebar--background-work buffer)))
    (let (parts)
      (pcase-dolist (`(,slot ,count ,noun)
                     `((subagents ,(car work) "subagent")
                       (tasks ,(cdr work) "task")))
        (when (> count 0)
          (let ((icon (agent-shell-vertico-sidebar--slot-icon slot)))
            (push (concat (if parts
                              (concat icon
                                      " ")
                            (agent-shell-vertico-sidebar--mark-field icon))
                          (format "%d %s%s" count noun (if (= count 1) "" "s")))
                  parts))))
      (cons (agent-shell-vertico-sidebar--fit
             (string-join (nreverse parts) " · ") width)
            'agent-shell-vertico-sidebar-detail))))

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

(defconst agent-shell-vertico-sidebar--icons
  '((project   . "⌂")
    (message   . "↳")
    (subagents . "◇")
    (tasks     . "$")
    (expanded  . "▼")
    (collapsed . "▶"))
  "Slot and character for each mark that is not a session's.

The fold triangles match the ones `agent-shell' uses for its own
collapsible fragments.")

(defun agent-shell-vertico-sidebar--slot-icon (slot &optional face)
  "Return the mark for SLOT, drawn in FACE."
  (let ((text (alist-get slot agent-shell-vertico-sidebar--icons)))
    (if face (propertize text 'face face) text)))

(defun agent-shell-vertico-sidebar--busy-frame (tick &optional face)
  "Return what a working mark shows on TICK, drawn in FACE."
  (let* ((frames agent-shell-vertico-sidebar-busy-frames)
         (text (nth (mod tick (length frames)) frames)))
    (if face (propertize text 'face face) text)))

(defun agent-shell-vertico-sidebar--count-text (glyph count face)
  "Return COUNT preceded by GLYPH, both drawn in FACE."
  (propertize (format "%s %d" glyph count) 'face face))

(defun agent-shell-vertico-sidebar--content-width (width depth)
  "Return the columns left for text on a session row of WIDTH.

DEPTH is how many levels the row is indented: 1 below a project header
or a parent session, 2 below both."
  (max 1 (- width (* 2 (or depth 0)) 2)))

(defun agent-shell-vertico-sidebar--mark-glyph (snapshot)
  "Return Claude Code's glyph for the session in SNAPSHOT.

Every session is the same star, and its face gives its state.  A
working star is turned by the spinner overlay; without the spin it is
a disc instead, so a working session still has a shape of its own.  A
session whose agent process is gone is a dot."
  (cond ((not (plist-get snapshot :live)) "∙")
        ((and (eq (plist-get snapshot :tempo) 'active)
              (not agent-shell-vertico-sidebar-animate-busy))
         "●")
        (t "✻")))

(defun agent-shell-vertico-sidebar--mark-face (snapshot)
  "Return the face of the mark of SNAPSHOT, by Claude Code's colour table.

Purple is what the reader has put off, yellow what waits for the
reader, blue what works, red a failure and green a finished turn.  A
stopped session and one nobody has prompted are grey.  Unread output
does not colour the mark: it makes the title bold."
  (pcase-let (((map :state :tempo :snoozed :in-flight) snapshot))
    (cond (snoozed 'agent-shell-vertico-sidebar-snoozed)
          ((eq tempo 'blocked) 'agent-shell-vertico-sidebar-blocked)
          ((or (eq tempo 'active) in-flight)
           'agent-shell-vertico-sidebar-working)
          ((eq state 'failed) 'agent-shell-vertico-sidebar-failed)
          ((eq state 'done) 'agent-shell-vertico-sidebar-ready)
          (t 'agent-shell-vertico-sidebar-detail))))

(defun agent-shell-vertico-sidebar--snapshot (buffer)
  "Return BUFFER's render snapshot, or a fresh one outside a render."
  (or (and (hash-table-p agent-shell-vertico-sidebar--render-snapshots)
           (gethash buffer agent-shell-vertico-sidebar--render-snapshots))
      (agent-shell-vertico-sidebar--session-snapshot buffer)))

(defun agent-shell-vertico-sidebar--icon (buffer)
  "Return the mark for BUFFER, drawn in its own face."
  (let ((snapshot (agent-shell-vertico-sidebar--snapshot buffer)))
    (propertize (agent-shell-vertico-sidebar--mark-glyph snapshot)
                'face (agent-shell-vertico-sidebar--mark-face snapshot))))

(defun agent-shell-vertico-sidebar--compare-buffers (left right sort-by)
  "Return non-nil when LEFT sorts before RIGHT by SORT-BY.

Under `priority' the tiers waiting on something order oldest first, so
the sidebar's first session is the one
`agent-shell-vertico-sidebar-jump' visits; the remaining tiers order
newest first so a session that was read or finished recently stays near
the top of its tier.  See
`agent-shell-vertico-sidebar--oldest-first-rank-p' for which is which.

Whatever SORT-BY is, a pinned session sorts before every session that
is not, and a snoozed one after every session that is not, and each
party keeps SORT-BY's order among itself: the reader has put the pinned
ones first and said the snoozed ones can wait."
  (let* ((left-pinned (agent-shell-vertico-sidebar--pinned-p left))
         (right-pinned (agent-shell-vertico-sidebar--pinned-p right))
         (left-snoozed (agent-shell-vertico-sidebar--snoozed-p left))
         (right-snoozed (agent-shell-vertico-sidebar--snoozed-p right))
         (left-title (agent-shell-vertico-sidebar--title left))
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
     ((not (eq left-pinned right-pinned)) left-pinned)
     ((not (eq left-snoozed right-snoozed)) right-snoozed)
     ((eq sort-by 'name)
      (agent-shell-vertico-sidebar--text-lessp left-title right-title))
     ((and (eq sort-by 'status) (/= left-rank right-rank))
      (< left-rank right-rank))
     ((and (eq sort-by 'priority) (/= left-rank right-rank))
      (< left-rank right-rank))
     ((and (eq sort-by 'priority) (/= left-time right-time))
      ;; Ranks are equal here, so LEFT's rank picks the tier's direction.
      (if (agent-shell-vertico-sidebar--oldest-first-rank-p left-rank)
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
        (goto-char (agent-shell-vertico-sidebar--row-point position)))
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
        (set-window-point window
                          (agent-shell-vertico-sidebar--row-point
                           position))))))

(defun agent-shell-vertico-sidebar--mark-field-p (position)
  "Return non-nil when POSITION is inside the icon a line begins with."
  (and (< position (point-max))
       (get-text-property position
                          'agent-shell-vertico-sidebar-mark-field)))

(defun agent-shell-vertico-sidebar--row-point (position)
  "Return where point rests on the line that POSITION is on.

Past the icon the line begins with, if it has one, and POSITION itself
otherwise.  Always forward, never back to the line above: a reader
moving up a list would otherwise be carried past the row they moved
to."
  (if (agent-shell-vertico-sidebar--mark-field-p position)
      (or (next-single-property-change
           position 'agent-shell-vertico-sidebar-mark-field nil
           (save-excursion (goto-char position) (line-end-position)))
          position)
    position))

(defun agent-shell-vertico-sidebar--keep-point-off-marks (window)
  "Move WINDOW's point past the icon its line begins with.

Run from `pre-redisplay-functions', so it answers for every way point
arrives on an icon, including the ones no command of this package took:
a click, an arrow key, or a window layout restored by a workspace
package.

`cursor-intangible-mode' is what this would otherwise be, and was:
`cursor-sensor-tangible-pos' compares point against a window parameter
that `cursor-sensor-move-to-tangible' sets only after a run that did not
signal, and `window-state-put' does not carry that parameter, so a
window restored with point on an icon signalled on every redisplay and
never set it.  Errors are demoted here for the same reason: a mistake in
this function must not be able to fill the echo area on every
redisplay."
  (with-demoted-errors "agent-shell-vertico-sidebar: %S"
    (when (window-live-p window)
      (let* ((position (window-point window))
             (moved (agent-shell-vertico-sidebar--row-point position)))
        (unless (eq moved position)
          (set-window-point window moved)
          (when (eq window (selected-window))
            (goto-char moved)))))))

(defun agent-shell-vertico-sidebar--mark-field (icon)
  "Return ICON and the gap after it as one field point is kept out of.

Standing on an icon says nothing, and the sidebar has no visible cursor
to say where point is, so point is moved on to the text.  Every leading
icon is one of these - a status mark, a fold triangle, the home of a
project line, the arrow of a message line - and the gap belongs to the
field because it is as empty an answer as the icon.  `propertize' leaves
the half-width display the gap carries alone.

`agent-shell-vertico-sidebar--keep-point-off-marks' is what acts on the
property; nothing else reads it."
  (propertize (concat icon " ")
              'agent-shell-vertico-sidebar-mark-field t))

(defun agent-shell-vertico-sidebar--session-lines
    (buffer root width &optional nested depth)
  "Return rendered session lines for BUFFER at WIDTH under ROOT.

NESTED suppresses the row's own flat project-context line, for a
session already named by a project header above it.  DEPTH is the
indent level and defaults to 1 when NESTED, 0 otherwise; a child
session passes a DEPTH one deeper than its parent's, independently of
NESTED, since the header that NESTED refers to says nothing about a
parent-child relationship."
  (let* ((depth (or depth (if nested 1 0)))
         (content-width
          (agent-shell-vertico-sidebar--content-width width depth))
         (snapshot (agent-shell-vertico-sidebar--snapshot buffer))
         (title (agent-shell-vertico-sidebar--title buffer))
         (icon (agent-shell-vertico-sidebar--icon buffer))
         (age (agent-shell-vertico-sidebar--age-text snapshot))
         (title-width (if age
                          (max 1 (- content-width (string-width age) 1))
                        content-width))
         (details-visible
          (agent-shell-vertico-sidebar--session-details-expanded-p buffer))
         (title-text (agent-shell-vertico-sidebar--title-display-text title))
         (title-lines
          (if agent-shell-vertico-sidebar-wrap-titles
              (agent-shell-vertico-sidebar--wrap-text title-text title-width)
            (list (agent-shell-vertico-sidebar--fit title-text title-width))))
         (detail-line
          (agent-shell-vertico-sidebar--detail-line snapshot content-width))
         (project-line
          (when (not nested)
            (agent-shell-vertico-sidebar--flat-project-line
             buffer root content-width)))
         (detail-lines
          (when details-visible
            (agent-shell-vertico-sidebar--extra-info-lines
             buffer root content-width (not nested)))))
    (dolist (face (list (and (agent-shell-vertico-sidebar--unread-p buffer)
                             'agent-shell-vertico-sidebar-unread-title)
                        (and (agent-shell-vertico-sidebar--snoozed-p buffer)
                             'agent-shell-vertico-sidebar-snoozed-title)))
      (when face
        ;; Prepended, so it wins over whatever face the title carries.
        (dolist (line title-lines)
          (add-face-text-property 0 (length line) face nil line))))
    (setq title-lines
          (cons (concat (agent-shell-vertico-sidebar--mark-field icon)
                        (car title-lines)
                        (when age
                          (concat (make-string
                                   (max 1 (- content-width
                                             (string-width (car title-lines))
                                             (string-width age)))
                                   ?\s)
                                  age)))
                (cdr title-lines)))
    (append (mapcar (lambda (line) (cons line nil)) title-lines)
            (when detail-line (list detail-line))
            (when project-line (list project-line))
            (when-let* ((line (agent-shell-vertico-sidebar--background-line
                               buffer content-width)))
              (list line))
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

(defun agent-shell-vertico-sidebar--current-session-marker (&optional focused)
  "Return a marker for a current session's row, or nil when none is drawn.

FOCUSED asks for the marker of the session the reader is working in, the
bar in the accent colour; every other session on the frame gets the grey
one.  The bar is the same either way, because colour is what separates
the two tiers.

`agent-shell-vertico-sidebar-marker-method' says where it is drawn.  The
marker is a `display' spec on one space in both cases, so it costs no
columns of the text area: Emacs draws the fringe bitmap, or the margin
bar, in place of the space.  That is the idiom `gptel-highlight-mode'
uses for both of its own methods."
  (let ((face (if focused
                  'agent-shell-vertico-sidebar-focused-session
                'agent-shell-vertico-sidebar-current-session)))
    (pcase agent-shell-vertico-sidebar-marker-method
      ('fringe
       (propertize " " 'display
                   `(left-fringe agent-shell-vertico-sidebar-session-fringe
                                 ,face)))
      ('margin
       (propertize " " 'display
                   `((margin left-margin)
                     ,(propertize agent-shell-vertico-sidebar--margin-bar
                                  'face face))))
      (_ nil))))

(defun agent-shell-vertico-sidebar--marker-fringes (fringes &optional reset)
  "Return the `set-window-fringes' arguments a fringe marker needs, or nil.
FRINGES is what `window-fringes' answered for the window.  Only a left
fringe narrower than the marker bitmap is widened; the right fringe and
the other two settings are kept.  RESET non-nil means re-showing the
buffer has just reset the window's fringes, so FRINGES are written back
even when wide enough."
  (let ((left (car fringes))
        (bitmap agent-shell-vertico-sidebar--fringe-bitmap-width))
    (when (or reset (< left bitmap))
      (cons (max bitmap left) (cdr fringes)))))

(defun agent-shell-vertico-sidebar--apply-marker-space ()
  "Reserve the display space the sidebar's marker method needs.
Return non-nil when a margin or fringe width changed.

A window reads `left-margin-width' when the buffer is put there, so a
margin change reaches an existing window by re-showing the buffer.
Doing nothing when the width already agrees keeps that out of ordinary
renders: re-showing resets what the render is careful to restore.

A fringe marker needs the bitmap's width in every graphical window
showing the sidebar.  A restored layout can carry a zero-width
fringe even when the frame's default is wide enough.  Repair only a
narrow left fringe, keeping the right fringe's width and the rest;
`set-window-fringes' leaves point and the window's start alone."
  (let* ((width (if (eq agent-shell-vertico-sidebar-marker-method 'margin)
                    1
                  0))
         (margin-changed (not (eql left-margin-width width)))
         (fringe-p (eq agent-shell-vertico-sidebar-marker-method 'fringe))
         (changed margin-changed))
    (when margin-changed
      (setq-local left-margin-width width))
    (when (or margin-changed fringe-p)
      (dolist (window (get-buffer-window-list nil nil t))
        ;; Re-showing for a margin change can reset non-persistent fringes.
        ;; Read them first so fringe markers retain the custom settings.
        (let ((fringes (and fringe-p
                            (display-graphic-p (window-frame window))
                            (window-fringes window))))
          (when margin-changed
            (set-window-buffer window (current-buffer)))
          (when-let* ((args (and fringes
                                 (agent-shell-vertico-sidebar--marker-fringes
                                  fringes margin-changed))))
            (when (apply #'set-window-fringes window args)
              (setq changed t))))))
    changed))

(defun agent-shell-vertico-sidebar--insert-row (lines kind node &optional depth)
  "Insert session LINES with KIND and NODE text properties.

DEPTH reserves two columns per level, the same two a project header
spends on its fold triangle, so a session icon lines up under whatever
is above it: a project name at depth 1, a parent session's icon at
depth 1 or, nested inside a grouped project, at depth 2.  A flat,
parentless row at depth 0 keeps its status icon at column zero.

Indentation is a `line-prefix' display property rather than inserted
spaces, as `agent-shell' does for its own fragments: the columns are
visual only, so copied rows carry no leading whitespace and point at the
beginning of a line is already on the row's first real character.  The
row of a session the reader can see gets the same treatment for its
fringe or margin marker, prepended to whichever indentation prefix
already applies, so it adds no columns of its own either."
  (let* ((current agent-shell-vertico-sidebar--rendered-current-sessions)
         (focused agent-shell-vertico-sidebar--rendered-focused-session)
         (marker (and (eq kind 'session)
                      (memq node current)
                      (agent-shell-vertico-sidebar--current-session-marker
                       (eq node focused))))
         (start (point))
         (indent (make-string (* 2 (or depth 0)) ?\s))
         (first-prefix (concat marker indent))
         (continuation-prefix (concat marker indent "  "))
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
        ;; A face of t says the line carries its own faces.
        (when (and (cdr line) (not (eq (cdr line) t)))
          ;; Merge rather than set, so the faces a line carries stay.
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

Only the sessions that need the reader are counted, the header's
attention band, and a project with none gets no count at all.  The
other bands are the whole sidebar's header, and every status is on the
session row that has it, so a project header states only what asks for
a reply.  BUFFERS are the roots drawn under the header, and each one's
live descendants are counted too, since they are drawn there as well."
  (let ((count (seq-count (lambda (buffer)
                            (eq (agent-shell-vertico-sidebar--band buffer)
                                'attention))
                          (seq-mapcat #'agent-shell-vertico-sidebar--family
                                      buffers))))
    (when (> count 0)
      (agent-shell-vertico-sidebar--count-text
       "✻" count 'agent-shell-vertico-sidebar-blocked))))

(defun agent-shell-vertico-sidebar--project-header-line
    (indicator name summary width)
  "Return a project header of WIDTH holding INDICATOR, NAME, and SUMMARY.

SUMMARY, when there is one, keeps the right edge of the row, so a NAME too
long for the remaining columns is the part that gets shortened."
  (let* ((reserved (if summary (+ 2 (string-width summary)) 0))
         (name (agent-shell-vertico-sidebar--fit
                name
                (max 1 (- width (string-width indicator) 1 reserved)))))
    (concat indicator " " name
            (when summary
              (concat (make-string
                       (max 2 (- width (string-width indicator) 1
                                 (string-width name) (string-width summary)))
                       ?\s)
                      summary)))))

(defun agent-shell-vertico-sidebar--insert-session-and-children
    (buffer width nested depth)
  "Insert BUFFER's row at WIDTH and DEPTH, then its child sessions.

NESTED says whether BUFFER already sits under a project header, which
`--session-lines' uses to suppress the row's own project-context line;
a child inherits it unchanged, since the same header (or its absence)
speaks for it too.  Each child is inserted one DEPTH deeper and sorted
among its siblings the way `--sort-groups' sorts a project's own
sessions: by `agent-shell-vertico-sidebar-sort-by', scoped to just this
parent, so nesting never reorders the top level."
  (agent-shell-vertico-sidebar--insert-row
   (agent-shell-vertico-sidebar--session-lines
    buffer (agent-shell-vertico-sidebar--project-root buffer)
    width nested depth)
   'session buffer depth)
  (agent-shell-vertico-sidebar--insert-sessions
   (agent-shell-vertico-sidebar--sort-buffers
    (agent-shell-vertico-sidebar--children-of buffer)
    agent-shell-vertico-sidebar-sort-by)
   width nested (1+ depth)))

(defun agent-shell-vertico-sidebar--insert-sessions
    (buffers width nested depth)
  "Insert sorted sibling BUFFERS, with a rule over the first snoozed one.

`agent-shell-vertico-sidebar--compare-buffers' puts the snoozed
siblings last, so the rule is drawn once, where they begin, and only
when some sibling above them is not snoozed.  It is an overline on the
row's first line rather than a line of its own, because a line with no
session on it is one every motion and every count of rows would have
to step over.  The newline carries it too, with `:extend', since rows
are not padded and the rule has to reach the window's edge.  A terminal
draws no overline, so there the split is the order alone."
  (let ((above nil))
    (dolist (buffer buffers)
      (let ((start (point))
            (snoozed (agent-shell-vertico-sidebar--snoozed-p buffer)))
        (agent-shell-vertico-sidebar--insert-session-and-children
         buffer width nested depth)
        (when (and snoozed above (not (eq above 'snoozed)))
          (add-face-text-property
           start (save-excursion (goto-char start) (1+ (line-end-position)))
           `(:overline ,(or (face-foreground
                             'agent-shell-vertico-sidebar-snoozed-rule nil t)
                            t)
                       :extend t)))
        (setq above (if snoozed 'snoozed 'awake))))))

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
    ;; A fold triangle is an icon like any other: point belongs on the
    ;; project name rather than on it.
    (put-text-property start (min (+ start 2) (1- (point)))
                       'agent-shell-vertico-sidebar-mark-field t)
    (add-text-properties
     start (1- (point))
     (list 'agent-shell-vertico-sidebar-node root
           'agent-shell-vertico-sidebar-node-kind 'project
           'mouse-face 'highlight
           'help-echo "TAB/RET/mouse-1: toggle project"
           'kbd-help "TAB/RET/mouse-1: toggle project"))
    (when expanded
      (agent-shell-vertico-sidebar--insert-sessions buffers width t 1))))

(defun agent-shell-vertico-sidebar--split-pinned (buffers)
  "Return (PINNED . REST), BUFFERS split by whether the reader pinned them.
The project view draws the pinned ones under their own header, above
the projects."
  (let (pinned rest)
    (dolist (buffer buffers)
      (if (agent-shell-vertico-sidebar--pinned-p buffer)
          (push buffer pinned)
        (push buffer rest)))
    (cons (nreverse pinned) (nreverse rest))))

(defun agent-shell-vertico-sidebar--section-folded-p (section)
  "Return non-nil when state SECTION hides its rows in this sidebar."
  (let ((unset (make-symbol "unset")))
    (let ((value (if (hash-table-p agent-shell-vertico-sidebar--section-folds)
                     (gethash section
                              agent-shell-vertico-sidebar--section-folds
                              unset)
                   unset)))
      (if (eq value unset)
          (and (memq section agent-shell-vertico-sidebar-folded-sections) t)
        value))))

(defun agent-shell-vertico-sidebar--set-section-folded (section folded)
  "Record in this sidebar that state SECTION is FOLDED or not.
Folding also puts back the limit on the section's rows."
  (unless (hash-table-p agent-shell-vertico-sidebar--section-folds)
    (setq agent-shell-vertico-sidebar--section-folds
          (make-hash-table :test #'eq)))
  (puthash section folded agent-shell-vertico-sidebar--section-folds)
  (when folded
    (setq agent-shell-vertico-sidebar--open-tails
          (delq section agent-shell-vertico-sidebar--open-tails))))

(defun agent-shell-vertico-sidebar--section-limit (section)
  "Return how many root rows state SECTION shows, or nil for all of them."
  (and (eq section 'idle)
       (not (memq section agent-shell-vertico-sidebar--open-tails))
       agent-shell-vertico-sidebar-idle-rows))

(defun agent-shell-vertico-sidebar--family-size (buffer)
  "Return how many rows BUFFER and its live descendants take."
  (length (agent-shell-vertico-sidebar--family buffer)))

(defun agent-shell-vertico-sidebar--insert-node-line (line kind node face)
  "Insert LINE as the one-line node NODE of KIND, drawn in FACE."
  (let ((start (point)))
    (insert line "\n")
    ;; Merged, so an icon keeps the font family in its own face.
    (add-face-text-property start (1- (point)) face)
    (add-text-properties
     start (1- (point))
     (list 'agent-shell-vertico-sidebar-node node
           'agent-shell-vertico-sidebar-node-kind kind
           'mouse-face 'highlight))
    start))

(defun agent-shell-vertico-sidebar--insert-section (section buffers width)
  "Insert the header of state SECTION and, unless folded, its BUFFERS.

An open header shows no count, since its rows are the count; a folded
one says how many sessions it hides, children included.  The Idle
section stops after `agent-shell-vertico-sidebar-idle-rows' top-level
sessions, each drawn with its children, and ends with a row counting
the sessions it hides the same way, which `RET' opens.  One hidden
session is shown instead, since the row counting it would take the
same line."
  (let* ((folded (agent-shell-vertico-sidebar--section-folded-p section))
         (line (agent-shell-vertico-sidebar--project-header-line
                (agent-shell-vertico-sidebar--slot-icon
                 (if folded 'collapsed 'expanded))
                (alist-get section agent-shell-vertico-sidebar--sections)
                (and folded
                     (number-to-string
                      (apply #'+ (mapcar
                                  #'agent-shell-vertico-sidebar--family-size
                                  buffers))))
                width))
         (start (agent-shell-vertico-sidebar--insert-node-line
                 (agent-shell-vertico-sidebar--fit line width)
                 'section section 'agent-shell-vertico-sidebar-section)))
    ;; The fold triangle is a mark: point belongs on the label.
    (put-text-property start (+ start 2)
                       'agent-shell-vertico-sidebar-mark-field t)
    (add-text-properties start (line-end-position 0)
                         (list 'help-echo "TAB/RET/mouse-1: toggle section"
                               'kbd-help "TAB/RET/mouse-1: toggle section"))
    (unless folded
      (let* ((limit (agent-shell-vertico-sidebar--section-limit section))
             (shown (if (and limit (> (length buffers) (1+ limit)))
                        (seq-take buffers limit)
                      buffers))
             (hidden (nthcdr (length shown) buffers)))
        (agent-shell-vertico-sidebar--insert-sessions shown width nil 1)
        (when hidden
          (agent-shell-vertico-sidebar--insert-more
           section
           (apply #'+ (mapcar #'agent-shell-vertico-sidebar--family-size
                              hidden))))))))

(defun agent-shell-vertico-sidebar--insert-more (section count)
  "Insert the row saying state SECTION hides COUNT more sessions."
  (let ((start (agent-shell-vertico-sidebar--insert-node-line
                (format "… %d more" count) 'more section
                'agent-shell-vertico-sidebar-detail)))
    (add-text-properties start (line-end-position 0)
                         (list 'line-prefix "  " 'wrap-prefix "  "
                               'help-echo "RET/mouse-1: show the rest"
                               'kbd-help "RET/mouse-1: show the rest"))))

(cl-defun agent-shell-vertico-sidebar--render ()
  "Render the current sidebar buffer."
  (unless (derived-mode-p 'agent-shell-vertico-sidebar-mode)
    (user-error "The named sidebar buffer is not an agent-shell sidebar"))
  (when agent-shell-vertico-sidebar--jump-in-progress
    ;; The key labels a jump has drawn live on this text.  Leave it, and
    ;; let the jump redraw once its key is read.
    (setq agent-shell-vertico-sidebar--dirty t)
    (cl-return-from agent-shell-vertico-sidebar--render))
  ;; Reserve fringes and margins before measuring `window-body-width':
  ;; neither is part of the text area the rows are laid out to.
  (agent-shell-vertico-sidebar--apply-marker-space)
  (let* ((buffers (seq-filter #'buffer-live-p (agent-shell-buffers)))
         ;; A child with a live parent is inserted under it instead, by
         ;; `--insert-session-and-children'; everything else, including an
         ;; orphan whose parent just died, roots its own place in the sort
         ;; or the grouping below.  `snapshots' still covers every buffer:
         ;; a nested child's own status still needs tracking and drawing.
         (roots (seq-remove #'agent-shell-vertico-sidebar--parent-of buffers))
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
          (agent-shell-vertico-sidebar--cancel-busy-refresh)
          (setq agent-shell-vertico-sidebar--dirty nil
                agent-shell-vertico-sidebar--last-rendered-width width
                agent-shell-vertico-sidebar--rendered-background
                (delq nil
                      (mapcar (lambda (snapshot)
                                (when-let* ((work (plist-get snapshot
                                                             :background)))
                                  (cons (plist-get snapshot :buffer) work)))
                              snapshots))
                agent-shell-vertico-sidebar--rendered-current-sessions
                (and buffers
                     (agent-shell-vertico-sidebar--current-sessions buffers))
                agent-shell-vertico-sidebar--rendered-focused-session
                (and agent-shell-vertico-sidebar--rendered-current-sessions
                     (agent-shell-vertico-sidebar--focused-session
                      agent-shell-vertico-sidebar--rendered-current-sessions
                      buffers))
                header-line-format
                (agent-shell-vertico-sidebar--header-line-for
                 snapshots width))
          (agent-shell-vertico-sidebar--watch-existing buffers nil t)
          (erase-buffer)
          (if (null buffers)
              (insert (propertize "  No agent-shell sessions\n"
                                  'face 'agent-shell-vertico-sidebar-detail))
            (pcase agent-shell-vertico-sidebar-group-by
              ('state
               (pcase-dolist (`(,section . ,members)
                              (agent-shell-vertico-sidebar--group-by-section
                               (agent-shell-vertico-sidebar--sort-buffers
                                roots agent-shell-vertico-sidebar-sort-by)))
                 (agent-shell-vertico-sidebar--insert-section
                  section members width)))
              ('project
               (pcase-let ((`(,pinned . ,rest)
                            (agent-shell-vertico-sidebar--split-pinned roots)))
                 (when pinned
                   (agent-shell-vertico-sidebar--insert-section
                    'pinned
                    (agent-shell-vertico-sidebar--sort-buffers
                     pinned agent-shell-vertico-sidebar-sort-by)
                    width))
                 (dolist (group
                          (agent-shell-vertico-sidebar--sort-groups
                           (agent-shell-vertico-sidebar--group-buffers rest)
                           agent-shell-vertico-sidebar-sort-by))
                   (agent-shell-vertico-sidebar--insert-project
                    (car group) (cdr group) width))))
              (_
               (agent-shell-vertico-sidebar--insert-sessions
                (agent-shell-vertico-sidebar--sort-buffers
                 roots agent-shell-vertico-sidebar-sort-by)
                width nil 0))))
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
             (agent-shell-vertico-sidebar--row-point
              (agent-shell-vertico-sidebar--anchor-position
               point-anchor node-positions)))
            (dolist (anchor window-anchors)
              (agent-shell-vertico-sidebar--restore-window-anchor
               anchor node-positions)))
          (agent-shell-vertico-sidebar--place-busy-overlays snapshots)
          (agent-shell-vertico-sidebar--ensure-busy-refresh)
          (agent-shell-vertico-sidebar--ensure-background-refresh)
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

(defun agent-shell-vertico-sidebar--cancel-busy-refresh ()
  "Cancel the repeating busy-animation timer."
  (when (timerp agent-shell-vertico-sidebar--busy-timer)
    (cancel-timer agent-shell-vertico-sidebar--busy-timer)
    (setq agent-shell-vertico-sidebar--busy-timer nil)))

(defun agent-shell-vertico-sidebar--cancel-background-refresh ()
  "Cancel the repeating background-work check."
  (when (timerp agent-shell-vertico-sidebar--background-timer)
    (cancel-timer agent-shell-vertico-sidebar--background-timer)
    (setq agent-shell-vertico-sidebar--background-timer nil)))

(defun agent-shell-vertico-sidebar--background-signature (buffers)
  "Return an alist of each of BUFFERS with background work to that work."
  (delq nil
        (mapcar (lambda (buffer)
                  (when-let* ((work
                               (agent-shell-vertico-sidebar--background-work
                                buffer)))
                    (cons buffer work)))
                buffers)))

(defun agent-shell-vertico-sidebar--background-poll ()
  "Schedule a render when background work differs from what was drawn.

agent-shell emits no event when a subagent or an async task starts or
ends, and a task can end with nothing said, so the sidebar asks.  Work
starts inside a turn, whose events render the sidebar anyway, which is
why this only runs while something is drawn as running."
  (unless (equal (agent-shell-vertico-sidebar--background-signature
                  (seq-filter #'buffer-live-p (agent-shell-buffers)))
                 agent-shell-vertico-sidebar--rendered-background)
    (agent-shell-vertico-sidebar--schedule-refresh)))

(defun agent-shell-vertico-sidebar--ensure-background-refresh ()
  "Check background work on a timer while some is drawn and on screen."
  (let ((sidebar (or (and (derived-mode-p 'agent-shell-vertico-sidebar-mode)
                          (current-buffer))
                     (get-buffer "*Agent Shell Sessions*"))))
    (when sidebar
      (with-current-buffer sidebar
        (if (and agent-shell-vertico-sidebar--rendered-background
                 (agent-shell-vertico-sidebar--sidebar-visible-p sidebar))
            (unless (timerp agent-shell-vertico-sidebar--background-timer)
              (setq agent-shell-vertico-sidebar--background-timer
                    (run-with-timer
                     agent-shell-vertico-sidebar--background-poll-seconds
                     agent-shell-vertico-sidebar--background-poll-seconds
                     (lambda ()
                       (agent-shell-vertico-sidebar--background-beat
                        sidebar)))))
          (agent-shell-vertico-sidebar--cancel-background-refresh))))))

(defun agent-shell-vertico-sidebar--background-beat (sidebar)
  "Check SIDEBAR's background work, or stop once it is not on screen."
  (when (buffer-live-p sidebar)
    (with-current-buffer sidebar
      (if (agent-shell-vertico-sidebar--sidebar-visible-p sidebar)
          (agent-shell-vertico-sidebar--background-poll)
        (agent-shell-vertico-sidebar--cancel-background-refresh)))))

(defun agent-shell-vertico-sidebar--clear-busy-overlays ()
  "Drop the overlays the busy animation draws on."
  (mapc #'delete-overlay agent-shell-vertico-sidebar--busy-overlays)
  (setq agent-shell-vertico-sidebar--busy-overlays nil))

(defun agent-shell-vertico-sidebar--place-busy-overlays (snapshots)
  "Give each working session in SNAPSHOTS an overlay over its mark.

The row keeps the still glyph underneath, so a sidebar that is never
animated - the setting off, no timer yet, a beat suppressed - reads
exactly as it did before.  The overlay only replaces what is drawn,
which is why nothing reflows and no row has to be built differently."
  (agent-shell-vertico-sidebar--clear-busy-overlays)
  (when agent-shell-vertico-sidebar-animate-busy
    (let ((working (seq-keep (lambda (snapshot)
                               (when (eq (plist-get snapshot :tempo) 'active)
                                 (plist-get snapshot :buffer)))
                             snapshots))
          (face 'agent-shell-vertico-sidebar-working))
      (when working
        (pcase-dolist (`(,buffer . ,start)
                       (agent-shell-vertico-sidebar--session-rows))
          (when (memq buffer working)
            (let* ((value (agent-shell-vertico-sidebar--busy-frame
                           agent-shell-vertico-sidebar--busy-tick face))
                   (limit (save-excursion
                            (goto-char start)
                            (line-end-position)))
                   (overlay (make-overlay start (min limit (1+ start)))))
              (overlay-put overlay 'display value)
              (push overlay agent-shell-vertico-sidebar--busy-overlays))))))))

(defun agent-shell-vertico-sidebar--animate-busy ()
  "Draw the next frame on every working mark.

Returns early while a jump is in progress, as the render does: a jump
draws its keys over the same cells, and repainting under them would
take a key off the screen the reader is choosing from."
  (unless agent-shell-vertico-sidebar--jump-in-progress
    (setq agent-shell-vertico-sidebar--busy-tick
          (1+ agent-shell-vertico-sidebar--busy-tick))
    (let ((value (agent-shell-vertico-sidebar--busy-frame
                  agent-shell-vertico-sidebar--busy-tick
                  'agent-shell-vertico-sidebar-working)))
      (dolist (overlay agent-shell-vertico-sidebar--busy-overlays)
        (when (overlay-buffer overlay)
          (overlay-put overlay 'display value))))))

(defun agent-shell-vertico-sidebar--busy-animation-wanted-p (sidebar)
  "Return non-nil when SIDEBAR has a working mark on screen to redraw.

There is nothing to animate without an overlay and nothing to see
without a window, so the one question both arms the timer and stops
it."
  (and (buffer-live-p sidebar)
       (with-current-buffer sidebar
         (and agent-shell-vertico-sidebar--busy-overlays
              (agent-shell-vertico-sidebar--sidebar-visible-p sidebar)))))

(defun agent-shell-vertico-sidebar--busy-beat (sidebar)
  "Draw the next frame in SIDEBAR, or stop when there is nothing to draw.

The timer outlives the answer that armed it: a sidebar can be hidden or
killed, and its sessions can settle, between one beat and the next."
  (if (agent-shell-vertico-sidebar--busy-animation-wanted-p sidebar)
      (with-current-buffer sidebar
        (agent-shell-vertico-sidebar--animate-busy))
    (when (buffer-live-p sidebar)
      (with-current-buffer sidebar
        (agent-shell-vertico-sidebar--cancel-busy-refresh)))))

(defun agent-shell-vertico-sidebar--ensure-busy-refresh ()
  "Run the busy animation while a working mark is drawn and on screen."
  (let ((sidebar (or (and (derived-mode-p 'agent-shell-vertico-sidebar-mode)
                          (current-buffer))
                     (get-buffer "*Agent Shell Sessions*"))))
    (when sidebar
      (with-current-buffer sidebar
        (if (agent-shell-vertico-sidebar--busy-animation-wanted-p sidebar)
            (unless (timerp agent-shell-vertico-sidebar--busy-timer)
              ;; Activation and ownership must survive C-g together.
              (let ((inhibit-quit t)
                    timer)
                (setq timer
                      (run-with-timer
                       agent-shell-vertico-sidebar-busy-frame-interval
                       agent-shell-vertico-sidebar-busy-frame-interval
                       (lambda ()
                         ;; A lost or replaced timer must not keep spinning.
                         (if (and (buffer-live-p sidebar)
                                  (eq timer
                                      (buffer-local-value
                                       'agent-shell-vertico-sidebar--busy-timer
                                       sidebar)))
                             (agent-shell-vertico-sidebar--busy-beat sidebar)
                           (cancel-timer timer))))
                      agent-shell-vertico-sidebar--busy-timer timer)))
          (agent-shell-vertico-sidebar--cancel-busy-refresh))))))

(defun agent-shell-vertico-sidebar--ensure-age-refresh
    (&optional snapshots snapshots-supplied)
  "Keep the ages on screen current while the sidebar shows sessions.

Every row draws its age, so a visible sidebar with a session in it needs
the minute timer.  SNAPSHOTS, when supplied by the current render,
avoids rediscovering live sessions just to decide that."
  (let ((sidebar (or (and (derived-mode-p 'agent-shell-vertico-sidebar-mode)
                          (current-buffer))
                     (get-buffer "*Agent Shell Sessions*"))))
    (when sidebar
      (with-current-buffer sidebar
        (let* ((visible (agent-shell-vertico-sidebar--sidebar-visible-p
                         sidebar))
               (sessions (if snapshots-supplied
                             snapshots
                           (seq-some #'buffer-live-p (agent-shell-buffers))))
               (needed (and visible sessions)))
          (cond
           ((and needed
                 (not (timerp agent-shell-vertico-sidebar--age-refresh-timer)))
            (setq agent-shell-vertico-sidebar--age-refresh-timer
                  (run-with-timer
                   60 60
                   (lambda ()
                     (if (and (buffer-live-p sidebar)
                              (agent-shell-vertico-sidebar--sidebar-visible-p
                               sidebar))
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
        (agent-shell-vertico-sidebar--cancel-age-refresh)
        (agent-shell-vertico-sidebar--cancel-busy-refresh)
        (agent-shell-vertico-sidebar--cancel-background-refresh)))))

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

(defun agent-shell-vertico-sidebar--subagent-event-p ()
  "Return non-nil when the event being handled is a subagent's.

agent-shell emits a subagent's messages and tool calls as the root
session's events, with nothing in them to say whose they are, but it
binds `agent-shell--subagent-group' around the dispatch that emits them,
and subscribers run inside that dispatch."
  (and (boundp 'agent-shell--subagent-group)
       agent-shell--subagent-group
       t))

(defun agent-shell-vertico-sidebar--out-of-turn-p (buffer kind)
  "Return non-nil when a KIND event in BUFFER is out-of-turn output.

Requires agent output with no request of any kind in flight.  Checking
the status alone is not enough: a steered prompt's own request is
tracked while `agent-shell-status' still answers `ready', and the updates
arriving during that round trip belong to the turn it is joining.

A subagent's output is not the session speaking: it is the background
work `agent-shell-vertico-sidebar--background-work' already reports."
  (and (memq kind agent-shell-vertico-sidebar--out-of-turn-events)
       (not (agent-shell-vertico-sidebar--subagent-event-p))
       (not (memq (agent-shell-vertico-sidebar--live-status buffer)
                  '(busy blocked)))
       (not (map-elt (agent-shell-vertico--state buffer) :active-requests))))

(defun agent-shell-vertico-sidebar--cancel-out-of-turn (buffer)
  "Drop any pending out-of-turn settle timer for BUFFER."
  (when-let* ((burst (agent-shell-vertico-sidebar--get buffer 'out-of-turn))
              (timer (plist-get burst :timer))
              ((timerp timer)))
    (cancel-timer timer))
  (agent-shell-vertico-sidebar--set buffer 'out-of-turn nil))

(defun agent-shell-vertico-sidebar--note-out-of-turn (buffer time)
  "Record out-of-turn output in BUFFER at TIME and rearm its settle timer.

The burst keeps the time of its first update as its working age, so a
long burst rises through the working tier instead of restarting at every
chunk."
  (agent-shell-vertico-sidebar--cancel-out-of-turn buffer)
  (unless (agent-shell-vertico-sidebar--get buffer 'busy-since)
    (agent-shell-vertico-sidebar--set buffer 'busy-since time))
  (agent-shell-vertico-sidebar--set buffer 'out-of-turn (list :timer
                 (run-at-time
                  (agent-shell-vertico-sidebar--out-of-turn-settle-seconds)
                  nil
                  #'agent-shell-vertico-sidebar--out-of-turn-settled
                  buffer)
                 :time time)))

(defun agent-shell-vertico-sidebar--out-of-turn-settled (buffer)
  "Mark BUFFER's finished out-of-turn output as unread.

A burst carries no completion event, so it counts as finished once it has
been quiet for `agent-shell-vertico-sidebar--out-of-turn-settle-seconds'.
A pause longer than that mid-burst settles early; the next update starts
a fresh burst and finds this mark already in place, so the reader still
sees one mark rather than a flicker.

That is also why a burst stacked on a mark nobody has read announces
nothing: quiet is the only signal there is, and it cannot tell one
message paused from a second wave minutes later, so a wave that would
have announced itself twice for one message stays silent instead.  A
wave arriving after the last one was read finds no mark and announces
itself as usual.

The one wave that does announce itself on a mark is the result of
background work: a turn that ended with work still running recorded so
in the session's `background-at-turn-end' slot, and the first
wave to settle once nothing runs is what that turn was waiting for.  It
is announced once, and the mark keeps its own time."
  (let ((burst (agent-shell-vertico-sidebar--get buffer 'out-of-turn)))
    (agent-shell-vertico-sidebar--cancel-out-of-turn buffer)
    (agent-shell-vertico-sidebar--set buffer 'busy-since nil)
    (when (and (buffer-live-p buffer)
               ;; A real turn started meanwhile and owns the session now.
               (not (memq (agent-shell-vertico-sidebar--live-status buffer)
                          '(busy blocked))))
      (let ((result (and (agent-shell-vertico-sidebar--get
                          buffer 'background-at-turn-end)
                         (not (agent-shell-vertico-sidebar--background-work
                               buffer)))))
        (when result
          (agent-shell-vertico-sidebar--set buffer 'background-at-turn-end nil))
        (unless (agent-shell-vertico-sidebar--session-focused-p buffer)
          (cond
           ;; An earlier unread mark keeps its own time, so the
           ;; attention tier still orders oldest first.  The record is
           ;; asked directly rather than through
           ;; `agent-shell-vertico-sidebar--unread-time', because this
           ;; writes the record: what a row would show is deferred while
           ;; a session works and answers nothing.
           ((not (agent-shell-vertico-sidebar--get buffer 'unread))
            (agent-shell-vertico-sidebar--set
             buffer 'unread (or (plist-get burst :time) (float-time)))
            (agent-shell-vertico-sidebar--notify buffer))
           (result
            (agent-shell-vertico-sidebar--notify buffer))))))
    ;; The burst stopping is a message boundary, the same way any other
    ;; event is one.  Two waves of chunks carry no event between them,
    ;; so without this the second wave's message would start with the
    ;; first wave's text.
    (agent-shell-vertico-sidebar--close-message buffer)
    (agent-shell-vertico-sidebar--schedule-refresh)))

(defun agent-shell-vertico-sidebar--close-message (buffer)
  "End the agent message BUFFER is streaming, keeping what it holds.

The chunks stay, so a notification sent afterwards still reads the
message; what streams next starts a new one."
  (when-let* ((entry (agent-shell-vertico-sidebar--get buffer 'message)))
    (agent-shell-vertico-sidebar--set buffer 'message
                                      (plist-put entry :open nil))))

(defun agent-shell-vertico-sidebar--record-message-chunk (buffer event)
  "Accumulate the agent message BUFFER is streaming in EVENT.

agent-shell emits one event per streamed chunk and accumulates none of
them, so the sidebar keeps the newest message for a notification to
carry.  Any other event ends the message, which is agent-shell's own
message boundary.  A subagent's events are neither, since what a
subagent says is not the message the session has for the reader."
  (let ((entry (agent-shell-vertico-sidebar--get buffer 'message)))
    (cond
     ((agent-shell-vertico-sidebar--subagent-event-p))
     ((not (eq (map-elt event :event) 'agent-message-chunk))
      (agent-shell-vertico-sidebar--close-message buffer))
     (t
      (unless (plist-get entry :open)
        (setq entry (list :chunks nil :open t)))
      (when-let* ((chunk (map-nested-elt event '(:data :text-chunk))))
        (setq entry (plist-put entry :chunks
                               (cons chunk (plist-get entry :chunks))))
        (agent-shell-vertico-sidebar--set buffer 'detail 'message))
      (agent-shell-vertico-sidebar--set buffer 'message entry)))))

(defun agent-shell-vertico-sidebar--clean-line (text)
  "Return TEXT as one plain line, or nil when nothing is left.

Terminal escapes and tags go, and every run of whitespace becomes one
space, as Claude Code cleans the lines of its transcript tail."
  (let ((line (string-trim
               (replace-regexp-in-string
                "[[:space:]]+" " "
                (replace-regexp-in-string
                 "<[^>\n]*>" ""
                 (replace-regexp-in-string
                  "\e\\[[0-9;?]*[A-Za-z]" "" (or text "")))))))
    (unless (string-empty-p line)
      line)))

(defun agent-shell-vertico-sidebar--message-last-line (buffer)
  "Return the last non-empty line of the message BUFFER is streaming.

Only the newest chunks are joined, as many as hold a whole last line,
so a long message costs no more than its end."
  (let ((chunks (plist-get (agent-shell-vertico-sidebar--get buffer 'message)
                           :chunks))
        (tail ""))
    (while (and chunks
                (not (string-match-p "\n[^\n]*[^[:space:]]" tail)))
      (setq tail (concat (pop chunks) tail)))
    (seq-some (lambda (line)
                (unless (string-match-p "\\`[ \t]*```" line)
                  (agent-shell-vertico-sidebar--clean-line line)))
              (reverse (split-string tail "\n")))))

(defun agent-shell-vertico-sidebar--record-tool-call (buffer event)
  "Record a failed tool call in EVENT as BUFFER's newest entry."
  (let ((call (map-nested-elt event '(:data :tool-call))))
    (when (and (equal (map-elt call :status) "failed")
               (not (agent-shell-vertico-sidebar--subagent-event-p)))
      (agent-shell-vertico-sidebar--set
       buffer 'detail
       (concat "✗ " (or (agent-shell-vertico-sidebar--clean-line
                         (map-elt call :title))
                        "tool call"))))))

(defun agent-shell-vertico-sidebar--detail-text (buffer)
  "Return BUFFER's newest entry as one line, or nil."
  (let ((detail (agent-shell-vertico-sidebar--get buffer 'detail)))
    (if (eq detail 'message)
        (agent-shell-vertico-sidebar--message-last-line buffer)
      detail)))

(defun agent-shell-vertico-sidebar--last-message (buffer)
  "Return the newest agent message streamed into BUFFER, or nil."
  (when-let* ((chunks (plist-get
                       (agent-shell-vertico-sidebar--get buffer 'message)
                       :chunks)))
    (apply #'concat (reverse chunks))))

(defconst agent-shell-vertico-sidebar--marker-regexp
  "^[ \t]*\\(result\\|needs input\\|blocked\\|failed\\):[ \t]*\\(.+?\\)[ \t]*$"
  "A line a turn can end on to say how it ended, read case-insensitively.")

(defun agent-shell-vertico-sidebar--classify-message (text)
  "Return (STATE . LINE) for agent message TEXT, read as Claude Code does.

Claude Code asks its background sessions to end a turn on a `result:',
`needs input:' or `failed:' line, and reads the end of the message for
one before it asks a model.  Here a marker counts only when it is the
message's last non-empty line outside code fences, where Claude Code
puts it, so a `Blocked:' or `Failed:' line in the middle of an ordinary
summary is just text.  There is no model step.  `needs input:' and
`blocked:' give `blocked', `failed:' gives `failed', and `result:'
gives `done'; LINE is what follows the colon.  When the last line is no
marker the turn is done, and LINE is that line, or nil when there is no
message."
  (let ((case-fold-search t)
        fenced last-line)
    (dolist (line (split-string (or text "") "\n"))
      (cond
       ((string-match-p "\\`[ \t]*```" line) (setq fenced (not fenced)))
       (fenced nil)
       (t (let ((trimmed (string-trim line)))
            (unless (string-empty-p trimmed)
              (setq last-line trimmed))))))
    (if (and last-line
             (string-match agent-shell-vertico-sidebar--marker-regexp
                           last-line))
        (cons (pcase (downcase (match-string 1 last-line))
                ("result" 'done)
                ("failed" 'failed)
                (_ 'blocked))
              (match-string 2 last-line))
      (cons 'done last-line))))

(defun agent-shell-vertico-sidebar--stamp-terminal (buffer time)
  "Record that a turn of BUFFER ended at TIME.
A wait for a permission request ends with the turn."
  (agent-shell-vertico-sidebar--set buffer 'last-terminal-at time)
  (agent-shell-vertico-sidebar--set buffer 'waiting-since nil)
  (unless (agent-shell-vertico-sidebar--get buffer 'first-terminal-at)
    (agent-shell-vertico-sidebar--set buffer 'first-terminal-at time)))

(defun agent-shell-vertico-sidebar--end-turn (buffer reason time)
  "Record how BUFFER's turn ended at TIME, stopping for REASON.

REASON is the ACP stop reason.  A cancelled turn is `stopped'.  A turn
that ran to its end is classified by
`agent-shell-vertico-sidebar--classify-message'.  Any other reason, a
refusal or a limit, cut the turn short, so it `failed', in agent-shell's
own words for the reason.  A turn-complete with no reason is read as
one that ran to its end, unless the error event before it already said
the turn failed."
  (agent-shell-vertico-sidebar--set buffer 'stop-reason reason)
  (agent-shell-vertico-sidebar--stamp-terminal buffer time)
  (pcase reason
    ("cancelled" (agent-shell-vertico-sidebar--set buffer 'state 'stopped))
    ((or "end_turn" 'nil)
     (unless (and (null reason)
                  (eq (agent-shell-vertico-sidebar--get buffer 'state) 'failed))
       (pcase-let ((`(,state . ,line)
                    (agent-shell-vertico-sidebar--classify-message
                     (agent-shell-vertico-sidebar--last-message buffer))))
         (agent-shell-vertico-sidebar--set buffer 'state state)
         (pcase state
           ('done (agent-shell-vertico-sidebar--set buffer 'result line))
           ('blocked (agent-shell-vertico-sidebar--set buffer 'needs line))
           ('failed (agent-shell-vertico-sidebar--set buffer 'error line))))))
    (_
     (agent-shell-vertico-sidebar--set buffer 'state 'failed)
     (agent-shell-vertico-sidebar--set
      buffer 'error (if (fboundp 'agent-shell--stop-reason-description)
                        (agent-shell--stop-reason-description reason)
                      reason)))))

(defun agent-shell-vertico-sidebar--notify (buffer)
  "Report that BUFFER now needs attention.

The report goes to `agent-shell-vertico-sidebar-notify-function'.  Call
this after the unread mark and the status are in place, since both are
read back from the session.  A snoozed session is not reported: the
events that end a snooze end it before they get here."
  (when (and agent-shell-vertico-sidebar-notify-function
             (buffer-live-p buffer)
             (not (agent-shell-vertico-sidebar--snoozed-p buffer))
             (not (agent-shell-vertico-sidebar--session-focused-p buffer)))
    (pcase-let ((`(,state ,_tempo ,needs)
                 (agent-shell-vertico-sidebar--job-state buffer)))
      (funcall agent-shell-vertico-sidebar-notify-function
               :buffer buffer
               :agent (agent-shell-vertico--agent-name buffer)
               :status (agent-shell-vertico-sidebar--status-name buffer)
               :state state
               :needs needs
               :unread (agent-shell-vertico-sidebar--unread-p buffer)
               :last-message (agent-shell-vertico-sidebar--last-message
                              buffer)))))

(defun agent-shell-vertico-sidebar--handle-event (buffer event)
  "Update sidebar metadata for BUFFER after agent EVENT."
  (let ((kind (map-elt event :event))
        (now (float-time)))
    (agent-shell-vertico-sidebar--record-message-chunk buffer event)
    (agent-shell-vertico-sidebar--set buffer 'updated-at now)
    (pcase kind
      ('permission-request
       (agent-shell-vertico-sidebar--cancel-out-of-turn buffer)
       (agent-shell-vertico-sidebar--set buffer 'busy-since nil)
       ;; The request itself is news; the session reports itself blocked
       ;; for as long as it waits, so nothing records that part.  It is
       ;; also a new ask, which no snooze put off.  The newest request
       ;; is the one the session waits on, so the wait ages from it.
       (agent-shell-vertico-sidebar--set buffer 'snoozed nil)
       (agent-shell-vertico-sidebar--set buffer 'waiting-since now)
       (agent-shell-vertico-sidebar--mark-unread-at buffer now)
       (agent-shell-vertico-sidebar--notify buffer))
      ('error
       (agent-shell-vertico-sidebar--cancel-out-of-turn buffer)
       (agent-shell-vertico-sidebar--set buffer 'busy-since nil)
       (agent-shell-vertico-sidebar--set buffer 'state 'failed)
       (agent-shell-vertico-sidebar--set
        buffer 'error (or (map-nested-elt event '(:data :message)) t))
       (agent-shell-vertico-sidebar--stamp-terminal buffer now)
       (agent-shell-vertico-sidebar--set buffer 'snoozed nil)
       (agent-shell-vertico-sidebar--mark-unread-at buffer now)
       (agent-shell-vertico-sidebar--notify buffer))
      ('turn-complete
       (agent-shell-vertico-sidebar--cancel-out-of-turn buffer)
       (agent-shell-vertico-sidebar--set buffer 'busy-since nil)
       (agent-shell-vertico-sidebar--end-turn
        buffer (map-nested-elt event '(:data :stop-reason)) now)
       (if (agent-shell-vertico-sidebar--background-work buffer)
           (agent-shell-vertico-sidebar--set buffer 'background-at-turn-end t)
         (agent-shell-vertico-sidebar--set buffer 'background-at-turn-end nil))
       (if (agent-shell-vertico-sidebar--session-focused-p buffer)
           (agent-shell-vertico-sidebar--set buffer 'unread nil)
         (agent-shell-vertico-sidebar--mark-unread-at buffer now)
         (agent-shell-vertico-sidebar--notify buffer)))
      ('input-submitted
       (agent-shell-vertico-sidebar--cancel-out-of-turn buffer)
       (agent-shell-vertico-sidebar--set buffer 'busy-since now)
       ;; Submitting a new prompt means the user has seen whatever the
       ;; previous turn produced, and starts a turn of their own, so how
       ;; the last one ended stops being what the session is.  It is
       ;; also dealing with the session, which is what a snooze waits for.
       (agent-shell-vertico-sidebar--set buffer 'unread nil)
       (agent-shell-vertico-sidebar--set buffer 'state 'working)
       (agent-shell-vertico-sidebar--set buffer 'fresh nil)
       (agent-shell-vertico-sidebar--set buffer 'needs nil)
       (agent-shell-vertico-sidebar--set buffer 'error nil)
       (agent-shell-vertico-sidebar--set buffer 'waiting-since nil)
       ;; What the last turn said is no answer to this prompt.
       (agent-shell-vertico-sidebar--set buffer 'message nil)
       (agent-shell-vertico-sidebar--set buffer 'result nil)
       (agent-shell-vertico-sidebar--set
        buffer 'detail
        (when-let* ((prompt (agent-shell-vertico-sidebar--clean-line
                             (map-nested-elt event '(:data :prompt)))))
          (concat "> " prompt)))
       (agent-shell-vertico-sidebar--set buffer 'snoozed nil)
       (agent-shell-vertico-sidebar--set buffer 'background-at-turn-end nil))
      ('tool-call-update
       (agent-shell-vertico-sidebar--record-tool-call buffer event))
      ('session-restored
       ;; A restored session has a history, so it has been prompted.
       (agent-shell-vertico-sidebar--set buffer 'fresh nil))
      ('permission-response
       ;; Answering a request is reading it, whether or not another one
       ;; is already pending behind it.
       (agent-shell-vertico-sidebar--set buffer 'unread nil)
       (when (eq (agent-shell-vertico-sidebar--live-status buffer) 'busy)
         (agent-shell-vertico-sidebar--set buffer 'busy-since now)))
      ('idle
       (agent-shell-vertico-sidebar--set buffer 'busy-since nil))
      ('clean-up
       (agent-shell-vertico-sidebar--cancel-out-of-turn buffer)
       (agent-shell-vertico-sidebar--forget buffer))
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
    (agent-shell-vertico-sidebar--forget (current-buffer))
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
               agent-shell-vertico-sidebar--subscriptions)
      (unless (agent-shell-vertico-sidebar--get buffer 'created-at)
        (agent-shell-vertico-sidebar--set buffer 'created-at (float-time))
        ;; Only a session seen before its ACP session exists is known to
        ;; have had no prompt yet.
        (unless (agent-shell-vertico--session-field buffer :id)
          (agent-shell-vertico-sidebar--set buffer 'fresh t))))
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
    (dolist (table (list agent-shell-vertico-sidebar--subscriptions
                         agent-shell-vertico-sidebar--sessions))
      (maphash (lambda (buffer _value)
                 (unless (or (buffer-live-p buffer) (memq buffer dead))
                   (push buffer dead)))
               table))
    (dolist (buffer dead)
      (agent-shell-vertico-sidebar--cancel-out-of-turn buffer)
      (remhash buffer agent-shell-vertico-sidebar--subscriptions)
      (agent-shell-vertico-sidebar--forget buffer)))
  (dolist (buffer (if buffers-supplied buffers (agent-shell-buffers)))
    (agent-shell-vertico-sidebar--watch-buffer buffer schedule)))

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
             (eq shown (agent-shell-vertico--viewport-buffer buffer))))))

(defun agent-shell-vertico-sidebar--session-for-buffer (buffer
                                                        &optional sessions)
  "Return the session BUFFER belongs to, or nil.

A session buffer stands for itself; a viewport stands for the session it
shows.  SESSIONS, when given, are the live session buffers to search for
a viewport, saving a render its own query."
  (when (buffer-live-p buffer)
    (if (with-current-buffer buffer (derived-mode-p 'agent-shell-mode))
        buffer
      (seq-find (lambda (session)
                  (eq buffer
                      (agent-shell-vertico--viewport-buffer session)))
                (or sessions
                    (seq-filter #'buffer-live-p (agent-shell-buffers)))))))

(defun agent-shell-vertico-sidebar--current-sessions (&optional sessions)
  "Return the live sessions on screen in the selected frame.

A session is current while the reader can see it: one of the frame's
windows shows its buffer or its viewport.  The selected window alone is
too narrow an answer, because a reader who moves to the sidebar, to a
file or to magit beside a session is still working in that session.
Windows on other frames do not count, and the selected frame already
follows input focus.  SESSIONS is passed on to
`agent-shell-vertico-sidebar--session-for-buffer', and is resolved once
here when the caller has no list of its own: the hooks that ask this
question run on every window change."
  (let ((sessions (or sessions
                      (seq-filter #'buffer-live-p (agent-shell-buffers)))))
    (delete-dups
     (delq nil
           (mapcar (lambda (window)
                     (agent-shell-vertico-sidebar--session-for-buffer
                      (window-buffer window) sessions))
                   (window-list nil 'no-minibuf))))))

(defun agent-shell-vertico-sidebar--focused-session (current
                                                    &optional sessions)
  "Return which of CURRENT the selected window shows, or nil.

CURRENT is `agent-shell-vertico-sidebar--current-sessions', the sessions
on the selected frame, which both callers have computed already.
SESSIONS is passed on to `agent-shell-vertico-sidebar--session-for-buffer'.

The answer is the selected window and nothing else: the session whose
buffer or viewport it shows, and nil beside a file, magit or the
sidebar, where the reader is typing into none of them.  Nothing is
remembered, so a frame or workspace is marked by what it shows and not
by where the reader last was on some other one, and the same layout is
always marked the same way.  This is the same question as
`agent-shell-vertico-sidebar--session-focused-p' asks about what has been
read, without that one's insistence on a focused frame: the sidebar
draws for the selected frame whether or not it has input focus."
  (car (memq (agent-shell-vertico-sidebar--session-for-buffer
              (window-buffer (selected-window)) sessions)
             current)))

(defun agent-shell-vertico-sidebar--refresh-current-marker ()
  "Schedule a redraw when the markers drawn no longer match the frame.

Two answers are drawn and either can go out of date.  Which sessions are
on screen is a set, so a window rearrangement showing the same ones
redraws nothing; which of them the reader is working in changes whenever
the selected window moves onto or off a session, with the set untouched."
  (when-let ((sidebar (get-buffer "*Agent Shell Sessions*")))
    ;; Resolved once and passed on, because this runs on every window
    ;; change and both questions would otherwise ask agent-shell for the
    ;; same list of sessions.
    (let* ((sessions (seq-filter #'buffer-live-p (agent-shell-buffers)))
           (current (agent-shell-vertico-sidebar--current-sessions sessions)))
      (unless (and (seq-set-equal-p
                    current
                    (buffer-local-value
                     'agent-shell-vertico-sidebar--rendered-current-sessions
                     sidebar))
                   (eq (and current
                            (agent-shell-vertico-sidebar--focused-session
                             current sessions))
                       (buffer-local-value
                        'agent-shell-vertico-sidebar--rendered-focused-session
                        sidebar)))
        (agent-shell-vertico-sidebar--schedule-refresh)))))

(defun agent-shell-vertico-sidebar--mark-seen (buffer)
  "Mark unread output in BUFFER as seen.

Reading settles what the session has said, not what it is waiting for:
a blocked session still needs its permission decision afterwards, and a
failed one is still failed."
  (when (agent-shell-vertico-sidebar--get buffer 'unread)
    (agent-shell-vertico-sidebar--set buffer 'unread nil)
    (agent-shell-vertico-sidebar--schedule-refresh)))

(defun agent-shell-vertico-sidebar--mark-selected-seen (frame-or-window)
  "Mark the session shown in FRAME-OR-WINDOW as seen, then redraw the marker.

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
      (agent-shell-vertico-sidebar--mark-seen session))
    (agent-shell-vertico-sidebar--refresh-current-marker)))

(defun agent-shell-vertico-sidebar--window-selection-change
    (&optional frame-or-window)
  "Mark a session seen when its window, or its viewport's, is selected.

Emacs passes the frame whose selected window changed, because this runs
from the default value of `window-selection-change-functions'.  Reading
the current buffer instead would clear the mark of whichever session
happens to be current, which is the wrong session once a second frame is
involved.  It also runs from `window-buffer-change-functions', which
passes the frame too: switching buffers in place leaves the selected
window alone, and only that hook sees the session come or go."
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
context and detail lines are not, so each key lands on one row's first line.
Moving back from one of those lines lands on the row point is already in,
and only the next key leaves it: a session's path and details are part of
its row, so backing out of them must not skip the row itself.

Point does not move at the ends of the list, and nothing is reported there.
The only row in a one-session sidebar is both ends at once, and answering
that there is no row would say the opposite of what the sidebar shows."
  (let* ((node-positions (agent-shell-vertico-sidebar--node-positions))
         (start (agent-shell-vertico-sidebar--row-start node-positions)))
    (if (and backward (> (line-beginning-position) start))
        (goto-char (agent-shell-vertico-sidebar--row-point start))
      (let* ((rows (mapcar #'cdr node-positions))
             (position (seq-find (if backward
                                     (lambda (position) (< position start))
                                   (lambda (position) (> position start)))
                                 (if backward (reverse rows) rows))))
        (when position
          (goto-char (agent-shell-vertico-sidebar--row-point position)))))))

(defun agent-shell-vertico-sidebar-next-row ()
  "Move point to the first line of the next session or project row."
  (interactive)
  (agent-shell-vertico-sidebar--move-to-row nil))

(defun agent-shell-vertico-sidebar-previous-row ()
  "Move point to the first line of the row above the one point sits in.

From a session's own path or detail lines this is that session's first
line, so the row point is in is never skipped."
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

(defun agent-shell-vertico-sidebar-toggle-section ()
  "Toggle the state section fold at point."
  (interactive)
  (unless (eq (agent-shell-vertico-sidebar--node-kind-at-point) 'section)
    (user-error "Point is not on a section header"))
  (let ((section (agent-shell-vertico-sidebar--node-at-point)))
    (agent-shell-vertico-sidebar--set-section-folded
     section (not (agent-shell-vertico-sidebar--section-folded-p section)))
    (agent-shell-vertico-sidebar--render)))

(defun agent-shell-vertico-sidebar-show-more ()
  "Show the rest of the state section whose \"more\" row is at point.
Folding the section puts the limit back."
  (interactive)
  (unless (eq (agent-shell-vertico-sidebar--node-kind-at-point) 'more)
    (user-error "Point is not on a \"more\" row"))
  (let ((section (agent-shell-vertico-sidebar--node-at-point)))
    (cl-pushnew section agent-shell-vertico-sidebar--open-tails)
    (let ((first-hidden
           (save-excursion
             (forward-line -1)
             (agent-shell-vertico-sidebar--node-at-point))))
      (agent-shell-vertico-sidebar--render)
      ;; The first newly shown row takes the place of the row that was
      ;; read, so point stays where the reader was looking.
      (when-let* ((next (cl-loop for (buffer . position)
                                 in (agent-shell-vertico-sidebar--session-rows)
                                 with seen = nil
                                 if seen return position
                                 if (eq buffer first-hidden) do (setq seen t))))
        (goto-char (agent-shell-vertico-sidebar--row-point next))))))

(defun agent-shell-vertico-sidebar-open ()
  "Open the session, or toggle the project or section, at point."
  (interactive)
  (pcase (agent-shell-vertico-sidebar--node-kind-at-point)
    ('project (agent-shell-vertico-sidebar-toggle-project))
    ('section (agent-shell-vertico-sidebar-toggle-section))
    ('more (agent-shell-vertico-sidebar-show-more))
    (_
     (let ((buffer (agent-shell-vertico-sidebar--session-at-point)))
       (agent-shell-vertico-sidebar--mark-seen buffer)
       (agent-shell-vertico--display-session (buffer-name buffer))
       (agent-shell-vertico-sidebar-refresh)))))

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
         ;; The criteria are listed in their own order, the default
         ;; first, which a reader left to sort would alphabetize away.
         (choice (completing-read
                  "Sort sessions by: "
                  (agent-shell-vertico--ordered-table (mapcar #'car choices))
                  nil t))
         (sort-by (cdr (assoc choice choices))))
    (setq agent-shell-vertico-sidebar-sort-by sort-by)
    (agent-shell-vertico-sidebar-refresh)))

(defun agent-shell-vertico-sidebar-toggle-grouping ()
  "Cycle the sidebar through the flat, project and state views."
  (interactive)
  (setq agent-shell-vertico-sidebar-group-by
        (pcase agent-shell-vertico-sidebar-group-by
          ('nil 'project)
          ('project 'state)
          (_ nil)))
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

(defun agent-shell-vertico-sidebar--any-section-unfolded-p ()
  "Return non-nil when any state section holding a session shows it."
  (seq-some (lambda (buffer)
              (not (agent-shell-vertico-sidebar--section-folded-p
                    (agent-shell-vertico-sidebar--family-section buffer))))
            (seq-remove #'agent-shell-vertico-sidebar--parent-of
                        (seq-filter #'buffer-live-p (agent-shell-buffers)))))

(defun agent-shell-vertico-sidebar--view-level ()
  "Return the fold level the whole sidebar currently shows.

`projects' shows project or section headers only, `sessions' adds their
session rows, and `details' adds each session's metadata lines.  A flat
list has no header level, so it never returns `projects'."
  (cond
   ((pcase agent-shell-vertico-sidebar-group-by
      ('project (not (agent-shell-vertico-sidebar--any-project-expanded-p)))
      ('state (not (agent-shell-vertico-sidebar--any-section-unfolded-p))))
    'projects)
   ((agent-shell-vertico-sidebar--any-session-details-visible-p) 'details)
   (t 'sessions)))

(defun agent-shell-vertico-sidebar--set-view-level (level)
  "Show every row at fold LEVEL, discarding per-row fold overrides.

In the state view the header level folds every section; the other
levels put back each section's default fold and row limit."
  (pcase agent-shell-vertico-sidebar-group-by
    ('project
     (setq agent-shell-vertico-sidebar-expand-by-default
           (not (eq level 'projects)))
     (when (hash-table-p agent-shell-vertico-sidebar--expanded-projects)
       (clrhash agent-shell-vertico-sidebar--expanded-projects)))
    ('state
     (when (hash-table-p agent-shell-vertico-sidebar--section-folds)
       (clrhash agent-shell-vertico-sidebar--section-folds))
     (setq agent-shell-vertico-sidebar--open-tails nil)
     (when (eq level 'projects)
       (dolist (section agent-shell-vertico-sidebar--sections)
         (agent-shell-vertico-sidebar--set-section-folded
          (car section) t)))))
  (setq agent-shell-vertico-sidebar-show-details (eq level 'details))
  (when (hash-table-p agent-shell-vertico-sidebar--expanded-sessions)
    (clrhash agent-shell-vertico-sidebar--expanded-sessions)))

(defun agent-shell-vertico-sidebar-cycle-global-view ()
  "Cycle the whole sidebar to its next fold level.

With project or state grouping the levels are the headers alone, then
their session rows, then each session's metadata lines, then back to the
headers.
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
      ;; Refuse a foreign buffer before the fold settings change.
      (unless (derived-mode-p 'agent-shell-vertico-sidebar-mode)
        (user-error "The named sidebar buffer is not an agent-shell sidebar"))
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
  "Toggle the project, section or session detail at point."
  (interactive)
  (pcase (agent-shell-vertico-sidebar--node-kind-at-point)
    ('project (agent-shell-vertico-sidebar-toggle-project))
    ('section (agent-shell-vertico-sidebar-toggle-section))
    ('more (agent-shell-vertico-sidebar-show-more))
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

The returned vector contains attention, working, ready, starting,
snoozed and background counts in that order."
  (let ((counts (make-vector 6 0)))
    (dolist (buffer (seq-filter #'buffer-live-p (agent-shell-buffers)))
      (cl-incf (aref counts
                     (aref agent-shell-vertico-sidebar--statistics-slots
                           (agent-shell-vertico-sidebar--status-rank buffer)))))
    counts))

(defconst agent-shell-vertico-sidebar--band-words
  '((attention . "need you") (working . "working") (idle . "idle")
    (snoozed . "snoozed"))
  "What the header calls the sessions of each band, in header order.")

(defconst agent-shell-vertico-sidebar--band-faces
  '((attention . agent-shell-vertico-sidebar-blocked)
    (working . agent-shell-vertico-sidebar-working)
    (idle . agent-shell-vertico-sidebar-ready)
    (snoozed . agent-shell-vertico-sidebar-snoozed))
  "The face each band's count is drawn in.")

(defconst agent-shell-vertico-sidebar--view-names
  '((state . "state") (project . "project") (nil . "flat"))
  "The name the header gives each value of the grouping.")

(defun agent-shell-vertico-sidebar--attention-tooltip (titles)
  "Return the tooltip of a count of the sessions with TITLES."
  (concat (string-join titles "\n") "\nmouse-1: jump"))

(defun agent-shell-vertico-sidebar--attention-map (event)
  "Return a keymap running `agent-shell-vertico-sidebar-jump' on EVENT."
  (let ((map (make-sparse-keymap)))
    (define-key map (vector event 'mouse-1)
                #'agent-shell-vertico-sidebar-jump)
    map))

(defun agent-shell-vertico-sidebar--band-count-text (band snapshots digits)
  "Return the header count of BAND's SNAPSHOTS, or nil when there are none.

DIGITS drops the words, which move to the tooltip.  The attention
count names its sessions in the tooltip and jumps to them on a click."
  (when snapshots
    (let* ((count (length snapshots))
           (words (alist-get band agent-shell-vertico-sidebar--band-words))
           (text (propertize
                  (if digits
                      (number-to-string count)
                    (format "%d %s" count words))
                  'face (alist-get band
                                   agent-shell-vertico-sidebar--band-faces))))
      (if (eq band 'attention)
          (propertize text
                      'help-echo
                      (agent-shell-vertico-sidebar--attention-tooltip
                       (mapcar (lambda (snapshot) (plist-get snapshot :title))
                               snapshots))
                      'mouse-face 'highlight
                      'local-map (agent-shell-vertico-sidebar--attention-map
                                  'header-line))
        (if digits (propertize text 'help-echo words) text)))))

(defun agent-shell-vertico-sidebar--header-line-for (snapshots width)
  "Return the header counting SNAPSHOTS by band, made to fit WIDTH columns.

Each session is counted in its own band, the one `--band-for' gives.
The state view draws a child under its parent, in the section of the
family's most urgent band (`--family-section'), so a session counted in
a band is drawn in that band's section or in an earlier one, never a
later one: whoever the header says needs the reader sits under Needs
you, unless the family is pinned.  A band with no sessions is left out.
The counts are in words when they fit with the view's name, and in
coloured digits otherwise; the name goes last when even the digits do
not fit.  It keeps the right edge through an `:align-to' space, since
the header spans the fringes and margins that WIDTH leaves out."
  (let* ((groups (seq-group-by (lambda (snapshot)
                                 (plist-get snapshot :band))
                               snapshots))
         (counts (lambda (digits)
                   (concat
                    " "
                    (string-join
                     (delq nil
                           (mapcar
                            (pcase-lambda (`(,band . ,_))
                              (agent-shell-vertico-sidebar--band-count-text
                               band (alist-get band groups) digits))
                            agent-shell-vertico-sidebar--band-words))
                     " · "))))
         (view (alist-get agent-shell-vertico-sidebar-group-by
                          agent-shell-vertico-sidebar--view-names))
         (fits (lambda (text)
                 (<= (+ (string-width text) 1 (string-width view)) width)))
         (words (funcall counts nil))
         (line (if (funcall fits words) words (funcall counts t))))
    (if (funcall fits line)
        (concat line
                (propertize " " 'display
                            `(space :align-to (- right ,(string-width view))))
                (propertize view 'face 'agent-shell-vertico-sidebar-detail))
      line)))

(defun agent-shell-vertico-sidebar--attention-titles ()
  "Return the titles of the live sessions in the attention band."
  (delq nil
        (mapcar (lambda (buffer)
                  (when (eq (agent-shell-vertico-sidebar--band buffer)
                            'attention)
                    (agent-shell-vertico-sidebar--title buffer)))
                (seq-filter #'buffer-live-p (agent-shell-buffers)))))

(defvar agent-shell-vertico-sidebar--mode-line-cache nil
  "The last mode line text and when it was counted, as (TIME . TEXT).")

(defun agent-shell-vertico-sidebar--mode-line-text ()
  "Return how many sessions need the reader, for the mode line, or nil.

The count is the header's attention band, read from the live sessions
because the sidebar need not be open."
  (when-let* ((titles (agent-shell-vertico-sidebar--attention-titles)))
    (propertize (format " %d need you" (length titles))
                'face 'agent-shell-vertico-sidebar-blocked
                'help-echo (agent-shell-vertico-sidebar--attention-tooltip
                            titles)
                'mouse-face 'mode-line-highlight
                'local-map (agent-shell-vertico-sidebar--attention-map
                            'mode-line))))

(defun agent-shell-vertico-sidebar--mode-line-cached ()
  "Return `--mode-line-text', counted at most once a second.
The mode line is redrawn far more often than a session changes."
  (let ((now (float-time)))
    (unless (and agent-shell-vertico-sidebar--mode-line-cache
                 (< (- now (car agent-shell-vertico-sidebar--mode-line-cache))
                    1))
      (setq agent-shell-vertico-sidebar--mode-line-cache
            (cons now (agent-shell-vertico-sidebar--mode-line-text))))
    (cdr agent-shell-vertico-sidebar--mode-line-cache)))

(defconst agent-shell-vertico-sidebar--mode-line-format
  '(:eval (agent-shell-vertico-sidebar--mode-line-cached))
  "The entry `agent-shell-vertico-sidebar-mode-line-mode' adds.")

;;;###autoload
(define-minor-mode agent-shell-vertico-sidebar-mode-line-mode
  "Show in the mode line how many agent-shell sessions need you.

The count is the sidebar header's \"need you\": sessions waiting for a
permission decision or a reply.  Nothing is shown when none does."
  :global t
  :group 'agent-shell-vertico-sidebar
  (setq agent-shell-vertico-sidebar--mode-line-cache nil)
  (if agent-shell-vertico-sidebar-mode-line-mode
      (progn
        (unless global-mode-string
          (setq global-mode-string '("")))
        (add-to-list 'global-mode-string
                     agent-shell-vertico-sidebar--mode-line-format t))
    (setq global-mode-string
          (delete agent-shell-vertico-sidebar--mode-line-format
                  global-mode-string))))

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
   "  TAB         Toggle a section, project or session details\n"
   "  S-TAB       Cycle all rows: headers, sessions, details\n\n"
   "Actions\n"
   "  o / O       Open here / open in another window\n"
   "  =           Cycle the flat, project and state views\n"
   "  s           Choose the sort criterion\n"
   "  g (gr)      Refresh (regular / Evil state)\n"
   "  c           Create a new session\n"
   "  m / M       Set mode / model\n"
   "  t / T       Traffic / transcript (regular); reverse in Evil\n"
   "  k / r / i   Kill / restart / interrupt (regular state)\n"
   "  u / !       Mark the session unread again / read\n"
   "  z           Snooze the session until it asks again, or wake it\n"
   "  P           Pin the session to the top, or unpin it\n"
   "  p           Peek: read the session's question and message, reply\n"
   "  S           List the session's subagents and background tasks\n"
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
    (define-key map (kbd "z") #'agent-shell-vertico-sidebar-snooze)
    (define-key map (kbd "P") #'agent-shell-vertico-sidebar-pin)
    (define-key map (kbd "p") #'agent-shell-vertico-sidebar-peek)
    (define-key map (kbd "S") #'agent-shell-vertico-sidebar-subagents)
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
    (define-key map (kbd "z") #'agent-shell-vertico-sidebar-snooze)
    (define-key map (kbd "P") #'agent-shell-vertico-sidebar-pin)
    (define-key map (kbd "p") #'agent-shell-vertico-sidebar-peek)
    (define-key map (kbd "S") #'agent-shell-vertico-sidebar-subagents)
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
    ("z" . agent-shell-vertico-sidebar-snooze)
    ("P" . agent-shell-vertico-sidebar-pin)
    ("p" . agent-shell-vertico-sidebar-peek)
    ("S" . agent-shell-vertico-sidebar-subagents)
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
              agent-shell-vertico-sidebar--busy-timer nil
              agent-shell-vertico-sidebar--background-timer nil
              agent-shell-vertico-sidebar--rendered-background nil
              agent-shell-vertico-sidebar--busy-tick 0
              agent-shell-vertico-sidebar--busy-overlays nil
              agent-shell-vertico-sidebar--dirty nil
              agent-shell-vertico-sidebar--last-rendered-width nil)
  (setq-local agent-shell-vertico-sidebar--expanded-projects
              (make-hash-table :test #'equal))
  (setq-local agent-shell-vertico-sidebar--section-folds
              (make-hash-table :test #'eq))
  (setq-local agent-shell-vertico-sidebar--expanded-sessions
              (make-hash-table :test #'eq))
  (add-hook 'pre-redisplay-functions
            #'agent-shell-vertico-sidebar--keep-point-off-marks nil t)
  (add-hook 'kill-buffer-hook
            #'agent-shell-vertico-sidebar--cancel-refresh nil t)
  (add-hook 'kill-buffer-hook
            #'agent-shell-vertico-sidebar--cancel-age-refresh nil t)
  (add-hook 'kill-buffer-hook
            #'agent-shell-vertico-sidebar--cancel-resize nil t)
  (add-hook 'kill-buffer-hook
            #'agent-shell-vertico-sidebar--cancel-busy-refresh nil t)
  (add-hook 'change-major-mode-hook
            #'agent-shell-vertico-sidebar--cancel-busy-refresh nil t)
  (add-hook 'kill-buffer-hook
            #'agent-shell-vertico-sidebar--cancel-background-refresh nil t)
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
run from nothing running at all, and counting the snoozed ones says
what is still owed once the reader wants it."
  (let* ((statistics (agent-shell-vertico-sidebar--session-statistics))
         (working (aref statistics 1))
         (background (aref statistics 5))
         (snoozed (aref statistics 4)))
    (concat "No session needs attention"
            (and (> working 0) (format ", %d working" working))
            (and (> background 0)
                 (format ", %d in the background" background))
            (and (> snoozed 0) (format ", %d snoozed" snoozed)))))

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

A snoozed session is woken: asking for it again is the opposite of
putting it off.

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
      (if (not (agent-shell-vertico-sidebar--get buffer 'snoozed))
          (message "Session %s is already unread" (buffer-name buffer))
        (agent-shell-vertico-sidebar--set buffer 'snoozed nil)
        (agent-shell-vertico-sidebar-refresh)
        (message "Session %s marked unread" (buffer-name buffer))))
     (t
      (agent-shell-vertico-sidebar--set buffer 'snoozed nil)
      (agent-shell-vertico-sidebar--mark-unread-at
       buffer (or (agent-shell-vertico-sidebar--get buffer 'updated-at)
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
keeps its place through its status, which marking it read cannot
change (`agent-shell-vertico-sidebar-snooze' can put it off), and a
failed session stays failed until a new turn starts.  A snooze is kept,
since reading a session is not dealing with it.

New output marks the session again, which includes a turn that finishes
after this and a background stream that goes quiet after this.

A session working through a burst carries no mark to see, and the one it
is holding back still goes: the record is what this command is about."
  (interactive)
  (let ((buffer (agent-shell-vertico-sidebar--attention-target)))
    (if (not (agent-shell-vertico-sidebar--get buffer 'unread))
        (message "Session %s has nothing unread" (buffer-name buffer))
      (agent-shell-vertico-sidebar--set buffer 'unread nil)
      (agent-shell-vertico-sidebar-refresh)
      (message "Session %s marked read" (buffer-name buffer)))))

;;;###autoload
(defun agent-shell-vertico-sidebar-subagents ()
  "List the subagents and background tasks of the session at point.

Called outside the sidebar, list the current session's, a viewport's
included.  This is agent-shell's own list, `agent-shell-subagents', run
in the session, so it offers what that list offers: opening a subagent,
jumping to where it started, and stopping a task."
  (interactive)
  (let ((buffer (agent-shell-vertico-sidebar--attention-target)))
    (unless (fboundp 'agent-shell-subagents)
      (user-error "This agent-shell has no subagents list"))
    (with-current-buffer buffer
      (agent-shell-subagents))))

;;;###autoload
(defun agent-shell-vertico-sidebar-snooze ()
  "Snooze the session at point, or the current session, or wake it.

A snoozed session stops asking for the reader without being marked
read.  The state view moves it to the Snoozed section, folded by
default; the other views sort it below every session that is not
snoozed, whatever the sort, under a rule drawn where the snoozed
sessions begin.  `agent-shell-vertico-sidebar-jump' passes it over.
Its mark turns purple whatever its state and its title dims, still
bold while it holds output nobody has read; only a burst of output
draws it as working until the burst goes quiet.  Snoozing unpins the
session.  Nothing is reported to
`agent-shell-vertico-sidebar-notify-function' while it is snoozed.

Looking at a snoozed session, marking it read and new output all leave
it snoozed, because none of them is dealing with it.  Sending it a
prompt is, and so is a new permission request or an error, since the
agent cannot go on without the reader; so is running this again, or
`agent-shell-vertico-sidebar-mark-unread'.  Whatever it held comes
back with the age it had.

A working session is refused, because it has not yet said anything to
put off."
  (interactive)
  (let ((buffer (agent-shell-vertico-sidebar--attention-target)))
    (cond
     ((agent-shell-vertico-sidebar--get buffer 'snoozed)
      (agent-shell-vertico-sidebar--set buffer 'snoozed nil)
      (agent-shell-vertico-sidebar-refresh)
      (message "Session %s woken" (buffer-name buffer)))
     ((eq (agent-shell-vertico-sidebar--raw-status buffer) 'busy)
      (user-error "Session %s is still working" (buffer-name buffer)))
     (t
      (agent-shell-vertico-sidebar--set buffer 'snoozed (float-time))
      (agent-shell-vertico-sidebar--set buffer 'pinned nil)
      (agent-shell-vertico-sidebar-refresh)
      (message "Session %s snoozed" (buffer-name buffer))))))

(defun agent-shell-vertico-sidebar-pin ()
  "Pin the session at point, or the current session, or unpin it.

A pinned session sorts above every other session, whatever the sort,
and the state and project views draw it under a Pinned header at the
top.  It keeps its state: the header still counts it in its own band.
Pinning wakes a snoozed session, and snoozing unpins one."
  (interactive)
  (let ((buffer (agent-shell-vertico-sidebar--attention-target)))
    (if (agent-shell-vertico-sidebar--get buffer 'pinned)
        (progn
          (agent-shell-vertico-sidebar--set buffer 'pinned nil)
          (message "Session %s unpinned" (buffer-name buffer)))
      (agent-shell-vertico-sidebar--set buffer 'pinned (float-time))
      (agent-shell-vertico-sidebar--set buffer 'snoozed nil)
      (message "Session %s pinned" (buffer-name buffer)))
    (agent-shell-vertico-sidebar-refresh)))

(defconst agent-shell-vertico-sidebar--peek-buffer "*Agent Shell Peek*"
  "Buffer `agent-shell-vertico-sidebar-peek' shows a session in.")

(defvar-local agent-shell-vertico-sidebar--peek-session nil
  "The session the peek buffer shows.")

(defvar agent-shell-vertico-sidebar-peek-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "r") #'agent-shell-vertico-sidebar-peek-reply)
    (define-key map (kbd "RET") #'agent-shell-vertico-sidebar-peek-open)
    (define-key map (kbd "<return>") #'agent-shell-vertico-sidebar-peek-open)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `agent-shell-vertico-sidebar-peek-mode'.")

(define-derived-mode agent-shell-vertico-sidebar-peek-mode special-mode
  "Agent-Shell-Peek"
  "Major mode for the window showing one session's question and message."
  (setq-local truncate-lines nil
              mode-line-format nil)
  (visual-line-mode 1)
  (when (fboundp 'evil-local-set-key)
    (dolist (state '(normal motion))
      (evil-local-set-key state (kbd "r")
                          #'agent-shell-vertico-sidebar-peek-reply)
      (evil-local-set-key state (kbd "RET")
                          #'agent-shell-vertico-sidebar-peek-open)
      (evil-local-set-key state (kbd "q") #'quit-window))))

(defun agent-shell-vertico-sidebar--peek-text (buffer)
  "Return what the peek shows for session BUFFER."
  (let* ((snapshot (agent-shell-vertico-sidebar--session-snapshot buffer))
         (needs (plist-get snapshot :needs))
         (message (or (agent-shell-vertico-sidebar--last-message buffer)
                      (agent-shell-vertico-sidebar--detail-for snapshot)))
         (age (agent-shell-vertico-sidebar--age-text snapshot)))
    (concat
     (propertize (agent-shell-vertico-sidebar--title buffer) 'face 'bold)
     " · "
     (propertize (agent-shell-vertico-sidebar--status-name-for
                  (plist-get snapshot :status))
                 'face (agent-shell-vertico-sidebar--mark-face snapshot))
     (and age (concat " · " age))
     "\n"
     (and needs
          (concat (propertize needs 'face 'agent-shell-vertico-sidebar-blocked)
                  "\n"))
     "\n"
     (propertize "Last message" 'face 'agent-shell-vertico-sidebar-section)
     "\n"
     (if message
         (string-trim message)
       (propertize "Nothing yet" 'face 'agent-shell-vertico-sidebar-detail))
     "\n\n"
     (propertize "r reply · RET open · q close"
                 'face 'agent-shell-vertico-sidebar-detail))))

(defun agent-shell-vertico-sidebar-peek ()
  "Show what the session at point asks and last said, below the sidebar.

Outside the sidebar the current session is shown.  The window takes the
sidebar's side, under it, and is selected, so `r' replies to the
session without leaving the list and `RET' opens it.  Showing the
message is reading it, so the session's unread mark goes."
  (interactive)
  (let* ((session (agent-shell-vertico-sidebar--attention-target))
         (buffer (get-buffer-create agent-shell-vertico-sidebar--peek-buffer)))
    (with-current-buffer buffer
      (agent-shell-vertico-sidebar-peek-mode)
      (setq agent-shell-vertico-sidebar--peek-session session)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (agent-shell-vertico-sidebar--peek-text session))
        (goto-char (point-min))))
    (agent-shell-vertico-sidebar--mark-seen session)
    (when-let* ((window (display-buffer-in-side-window
                         buffer
                         `((side . ,agent-shell-vertico-sidebar-side)
                           (slot . 1)
                           (window-height . 0.35)))))
      (select-window window))))

(defun agent-shell-vertico-sidebar--peek-target ()
  "Return the live session the peek buffer shows, or signal a user error."
  (let ((session agent-shell-vertico-sidebar--peek-session))
    (unless (buffer-live-p session)
      (user-error "The peeked session is gone"))
    session))

(defun agent-shell-vertico-sidebar-peek-reply ()
  "Send one prompt to the session the peek shows, staying in the peek."
  (interactive)
  (let* ((session (agent-shell-vertico-sidebar--peek-target))
         (text (string-trim
                (read-string
                 (format "Reply to %s: "
                         (agent-shell-vertico-sidebar--title session))))))
    (when (string-empty-p text)
      (user-error "Nothing to send"))
    (agent-shell-insert :text text :submit t :no-focus t
                        :shell-buffer session)
    (message "Sent to %s" (buffer-name session))))

(defun agent-shell-vertico-sidebar-peek-open ()
  "Open the session the peek shows, and close the peek."
  (interactive)
  (let ((session (agent-shell-vertico-sidebar--peek-target)))
    (quit-window)
    (agent-shell-vertico--display-session (buffer-name session))))

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
      (agent-shell-vertico-sidebar--jump-display
       (get-buffer (agent-shell-vertico--read-session "Agent shell: " 'all)))
    (let* ((sessions (agent-shell-vertico-sidebar--attention-sessions))
           (target
            (seq-find
             (lambda (buffer)
               (not (agent-shell-vertico-sidebar--session-focused-p buffer)))
             sessions)))
      (cond
       ;; Visiting reads whatever the session had to say.  A
       ;; permission decision is still owed afterwards, and the
       ;; blocked status keeps the session in place for it.
       (target (agent-shell-vertico-sidebar--jump-display target))
       ;; Every session asking is the one the reader is already in,
       ;; which only a blocked one can be: arriving would settle
       ;; nothing, and saying so beats a jump that does not move.
       (sessions
        (message "%s"
                 (agent-shell-vertico-sidebar--attention-here-message
                  (car sessions))))
       (t
        (message
         "%s" (agent-shell-vertico-sidebar--no-attention-message)))))))

(defun agent-shell-vertico-sidebar--attention-here-message (buffer)
  "Return what to report when only BUFFER asks and the reader is in it."
  (format "No other session needs attention (this one is %s)"
          (downcase (agent-shell-vertico-sidebar--status-name buffer))))

(defun agent-shell-vertico-sidebar--jump-display (buffer)
  "Display session BUFFER, the default action of a jump."
  (agent-shell-vertico-sidebar--mark-seen buffer)
  (agent-shell-vertico--display-session (buffer-name buffer)))

(defun agent-shell-vertico-sidebar--jump-display-other-window (buffer)
  "Display session BUFFER in another window."
  (agent-shell-vertico-sidebar--mark-seen buffer)
  (agent-shell-vertico--display-session-other-window (buffer-name buffer)))

(defun agent-shell-vertico-sidebar--jump-mark-unread (buffer)
  "Mark session BUFFER unread.

The command reads its own target, so it is run with BUFFER current:
`--attention-target' answers with the session it is standing in, which
for a session buffer is that buffer."
  (with-current-buffer buffer
    (agent-shell-vertico-sidebar-mark-unread)))

(defun agent-shell-vertico-sidebar--jump-mark-read (buffer)
  "Mark session BUFFER read.
Run the same way as `agent-shell-vertico-sidebar--jump-mark-unread'."
  (with-current-buffer buffer
    (agent-shell-vertico-sidebar-mark-read)))

(defun agent-shell-vertico-sidebar--jump-subagents (buffer)
  "List session BUFFER's subagents and background tasks.
Run the same way as `agent-shell-vertico-sidebar--jump-mark-unread'."
  (with-current-buffer buffer
    (agent-shell-vertico-sidebar-subagents)))

(defun agent-shell-vertico-sidebar--jump-snooze (buffer)
  "Snooze or wake session BUFFER.
Run the same way as `agent-shell-vertico-sidebar--jump-mark-unread'."
  (with-current-buffer buffer
    (agent-shell-vertico-sidebar-snooze)))

(defun agent-shell-vertico-sidebar--dispatch-help ()
  "Return the action list `?' shows during a jump, one action a line.

Every line starts with its key, and the key is faced where the
description is not, so the list is a column to scan down rather than a
paragraph to read.  `ace-window' draws `aw-dispatch-alist' the same
way.  The blank line at the end keeps the list from running into the
prompt it is drawn above."
  (concat
   (mapconcat
    (pcase-lambda (`(,key ,_ ,description))
      (format "%s: %s"
              (propertize
               (char-to-string key)
               'face 'agent-shell-vertico-sidebar-jump-help-key)
              description))
    agent-shell-vertico-sidebar-jump-dispatch-alist
    "\n")
   "\n\n"))

;;;###autoload
(defun agent-shell-vertico-sidebar-jump-to-index (index &optional other-window)
  "Display the session at INDEX in the order the sidebar lists them.

INDEX counts from 1, so session 1 is the row at the top of the sidebar,
the one `agent-shell-vertico-sidebar-jump-by-key' gives its first key.
Every live session counts, whether the sidebar is showing it or not,
because this jump draws nothing for the reader to look at: it is the
blind jump the `agent-shell-vertico-sidebar-jump-to-1' family is bound
to, and it opens no sidebar of its own.

The order is `agent-shell-vertico-sidebar-sort-by', so an index is a
position and not a name for a session: under `priority' a finished turn
moves its session up and the same index answers differently.  That is
the trade a quick jump makes; press `?' during
`agent-shell-vertico-sidebar-jump-by-key' to choose from what is on
screen instead.

With OTHER-WINDOW, display the session in another window."
  (interactive
   (list (or (and current-prefix-arg (prefix-numeric-value current-prefix-arg))
             (read-number "Jump to session #: "))))
  (let ((buffers (agent-shell-vertico-sidebar--sort-buffers
                  (seq-filter #'buffer-live-p (agent-shell-buffers))
                  agent-shell-vertico-sidebar-sort-by)))
    (unless buffers
      (user-error "No agent-shell sessions"))
    (let ((buffer (and (> index 0) (nth (1- index) buffers))))
      (unless buffer
        (user-error "No session at #%d" index))
      (if other-window
          (agent-shell-vertico-sidebar--jump-display-other-window buffer)
        (agent-shell-vertico-sidebar--jump-display buffer))
      (agent-shell-vertico-sidebar-refresh))))

;; One command a session, the way `+workspace/switch-to-N' is generated
;; for workspaces: a named command is bindable in a `map!' without a
;; lambda, findable through `execute-extended-command', and carries its
;; own index rather than reading it back out of the key that ran it.
;; These count from 1, unlike Doom's, so a command's number is the key.
;;;###autoload
(dotimes (offset 9)
  (let ((index (1+ offset)))
    (defalias (intern (format "agent-shell-vertico-sidebar-jump-to-%d" index))
      (lambda (&optional other-window)
        (interactive "P")
        (agent-shell-vertico-sidebar-jump-to-index index other-window))
      (format "Jump to session #%d in the order the sidebar lists them."
              index))))

(defun agent-shell-vertico-sidebar--display-order ()
  "Return every live session in the order the sidebar draws its rows.

This is the walk `--render' makes, without drawing: the sessions with no
live parent, grouped by state section or project when
`agent-shell-vertico-sidebar-group-by' says so, each followed depth-first
by its children.  A folded project or section, and the Idle rows past
its limit, still list their sessions, because nothing is drawn for the
reader to look at and a step should not depend on how the sidebar was
left."
  (let* ((sort-by agent-shell-vertico-sidebar-sort-by)
         (buffers (seq-filter #'buffer-live-p (agent-shell-buffers)))
         (roots (seq-remove #'agent-shell-vertico-sidebar--parent-of buffers)))
    (named-let walk ((buffers
                      (pcase agent-shell-vertico-sidebar-group-by
                        ('state
                         (seq-mapcat
                          #'cdr
                          (agent-shell-vertico-sidebar--group-by-section
                           (agent-shell-vertico-sidebar--sort-buffers
                            roots sort-by))))
                        ('project
                         (pcase-let ((`(,pinned . ,rest)
                                      (agent-shell-vertico-sidebar--split-pinned
                                       roots)))
                           (append
                            (agent-shell-vertico-sidebar--sort-buffers
                             pinned sort-by)
                            (seq-mapcat
                             #'cdr
                             (agent-shell-vertico-sidebar--sort-groups
                              (agent-shell-vertico-sidebar--group-buffers
                               rest)
                              sort-by)))))
                        (_ (agent-shell-vertico-sidebar--sort-buffers
                            roots sort-by)))))
      (seq-mapcat (lambda (buffer)
                    (cons buffer
                          (walk (agent-shell-vertico-sidebar--sort-buffers
                                 (agent-shell-vertico-sidebar--children-of
                                  buffer)
                                 sort-by))))
                  buffers))))

(defun agent-shell-vertico-sidebar--step-session (offset other-window)
  "Display the session OFFSET rows from this one in the sidebar's order.

The order wraps, so a step past either end arrives at the other.  From a
buffer that is no session, a step forward starts at the top row and a
step back at the bottom one.  The order is asked afresh every step, so
under `priority' the session just read may have moved by the next one;
that is the same trade `agent-shell-vertico-sidebar-jump-to-index'
makes.  OTHER-WINDOW displays the session in another window."
  (let ((order (agent-shell-vertico-sidebar--display-order)))
    (unless order
      (user-error "No agent-shell sessions"))
    (let* ((index (or (seq-position order
                                    (agent-shell-vertico--current-session)
                                    #'eq)
                      (if (> offset 0) -1 0)))
           (buffer (nth (mod (+ index offset) (length order)) order)))
      (if other-window
          (agent-shell-vertico-sidebar--jump-display-other-window buffer)
        (agent-shell-vertico-sidebar--jump-display buffer))
      (agent-shell-vertico-sidebar-refresh))))

;;;###autoload
(defun agent-shell-vertico-sidebar-next-session (&optional other-window)
  "Display the session on the row below this one in the sidebar.

Every live session counts, folded or not, and the bottom row wraps to
the top.  With OTHER-WINDOW, display the session in another window."
  (interactive "P")
  (agent-shell-vertico-sidebar--step-session 1 other-window))

;;;###autoload
(defun agent-shell-vertico-sidebar-previous-session (&optional other-window)
  "Display the session on the row above this one in the sidebar.

Every live session counts, folded or not, and the top row wraps to the
bottom.  With OTHER-WINDOW, display the session in another window."
  (interactive "P")
  (agent-shell-vertico-sidebar--step-session -1 other-window))

(defun agent-shell-vertico-sidebar--session-rows ()
  "Return (BUFFER . POSITION) for each session row, top to bottom."
  (seq-keep (pcase-lambda (`((,kind . ,node) . ,position))
              (and (eq kind 'session) (cons node position)))
            (agent-shell-vertico-sidebar--node-positions)))

(defun agent-shell-vertico-sidebar--visible-rows (rows window)
  "Return the ROWS whose first line WINDOW shows.

A key nobody can see is a key nobody can press: `read-key' blocks, so
the reader cannot scroll the sidebar to look for one.  Rows below the
window are therefore left unlabelled and counted in the prompt, the
same way the rows past the last key are.  Nothing scrolls, so a reader
who had scrolled the sidebar keeps their place and the labels appear
where they were already looking."
  (if (not (window-live-p window))
      rows
    (let* ((start (window-start window))
           ;; Counting lines rather than asking `window-end': the sidebar
           ;; sets `truncate-lines', so one buffer line is one screen
           ;; line and the count is exact.  `window-end' would also
           ;; report the whole buffer until a redisplay it cannot force
           ;; from here has happened.
           (end (save-excursion
                  (goto-char start)
                  (forward-line (window-body-height window))
                  (point))))
      (seq-filter (lambda (row) (and (>= (cdr row) start)
                                     (< (cdr row) end)))
                  rows))))

(defun agent-shell-vertico-sidebar--jump-prompt
    (labelled total &optional action)
  "Return the prompt for a jump over TOTAL sessions, LABELLED of them keyed.

ACTION is the description of a pending dispatch action, which the
prompt names in place of asking where to jump."
  (concat (if action
              (format "Session to %s" action)
            "Jump to session")
          (when (> total labelled)
            (format " (%d more, use agent-shell-vertico-switch)"
                    (- total labelled)))
          ": "))

(defun agent-shell-vertico-sidebar--row-end (start rows)
  "Return where the session row beginning at START ends.

ROWS are in ascending order, so the next row's start is this row's
end, and the last row ends where the list does."
  (or (seq-some (lambda (row) (and (> (cdr row) start) (cdr row))) rows)
      (point-max)))

(defun agent-shell-vertico-sidebar--dim-overlays (window rows labels)
  "Return the overlays a jump dims with, or nil when dimming is off.

WINDOW shows the sidebar, ROWS are every session row and LABELS the
keys drawn on them.  Two things go grey, and the list the reader is
reading is not one of them: every other window of WINDOW's frame, so
the sidebar is what stands out, and each row that LABELS gave no key,
because such a row is not one of the answers.

An overlay face takes precedence over the faces the text carries, so
one overlay a window and one a row is the whole answer."
  (when agent-shell-vertico-sidebar-jump-dim-others
    (append
     (mapcar
      (lambda (other)
        (let ((overlay (make-overlay (window-start other)
                                     (window-end other t)
                                     (window-buffer other))))
          (overlay-put overlay 'face
                       'agent-shell-vertico-sidebar-jump-dimmed)
          ;; A buffer shown twice must dim only in the other window.
          (overlay-put overlay 'window other)
          overlay))
      (seq-remove (lambda (other) (eq other window))
                  (window-list (window-frame window) 'no-minibuffer)))
     (mapcar
      (lambda (row)
        (let ((overlay (make-overlay
                        (cdr row)
                        (agent-shell-vertico-sidebar--row-end (cdr row) rows))))
          (overlay-put overlay 'face
                       'agent-shell-vertico-sidebar-jump-dimmed)
          overlay))
      (seq-remove (lambda (row) (rassq (car row) labels)) rows)))))

(defun agent-shell-vertico-sidebar--show-jump-labels (labels rows)
  "Draw each key in LABELS over its session's mark and return the overlays.

LABELS is an alist of key to session buffer and ROWS gives each buffer's
row start.  The key takes the mark's cell through a `display' property,
so the row keeps its width and nothing reflows.

The face goes on the overlay rather than into the string, as
`ace-window' does with `aw-leading-char-face': an overlay face beats
the icon font the mark carries, which a face inside the string could
not be relied on to do."
  (mapcar (pcase-lambda (`(,key . ,buffer))
            (let* ((start (cdr (assq buffer rows)))
                   (overlay (make-overlay start (1+ start))))
              (overlay-put overlay
                           'agent-shell-vertico-sidebar-jump-key key)
              (overlay-put overlay 'display (char-to-string key))
              (overlay-put overlay 'face
                           'agent-shell-vertico-sidebar-jump-key)
              ;; Above any dimming that reaches the same cell.
              (overlay-put overlay 'priority 100)
              overlay))
          labels))

(defun agent-shell-vertico-sidebar--read-jump-key (prompt)
  "Read one key with PROMPT."
  (read-key prompt))

(defun agent-shell-vertico-sidebar--read-jump-keys
    (labels labelled total &optional default-action)
  "Read which of LABELS to act on, and what to do with it.

LABELLED and TOTAL are how many sessions carry a key and how many there
are, which the prompt reports.  Reading loops: an action key from
`agent-shell-vertico-sidebar-jump-dispatch-alist' sets what the next
session key will do and asks again, `?' adds the list of actions above
the prompt, and a session key ends the read.  Return (BUFFER . ACTION),
where ACTION takes a session buffer.

DEFAULT-ACTION is what a session key resolves to absent an explicit
dispatch key, `--jump-display' unless the caller passes its own.  A
parent session with children is answered in two reads, one over the
parent rows and one over just that parent's children once it is
chosen; passing the first read's result back in as DEFAULT-ACTION for
the second is what keeps a dispatch key pressed before drilling in
\(kill, say\) aimed at the child eventually chosen rather than silently
falling back to a plain jump.

The labels stay drawn throughout, so choosing an action costs no
redraw, and the action itself is left to the caller to run once the
sidebar is back as it was."
  (let ((action nil)
        (help nil)
        (result nil))
    (while (not result)
      (let* ((key (agent-shell-vertico-sidebar--read-jump-key
                   (concat
                    (when help (agent-shell-vertico-sidebar--dispatch-help))
                    (agent-shell-vertico-sidebar--jump-prompt
                     labelled total (nth 2 action)))))
             (session (cdr (assq key labels))))
        (cond
         ;; A quit char never reaches here: `read-key' leaves it in
         ;; `quit-flag', which signals `quit' inside the read and the
         ;; caller's cleanup handles it.  This is for ESC, which does
         ;; arrive as an event, and costs nothing for C-g.
         ((memq key '(?\C-g ?\e)) (keyboard-quit))
         ;; A session key first, so a key that is both never leaves a
         ;; session unreachable.
         (session
          (setq result (cons session
                             (or (nth 1 action)
                                 default-action
                                 #'agent-shell-vertico-sidebar--jump-display))))
         ((eq key ??) (setq help t))
         ((assq key agent-shell-vertico-sidebar-jump-dispatch-alist)
          (setq action
                (assq key agent-shell-vertico-sidebar-jump-dispatch-alist)))
         (t (user-error "No session on %s" (single-key-description key))))))
    result))

(defun agent-shell-vertico-sidebar--read-child-jump-target
    (rows window parent-key parent children action)
  "Read which of PARENT or its CHILDREN to act on.

ROWS and WINDOW are as in `--read-jump-target'.  PARENT-KEY is the key
PARENT was already chosen by in the first read, kept live here so
choosing a session with children does not cost the ability to land on
the parent itself.  ACTION is the action already resolved for PARENT
in that first read, offered as the default here so a dispatch key
pressed before drilling in \(kill, say\) survives to whichever child is
chosen next instead of quietly falling back to a plain jump.

Return (cons RESULT OVERLAYS), RESULT being
`agent-shell-vertico-sidebar--read-jump-keys' own (BUFFER . ACTION) and
OVERLAYS the ones this read drew, for the caller to fold into its own
cleanup list."
  (let* ((child-rows (seq-filter (lambda (row) (memq (car row) children))
                                 rows))
         (child-keyed (agent-shell-vertico-sidebar--visible-rows
                       child-rows window))
         (labels (cons (cons parent-key parent)
                       (cl-mapcar (lambda (key row) (cons key (car row)))
                                  (remove parent-key
                                          agent-shell-vertico-sidebar-jump-keys)
                                  child-keyed)))
         (keyed (cons (assq parent rows) child-keyed))
         (overlays
          (append (agent-shell-vertico-sidebar--dim-overlays
                   window rows labels)
                  (agent-shell-vertico-sidebar--show-jump-labels
                   labels keyed))))
    (cons (agent-shell-vertico-sidebar--read-jump-keys
           labels (length labels) (1+ (length child-rows)) action)
          overlays)))

(defun agent-shell-vertico-sidebar--read-jump-target ()
  "Key the top-level sessions listed flat in the sidebar and read which.

A hidden sidebar is shown for the read and closed again after it.  A
grouped sidebar is drawn flat for the read, so a folded session has a
row too.  Every exit path renders again under the real grouping, which
is also what puts a sidebar shown on another frame back: the buffer is
shared, so the flat render reached that frame too.  The folds
themselves are never touched.

A session with live children is not enough to end the read: nesting
already puts a child's row right after its parent's in the flat
render, so `labels' only keys the rows with no parent \(see
`--parent-of'\), leaving every child dimmed like any other unlabelled
row.  Choosing a parent this way starts a second read, scoped to just
its own rows, via `--read-child-jump-target'.

Return (BUFFER . ACTION) from
`agent-shell-vertico-sidebar--read-jump-keys'.  The action is returned
rather than run, so it runs with the sidebar back as it was and a
window free for a prompt of its own."
  (let* ((existing (when-let* ((buffer (get-buffer "*Agent Shell Sessions*")))
                     (get-buffer-window buffer)))
         (window (or existing
                     (save-selected-window
                       (agent-shell-vertico-sidebar--display-buffer))))
         ;; `display-buffer-in-side-window' can decline.  Ask before
         ;; `window-buffer', whose answer for nil is the selected
         ;; window's buffer, so the failure would otherwise surface as a
         ;; render error about a buffer nobody named.
         (_ (unless (window-live-p window)
              (user-error "Cannot display the agent-shell sidebar")))
         (sidebar (window-buffer window))
         (overlays nil))
    (unwind-protect
        (with-current-buffer sidebar
          (let ((agent-shell-vertico-sidebar-group-by nil))
            (agent-shell-vertico-sidebar--render))
          ;; The keys are drawn over the marks, so the animation gives
          ;; the cells up for the read; the render below restores them.
          (agent-shell-vertico-sidebar--cancel-busy-refresh)
          (agent-shell-vertico-sidebar--clear-busy-overlays)
          (let* ((agent-shell-vertico-sidebar--jump-in-progress t)
                 (rows (agent-shell-vertico-sidebar--session-rows))
                 (roots (seq-remove
                         (lambda (row)
                           (agent-shell-vertico-sidebar--parent-of (car row)))
                         rows))
                 (keyed (agent-shell-vertico-sidebar--visible-rows
                         roots window))
                 (labels (cl-mapcar (lambda (key row) (cons key (car row)))
                                    agent-shell-vertico-sidebar-jump-keys
                                    keyed)))
            (setq overlays
                  (append
                   (agent-shell-vertico-sidebar--dim-overlays
                    window rows labels)
                   (agent-shell-vertico-sidebar--show-jump-labels
                    labels keyed)))
            (let* ((choice (agent-shell-vertico-sidebar--read-jump-keys
                            labels (length labels) (length roots)))
                   (children (agent-shell-vertico-sidebar--children-of
                              (car choice))))
              (if (null children)
                  choice
                (mapc #'delete-overlay overlays)
                (setq overlays nil)
                (let ((refined
                       (agent-shell-vertico-sidebar--read-child-jump-target
                        rows window (car (rassq (car choice) labels))
                        (car choice) children (cdr choice))))
                  (setq overlays (cdr refined))
                  (car refined))))))
      (mapc #'delete-overlay overlays)
      (unless existing
        (when (window-live-p window)
          (delete-window window)))
      (when (buffer-live-p sidebar)
        (with-current-buffer sidebar
          (agent-shell-vertico-sidebar--render))))))

;;;###autoload
(defun agent-shell-vertico-sidebar-jump-by-key (&optional other-window)
  "Jump to a session by the key drawn beside it, `ace-window' style.

The sessions are listed flat in the sidebar, each row's mark replaced
by one of `agent-shell-vertico-sidebar-jump-keys' in row order, and one
key is read: press a session's key and that session is displayed.  A
hidden sidebar is shown for the read and closed again after it; a
grouped one is grouped again after, its folds as they were.  The keys
follow the rows, so they are assigned afresh each time and read off the
sidebar rather than remembered.

Press `?' to list the actions in
`agent-shell-vertico-sidebar-jump-dispatch-alist', or an action's key
to do that to the next session chosen instead of displaying it, the way
`ace-window' dispatches on `aw-dispatch-alist'.

A session with a child \(a side conversation, see `agent-shell-side'\)
does not end the read: only sessions with no parent are keyed at
first, and choosing one with children starts a second read, dimmed
down to just that session and its children, its own key still live
for landing on it directly instead of a child.

Only the rows the sidebar window shows are keyed, and only as many as
there are keys.  Nothing scrolls, because the read cannot be
interrupted to scroll; the prompt counts whatever is left over, and
`agent-shell-vertico-switch' reaches those sessions.

A single live session is acted on without asking, which is why the
prefix argument has its own place here: with OTHER-WINDOW, display the
session in another window."
  (interactive "P")
  (let* ((buffers (seq-filter #'buffer-live-p (agent-shell-buffers)))
         (default (if other-window
                      #'agent-shell-vertico-sidebar--jump-display-other-window
                    #'agent-shell-vertico-sidebar--jump-display))
         (target
          (pcase (length buffers)
            (0 (user-error "No agent-shell sessions"))
            (1 (cons (car buffers) default))
            (_ (agent-shell-vertico-sidebar--read-jump-target)))))
    ;; A dispatched action replaces displaying the session, so the
    ;; prefix only decides where the default action puts it.
    (funcall (if (eq (cdr target)
                     #'agent-shell-vertico-sidebar--jump-display)
                 default
               (cdr target))
             (car target))
    (agent-shell-vertico-sidebar-refresh)))

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
  "Focus the visible sidebar, opening it when necessary.

Point lands on the row of the session the selected window showed, a
viewport counting as its session, and stays where it was when that
window showed none.  A folded project group holding that row is
unfolded.  Called from the sidebar, select the window used most
recently before it instead, leaving the sidebar open."
  (interactive)
  (let ((buffer (get-buffer "*Agent Shell Sessions*")))
    (if (and buffer (eq (window-buffer (selected-window)) buffer))
        (select-window (or (get-mru-window nil nil t)
                           (user-error "No other window to return to")))
      (let* ((session (agent-shell-vertico-sidebar--session-for-buffer
                       (window-buffer (selected-window))))
             (existing-window (and buffer (get-buffer-window buffer)))
             (window (or existing-window
                         (agent-shell-vertico-sidebar--display-buffer))))
        (when (and existing-window (window-live-p window))
          (with-current-buffer buffer
            (when (derived-mode-p 'agent-shell-vertico-sidebar-mode)
              (agent-shell-vertico-sidebar--render))))
        (select-window window)
        ;; After selecting, so the move is the window's point and not
        ;; only the buffer's.
        (when session
          (agent-shell-vertico-sidebar--reveal-session session))))))

(defun agent-shell-vertico-sidebar--reveal-session (session)
  "Move point to SESSION's row, unfolding its group if needed.

A child is drawn under its topmost live ancestor, whatever its own
directory or state, so the group to unfold is that ancestor's.  In the
state view that means its family's section (`--family-section') and the
rows past the section's limit."
  (let ((node (cons 'session session)))
    (unless (agent-shell-vertico-sidebar--goto-node node)
      (let ((top session))
        (while-let ((parent (agent-shell-vertico-sidebar--parent-of top)))
          (setq top parent))
        (pcase agent-shell-vertico-sidebar-group-by
          ('project
           (if (agent-shell-vertico-sidebar--pinned-p top)
               (agent-shell-vertico-sidebar--set-section-folded 'pinned nil)
             (when (hash-table-p
                    agent-shell-vertico-sidebar--expanded-projects)
               (puthash (agent-shell-vertico-sidebar--project-root top) t
                        agent-shell-vertico-sidebar--expanded-projects)))
           (agent-shell-vertico-sidebar--render)
           (agent-shell-vertico-sidebar--goto-node node))
          ('state
           (let ((section
                  (agent-shell-vertico-sidebar--family-section top)))
             (agent-shell-vertico-sidebar--set-section-folded section nil)
             (cl-pushnew section agent-shell-vertico-sidebar--open-tails)
             (agent-shell-vertico-sidebar--render)
             (agent-shell-vertico-sidebar--goto-node node))))))))

(defun agent-shell-vertico-sidebar--window-configuration-change ()
  "Repair visible sidebar display settings and stop timers when hidden.
A repaired fringe or margin narrows the text area, so every frame
showing the sidebar is offered to the resize callback.  The offer is not
redundant: Emacs records window sizes after this hook has run, so
`window-size-change-functions' never sees a width changed here.  Every
frame is offered because the hook is called with no frame to name."
  (when-let ((sidebar (get-buffer "*Agent Shell Sessions*")))
    (with-current-buffer sidebar
      (if (agent-shell-vertico-sidebar--sidebar-visible-p sidebar)
          (progn
            (when (agent-shell-vertico-sidebar--apply-marker-space)
              (dolist (window (get-buffer-window-list sidebar nil t))
                (agent-shell-vertico-sidebar--window-size-change
                 (window-frame window))))
            (agent-shell-vertico-sidebar--ensure-age-refresh)
            (agent-shell-vertico-sidebar--ensure-busy-refresh)
            (agent-shell-vertico-sidebar--ensure-background-refresh))
        (agent-shell-vertico-sidebar--cancel-refresh)
        (agent-shell-vertico-sidebar--cancel-resize)
        (agent-shell-vertico-sidebar--cancel-age-refresh)
        (agent-shell-vertico-sidebar--cancel-busy-refresh)
        (agent-shell-vertico-sidebar--cancel-background-refresh)))))

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
(add-hook 'window-buffer-change-functions
          #'agent-shell-vertico-sidebar--window-selection-change)
(add-function :after after-focus-change-function
              #'agent-shell-vertico-sidebar--focus-change)
(add-hook 'window-size-change-functions
          #'agent-shell-vertico-sidebar--window-size-change)
(add-hook 'window-configuration-change-hook
          #'agent-shell-vertico-sidebar--window-configuration-change)

(provide 'agent-shell-vertico-sidebar)

;;; agent-shell-vertico-sidebar.el ends here
