;;; agent-shell-vertico-resume.el --- Enriched agent-shell session picker -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Bill and contributors

;; Author: Bill
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (agent-shell "0.63.5") (marginalia "2.1"))
;; Keywords: convenience, tools
;; URL: https://github.com/liaowang11/agent-shell-vertico

;;; Commentary:

;; Annotations for the session picker `agent-shell' opens when
;; `agent-shell-session-strategy' is `prompt'.
;;
;; That picker lists a session's directory, title and date, which is all
;; `session/list' reports.  Every session it lists that this machine also
;; wrote a transcript for is joined to that transcript by session ID, and
;; annotated with the agent, the model and the first thing the session was
;; asked, plus whether a shell already holds it.
;;
;; Loading `agent-shell-vertico-consult' on top adds a live preview of the
;; joined transcript as the reader moves through the list.

;;; Code:

(require 'agent-shell)
(require 'agent-shell-vertico)
(require 'agent-shell-vertico-transcript)
(require 'cl-lib)
(require 'map)
(require 'marginalia)
(require 'seq)
(require 'subr-x)

(declare-function agent-shell-cwd "agent-shell" ())

;; No value: `agent-shell' installs its own default when it loads, and a
;; `defvar' with one here would pre-empt that.
(defvar agent-shell-session-choices-function)

(defgroup agent-shell-vertico-resume nil
  "Session picker enrichment for `agent-shell'."
  :group 'agent-shell-vertico)

(defconst agent-shell-vertico-resume--annotation-columns
  '((status . 10)
    (agent . 10)
    (model . 0.2)
    (message . 0.5))
  "Truncation width of each annotation column, in display order.

A float is a fraction of `marginalia-field-width'.  The first message of
the session takes the widest fraction: the picker's own columns already
carry the title and the date, so what the session was asked for is the
column that tells two same-day sessions apart.")

(defvar agent-shell-vertico-resume-read-choice-function
  #'agent-shell-vertico-resume--completing-read-choice
  "Function reading one choice from the `agent-shell' session picker.

Called with a prompt, the annotated candidates, and the default
candidate, and must return one of the candidates.  Loading
`agent-shell-vertico-consult' replaces the default with a reader that
previews each session's transcript.")

(defvar agent-shell-vertico-resume--choices nil
  "Choices the picker is offering, as an alist of label to token.

Bound while the picker runs.  The reader looks a label up here to find
the session it stands for, because `completing-read' is handed the
labels alone.")

(defvar agent-shell-vertico-resume--index nil
  "Table of session ID to transcript record for the choices being offered.
Bound while the picker runs.")

;;; Reading sessions and their transcripts

(defun agent-shell-vertico-resume--record-index (records)
  "Return a table of session ID to transcript record, built from RECORDS.

RECORDS arrive newest first and a session can be resumed more than once,
so the first record for a session ID is the one kept."
  (let ((index (make-hash-table :test #'equal)))
    (dolist (record records)
      (when-let* ((session-id
                   (agent-shell-vertico-transcript-record-session-id record)))
        (unless (gethash session-id index)
          (puthash session-id record index))))
    index))

(defun agent-shell-vertico-resume--index-for-directory (directory)
  "Return the transcript index for the project DIRECTORY belongs to.

A store that cannot be read costs the picker its annotations and nothing
else, so the session list still works when the transcript configuration
is broken or the store has gone missing."
  (condition-case error
      (agent-shell-vertico-resume--record-index
       (agent-shell-vertico-transcript--records-for-project
        (or (let ((default-directory directory))
              (agent-shell-vertico-transcript--current-project-root))
            directory)))
    (error
     (message "agent-shell-vertico: no transcripts to annotate with (%s)"
              (error-message-string error))
     (make-hash-table :test #'equal))))

;;; Candidates

(defun agent-shell-vertico-resume--candidate (label session record)
  "Return LABEL carrying its ACP SESSION and transcript RECORD.

Both travel with the candidate as text properties, so the annotation and
the preview read them without the picker still being on the stack.  A
choice that starts a new shell has no session and is left as it is."
  (let ((candidate (copy-sequence label)))
    (when session
      (put-text-property 0 (length candidate)
                         'agent-shell-vertico-resume-session session candidate)
      (when record
        (put-text-property 0 (length candidate)
                           'agent-shell-vertico-transcript-record record
                           candidate)
        (put-text-property 0 (length candidate)
                           'agent-shell-vertico-transcript-file
                           (agent-shell-vertico-transcript-record-file record)
                           candidate)))
    candidate))

(defun agent-shell-vertico-resume--candidate-session (candidate)
  "Return the ACP session CANDIDATE stands for, or nil."
  (when (and (stringp candidate) (> (length candidate) 0))
    (get-text-property 0 'agent-shell-vertico-resume-session candidate)))

(defun agent-shell-vertico-resume--candidate-record (candidate)
  "Return the transcript record CANDIDATE was joined to, or nil."
  (when (and (stringp candidate) (> (length candidate) 0))
    (get-text-property 0 'agent-shell-vertico-transcript-record candidate)))

(defun agent-shell-vertico-resume--session-token (token)
  "Return TOKEN when it names a resumable session.
The picker's other tokens are keywords standing for a new shell."
  (unless (keywordp token) token))

(defun agent-shell-vertico-resume--candidates (labels)
  "Return LABELS as candidates carrying their session and transcript."
  (mapcar
   (lambda (label)
     (let* ((session
             (agent-shell-vertico-resume--session-token
              (cdr (assoc label agent-shell-vertico-resume--choices))))
            (session-id (and session (map-elt session 'sessionId))))
       (agent-shell-vertico-resume--candidate
        label session
        (and session-id
             agent-shell-vertico-resume--index
             (gethash session-id agent-shell-vertico-resume--index)))))
   labels))

;;; Annotation

(defun agent-shell-vertico-resume--column-width (name)
  "Return the truncation width of the annotation column NAME."
  (alist-get name agent-shell-vertico-resume--annotation-columns))

(defun agent-shell-vertico-resume--status (session)
  "Return whether a shell already holds SESSION.
Resuming a session a shell is already showing starts a second shell on
it, so the picker says which ones are taken."
  (if (agent-shell-vertico--live-session-buffer (map-elt session 'sessionId))
      "Live"
    "Resumable"))

(defun agent-shell-vertico-resume--suffix (candidate)
  "Return the annotation columns for CANDIDATE, or nil when it has no session.

A session this machine has no transcript for still annotates: it can be
resumed, and the empty columns are what say the conversation is not
here."
  (when-let* ((session (agent-shell-vertico-resume--candidate-session
                        candidate)))
    (let ((record (agent-shell-vertico-resume--candidate-record candidate)))
      (agent-shell-vertico-transcript--fields
       (list
        (list (agent-shell-vertico-resume--status session)
              (agent-shell-vertico-resume--column-width 'status)
              'marginalia-type)
        (list (or (and record
                       (agent-shell-vertico-transcript-record-agent record))
                  "-")
              (agent-shell-vertico-resume--column-width 'agent)
              'marginalia-value)
        (list (or (and record
                       (agent-shell-vertico-transcript-record-model record))
                  "-")
              (agent-shell-vertico-resume--column-width 'model)
              'marginalia-value)
        (list (or (and record
                       (agent-shell-vertico-transcript-record-preview record))
                  "-")
              (agent-shell-vertico-resume--column-width 'message)
              'marginalia-documentation))))))

(defun agent-shell-vertico-resume--annotate (candidate)
  "Marginalia annotator for CANDIDATE in category `agent-shell-session-choice'.

Renders through `agent-shell-vertico-resume--suffix', which the
completion table's affixation function also uses, so the two cannot
drift apart."
  (agent-shell-vertico-resume--suffix candidate))

(defun agent-shell-vertico-resume--affixate (candidates)
  "Add the annotation suffix to CANDIDATES."
  (mapcar (lambda (candidate)
            (list candidate
                  ""
                  (or (agent-shell-vertico-resume--suffix candidate) "")))
          candidates))

(add-to-list 'marginalia-annotators
             '(agent-shell-session-choice
               agent-shell-vertico-resume--annotate none))

;;; Reading

(defun agent-shell-vertico-resume--table (candidates)
  "Return a completion table over the picker's CANDIDATES.

The order is the picker's own, newest session first, so both sort
functions leave it alone."
  (lambda (string predicate action)
    (if (eq action 'metadata)
        `(metadata
          (category . agent-shell-session-choice)
          (affixation-function . ,#'agent-shell-vertico-resume--affixate)
          (display-sort-function . ,#'identity)
          (cycle-sort-function . ,#'identity))
      (complete-with-action action candidates string predicate))))

(defun agent-shell-vertico-resume--completing-read-choice
    (prompt candidates default)
  "Read one of CANDIDATES with PROMPT, defaulting to DEFAULT.

Calls `completing-read-function' rather than `completing-read': the
picker has replaced that function with the reader now running, and
calling it here would loop."
  (funcall completing-read-function
           prompt
           (agent-shell-vertico-resume--table candidates)
           nil t nil nil default))

(defun agent-shell-vertico-resume--ours-p (candidates)
  "Return non-nil when CANDIDATES are the choices the picker recorded."
  (and candidates
       agent-shell-vertico-resume--choices
       (seq-every-p (lambda (candidate)
                      (assoc candidate agent-shell-vertico-resume--choices))
                    candidates)))

(defun agent-shell-vertico-resume--read
    (inner prompt collection &optional predicate require-match initial-input
           hist default inherit-input-method)
  "Read the picker's own choice with annotations, or delegate to INNER.

INNER is the `completing-read' the picker would have called.  PROMPT,
COLLECTION, PREDICATE, REQUIRE-MATCH, INITIAL-INPUT, HIST, DEFAULT and
INHERIT-INPUT-METHOD are its arguments.

Only the prompt offering the recorded choices is enriched.  The picker
reads other things while this replacement is installed, such as which
shell buffer to switch to, and those have to read as they always did."
  (let ((candidates (all-completions "" collection predicate)))
    (if (agent-shell-vertico-resume--ours-p candidates)
        (funcall agent-shell-vertico-resume-read-choice-function
                 prompt
                 (agent-shell-vertico-resume--candidates candidates)
                 default)
      (funcall inner prompt collection predicate require-match initial-input
               hist default inherit-input-method))))

(defun agent-shell-vertico-resume--choices-function (user-function)
  "Return a session choices function recording what the picker offers.

USER-FUNCTION is whatever the user configured, and still decides which
choices are offered and how they are labelled.  What it returns is
recorded in `agent-shell-vertico-resume--choices', which is how the
reader knows what a label stands for."
  (lambda (choices)
    (let ((result (if user-function (funcall user-function choices) choices)))
      (setq agent-shell-vertico-resume--choices result)
      result)))

(defun agent-shell-vertico-resume--select-session (original acp-sessions)
  "Run the session picker ORIGINAL over ACP-SESSIONS, annotated.

ORIGINAL keeps deciding what a choice means, including the ones that
start a new shell or switch to an existing one.  This only replaces how
the choice is read."
  (if (not acp-sessions)
      (funcall original acp-sessions)
    (let* ((agent-shell-vertico-resume--index
            (agent-shell-vertico-resume--index-for-directory
             (agent-shell-cwd)))
           (agent-shell-vertico-resume--choices nil)
           (agent-shell-session-choices-function
            (agent-shell-vertico-resume--choices-function
             agent-shell-session-choices-function))
           (inner (symbol-function 'completing-read)))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest arguments)
                   (apply #'agent-shell-vertico-resume--read
                          inner arguments))))
        (funcall original acp-sessions)))))

;;;###autoload
(defun agent-shell-vertico-resume-setup ()
  "Annotate the session picker `agent-shell' opens when it lists sessions.

The picker itself offers no way in, so this advises it."
  (interactive)
  (advice-add 'agent-shell--prompt-select-session :around
              #'agent-shell-vertico-resume--select-session))

(provide 'agent-shell-vertico-resume)

;;; agent-shell-vertico-resume.el ends here
