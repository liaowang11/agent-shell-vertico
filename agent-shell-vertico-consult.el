;;; agent-shell-vertico-consult.el --- Live transcript recall with Consult -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Bill and contributors

;; Author: Bill
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (agent-shell "0.63.5") (consult "2.0") (marginalia "2.1"))
;; Keywords: convenience, tools
;; URL: https://github.com/liaowang11/agent-shell-vertico

;;; Commentary:

;; Live, aggregated `rg' search over current `agent-shell' transcript
;; files, live preview of the prompts queued in a session, and live
;; preview of the transcripts behind `agent-shell''s session picker.

;;; Code:

(require 'agent-shell-vertico-prompt-queue)
(require 'agent-shell-vertico-resume)
(require 'agent-shell-vertico-transcript)
(require 'consult)
(require 'subr-x)

(declare-function consult--file-action "consult" (file))
(declare-function consult--jump-preview "consult" ())
(declare-function consult--lookup-member "consult" (&rest args))
(declare-function consult--marker-from-line-column
                  "consult" (buffer line column))
(declare-function consult--process-collection "consult" (builder &rest props))
(declare-function consult--read "consult" (table &rest options))
(declare-function consult--temporary-files "consult" ())

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
  "Return the major mode used to display transcript previews."
  (if (fboundp 'markdown-mode)
      'markdown-mode
    'text-mode))

(defun agent-shell-vertico-consult--open-preview (file opener)
  "Open FILE for preview with OPENER, highlighted as Markdown.

Consult opens preview buffers with `delay-mode-hooks' bound, so a
transcript never reaches the state its Markdown mode needs to fontify.
Two cases show up as an unhighlighted preview:

- A Markdown mode that finishes its setup in mode hooks, such as
  Polymode's `poly-markdown-mode', installs itself as the fontification
  engine and then never fontifies anything.  Previewing in the plain mode
  returned by `agent-shell-vertico-consult--preview-major-mode' leaves
  jit-lock in charge instead.

- A file above `consult-preview-partial-size' is read into a buffer with
  no file name, where `set-auto-mode' cannot detect Markdown and leaves
  Fundamental mode.  Set the mode there directly."
  (let* ((mode (agent-shell-vertico-consult--preview-major-mode))
         (auto-mode-alist (cons (cons "\\.md\\'" mode) auto-mode-alist))
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
          :sort nil)))
    (or (agent-shell-vertico-prompt-queue--record-from-candidate selection)
        (user-error "Prompt no longer pending"))))

;; Annotations come from the Marginalia annotator registered for the
;; category, so both readers render from one definition.
(setq agent-shell-vertico-prompt-queue-read-function
      #'agent-shell-vertico-consult--read-prompt-queue)

(provide 'agent-shell-vertico-consult)

;;; agent-shell-vertico-consult.el ends here
