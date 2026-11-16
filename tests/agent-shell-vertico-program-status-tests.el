;;; emacs-agent-shell-program-status.el --- Rex program status reports -*- lexical-binding: t; -*-
;; ABOUTME: Portable ERT tests for reporting agent-shell run states to Rex
;; ABOUTME: terminals with OSC 7501. Exercises the package module, stubs
;; agent-shell and the terminal primitives, and checks the bytes sent where.

(require 'ert)
(require 'cl-lib)
(require 'map)
(require 'seq)
(require 'subr-x)

(require 'agent-shell-vertico-program-status)

(defvar agent-shell--subagent-group)

(defvar-local bill/psp-test--session-id nil
  "The session id the stubbed `agent-shell--state' reports.")

(defvar bill/psp-test--sent nil
  "Reports sent, newest first, as (TERMINAL . STRING).")

(defvar bill/psp-test--terminal-params nil
  "Stubbed terminal parameters, as ((TERMINAL . PARAM) . VALUE).")

(defvar bill/psp-test--subscriptions nil
  "Subscriptions made, as (BUFFER EVENT ON-EVENT).")

(defvar bill/psp-test--frame-terminal 'rex
  "The terminal the stubbed `frame-terminal' returns.")

(defvar bill/psp-test--shells nil
  "Shell buffers made by the current test.")

(defun bill/psp-test--tty-type (terminal)
  (pcase terminal
    ('rex "xterm-256color")
    ('rex-term "xterm-rex")
    ('plain "xterm-256color")
    (_ nil)))

(defmacro bill/psp-test--with-terminals (&rest body)
  "Run BODY against fake terminals with every side effect recorded.
`rex' is a tty whose client frame carries REX_BLOCK, `rex-term' a tty
of type xterm-rex, `plain' another tty, `gui' a graphical terminal and
`initial' the daemon's initial terminal."
  (declare (indent 0))
  `(let ((bill/psp-test--sent nil)
         (bill/psp-test--terminal-params nil)
         (bill/psp-test--subscriptions nil)
         (bill/psp-test--frame-terminal 'rex)
         (bill/psp-test--shells nil))
     (clrhash agent-shell-vertico-program-status--shells)
     (cl-letf (((symbol-function 'terminal-list)
                (lambda () '(initial gui plain rex rex-term)))
               ((symbol-function 'terminal-live-p)
                (lambda (terminal) (if (eq terminal 'gui) 'ns t)))
               ((symbol-function 'tty-type) #'bill/psp-test--tty-type)
               ((symbol-function 'frames-on-display-list)
                (lambda (terminal) (list (list 'frame terminal))))
               ((symbol-function 'getenv)
                (lambda (variable &optional frame)
                  (and (equal variable "REX_BLOCK")
                       (equal frame '(frame rex))
                       "block-1")))
               ((symbol-function 'frame-terminal)
                (lambda (&optional _frame) bill/psp-test--frame-terminal))
               ((symbol-function 'terminal-parameter)
                (lambda (terminal parameter)
                  (alist-get (cons terminal parameter)
                             bill/psp-test--terminal-params nil nil #'equal)))
               ((symbol-function 'set-terminal-parameter)
                (lambda (terminal parameter value)
                  (setf (alist-get (cons terminal parameter)
                                   bill/psp-test--terminal-params nil nil #'equal)
                        value)))
               ((symbol-function 'send-string-to-terminal)
                (lambda (string &optional terminal)
                  (push (cons terminal string) bill/psp-test--sent)))
               ((symbol-function 'agent-shell--state)
                (lambda ()
                  (list (cons :session (list (cons :id bill/psp-test--session-id))))))
               ((symbol-function 'agent-shell-unsubscribe) (lambda (&rest _) nil))
               ((symbol-function 'agent-shell-subscribe-to)
                (cl-function
                 (lambda (&key shell-buffer event on-event)
                   (push (list shell-buffer event on-event)
                         bill/psp-test--subscriptions)))))
       (unwind-protect
           (progn ,@body)
         (dolist (buffer bill/psp-test--shells)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (setq kill-buffer-hook nil))
             (kill-buffer buffer)))
         (clrhash agent-shell-vertico-program-status--shells)))))

(defun bill/psp-test--shell (name &optional session-id)
  "Return a new shell buffer NAME with SESSION-ID, set up as the mode hook does."
  (let ((buffer (generate-new-buffer name)))
    (push buffer bill/psp-test--shells)
    (with-current-buffer buffer
      (setq bill/psp-test--session-id session-id)
      (agent-shell-vertico-program-status--subscribe))
    buffer))

(defun bill/psp-test--emit (buffer state &optional stop-reason child)
  "Deliver a `state-changed' event to BUFFER's subscriber."
  (let ((subscription (seq-find (lambda (entry)
                                  (and (eq (nth 0 entry) buffer)
                                       (eq (nth 1 entry) 'state-changed)))
                                bill/psp-test--subscriptions)))
    (should subscription)
    (with-current-buffer buffer
      (funcall (nth 2 subscription)
               (list (cons :event 'state-changed)
                     (cons :data (list (cons :id child)
                                       (cons :state state)
                                       (cons :stop-reason stop-reason))))))))

(defun bill/psp-test--sent-to (terminal)
  "Return the reports sent to TERMINAL, oldest first."
  (nreverse (mapcar #'cdr (seq-filter (lambda (entry) (eq (car entry) terminal))
                                      bill/psp-test--sent))))

(defun bill/psp-test--b64 (text)
  (base64-encode-string (encode-coding-string text 'utf-8 t) t))

(defun bill/psp-test--decoded (report key)
  "Return the decoded text of KEY in REPORT, nil when it is absent."
  (when (string-match (concat "[;:]" key "=\\([A-Za-z0-9+/=]*\\)") report)
    (decode-coding-string (base64-decode-string (match-string 1 report)) 'utf-8)))

;;; Formatter

(ert-deftest bill/psp-format-each-state ()
  (dolist (state '("idle" "working" "done" "error" "blocked"))
    (should (equal (agent-shell-vertico-program-status-format state :id "s1" :app "emacs" :title "a")
                   (concat "\e]7501;state=" state ":id=s1:app=emacs:title=YQ==\e\\"))))
  (should (equal (agent-shell-vertico-program-status-format "clear" :id "s1/task/t")
                 "\e]7501;state=clear:id=s1/task/t\e\\"))
  (should (equal (agent-shell-vertico-program-status-format "clear") "\e]7501;state=clear\e\\")))

(ert-deftest bill/psp-format-all-keys-in-order ()
  (should (equal (agent-shell-vertico-program-status-format "blocked" :id "a/b" :kind "question"
                                          :progress 40 :app "emacs"
                                          :title "t" :msg "m")
                 "\e]7501;state=blocked:id=a/b:kind=question:progress=40:app=emacs:title=dA==:msg=bQ==\e\\")))

(ert-deftest bill/psp-format-non-ascii-title ()
  (should (equal (agent-shell-vertico-program-status-format "working" :title "日本")
                 "\e]7501;state=working:title=5pel5pys\e\\")))

(ert-deftest bill/psp-format-truncates-at-byte-limits ()
  (let ((title (bill/psp-test--decoded
                (agent-shell-vertico-program-status-format "idle" :title (make-string 100 ?日))
                "title")))
    (should (equal title (make-string 64 ?日))))
  ;; A three-byte character that would cross the limit is dropped whole.
  (let ((title (bill/psp-test--decoded
                (agent-shell-vertico-program-status-format
                 "idle" :title (concat (make-string 191 ?a) "日"))
                "title")))
    (should (equal title (make-string 191 ?a))))
  (let ((msg (bill/psp-test--decoded
              (agent-shell-vertico-program-status-format "idle" :msg (make-string 3000 ?m))
              "msg")))
    (should (= (string-bytes msg) 2048))))

(ert-deftest bill/psp-format-strips-control-characters ()
  (should (equal (bill/psp-test--decoded
                  (agent-shell-vertico-program-status-format
                   "idle" :title (string ?a ?\n ?b ?\t ?c #x7f #x85 #x1b ?d))
                  "title")
                 "abcd"))
  ;; Nothing left: the key is omitted.
  (should (equal (agent-shell-vertico-program-status-format "idle" :title "\n\t")
                 "\e]7501;state=idle\e\\")))

(ert-deftest bill/psp-format-rejects-what-the-terminal-discards ()
  (should-error (agent-shell-vertico-program-status-format "busy"))
  (should-error (agent-shell-vertico-program-status-format "working" :kind "question"))
  (should-error (agent-shell-vertico-program-status-format "blocked" :kind "other"))
  (should-error (agent-shell-vertico-program-status-format "working" :progress 101))
  (should-error (agent-shell-vertico-program-status-format "working" :app "two words"))
  (should-error (agent-shell-vertico-program-status-format "working" :id "a b"))
  (should-error (agent-shell-vertico-program-status-format "working" :id "a//b"))
  (should-error (agent-shell-vertico-program-status-format "working" :id (make-string 33 ?a)))
  (should-error (agent-shell-vertico-program-status-format "working" :id "a/b/c/d/e/f/g/h/i"))
  (should-error (agent-shell-vertico-program-status-format
                 "working" :id (mapconcat #'identity (make-list 5 (make-string 30 ?a)) "/"))))

(ert-deftest bill/psp-segment-sanitises ()
  (should (equal (agent-shell-vertico-program-status--segment "*Claude Code @ repo*")
                 "-Claude-Code-repo-"))
  (should (equal (agent-shell-vertico-program-status--segment (make-string 40 ?x)) (make-string 32 ?x)))
  (should (equal (agent-shell-vertico-program-status--segment "") "shell"))
  (should (equal (agent-shell-vertico-program-status--segment "a.b_c+d-e") "a.b_c+d-e")))

(ert-deftest bill/psp-state-mapping ()
  (should (equal (agent-shell-vertico-program-status-state "running" nil nil) "working"))
  (should (equal (agent-shell-vertico-program-status-state "requires_action" nil "working") "blocked"))
  (should (equal (agent-shell-vertico-program-status-state "idle" "end_turn" "working") "done"))
  (should (equal (agent-shell-vertico-program-status-state "idle" "end_turn" "blocked") "done"))
  (should (equal (agent-shell-vertico-program-status-state "idle" "end_turn" nil) "idle"))
  (should (equal (agent-shell-vertico-program-status-state "idle" nil "idle") "idle"))
  (should (equal (agent-shell-vertico-program-status-state "idle" "error" nil) "error"))
  (should (equal (agent-shell-vertico-program-status-state "idle" "cancelled" "working") "idle"))
  (should-not (agent-shell-vertico-program-status-state "paused" nil nil)))

;;; Routing and lifecycle

(ert-deftest bill/psp-routes-only-to-rex-text-terminals ()
  (bill/psp-test--with-terminals
    (let ((shell (bill/psp-test--shell "*claude*" "sess-1")))
      (bill/psp-test--emit shell "running")
      (let ((expected (concat "\e]7501;state=working:id=sess-1:app=emacs:title="
                              (bill/psp-test--b64 "*claude*") ":msg="
                              (bill/psp-test--b64 "Working") "\e\\")))
        (should (equal (bill/psp-test--sent-to 'rex) (list expected)))
        (should (equal (bill/psp-test--sent-to 'rex-term) (list expected))))
      (should (= (length bill/psp-test--sent) 2)))))

(ert-deftest bill/psp-working-message-follows-active-tools ()
  (bill/psp-test--with-terminals
    (let ((shell (bill/psp-test--shell "*claude*" "s")))
      (bill/psp-test--emit shell "running")
      (let ((callback (nth 2 (seq-find (lambda (entry)
                                         (and (eq (car entry) shell)
                                              (eq (cadr entry) 'tool-call-update)))
                                       bill/psp-test--subscriptions))))
        (should callback)
        (cl-labels ((tool (id status title)
                      (with-current-buffer shell
                        (funcall callback
                                 `((:data . ((:tool-call-id . ,id)
                                             (:tool-call . ((:status . ,status)
                                                            (:title . ,title))))))))))
          (setq bill/psp-test--sent nil)
          (tool "a" "in_progress" "Reading config")
          (tool "b" "in_progress" "Running tests")
          ;; An old completion must not replace the current action.
          (tool "a" "completed" "Reading config")
          (tool "b" "completed" "Running tests")
          (should (equal (mapcar (lambda (report) (bill/psp-test--decoded report "msg"))
                                 (bill/psp-test--sent-to 'rex))
                         '("Reading config" "Running tests" "Running tests" "Working"))))))))

(defun bill/psp-test--tool (shell id status title &optional subagent)
  "Deliver a tool call update to SHELL, dispatched by SUBAGENT's session if given."
  (let ((callback (nth 2 (seq-find (lambda (entry)
                                     (and (eq (car entry) shell)
                                          (eq (cadr entry) 'tool-call-update)))
                                   bill/psp-test--subscriptions)))
        (agent-shell--subagent-group (and subagent (list subagent))))
    (should callback)
    (with-current-buffer shell
      (funcall callback
               `((:data . ((:tool-call-id . ,id)
                           (:tool-call . ((:status . ,status)
                                          (:title . ,title))))))))))

(defun bill/psp-test--messages (id)
  "Return the decoded msg of each report sent to `rex' for record ID."
  (delq nil (mapcar (lambda (report)
                      (when (string-match-p (concat ":id=" (regexp-quote id) ":") report)
                        (bill/psp-test--decoded report "msg")))
                    (bill/psp-test--sent-to 'rex))))

(ert-deftest bill/psp-subagent-tools-describe-the-subagent-record ()
  (bill/psp-test--with-terminals
    (let ((shell (bill/psp-test--shell "*claude*" "s")))
      (bill/psp-test--emit shell "running")
      (bill/psp-test--emit shell "running" nil "subagent/abc")
      (setq bill/psp-test--sent nil)
      (bill/psp-test--tool shell "t1" "in_progress" "Grep TODO" "abc")
      (bill/psp-test--tool shell "t2" "in_progress" "Read notes.org")
      (bill/psp-test--tool shell "t1" "completed" "Grep TODO" "abc")
      (should (equal (bill/psp-test--messages "s/subagent/abc") '("Grep TODO" "Working")))
      ;; The root reports its own tool, never the subagent's.
      (should (equal (bill/psp-test--messages "s") '("Read notes.org"))))))

(ert-deftest bill/psp-pending-server-tool-yields-to-the-next-tool ()
  (bill/psp-test--with-terminals
    (let ((shell (bill/psp-test--shell "*claude*" "s")))
      (bill/psp-test--emit shell "running")
      (setq bill/psp-test--sent nil)
      ;; A server-side tool (srvtoolu_) never gets a completed update.
      (bill/psp-test--tool shell "srvtoolu_1" "pending" "advisor")
      (bill/psp-test--tool shell "toolu_2" "in_progress" "Run tests")
      (bill/psp-test--tool shell "toolu_2" "completed" "Run tests")
      (should (equal (bill/psp-test--messages "s") '("advisor" "Run tests" "Working"))))))

(ert-deftest bill/psp-new-tool-clears-old-child-error ()
  (bill/psp-test--with-terminals
    (let ((shell (bill/psp-test--shell "*claude*" "s")))
      (bill/psp-test--emit shell "running")
      (bill/psp-test--emit shell "running" nil "task/failed")
      (bill/psp-test--emit shell "idle" "error" "task/failed")
      (setq bill/psp-test--sent nil)
      (with-current-buffer shell
        (agent-shell-vertico-program-status--on-tool-call
         '((:data . ((:tool-call-id . "next")
                     (:tool-call . ((:status . "in_progress") (:title . "Next action"))))))))
      (let ((reports (bill/psp-test--sent-to 'rex)))
        (should (member "\e]7501;state=clear:id=s/task/failed\e\\" reports))
        (should (equal (bill/psp-test--decoded (car (last reports)) "msg") "Next action"))))))

(ert-deftest bill/psp-done-uses-tracked-agent-message ()
  (bill/psp-test--with-terminals
    (let ((shell (bill/psp-test--shell "*claude*" "s")))
      (cl-letf (((symbol-function 'agent-shell-vertico-sidebar--last-message)
                 (lambda (buffer) (and (eq buffer shell) "Finished\nthe task"))))
        (bill/psp-test--emit shell "running")
        (bill/psp-test--emit shell "idle" "end_turn")
        (should (equal (bill/psp-test--decoded (car (last (bill/psp-test--sent-to 'rex))) "msg")
                       "Finished the task"))))))

(ert-deftest bill/psp-idle-after-running-is-done ()
  (bill/psp-test--with-terminals
    (let ((shell (bill/psp-test--shell "*claude*" "s")))
      (bill/psp-test--emit shell "idle" "end_turn")
      (bill/psp-test--emit shell "running")
      (bill/psp-test--emit shell "requires_action")
      (bill/psp-test--emit shell "idle" "end_turn")
      (should (equal (mapcar (lambda (r) (and (string-match "state=\\([a-z]+\\)" r)
                                              (match-string 1 r)))
                             (bill/psp-test--sent-to 'rex))
                     '("idle" "working" "blocked" "done"))))))

(ert-deftest bill/psp-error-and-cancelled ()
  (bill/psp-test--with-terminals
    (let ((shell (bill/psp-test--shell "*claude*" "s")))
      (bill/psp-test--emit shell "running")
      (bill/psp-test--emit shell "idle" "error")
      (bill/psp-test--emit shell "running")
      (bill/psp-test--emit shell "idle" "cancelled")
      (should (equal (mapcar (lambda (r) (and (string-match "state=\\([a-z]+\\)" r)
                                              (match-string 1 r)))
                             (bill/psp-test--sent-to 'rex))
                     '("working" "error" "working" "idle"))))))

(ert-deftest bill/psp-new-work-clears-previous-errors-across-shells ()
  (bill/psp-test--with-terminals
    (let ((a (bill/psp-test--shell "*a*" "a"))
          (b (bill/psp-test--shell "*b*" "b")))
      (bill/psp-test--emit a "running")
      (bill/psp-test--emit a "running" nil "task/failed")
      (bill/psp-test--emit b "running")
      (bill/psp-test--emit a "idle" "error" "task/failed")
      (bill/psp-test--emit b "idle" "error")
      (setq bill/psp-test--sent nil)
      ;; A new child can start while its parent is already running.
      (bill/psp-test--emit a "running" nil "task/new")
      (let ((reports (bill/psp-test--sent-to 'rex)))
        (should (member "\e]7501;state=clear:id=a/task/failed\e\\" reports))
        (should (member (concat "\e]7501;state=idle:id=b:app=emacs:title="
                                (bill/psp-test--b64 "*b*") "\e\\") reports))
        (should (member (concat "\e]7501;state=working:id=a/task/new:app=emacs:title="
                                (bill/psp-test--b64 "task/new") ":msg="
                                (bill/psp-test--b64 "Working") "\e\\") reports)))
      (should-not (alist-get "task/failed" (cdr (gethash a agent-shell-vertico-program-status--shells))
                             nil nil #'equal))
      (should (equal (alist-get nil (cdr (gethash b agent-shell-vertico-program-status--shells))) "idle")))))

(ert-deftest bill/psp-child-records-sit-beneath-the-shell ()
  (bill/psp-test--with-terminals
    (let ((shell (bill/psp-test--shell "*claude*" "s")))
      (bill/psp-test--emit shell "running" nil "subagent/abc def")
      (bill/psp-test--emit shell "running" nil
                           "task/0123456789abcdef0123456789abcdefXYZ")
      ;; A child first seen idle (a reloaded session's history) is skipped,
      ;; whatever stopped it.
      (bill/psp-test--emit shell "idle" "end_turn" "subagent/old")
      (bill/psp-test--emit shell "idle" "error" "task/old")
      (bill/psp-test--emit shell "idle" "end_turn" "subagent/abc def")
      (should (equal (bill/psp-test--sent-to 'rex)
                     (list (concat "\e]7501;state=working:id=s/subagent/abc-def:app=emacs:title="
                                   (bill/psp-test--b64 "subagent/abc def") ":msg="
                                   (bill/psp-test--b64 "Working") "\e\\")
                           (concat "\e]7501;state=working:id=s/task/0123456789abcdef0123456789abcdef:app=emacs:title="
                                   (bill/psp-test--b64 "task/0123456789abcdef0123456789abcdefXYZ") ":msg="
                                   (bill/psp-test--b64 "Working") "\e\\")
                           (concat "\e]7501;state=done:id=s/subagent/abc-def:app=emacs:title="
                                   (bill/psp-test--b64 "subagent/abc def") "\e\\")))))))

(ert-deftest bill/psp-slug-is-pinned-and-falls-back-to-buffer-name ()
  (bill/psp-test--with-terminals
    (let ((a (bill/psp-test--shell "*claude a*"))
          (b (bill/psp-test--shell "*claude a*x")))
      (bill/psp-test--emit a "running")
      ;; The session id arriving later does not rename the record.
      (with-current-buffer a (setq bill/psp-test--session-id "late"))
      (bill/psp-test--emit a "idle" "end_turn")
      (with-current-buffer b (setq bill/psp-test--session-id "late"))
      (bill/psp-test--emit b "running")
      (should (equal (mapcar (lambda (r) (and (string-match "id=\\([^:]+\\)" r)
                                              (match-string 1 r)))
                             (bill/psp-test--sent-to 'rex))
                     '("-claude-a-" "-claude-a-" "late"))))
    ;; Two shells whose names sanitise alike get distinct ids.
    (clrhash agent-shell-vertico-program-status--shells)
    (let ((c (bill/psp-test--shell "#same#"))
          (d (bill/psp-test--shell "?same?")))
      (bill/psp-test--emit c "running")
      (bill/psp-test--emit d "running")
      (let ((ids (last (mapcar (lambda (r) (and (string-match "id=\\([^:]+\\)" r)
                                                (match-string 1 r)))
                               (bill/psp-test--sent-to 'rex))
                       2)))
        (should (equal ids '("-same-" "-same--2")))))))

(ert-deftest bill/psp-seen-downgrades-done-and-clears-finished-children ()
  (bill/psp-test--with-terminals
    (let ((shell (bill/psp-test--shell "*claude*" "s")))
      (bill/psp-test--emit shell "running")
      (bill/psp-test--emit shell "running" nil "subagent/a")
      (bill/psp-test--emit shell "running" nil "task/b")
      (bill/psp-test--emit shell "idle" "end_turn" "subagent/a")
      (bill/psp-test--emit shell "idle" "end_turn")
      (setq bill/psp-test--sent nil)
      ;; The hook also runs for a window losing selection; that is not seen.
      (with-current-buffer shell
        (run-hook-with-args 'window-selection-change-functions 'other-window))
      (should-not bill/psp-test--sent)
      (with-current-buffer shell
        (run-hook-with-args 'window-selection-change-functions (selected-window)))
      (should (equal (sort (bill/psp-test--sent-to 'rex) #'string<)
                     (sort (list "\e]7501;state=clear:id=s/subagent/a\e\\"
                                 (concat "\e]7501;state=idle:id=s:app=emacs:title="
                                         (bill/psp-test--b64 "*claude*") "\e\\"))
                           #'string<)))
      ;; Seen again: nothing left to downgrade.
      (setq bill/psp-test--sent nil)
      (with-current-buffer shell
        (run-hook-with-args 'window-selection-change-functions (selected-window)))
      (should-not bill/psp-test--sent))))

(ert-deftest bill/psp-killed-shell-clears-its-record ()
  (bill/psp-test--with-terminals
    (let ((shell (bill/psp-test--shell "*claude*" "s")))
      (bill/psp-test--emit shell "running")
      (bill/psp-test--emit shell "running" nil "task/t")
      (setq bill/psp-test--sent nil)
      (kill-buffer shell)
      (should (equal (bill/psp-test--sent-to 'rex) '("\e]7501;state=clear:id=s\e\\")))
      (should (equal (bill/psp-test--sent-to 'rex-term) '("\e]7501;state=clear:id=s\e\\")))
      (should (= (hash-table-count agent-shell-vertico-program-status--shells) 0)))))

(ert-deftest bill/psp-replays-records-to-an-attaching-rex-terminal ()
  (bill/psp-test--with-terminals
    (let ((shell (bill/psp-test--shell "*claude*" "s")))
      (bill/psp-test--emit shell "running")
      (bill/psp-test--emit shell "requires_action" nil "subagent/a")
      (setq bill/psp-test--sent nil)
      (setq bill/psp-test--frame-terminal 'rex-term)
      ;; Call the hook function alone: other suites in the same process
      ;; put their own terminal setup on `tty-setup-hook'.
      (agent-shell-vertico-program-status--replay-h)
      (should (equal (bill/psp-test--sent-to 'rex-term)
                     (list (concat "\e]7501;state=working:id=s:app=emacs:title="
                                   (bill/psp-test--b64 "*claude*") ":msg="
                                   (bill/psp-test--b64 "Working") "\e\\")
                           (concat "\e]7501;state=blocked:id=s/subagent/a:app=emacs:title="
                                   (bill/psp-test--b64 "subagent/a") "\e\\"))))
      (should (= (length bill/psp-test--sent) 2))
      ;; A terminal that is not a Rex pane gets nothing.
      (setq bill/psp-test--sent nil)
      (setq bill/psp-test--frame-terminal 'plain)
      (agent-shell-vertico-program-status--replay-h)
      (should-not bill/psp-test--sent))))

(ert-deftest bill/psp-deleted-terminal-is-cleared ()
  (bill/psp-test--with-terminals
    (let ((a (bill/psp-test--shell "*a*" "sa"))
          (b (bill/psp-test--shell "*b*" "sb")))
      (bill/psp-test--emit a "running")
      (bill/psp-test--emit b "idle" "end_turn")
      (setq bill/psp-test--sent nil)
      (agent-shell-vertico-program-status--retract 'rex)
      (should (equal (sort (bill/psp-test--sent-to 'rex) #'string<)
                     '("\e]7501;state=clear:id=sa\e\\" "\e]7501;state=clear:id=sb\e\\")))
      (should (= (length bill/psp-test--sent) 2))
      ;; A terminal that never got a report is left alone.
      (setq bill/psp-test--sent nil)
      (agent-shell-vertico-program-status--retract 'plain)
      (should-not bill/psp-test--sent)
      ;; Emacs exit clears every terminal reported to.
      (agent-shell-vertico-program-status--retract-h)
      (should (= (length (bill/psp-test--sent-to 'rex)) 2))
      (should (= (length (bill/psp-test--sent-to 'rex-term)) 2))
      (should (= (length bill/psp-test--sent) 4)))))

(provide 'emacs-agent-shell-program-status)

;;; emacs-agent-shell-program-status.el ends here
