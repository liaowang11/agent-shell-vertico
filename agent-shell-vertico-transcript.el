;;; agent-shell-vertico-transcript.el --- Transcript recall for agent-shell -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Bill and contributors

;; Author: Bill
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (agent-shell "0") (marginalia "1.0"))
;; Keywords: convenience, tools
;; URL: https://github.com/liaowang11/agent-shell-vertico

;;; Commentary:

;; Project-aware browsing, search, and restoration of `agent-shell'
;; transcripts without a persistent transcript index.

;;; Code:

(require 'agent-shell)
(require 'agent-shell-vertico)
(require 'cl-lib)
(require 'json)
(require 'map)
(require 'project)
(require 'seq)
(require 'subr-x)

(defvar agent-shell-dot-subdir-function)
(defvar agent-shell-transcript-file-path-function)
(defvar embark-default-action-overrides)
(defvar embark-keymap-alist)
(defvar projectile-current-project-on-switch)
(defvar projectile-mode)

(declare-function agent-shell-resume-session "agent-shell" (session-id))
(declare-function dired "dired" (dirname &optional switches))
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
            (or
             (agent-shell-vertico-transcript--header-value "Session ID")
             (agent-shell-vertico-transcript--header-value "Session")))
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
              (directory-files-recursively directory "\\.md\\'"))))
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

(defun agent-shell-vertico-transcript--search-directories (project-roots)
  "Return existing transcript directories for PROJECT-ROOTS."
  (delete-dups
   (seq-filter
    #'file-directory-p
    (mapcar
     #'agent-shell-vertico-transcript--directory
     project-roots))))

(defun agent-shell-vertico-transcript--rg-command (directories query)
  "Return an rg command searching DIRECTORIES for QUERY."
  (when (and directories
             (stringp query)
             (not (string-empty-p query)))
    (unless (executable-find "rg")
      (user-error "The rg executable is required for transcript search"))
    (append
     '("rg" "--json" "--smart-case" "--hidden" "--no-ignore"
       "--glob" "*.md" "--")
     (list query)
     directories)))

(defun agent-shell-vertico-transcript--rg-match-from-json (line)
  "Return a transcript match entry parsed from rg JSON LINE."
  (unless (string-empty-p line)
    (let ((event
           (json-parse-string
            line :object-type 'alist
            :array-type 'list
            :null-object nil
            :false-object nil)))
      (when (equal (map-elt event 'type) "match")
        (cons
         (map-nested-elt event '(data path text))
         (list
          :count 1
          :line (map-nested-elt event '(data line_number))
          :text
          (string-trim-right
           (map-nested-elt event '(data lines text)))))))))

(defun agent-shell-vertico-transcript--rg-matches
    (directories query)
  "Return an alist of transcript matches for QUERY in DIRECTORIES.

Each value is a plist containing `:count', `:line', and `:text'."
  (when-let* ((command
               (agent-shell-vertico-transcript--rg-command
                directories query)))
    (with-temp-buffer
      (let ((status
             (apply
              #'process-file
              (car command) nil t nil (cdr command))))
        (cond
         ((= status 1) nil)
         ((not (zerop status))
          (user-error "rg transcript search failed: %s"
                      (string-trim (buffer-string))))
         (t
          (goto-char (point-min))
          (let ((matches (make-hash-table :test #'equal)))
            (while (not (eobp))
              (let ((line
                     (buffer-substring-no-properties
                      (line-beginning-position)
                      (line-end-position))))
                (unless (string-empty-p line)
                  (when-let* ((entry
                               (agent-shell-vertico-transcript--rg-match-from-json
                                line)))
                    (let* ((file (car entry))
                           (match (gethash file matches)))
                      (if match
                          (plist-put
                           match :count
                           (1+ (plist-get match :count)))
                        (puthash file (cdr entry) matches))))))
              (forward-line 1))
            (let (result)
              (maphash
               (lambda (file match)
                 (push (cons file match) result))
               matches)
              (nreverse result)))))))))

(defun agent-shell-vertico-transcript--root-for-record
    (record project-roots)
  "Return the project root for RECORD among PROJECT-ROOTS."
  (or
   (when-let* ((working-directory
                (agent-shell-vertico-transcript-record-working-directory
                 record)))
     (seq-find
      (lambda (root)
        (agent-shell-vertico-transcript--same-directory-p
         working-directory root))
      project-roots))
   (seq-find
    (lambda (root)
      (file-in-directory-p
       (agent-shell-vertico-transcript-record-file record)
       (agent-shell-vertico-transcript--directory root)))
    project-roots)))

(defun agent-shell-vertico-transcript--record-for-match
    (file match project-roots)
  "Return a record for FILE and MATCH within PROJECT-ROOTS."
  (let* ((fallback-root
          (or (car project-roots)
              (file-name-directory file)))
         (record
          (agent-shell-vertico-transcript--parse-file
           file fallback-root))
         (project-root
          (agent-shell-vertico-transcript--root-for-record
           record project-roots)))
    (when (and project-root
               (agent-shell-vertico-transcript--record-in-project-p
                record project-root
                (agent-shell-vertico-transcript--directory
                 project-root)))
      (setf
       (agent-shell-vertico-transcript-record-project-root record)
       project-root
       (agent-shell-vertico-transcript-record-project-name record)
       (file-name-nondirectory
        (directory-file-name project-root))
       (agent-shell-vertico-transcript-record-match-count record)
       (plist-get match :count)
       (agent-shell-vertico-transcript-record-match-line record)
       (plist-get match :line)
       (agent-shell-vertico-transcript-record-match-text record)
       (plist-get match :text))
      record)))

(defun agent-shell-vertico-transcript--search (project-roots query)
  "Search PROJECT-ROOTS for transcripts matching QUERY.

Return one record per matching transcript, ordered by modification
time with the newest first."
  (let* ((project-roots
          (mapcar
           #'agent-shell-vertico-transcript--normalize-directory
           project-roots))
         (directories
          (agent-shell-vertico-transcript--search-directories
           project-roots))
         (matches
          (agent-shell-vertico-transcript--rg-matches
           directories query))
         records)
    (dolist (entry matches)
      (when-let* ((record
                   (agent-shell-vertico-transcript--record-for-match
                    (car entry) (cdr entry) project-roots)))
        (push record records)))
    (seq-sort
     (lambda (left right)
       (time-less-p
        (agent-shell-vertico-transcript-record-modified-time right)
        (agent-shell-vertico-transcript-record-modified-time left)))
     records)))

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
         (live-buffer
          (agent-shell-vertico-transcript--live-buffer session-id)))
    (cond
     (live-buffer
      (agent-shell-vertico--display-session
       (buffer-name live-buffer)))
     (session-id
      (agent-shell-vertico-transcript--resume-record record))
     (t
      (agent-shell-vertico-transcript--open-record record)))))

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

(defun agent-shell-vertico-transcript--completing-read-record
    (prompt records)
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
     (when-let* ((candidate (assoc-string selection candidates)))
       (agent-shell-vertico-transcript--record-from-candidate candidate))
     (user-error "Transcript no longer exists"))))

(defvar agent-shell-vertico-transcript-read-record-function
  #'agent-shell-vertico-transcript--completing-read-record
  "Function used to read one transcript candidate.
It receives a prompt and a list of transcript records.")

(defun agent-shell-vertico-transcript--read-record (prompt records)
  "Read one transcript from RECORDS with PROMPT."
  (funcall
   agent-shell-vertico-transcript-read-record-function
   prompt records))

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
     (when-let* ((candidate (assoc-string selection candidates)))
       (get-text-property
        0 'agent-shell-vertico-project-root candidate))
     (user-error "No known projects"))))

(defun agent-shell-vertico-transcript--current-project-or-error ()
  "Return the current project root or signal a user error."
  (or
   (agent-shell-vertico-transcript--current-project-root)
   (user-error "Not in a project")))

(defvar-local agent-shell-vertico-transcript--record nil
  "Transcript record associated with the current transcript buffer.")

(defvar-local agent-shell-vertico-transcript--last-navigation nil
  "Last speaker heading reached by transcript navigation.")

(defvar-keymap agent-shell-vertico-transcript-mode-map
  :doc "Keymap for `agent-shell-vertico-transcript-mode'."
  "r" #'agent-shell-vertico-transcript-resume-current
  "R" #'agent-shell-vertico-transcript-force-resume-current
  "c" #'agent-shell-vertico-transcript-clean-view
  "b" #'agent-shell-vertico-transcript-browse-from-current
  "i" #'agent-shell-vertico-transcript-set-session-id
  "n" #'agent-shell-vertico-transcript-next-user
  "p" #'agent-shell-vertico-transcript-previous-user
  "N" #'agent-shell-vertico-transcript-next-agent
  "P" #'agent-shell-vertico-transcript-previous-agent)

(defvar-keymap agent-shell-vertico-transcript-embark-map
  :doc "Embark actions for `agent-shell' transcripts."
  "o" #'agent-shell-vertico-transcript-embark-open
  "b" #'agent-shell-vertico-transcript-embark-open
  "O" #'agent-shell-vertico-transcript-embark-open-other-window
  "r" #'agent-shell-vertico-transcript-embark-resume
  "R" #'agent-shell-vertico-transcript-embark-force-resume
  "d" #'agent-shell-vertico-transcript-embark-directory
  "c" #'agent-shell-vertico-transcript-embark-clean-view
  "i" #'agent-shell-vertico-transcript-embark-copy-session-id
  "I" #'agent-shell-vertico-transcript-embark-set-session-id
  "w" #'agent-shell-vertico-transcript-embark-copy-working-directory
  "f" #'agent-shell-vertico-transcript-embark-copy-file)

(defun agent-shell-vertico-transcript--header-line ()
  "Return a header line for the current transcript buffer."
  (when agent-shell-vertico-transcript--record
    (let ((record agent-shell-vertico-transcript--record))
      (format
       " %s · %s · %s    [r] Resume  [R] Force  [c] Clean  [b] Browse"
       (or
        (agent-shell-vertico-transcript-record-agent record)
        "Unknown agent")
       (or
        (agent-shell-vertico-transcript-record-project-name record)
        "Unscoped")
       (agent-shell-vertico-transcript--record-status record)))))

(define-minor-mode agent-shell-vertico-transcript-mode
  "Read and act on an `agent-shell' transcript."
  :lighter " Transcript"
  :keymap agent-shell-vertico-transcript-mode-map
  (if agent-shell-vertico-transcript-mode
      (progn
        (setq-local header-line-format
                    '(:eval
                      (agent-shell-vertico-transcript--header-line)))
        (read-only-mode 1))
    (setq-local header-line-format nil)
    (read-only-mode -1)))

(defun agent-shell-vertico-transcript--resume-record (record)
  "Resume transcript RECORD without checking for a live buffer."
  (let ((session-id
         (agent-shell-vertico-transcript-record-session-id record))
        (file
         (agent-shell-vertico-transcript-record-file record)))
    (unless session-id
      (user-error "This transcript has no session ID"))
    (let ((default-directory
           (or
            (agent-shell-vertico-transcript-record-working-directory
             record)
            default-directory))
          (agent-shell-transcript-file-path-function
           (lambda () file)))
      (agent-shell-resume-session session-id))))

(defun agent-shell-vertico-transcript--open-record
    (record &optional other-window)
  "Open transcript RECORD, optionally in OTHER-WINDOW."
  (let* ((file
          (agent-shell-vertico-transcript-record-file record))
         (buffer
          (if other-window
              (find-file-other-window file)
            (find-file file))))
    (with-current-buffer buffer
      (setq-local agent-shell-vertico-transcript--record record)
      (agent-shell-vertico-transcript-mode 1)
      (when-let* ((line
                   (agent-shell-vertico-transcript-record-match-line
                    record)))
        (goto-char (point-min))
        (forward-line (1- line))))
    buffer))

(defun agent-shell-vertico-transcript--current-record ()
  "Return the transcript record associated with the current buffer."
  (or
   agent-shell-vertico-transcript--record
   (when-let* ((file (buffer-file-name)))
     (let* ((fallback-root
             (or
              (agent-shell-vertico-transcript--current-project-root)
              default-directory))
            (record
             (agent-shell-vertico-transcript--parse-file
              file fallback-root))
            (working-directory
             (agent-shell-vertico-transcript-record-working-directory
              record)))
       (when working-directory
         (setf
          (agent-shell-vertico-transcript-record-project-root record)
          working-directory
          (agent-shell-vertico-transcript-record-project-name record)
          (file-name-nondirectory
           (directory-file-name working-directory))))
       record))
   (user-error "Current buffer is not an agent-shell transcript")))

(defun agent-shell-vertico-transcript--move-to-speaker
    (speaker direction)
  "Move to the next or previous SPEAKER heading in DIRECTION."
  (let ((regexp
         (format "^## %s\\(?:[ \t(].*\\)?$"
                 (regexp-quote speaker)))
        found)
    (when (and (> direction 0)
               (looking-at-p regexp)
               (or
                (not (= (point) (point-min)))
                (equal
                 agent-shell-vertico-transcript--last-navigation
                 (cons speaker (point)))))
      (forward-line 1))
    (setq found
          (if (> direction 0)
              (re-search-forward regexp nil t)
            (re-search-backward regexp nil t)))
    (if found
        (progn
          (goto-char (match-beginning 0))
          (setq
           agent-shell-vertico-transcript--last-navigation
           (cons speaker (point))))
      (user-error "No %s %s message"
                  (if (> direction 0) "next" "previous")
                  (downcase speaker)))))

(defun agent-shell-vertico-transcript-next-user ()
  "Move to the next user message."
  (interactive)
  (agent-shell-vertico-transcript--move-to-speaker "User" 1))

(defun agent-shell-vertico-transcript-previous-user ()
  "Move to the previous user message."
  (interactive)
  (agent-shell-vertico-transcript--move-to-speaker "User" -1))

(defun agent-shell-vertico-transcript-next-agent ()
  "Move to the next agent message."
  (interactive)
  (agent-shell-vertico-transcript--move-to-speaker "Agent" 1))

(defun agent-shell-vertico-transcript-previous-agent ()
  "Move to the previous agent message."
  (interactive)
  (agent-shell-vertico-transcript--move-to-speaker "Agent" -1))

(defun agent-shell-vertico-transcript--clean-text (text)
  "Return user and agent sections extracted from transcript TEXT."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (let (sections)
      (while
          (re-search-forward
           "^## \\(?:User\\|Agent\\)\\(?:[ \t(].*\\)?$"
           nil t)
        (let* ((start (match-beginning 0))
               (end
                (save-excursion
                  (goto-char (match-end 0))
                  (if
                      (re-search-forward
                       "^\\(?:## \\|### Tool Call\\)"
                       nil t)
                      (match-beginning 0)
                    (point-max)))))
          (push
           (string-trim-right
            (buffer-substring-no-properties start end))
           sections)
          (goto-char end)))
      (concat
       (mapconcat #'identity (nreverse sections) "\n\n")
       "\n"))))

(defun agent-shell-vertico-transcript-clean-view ()
  "Display a clean view containing only user and agent messages."
  (interactive)
  (let* ((source (current-buffer))
         (name
          (format "*Agent transcript: %s*"
                  (file-name-base
                   (or (buffer-file-name source)
                       (buffer-name source)))))
         (buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert
         (with-current-buffer source
           (agent-shell-vertico-transcript--clean-text
            (buffer-substring-no-properties
             (point-min) (point-max)))))
        (goto-char (point-min))
        (special-mode)))
    (pop-to-buffer buffer)))

(defun agent-shell-vertico-transcript-resume-current ()
  "Smart-resume the current transcript or switch to its live session."
  (interactive)
  (agent-shell-vertico-transcript--activate
   (agent-shell-vertico-transcript--current-record)))

(defun agent-shell-vertico-transcript-force-resume-current ()
  "Resume the current transcript in a new shell buffer."
  (interactive)
  (agent-shell-vertico-transcript--resume-record
   (agent-shell-vertico-transcript--current-record)))

(defun agent-shell-vertico-transcript--set-session-id-in-text
    (text session-id)
  "Return TEXT with its transcript header set to SESSION-ID."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (if
        (re-search-forward
         "^\\*\\*Session\\(?: ID\\)?:\\*\\*[ \t]+.*$"
         nil t)
        (replace-match
         (format "**Session ID:** %s" session-id)
         t t)
      (goto-char (point-min))
      (if (re-search-forward "^---[ \t]*$" nil t)
          (progn
            (beginning-of-line)
            (insert (format "**Session ID:** %s\n" session-id)))
        (goto-char (point-max))
        (unless (bolp)
          (insert "\n"))
        (insert (format "**Session ID:** %s\n" session-id))))
    (buffer-string)))

;;;###autoload
(defun agent-shell-vertico-transcript-set-session-id (session-id)
  "Set the current transcript's session header to SESSION-ID."
  (interactive
   (let* ((record
           (agent-shell-vertico-transcript--current-record))
          (current
           (agent-shell-vertico-transcript-record-session-id record)))
     (list
      (read-string
       (if current
           (format "Session ID (currently %s): " current)
         "Session ID: ")
       nil nil current))))
  (setq session-id (string-trim session-id))
  (when (string-empty-p session-id)
    (user-error "Session ID cannot be empty"))
  (let* ((record
          (agent-shell-vertico-transcript--current-record))
         (file
          (agent-shell-vertico-transcript-record-file record))
         (buffer
          (or (find-buffer-visiting file)
              (find-file-noselect file))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (point (point))
            (text
             (buffer-substring-no-properties
              (point-min) (point-max))))
        (erase-buffer)
        (insert
         (agent-shell-vertico-transcript--set-session-id-in-text
          text
          session-id))
        (goto-char (min point (point-max)))
        (save-buffer))
      (when agent-shell-vertico-transcript--record
        (setf
         (agent-shell-vertico-transcript-record-session-id
          agent-shell-vertico-transcript--record)
         session-id)))
    (setf
     (agent-shell-vertico-transcript-record-session-id record)
     session-id)
    (message "Set transcript session ID to %s" session-id)))

(defun agent-shell-vertico-transcript-browse-from-current ()
  "Browse transcripts belonging to the current transcript's project."
  (interactive)
  (let ((project-root
         (agent-shell-vertico-transcript-record-project-root
          (agent-shell-vertico-transcript--current-record))))
    (unless project-root
      (user-error "Transcript has no project directory"))
    (quit-window)
    (agent-shell-vertico-transcript--browse-project-root
     project-root)))

(defun agent-shell-vertico-transcript--embark-record (candidate)
  "Return the transcript record carried by Embark CANDIDATE."
  (or
   (get-text-property
    0 'agent-shell-vertico-transcript-record candidate)
   (user-error "Candidate has no transcript record")))

(defun agent-shell-vertico-transcript-embark-open (candidate)
  "Open transcript CANDIDATE."
  (agent-shell-vertico-transcript--open-record
   (agent-shell-vertico-transcript--embark-record candidate)))

(defun agent-shell-vertico-transcript-embark-open-other-window
    (candidate)
  "Open transcript CANDIDATE in another window."
  (agent-shell-vertico-transcript--open-record
   (agent-shell-vertico-transcript--embark-record candidate) t))

(defun agent-shell-vertico-transcript-embark-resume (candidate)
  "Smart-resume transcript CANDIDATE."
  (agent-shell-vertico-transcript--activate
   (agent-shell-vertico-transcript--embark-record candidate)))

(defun agent-shell-vertico-transcript-embark-force-resume (candidate)
  "Force-resume transcript CANDIDATE."
  (agent-shell-vertico-transcript--resume-record
   (agent-shell-vertico-transcript--embark-record candidate)))

(defun agent-shell-vertico-transcript-embark-directory (candidate)
  "Open CANDIDATE's working directory in Dired."
  (let* ((record
          (agent-shell-vertico-transcript--embark-record candidate))
         (directory
          (or
           (agent-shell-vertico-transcript-record-working-directory
            record)
           (file-name-directory
            (agent-shell-vertico-transcript-record-file record)))))
    (dired directory)))

(defun agent-shell-vertico-transcript-embark-set-session-id (candidate)
  "Set the session ID for transcript CANDIDATE."
  (agent-shell-vertico-transcript--open-record
   (agent-shell-vertico-transcript--embark-record candidate))
  (call-interactively #'agent-shell-vertico-transcript-set-session-id))

(defun agent-shell-vertico-transcript-embark-clean-view (candidate)
  "Open transcript CANDIDATE and display its clean view."
  (agent-shell-vertico-transcript--open-record
   (agent-shell-vertico-transcript--embark-record candidate))
  (agent-shell-vertico-transcript-clean-view))

(defun agent-shell-vertico-transcript-embark-copy-session-id
    (candidate)
  "Copy transcript CANDIDATE's session ID."
  (let ((session-id
         (agent-shell-vertico-transcript-record-session-id
          (agent-shell-vertico-transcript--embark-record candidate))))
    (unless session-id
      (user-error "Transcript has no session ID"))
    (kill-new session-id)
    (message "Copied session ID: %s" session-id)))

(defun agent-shell-vertico-transcript-embark-copy-working-directory
    (candidate)
  "Copy transcript CANDIDATE's working directory."
  (let ((directory
         (agent-shell-vertico-transcript-record-working-directory
          (agent-shell-vertico-transcript--embark-record candidate))))
    (unless directory
      (user-error "Transcript has no working directory"))
    (kill-new directory)
    (message "Copied working directory: %s" directory)))

(defun agent-shell-vertico-transcript-embark-copy-file (candidate)
  "Copy transcript CANDIDATE's file name."
  (let ((file
         (agent-shell-vertico-transcript-record-file
          (agent-shell-vertico-transcript--embark-record candidate))))
    (kill-new file)
    (message "Copied transcript file: %s" file)))

;;;###autoload
(defun agent-shell-vertico-transcript-setup-embark ()
  "Register transcript candidates and actions with Embark."
  (interactive)
  (add-to-list
   'embark-keymap-alist
   '(agent-shell-transcript
     agent-shell-vertico-transcript-embark-map))
  (add-to-list
   'embark-default-action-overrides
   '(agent-shell-transcript
     . agent-shell-vertico-transcript-embark-open)))

(defun agent-shell-vertico-transcript--all-records (&optional project-roots)
  "Return deduplicated records for PROJECT-ROOTS.
When PROJECT-ROOTS is nil, use all known local projects."
  (let ((seen (make-hash-table :test #'equal))
        records)
    (dolist
        (root
         (or project-roots
             (agent-shell-vertico-transcript--project-roots)))
      (dolist
          (record
           (agent-shell-vertico-transcript--records-for-project root))
        (let ((file
               (agent-shell-vertico-transcript-record-file record)))
          (unless (gethash file seen)
            (puthash file t seen)
            (push record records)))))
    (seq-sort
     (lambda (left right)
       (time-less-p
        (agent-shell-vertico-transcript-record-modified-time right)
        (agent-shell-vertico-transcript-record-modified-time left)))
     records)))

(defun agent-shell-vertico-transcript--stats-for-records (records)
  "Return availability statistics for transcript RECORDS."
  (let ((live 0)
        (resumable 0)
        (transcript-only 0)
        (bytes 0))
    (dolist (record records)
      (let ((session-id
             (agent-shell-vertico-transcript-record-session-id record))
            (file
             (agent-shell-vertico-transcript-record-file record)))
        (cond
         ((agent-shell-vertico-transcript--live-buffer session-id)
          (cl-incf live))
         (session-id
          (cl-incf resumable))
         (t
          (cl-incf transcript-only)))
        (when-let* ((attributes
                     (and file
                          (file-exists-p file)
                          (file-attributes file))))
          (cl-incf bytes (file-attribute-size attributes)))))
    (list :total (length records)
          :live live
          :resumable resumable
          :transcript-only transcript-only
          :bytes bytes)))

(defun agent-shell-vertico-transcript--diagnostic-issues (records)
  "Return metadata issue descriptions for transcript RECORDS."
  (let ((missing-session-id 0)
        (missing-working-directory 0)
        (invalid-working-directory 0)
        (session-counts (make-hash-table :test #'equal))
        issues)
    (dolist (record records)
      (if-let* ((session-id
                 (agent-shell-vertico-transcript-record-session-id
                  record)))
          (puthash
           session-id
           (1+ (gethash session-id session-counts 0))
           session-counts)
        (cl-incf missing-session-id))
      (if-let* ((directory
                 (agent-shell-vertico-transcript-record-working-directory
                  record)))
          (unless (file-directory-p directory)
            (cl-incf invalid-working-directory))
        (cl-incf missing-working-directory)))
    (when (> missing-session-id 0)
      (push
       (format "%d transcript%s missing a session ID"
               missing-session-id
               (if (= missing-session-id 1) " is" "s are"))
       issues))
    (when (> missing-working-directory 0)
      (push
       (format "%d transcript%s missing a working directory"
               missing-working-directory
               (if (= missing-working-directory 1) " is" "s are"))
       issues))
    (when (> invalid-working-directory 0)
      (push
       (format "%d working director%s no longer exist%s"
               invalid-working-directory
               (if (= invalid-working-directory 1) "y" "ies")
               (if (= invalid-working-directory 1) "s" ""))
       issues))
    (maphash
     (lambda (session-id count)
       (when (> count 1)
         (push
          (format "Session ID %s is duplicate across %d transcripts"
                  session-id count)
          issues)))
     session-counts)
    (nreverse issues)))

;;;###autoload
(defun agent-shell-vertico-transcript-stats ()
  "Display statistics for known `agent-shell' transcripts."
  (interactive)
  (let* ((project-roots
          (agent-shell-vertico-transcript--project-roots))
         (records
          (agent-shell-vertico-transcript--all-records project-roots))
         (stats
          (agent-shell-vertico-transcript--stats-for-records records))
         (buffer
          (get-buffer-create "*Agent transcript statistics*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert
         (format
          (concat
           "Agent transcript statistics\n\n"
           "Projects:        %d\n"
           "Transcripts:     %d\n"
           "Live:            %d\n"
           "Resumable:       %d\n"
           "Transcript only: %d\n"
           "Disk usage:      %s\n")
          (length project-roots)
          (plist-get stats :total)
          (plist-get stats :live)
          (plist-get stats :resumable)
          (plist-get stats :transcript-only)
          (file-size-human-readable (plist-get stats :bytes))))
        (goto-char (point-min))
        (special-mode)))
    (pop-to-buffer buffer)))

;;;###autoload
(defun agent-shell-vertico-transcript-doctor ()
  "Check transcript discovery tools and metadata for common problems."
  (interactive)
  (let* ((project-roots
          (agent-shell-vertico-transcript--project-roots))
         (records
          (agent-shell-vertico-transcript--all-records project-roots))
         (issues
          (agent-shell-vertico-transcript--diagnostic-issues records))
         (buffer
          (get-buffer-create "*Agent transcript doctor*")))
    (unless (executable-find "rg")
      (push "rg is unavailable; full-text search will not work" issues))
    (unless project-roots
      (push "No local projects were discovered" issues))
    (unless records
      (push "No agent-shell transcripts were discovered" issues))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Agent transcript doctor\n\n")
        (if issues
            (dolist (issue (nreverse issues))
              (insert (format "• %s\n" issue)))
          (insert "No problems found.\n"))
        (goto-char (point-min))
        (special-mode)))
    (pop-to-buffer buffer)))

(defun agent-shell-vertico-transcript--read-project-record
    (project-root &optional resumable-only)
  "Read one transcript record for PROJECT-ROOT.
When RESUMABLE-ONLY is non-nil, omit records without session IDs."
  (let ((records
         (agent-shell-vertico-transcript--records-for-project
          project-root)))
    (when resumable-only
      (setq records
            (seq-filter
             #'agent-shell-vertico-transcript-record-session-id
             records)))
    (agent-shell-vertico-transcript--read-record
     (if resumable-only "Resume session: " "Transcript: ")
     records)))

(defun agent-shell-vertico-transcript--browse-project-root (project-root)
  "Select and open a transcript for PROJECT-ROOT."
  (agent-shell-vertico-transcript--open-record
   (agent-shell-vertico-transcript--read-project-record project-root)))

(defun agent-shell-vertico-transcript--resume-project-root (project-root)
  "Select and resume a transcript session for PROJECT-ROOT."
  (agent-shell-vertico-transcript--activate
   (agent-shell-vertico-transcript--read-project-record project-root t)))

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
  (agent-shell-vertico-transcript--resume-project-root
   (agent-shell-vertico-transcript--read-project)))

;;;###autoload
(defun agent-shell-vertico-transcript-resume-project ()
  "Resume a transcript session belonging to the current project."
  (interactive)
  (agent-shell-vertico-transcript--resume-project-root
   (agent-shell-vertico-transcript--current-project-or-error)))

(provide 'agent-shell-vertico-transcript)

;;; agent-shell-vertico-transcript.el ends here
