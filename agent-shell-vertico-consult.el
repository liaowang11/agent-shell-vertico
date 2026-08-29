;;; agent-shell-vertico-consult.el --- Live transcript recall with Consult -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Bill and contributors

;; Author: Bill
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (agent-shell "0.63.5") (consult "2.4") (marginalia "2.1"))
;; Keywords: convenience, tools
;; URL: https://github.com/liaowang11/agent-shell-vertico

;;; Commentary:

;; Live, aggregated `rg' search over current `agent-shell' transcript
;; files, live preview of the prompts queued in a session, and live
;; preview of the transcripts behind `agent-shell''s session picker.
;;
;; Also makes Consult's line search usable inside a live shell buffer,
;; where agent-shell's collapsed blocks otherwise arrive blank.

;;; Code:

(require 'agent-shell-vertico-prompt-queue)
(require 'agent-shell-vertico-resume)
(require 'agent-shell-vertico-transcript)
(require 'agent-shell-vertico)
(require 'consult)
(require 'map)
(require 'subr-x)

(declare-function consult--buffer-preview "consult" ())
(declare-function consult--file-action "consult" (file))
(declare-function consult--jump-preview "consult" ())
(declare-function consult--lookup-member "consult" (&rest args))
(declare-function consult--marker-from-line-column
                  "consult" (buffer line column))
(declare-function consult--process-collection "consult" (builder &rest props))
(declare-function consult--read "consult" (table &rest options))
(declare-function consult--temporary-files "consult" ())

;; No value: Consult's own definitions must install the real defaults.
(defvar consult-fontify-preserve)
(defvar consult--buffer-display)
(defvar consult--narrow)

;; No value: markdown-ts-mode's own `defcustom' must install the real
;; default when it loads after this file.
(defvar markdown-ts-inline-images)
(defvar markdown-ts-view-mode-pre-init-hook)
(defvar markdown-ts-fontify-code-blocks-natively)

(defvar agent-shell-vertico-consult-history nil
  "Minibuffer history for transcript searches.")

(defun agent-shell-vertico-consult--one-line (text)
  "Return TEXT collapsed to one trimmed display line."
  (string-trim
   (replace-regexp-in-string "[ \t\n\r]+" " " (or text ""))))

(defun agent-shell-vertico-consult--candidate (record)
  "Return an aggregated Consult candidate for transcript RECORD."
  (let* ((project
          (or
           (agent-shell-vertico-transcript-record-project-name record)
           "Unscoped"))
         (count
          (or
           (agent-shell-vertico-transcript-record-match-count record)
           0))
         (started
          (or
           (agent-shell-vertico-transcript-record-started record)
           (format-time-string
            "%F %R"
            (agent-shell-vertico-transcript-record-modified-time
             record))))
         (text
          (truncate-string-to-width
           (agent-shell-vertico-consult--one-line
            (agent-shell-vertico-transcript-record-match-text record))
           100 nil nil "…"))
         (candidate
          (format "[%s] [%d] %s  %s"
                  project count started text)))
    (add-text-properties
     0 (length candidate)
     (list
      'agent-shell-vertico-transcript-record record
      'agent-shell-vertico-transcript-file
      (agent-shell-vertico-transcript-record-file record)
      'agent-shell-vertico-transcript-line
      (agent-shell-vertico-transcript-record-match-line record))
     candidate)
    candidate))

(defun agent-shell-vertico-consult--async-candidates (project-roots)
  "Return an async stage aggregating rg output for PROJECT-ROOTS."
  (lambda (sink)
    (let ((records (make-hash-table :test #'equal))
          (ignored (make-symbol "ignored")))
      (lambda (action)
        (cond
         ((stringp action)
          (clrhash records)
          (funcall sink action))
         ((eq action 'flush)
          (clrhash records)
          (funcall sink action))
         ((consp action)
          (dolist (line action)
            (when-let* ((entry
                         (agent-shell-vertico-transcript--rg-match-from-json
                          line)))
              (let* ((file (car entry))
                     (match (cdr entry))
                     (record (gethash file records)))
                (cond
                 ((eq record ignored))
                 ((agent-shell-vertico-transcript-record-p record)
                  (setf
                   (agent-shell-vertico-transcript-record-match-count
                    record)
                   (1+
                    (agent-shell-vertico-transcript-record-match-count
                     record))))
                 (t
                  (setq record
                        (agent-shell-vertico-transcript--record-for-match
                         file match project-roots))
                  (puthash file (or record ignored) records))))))
          (let (found)
            (maphash
             (lambda (_file record)
               (unless (eq record ignored)
                 (push record found)))
             records)
            (setq found
                  (seq-sort
                   (lambda (left right)
                     (time-less-p
                      (agent-shell-vertico-transcript-record-modified-time
                       right)
                      (agent-shell-vertico-transcript-record-modified-time
                       left)))
                   found))
            (funcall sink 'flush)
            (when found
              (funcall
               sink
               (mapcar
                #'agent-shell-vertico-consult--candidate
                found)))))
         (t
          (funcall sink action)))))))

(defun agent-shell-vertico-consult--preview-major-mode ()
  "Return the major mode used to display transcript previews.

The mode the reader opens a transcript in, so a preview and the
transcript it leads to look the same.  Text mode when there is no
Markdown mode to use."
  (or (agent-shell-vertico-transcript--markdown-major-mode)
      'text-mode))

(defun agent-shell-vertico-consult--open-preview (file opener)
  "Open FILE for preview with OPENER, highlighted as Markdown.

Consult opens preview buffers with `delay-mode-hooks' bound, so a
transcript never reaches the state its Markdown mode needs to fontify.
Two cases show up as an unhighlighted preview:

- A Markdown mode that finishes its setup in mode hooks, such as
  Polymode's `poly-markdown-mode', installs itself as the fontification
  engine and then never fontifies anything.  Naming the mode here instead
  of letting the user's `auto-mode-alist' pick it keeps such a mode out of
  previews: `agent-shell-vertico-consult--preview-major-mode' returns
  either the tree-sitter view mode, which sets itself up in the mode body,
  or plain `markdown-mode'.  Either way jit-lock stays in charge.

- A file above `consult-preview-partial-size' is read into a buffer with
  no file name, where `set-auto-mode' cannot detect Markdown and leaves
  Fundamental mode.  Set the mode there directly.

Native code-block fontification is off for the mode call: it runs each
visible block's own major mode and a whole-block `font-lock-ensure',
the only step in the preview pipeline costing more than a few
milliseconds, and a scanned preview does not need it."
  (let* ((mode (agent-shell-vertico-consult--preview-major-mode))
         (auto-mode-alist (cons (cons "\\.md\\'" mode) auto-mode-alist))
         ;; `markdown-ts-view-mode' turns inline images on and amends the
         ;; buffer from this hook, whose default adds a final newline.  A
         ;; preview is scanned, not read, and previews visit the real
         ;; file, so neither belongs here.  The mode sets the variable
         ;; itself, so the hook is the only place left to answer it.
         (markdown-ts-view-mode-pre-init-hook
          (list (lambda () (setq-local markdown-ts-inline-images nil))))
         (markdown-ts-fontify-code-blocks-natively nil)
         (buffer (funcall opener file)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (eq major-mode 'fundamental-mode)
          (delay-mode-hooks (funcall mode))
          (font-lock-mode 1))))
    buffer))

(defun agent-shell-vertico-consult--position (candidate &optional opener)
  "Return a Consult marker for CANDIDATE, opening with OPENER."
  (when candidate
    (when-let* ((record
                 (get-text-property
                  0 'agent-shell-vertico-transcript-record candidate))
                (file
                 (or
                  (get-text-property
                   0 'agent-shell-vertico-transcript-file candidate)
                  (agent-shell-vertico-transcript-record-file record)))
                (line
                 (or
                  (get-text-property
                   0 'agent-shell-vertico-transcript-line candidate)
                  1))
                (buffer
                 (funcall
                  (or opener #'consult--file-action)
                  file))
                (marker
                 (consult--marker-from-line-column
                  buffer line 0)))
      (cons marker nil))))

(defun agent-shell-vertico-consult--state ()
  "Return a Consult state function for transcript previews.
Previews are temporary.  Selecting a candidate performs no action, so
the caller decides what to open once the minibuffer is gone."
  (let ((open (consult--temporary-files))
        (preview (consult--jump-preview)))
    (lambda (action candidate)
      (when (eq action 'preview)
        (funcall
         preview action
         (agent-shell-vertico-consult--position
          candidate
          (lambda (file)
            (agent-shell-vertico-consult--open-preview file open))))
        (unless candidate
          (funcall open))))))

(defun agent-shell-vertico-consult--session-preview-buffer (candidate)
  "Return the buffer previewed for session CANDIDATE.

When viewport interaction is preferred, use an existing viewport when
there is one.  Do not create a viewport just because completion moved
over a candidate; fall back to the shell buffer when none exists."
  (when-let* ((buffer (get-buffer (substring-no-properties candidate))))
    (or (and agent-shell-prefer-viewport-interaction
             (agent-shell-viewport--buffer
              :shell-buffer buffer :existing-only t))
        buffer)))

(defun agent-shell-vertico-consult--session-state (&optional other-window)
  "Return a Consult state function for live session previews.

OTHER-WINDOW makes the preview use the same window direction as the
command that runs after selection.  Consult reads
`consult--buffer-display' while the preview runs, not while this closure
is built, so the binding wraps each call, the way
`consult--man-preview' does it.

Previewing performs no part of the command that follows: it neither
clears attention state nor displays the session the way the switch
commands do."
  (let ((display (if other-window
                     #'switch-to-buffer-other-window
                   #'switch-to-buffer))
        (preview (consult--buffer-preview)))
    (lambda (action candidate)
      (let ((consult--buffer-display display))
        (funcall
         preview action
         (when (and (eq action 'preview) candidate)
           (agent-shell-vertico-consult--session-preview-buffer
            candidate)))))))

(defun agent-shell-vertico-consult--narrow (keys matcher &optional context)
  "Return a Consult narrowing configuration offering KEYS.

MATCHER answers whether a candidate belongs to the narrowing key in
force, which Consult reports in `consult--narrow'.  CONTEXT is whatever
the matcher needs to know about the buffer the command was called from.
It is read here, while that buffer is still current: the predicate itself
runs with the minibuffer current and can no longer ask.

Consult installs the predicate as `minibuffer-completion-predicate', and
every table this package reads through passes its predicate on to
`complete-with-action', so the answer reaches the candidates.

The `(:predicate FN :keys ALIST)' shape is what Consult has taken since
2.4, which is the earliest release this package can be built against."
  (list :predicate
        (lambda (candidate)
          (funcall matcher consult--narrow candidate context))
        :keys keys))

(defun agent-shell-vertico-consult--group (function)
  "Return FUNCTION as a Consult group function, or nil when not grouping.

Consult puts its own metadata ahead of the completion table's, so a
group function passed here wins over one the table declares.  Both name
the same function, so the two cannot disagree."
  (and agent-shell-vertico-group-by function))

(defun agent-shell-vertico-consult--read-session
    (prompt table &optional other-window)
  "Read a live session from TABLE with PROMPT, previewing each candidate.

OTHER-WINDOW matches the final display direction, for the reader
`agent-shell-vertico-switch-other-window' uses.

TABLE is the same completion table the plain reader uses, so candidate
annotations and sorting come from its metadata.  Consult merges its own
metadata behind the table's, and its default lookup returns the selected
string, which is the buffer name the caller expects."
  (let ((selection
         (consult--read
          table
          :prompt prompt
          :state (agent-shell-vertico-consult--session-state other-window)
          :require-match t
          :category 'agent-shell-session
          :narrow (agent-shell-vertico-consult--narrow
                   (agent-shell-vertico--narrow-keys
                    agent-shell-vertico--session-narrow-keys)
                   #'agent-shell-vertico--session-narrow-p
                   (agent-shell-vertico--session-narrow-context))
          :group (agent-shell-vertico-consult--group
                  #'agent-shell-vertico--session-group)
          :history 'agent-shell-vertico-history)))
    (or (and selection (substring-no-properties selection))
        (user-error "Nothing selected"))))

(setq agent-shell-vertico-read-session-function
      #'agent-shell-vertico-consult--read-session)

(defun agent-shell-vertico-consult--read-record (prompt records)
  "Read one transcript from RECORDS with PROMPT and live preview."
  (unless records
    (user-error "No matching agent-shell transcripts"))
  (let* ((candidates
          (agent-shell-vertico-transcript--record-candidates records))
         (selection
          ;; Annotations come from the Marginalia annotator registered for
          ;; the category, so both readers render from one definition.
          (consult--read
           candidates
           :prompt prompt
           :lookup #'consult--lookup-member
           :state (agent-shell-vertico-consult--state)
           :require-match t
           :category 'agent-shell-transcript
           :narrow (agent-shell-vertico-consult--narrow
                    (agent-shell-vertico--narrow-keys
                     agent-shell-vertico-transcript--narrow-keys)
                    #'agent-shell-vertico-transcript--narrow-p
                    (agent-shell-vertico-transcript--narrow-context))
           :group (agent-shell-vertico-consult--group
                   #'agent-shell-vertico-transcript--group)
           :sort nil)))
    (or
     (agent-shell-vertico-transcript--record-from-candidate selection)
     (user-error "Transcript no longer exists"))))

(setq agent-shell-vertico-transcript-read-record-function
      #'agent-shell-vertico-consult--read-record)

(defun agent-shell-vertico-consult--read-session-choice
    (prompt candidates default)
  "Read one session picker choice from CANDIDATES with PROMPT and preview.

DEFAULT is the choice the picker starts on.  Candidates carry the
transcript record they were joined to, which is what the preview shows;
a choice with no transcript behind it previews nothing."
  (consult--read
   candidates
   :prompt prompt
   :lookup #'consult--lookup-member
   :state (agent-shell-vertico-consult--state)
   :require-match t
   :category 'agent-shell-session-choice
   :narrow (agent-shell-vertico-consult--narrow
            (agent-shell-vertico--narrow-keys
             agent-shell-vertico-resume--narrow-keys)
            #'agent-shell-vertico-resume--narrow-p)
   :group (agent-shell-vertico-consult--group
           #'agent-shell-vertico-resume--group)
   :default default
   :sort nil))

(setq agent-shell-vertico-resume-read-choice-function
      #'agent-shell-vertico-consult--read-session-choice)

(defun agent-shell-vertico-consult--search (project-roots)
  "Search transcripts belonging to PROJECT-ROOTS and open one."
  (unless project-roots
    (user-error "No projects available for transcript search"))
  (let* ((directories
          (agent-shell-vertico-transcript--search-directories
           project-roots))
         (builder
          (lambda (input)
            (agent-shell-vertico-transcript--rg-command
             directories input)))
         (collection
          (consult--process-collection
           builder
           :min-input 1
           :transform
           (agent-shell-vertico-consult--async-candidates
            project-roots)))
         (selection
          (consult--read
           collection
           :prompt "Transcript search: "
           :lookup #'consult--lookup-member
           :state (agent-shell-vertico-consult--state)
           :require-match t
           :category 'agent-shell-transcript
           :narrow (agent-shell-vertico-consult--narrow
                    (agent-shell-vertico--narrow-keys
                     agent-shell-vertico-transcript--narrow-keys)
                    #'agent-shell-vertico-transcript--narrow-p
                    (agent-shell-vertico-transcript--narrow-context))
           :group (agent-shell-vertico-consult--group
                   #'agent-shell-vertico-transcript--group)
           :history '(:input agent-shell-vertico-consult-history)
           :sort nil)))
    (when selection
      (agent-shell-vertico-transcript--open-record
       (get-text-property
        0 'agent-shell-vertico-transcript-record selection)))))

;;;###autoload
(defun agent-shell-vertico-transcript-search ()
  "Search transcripts across all known projects."
  (interactive)
  (agent-shell-vertico-consult--search
   (agent-shell-vertico-transcript--project-roots)))

;;;###autoload
(defun agent-shell-vertico-transcript-search-project ()
  "Search transcripts belonging to the current project."
  (interactive)
  (agent-shell-vertico-consult--search
   (list
    (agent-shell-vertico-transcript--current-project-or-error))))

;;; Prompt queue preview
;;
;; A queued prompt is text, not a file or a position, so none of
;; Consult's own preview helpers fit.  The state function below shows
;; the prompt under point in the same buffer the `v' action uses, and
;; puts the windows back when the session ends.

(defun agent-shell-vertico-consult--prompt-queue-state ()
  "Return a Consult state function previewing pending prompts.
A queue-wide entry has no prompt of its own, so preview describes what
it would do instead of leaving the previous prompt on screen."
  (let ((restore (current-window-configuration)))
    (lambda (action candidate)
      (pcase action
        ('preview
         (when-let*
             ((record
               (agent-shell-vertico-prompt-queue--record-from-candidate
                candidate)))
           (display-buffer
            (agent-shell-vertico-prompt-queue--render record))))
        ('exit
         (when-let* ((buffer
                      (get-buffer
                       agent-shell-vertico-prompt-queue--buffer)))
           (kill-buffer buffer))
         (set-window-configuration restore))))))

(defun agent-shell-vertico-consult--read-prompt-queue (prompt candidates)
  "Read one of CANDIDATES with PROMPT and live preview."
  (let ((selection
         (consult--read
          candidates
          :prompt prompt
          :lookup #'consult--lookup-member
          :state (agent-shell-vertico-consult--prompt-queue-state)
          :require-match t
          :category 'agent-shell-prompt-queue
          :narrow (agent-shell-vertico-consult--narrow
                   agent-shell-vertico-prompt-queue--narrow-keys
                   #'agent-shell-vertico-prompt-queue--narrow-p)
          :sort nil)))
    (or (agent-shell-vertico-prompt-queue--record-from-candidate selection)
        (user-error "Prompt no longer pending"))))

;; Annotations come from the Marginalia annotator registered for the
;; category, so both readers render from one definition.
(setq agent-shell-vertico-prompt-queue-read-function
      #'agent-shell-vertico-consult--read-prompt-queue)

;;; Searching inside a live shell buffer

(defun agent-shell-vertico-consult--folding-buffer-p (buffer)
  "Return non-nil when BUFFER hides text with agent-shell's folds."
  (and (buffer-live-p buffer)
       (buffer-local-boundp 'agent-shell-ui-mode buffer)
       (buffer-local-value 'agent-shell-ui-mode buffer)))

(defun agent-shell-vertico-consult--plain-candidates ()
  "Stop Consult copying agent-shell's `invisible' property onto candidates.
agent-shell hides a collapsed block's body with an `invisible' text
property.  `consult--line-fontify' copies `face', `invisible' and
`display' from the source buffer onto each candidate, and the minibuffer
hides any non-nil `invisible' value, so every line inside a collapsed
block arrives blank.  Nil `consult-fontify-preserve' skips that copy.

It has to be set here rather than in the shell buffer: the annotation
runs with the minibuffer current, so a value local to the shell buffer
is never read.  Candidates lose their buffer faces and keep their text."
  (when-let* ((window (minibuffer-selected-window))
              ((agent-shell-vertico-consult--folding-buffer-p
                (window-buffer window))))
    (setq-local consult-fontify-preserve nil)))

(defun agent-shell-vertico-consult--expand-fold ()
  "Reveal the activity group and fragment Consult jumped or previewed into.
Agent-shell folds use text properties rather than overlays, so Consult's
normal invisible-text handling cannot reveal them on its own."
  (when (agent-shell-vertico-consult--folding-buffer-p (current-buffer))
    (agent-shell-vertico--imenu-reveal-at-point)))

;;;###autoload
(defun agent-shell-vertico-consult-setup-buffer-search ()
  "Make Consult's line search work inside agent-shell's collapsed blocks.
Candidates keep their text instead of arriving blank, and both previewing
and selecting one expand the block it lives in.  Nothing collapses those
blocks again: Consult's preview only restores the folds it opened
itself, which are overlays."
  (add-hook 'minibuffer-setup-hook
            #'agent-shell-vertico-consult--plain-candidates)
  (add-hook 'consult-after-jump-hook
            #'agent-shell-vertico-consult--expand-fold))

(provide 'agent-shell-vertico-consult)

;;; agent-shell-vertico-consult.el ends here
