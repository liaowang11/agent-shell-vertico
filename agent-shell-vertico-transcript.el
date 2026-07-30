;;; agent-shell-vertico-transcript.el --- Transcript recall for agent-shell -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Bill and contributors

;; Author: Bill
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (agent-shell "0") (agent-shell-vertico "0.1.0"))
;; Keywords: convenience, tools
;; URL: https://github.com/liaowang11/agent-shell-vertico

;;; Commentary:

;; Project-aware browsing, search, and restoration of `agent-shell'
;; transcripts without a persistent transcript index.

;;; Code:

(require 'agent-shell)
(require 'agent-shell-vertico)
(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'subr-x)

(defvar agent-shell-dot-subdir-function)
(defvar agent-shell-transcript-file-path-function)
(defvar projectile-current-project-on-switch)
(defvar projectile-mode)

(declare-function agent-shell-resume-session "agent-shell" (session-id))
(declare-function projectile-project-root "projectile" (&optional dir))
(declare-function projectile-relevant-known-projects "projectile" ())

(cl-defstruct
    (agent-shell-vertico-transcript-record
     (:constructor agent-shell-vertico-transcript-record-create))
  "Metadata for one `agent-shell' transcript."
  file
  project-root
  project-name
  agent
  model
  session-id
  started
  working-directory
  preview
  modified-time
  match-count
  match-line
  match-text)

(defun agent-shell-vertico-transcript--normalize-directory (directory)
  "Return DIRECTORY expanded and terminated with a slash."
  (file-name-as-directory (expand-file-name directory)))

(defun agent-shell-vertico-transcript--current-project-root ()
  "Return the current Projectile or project.el root, or nil."
  (cond
   ((and (bound-and-true-p projectile-mode)
         (fboundp 'projectile-project-root))
    (when-let* ((root (projectile-project-root)))
      (agent-shell-vertico-transcript--normalize-directory root)))
   ((fboundp 'project-current)
    (when-let* ((project (project-current))
                (root (project-root project)))
      (agent-shell-vertico-transcript--normalize-directory root)))))

(defun agent-shell-vertico-transcript--project-roots ()
  "Return known local project roots, with the current project first."
  (let* ((current (agent-shell-vertico-transcript--current-project-root))
         (known
          (cond
           ((and (bound-and-true-p projectile-mode)
                 (fboundp 'projectile-relevant-known-projects))
            (let ((projectile-current-project-on-switch 'keep))
              (projectile-relevant-known-projects)))
           ((fboundp 'project-known-project-roots)
            (project-known-project-roots))))
         roots)
    (dolist (root (cons current known))
      (when (and root (not (file-remote-p root)))
        (setq root
              (agent-shell-vertico-transcript--normalize-directory root))
        (unless (member root roots)
          (setq roots (append roots (list root))))))
    roots))

(defun agent-shell-vertico-transcript--directory (project-root)
  "Return the transcript directory configured for PROJECT-ROOT.

Resolve the path through `agent-shell-dot-subdir-function' without
creating the directory."
  (unless (functionp agent-shell-dot-subdir-function)
    (user-error "`agent-shell-dot-subdir-function' is not a function"))
  (let* ((default-directory
          (agent-shell-vertico-transcript--normalize-directory project-root))
         (directory (funcall agent-shell-dot-subdir-function "transcripts")))
    (unless (and (stringp directory)
                 (not (string-empty-p (string-trim directory))))
      (user-error "Could not resolve transcript directory for %s"
                  project-root))
    (expand-file-name directory default-directory)))

(defun agent-shell-vertico-transcript--header-value (label)
  "Return the current buffer's Markdown header value for LABEL."
  (goto-char (point-min))
  (when (re-search-forward
         (format "^\\*\\*%s:\\*\\*[ \t]+\\(.+\\)$" (regexp-quote label))
         nil t)
    (string-trim (match-string-no-properties 1))))

(defun agent-shell-vertico-transcript--first-user-message ()
  "Return the first nonblank line of the first user message."
  (goto-char (point-min))
  (when (re-search-forward "^## User\\(?:[ \t(].*\\)?$" nil t)
    (forward-line 1)
    (while (and (not (eobp))
                (or (looking-at-p "^[ \t]*$")
                    (looking-at-p "^>?[ \t]*$")))
      (forward-line 1))
    (unless (or (eobp) (looking-at-p "^## "))
      (string-trim
       (replace-regexp-in-string
        "\\`>[ \t]?" ""
        (buffer-substring-no-properties
         (line-beginning-position) (line-end-position)))))))

(defun agent-shell-vertico-transcript--parse-file (file project-root)
  "Return a transcript record parsed from FILE for PROJECT-ROOT."
  (with-temp-buffer
    (insert-file-contents file nil 0 65536)
    (let* ((agent (agent-shell-vertico-transcript--header-value "Agent"))
           (started (agent-shell-vertico-transcript--header-value "Started"))
           (working-directory
            (agent-shell-vertico-transcript--header-value
             "Working Directory"))
           (session-id
            (agent-shell-vertico-transcript--header-value "Session ID"))
           (model (agent-shell-vertico-transcript--header-value "Model"))
           (preview (agent-shell-vertico-transcript--first-user-message))
           (attributes (file-attributes file))
           (normalized-root
            (agent-shell-vertico-transcript--normalize-directory
             project-root)))
      (agent-shell-vertico-transcript-record-create
       :file file
       :project-root normalized-root
       :project-name
       (file-name-nondirectory (directory-file-name normalized-root))
       :agent agent
       :model model
       :session-id session-id
       :started started
       :working-directory
       (and working-directory
            (agent-shell-vertico-transcript--normalize-directory
             working-directory))
       :preview (or preview "(empty transcript)")
       :modified-time (file-attribute-modification-time attributes)))))

(defun agent-shell-vertico-transcript--same-directory-p (left right)
  "Return non-nil when LEFT and RIGHT name the same directory."
  (and left right
       (string=
        (agent-shell-vertico-transcript--normalize-directory left)
        (agent-shell-vertico-transcript--normalize-directory right))))

(defun agent-shell-vertico-transcript--record-in-project-p
    (record project-root transcript-directory)
  "Return non-nil when RECORD belongs to PROJECT-ROOT.
TRANSCRIPT-DIRECTORY is used for old records without a working
directory header."
  (if-let* ((working-directory
             (agent-shell-vertico-transcript-record-working-directory
              record)))
      (agent-shell-vertico-transcript--same-directory-p
       working-directory project-root)
    (file-in-directory-p transcript-directory project-root)))

(defun agent-shell-vertico-transcript--records-for-project (project-root)
  "Return transcript records belonging to PROJECT-ROOT, newest first."
  (let ((directory
         (agent-shell-vertico-transcript--directory project-root)))
    (when (file-directory-p directory)
      (let ((records
             (mapcar
              (lambda (file)
                (agent-shell-vertico-transcript--parse-file
                 file project-root))
              (directory-files directory t "\\.md\\'" t))))
        (setq records
              (seq-filter
               (lambda (record)
                 (agent-shell-vertico-transcript--record-in-project-p
                  record project-root directory))
               records))
        (seq-sort
         (lambda (left right)
           (time-less-p
            (agent-shell-vertico-transcript-record-modified-time right)
            (agent-shell-vertico-transcript-record-modified-time left)))
         records)))))

(defun agent-shell-vertico-transcript--live-buffer (session-id)
  "Return the live `agent-shell' buffer for SESSION-ID, or nil."
  (when session-id
    (seq-find
     (lambda (buffer)
       (and
        (buffer-live-p buffer)
        (with-current-buffer buffer
          (and
           (boundp 'agent-shell--state)
           (or
            (equal
             session-id
             (map-nested-elt agent-shell--state '(:session :id)))
            (equal
             session-id
             (map-elt agent-shell--state :resume-session-id)))))))
     (agent-shell-buffers))))

(defun agent-shell-vertico-transcript--activate (record)
  "Switch to, resume, or open transcript RECORD."
  (let* ((session-id
          (agent-shell-vertico-transcript-record-session-id record))
         (file (agent-shell-vertico-transcript-record-file record))
         (live-buffer
          (agent-shell-vertico-transcript--live-buffer session-id)))
    (cond
     (live-buffer
      (agent-shell-vertico--display-session
       (buffer-name live-buffer)))
     (session-id
      (let ((default-directory
             (or
              (agent-shell-vertico-transcript-record-working-directory
               record)
              default-directory))
            (agent-shell-transcript-file-path-function
             (lambda () file)))
        (agent-shell-resume-session session-id)))
     (t
      (find-file file)))))

(defun agent-shell-vertico-transcript--record-status (record)
  "Return a short availability label for RECORD."
  (cond
   ((agent-shell-vertico-transcript--live-buffer
     (agent-shell-vertico-transcript-record-session-id record))
    "Live")
   ((agent-shell-vertico-transcript-record-session-id record)
    "Resumable")
   (t "Transcript only")))

(defun agent-shell-vertico-transcript--record-candidate (record)
  "Return a completion candidate for RECORD."
  (let* ((started
          (or
           (agent-shell-vertico-transcript-record-started record)
           (file-name-sans-extension
            (file-name-nondirectory
             (agent-shell-vertico-transcript-record-file record)))))
         (candidate
          (format "[%s] %s" started
                  (agent-shell-vertico-transcript-record-preview record))))
    (put-text-property
     0 (length candidate) 'agent-shell-vertico-transcript-record
     record candidate)
    candidate))

(defun agent-shell-vertico-transcript--record-from-candidate (candidate)
  "Return the transcript record carried by CANDIDATE."
  (get-text-property
   0 'agent-shell-vertico-transcript-record candidate))

(defun agent-shell-vertico-transcript--record-annotation (candidate)
  "Return an annotation for transcript CANDIDATE."
  (when-let* ((record
               (agent-shell-vertico-transcript--record-from-candidate
                candidate)))
    (marginalia--fields
     ((agent-shell-vertico-transcript--record-status record)
      :truncate 16 :face 'marginalia-type)
     ((or (agent-shell-vertico-transcript-record-agent record) "-")
      :truncate 14 :face 'marginalia-value)
     ((or (agent-shell-vertico-transcript-record-started record)
          (format-time-string
           "%F %R"
           (agent-shell-vertico-transcript-record-modified-time
            record)))
      :truncate 18 :face 'marginalia-date))))

(defun agent-shell-vertico-transcript--read-record (prompt records)
  "Read one transcript from RECORDS with PROMPT."
  (unless records
    (user-error "No matching agent-shell transcripts"))
  (let* ((candidates
          (mapcar
           #'agent-shell-vertico-transcript--record-candidate
           records))
         (selection
          (completing-read
           prompt
           (lambda (string pred action)
             (if (eq action 'metadata)
                 `(metadata
                   (category . agent-shell-transcript)
                   (annotation-function
                    . ,#'agent-shell-vertico-transcript--record-annotation)
                   (display-sort-function . identity)
                   (cycle-sort-function . identity))
               (complete-with-action action candidates string pred)))
           nil t)))
    (or
     (agent-shell-vertico-transcript--record-from-candidate selection)
     (user-error "Transcript no longer exists"))))

(defun agent-shell-vertico-transcript--project-candidate (root)
  "Return a completion candidate carrying project ROOT."
  (let ((candidate
         (format "%s  %s"
                 (file-name-nondirectory (directory-file-name root))
                 (abbreviate-file-name root))))
    (put-text-property
     0 (length candidate) 'agent-shell-vertico-project-root root candidate)
    candidate))

(defun agent-shell-vertico-transcript--read-project ()
  "Read one known project root."
  (let* ((candidates
          (mapcar
           #'agent-shell-vertico-transcript--project-candidate
           (agent-shell-vertico-transcript--project-roots)))
         (selection
          (completing-read "Project: " candidates nil t)))
    (or
     (get-text-property
      0 'agent-shell-vertico-project-root selection)
     (user-error "No known projects"))))

(defun agent-shell-vertico-transcript--current-project-or-error ()
  "Return the current project root or signal a user error."
  (or
   (agent-shell-vertico-transcript--current-project-root)
   (user-error "Not in a project")))

(defun agent-shell-vertico-transcript--browse-project-root
    (project-root &optional resumable-only)
  "Browse transcripts for PROJECT-ROOT.
When RESUMABLE-ONLY is non-nil, omit records without session IDs."
  (let ((records
         (agent-shell-vertico-transcript--records-for-project
          project-root)))
    (when resumable-only
      (setq records
            (seq-filter
             #'agent-shell-vertico-transcript-record-session-id
             records)))
    (agent-shell-vertico-transcript--activate
     (agent-shell-vertico-transcript--read-record
      (if resumable-only "Resume session: " "Transcript: ")
      records))))

;;;###autoload
(defun agent-shell-vertico-transcript-browse ()
  "Select a known project, then browse its transcripts."
  (interactive)
  (agent-shell-vertico-transcript--browse-project-root
   (agent-shell-vertico-transcript--read-project)))

;;;###autoload
(defun agent-shell-vertico-transcript-browse-project ()
  "Browse transcripts belonging to the current project."
  (interactive)
  (agent-shell-vertico-transcript--browse-project-root
   (agent-shell-vertico-transcript--current-project-or-error)))

;;;###autoload
(defun agent-shell-vertico-transcript-resume ()
  "Select a known project, then resume one of its sessions."
  (interactive)
  (agent-shell-vertico-transcript--browse-project-root
   (agent-shell-vertico-transcript--read-project) t))

;;;###autoload
(defun agent-shell-vertico-transcript-resume-project ()
  "Resume a transcript session belonging to the current project."
  (interactive)
  (agent-shell-vertico-transcript--browse-project-root
   (agent-shell-vertico-transcript--current-project-or-error) t))

(provide 'agent-shell-vertico-transcript)

;;; agent-shell-vertico-transcript.el ends here
