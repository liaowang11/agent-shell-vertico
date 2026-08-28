;;; agent-shell-vertico-transcript.el --- Transcript recall for agent-shell -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Bill and contributors

;; Author: Bill
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (agent-shell "0.63.5") (marginalia "2.1"))
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
(require 'mule-util)
(require 'project)
(require 'seq)
(require 'subr-x)

(defvar agent-shell-dot-subdir-function)
(defvar agent-shell-transcript-file-path-function)
;; No value: markdown-ts-mode's own `defcustom' must install the real
;; default when it loads after this file.
(defvar markdown-ts-view-mode-pre-init-hook)
(defvar embark-default-action-overrides)
(defvar embark-keymap-alist)
(defvar evil-local-mode)
(defvar evil-state)
(defvar projectile-current-project-on-switch)
(defvar projectile-mode)

(declare-function agent-shell--current-shell "agent-shell" ())
(declare-function agent-shell--resolved-agent-configs "agent-shell" ())
(declare-function dired "dired" (dirname &optional switches))
(declare-function evil-local-set-key "evil" (state key definition))
(declare-function projectile-project-root "projectile" (&optional dir))
(declare-function projectile-relevant-known-projects "projectile" ())
(declare-function treesit-language-available-p "treesit.c"
                  (language &optional detail))

(defgroup agent-shell-vertico-transcript nil
  "Transcript recall for `agent-shell'."
  :group 'agent-shell-vertico)

(defcustom agent-shell-vertico-transcript-candidate-limit 10000
  "Most transcripts offered at once, or nil to offer every one.

Transcripts are listed newest first, so the limit drops the oldest.
Whenever it drops any, the prompt says how many of the total are being
offered, rather than presenting a shortened list as the whole of it.

Every transcript still has to be read from disk before the list can be
ordered, so the limit bounds what the completion UI holds, not the time
it takes to open."
  :type '(choice (const :tag "No limit" nil) integer)
  :group 'agent-shell-vertico-transcript)

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
  title
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

(defun agent-shell-vertico-transcript--header-end ()
  "Return where the current buffer's transcript header ends.

The header ends at the `---' separator, or at the first speaker heading
when a transcript has none.  Bodies quote header fields verbatim
whenever an agent echoes a file or an older transcript, so a search for
a field has to stop here rather than pick a quoted line up."
  (save-excursion
    (let (separator speaker)
      (goto-char (point-min))
      (when (re-search-forward "^---[ \t]*$" nil t)
        (setq separator (match-beginning 0)))
      (goto-char (point-min))
      (when (re-search-forward "^## " nil t)
        (setq speaker (match-beginning 0)))
      (min (or separator (point-max))
           (or speaker (point-max))))))

(defun agent-shell-vertico-transcript--header-value (label)
  "Return the current buffer's Markdown header value for LABEL."
  (let ((header-end (agent-shell-vertico-transcript--header-end)))
    (goto-char (point-min))
    (when (re-search-forward
           (format "^\\*\\*%s:\\*\\*[ \t]+\\(.+\\)$" (regexp-quote label))
           header-end t)
      (string-trim (match-string-no-properties 1)))))

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
           (title (agent-shell-vertico-transcript--header-value "Title"))
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
       :title title
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
TRANSCRIPT-DIRECTORY identifies project-local stores.  Shared stores use
the record's working directory to distinguish projects."
  (let ((working-directory
         (agent-shell-vertico-transcript-record-working-directory record)))
    (or
     ;; A project-local store is authoritative even when a transcript was
     ;; written from a subdirectory or carries a path from another machine.
     (agent-shell-vertico-transcript--same-directory-p
      transcript-directory project-root)
     (file-in-directory-p transcript-directory project-root)
     ;; A shared store needs the header to disambiguate projects, but a
     ;; working directory anywhere under the root still belongs to it.
     (and working-directory
          (or
           (agent-shell-vertico-transcript--same-directory-p
            working-directory project-root)
           (file-in-directory-p working-directory project-root))))))

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

(defun agent-shell-vertico-transcript--rg-field (data field)
  "Return FIELD of rg match DATA as a string, or nil when absent.

rg reports a path or a matched line that is not valid UTF-8 as base64
under `bytes' instead of as `text', so a transcript holding binary tool
output would otherwise stop the search at its first match."
  (let ((value (map-elt data field)))
    (or (map-elt value 'text)
        (when-let* ((bytes (map-elt value 'bytes)))
          (decode-coding-string (base64-decode-string bytes) 'utf-8)))))

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
        (when-let* ((data (map-elt event 'data))
                    (path
                     (agent-shell-vertico-transcript--rg-field data 'path)))
          (cons
           path
           (list
            :count 1
            :line (map-elt data 'line_number)
            :text
            (string-trim-right
             (or (agent-shell-vertico-transcript--rg-field data 'lines)
                 "")))))))))

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
     (car
      (seq-sort-by
       (lambda (root)
         (length (agent-shell-vertico-transcript--normalize-directory root)))
       #'>
       (seq-filter
        (lambda (root)
          (or
           (agent-shell-vertico-transcript--same-directory-p
            working-directory root)
           (file-in-directory-p working-directory root)))
        project-roots))))
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

(defun agent-shell-vertico-transcript--activate (record)
  "Switch to, resume, or open transcript RECORD."
  (let* ((session-id
          (agent-shell-vertico-transcript-record-session-id record))
         (live-buffer
          (agent-shell-vertico--live-session-buffer session-id)))
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
   ((agent-shell-vertico--live-session-buffer
     (agent-shell-vertico-transcript-record-session-id record))
    "Live")
   ((agent-shell-vertico-transcript-record-session-id record)
    "Resumable")
   (t "Transcript only")))

(defconst agent-shell-vertico-transcript--annotation-columns
  '((project . 0.3)
    (agent . 0.14)
    (status . 16)
    (changed . 12)
    (created . 16))
  "Truncation width of each annotation column, in display order.

A float is a fraction of `marginalia-field-width', which marginalia
resolves against the window width, so those columns shrink on a narrow
frame.  The project takes the widest fraction, because repository names
run to about twenty characters and it is the column readers scan first.
The two time columns are fixed, because a timestamp cut in half tells the
reader nothing.  `--record-annotation' renders these columns
and `--candidate-width' subtracts them from the window, so the two stay
in step.")

(defun agent-shell-vertico-transcript--column-width (name)
  "Return the truncation width of the annotation column NAME."
  (alist-get name agent-shell-vertico-transcript--annotation-columns))

(defun agent-shell-vertico-transcript--resolve-width (width)
  "Return WIDTH in columns, resolving a fraction against the field width."
  (if (floatp width)
      (round (* width marginalia-field-width))
    width))

(defun agent-shell-vertico-transcript--field (value width face)
  "Return VALUE as an annotation column of WIDTH, drawn in FACE.

WIDTH is a column count or a fraction of `marginalia-field-width'.

The columns are padded here rather than by `marginalia--fields'.  That
macro expands where this file is compiled, so building the package
against the marginalia test stub would freeze the stub's plain
concatenation into the compiled file, and every annotation would lose its
padding, its faces and the marker marginalia aligns by."
  (let* ((width (agent-shell-vertico-transcript--resolve-width width))
         (text (truncate-string-to-width (or value "") width 0 ?\s
                                         (truncate-string-ellipsis))))
    (unless (string-prefix-p (or value "") text)
      (put-text-property 0 (length text) 'help-echo value text))
    (put-text-property 0 (length text) 'face face text)
    text))

(defconst agent-shell-vertico-transcript--align-marker
  (propertize " " 'marginalia--align t)
  "Space marking where marginalia may pad to align annotations.

`marginalia--align' looks for this property to decide how far to indent
every annotation in the list.")

(defun agent-shell-vertico-transcript--fields (fields)
  "Return FIELDS as one annotation string.

Each entry in FIELDS is a value, a column width, and a face.  Columns are
separated by `marginalia-separator', as marginalia's own annotations are."
  (concat
   agent-shell-vertico-transcript--align-marker
   (mapconcat
    (lambda (field)
      (pcase-let ((`(,value ,width ,face) field))
        (concat marginalia-separator
                (agent-shell-vertico-transcript--field value width face))))
    fields
    "")))

(defun agent-shell-vertico-transcript--annotation-width (window-width)
  "Return the widest annotation the columns produce in WINDOW-WIDTH.

Marginalia resolves a fractional column against half the window, capped
by `marginalia-field-width', and puts `marginalia-separator' before every
column."
  (let ((field-width (min (/ window-width 2) marginalia-field-width))
        (separator (string-width marginalia-separator)))
    (cl-loop
     for (_name . width) in agent-shell-vertico-transcript--annotation-columns
     sum (+ separator
            (if (floatp width)
                (round (* width field-width))
              width)))))

(defconst agent-shell-vertico-transcript--candidate-width-step 10
  "Step marginalia rounds the annotation column up to.
Mirrors `marginalia--cand-width-step'.")

(defconst agent-shell-vertico-transcript--candidate-width-min 19
  "Smallest width a candidate keeps.
Below roughly ninety columns of window the annotation no longer fits
beside a readable candidate.  The annotation is cut there rather than the
candidate shrinking to nothing.")

(defun agent-shell-vertico-transcript--candidate-width (window-width)
  "Return the display width a candidate may use inside WINDOW-WIDTH.

Marginalia starts the annotation at the widest candidate rounded up to a
multiple of `--candidate-width-step' and never checks that the annotation
still fits, so one long title pushes every column past the right edge of
every row.  Reserving the annotation its own room is what keeps the
columns on screen.  The result is one column short of a multiple of the
step, because the invisible key character counts toward the width
marginalia measures."
  (let ((step agent-shell-vertico-transcript--candidate-width-step))
    (max agent-shell-vertico-transcript--candidate-width-min
         (1- (* step
                (/ (- window-width
                      (agent-shell-vertico-transcript--annotation-width
                       window-width))
                   step))))))

(defun agent-shell-vertico-transcript--truncate (string width)
  "Return STRING within WIDTH columns, keeping the whole of it reachable.
The full text goes on `help-echo', which is what the completion UI shows
when the reader points at the candidate."
  (if (<= (string-width string) width)
      string
    (let ((short (truncate-string-to-width string width 0 nil t)))
      (put-text-property 0 (length short) 'help-echo string short)
      short)))

(defun agent-shell-vertico-transcript--candidate-text (record &optional width)
  "Return the text shown for RECORD in completion.

The session title when the transcript has one, else its first user
message.  No time is shown: the list is ordered by last change and the
annotation carries both times.  WIDTH, when given, is how many columns
the text may use."
  (let ((text
         (or (agent-shell-vertico-transcript-record-title record)
             (agent-shell-vertico-transcript-record-preview record)
             (file-name-sans-extension
              (file-name-nondirectory
               (agent-shell-vertico-transcript-record-file record))))))
    (if width
        (agent-shell-vertico-transcript--truncate text width)
      text)))

(defun agent-shell-vertico-transcript--record-candidate
    (record &optional index width)
  "Return a completion candidate for RECORD.
With INDEX, append the invisible key that keeps candidates distinct.
WIDTH, when given, is how many columns the candidate text may use."
  (let ((candidate
         (concat
          (agent-shell-vertico-transcript--candidate-text record width)
          (when index
            (agent-shell-vertico--candidate-key index)))))
    (put-text-property
     0 (length candidate) 'agent-shell-vertico-transcript-record
     record candidate)
    candidate))

(defun agent-shell-vertico-transcript--record-candidates
    (records &optional width)
  "Return one distinct completion candidate per record in RECORDS.
WIDTH is how many columns a candidate may use, by default whatever the
minibuffer leaves once the annotation has its room."
  (let ((width
         (or width
             (agent-shell-vertico-transcript--candidate-width
              (window-width (minibuffer-window))))))
    (seq-map-indexed
     (lambda (record index)
       (agent-shell-vertico-transcript--record-candidate record index width))
     records)))

(defun agent-shell-vertico-transcript--record-from-candidate (candidate)
  "Return the transcript record carried by CANDIDATE."
  (when (and (stringp candidate)
             (> (length candidate) 0))
    (get-text-property
     0 'agent-shell-vertico-transcript-record candidate)))

(defun agent-shell-vertico-transcript--record-created (record)
  "Return RECORD's creation time for display."
  (let ((started (agent-shell-vertico-transcript-record-started record)))
    (cond
     ((and started (>= (length started) 16)) (substring started 0 16))
     (started started)
     (t
      (format-time-string
       "%F %R"
       (agent-shell-vertico-transcript-record-modified-time record))))))

(defun agent-shell-vertico-transcript--record-annotation (candidate)
  "Return an annotation for transcript CANDIDATE.

Columns run from most to least identifying: the project, the agent, and
whether the session can be reached, then when it last changed and when it
started.

The first user message is not a column.  It claimed up to a third of the
row, and the candidate itself shows it whenever a transcript has no
title.

The last change is always a relative age and the start is always a
stamp, and the two carry different faces, so the columns never read as
two of the same thing.  `marginalia--time' would switch to a stamp after
two weeks, which is what made them hard to tell apart."
  (when-let* ((record
               (agent-shell-vertico-transcript--record-from-candidate
                candidate)))
    (agent-shell-vertico-transcript--fields
     (list
      (list (or (agent-shell-vertico-transcript-record-project-name record) "-")
            (agent-shell-vertico-transcript--column-width 'project)
            'marginalia-value)
      (list (or (agent-shell-vertico-transcript-record-agent record) "-")
            (agent-shell-vertico-transcript--column-width 'agent)
            'marginalia-value)
      (list (agent-shell-vertico-transcript--record-status record)
            (agent-shell-vertico-transcript--column-width 'status)
            'marginalia-type)
      (list (marginalia--time-relative
             (agent-shell-vertico-transcript-record-modified-time record))
            (agent-shell-vertico-transcript--column-width 'changed)
            'marginalia-date)
      (list (agent-shell-vertico-transcript--record-created record)
            (agent-shell-vertico-transcript--column-width 'created)
            'shadow)))))

(add-to-list 'marginalia-annotators
             '(agent-shell-transcript
               agent-shell-vertico-transcript--record-annotation none))

(defconst agent-shell-vertico-transcript--narrow-keys
  '((?l . "Live")
    (?r . "Resumable")
    (?t . "Transcript only")
    (?p . "This project")
    (?d . "Today")
    (?w . "Last 7 days"))
  "Narrowing keys offered for transcripts, before the agent keys.

The first three are named after the availability they select, which is
what `agent-shell-vertico-transcript--record-status' answers.")

(defun agent-shell-vertico-transcript--narrow-context ()
  "Return what a transcript narrowing predicate needs from the caller.

Read before the reader opens its minibuffer: the project is the one the
command was called from, and the day is the day the list was offered on.
Neither is knowable once the minibuffer is current."
  (list :project (agent-shell-vertico-transcript--current-project-root)
        :now (current-time)))

(defun agent-shell-vertico-transcript--same-day-p (left right)
  "Return non-nil when times LEFT and RIGHT fall on the same day."
  (equal (format-time-string "%F" left)
         (format-time-string "%F" right)))

(defconst agent-shell-vertico-transcript--week (* 7 24 60 60)
  "Seconds in the week the `Last 7 days' narrowing key covers.")

(defun agent-shell-vertico-transcript--record-narrow-p (key record context)
  "Return non-nil when transcript RECORD belongs to narrowing KEY.

CONTEXT is what `agent-shell-vertico-transcript--narrow-context' read.
A nil KEY is no narrowing at all, so every record belongs to it, and a
key standing for nothing selects nothing."
  (if (null key)
      t
    (let ((now (or (plist-get context :now) (current-time)))
          (modified
           (agent-shell-vertico-transcript-record-modified-time record)))
      (pcase key
        ((or ?l ?r ?t)
         (equal (agent-shell-vertico-transcript--record-status record)
                (alist-get key agent-shell-vertico-transcript--narrow-keys)))
        (?p (agent-shell-vertico-transcript--same-directory-p
             (agent-shell-vertico-transcript-record-project-root record)
             (plist-get context :project)))
        (?d (and modified
                 (agent-shell-vertico-transcript--same-day-p modified now)))
        (?w (and modified
                 (< (float-time (time-subtract now modified))
                    agent-shell-vertico-transcript--week)))
        (_ (agent-shell-vertico--narrow-agent-match-p
            (agent-shell-vertico-transcript-record-agent record) key))))))

(defun agent-shell-vertico-transcript--narrow-p (key candidate context)
  "Return non-nil when transcript CANDIDATE belongs to narrowing KEY.
The record travels with the candidate, so this is the same question
`agent-shell-vertico-transcript--record-narrow-p' answers."
  (if (null key)
      t
    (when-let* ((record
                 (agent-shell-vertico-transcript--record-from-candidate
                  candidate)))
      (agent-shell-vertico-transcript--record-narrow-p key record context))))

(defun agent-shell-vertico-transcript--group (candidate transform)
  "Return the group title of transcript CANDIDATE.
With TRANSFORM, return CANDIDATE as the completion UI should display it,
which is unchanged: the candidate already shows the title or the first
message, and nothing of it belongs to the group heading."
  (if transform
      candidate
    (when-let* ((agent-shell-vertico-group-by)
                (record
                 (agent-shell-vertico-transcript--record-from-candidate
                  candidate)))
      (pcase agent-shell-vertico-group-by
        ('project
         (agent-shell-vertico-transcript-record-project-name record))
        ('agent (agent-shell-vertico-transcript-record-agent record))
        ('status
         (agent-shell-vertico-transcript--record-status record))))))

(defun agent-shell-vertico-transcript--completing-read-record
    (prompt records)
  "Read one transcript from RECORDS with PROMPT."
  (unless records
    (user-error "No matching agent-shell transcripts"))
  (let* ((candidates
          (agent-shell-vertico-transcript--record-candidates records))
         (selection
          ;; Keep the text properties on the returned candidate so the
          ;; record comes back directly, rather than through a lookup by
          ;; display text that repeated titles make ambiguous.
          (let ((minibuffer-allow-text-properties t))
            (completing-read
             prompt
             (lambda (string pred action)
               (if (eq action 'metadata)
                   `(metadata
                     (category . agent-shell-transcript)
                     (annotation-function
                      . ,#'agent-shell-vertico-transcript--record-annotation)
                     ,@(when agent-shell-vertico-group-by
                         `((group-function
                            . ,#'agent-shell-vertico-transcript--group)))
                     (display-sort-function . identity)
                     (cycle-sort-function . identity))
                 (complete-with-action action candidates string pred)))
             nil t))))
    (or
     (agent-shell-vertico-transcript--record-from-candidate selection)
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

(defconst agent-shell-vertico-transcript--clean-invisibility
  'agent-shell-vertico-transcript-clean
  "Invisibility category used by the clean transcript view.")

(defconst agent-shell-vertico-transcript--event-timestamp-regexp
  (concat
   "[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\} "
   "[0-9]\\{2\\}:[0-9]\\{2\\}:[0-9]\\{2\\}")
  "Timestamp format used in transcript event headings.")

(defconst agent-shell-vertico-transcript--message-heading-regexp
  (concat
   "^## \\(?:Agent\\|User\\(?: (injected)\\)?\\)"
   "\\(?: ("
   agent-shell-vertico-transcript--event-timestamp-regexp
   ")\\)?[ \t]*$")
  "Heading that begins visible user or agent transcript content.")

(defconst agent-shell-vertico-transcript--thought-heading-regexp
  (concat
   "^## Agent's Thoughts\\(?: ("
   agent-shell-vertico-transcript--event-timestamp-regexp
   ")\\)?[ \t]*$")
  "Heading that begins hidden agent thought transcript content.")

(defconst agent-shell-vertico-transcript--tool-heading-regexp
  "^### Tool Call \\[[^]\n]+\\]:.*$"
  "Heading that begins hidden tool transcript content.")

(defvar-local agent-shell-vertico-transcript--clean-overlays nil
  "Overlays hiding non-message text in the current transcript buffer.")

(defvar-local agent-shell-vertico-transcript--clean-view-p nil
  "Non-nil while the current transcript shows its clean view.")

(defun agent-shell-vertico-transcript--show-full-view ()
  "Restore the full transcript in the current buffer."
  (mapc #'delete-overlay agent-shell-vertico-transcript--clean-overlays)
  (setq agent-shell-vertico-transcript--clean-overlays nil
        agent-shell-vertico-transcript--clean-view-p nil)
  (remove-from-invisibility-spec
   agent-shell-vertico-transcript--clean-invisibility))

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
  "P" #'agent-shell-vertico-transcript-previous-agent
  "]" #'agent-shell-vertico-transcript-next-message
  "[" #'agent-shell-vertico-transcript-previous-message
  "?" #'agent-shell-vertico-transcript-help)

(defconst agent-shell-vertico-transcript--evil-bindings
  '(("gr" . agent-shell-vertico-transcript-resume-current)
    ("gR" . agent-shell-vertico-transcript-force-resume-current)
    ("gc" . agent-shell-vertico-transcript-clean-view)
    ("gb" . agent-shell-vertico-transcript-browse-from-current)
    ("gi" . agent-shell-vertico-transcript-set-session-id)
    ("g?" . agent-shell-vertico-transcript-help)
    ("]]" . agent-shell-vertico-transcript-next-message)
    ("[[" . agent-shell-vertico-transcript-previous-message)
    ("]u" . agent-shell-vertico-transcript-next-user)
    ("[u" . agent-shell-vertico-transcript-previous-user)
    ("]a" . agent-shell-vertico-transcript-next-agent)
    ("[a" . agent-shell-vertico-transcript-previous-agent))
  "Transcript bindings for Evil normal and motion states.

Evil's state keymaps take precedence over minor mode maps, so the
single-key bindings in `agent-shell-vertico-transcript-mode-map' never
run while Evil is in normal state.  Every key here is a two-key sequence
starting with `g', `]' or `[', which Emacs looks up across all active
keymaps: Evil's own `gg', `gv', `]p' and the rest stay reachable, and no
single-key Evil command is shadowed.  The bracket pairs follow the
vim-unimpaired convention, where `]' moves forward and `[' backward.")

(defun agent-shell-vertico-transcript--bind-evil-keys ()
  "Install `agent-shell-vertico-transcript--evil-bindings' for this buffer.
Does nothing when Evil is not loaded."
  (when (fboundp 'evil-local-set-key)
    (dolist (state '(normal motion))
      (dolist (binding agent-shell-vertico-transcript--evil-bindings)
        (evil-local-set-key state (kbd (car binding)) (cdr binding))))))

(defun agent-shell-vertico-transcript--unbind-evil-keys ()
  "Remove `agent-shell-vertico-transcript--evil-bindings' from this buffer."
  (when (fboundp 'evil-local-set-key)
    (dolist (state '(normal motion))
      (dolist (binding agent-shell-vertico-transcript--evil-bindings)
        (evil-local-set-key state (kbd (car binding)) nil)))))

(defun agent-shell-vertico-transcript--evil-state-p ()
  "Return non-nil when Evil handles keys in the current buffer."
  (and (bound-and-true-p evil-local-mode)
       (memq (bound-and-true-p evil-state) '(normal motion visual))))

(defconst agent-shell-vertico-transcript--help-buffer
  "*Agent Shell Transcript Help*"
  "Buffer used by `agent-shell-vertico-transcript-help'.")

(defun agent-shell-vertico-transcript--help-text ()
  "Return the key reference shown by `agent-shell-vertico-transcript-help'."
  (concat
   "Agent Shell Transcript\n"
   "======================\n\n"
   "Keys\n"
   "  r / R       Resume / resume in a new shell\n"
   "  c           Toggle clean/full content\n"
   "  b           Browse this project's transcripts\n"
   "  i           Set the session ID header\n"
   "  n / p       Next / previous user message\n"
   "  N / P       Next / previous agent message\n"
   "  ] / [       Next / previous message\n"
   "  ?           This help\n\n"
   "Keys in Evil normal and motion states\n"
   "  gr / gR     Resume / resume in a new shell\n"
   "  gc          Toggle clean/full content\n"
   "  gb          Browse this project's transcripts\n"
   "  gi          Set the session ID header\n"
   "  ]u / [u     Next / previous user message\n"
   "  ]a / [a     Next / previous agent message\n"
   "  ]] / [[     Next / previous message\n"
   "  g?          This help\n\n"
   "Evil states get two-key sequences only, so Evil's own g, ] and [\n"
   "commands and every text motion keep working.\n"))

(defun agent-shell-vertico-transcript-help ()
  "Display the transcript key reference."
  (interactive)
  (require 'help-mode)
  (with-help-window (get-buffer-create
                     agent-shell-vertico-transcript--help-buffer)
    (insert (agent-shell-vertico-transcript--help-text))))

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
  "Return a header line for the current transcript buffer.
Action keys are shown with the `g' prefix while Evil handles keys, since
that is how they are reached in Evil states."
  (when agent-shell-vertico-transcript--record
    (let ((record agent-shell-vertico-transcript--record)
          (prefix (if (agent-shell-vertico-transcript--evil-state-p)
                      "g"
                    "")))
      (format
       (concat
        " %s · %s · %s    [%sr] Resume  [%sR] Force  "
        "[%sc] %s  [%sb] Browse")
       (or
        (agent-shell-vertico-transcript-record-agent record)
        "Unknown agent")
       (or
        (agent-shell-vertico-transcript-record-project-name record)
        "Unscoped")
       (agent-shell-vertico-transcript--record-status record)
       prefix prefix prefix
       (if agent-shell-vertico-transcript--clean-view-p "Full" "Clean")
       prefix))))

(define-minor-mode agent-shell-vertico-transcript-mode
  "Read and act on an `agent-shell' transcript."
  :lighter " Transcript"
  :keymap agent-shell-vertico-transcript-mode-map
  (if agent-shell-vertico-transcript-mode
      (progn
        (setq-local header-line-format
                    '(:eval
                      (agent-shell-vertico-transcript--header-line)))
        (agent-shell-vertico-transcript--bind-evil-keys)
        (read-only-mode 1))
    (setq-local header-line-format nil)
    (agent-shell-vertico-transcript--unbind-evil-keys)
    (agent-shell-vertico-transcript--show-full-view)
    (read-only-mode -1)))

(defun agent-shell-vertico-transcript--config-for-agent (agent)
  "Return the `agent-shell' configuration named AGENT, or nil.

Transcript headers record the agent's `:mode-line-name', falling back
to its `:buffer-name' when the configuration sets no mode line name.

Entries are read through `agent-shell--resolved-agent-configs' because
`agent-shell-agent-configs' holds config-making functions by default,
and may itself be a function returning the list."
  (when agent
    (seq-find
     (lambda (config)
       (member agent
               (list (map-elt config :mode-line-name)
                     (map-elt config :buffer-name))))
     (agent-shell--resolved-agent-configs))))

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
      (agent-shell-vertico--resume-session
       session-id
       (agent-shell-vertico-transcript--config-for-agent
        (agent-shell-vertico-transcript-record-agent record))))))

(defun agent-shell-vertico-transcript--markdown-ts-view-mode-available-p ()
  "Return non-nil when the tree-sitter Markdown view mode is usable."
  (and (or (fboundp 'markdown-ts-view-mode)
           (require 'markdown-ts-mode nil t))
       (fboundp 'markdown-ts-view-mode)
       (fboundp 'treesit-language-available-p)
       (treesit-language-available-p 'markdown)
       (treesit-language-available-p 'markdown-inline)))

(defun agent-shell-vertico-transcript--markdown-major-mode ()
  "Return the Markdown major mode used to read a transcript, or nil.

Prefer `markdown-ts-view-mode', the read-only viewing mode built on
`markdown-ts-mode', which hides the markup and renders inline images.  A
transcript is read, not edited, and the reader makes the buffer read-only
anyway.

Emacs ships both modes but leaves them out of `auto-mode-alist', so a
transcript never reaches either on its own: the mode has to be loaded and
named here.  The `markdown' and `markdown-inline' grammars are checked
first, because without them the mode drops the buffer to Text mode and
warns, which is worse than the fallback.

Fall back to `markdown-mode', and to nil when neither mode is available,
which leaves the mode the file itself selects in place."
  (cond
   ((agent-shell-vertico-transcript--markdown-ts-view-mode-available-p)
    'markdown-ts-view-mode)
   ((fboundp 'markdown-mode)
    'markdown-mode)))

(defun agent-shell-vertico-transcript--set-markdown-major-mode ()
  "Put the current buffer in the Markdown mode transcripts are read in.

A mode already built on that one is left alone, so a reader who visits
transcripts in a mode derived from `markdown-mode' keeps it.

`markdown-ts-view-mode-pre-init-hook' is emptied for the mode call.  It
exists to amend buffer content, and its default adds a final newline,
which marks the buffer modified for every transcript that ends without
one.  A reader must not change the file it shows.  The cost is that the
grammar can misread markup at the very end of such a transcript."
  (when-let* ((mode (agent-shell-vertico-transcript--markdown-major-mode)))
    (unless (derived-mode-p mode)
      (let ((markdown-ts-view-mode-pre-init-hook nil))
        (funcall mode)))))

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
      ;; Before the record and the minor mode, since changing the major
      ;; mode clears both.
      (agent-shell-vertico-transcript--set-markdown-major-mode)
      (setq-local agent-shell-vertico-transcript--record record)
      (agent-shell-vertico-transcript-mode 1)
      (when-let* ((line
                   (agent-shell-vertico-transcript-record-match-line
                    record)))
        (goto-char (point-min))
        (forward-line (1- line))))
    buffer))

(defun agent-shell-vertico-transcript--record-from-file
    (file project-root)
  "Return the transcript record FILE describes, scoped to PROJECT-ROOT.

PROJECT-ROOT only stands in for the project a browsed record carries.
The transcript names the directory it was written for in its own header,
so that directory wins whenever the file has one."
  (let* ((record
          (agent-shell-vertico-transcript--parse-file file project-root))
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

(defun agent-shell-vertico-transcript--current-record ()
  "Return the transcript record associated with the current buffer."
  (or
   agent-shell-vertico-transcript--record
   (when-let* ((file (buffer-file-name)))
     (agent-shell-vertico-transcript--record-from-file
      file
      (or
       (agent-shell-vertico-transcript--current-project-root)
       default-directory)))
   (user-error "Current buffer is not an agent-shell transcript")))

;;;###autoload
(defun agent-shell-vertico-transcript-open-session ()
  "Open the transcript of the current session in the transcript reader.

Reads the session from an `agent-shell' buffer or from a viewport
showing one.  `agent-shell-open-transcript' visits the same file and
leaves the mode to the file itself, which for a transcript is no mode at
all.  This opens it the way `agent-shell-vertico-transcript-browse'
does: the Markdown reader, the header line, speaker navigation, the
clean view, and resume."
  (interactive)
  (let* ((shell (or (agent-shell--current-shell)
                    (user-error "Not in an agent-shell session")))
         (file (buffer-local-value 'agent-shell--transcript-file shell)))
    (unless file
      (user-error "No transcript file available for this session"))
    (unless (file-exists-p file)
      (user-error "Transcript file does not exist: %s" file))
    (agent-shell-vertico-transcript--open-record
     (agent-shell-vertico-transcript--record-from-file
      file (buffer-local-value 'default-directory shell)))))

(defun agent-shell-vertico-transcript--move-to-speaker
    (speakers direction)
  "Move to the next or previous heading for SPEAKERS in DIRECTION.
SPEAKERS is a list of heading names such as (\"User\")."
  (let ((regexp
         (format "^## \\(?:%s\\)\\(?:[ \t(].*\\)?$"
                 (mapconcat #'regexp-quote speakers "\\|")))
        found)
    (when (and (> direction 0)
               (looking-at-p regexp)
               (or
                (not (= (point) (point-min)))
                (equal
                 agent-shell-vertico-transcript--last-navigation
                 (cons speakers (point)))))
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
           (cons speakers (point))))
      (user-error "No %s %s message"
                  (if (> direction 0) "next" "previous")
                  (mapconcat #'downcase speakers " or ")))))

(defun agent-shell-vertico-transcript-next-user ()
  "Move to the next user message."
  (interactive)
  (agent-shell-vertico-transcript--move-to-speaker '("User") 1))

(defun agent-shell-vertico-transcript-previous-user ()
  "Move to the previous user message."
  (interactive)
  (agent-shell-vertico-transcript--move-to-speaker '("User") -1))

(defun agent-shell-vertico-transcript-next-agent ()
  "Move to the next agent message."
  (interactive)
  (agent-shell-vertico-transcript--move-to-speaker '("Agent") 1))

(defun agent-shell-vertico-transcript-previous-agent ()
  "Move to the previous agent message."
  (interactive)
  (agent-shell-vertico-transcript--move-to-speaker '("Agent") -1))

(defun agent-shell-vertico-transcript-next-message ()
  "Move to the next user or agent message."
  (interactive)
  (agent-shell-vertico-transcript--move-to-speaker '("User" "Agent") 1))

(defun agent-shell-vertico-transcript-previous-message ()
  "Move to the previous user or agent message."
  (interactive)
  (agent-shell-vertico-transcript--move-to-speaker '("User" "Agent") -1))

(defun agent-shell-vertico-transcript--hide-clean-region (start end)
  "Hide the transcript region from START to END in the clean view.

START and END are line beginnings.  The region is moved back over the
newline on each side, so that it covers the newline ending the last
visible line and stops before the newline ending the last hidden line.
This is how `outline-flag-region' hides a subtree, and it leaves the
heading at END at the start of its own display line.

Hiding through END instead would put that heading on a display line
beginning at START.  Emacs would then have to scan and fontify the whole
hidden region to find where that display line starts, which is what
`vertical-motion' does on every line move and every pixel scroll."
  (let ((start (if (eq (char-before start) ?\n) (1- start) start))
        (end (if (eq (char-before end) ?\n) (1- end) end)))
    (when (< start end)
      (let ((overlay (make-overlay start end nil nil t)))
        (overlay-put overlay 'invisible
                     agent-shell-vertico-transcript--clean-invisibility)
        (push overlay agent-shell-vertico-transcript--clean-overlays)))))

(defun agent-shell-vertico-transcript--clean-event-at-point ()
  "Return the transcript visibility event at the current line."
  (cond
   ((looking-at-p agent-shell-vertico-transcript--message-heading-regexp)
    'visible)
   ((or
     (looking-at-p agent-shell-vertico-transcript--thought-heading-regexp)
     (looking-at-p agent-shell-vertico-transcript--tool-heading-regexp))
    'hidden)))

(defun agent-shell-vertico-transcript--clean-fence-at-point ()
  "Return Markdown fence information for the current line, or nil.
The return value is (CHARACTER LENGTH CLOSING-P)."
  (when (looking-at "^[ \t]\\{0,3\\}\\(```+\\|~~~+\\)")
    (let ((run (match-string-no-properties 1)))
      (list
       (aref run 0)
       (length run)
       (string-match-p
        "\\`[ \t]*\\'"
        (buffer-substring-no-properties
         (match-end 1) (line-end-position)))))))

(defun agent-shell-vertico-transcript--show-clean-view ()
  "Show only user and agent messages in the current transcript buffer."
  (add-to-invisibility-spec
   agent-shell-vertico-transcript--clean-invisibility)
  (save-excursion
    (goto-char (point-min))
    (let ((hidden-start (point-min))
          (visible nil)
          fence)
      (while (not (eobp))
        (let ((fence-info
               (agent-shell-vertico-transcript--clean-fence-at-point)))
          (cond
           (fence
            (when (and fence-info
                       (= (car fence-info) (car fence))
                       (>= (cadr fence-info) (cdr fence))
                       (caddr fence-info))
              (setq fence nil)))
           (fence-info
            (setq fence (cons (car fence-info) (cadr fence-info))))
           (t
            (pcase (agent-shell-vertico-transcript--clean-event-at-point)
              ('visible
               (unless visible
                 (agent-shell-vertico-transcript--hide-clean-region
                  hidden-start (point)))
               (setq visible t))
              ('hidden
               (when visible
                 (setq hidden-start (point)))
               (setq visible nil))))))
        (forward-line 1))
      (unless visible
        (agent-shell-vertico-transcript--hide-clean-region
         hidden-start (point-max)))))
  (setq agent-shell-vertico-transcript--clean-view-p t))

(defun agent-shell-vertico-transcript-clean-view ()
  "Toggle between clean and full content in this transcript buffer.
The clean view hides everything except user and agent messages without
changing the buffer's text."
  (interactive)
  (if agent-shell-vertico-transcript--clean-view-p
      (agent-shell-vertico-transcript--show-full-view)
    (agent-shell-vertico-transcript--show-clean-view)))

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
  "Return TEXT with its transcript header set to SESSION-ID.

Both the search and the insertion stop at `--header-end', as reading a
header field does.  A body quotes header fields verbatim whenever an
agent echoes a file or an older transcript, and a field written past the
header is one the parser can never read back."
  (with-temp-buffer
    (insert text)
    (let ((header-end (agent-shell-vertico-transcript--header-end)))
      (goto-char (point-min))
      (if (re-search-forward
           "^\\*\\*Session\\(?: ID\\)?:\\*\\*[ \t]+.*$"
           header-end t)
          (replace-match
           (format "**Session ID:** %s" session-id)
           t t)
        (goto-char header-end)
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
      ;; `erase-buffer' empties the whole buffer whatever the restriction,
      ;; so a narrowed transcript would be saved as its accessible region
      ;; alone unless the text is read and written widened.
      (save-restriction
        (widen)
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
          (save-buffer)))
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
  "Browse transcripts belonging to the current transcript's project.

The transcript stays on screen until another one replaces it.  Burying it
first left nothing to come back to when the prompt was quit, and dropped
it from the window history, so `q' skipped every transcript hopped
through and landed on whatever preceded the first one."
  (interactive)
  (let ((project-root
         (agent-shell-vertico-transcript-record-project-root
          (agent-shell-vertico-transcript--current-record))))
    (unless project-root
      (user-error "Transcript has no project directory"))
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
  (unless agent-shell-vertico-transcript--clean-view-p
    (agent-shell-vertico-transcript--show-clean-view)))

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
(defun agent-shell-vertico-transcript-setup-open-transcript ()
  "Open every `agent-shell' transcript in the transcript reader.

`agent-shell-open-transcript' is the one function the session commands
share: `agent-shell-viewport-open-transcript', the viewport transient,
and this package's own `agent-shell-vertico-open-transcript' all reach
it.  It takes no hook, so this advises it.

The reader makes the buffer read-only.  Turn
`agent-shell-vertico-transcript-mode' off to edit a transcript."
  (interactive)
  (advice-add 'agent-shell-open-transcript :override
              #'agent-shell-vertico-transcript-open-session))

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
         ((agent-shell-vertico--live-session-buffer session-id)
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

(defun agent-shell-vertico-transcript--unlisted-file-count
    (project-roots records)
  "Return how many transcripts under PROJECT-ROOTS are absent from RECORDS.

A transcript can remain unlisted when a shared store cannot map its
missing or stale Working Directory header to a known project.  Counting
files rather than records makes those transcripts visible to the doctor:
reading them through the same filter that omits them would always report
none."
  (let ((listed (make-hash-table :test #'equal))
        (count 0))
    (dolist (record records)
      (puthash (agent-shell-vertico-transcript-record-file record) t listed))
    (dolist (root project-roots)
      (let ((directory
             (agent-shell-vertico-transcript--directory root)))
        (when (file-directory-p directory)
          (dolist (file (directory-files-recursively directory "\\.md\\'"))
            (unless (gethash file listed)
              (puthash file t listed)
              (cl-incf count))))))
    count))

(defun agent-shell-vertico-transcript--diagnostic-issues
    (records &optional project-roots)
  "Return metadata issue descriptions for transcript RECORDS.

With PROJECT-ROOTS, also report transcripts stored under those projects
that RECORDS omits."
  (let ((missing-session-id 0)
        (missing-working-directory 0)
        (invalid-working-directory 0)
        (unlisted
         (and project-roots
              (agent-shell-vertico-transcript--unlisted-file-count
               project-roots records)))
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
    (when (and unlisted (> unlisted 0))
      (push
       (format
        (concat "%d transcript%s stored under a known project but not "
                "listed; %s Working Directory header is missing or "
                "names another directory")
        unlisted
        (if (= unlisted 1) " is" "s are")
        (if (= unlisted 1) "its" "their"))
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
          (agent-shell-vertico-transcript--diagnostic-issues
           records project-roots))
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

(defun agent-shell-vertico-transcript--limited-prompt (prompt shown total)
  "Return PROMPT saying that SHOWN of TOTAL transcripts are offered."
  (format "%s (newest %d of %d): "
          (string-trim-right prompt "[ :]+")
          shown total))

(defun agent-shell-vertico-transcript--read-records
    (prompt records &optional resumable-only)
  "Read one transcript from RECORDS with PROMPT.

When RESUMABLE-ONLY is non-nil, omit records without session IDs.
RECORDS past `agent-shell-vertico-transcript-candidate-limit' are
dropped, and PROMPT then reports how many of the total remain."
  (when resumable-only
    (setq records
          (seq-filter
           #'agent-shell-vertico-transcript-record-session-id
           records)))
  (let ((limit agent-shell-vertico-transcript-candidate-limit)
        (total (length records)))
    (when (and limit (> total limit))
      (setq records (seq-take records limit)
            prompt
            (agent-shell-vertico-transcript--limited-prompt
             prompt limit total)))
    (agent-shell-vertico-transcript--read-record prompt records)))

(defun agent-shell-vertico-transcript--browse-records (records)
  "Select and open one transcript from RECORDS."
  (agent-shell-vertico-transcript--open-record
   (agent-shell-vertico-transcript--read-records
    "Transcript: " records)))

(defun agent-shell-vertico-transcript--resume-records (records)
  "Select and resume one transcript session from RECORDS."
  (agent-shell-vertico-transcript--activate
   (agent-shell-vertico-transcript--read-records
    "Resume session: " records t)))

(defun agent-shell-vertico-transcript--browse-project-root (project-root)
  "Select and open a transcript for PROJECT-ROOT."
  (agent-shell-vertico-transcript--browse-records
   (agent-shell-vertico-transcript--records-for-project project-root)))

(defun agent-shell-vertico-transcript--resume-project-root (project-root)
  "Select and resume a transcript session for PROJECT-ROOT."
  (agent-shell-vertico-transcript--resume-records
   (agent-shell-vertico-transcript--records-for-project project-root)))

;;;###autoload
(defun agent-shell-vertico-transcript-browse (&optional select-project)
  "Browse transcripts from every known project.

With prefix argument SELECT-PROJECT, select one known project first and
browse only its transcripts."
  (interactive "P")
  (if select-project
      (agent-shell-vertico-transcript--browse-project-root
       (agent-shell-vertico-transcript--read-project))
    (agent-shell-vertico-transcript--browse-records
     (agent-shell-vertico-transcript--all-records))))

;;;###autoload
(defun agent-shell-vertico-transcript-browse-project ()
  "Browse transcripts belonging to the current project."
  (interactive)
  (agent-shell-vertico-transcript--browse-project-root
   (agent-shell-vertico-transcript--current-project-or-error)))

;;;###autoload
(defun agent-shell-vertico-transcript-resume (&optional select-project)
  "Resume a session from every known project's transcripts.

With prefix argument SELECT-PROJECT, select one known project first and
resume only from its transcripts."
  (interactive "P")
  (if select-project
      (agent-shell-vertico-transcript--resume-project-root
       (agent-shell-vertico-transcript--read-project))
    (agent-shell-vertico-transcript--resume-records
     (agent-shell-vertico-transcript--all-records))))

;;;###autoload
(defun agent-shell-vertico-transcript-resume-project ()
  "Resume a transcript session belonging to the current project."
  (interactive)
  (agent-shell-vertico-transcript--resume-project-root
   (agent-shell-vertico-transcript--current-project-or-error)))

(provide 'agent-shell-vertico-transcript)

;;; agent-shell-vertico-transcript.el ends here
