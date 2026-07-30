;;; agent-shell-vertico-consult.el --- Live transcript recall with Consult -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Bill and contributors

;; Author: Bill
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (agent-shell "0") (consult "2.0") (marginalia "1.0"))
;; Keywords: convenience, tools
;; URL: https://github.com/liaowang11/agent-shell-vertico

;;; Commentary:

;; Live, aggregated `rg' search over current `agent-shell' transcript files.

;;; Code:

(require 'agent-shell-vertico-transcript)
(require 'consult)
(require 'subr-x)

(declare-function consult--file-action "consult" (file))
(declare-function consult--jump-state "consult" ())
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
  "Return a Consult state function for transcript previews."
  (let ((open (consult--temporary-files))
        (jump (consult--jump-state)))
    (lambda (action candidate)
      (unless candidate
        (funcall open))
      (funcall
       jump action
       (agent-shell-vertico-consult--position
        candidate
       (and (not (eq action 'return)) open))))))

(defun agent-shell-vertico-consult--read-record (prompt records)
  "Read one transcript from RECORDS with PROMPT and live preview."
  (unless records
    (user-error "No matching agent-shell transcripts"))
  (let* ((candidates
          (mapcar
           #'agent-shell-vertico-transcript--record-candidate
           records))
         (selection
          (consult--read
           candidates
           :prompt prompt
           :lookup #'consult--lookup-member
           :state (agent-shell-vertico-consult--state)
           :require-match t
           :category 'agent-shell-transcript
           :annotate
           #'agent-shell-vertico-transcript--record-annotation
           :sort nil)))
    (or
     (agent-shell-vertico-transcript--record-from-candidate selection)
     (user-error "Transcript no longer exists"))))

(setq agent-shell-vertico-transcript-read-record-function
      #'agent-shell-vertico-consult--read-record)

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

(provide 'agent-shell-vertico-consult)

;;; agent-shell-vertico-consult.el ends here
