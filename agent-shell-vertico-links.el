;;; agent-shell-vertico-links.el --- Bookmarks and Org links for agent-shell -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Bill and contributors

;; Author: Bill
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (agent-shell "0.63.5"))
;; Keywords: convenience, tools
;; URL: https://github.com/liaowang11/agent-shell-vertico

;;; Commentary:

;; Stable pointers to `agent-shell' sessions, stored as Emacs bookmarks
;; and Org links.  A pointer records the session id, the agent
;; identifier, and the working directory.  Opening it reuses a live
;; matching `agent-shell' buffer; otherwise the session is resumed
;; through `agent-shell'.  A resume the agent cannot complete fails
;; loudly instead of silently starting a new session.
;;
;; Enable everything with:
;;
;;   (agent-shell-vertico-links-setup)
;;
;; Then `bookmark-set' and `org-store-link' work from `agent-shell'
;; buffers and the viewports showing them, and stored pointers open
;; with `bookmark-jump', `org-open-at-point', or
;; `agent-shell-vertico-links-open-session'.
;; With Embark, `embark-act' on a stored link offers actions for the
;; session behind it.

;;; Code:

(require 'agent-shell)
(require 'agent-shell-vertico)
(require 'bookmark)
(require 'map)
(require 'seq)
(require 'subr-x)

(declare-function agent-shell--resolved-agent-configs "agent-shell" ())
(declare-function agent-shell-cwd "agent-shell-project")
(declare-function agent-shell-viewport--shell-buffer
                  "agent-shell-viewport" (&optional viewport-buffer))
(declare-function org-in-regexp "org-macs" (regexp &optional limit visibility))
(declare-function org-link-decode "ol" (text))
(declare-function org-link-encode "ol" (text table))
(declare-function org-link-set-parameters "ol" (type &rest parameters))
(declare-function org-link-store-props "ol" (&rest plist))

(defvar agent-shell-viewport-view-mode-hook)
(defvar agent-shell-viewport-edit-mode-hook)
(defvar embark-default-action-overrides)
(defvar embark-keymap-alist)
(defvar embark-target-finders)
(defvar org-link-any-re)

;;; Session pointers

(defun agent-shell-vertico-links--session-shell-buffer ()
  "Return the shell buffer for the session shown in the current buffer.
The current buffer itself in `agent-shell-mode'; in a viewport
buffer, the shell buffer that viewport was created from.  Nil
anywhere else.  Viewports have sibling edit and view modes, and a
session may be stored while composing in either."
  (cond
   ((derived-mode-p 'agent-shell-mode) (current-buffer))
   ((and (fboundp 'agent-shell-viewport--shell-buffer)
         (or (derived-mode-p 'agent-shell-viewport-view-mode)
             (derived-mode-p 'agent-shell-viewport-edit-mode)))
    (agent-shell-viewport--shell-buffer))))

(defun agent-shell-vertico-links--current-session ()
  "Return a plist describing the current `agent-shell' session, or nil.
The plist carries `:session-id', `:identifier', `:dir', and `:title'.
Reads through to the shell buffer in a viewport view buffer, which is
where `agent-shell' keeps the session state."
  (when-let* ((shell-buffer
               (agent-shell-vertico-links--session-shell-buffer))
              (state (agent-shell-vertico--state shell-buffer))
              (session-id (map-nested-elt state '(:session :id)))
              ((not (string-empty-p session-id))))
    (list :session-id session-id
          :identifier (map-nested-elt state '(:agent-config :identifier))
          :dir (with-current-buffer shell-buffer
                 (ignore-errors (agent-shell-cwd)))
          :title (map-nested-elt state '(:session :title)))))

(defun agent-shell-vertico-links--description (session)
  "Return a display description for SESSION.
Prefers the session title, which `agent-shell' keeps refreshed from
the agent; falls back to naming the session id."
  (let ((title (plist-get session :title)))
    (if (and title (not (string-empty-p title)))
        title
      (format "agent-shell session %s" (plist-get session :session-id)))))

(defun agent-shell-vertico-links--config-for-identifier (identifier)
  "Return the agent config whose :identifier matches IDENTIFIER.
Return nil when none matches.  Entries are read through
`agent-shell--resolved-agent-configs' because
`agent-shell-agent-configs' holds config-making functions by default."
  (when identifier
    (seq-find (lambda (config)
                (eq (map-elt config :identifier) identifier))
              (agent-shell--resolved-agent-configs))))

;;;###autoload
(defun agent-shell-vertico-links-open-session (session-id &optional agent dir)
  "Open SESSION-ID in `agent-shell'.
AGENT is an optional agent identifier, as a symbol or string.  DIR is
an optional working directory.  When a live buffer already runs the
same session id and agent, display that buffer instead of starting
another shell.  Otherwise resume SESSION-ID with the agent that issued
it."
  (when (or (null session-id) (string-empty-p session-id))
    (user-error "Agent-shell link has no session id"))
  (let* ((identifier (cond ((symbolp agent) agent)
                           ((and (stringp agent)
                                 (not (string-empty-p agent)))
                            (intern-soft agent))))
         (live-buffer
          ;; An agent named in the link that matches no configured
          ;; identifier can name no live buffer either, so the live
          ;; lookup is skipped rather than risking the wrong agent.
          (and (or (null agent) identifier)
               (agent-shell-vertico--live-session-buffer session-id)))
         (buffer
          (and live-buffer
               (or (null identifier)
                   (eq (map-nested-elt
                        (agent-shell-vertico--state live-buffer)
                        '(:agent-config :identifier))
                       identifier))
               live-buffer)))
    (if buffer
        (agent-shell-vertico--display-session (buffer-name buffer))
      (when (and dir (not (file-directory-p dir)))
        (user-error "Agent-shell session directory no longer exists: %s" dir))
      (let ((default-directory (or dir default-directory)))
        (agent-shell-vertico-links--ensure-strict-resume-advice)
        (let ((shell-buffer
               (agent-shell-vertico--resume-session
                session-id
                (agent-shell-vertico-links--config-for-identifier identifier))))
          (agent-shell-vertico-links--mark-strict-resume
           shell-buffer session-id)
          shell-buffer)))))

;;; Strict resume
;;
;; `agent-shell' falls back to starting a new session whenever the
;; agent cannot resume the requested one: an unsupported protocol, a
;; missing session, a failed listing.  Every fallback funnels through
;; `agent-shell--initiate-new-session', so advice there, gated by a
;; buffer-local mark, is the single interception point.  A linked
;; resume that hits the fallback is reported and its half-started
;; buffer killed, rather than silently replacing the linked session
;; with an empty one.

(defvar agent-shell-vertico-links--strict-resume-advice-installed nil
  "Non-nil when fallback prevention advice has been installed.")

(defvar-local agent-shell-vertico-links--strict-resume-session-id nil
  "Session id this buffer must resume without falling back to a new session.")

(defun agent-shell-vertico-links--prevent-new-session-fallback (orig &rest args)
  "Call ORIG with ARGS unless this is a failed strict resume fallback."
  (let* ((shell-buffer (plist-get args :shell-buffer))
         (session-id
          (and (buffer-live-p shell-buffer)
               (buffer-local-value
                'agent-shell-vertico-links--strict-resume-session-id
                shell-buffer))))
    (if (and session-id (not (string-empty-p session-id)))
        (progn
          (display-warning
           'agent-shell-vertico-links
           (format
            "Could not resume agent-shell session %s; not \
starting a new session"
            session-id))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer shell-buffer)))
      (apply orig args))))

(defun agent-shell-vertico-links--ensure-strict-resume-advice ()
  "Install advice that prevents linked session resumes from falling back."
  (unless agent-shell-vertico-links--strict-resume-advice-installed
    (advice-add 'agent-shell--initiate-new-session
                :around
                #'agent-shell-vertico-links--prevent-new-session-fallback)
    (setq agent-shell-vertico-links--strict-resume-advice-installed t)))

(defun agent-shell-vertico-links--mark-strict-resume (buffer session-id)
  "Mark BUFFER as requiring a strict resume of SESSION-ID.
The mark and its event subscription clear once initialization
finishes, so the advice affects only this resume attempt and later
restarts of the buffer fall back normally."
  (with-current-buffer buffer
    (setq-local agent-shell-vertico-links--strict-resume-session-id session-id)
    (let* ((subscription nil)
           (clear
            (lambda (_event)
              ;; The event may be delivered in any buffer, so target the
              ;; marked one explicitly.
              (when (buffer-live-p buffer)
                (with-current-buffer buffer
                  (setq
                   agent-shell-vertico-links--strict-resume-session-id
                   nil)))
              (agent-shell-unsubscribe :subscription subscription))))
      (setq subscription
            (agent-shell-subscribe-to
             :shell-buffer buffer
             :event 'init-finished
             :on-event clear)))))

;;; Bookmarks

;;;###autoload
(defun agent-shell-vertico-links-bookmark-enable ()
  "Make `bookmark-set' store the current `agent-shell' session.
Installs the buffer-local `bookmark-make-record-function';
`agent-shell-vertico-links-setup' adds it to the shell and viewport
mode hooks."
  (setq-local bookmark-make-record-function
              #'agent-shell-vertico-links-bookmark-make-record))

(defun agent-shell-vertico-links-bookmark-make-record ()
  "Return a bookmark record for the current `agent-shell' session."
  (let* ((session (or (agent-shell-vertico-links--current-session)
                      (user-error "No active agent-shell session")))
         (description (agent-shell-vertico-links--description session)))
    (list description
          (cons 'handler #'agent-shell-vertico-links-bookmark-jump)
          (cons 'session-id (plist-get session :session-id))
          (cons 'agent (plist-get session :identifier))
          (cons 'filename (plist-get session :dir))
          (cons 'location description))))

;;;###autoload
(defun agent-shell-vertico-links-bookmark-jump (bookmark)
  "Jump to an agent-shell BOOKMARK."
  (agent-shell-vertico-links-open-session
   (bookmark-prop-get bookmark 'session-id)
   (bookmark-prop-get bookmark 'agent)
   (bookmark-get-filename bookmark)))

;;; Org links
;;
;; Links look like `agent-shell:SESSION-ID?agent=IDENTIFIER&dir=DIR',
;; percent-encoded in the same character set the upstream
;; agent-shell-links package uses, so links stored by either package
;; open with the other installed.

(defconst agent-shell-vertico-links--encode-chars
  '(?\s ?\t ?\n ?% ?& ?? ?= ?#)
  "Characters percent-encoded in link query values.
These are the characters that would otherwise confuse query parsing
or Org's own link reader.")

(defun agent-shell-vertico-links--encode (string)
  "Return STRING encoded for an `agent-shell' Org link path."
  (require 'ol)
  (org-link-encode string agent-shell-vertico-links--encode-chars))

(defun agent-shell-vertico-links--decode (string)
  "Return STRING decoded from an `agent-shell' Org link path."
  (require 'ol)
  (org-link-decode string))

(defun agent-shell-vertico-links--build (session-id identifier dir)
  "Build an agent-shell link path from SESSION-ID, IDENTIFIER and DIR.
IDENTIFIER and DIR are optional and omitted from the result when nil."
  (let* ((agent-param
          (when identifier
            (format "agent=%s"
                    (agent-shell-vertico-links--encode
                     (symbol-name identifier)))))
         (dir-param
          (when (and dir (not (string-empty-p dir)))
            (format "dir=%s"
                    (agent-shell-vertico-links--encode
                     (expand-file-name dir)))))
         (params (delq nil (list agent-param dir-param))))
    (concat (agent-shell-vertico-links--encode session-id)
            (when params
              (concat "?" (string-join params "&"))))))

(defun agent-shell-vertico-links--parse (path)
  "Parse link PATH into a list of session id, agent id, and directory."
  (let* ((qpos (string-search "?" path))
         (session-id (agent-shell-vertico-links--decode
                      (if qpos (substring path 0 qpos) path)))
         (query (and qpos (substring path (1+ qpos))))
         agent
         dir)
    (dolist (pair (and query (split-string query "&" t)))
      (let* ((eq (string-search "=" pair))
             (key (if eq (substring pair 0 eq) pair))
             (val (agent-shell-vertico-links--decode
                   (if eq (substring pair (1+ eq)) ""))))
        (pcase key
          ("agent" (setq agent val))
          ("dir" (setq dir val)))))
    (list session-id agent dir)))

;;;###autoload
(defun agent-shell-vertico-links-org-store ()
  "Store an Org link to the current `agent-shell' session.
Returns nil when not in an `agent-shell' buffer with an active
session, so other store functions can still run."
  (when-let* ((session (agent-shell-vertico-links--current-session)))
    (let ((link (agent-shell-vertico-links--build
                 (plist-get session :session-id)
                 (plist-get session :identifier)
                 (plist-get session :dir))))
      (require 'ol)
      (org-link-store-props
       :type "agent-shell"
       :link (concat "agent-shell:" link)
       :description (agent-shell-vertico-links--description session))
      link)))

;;;###autoload
(defun agent-shell-vertico-links-org-follow (path &optional _arg)
  "Follow an `agent-shell' Org link described by PATH.
Resumes the stored session, resolving the agent by identifier and
binding `default-directory' to the stored directory."
  (pcase-let ((`(,session-id ,agent ,dir)
               (agent-shell-vertico-links--parse path)))
    (agent-shell-vertico-links-open-session session-id agent dir)))

;;; Embark
;;
;; `embark-org' installs a target finder that claims every Org link as
;; a generic `org-link' target, and its type refinement cannot be
;; extended (Embark allows one transformer per type).  A finder of our
;; own, registered ahead of it, therefore claims `agent-shell:' links
;; as an `agent-shell-link' target and leaves every other link alone.
;; When `embark-org' is loaded, its generic link actions join our
;; keymap entry, keeping the copy variants and link navigation.

(defvar-keymap agent-shell-vertico-links-embark-map
  :doc "Embark actions for agent-shell Org links."
  "RET" #'agent-shell-vertico-links-embark-open
  "o" #'agent-shell-vertico-links-embark-open
  "i" #'agent-shell-vertico-links-embark-copy-session-id)

(defun agent-shell-vertico-links--org-target ()
  "Return the Embark target for the agent-shell Org link at point.
The target is `(agent-shell-link LINK BEG . END)', where LINK is the
`agent-shell:...' address and BEG and END span the whole link, in the
`embark-target-finders' shape.  Returns nil on any other link, so
`embark-org' still claims those as generic `org-link' targets."
  (when (and (boundp 'org-link-any-re) (fboundp 'org-in-regexp))
    (pcase (org-in-regexp org-link-any-re)
      (`(,start . ,end)
       ;; Group 2 of `org-link-any-re' is the path of a bracketed
       ;; link; a plain link has no group 2 and matches in full.
       (when-let* ((target (or (match-string-no-properties 2)
                               (match-string-no-properties 0)))
                   ((string-prefix-p "agent-shell:" target)))
         `(agent-shell-link ,target ,start . ,end))))))

(defun agent-shell-vertico-links--parse-target (target)
  "Return (SESSION-ID AGENT DIR) parsed from an Embark TARGET."
  (when (string-prefix-p "agent-shell:" target)
    (agent-shell-vertico-links--parse
     (string-remove-prefix "agent-shell:" target))))

(defun agent-shell-vertico-links-embark-open (target)
  "Open the session behind agent-shell link TARGET."
  (pcase-let ((`(,session-id ,agent ,dir)
               (agent-shell-vertico-links--parse-target target)))
    (agent-shell-vertico-links-open-session session-id agent dir)))

(defun agent-shell-vertico-links-embark-copy-session-id (target)
  "Copy the session id of agent-shell link TARGET."
  (if-let* ((session-id
             (car (agent-shell-vertico-links--parse-target target))))
      (progn
        (kill-new session-id)
        (message "Copied session ID: %s" session-id))
    (user-error "Target is not an agent-shell link")))

(defun agent-shell-vertico-links--register-embark ()
  "Register the Org link target finder and actions with Embark.
The keymap entry names only `embark-org-link-map' once `embark-org'
is loaded, because Embark resolves every keymap an entry names and an
unbound one would signal a void variable."
  (add-to-list 'embark-target-finders
               #'agent-shell-vertico-links--org-target)
  (add-to-list 'embark-keymap-alist
               (if (featurep 'embark-org)
                   '(agent-shell-link
                     agent-shell-vertico-links-embark-map
                     embark-org-link-map)
                 '(agent-shell-link
                   agent-shell-vertico-links-embark-map)))
  (add-to-list 'embark-default-action-overrides
               '(agent-shell-link . agent-shell-vertico-links-embark-open)))

(defun agent-shell-vertico-links--compose-embark-org-map ()
  "Add `embark-org-link-map' to the agent-shell link keymap entry.
Gives the generic Org link actions, such as the copy variants and
link navigation, a place beside ours.  Idempotent, so `setup' can
call it both immediately and when `embark-org' loads."
  (when (and (featurep 'embark) (featurep 'embark-org))
    (setf (alist-get 'agent-shell-link embark-keymap-alist)
          '(agent-shell-vertico-links-embark-map
            embark-org-link-map))))

;;;###autoload
(defun agent-shell-vertico-links-setup ()
  "Enable session bookmarks, Org links, and Embark for `agent-shell'.
Adds `bookmark-set' support to `agent-shell' buffers and viewports
through their mode hooks, applies it to live buffers, registers the
`agent-shell' Org link type, and registers the Embark target and
actions once Embark loads."
  (interactive)
  (add-hook 'agent-shell-mode-hook #'agent-shell-vertico-links-bookmark-enable)
  (dolist (hook '(agent-shell-viewport-view-mode-hook
                  agent-shell-viewport-edit-mode-hook))
    (add-hook hook #'agent-shell-vertico-links-bookmark-enable))
  (dolist (shell-buffer (agent-shell-buffers))
    (when (buffer-live-p shell-buffer)
      (dolist (buffer
               (cons shell-buffer
                     (when (fboundp 'agent-shell-viewport--buffer)
                       (list (agent-shell-viewport--buffer
                              :shell-buffer shell-buffer
                              :existing-only t)))))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (agent-shell-vertico-links-bookmark-enable))))))
  (require 'ol)
  (org-link-set-parameters
   "agent-shell"
   :follow #'agent-shell-vertico-links-org-follow
   :store #'agent-shell-vertico-links-org-store)
  (with-eval-after-load 'embark
    (agent-shell-vertico-links--register-embark))
  (with-eval-after-load 'embark-org
    (agent-shell-vertico-links--compose-embark-org-map)))

(provide 'agent-shell-vertico-links)

;;; agent-shell-vertico-links.el ends here
