;;; agent-shell-vertico-prompt-queue.el --- Pending prompt completion -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Bill and contributors

;; Author: Bill
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (agent-shell "0.63.5") (marginalia "2.1"))
;; Keywords: convenience, tools
;; URL: https://github.com/liaowang11/agent-shell-vertico

;;; Commentary:

;; Completion over the prompts queued in the current `agent-shell'
;; session, with annotations and Embark actions.
;;
;; `agent-shell' queues a prompt whenever the shell is busy and sends
;; the queue on once the agent is free.  Its own selection UI is a plain
;; `completing-read' with no completion category, so the queue carries
;; no annotations and Embark has nothing to act on.  This module offers
;; the same queue as an annotated category, and dispatches every change
;; through `agent-shell''s own commands.
;;
;; The queue moves on its own: the agent takes the head of it whenever
;; it finishes, and each removal shifts every later prompt up.  A
;; candidate's position is therefore only a snapshot, and every action
;; re-resolves its prompt against the queue as it stands before touching
;; anything.

;;; Code:

(require 'agent-shell)
(require 'agent-shell-vertico)
(require 'map)
(require 'marginalia)
(require 'mule-util)
(require 'seq)
(require 'subr-x)

(defvar embark-default-action-overrides)
(defvar embark-keymap-alist)
(defvar embark-quit-after-action)

(declare-function agent-shell--shell-buffer "agent-shell" (&rest arguments))
(declare-function agent-shell-prompt-queue-edit
                  "agent-shell-prompt-queue" (index))
(declare-function agent-shell-prompt-queue-steer
                  "agent-shell-prompt-queue" (index))
(declare-function agent-shell-prompt-queue-remove
                  "agent-shell-prompt-queue" (&optional remove-index))
(declare-function agent-shell-prompt-queue-resume
                  "agent-shell-prompt-queue" ())

(defconst agent-shell-vertico-prompt-queue--candidate-width 80
  "Columns a candidate may use for its prompt line.
Matches the width `agent-shell' uses when it lists the queue in the
shell buffer.")

(defconst agent-shell-vertico-prompt-queue--buffer
  "*Agent Shell Pending Prompt*"
  "Buffer showing one pending prompt in full.")

(defvar agent-shell-vertico-prompt-queue--last-candidates nil
  "Candidates offered by the last read.
Consulted when a candidate reaches an action stripped of the text
property carrying its record.")

(defun agent-shell-vertico-prompt-queue--shell-buffer ()
  "Return the `agent-shell' session the current buffer belongs to.
Resolved through agent-shell's own `agent-shell--shell-buffer', so a
viewport buffer resolves to the shell behind it, a shell buffer to
itself, and any other buffer to the current project's shell."
  (let ((buffer (agent-shell--shell-buffer :no-create t)))
    (unless (buffer-live-p buffer)
      (user-error "No agent-shell session for this buffer"))
    (agent-shell-vertico--ensure-shell-buffer buffer)))

(defun agent-shell-vertico-prompt-queue--pending (buffer)
  "Return the prompts queued in BUFFER."
  (map-elt (agent-shell-vertico--state buffer) :pending-prompts))

(defun agent-shell-vertico-prompt-queue--first-line (text)
  "Return TEXT's first nonblank line, truncated to fit a candidate."
  (truncate-string-to-width
   (or (car (split-string text "\n" t)) "")
   agent-shell-vertico-prompt-queue--candidate-width 0 nil "…"))

(defun agent-shell-vertico-prompt-queue--remainder (text)
  "Return TEXT after its first line, as one line.
Newlines become spaces so the annotation shows as much of the prompt as
its column has room for, rather than stopping at the first line break."
  (string-join (cdr (split-string text "\n" t "[ \t]+")) " "))

(defun agent-shell-vertico-prompt-queue--size (record)
  "Return RECORD's size column, empty unless the prompt is multi-line."
  (if-let* ((text (map-elt record :text))
            (lines (length (split-string text "\n" t)))
            ((> lines 1)))
      (format "%d lines" lines)
    ""))

(defun agent-shell-vertico-prompt-queue--busy-p (buffer)
  "Return non-nil when BUFFER's agent is working on a prompt."
  (equal (agent-shell-vertico--status buffer) "Working"))

(defun agent-shell-vertico-prompt-queue--detail (record)
  "Return RECORD's description column.
A prompt is described by whatever of it the candidate could not show; a
queue-wide entry by what it does to the queue."
  (let ((buffer (map-elt record :buffer)))
    (pcase (map-elt record :action)
      ('resume
       (if (agent-shell-vertico-prompt-queue--busy-p buffer)
           "shell busy, prompts auto-resume when ready"
         "send the next pending prompt"))
      ('remove-all
       (let ((count (length (agent-shell-vertico-prompt-queue--pending
                             buffer))))
         (format "drop %d pending prompt%s" count
                 (if (= count 1) "" "s"))))
      (_ (agent-shell-vertico-prompt-queue--remainder
          (map-elt record :text))))))

(defun agent-shell-vertico-prompt-queue--suffix (record)
  "Return the annotation suffix for RECORD."
  (let ((size (agent-shell-vertico-prompt-queue--size record))
        (detail (agent-shell-vertico-prompt-queue--detail record)))
    (marginalia--fields
     (size :truncate 10 :face 'marginalia-type)
     (detail :truncate 0.8 :face 'marginalia-documentation))))

(defun agent-shell-vertico-prompt-queue--label (record)
  "Return the text shown for RECORD in completion."
  (pcase (map-elt record :action)
    ('resume "[Resume queue]")
    ('remove-all "[Remove all]")
    (_ (agent-shell-vertico-prompt-queue--first-line
        (map-elt record :text)))))

(defun agent-shell-vertico-prompt-queue--candidate (record index)
  "Return a completion candidate for RECORD at INDEX in the list.
INDEX only keys the candidate: two identical prompts show the same text
and completion would otherwise collapse them into one."
  (let ((candidate (concat (agent-shell-vertico-prompt-queue--label record)
                           (agent-shell-vertico--candidate-key index))))
    (put-text-property 0 (length candidate)
                       'agent-shell-vertico-prompt-queue-record
                       record candidate)
    candidate))

(defun agent-shell-vertico-prompt-queue--records (buffer)
  "Return one record per pending prompt in BUFFER, then the queue actions."
  (when-let* ((pending (agent-shell-vertico-prompt-queue--pending buffer)))
    (append
     (seq-map-indexed
      (lambda (text index)
        (list (cons :buffer buffer)
              (cons :index index)
              (cons :text text)))
      pending)
     (list (list (cons :buffer buffer) (cons :action 'resume))
           (list (cons :buffer buffer) (cons :action 'remove-all))))))

(defun agent-shell-vertico-prompt-queue--candidates (buffer)
  "Return completion candidates for BUFFER's prompt queue.
The pending prompts come first, in queue order, so the preselected
candidate is never one of the queue-wide entries that follow them."
  (setq agent-shell-vertico-prompt-queue--last-candidates
        (seq-map-indexed #'agent-shell-vertico-prompt-queue--candidate
                         (agent-shell-vertico-prompt-queue--records buffer))))

(defun agent-shell-vertico-prompt-queue--record-from-candidate (candidate)
  "Return the queue record CANDIDATE carries."
  (when (and (stringp candidate) (not (string-empty-p candidate)))
    (or (get-text-property
         0 'agent-shell-vertico-prompt-queue-record candidate)
        (when-let* ((known
                     (assoc-string
                      candidate
                      agent-shell-vertico-prompt-queue--last-candidates)))
          (get-text-property
           0 'agent-shell-vertico-prompt-queue-record known)))))

(defun agent-shell-vertico-prompt-queue--affixate (candidates)
  "Add annotation suffixes to CANDIDATES."
  (mapcar (lambda (candidate)
            (list candidate ""
                  (or (agent-shell-vertico-prompt-queue--annotate candidate)
                      "")))
          candidates))

(defun agent-shell-vertico-prompt-queue--annotate (candidate)
  "Marginalia annotator for CANDIDATE in category `agent-shell-prompt-queue'.

Renders through `agent-shell-vertico-prompt-queue--suffix', which the
completion table's affixation function also uses, so the two cannot
drift apart."
  (when-let* ((record
               (agent-shell-vertico-prompt-queue--record-from-candidate
                candidate)))
    (agent-shell-vertico-prompt-queue--suffix record)))

(add-to-list 'marginalia-annotators
             '(agent-shell-prompt-queue
               agent-shell-vertico-prompt-queue--annotate none))

(defconst agent-shell-vertico-prompt-queue--narrow-keys
  '((?p . "Prompt")
    (?a . "Queue action")
    (?m . "Multi-line"))
  "Narrowing keys offered for a session's prompt queue.

No agent keys: a queue belongs to one session, and so to one agent.")

(defun agent-shell-vertico-prompt-queue--narrow-p (key candidate _context)
  "Return non-nil when queue CANDIDATE belongs to narrowing KEY.
A nil KEY is no narrowing at all, so every candidate belongs to it."
  (if (null key)
      t
    (when-let* ((record
                 (agent-shell-vertico-prompt-queue--record-from-candidate
                  candidate)))
      (pcase key
        (?p (null (map-elt record :action)))
        (?a (and (map-elt record :action) t))
        (?m (when-let* ((text (map-elt record :text)))
              (> (length (split-string text "\n" t)) 1)))))))

(defun agent-shell-vertico-prompt-queue--table (candidates)
  "Return a completion table over CANDIDATES.
Sorting is left alone: the list is already in queue order."
  (lambda (string pred action)
    (if (eq action 'metadata)
        `(metadata
          (category . agent-shell-prompt-queue)
          (affixation-function
           . ,#'agent-shell-vertico-prompt-queue--affixate)
          (display-sort-function . ,#'identity)
          (cycle-sort-function . ,#'identity))
      (complete-with-action action candidates string pred))))

(defun agent-shell-vertico-prompt-queue--completing-read (prompt candidates)
  "Read one of CANDIDATES with PROMPT and return its record."
  (let ((selection
         ;; Keep the text properties on the returned candidate so the
         ;; record comes back directly, rather than through a lookup by
         ;; display text that repeated prompts make ambiguous.
         (let ((minibuffer-allow-text-properties t))
           (completing-read
            prompt
            (agent-shell-vertico-prompt-queue--table candidates)
            nil t))))
    (or (agent-shell-vertico-prompt-queue--record-from-candidate selection)
        (user-error "Prompt no longer pending"))))

(defvar agent-shell-vertico-prompt-queue-read-function
  #'agent-shell-vertico-prompt-queue--completing-read
  "Function used to read one pending prompt candidate.
It receives a prompt and a list of candidates, and returns the record
of the one chosen.  `agent-shell-vertico-consult' replaces it with a
reader that previews the prompt under point.")

(defun agent-shell-vertico-prompt-queue--read (prompt candidates)
  "Read one of CANDIDATES with PROMPT."
  (funcall agent-shell-vertico-prompt-queue-read-function prompt candidates))

(defun agent-shell-vertico-prompt-queue--session (record)
  "Return RECORD's live `agent-shell' session buffer."
  (agent-shell-vertico--ensure-shell-buffer
   (or (map-elt record :buffer)
       (user-error "Candidate belongs to no session"))))

(defun agent-shell-vertico-prompt-queue--prompt-p (record)
  "Return non-nil when RECORD names a pending prompt.
A queue-wide entry is reported and skipped rather than refused, because
`embark-act-all' runs over every candidate and an error would abandon
the prompts after it."
  (cond
   ((null record) (ignore (message "No pending prompt here")))
   ((map-elt record :action) (ignore (message "Not a pending prompt")))
   (t record)))

(defun agent-shell-vertico-prompt-queue--resolve-index (record)
  "Return RECORD's position in its session's queue as it stands now.
The recorded position is kept when the prompt is still there; otherwise
the prompt is searched for, since the agent may have taken earlier
prompts, or earlier removals may have moved this one up."
  (let* ((pending (agent-shell-vertico-prompt-queue--pending
                   (map-elt record :buffer)))
         (text (map-elt record :text))
         (index (map-elt record :index)))
    (cond
     ((and index (equal (nth index pending) text)) index)
     ((seq-position pending text #'equal))
     (t (user-error "Prompt no longer pending")))))

(defun agent-shell-vertico-prompt-queue--act-edit (record)
  "Edit RECORD's prompt through `agent-shell-prompt-queue-edit'."
  (when (agent-shell-vertico-prompt-queue--prompt-p record)
    (with-current-buffer (agent-shell-vertico-prompt-queue--session record)
      (agent-shell-prompt-queue-edit
       (agent-shell-vertico-prompt-queue--resolve-index record)))))

(defun agent-shell-vertico-prompt-queue--act-remove (record)
  "Remove RECORD's prompt through `agent-shell-prompt-queue-remove'."
  (when (agent-shell-vertico-prompt-queue--prompt-p record)
    (with-current-buffer (agent-shell-vertico-prompt-queue--session record)
      (agent-shell-prompt-queue-remove
       (agent-shell-vertico-prompt-queue--resolve-index record)))))

(defun agent-shell-vertico-prompt-queue--act-inject (record)
  "Deliver RECORD's prompt to the turn already running.

`agent-shell-prompt-queue-steer' takes the prompt out of the queue
itself, and only once the agent has taken it: an agent that declines,
or one that never advertised mid-turn steering, leaves the prompt
pending rather than losing it.

Steering is newer than the agent-shell version this package requires,
so an older one is reported rather than left to signal a void function."
  (when (agent-shell-vertico-prompt-queue--prompt-p record)
    (unless (fboundp 'agent-shell-prompt-queue-steer)
      (user-error "This agent-shell cannot steer prompts mid-turn"))
    (with-current-buffer (agent-shell-vertico-prompt-queue--session record)
      (agent-shell-prompt-queue-steer
       (agent-shell-vertico-prompt-queue--resolve-index record)))))

(defun agent-shell-vertico-prompt-queue--act-copy (record)
  "Copy RECORD's whole prompt to the kill ring."
  (when (agent-shell-vertico-prompt-queue--prompt-p record)
    (kill-new (map-elt record :text))
    (message "Copied pending prompt")))

(defun agent-shell-vertico-prompt-queue--text (record)
  "Return the text RECORD shows in full."
  (or (map-elt record :text)
      (agent-shell-vertico-prompt-queue--detail record)))

(defun agent-shell-vertico-prompt-queue--render (record)
  "Fill `agent-shell-vertico-prompt-queue--buffer' with RECORD's text."
  (let ((buffer (get-buffer-create
                 agent-shell-vertico-prompt-queue--buffer)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (agent-shell-vertico-prompt-queue--text record))
        (goto-char (point-min)))
      (unless (derived-mode-p 'special-mode)
        (special-mode)))
    buffer))

(defun agent-shell-vertico-prompt-queue--act-view (record)
  "Show RECORD's prompt in full.
The candidate shows one line and the annotation one column of the rest,
so a long prompt is only readable in a buffer of its own."
  (when record
    (display-buffer (agent-shell-vertico-prompt-queue--render record))))

(defun agent-shell-vertico-prompt-queue--act-resume (record)
  "Resume RECORD's session queue."
  (with-current-buffer (agent-shell-vertico-prompt-queue--session record)
    (agent-shell-prompt-queue-resume)))

(defun agent-shell-vertico-prompt-queue--act-remove-all (record)
  "Remove every prompt queued in RECORD's session."
  (with-current-buffer (agent-shell-vertico-prompt-queue--session record)
    (agent-shell-prompt-queue-remove nil)))

(defun agent-shell-vertico-prompt-queue--act (record)
  "Run RECORD's own action: edit a prompt, or act on the whole queue."
  (pcase (map-elt record :action)
    ('resume (agent-shell-vertico-prompt-queue--act-resume record))
    ('remove-all (agent-shell-vertico-prompt-queue--act-remove-all record))
    (_ (agent-shell-vertico-prompt-queue--act-edit record))))

(defun agent-shell-vertico-prompt-queue-embark-act (candidate)
  "Run CANDIDATE's own action."
  (agent-shell-vertico-prompt-queue--act
   (agent-shell-vertico-prompt-queue--record-from-candidate candidate)))

(defun agent-shell-vertico-prompt-queue-embark-edit (candidate)
  "Edit pending prompt CANDIDATE."
  (agent-shell-vertico-prompt-queue--act-edit
   (agent-shell-vertico-prompt-queue--record-from-candidate candidate)))

(defun agent-shell-vertico-prompt-queue-embark-remove (candidate)
  "Remove pending prompt CANDIDATE."
  (agent-shell-vertico-prompt-queue--act-remove
   (agent-shell-vertico-prompt-queue--record-from-candidate candidate)))

(defun agent-shell-vertico-prompt-queue-embark-inject (candidate)
  "Inject pending prompt CANDIDATE into the running turn."
  (agent-shell-vertico-prompt-queue--act-inject
   (agent-shell-vertico-prompt-queue--record-from-candidate candidate)))

(defun agent-shell-vertico-prompt-queue-embark-copy (candidate)
  "Copy pending prompt CANDIDATE to the kill ring."
  (agent-shell-vertico-prompt-queue--act-copy
   (agent-shell-vertico-prompt-queue--record-from-candidate candidate)))

(defun agent-shell-vertico-prompt-queue-embark-view (candidate)
  "Show pending prompt CANDIDATE in full."
  (agent-shell-vertico-prompt-queue--act-view
   (agent-shell-vertico-prompt-queue--record-from-candidate candidate)))

(defvar-keymap agent-shell-vertico-prompt-queue-embark-map
  :doc "Embark actions for `agent-shell' pending prompts."
  "e" #'agent-shell-vertico-prompt-queue-embark-edit
  ;; `i' is the key agent-shell gives Inject in the queue's own button row.
  "i" #'agent-shell-vertico-prompt-queue-embark-inject
  "x" #'agent-shell-vertico-prompt-queue-embark-remove
  "w" #'agent-shell-vertico-prompt-queue-embark-copy
  "v" #'agent-shell-vertico-prompt-queue-embark-view)

;;;###autoload
(defun agent-shell-vertico-prompt-queue-setup-embark ()
  "Register pending prompt candidates and actions with Embark.
Call this only after Embark is loaded."
  (interactive)
  (add-to-list 'embark-keymap-alist
               '(agent-shell-prompt-queue
                 agent-shell-vertico-prompt-queue-embark-map))
  (add-to-list 'embark-default-action-overrides
               '(agent-shell-prompt-queue
                 . agent-shell-vertico-prompt-queue-embark-act))
  ;; Viewing a prompt is a peek, so keep the completion session alive
  ;; and let the next candidate be viewed too.  `embark-quit-after-action'
  ;; is a boolean until someone configures a command of their own, so
  ;; carry whatever it says now over to the default entry.
  (unless (consp embark-quit-after-action)
    (setq embark-quit-after-action
          (list (cons t embark-quit-after-action))))
  (setf (alist-get 'agent-shell-vertico-prompt-queue-embark-view
                   embark-quit-after-action)
        nil))

;;;###autoload
(defun agent-shell-vertico-prompt-queue ()
  "Act on a prompt queued in the current `agent-shell' session.

Lists the session's pending prompts, then `[Resume queue]' and
`[Remove all]'.  Choosing a prompt edits it; choosing one of the
queue-wide entries resumes or empties the queue.  With Embark, a prompt
also takes `e' to edit, `i' to inject into the running turn, `x' to
remove, `w' to copy, and `v' to read in full.

Works from the shell buffer, from its viewport, and from any other
buffer in a project that has a shell."
  (interactive)
  (let* ((buffer (agent-shell-vertico-prompt-queue--shell-buffer))
         (candidates (agent-shell-vertico-prompt-queue--candidates buffer)))
    (unless candidates
      (user-error "No pending prompts"))
    (agent-shell-vertico-prompt-queue--act
     (agent-shell-vertico-prompt-queue--read "Pending prompt: "
                                             candidates))))

(provide 'agent-shell-vertico-prompt-queue)

;;; agent-shell-vertico-prompt-queue.el ends here
