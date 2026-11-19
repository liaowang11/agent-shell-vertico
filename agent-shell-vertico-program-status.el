;;; agent-shell-vertico-program-status.el --- Terminal program status -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'map)
(require 'seq)
(require 'subr-x)

(declare-function agent-shell--state "agent-shell" ())
(declare-function agent-shell-buffers "agent-shell" ())
(declare-function agent-shell-subscribe-to "agent-shell" (&rest args))
(declare-function agent-shell-unsubscribe "agent-shell" (&rest args))
(declare-function agent-shell-vertico-sidebar--watch-existing "agent-shell-vertico-sidebar" (&rest args))
(declare-function agent-shell-vertico-sidebar--last-message "agent-shell-vertico-sidebar" (buffer))

(defvar agent-shell--subagent-group)

(defconst agent-shell-vertico-program-status-app "emacs"
  "The `app' every program status report names.")

(defun agent-shell-vertico-program-status--text (text limit)
  "Return TEXT without control characters, cut to LIMIT UTF-8 bytes.
The cut falls on a character boundary."
  (let ((clean (replace-regexp-in-string
                (rx (any (0 . 31) (127 . 159))) "" text t t))
        (bytes 0)
        (end 0))
    (while (and (< end (length clean))
                (<= (+ bytes (string-bytes (string (aref clean end)))) limit))
      (setq bytes (+ bytes (string-bytes (string (aref clean end))))
            end (1+ end)))
    (substring clean 0 end)))

(defun agent-shell-vertico-program-status--segment (string &optional fallback)
  "Return STRING as an id segment: allowed characters only, at most 32.
Runs of other characters become a single \"-\"; FALLBACK, or \"shell\",
stands in for a STRING with nothing left."
  (let ((segment (replace-regexp-in-string
                  "[^A-Za-z0-9_.+-]+" "-" (or string "") t t)))
    (if (string-empty-p segment)
        (or fallback "shell")
      (substring segment 0 (min 32 (length segment))))))

(cl-defun agent-shell-vertico-program-status-format (state &key id kind progress app title msg)
  "Return the OSC 7501 report for STATE, or signal an error.
ID, KIND, PROGRESS, APP, TITLE and MSG are the protocol's keys; omitted
ones are left out of the report.  TITLE and MSG are cleaned and cut to
their limits; anything else the terminal would discard is an error."
  (unless (member state '("idle" "working" "done" "blocked" "error" "clear"))
    (error "Invalid program status state: %S" state))
  (when id
    (let ((segments (split-string id "/")))
      (unless (and (<= (length id) 128)
                   (<= (length segments) 8)
                   (seq-every-p (lambda (segment)
                                  (string-match-p
                                   "\\`[A-Za-z0-9_.+-]\\{1,32\\}\\'" segment))
                                segments))
        (error "Invalid program status id: %S" id))))
  (when (and kind (not (and (equal state "blocked")
                            (member kind '("permission" "question" "auth")))))
    (error "Invalid program status kind: %S" kind))
  (when (and progress (not (and (natnump progress) (<= progress 100))))
    (error "Invalid program status progress: %S" progress))
  (when (and app (not (string-match-p "\\`[A-Za-z0-9_.+-]\\{1,32\\}\\'" app)))
    (error "Invalid program status app: %S" app))
  (let* ((encode (lambda (text limit)
                   (let ((clean (agent-shell-vertico-program-status--text text limit)))
                     (unless (string-empty-p clean)
                       (base64-encode-string
                        (encode-coding-string clean 'utf-8 t) t)))))
         (pairs (seq-filter
                 #'cdr
                 `(("state" . ,state)
                   ("id" . ,id)
                   ("kind" . ,kind)
                   ("progress" . ,(and progress (number-to-string progress)))
                   ("app" . ,app)
                   ("title" . ,(and title (funcall encode title 192)))
                   ("msg" . ,(and msg (funcall encode msg 2048))))))
         (report (concat "\e]7501;"
                         (mapconcat (lambda (pair)
                                      (concat (car pair) "=" (cdr pair)))
                                    pairs ":")
                         "\e\\")))
    (when (> (string-bytes report) 4096)
      (error "Program status report over 4096 bytes"))
    report))

(defun agent-shell-vertico-program-status-state (agent-state stop-reason previous)
  "Return the protocol state for AGENT-STATE ended by STOP-REASON.
PREVIOUS is the record's last protocol state, nil if it has none."
  (pcase agent-state
    ("running" "working")
    ("requires_action" "blocked")
    ("idle" (cond ((equal stop-reason "error") "error")
                  ((equal stop-reason "cancelled") "idle")
                  ((member previous '("working" "blocked")) "done")
                  (t "idle")))))

(defvar agent-shell-vertico-program-status--shells (make-hash-table :test #'eq)
  "Each shell buffer's (SLUG . RECORDS).
RECORDS maps nil (the shell itself) or a child id to its protocol state.")

(defconst agent-shell-vertico-program-status--detail-delay 0.5
  "Seconds to collect working detail changes before reporting the latest.")

(cl-defstruct agent-shell-vertico-program-status--activity
  calls                                 ; Active tool IDs, newest first.
  detail                                ; Latest meaningful working message.
  report                                ; Last working report, for dedup and replay.
  timer)                                ; Pending detail update, if any.

(defvar-local agent-shell-vertico-program-status--activities nil
  "Working activity keyed by nil for the shell or by a child record id.")

(defun agent-shell-vertico-program-status--activity-for (child)
  "Return the working activity for CHILD, creating it if needed."
  (or (alist-get child agent-shell-vertico-program-status--activities
                nil nil #'equal)
      (setf (alist-get child agent-shell-vertico-program-status--activities
                       nil nil #'equal)
            (make-agent-shell-vertico-program-status--activity))))

(defun agent-shell-vertico-program-status--tool-owner ()
  "Return the record the tool call being dispatched belongs to.
agent-shell binds `agent-shell--subagent-group' while it dispatches a
native subagent's update; nil means the shell itself."
  (when-let* ((session-id (car-safe (bound-and-true-p agent-shell--subagent-group))))
    (concat "subagent/" session-id)))

(defun agent-shell-vertico-program-status--cancel-detail (activity)
  "Cancel ACTIVITY's pending report, if any."
  (when-let* ((timer (agent-shell-vertico-program-status--activity-timer activity)))
    (cancel-timer timer)
    (setf (agent-shell-vertico-program-status--activity-timer activity) nil)))

(defvar-local agent-shell-vertico-program-status--subscriptions nil
  "Event subscriptions owned by program status mode.")

(defun agent-shell-vertico-program-status--rex-terminal-p (terminal)
  "Non-nil when TERMINAL is a live text terminal in a Rex pane."
  (and (eq (terminal-live-p terminal) t)
       (when-let* ((type (tty-type terminal)))
         (or (string-prefix-p "xterm-rex" type)
             (seq-some (lambda (frame) (getenv "REX_BLOCK" frame))
                       (frames-on-display-list terminal))))))

(defun agent-shell-vertico-program-status--send (report &optional terminals)
  "Send REPORT to TERMINALS, or to every Rex terminal."
  (dolist (terminal (or terminals
                        (seq-filter #'agent-shell-vertico-program-status--rex-terminal-p
                                    (terminal-list))))
    (when (terminal-live-p terminal)
      (condition-case nil
          (progn
            (send-string-to-terminal report terminal)
            (set-terminal-parameter terminal 'agent-shell-vertico-program-status t))
        (error nil)))))

(defun agent-shell-vertico-program-status--slug (buffer)
  "Return BUFFER's record id, pinning it on first use."
  (or (car (gethash buffer agent-shell-vertico-program-status--shells))
      (let* ((session-id (with-current-buffer buffer
                           (ignore-errors
                             (map-nested-elt (agent-shell--state)
                                             '(:session :id)))))
             (base (agent-shell-vertico-program-status--segment
                    (or session-id (buffer-name buffer))))
             (taken (let (slugs)
                      (maphash (lambda (_buffer entry) (push (car entry) slugs))
                               agent-shell-vertico-program-status--shells)
                      slugs))
             (slug base)
             (n 1))
        (while (member slug taken)
          (setq n (1+ n)
                slug (let ((suffix (format "-%d" n)))
                       (concat (substring base 0 (min (length base)
                                                      (- 32 (length suffix))))
                               suffix))))
        (puthash buffer (list slug) agent-shell-vertico-program-status--shells)
        slug)))

(defun agent-shell-vertico-program-status--report (buffer child state &optional detail)
  "Return BUFFER's report for CHILD in STATE, with working DETAIL.
CHILD is nil for the shell itself."
  (let ((slug (agent-shell-vertico-program-status--slug buffer)))
    (let ((id (if child
                  (let ((split (string-search "/" child)))
                    (concat slug "/"
                            (agent-shell-vertico-program-status--segment (substring child 0 split))
                            (if split
                                (concat "/" (agent-shell-vertico-program-status--segment
                                             (substring child (1+ split))))
                              "")))
                slug)))
      (if (equal state "clear")
          (agent-shell-vertico-program-status-format state :id id)
        (agent-shell-vertico-program-status-format state :id id :app agent-shell-vertico-program-status-app
                                 :title (or child (buffer-name buffer))
                                 :msg (cond
                                       ((equal state "working")
                                        (or detail "Working"))
                                       ((and (null child) (equal state "done")
                                             (fboundp 'agent-shell-vertico-sidebar--last-message))
                                        (when-let* ((message (agent-shell-vertico-sidebar--last-message buffer)))
                                          (replace-regexp-in-string "[\n\r\t]+" " " message)))))))))

(defun agent-shell-vertico-program-status--send-working (buffer child activity)
  "Publish CHILD's latest working ACTIVITY in BUFFER if it changed."
  (let ((report (agent-shell-vertico-program-status--report
                 buffer child "working"
                 (agent-shell-vertico-program-status--activity-detail activity))))
    (unless (equal report (agent-shell-vertico-program-status--activity-report
                           activity))
      (setf (agent-shell-vertico-program-status--activity-report activity) report)
      (agent-shell-vertico-program-status--send report))))

(defun agent-shell-vertico-program-status--flush-detail (buffer child activity)
  "Publish the coalesced working ACTIVITY for CHILD in BUFFER."
  (setf (agent-shell-vertico-program-status--activity-timer activity) nil)
  (when (buffer-live-p buffer)
    (agent-shell-vertico-program-status--send-working buffer child activity)))

(defun agent-shell-vertico-program-status--schedule-detail (buffer child activity)
  "Start a detail update window for CHILD's ACTIVITY in BUFFER."
  (unless (agent-shell-vertico-program-status--activity-timer activity)
    (setf (agent-shell-vertico-program-status--activity-timer activity)
          (run-at-time agent-shell-vertico-program-status--detail-delay nil
                       #'agent-shell-vertico-program-status--flush-detail
                       buffer child activity))))

(defun agent-shell-vertico-program-status--set (buffer child state)
  "Record CHILD of BUFFER as STATE, or forget it for nil, and report it."
  (let* ((slug (agent-shell-vertico-program-status--slug buffer))
         (records (cdr (gethash buffer agent-shell-vertico-program-status--shells))))
    (if state
        (setf (alist-get child records nil nil #'equal) state)
      (setq records (assoc-delete-all child records)))
    (puthash buffer (cons slug records) agent-shell-vertico-program-status--shells)
    (with-current-buffer buffer
      (if (equal state "working")
          (agent-shell-vertico-program-status--send-working
           buffer child (agent-shell-vertico-program-status--activity-for child))
        (when-let* ((activity (alist-get child
                                         agent-shell-vertico-program-status--activities
                                         nil nil #'equal)))
          (agent-shell-vertico-program-status--cancel-detail activity)
          (if (equal state "blocked")
              (setf (agent-shell-vertico-program-status--activity-report activity)
                    nil)
            (setq agent-shell-vertico-program-status--activities
                  (assoc-delete-all
                   child agent-shell-vertico-program-status--activities))))
        (agent-shell-vertico-program-status--send
         (agent-shell-vertico-program-status--report
          buffer child (or state "clear")))))))

(defun agent-shell-vertico-program-status--clear-errors (running-buffer running-child)
  "Acknowledge errors except the record being replaced by new work."
  (maphash (lambda (buffer entry)
             (when (buffer-live-p buffer)
               (pcase-dolist (`(,child . ,state) (cdr entry))
                 (when (and (equal state "error")
                            (not (and (eq buffer running-buffer)
                                      (equal child running-child))))
                   (agent-shell-vertico-program-status--set buffer child (unless child "idle"))))))
           agent-shell-vertico-program-status--shells))

(defun agent-shell-vertico-program-status--on-tool-call (event)
  "Collect working detail from tool call EVENT for its owning record.
Starting a call drops pending server-side calls (ids starting with
\"srvtoolu_\"), which ACP never reports finished.  A completion never
replaces the working detail."
  (let* ((data (map-elt event :data))
         (id (map-elt data :tool-call-id))
         (call (map-elt data :tool-call))
         (status (map-elt call :status))
         (description (or (map-elt call :description) (map-elt call :title))))
    (when id
      (let* ((buffer (current-buffer))
             (owner (agent-shell-vertico-program-status--tool-owner))
             (activity (agent-shell-vertico-program-status--activity-for owner))
             (calls (agent-shell-vertico-program-status--activity-calls activity)))
        (cond
         ((member status '("completed" "failed" "cancelled"))
          (setf (agent-shell-vertico-program-status--activity-calls activity)
                (delete id calls)))
         ((or (null status) (member status '("pending" "in_progress")))
          (let* ((entry (gethash buffer agent-shell-vertico-program-status--shells))
                 (working (equal (alist-get owner (cdr entry) nil nil #'equal)
                                 "working")))
            (unless (member id calls)
              (setq calls (cons id (seq-remove
                                    (lambda (call)
                                      (string-prefix-p "srvtoolu_" call))
                                    calls)))
              (setf (agent-shell-vertico-program-status--activity-calls activity)
                    calls)
              (when working
                (agent-shell-vertico-program-status--clear-errors buffer owner)))
            (when (and (equal id (car calls))
                       (stringp description)
                       (not (string-blank-p description))
                       (not (equal description
                                   (agent-shell-vertico-program-status--activity-detail
                                    activity))))
              (setf (agent-shell-vertico-program-status--activity-detail activity)
                    description)
              (when working
                (agent-shell-vertico-program-status--schedule-detail
                 buffer owner activity))))))))))

(defun agent-shell-vertico-program-status--on-state-changed (event)
  "Report the run state EVENT, a `state-changed' event, declares."
  (let* ((buffer (current-buffer))
         (child (map-nested-elt event '(:data :id)))
         (agent-state (map-nested-elt event '(:data :state)))
         (previous (alist-get child (cdr (gethash buffer agent-shell-vertico-program-status--shells))
                              nil nil #'equal))
         (state (agent-shell-vertico-program-status-state
                 agent-state
                 (map-nested-elt event '(:data :stop-reason))
                 previous)))
    (when (equal state "working")
      (agent-shell-vertico-program-status--clear-errors buffer child))
    (when (and state
               (not (equal state previous))
               (or previous (null child) (not (equal agent-state "idle"))))
      (agent-shell-vertico-program-status--set buffer child state))))

(defun agent-shell-vertico-program-status--seen-h (window)
  "Mark this shell's finished records seen when WINDOW becomes selected."
  (when-let* (((eq window (selected-window)))
              (buffer (current-buffer))
              (records (cdr (gethash buffer agent-shell-vertico-program-status--shells))))
    (pcase-dolist (`(,child . ,state) records)
      (cond ((not (member state '("done" "error" "idle"))))
            (child (agent-shell-vertico-program-status--set buffer child nil))
            ((not (equal state "idle"))
             (agent-shell-vertico-program-status--set buffer nil "idle"))))))

(defun agent-shell-vertico-program-status--clear-h ()
  "Clear this shell's records from every Rex terminal and forget them."
  (when-let* ((entry (gethash (current-buffer) agent-shell-vertico-program-status--shells)))
    (remhash (current-buffer) agent-shell-vertico-program-status--shells)
    (agent-shell-vertico-program-status--send
     (agent-shell-vertico-program-status-format "clear" :id (car entry)))))

(defun agent-shell-vertico-program-status--replay-h ()
  "Send every shell's records to the new terminal, if it is a Rex pane."
  (let ((terminal (frame-terminal)))
    (when (agent-shell-vertico-program-status--rex-terminal-p terminal)
      (maphash (lambda (buffer entry)
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (pcase-dolist (`(,child . ,state) (reverse (cdr entry)))
                       (agent-shell-vertico-program-status--send
                        (if (equal state "working")
                            (agent-shell-vertico-program-status--activity-report
                             (agent-shell-vertico-program-status--activity-for
                              child))
                          (agent-shell-vertico-program-status--report
                           buffer child state))
                        (list terminal))))))
               agent-shell-vertico-program-status--shells))))

(defun agent-shell-vertico-program-status--retract (&optional terminal)
  "Clear every shell's record from TERMINAL, or from all reported ones."
  (when-let* ((terminals (seq-filter
                          (lambda (term) (terminal-parameter term 'agent-shell-vertico-program-status))
                          (if terminal (list terminal) (terminal-list)))))
    (maphash (lambda (_buffer entry)
               (agent-shell-vertico-program-status--send
                (agent-shell-vertico-program-status-format "clear" :id (car entry))
                terminals))
             agent-shell-vertico-program-status--shells)))

(defun agent-shell-vertico-program-status--retract-h ()
  "Clear every shell's record before Emacs exits."
  (agent-shell-vertico-program-status--retract))

(defun agent-shell-vertico-program-status--unsubscribe ()
  "Unsubscribe this buffer and retract its records."
  (dolist (token agent-shell-vertico-program-status--subscriptions)
    (agent-shell-unsubscribe :subscription token))
  (dolist (entry agent-shell-vertico-program-status--activities)
    (agent-shell-vertico-program-status--cancel-detail (cdr entry)))
  (setq agent-shell-vertico-program-status--subscriptions nil
        agent-shell-vertico-program-status--activities nil)
  (remove-hook 'window-selection-change-functions #'agent-shell-vertico-program-status--seen-h t)
  (remove-hook 'kill-buffer-hook #'agent-shell-vertico-program-status--unsubscribe t)
  (agent-shell-vertico-program-status--clear-h))

(defun agent-shell-vertico-program-status--subscribe ()
  "Watch the current agent-shell session."
  (unless agent-shell-vertico-program-status--subscriptions
    (setq agent-shell-vertico-program-status--subscriptions
          (list (agent-shell-subscribe-to
                 :shell-buffer (current-buffer) :event 'state-changed
                 :on-event #'agent-shell-vertico-program-status--on-state-changed)
                (agent-shell-subscribe-to
                 :shell-buffer (current-buffer) :event 'tool-call-update
                 :on-event #'agent-shell-vertico-program-status--on-tool-call)))
    (add-hook 'window-selection-change-functions #'agent-shell-vertico-program-status--seen-h nil t)
    (add-hook 'kill-buffer-hook #'agent-shell-vertico-program-status--unsubscribe nil t)
    (let ((state (agent-shell--state)))
      (when-let* ((current (map-elt state :agent-state)))
        (agent-shell-vertico-program-status--on-state-changed
         `((:data . ((:state . ,current))))))
      (when (fboundp 'agent-shell--child-states)
        (dolist (child (agent-shell--child-states state))
          (agent-shell-vertico-program-status--on-state-changed
           `((:data . ((:id . ,(nth 0 child)) (:state . ,(nth 1 child))
                       (:stop-reason . ,(nth 2 child)))))))))))

;;;###autoload
(define-minor-mode agent-shell-vertico-program-status-mode
  "Report agent-shell activity to Rex terminals using OSC 7501."
  :global t
  :group 'agent-shell-vertico
  (if agent-shell-vertico-program-status-mode
      (progn
        (require 'agent-shell)
        (require 'agent-shell-vertico-sidebar)
        (agent-shell-vertico-sidebar--watch-existing)
        (add-hook 'agent-shell-mode-hook #'agent-shell-vertico-program-status--subscribe)
        (add-hook 'tty-setup-hook #'agent-shell-vertico-program-status--replay-h)
        (add-hook 'delete-terminal-functions #'agent-shell-vertico-program-status--retract)
        (add-hook 'kill-emacs-hook #'agent-shell-vertico-program-status--retract-h)
        (dolist (buffer (agent-shell-buffers))
          (with-current-buffer buffer (agent-shell-vertico-program-status--subscribe))))
    (remove-hook 'agent-shell-mode-hook #'agent-shell-vertico-program-status--subscribe)
    (remove-hook 'tty-setup-hook #'agent-shell-vertico-program-status--replay-h)
    (remove-hook 'delete-terminal-functions #'agent-shell-vertico-program-status--retract)
    (remove-hook 'kill-emacs-hook #'agent-shell-vertico-program-status--retract-h)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when agent-shell-vertico-program-status--subscriptions
          (agent-shell-vertico-program-status--unsubscribe))))))

(provide 'agent-shell-vertico-program-status)
;;; agent-shell-vertico-program-status.el ends here
