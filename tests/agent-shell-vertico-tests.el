;;; agent-shell-vertico-tests.el --- Tests for agent-shell-vertico -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'map)
(require 'timer)

(add-to-list 'load-path (expand-file-name "tests/support" default-directory))
(add-to-list 'load-path default-directory)

(defun agent-shell-vertico-tests--ensure-agent-shell-stub ()
  "Reject a test environment using the real agent-shell package."
  (unless (bound-and-true-p agent-shell-test-stub-p)
    (user-error
     "Tests require isolated Emacs with tests/support/agent-shell.el")))

(when (featurep 'agent-shell)
  (agent-shell-vertico-tests--ensure-agent-shell-stub))
(require 'agent-shell)
(agent-shell-vertico-tests--ensure-agent-shell-stub)

(require 'agent-shell-vertico)
(require 'agent-shell-vertico-sidebar)
(require 'agent-shell-vertico-transcript)
(require 'agent-shell-vertico-resume)
(require 'agent-shell-vertico-prompt-queue)
(require 'agent-shell-vertico-consult)
(require 'agent-shell-vertico-links)

;; Declare as a dynamic variable so `let' bindings below are dynamic and
;; visible to functions under test. Mirrors how the real `embark-keymap-alist'
;; is declared by embark.el.
(defvar embark-keymap-alist)
(defvar embark-default-action-overrides)
(defvar embark-target-finders)
(defvar embark-quit-after-action)
(defvar agent-shell-viewport-view-mode-hook)
(defvar agent-shell-viewport-edit-mode-hook)
(defvar evil-local-mode)
(defvar evil-state)
(defvar persp-activated-functions)
(defvar persp-before-deactivate-functions)

(defun agent-shell-vertico-tests--package-requirement (file dependency)
  "Return DEPENDENCY's declared version from FILE's package header."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (when (re-search-forward
           (format "(%s \"\\([^\"]+\\)\")" (regexp-quote dependency))
           nil t)
      (match-string 1))))

(ert-deftest agent-shell-vertico-package-headers-require-supported-apis ()
  "Package metadata must not promise dependency versions that fail to load."
  (dolist (spec '(("agent-shell-vertico.el" . "0.63.5")
                  ("agent-shell-vertico-sidebar.el" . "0.60.2")
                  ("agent-shell-vertico-transcript.el" . "0.63.5")
                  ("agent-shell-vertico-prompt-queue.el" . "0.63.5")
                  ("agent-shell-vertico-resume.el" . "0.63.5")
                  ("agent-shell-vertico-consult.el" . "0.63.5")
                  ("agent-shell-vertico-links.el" . "0.63.5")))
    (should
     (equal
      (agent-shell-vertico-tests--package-requirement (car spec) "agent-shell")
      (cdr spec))))
  (dolist (file '("agent-shell-vertico.el"
                  "agent-shell-vertico-transcript.el"
                  "agent-shell-vertico-resume.el"
                  "agent-shell-vertico-prompt-queue.el"
                  "agent-shell-vertico-consult.el"))
    (should (equal
             (agent-shell-vertico-tests--package-requirement file "marginalia")
             "2.1")))
  ;; Narrowing is configured with the `(:predicate FN :keys ALIST)' plist
  ;; Consult has taken since 2.4.  It is also the earliest release there
  ;; is: Consult went from 1.8 straight to 2.4.
  (should (equal
           (agent-shell-vertico-tests--package-requirement
            "agent-shell-vertico-consult.el" "consult")
           "2.4")))

(defvar markdown-ts-inline-images)
(defvar markdown-ts-view-mode-pre-init-hook)
(defvar markdown-ts-fontify-code-blocks-natively)

(defun agent-shell-vertico-tests--fail-if-run ()
  "Signal when a hook that must be replaced is run."
  (error "Buffer-amending hook ran"))

(define-derived-mode agent-shell-vertico-tests--markdown-mode text-mode
  "Test Markdown"
  "Stand-in for a Markdown major mode.
The real Markdown modes are not available to the suite.")

(define-derived-mode agent-shell-vertico-tests--derived-markdown-mode
  agent-shell-vertico-tests--markdown-mode
  "Test Markdown Child"
  "Stand-in for a mode built on a Markdown major mode.")

(defmacro agent-shell-vertico-tests--with-sidebar (&rest body)
  "Evaluate BODY in a freshly initialized named sidebar buffer."
  (declare (indent 0) (debug t))
  `(let ((sidebar (get-buffer-create "*Agent Shell Sessions*")))
     (unwind-protect
         (with-current-buffer sidebar
           (agent-shell-vertico-sidebar-mode)
           ,@body)
       (when (buffer-live-p sidebar)
         (kill-buffer sidebar)))))

(cl-defun agent-shell-vertico-tests--insert-block
    (&key qid kind group-id label-left label-right body (navigatable t)
          (collapsed nil) (invisible nil))
  "Insert a fragment block mimicking `agent-shell-ui--insert-fragment'.
QID is the qualified id; LABEL-LEFT, LABEL-RIGHT, and BODY are the
section texts; NAVIGATABLE sets the `:navigatable' state flag.  KIND is
the fragment `:kind' (`group' for an activity-group header); GROUP-ID is
the qualified id of the header this block nests under.  COLLAPSED and
INVISIBLE set the corresponding fold state and text property.  Return
the block start position."
  (let ((start (point)))
    (when (and (or label-left label-right) body)
      (let ((i (point)))
        (insert "▶ ")
        (put-text-property i (point) 'agent-shell-ui-section 'indicator)))
    (when label-left
      (let ((i (point)))
        (insert label-left)
        (put-text-property i (point) 'agent-shell-ui-section 'label-left)))
    (when label-right
      (when label-left (insert " "))
      (let ((i (point)))
        (insert label-right)
        (put-text-property i (point) 'agent-shell-ui-section 'label-right)))
    (when body
      (when (or label-left label-right) (insert "\n\n"))
      (let ((i (point)))
        (insert body)
        (put-text-property i (point) 'agent-shell-ui-section 'body)))
    (put-text-property start (point) 'agent-shell-ui-state
                       (list (cons :qualified-id qid)
                             (cons :kind kind)
                             (cons :group-id group-id)
                             (cons :collapsed collapsed)
                             (cons :navigatable navigatable)))
    (when invisible
      (put-text-property start (point) 'invisible t))
    (insert "\n\n")
    start))

(defmacro agent-shell-vertico-tests--with-session-buffers (bindings &rest body)
  "Create session buffers from BINDINGS and evaluate BODY.

Each element in BINDINGS is of the form:

  (SYMBOL BUFFER-NAME DIRECTORY STATE)"
  (declare (indent 1))
  `(let (created)
     (unwind-protect
         (cl-letf (((symbol-value 'agent-shell-test-buffers) nil)
                    ((symbol-value 'agent-shell-test-project-buffers) nil)
                    ((symbol-value 'agent-shell-test-last-command) nil)
                    ((symbol-value 'agent-shell-test-last-buffer) nil)
                    ((symbol-value 'agent-shell-test-last-args) nil)
                    ((symbol-value 'agent-shell-test-last-target) nil)
                    ((symbol-value 'agent-shell-test-statuses) nil)
                    ((symbol-value 'agent-shell-test-project-names) nil)
                    ((symbol-value 'agent-shell-test-buffer-query-count) 0)
                    ((symbol-value 'agent-shell-test-status-query-count) 0)
                    ((symbol-value 'agent-shell-test-subscriptions) nil)
                    ((symbol-value
                      'agent-shell-vertico-sidebar--busy-since-times)
                     (make-hash-table :test #'eq))
                    ((symbol-value 'agent-shell-vertico-sidebar--attention)
                     (make-hash-table :test #'eq))
                    ((symbol-value 'agent-shell-vertico-sidebar--activity)
                     (make-hash-table :test #'eq))
                    ((symbol-value 'agent-shell-vertico-sidebar--subscriptions)
                     (make-hash-table :test #'eq))
                    ((symbol-value 'agent-shell-vertico-sidebar--out-of-turn)
                     (make-hash-table :test #'eq))
                    ((symbol-value 'agent-shell-vertico-sidebar--messages)
                     (make-hash-table :test #'eq))
                    ((symbol-value 'agent-shell-test-displayed-buffer) nil)
                    ((symbol-value 'agent-shell-test-viewport-buffer) nil)
                    ((symbol-value
                      'agent-shell-vertico-read-session-function)
                     #'agent-shell-vertico--completing-read-session)
                    ((symbol-value 'agent-shell-agent-configs) nil)
                    ;; Render assertions name the plain marks, so they must
                    ;; not depend on whether nerd-icons happens to be
                    ;; installed where the suite runs.  Tests about icons
                    ;; bind these themselves.
                    ((symbol-value
                      'agent-shell-vertico-sidebar-use-nerd-icons)
                     nil)
                    ((symbol-value
                      'agent-shell-vertico-sidebar--nerd-icons-available)
                     'unknown)
                    ((symbol-value 'agent-shell-mode-hook) nil))
           (let ,(mapcar
                  (lambda (binding)
                    (pcase-let ((`(,symbol ,name ,directory ,state) binding))
                      `(,symbol
                        (let ((buffer (generate-new-buffer ,name)))
                          (push buffer created)
                          (with-current-buffer buffer
                            (agent-shell-mode)
                            (setq default-directory ,directory)
                            (setq-local agent-shell--state ,state))
                          buffer))))
                  bindings)
             ,@body))
       (mapc (lambda (buffer)
               (when (buffer-live-p buffer)
                 (kill-buffer buffer)))
             created))))

(ert-deftest agent-shell-vertico-sidebar-groups-by-project-root ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha one")))))
       (alpha-two "Claude Agent @ alpha-two" "/work/alpha/"
                  '((:session . ((:id . "a2") (:title . "Alpha two")))))
       (beta "Codex Agent @ beta" "/work/beta/"
             '((:session . ((:id . "b") (:title . "Beta"))))))
    (let ((groups (agent-shell-vertico-sidebar--group-buffers
                   (list alpha alpha-two beta))))
      (should (equal (mapcar #'car groups)
                     '("/work/alpha/" "/work/beta/")))
      (should (equal (mapcar #'length (mapcar #'cdr groups)) '(2 1))))))

(ert-deftest agent-shell-vertico-sidebar-uses-agent-shell-project-name ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-test-project-names (list (cons alpha "Alpha Workspace")))
          (agent-shell-vertico-sidebar-group-by nil)
          (agent-shell-vertico-sidebar-extra-info '(project)))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (agent-shell-vertico-sidebar--render)
        (search-forward "⌂ Alpha Workspace")
        (should (equal (get-text-property (1- (point)) 'help-echo)
                       "/work/alpha/"))
        (let ((case-fold-search nil))
          (should-not (string-match-p "⌂ alpha" (buffer-string))))
        (setq agent-shell-vertico-sidebar-group-by 'project)
        (agent-shell-vertico-sidebar--render)
        (should (string-match-p "Alpha Workspace" (buffer-string)))))))

(ert-deftest agent-shell-vertico-sidebar-priority-puts-attention-first ()
  (agent-shell-vertico-tests--with-session-buffers
      ((ready "Codex Agent @ ready" "/work/ready/"
              '((:session . ((:id . "r") (:title . "Ready")))))
       (blocked "Claude Agent @ blocked" "/work/blocked/"
                '((:session . ((:id . "b") (:title . "Blocked"))))))
    (let ((agent-shell-test-statuses (list (cons ready 'ready)
                                           (cons blocked 'blocked))))
      (should (equal (agent-shell-vertico-sidebar--sort-buffers
                      (list ready blocked) 'priority)
                     (list blocked ready))))))

(ert-deftest agent-shell-vertico-sidebar-priority-uses-busy-entry-time ()
  (agent-shell-vertico-tests--with-session-buffers
      ((older "Codex Agent @ older" "/work/older/"
              '((:session . ((:id . "o") (:title . "Older")))))
       (newer "Claude Agent @ newer" "/work/newer/"
              '((:session . ((:id . "n") (:title . "Newer"))))))
    (let ((agent-shell-test-statuses (list (cons older 'busy)
                                           (cons newer 'busy))))
      ;; Priority orders working sessions oldest first: the turn that
      ;; entered the busy state earliest leads.  Streaming chunks can
      ;; arrive in either order and must not reorder them.
      (puthash older 100.0 agent-shell-vertico-sidebar--busy-since-times)
      (puthash newer 200.0 agent-shell-vertico-sidebar--busy-since-times)
      (puthash older 300.0 agent-shell-vertico-sidebar--activity)
      (puthash newer 150.0 agent-shell-vertico-sidebar--activity)
      (should (equal (agent-shell-vertico-sidebar--sort-buffers
                      (list newer older) 'priority)
                     (list older newer))))))

(ert-deftest agent-shell-vertico-sidebar-priority-attention-oldest-first ()
  (agent-shell-vertico-tests--with-session-buffers
      ((older "Codex Agent @ older" "/work/older/"
              '((:session . ((:id . "o") (:title . "Older")))))
       (newer "Claude Agent @ newer" "/work/newer/"
              '((:session . ((:id . "n") (:title . "Newer"))))))
    (let ((agent-shell-test-statuses (list (cons older 'ready)
                                           (cons newer 'ready))))
      ;; The longest-waiting attention mark leads the list, matching what
      ;; `agent-shell-vertico-sidebar-jump' visits.
      (puthash older (list :kind 'done :time 100.0)
               agent-shell-vertico-sidebar--attention)
      (puthash newer (list :kind 'done :time 200.0)
               agent-shell-vertico-sidebar--attention)
      (should (equal (agent-shell-vertico-sidebar--sort-buffers
                      (list newer older) 'priority)
                     (list older newer))))))

(ert-deftest agent-shell-vertico-sidebar-priority-orders-ready-by-activity ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha")))))
       (beta "Codex Agent @ beta" "/work/beta/"
             '((:session . ((:id . "b") (:title . "Beta"))))))
    (let ((agent-shell-test-statuses (list (cons alpha 'ready)
                                           (cons beta 'ready))))
      ;; Ready sessions order by their latest activity, not by title: a
      ;; session that finished work recently stays above a staler one.
      (puthash alpha 100.0 agent-shell-vertico-sidebar--activity)
      (puthash beta 200.0 agent-shell-vertico-sidebar--activity)
      (should (equal (agent-shell-vertico-sidebar--sort-buffers
                      (list alpha beta) 'priority)
                     (list beta alpha))))))

(ert-deftest agent-shell-vertico-sidebar-priority-keeps-read-session-above-stale-idle ()
  (agent-shell-vertico-tests--with-session-buffers
      ((zebra "Codex Agent @ zebra" "/work/zebra/"
              '((:session . ((:id . "z") (:title . "Zebra")))))
       (apple "Codex Agent @ apple" "/work/apple/"
              '((:session . ((:id . "p") (:title . "Apple"))))))
    (let ((agent-shell-test-statuses (list (cons zebra 'ready)
                                           (cons apple 'ready))))
      (puthash zebra 300.0 agent-shell-vertico-sidebar--activity)
      (puthash apple 100.0 agent-shell-vertico-sidebar--activity)
      (puthash zebra (list :kind 'done :time 300.0)
               agent-shell-vertico-sidebar--attention)
      ;; Unread, the finished session leads the list.
      (should (equal (agent-shell-vertico-sidebar--sort-buffers
                      (list apple zebra) 'priority)
                     (list zebra apple)))
      (agent-shell-vertico-sidebar--mark-seen zebra)
      ;; Read, it keeps the top of the ready tier by its activity time
      ;; instead of dropping to its alphabetical slot.
      (should (equal (agent-shell-vertico-sidebar--sort-buffers
                      (list apple zebra) 'priority)
                     (list zebra apple))))))

(ert-deftest agent-shell-vertico-sidebar-title-tie-break-ignores-case ()
  (agent-shell-vertico-tests--with-session-buffers
      ((apple "Codex Agent @ apple" "/work/apple/"
              '((:session . ((:id . "p") (:title . "apple")))))
       (zebra "Codex Agent @ zebra" "/work/zebra/"
              '((:session . ((:id . "z") (:title . "Zebra"))))))
    (let ((agent-shell-test-statuses (list (cons apple 'ready)
                                           (cons zebra 'ready))))
      (puthash apple 150.0 agent-shell-vertico-sidebar--activity)
      (puthash zebra 150.0 agent-shell-vertico-sidebar--activity)
      ;; Equal times fall back to the title, where case never decides.
      (should (equal (agent-shell-vertico-sidebar--sort-buffers
                      (list zebra apple) 'priority)
                     (list apple zebra)))
      (should (equal (agent-shell-vertico-sidebar--sort-buffers
                      (list zebra apple) 'name)
                     (list apple zebra))))))

(ert-deftest agent-shell-vertico-sidebar-busy-entry-time-ignores-chunks ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha"))))))
    (let ((times '(10.0 20.0 30.0)))
      (cl-letf (((symbol-function 'float-time)
                 (lambda (&optional _time) (pop times))))
        (agent-shell-vertico-sidebar--handle-event
         alpha '((:event . input-submitted)))
        (should (= (gethash alpha
                            agent-shell-vertico-sidebar--busy-since-times)
                   10.0))
        (agent-shell-vertico-sidebar--handle-event
         alpha '((:event . agent-message-chunk)))
        (should (= (gethash alpha
                            agent-shell-vertico-sidebar--busy-since-times)
                   10.0))
        (agent-shell-vertico-sidebar--handle-event
         alpha '((:event . turn-complete)))
        (should-not (gethash alpha
                             agent-shell-vertico-sidebar--busy-since-times))))))

(ert-deftest agent-shell-vertico-sidebar-priority-sorts-project-groups ()
  (agent-shell-vertico-tests--with-session-buffers
      ((quiet "Codex Agent @ quiet" "/work/quiet/"
              '((:session . ((:id . "q") (:title . "Quiet")))))
       (urgent-ready "Codex Agent @ urgent-ready" "/work/urgent/"
                     '((:session . ((:id . "ur") (:title . "Urgent ready")))))
       (urgent-blocked "Codex Agent @ urgent-blocked" "/work/urgent/"
                       '((:session . ((:id . "ub")
                                      (:title . "Urgent blocked"))))))
    (let ((agent-shell-test-buffers
           (list quiet urgent-ready urgent-blocked))
          (agent-shell-test-statuses
           (list (cons quiet 'ready)
                 (cons urgent-ready 'ready)
                 (cons urgent-blocked 'blocked))))
      (let ((groups (agent-shell-vertico-sidebar--sort-groups
                     (agent-shell-vertico-sidebar--group-buffers
                      agent-shell-test-buffers)
                     'priority)))
        (should (equal (mapcar #'car groups)
                       '("/work/urgent/" "/work/quiet/")))
        (should (eq (cadr (car groups)) urgent-blocked))))))

(ert-deftest agent-shell-vertico-sidebar-defaults-to-flat ()
  (should-not (default-value 'agent-shell-vertico-sidebar-group-by)))

(ert-deftest agent-shell-vertico-sidebar-default-width-is-roomy ()
  (should (= (default-value 'agent-shell-vertico-sidebar-width) 40)))

(ert-deftest agent-shell-vertico-sidebar-default-max-width-fraction ()
  (should (= (default-value 'agent-shell-vertico-sidebar-max-width-fraction)
             0.3)))

(ert-deftest agent-shell-vertico-sidebar-clamp-width-keeps-roomy-frames ()
  "The configured width wins whenever the frame has room for it."
  (let ((agent-shell-vertico-sidebar-max-width-fraction 0.3))
    (should (= (agent-shell-vertico-sidebar--clamp-width 40 200) 40))))

(ert-deftest agent-shell-vertico-sidebar-clamp-width-caps-narrow-frames ()
  "A narrow frame caps the sidebar to its share of the columns."
  (let ((agent-shell-vertico-sidebar-max-width-fraction 0.3))
    (should (= (agent-shell-vertico-sidebar--clamp-width 40 60) 18))))

(ert-deftest agent-shell-vertico-sidebar-clamp-width-keeps-a-readable-floor ()
  "The cap stops at 16 columns, and still never widens the sidebar."
  (let ((agent-shell-vertico-sidebar-max-width-fraction 0.3))
    (should (= (agent-shell-vertico-sidebar--clamp-width 40 20) 16))
    (should (= (agent-shell-vertico-sidebar--clamp-width 12 20) 12))))

(ert-deftest agent-shell-vertico-sidebar-clamp-width-nil-fraction-disables ()
  "A nil fraction disables the cap entirely."
  (let ((agent-shell-vertico-sidebar-max-width-fraction nil))
    (should (= (agent-shell-vertico-sidebar--clamp-width 40 60) 40))))

(ert-deftest agent-shell-vertico-sidebar-status-sort-ignores-attention ()
  (agent-shell-vertico-tests--with-session-buffers
      ((ready "Codex Agent @ ready" "/work/ready/"
              '((:session . ((:id . "r") (:title . "Ready")))))
       (working "Claude Agent @ working" "/work/working/"
                '((:session . ((:id . "w") (:title . "Working"))))))
    (let ((agent-shell-test-statuses (list (cons ready 'ready)
                                           (cons working 'busy))))
      (puthash ready (list :kind 'done :time 2.0)
               agent-shell-vertico-sidebar--attention)
      (should (equal (agent-shell-vertico-sidebar--sort-buffers
                      (list ready working) 'status)
                     (list working ready))))))

(ert-deftest agent-shell-vertico-sidebar-recency-sorts-by-display-time ()
  (agent-shell-vertico-tests--with-session-buffers
      ((old "Codex Agent @ old" "/work/old/"
            '((:session . ((:id . "o") (:title . "Old")))))
       (new "Codex Agent @ new" "/work/new/"
            '((:session . ((:id . "n") (:title . "New"))))))
    (with-current-buffer old
      (setq-local buffer-display-time (encode-time 0 0 10 1 1 2026)))
    (with-current-buffer new
      (setq-local buffer-display-time (encode-time 0 0 12 1 1 2026)))
    (should (equal (agent-shell-vertico-sidebar--sort-buffers
                    (list old new) 'recency)
                   (list new old)))))

(ert-deftest agent-shell-vertico-sidebar-renders-stacked-session-blocks ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a")
                             (:title . "Review alpha")
                             (:model-id . "gpt-5")
                             (:models . [((:model-id . "gpt-5")
                                          (:name . "GPT-5"))])
                             (:mode-id . "plan")
                             (:modes . [((:id . "plan") (:name . "Plan"))]))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar-group-by 'project)
          (agent-shell-vertico-sidebar-show-details t)
          (agent-shell-vertico-sidebar-sort-by 'name))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (puthash "/work/alpha/" t agent-shell-vertico-sidebar--expanded-projects)
        (agent-shell-vertico-sidebar--render)
        (should (string-match-p "alpha" (buffer-string)))
        (should (string-match-p "Review alpha" (buffer-string)))
        (should (string-match-p "GPT-5" (buffer-string)))
        (goto-char (point-min))
        (search-forward "Review alpha")
        (should (eq (get-text-property (line-beginning-position)
                                       'agent-shell-vertico-sidebar-node)
                    alpha))))))

(ert-deftest agent-shell-vertico-sidebar-renders-flat-compact-rows ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar-group-by nil)
          (agent-shell-vertico-sidebar-show-details nil))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (agent-shell-vertico-sidebar--render)
        (should (string-match-p "Review alpha" (buffer-string)))
        (should (string-match-p "⌂ alpha" (buffer-string)))
        (should (= (count-lines (point-min) (point-max)) 2))
        (should-not (eq (get-text-property
                         (point-min) 'agent-shell-vertico-sidebar-node-kind)
                        'project))))))

(ert-deftest agent-shell-vertico-sidebar-flat-project-context-is-actionable ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar-group-by nil)
          (agent-shell-vertico-sidebar-show-details nil))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (agent-shell-vertico-sidebar--render)
        (search-forward "⌂ alpha")
        (should (eq (get-text-property (1- (point))
                                       'agent-shell-vertico-sidebar-field)
                    'project))
        (should (equal (get-text-property
                        (1- (point)) 'help-echo)
                       "/work/alpha/"))))))

(ert-deftest agent-shell-vertico-sidebar-extra-info-fields-are-identifiable ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a")
                             (:title . "Review alpha")
                             (:model-id . "gpt-5")
                             (:models . [((:model-id . "gpt-5")
                                          (:name . "GPT-5"))])
                             (:mode-id . "plan")
                             (:modes . [((:id . "plan")
                                         (:name . "Plan"))]))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar-show-details t)
          (agent-shell-vertico-sidebar-extra-info '(mode status model)))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (agent-shell-vertico-sidebar--render)
        (dolist (case '(("Plan" . mode)
                       ("Ready" . status)
                       ("GPT-5" . model)))
          (goto-char (point-min))
          (search-forward (car case))
          (should (eq (get-text-property (1- (point))
                                         'agent-shell-vertico-sidebar-field)
                      (cdr case)))
          (should (eq (get-text-property (1- (point)) 'mouse-face)
                      'highlight))
          (should (equal (get-text-property (1- (point)) 'kbd-help)
                         (get-text-property (1- (point)) 'help-echo)))
          (should-not (get-text-property (point) 'mouse-face)))))))

(ert-deftest agent-shell-vertico-sidebar-field-help-works-at-point ()
  (require 'help-at-pt)
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a")
                             (:title . "Review alpha")
                             (:mode-id . "plan")
                             (:modes . [((:id . "plan")
                                         (:name . "Plan"))]))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar-show-details t)
          (agent-shell-vertico-sidebar-extra-info '(mode)))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (agent-shell-vertico-sidebar--render)
        (search-forward "Plan")
        (should (equal (help-at-pt-kbd-string)
                       "RET/mouse-1: set mode"))))))

(ert-deftest agent-shell-vertico-sidebar-activates-fields-at-point ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a")
                             (:title . "Review alpha")
                             (:model-id . "gpt-5")
                             (:models . [((:model-id . "gpt-5")
                                          (:name . "GPT-5"))])
                             (:mode-id . "plan")
                             (:modes . [((:id . "plan")
                                         (:name . "Plan"))]))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar-show-details t)
          (agent-shell-vertico-sidebar-extra-info '(project mode model))
          (opened-root nil))
      (cl-letf (((symbol-function 'dired-other-window)
                 (lambda (root) (setq opened-root root))))
        (with-temp-buffer
          (agent-shell-vertico-sidebar-mode)
          (agent-shell-vertico-sidebar--render)
          (search-forward "Plan")
          (agent-shell-vertico-sidebar-activate)
          (should (eq agent-shell-test-last-command
                      'agent-shell-set-session-mode))
          (goto-char (point-min))
          (search-forward "GPT-5")
          (agent-shell-vertico-sidebar-activate)
          (should (eq agent-shell-test-last-command
                      'agent-shell-set-session-model))
          (goto-char (point-min))
          (search-forward "⌂ alpha")
          (agent-shell-vertico-sidebar-activate)
          (should (equal opened-root "/work/alpha/")))))))

(ert-deftest agent-shell-vertico-sidebar-activation-opens-title-session ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar-group-by nil))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (agent-shell-vertico-sidebar--render)
        (search-forward "Review alpha")
        (agent-shell-vertico-sidebar-activate)
        (should (eq agent-shell-test-displayed-buffer alpha))))))

(ert-deftest agent-shell-vertico-sidebar-mouse-activation-uses-event-position ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar-extra-info '(project))
          (called nil))
      (save-window-excursion
        (with-temp-buffer
          (agent-shell-vertico-sidebar-mode)
          (agent-shell-vertico-sidebar--render)
          (search-forward "⌂ alpha")
          (let ((clicked (1- (point)))
                (sidebar (current-buffer)))
            (set-window-buffer (selected-window) sidebar)
            (cl-letf (((symbol-function 'event-end)
                       (lambda (_event) (list (selected-window) clicked)))
                      ((symbol-function 'agent-shell-vertico-sidebar-open-project)
                       (lambda () (setq called t))))
              (agent-shell-vertico-sidebar-activate 'fake-event)
              (should called))))))))

(ert-deftest agent-shell-vertico-sidebar-default-extra-info ()
  (should (equal
           (default-value 'agent-shell-vertico-sidebar-extra-info)
           '(agent project model mode activity)))
  (should-not
   (memq 'last-user-message
         (default-value 'agent-shell-vertico-sidebar-extra-info)))
  ;; The row icon already carries the status, so the default leaves the
  ;; textual status value out.
  (should-not
   (memq 'status
         (default-value 'agent-shell-vertico-sidebar-extra-info))))

(ert-deftest agent-shell-vertico-sidebar-agent-shares-row-with-model ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:agent-config . ((:buffer-name . "Codex")))
                (:session . ((:id . "a")
                             (:title . "Review alpha")
                             (:model-id . "gpt-5")
                             (:models . [((:model-id . "gpt-5")
                                          (:name . "GPT-5"))]))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar-group-by nil)
          (agent-shell-vertico-sidebar-show-details t)
          (agent-shell-vertico-sidebar-extra-info '(agent model)))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (should (equal
                 (split-string (substring-no-properties (buffer-string))
                               "\n" t)
                 '("✓ Review alpha" "Codex · GPT-5")))))))

(ert-deftest agent-shell-vertico-sidebar-agent-value-is-identifiable ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:agent-config . ((:buffer-name . "Codex")))
                (:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar-group-by nil)
          (agent-shell-vertico-sidebar-show-details t)
          (agent-shell-vertico-sidebar-extra-info '(agent)))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (agent-shell-vertico-sidebar--render)
        (search-forward "Codex")
        (should (eq (get-text-property (1- (point))
                                       'agent-shell-vertico-sidebar-field)
                    'agent))
        (should (eq (get-text-property (1- (point)) 'mouse-face)
                    'highlight))
        (should (equal (get-text-property (1- (point)) 'help-echo)
                       "RET/mouse-1: new session with this agent"))))))

(ert-deftest agent-shell-vertico-sidebar-omits-agent-without-name ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar-group-by nil)
          (agent-shell-vertico-sidebar-show-details t)
          (agent-shell-vertico-sidebar-extra-info '(agent model)))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (should (equal
                 (split-string (substring-no-properties (buffer-string))
                               "\n" t)
                 '("✓ Review alpha" "-")))))))

(ert-deftest agent-shell-vertico-agent-name-prefers-mode-line-name ()
  (agent-shell-vertico-tests--with-session-buffers
      ((named "Gemini Agent @ alpha" "/work/alpha/"
              '((:agent-config . ((:mode-line-name . "Gemini CLI")
                                  (:buffer-name . "Gemini Agent")))
                (:session . ((:id . "a") (:title . "Alpha")))))
       (plain "Codex Agent @ beta" "/work/beta/"
              '((:agent-config . ((:buffer-name . "Codex")))
                (:session . ((:id . "b") (:title . "Beta")))))
       (bare "Agent @ gamma" "/work/gamma/"
             '((:session . ((:id . "c") (:title . "Gamma"))))))
    (should (equal (agent-shell-vertico--agent-name named) "Gemini CLI"))
    (should (equal (agent-shell-vertico--agent-name plain) "Codex"))
    (should-not (agent-shell-vertico--agent-name bare))))

(ert-deftest agent-shell-vertico-sidebar-activates-agent-with-new-session ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:agent-config . ((:buffer-name . "Codex")))
                (:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar-group-by nil)
          (agent-shell-vertico-sidebar-show-details t)
          (agent-shell-vertico-sidebar-extra-info '(agent)))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (agent-shell-vertico-sidebar--render)
        (search-forward "Codex")
        (agent-shell-vertico-sidebar-activate)
        (should (eq agent-shell-test-last-command 'agent-shell--new-shell))
        (should (equal (plist-get agent-shell-test-last-args :location)
                       "/work/alpha/"))
        (should (equal (map-elt (plist-get agent-shell-test-last-args :config)
                                :buffer-name)
                       "Codex"))))))

(ert-deftest agent-shell-vertico-sidebar-extra-info-selects-fields ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a")
                             (:title . "Review alpha")
                             (:model-id . "gpt-5")
                             (:models . [((:model-id . "gpt-5")
                                          (:name . "GPT-5"))]))))))
    (with-current-buffer alpha
      (insert "Find the failing test")
      (setq-local comint-last-input-start (copy-marker (point-min))
                  comint-last-input-end (copy-marker (point-max))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar-show-details t)
          (agent-shell-vertico-sidebar-extra-info '(last-user-message)))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (should (equal
                 (split-string (substring-no-properties (buffer-string))
                               "\n" t)
                 '("✓ Review alpha" "↳ Find the failing test")))))))

(ert-deftest agent-shell-vertico-sidebar-extra-info-renders-in-order ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a")
                             (:title . "Review alpha")
                             (:model-id . "gpt-5")
                             (:models . [((:model-id . "gpt-5")
                                          (:name . "GPT-5"))])
                             (:mode-id . "plan")
                             (:modes . [((:id . "plan")
                                         (:name . "Plan"))]))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar-group-by nil)
          (agent-shell-vertico-sidebar-show-details t)
          (agent-shell-vertico-sidebar-extra-info '(mode status model)))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (should (equal
                 (split-string (substring-no-properties (buffer-string))
                               "\n" t)
                 '("✓ Review alpha" "Plan · Ready" "GPT-5")))))))

(ert-deftest agent-shell-vertico-sidebar-extra-info-can-be-empty ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar-show-details t)
          (agent-shell-vertico-sidebar-extra-info nil))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (should (equal
                 (split-string (substring-no-properties (buffer-string))
                               "\n" t)
                 '("✓ Review alpha")))))))

(ert-deftest agent-shell-vertico-sidebar-flat-rows-have-no-project-indent ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha")))))
       (beta "Codex Agent @ beta" "/work/beta/"
             '((:session . ((:id . "b") (:title . "Review beta"))))))
    (let ((agent-shell-test-buffers (list alpha beta))
          (agent-shell-vertico-sidebar-group-by nil)
          (agent-shell-vertico-sidebar-show-details nil))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (agent-shell-vertico-sidebar--render)
        (should-not (memq (char-after (point-min)) '(?\s ?\t)))
        (search-forward "Review beta")
        (beginning-of-line)
        (should-not (memq (char-after) '(?\s ?\t)))))))

(ert-deftest agent-shell-vertico-sidebar-header-reports-session-statistics ()
  (agent-shell-vertico-tests--with-session-buffers
      ((attention "Codex Agent @ attention" "/work/attention/"
                  '((:session . ((:id . "a") (:title . "Attention")))))
       (working "Codex Agent @ working" "/work/working/"
                '((:session . ((:id . "w") (:title . "Working")))))
       (ready "Codex Agent @ ready" "/work/ready/"
              '((:session . ((:id . "r") (:title . "Ready")))))
       (starting "Codex Agent @ starting" "/work/starting/"
                 '((:session . ((:title . "Starting"))))))
    (let ((agent-shell-test-buffers
           (list attention working ready starting))
          (agent-shell-test-statuses
           (list (cons attention 'blocked)
                 (cons working 'busy)
                 (cons ready 'ready)
                 (cons starting 'starting))))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (let ((header (agent-shell-vertico-sidebar--header-line)))
          ;; The total is a mark too, so no count is spelled out in words,
          ;; and a colon reads as "of which" before the statuses.
          (should
           (equal (substring-no-properties header)
                  " ⧉ 4 : ▲ 1 · ◆ 1 · ✓ 1 · ○ 1"))
          (should (<= (string-width header) 34))
          (let ((position (string-match
                           "▲ 1" (substring-no-properties header))))
            (should position)
            ;; Counts are per attention kind now, so each names its own.
            (should (equal (get-text-property position 'help-echo header)
                           "waiting")))
          (should (equal (get-text-property
                          (string-match "⧉" (substring-no-properties header))
                          'help-echo header)
                         "sessions")))))))

(ert-deftest agent-shell-vertico-sidebar-expands-projects-by-default ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar-group-by 'project)
          (agent-shell-vertico-sidebar-expand-by-default t))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (should (string-match-p "Review alpha" (buffer-string)))))))

(ert-deftest agent-shell-vertico-sidebar-toggles-session-details ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar-group-by 'project)
          (agent-shell-vertico-sidebar-show-details nil)
          (agent-shell-vertico-sidebar-extra-info '(status)))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (puthash "/work/alpha/" t agent-shell-vertico-sidebar--expanded-projects)
        (agent-shell-vertico-sidebar--render)
        (should-not (string-match-p "Ready" (buffer-string)))
        (agent-shell-vertico-sidebar-toggle-details)
        (agent-shell-vertico-sidebar--render)
        (should (string-match-p "Ready" (buffer-string)))
        (agent-shell-vertico-sidebar-toggle-details)
        (agent-shell-vertico-sidebar--render)
        (should-not (string-match-p "Ready" (buffer-string)))))))

(ert-deftest agent-shell-vertico-sidebar-tab-toggles-session-details ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar-group-by 'project)
          (agent-shell-vertico-sidebar-show-details nil)
          (agent-shell-vertico-sidebar-extra-info '(status)))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (puthash "/work/alpha/" t agent-shell-vertico-sidebar--expanded-projects)
        (agent-shell-vertico-sidebar--render)
        (search-forward "Review alpha")
        (beginning-of-line)
        (call-interactively
         (lookup-key agent-shell-vertico-sidebar-mode-map (kbd "TAB")))
        (agent-shell-vertico-sidebar--render)
        (should (string-match-p "Ready" (buffer-string)))))))

(ert-deftest agent-shell-vertico-sidebar-tab-toggles-only-current-flat-session ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha")))))
       (beta "Codex Agent @ beta" "/work/beta/"
             '((:session . ((:id . "b") (:title . "Review beta"))))))
    (let ((agent-shell-test-buffers (list alpha beta))
          (agent-shell-vertico-sidebar-group-by nil)
          (agent-shell-vertico-sidebar-show-details nil)
          (agent-shell-vertico-sidebar-extra-info '(status project)))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (agent-shell-vertico-sidebar--render)
        (search-forward "Review alpha")
        (beginning-of-line)
        (call-interactively
         (lookup-key agent-shell-vertico-sidebar-mode-map (kbd "TAB")))
        (should (= (how-many "Ready" (point-min) (point-max)) 1))
        (should (string-match-p "⌂ alpha" (buffer-string)))
        (should-not (string-match-p "Ready.*beta" (buffer-string)))))))

(ert-deftest agent-shell-vertico-sidebar-cycles-project-grouped-levels ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar-group-by 'project)
          (agent-shell-vertico-sidebar-expand-by-default nil)
          (agent-shell-vertico-sidebar-show-details nil)
          (agent-shell-vertico-sidebar-extra-info '(status)))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (should (string-match-p "alpha" (buffer-string)))
        (should-not (string-match-p "Review alpha" (buffer-string)))
        (agent-shell-vertico-sidebar-cycle-global-view)
        (should (string-match-p "Review alpha" (buffer-string)))
        (should-not (string-match-p "Ready" (buffer-string)))
        (agent-shell-vertico-sidebar-cycle-global-view)
        (should (string-match-p "Review alpha" (buffer-string)))
        (should (string-match-p "Ready" (buffer-string)))
        (agent-shell-vertico-sidebar-cycle-global-view)
        (should-not (string-match-p "Review alpha" (buffer-string)))))))

(ert-deftest agent-shell-vertico-sidebar-cycle-overrides-per-node-folds ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha")))))
       (beta "Codex Agent @ beta" "/work/beta/"
             '((:session . ((:id . "b") (:title . "Review beta"))))))
    (let ((agent-shell-test-buffers (list alpha beta))
          (agent-shell-vertico-sidebar-group-by 'project)
          (agent-shell-vertico-sidebar-expand-by-default nil)
          (agent-shell-vertico-sidebar-show-details nil))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (puthash "/work/alpha/" t
                 agent-shell-vertico-sidebar--expanded-projects)
        (puthash alpha t agent-shell-vertico-sidebar--expanded-sessions)
        (agent-shell-vertico-sidebar--render)
        ;; One project is expanded and one session shows details, so the
        ;; sidebar is already at its last level and cycles back to projects.
        (agent-shell-vertico-sidebar-cycle-global-view)
        (should-not (string-match-p "Review alpha" (buffer-string)))
        (should-not (string-match-p "Review beta" (buffer-string)))
        (agent-shell-vertico-sidebar-cycle-global-view)
        (should (string-match-p "Review alpha" (buffer-string)))
        (should (string-match-p "Review beta" (buffer-string)))
        (should-not (string-match-p "Ready" (buffer-string)))))))

(ert-deftest agent-shell-vertico-sidebar-cycles-details-in-flat-view ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar-group-by nil)
          (agent-shell-vertico-sidebar-expand-by-default nil)
          (agent-shell-vertico-sidebar-show-details nil)
          (agent-shell-vertico-sidebar-extra-info '(status)))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (should-not (string-match-p "Ready" (buffer-string)))
        (agent-shell-vertico-sidebar-cycle-global-view)
        (should (string-match-p "Review alpha" (buffer-string)))
        (should (string-match-p "Ready" (buffer-string)))
        (agent-shell-vertico-sidebar-cycle-global-view)
        (should (string-match-p "Review alpha" (buffer-string)))
        (should-not (string-match-p "Ready" (buffer-string)))
        ;; A flat list has no project level, so the default never changes.
        (should-not agent-shell-vertico-sidebar-expand-by-default)))))

(ert-deftest agent-shell-vertico-sidebar-binds-both-tab-events ()
  (should (eq (lookup-key agent-shell-vertico-sidebar-mode-map (kbd "TAB"))
              #'agent-shell-vertico-sidebar-toggle-at-point))
  (should (eq (lookup-key agent-shell-vertico-sidebar-mode-map
                           (kbd "<tab>"))
              #'agent-shell-vertico-sidebar-toggle-at-point)))

(ert-deftest agent-shell-vertico-sidebar-binds-both-shift-tab-events ()
  (should (eq (lookup-key agent-shell-vertico-sidebar-mode-map
                           (kbd "S-TAB"))
              #'agent-shell-vertico-sidebar-cycle-global-view))
  (should (eq (lookup-key agent-shell-vertico-sidebar-mode-map
                           (kbd "<backtab>"))
              #'agent-shell-vertico-sidebar-cycle-global-view))
  (should-not (lookup-key agent-shell-vertico-sidebar-mode-map (kbd "v"))))

(ert-deftest agent-shell-vertico-sidebar-action-prefix-preserves-k-navigation ()
  (should (eq (lookup-key agent-shell-vertico-sidebar-mode-map (kbd "k"))
              #'agent-shell-vertico-sidebar-kill))
  (should (eq (lookup-key agent-shell-vertico-sidebar-mode-map (kbd "C-c k"))
              #'agent-shell-vertico-sidebar-kill))
  (should (eq (lookup-key agent-shell-vertico-sidebar-mode-map (kbd "C-c o"))
              #'agent-shell-vertico-sidebar-open)))

(ert-deftest agent-shell-vertico-sidebar-help-is-discoverable ()
  (should (eq (lookup-key agent-shell-vertico-sidebar-mode-map (kbd "?"))
              #'agent-shell-vertico-sidebar-help))
  (should (eq (cdr (assoc "?"
                          agent-shell-vertico-sidebar--evil-bindings))
              #'agent-shell-vertico-sidebar-help))
  (should (string-match-p "TAB.*toggle"
                          (agent-shell-vertico-sidebar--help-text)))
  (should (string-match-p "RET.*activate"
                          (agent-shell-vertico-sidebar--help-text))))

(ert-deftest agent-shell-vertico-sidebar-help-opens-help-buffer ()
  (let ((buffer-name agent-shell-vertico-sidebar--help-buffer))
    (when-let ((buffer (get-buffer buffer-name)))
      (kill-buffer buffer))
    (unwind-protect
        (progn
          (let ((inhibit-message t))
            (agent-shell-vertico-sidebar-help))
          (should (get-buffer buffer-name))
          (with-current-buffer buffer-name
            (should (derived-mode-p 'help-mode))
            (should (string-match-p "Agent Shell Sidebar" (buffer-string)))))
      (when-let ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest agent-shell-vertico-sidebar-evil-bindings-keep-jk-navigation ()
  (should (eq (cdr (assoc "j"
                          agent-shell-vertico-sidebar--evil-bindings))
              #'evil-next-line))
  (should (eq (cdr (assoc "k"
                          agent-shell-vertico-sidebar--evil-bindings))
              #'evil-previous-line))
  (should (eq (cdr (assoc "RET"
                          agent-shell-vertico-sidebar--evil-bindings))
              #'agent-shell-vertico-sidebar-activate))
  (should (eq (cdr (assoc "<return>"
                          agent-shell-vertico-sidebar--evil-bindings))
              #'agent-shell-vertico-sidebar-activate))
  (should (eq (cdr (assoc "<mouse-1>"
                          agent-shell-vertico-sidebar--evil-bindings))
              #'agent-shell-vertico-sidebar-activate))
  (should (eq (cdr (assoc "D"
                          agent-shell-vertico-sidebar--evil-bindings))
              #'agent-shell-vertico-sidebar-kill))
  (should (eq (cdr (assoc "R"
                          agent-shell-vertico-sidebar--evil-bindings))
              #'agent-shell-vertico-sidebar-restart))
  (should (eq (cdr (assoc "I"
                          agent-shell-vertico-sidebar--evil-bindings))
              #'agent-shell-vertico-sidebar-interrupt))
  (should-not (assoc "r" agent-shell-vertico-sidebar--evil-bindings))
  (should-not (assoc "i" agent-shell-vertico-sidebar--evil-bindings))
  (should (eq (cdr (assoc "gr"
                          agent-shell-vertico-sidebar--evil-bindings))
              #'agent-shell-vertico-sidebar-refresh))
  (should-not (assoc "g" agent-shell-vertico-sidebar--evil-bindings))
  (should (eq (cdr (assoc "t"
                          agent-shell-vertico-sidebar--evil-bindings))
              #'agent-shell-vertico-sidebar-open-transcript))
  (should (eq (cdr (assoc "T"
                          agent-shell-vertico-sidebar--evil-bindings))
              #'agent-shell-vertico-sidebar-view-traffic))
  (should (eq (cdr (assoc "TAB"
                          agent-shell-vertico-sidebar--evil-bindings))
              #'agent-shell-vertico-sidebar-toggle-at-point))
  (should (eq (cdr (assoc "S-TAB"
                          agent-shell-vertico-sidebar--evil-bindings))
              #'agent-shell-vertico-sidebar-cycle-global-view))
  (should (eq (cdr (assoc "<backtab>"
                          agent-shell-vertico-sidebar--evil-bindings))
              #'agent-shell-vertico-sidebar-cycle-global-view))
  (should-not (assoc "v" agent-shell-vertico-sidebar--evil-bindings)))

(ert-deftest agent-shell-vertico-sidebar-evil-bindings-install-gr-prefix ()
  (let (bindings)
    (cl-letf (((symbol-function 'evil-local-set-key)
               (lambda (_state key definition)
                 (push (cons key definition) bindings)))
              ((symbol-function 'evil-get-auxiliary-keymap)
               (lambda (&rest _args) nil)))
      (agent-shell-vertico-sidebar--bind-evil-keys)
      (let ((refresh-prefix (cdr (assoc "g" bindings))))
        (should (keymapp refresh-prefix))
        (should (eq (lookup-key refresh-prefix (kbd "r"))
                    #'agent-shell-vertico-sidebar-refresh)))
      (should (eq (cdr (assoc "gr"
                              agent-shell-vertico-sidebar--evil-bindings))
                  #'agent-shell-vertico-sidebar-refresh)))))

(ert-deftest agent-shell-vertico-sidebar-hides-mode-line ()
  (with-temp-buffer
    (agent-shell-vertico-sidebar-mode)
    (should-not mode-line-format)))

(ert-deftest agent-shell-vertico-sidebar-wraps-titles-with-a-character-cap ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a")
                             (:title . "A title that is deliberately long"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar-group-by nil)
          (agent-shell-vertico-sidebar-show-details nil)
          (agent-shell-vertico-sidebar-title-max-length 18)
          (agent-shell-vertico-sidebar-width 16))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (agent-shell-vertico-sidebar--render)
        (should (> (count-lines (point-min) (point-max)) 1))
        (should (string-match-p "A title" (buffer-string)))
        (should-not (string-match-p "deliberately long" (buffer-string)))))))

(ert-deftest agent-shell-vertico-sidebar-title-ellipsis-does-not-pad ()
  (let* ((agent-shell-vertico-sidebar-title-max-length 40)
         (title "3a36c40 origin/main Add compact agent-shell-vertico long tail")
         (display (agent-shell-vertico-sidebar--title-display-text title))
         (lines (agent-shell-vertico-sidebar--wrap-text display 34))
         (last-line (car (last lines))))
    (should (equal (car lines)
                   "3a36c40 origin/main Add compact"))
    (should (equal last-line "agent-s…"))
    (should-not (string-match-p " +…\\'" last-line))))

(ert-deftest agent-shell-vertico-sidebar-title-normalizes-whitespace ()
  (should (equal
           (agent-shell-vertico-sidebar--title-display-text
            "  first\nsecond\tthird  ")
           "first second third")))

(ert-deftest agent-shell-vertico-sidebar-refreshes-on-window-resize ()
  (should (memq #'agent-shell-vertico-sidebar--window-size-change
               window-size-change-functions)))

(ert-deftest agent-shell-vertico-sidebar-event-burst-keeps-one-idle-refresh ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (callbacks nil)
          (delay nil)
          (timer-calls 0))
      (agent-shell-vertico-tests--with-sidebar
        (cl-letf (((symbol-function
                    'agent-shell-vertico-sidebar--sidebar-visible-p)
                   (lambda (&optional _buffer) t))
                  ((symbol-function 'run-with-idle-timer)
                   (lambda (idle-delay _repeat function &rest _args)
                     (setq delay idle-delay)
                     (cl-incf timer-calls)
                     (push function callbacks)
                     (timer-create))))
          (dotimes (_ 10000)
            (agent-shell-vertico-sidebar--handle-event
             alpha '((:event . chunk))))
          (should (= timer-calls 1))
          (should (= delay 0.5))
          (should (= (length callbacks) 1))
          (should agent-shell-vertico-sidebar--dirty))))))

(ert-deftest agent-shell-vertico-sidebar-toggle-opens-then-closes ()
  "Toggling opens the sidebar window, and toggling again deletes it."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (original (selected-window)))
      (unwind-protect
          (progn
            (agent-shell-vertico-sidebar-toggle)
            (let* ((sidebar (get-buffer "*Agent Shell Sessions*"))
                   (window (get-buffer-window sidebar)))
              (should (window-live-p window))
              (should (eq (selected-window) original))
              (should (string-match-p
                       "Review alpha"
                       (with-current-buffer sidebar (buffer-string))))
              (agent-shell-vertico-sidebar-toggle)
              (should-not (get-buffer-window sidebar))))
        (when (window-live-p original)
          (select-window original))
        (when-let ((sidebar (get-buffer "*Agent Shell Sessions*")))
          (kill-buffer sidebar))))))

(ert-deftest agent-shell-vertico-sidebar-toggle-closes-visible-window ()
  "Toggling an unfocused visible sidebar closes it without selecting it."
  (let ((agent-shell-test-buffers nil)
        (original (selected-window)))
    (unwind-protect
        (progn
          (agent-shell-vertico-sidebar-toggle)
          (let ((window (get-buffer-window "*Agent Shell Sessions*")))
            (should (window-live-p window))
            (select-window original)
            (agent-shell-vertico-sidebar-toggle)
            (should-not (window-live-p window))
            (should (eq (selected-window) original))))
      (when (window-live-p original)
        (select-window original))
      (when-let* ((sidebar (get-buffer "*Agent Shell Sessions*")))
        (kill-buffer sidebar)))))

(ert-deftest agent-shell-vertico-sidebar-focus-opens-and-selects ()
  "Focusing opens the sidebar when it is closed and selects its window."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (original (selected-window)))
      (unwind-protect
          (progn
            (agent-shell-vertico-sidebar-focus)
            (let ((window (get-buffer-window "*Agent Shell Sessions*")))
              (should (window-live-p window))
              (should (eq (selected-window) window))
              ;; Focusing again keeps the same window rather than opening one.
              (agent-shell-vertico-sidebar-focus)
              (should (eq (get-buffer-window "*Agent Shell Sessions*")
                          window))))
        (when (window-live-p original)
          (select-window original))
        (when-let ((sidebar (get-buffer "*Agent Shell Sessions*")))
          (kill-buffer sidebar))))))

(ert-deftest agent-shell-vertico-sidebar-permission-request-marks-blocked ()
  "A permission request marks the session blocked and stops its busy clock."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha)))
      (agent-shell-vertico-tests--with-sidebar
        (puthash alpha (float-time)
                 agent-shell-vertico-sidebar--busy-since-times)
        (agent-shell-vertico-sidebar--handle-event
         alpha '((:event . permission-request)))
        (should (eq (plist-get (gethash alpha
                                        agent-shell-vertico-sidebar--attention)
                               :kind)
                    'blocked))
        (should-not (gethash alpha
                             agent-shell-vertico-sidebar--busy-since-times))))))

(ert-deftest agent-shell-vertico-sidebar-error-event-marks-error ()
  "An error marks the session and stops its busy clock."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha)))
      (agent-shell-vertico-tests--with-sidebar
        (puthash alpha (float-time)
                 agent-shell-vertico-sidebar--busy-since-times)
        (agent-shell-vertico-sidebar--handle-event
         alpha '((:event . error)))
        (should (eq (plist-get (gethash alpha
                                        agent-shell-vertico-sidebar--attention)
                               :kind)
                    'error))
        (should-not (gethash alpha
                             agent-shell-vertico-sidebar--busy-since-times))))))

(ert-deftest agent-shell-vertico-sidebar-permission-response-keeps-blocked-mark ()
  "Answering one request leaves the mark while another is still pending.
The mark follows the live status, not the arrival of the response, so a
session that is blocked again must keep asking for a reply."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-test-statuses (list (cons alpha 'blocked))))
      (agent-shell-vertico-tests--with-sidebar
        (puthash alpha (list :kind 'blocked :time (float-time))
                 agent-shell-vertico-sidebar--attention)
        (agent-shell-vertico-sidebar--handle-event
         alpha '((:event . permission-response)))
        (should (gethash alpha agent-shell-vertico-sidebar--attention))
        (should-not (gethash alpha
                             agent-shell-vertico-sidebar--busy-since-times))))))

(ert-deftest agent-shell-vertico-sidebar-permission-response-restarts-busy-clock ()
  "A granted permission that resumes work clears the mark and times the turn."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-test-statuses (list (cons alpha 'busy))))
      (agent-shell-vertico-tests--with-sidebar
        (puthash alpha (list :kind 'blocked :time (float-time))
                 agent-shell-vertico-sidebar--attention)
        (agent-shell-vertico-sidebar--handle-event
         alpha '((:event . permission-response)))
        (should-not (gethash alpha agent-shell-vertico-sidebar--attention))
        (should (gethash alpha
                         agent-shell-vertico-sidebar--busy-since-times))))))

(ert-deftest agent-shell-vertico-sidebar-idle-event-stops-busy-clock ()
  "An idle event ends the turn without marking the session."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha)))
      (agent-shell-vertico-tests--with-sidebar
        (puthash alpha (float-time)
                 agent-shell-vertico-sidebar--busy-since-times)
        (agent-shell-vertico-sidebar--handle-event alpha '((:event . idle)))
        (should-not (gethash alpha
                             agent-shell-vertico-sidebar--busy-since-times))
        (should-not (gethash alpha
                             agent-shell-vertico-sidebar--attention))))))

(ert-deftest agent-shell-vertico-sidebar-clean-up-event-forgets-the-session ()
  "Cleaning up drops every record the sidebar keeps for the session."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha)))
      (agent-shell-vertico-tests--with-sidebar
        (puthash alpha (float-time)
                 agent-shell-vertico-sidebar--busy-since-times)
        (puthash alpha (list :kind 'done :time (float-time))
                 agent-shell-vertico-sidebar--attention)
        (agent-shell-vertico-sidebar--handle-event alpha '((:event . clean-up)))
        (should-not (gethash alpha agent-shell-vertico-sidebar--attention))
        (should-not (gethash alpha
                             agent-shell-vertico-sidebar--busy-since-times))
        (should-not (gethash alpha
                             agent-shell-vertico-sidebar--activity))))))

(ert-deftest agent-shell-vertico-sidebar-watches-each-session-once ()
  "Every live session is subscribed to exactly once."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a")))))
       (beta "Codex Agent @ beta" "/work/beta/"
             '((:session . ((:id . "b"))))))
    (let ((agent-shell-test-buffers (list alpha beta)))
      (agent-shell-vertico-tests--with-sidebar
        (agent-shell-vertico-sidebar--watch-existing)
        (agent-shell-vertico-sidebar--watch-existing)
        (should (= (length agent-shell-test-subscriptions) 2))
        (should (gethash alpha agent-shell-vertico-sidebar--subscriptions))
        (should (gethash beta agent-shell-vertico-sidebar--subscriptions))))))

(ert-deftest agent-shell-vertico-sidebar-renders-past-a-refused-subscription ()
  "A session that cannot take a subscription does not blank the sidebar.

`agent-shell-subscribe-to' extends the session's own state alist with
`map-put!', which signals `map-not-inplace' when that alist has no
`:event-subscriptions' key.  One such buffer aborted the whole render."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha")))))
       (beta "Codex Agent @ beta" "/work/beta/"
             '((:session . ((:id . "b") (:title . "Review beta"))))))
    (let ((agent-shell-test-buffers (list alpha beta))
          (agent-shell-vertico-sidebar-group-by nil)
          (subscribe (symbol-function 'agent-shell-subscribe-to)))
      (cl-letf (((symbol-function 'agent-shell-subscribe-to)
                 (lambda (&rest args)
                   (if (eq (plist-get args :shell-buffer) alpha)
                       (signal 'map-not-inplace (list '((:buffer . alpha))))
                     (apply subscribe args)))))
        (agent-shell-vertico-tests--with-sidebar
          (agent-shell-vertico-sidebar--render)
          (should (string-match-p "Review alpha" (buffer-string)))
          (should (string-match-p "Review beta" (buffer-string)))
          (should (gethash beta agent-shell-vertico-sidebar--subscriptions))
          (should (= (length agent-shell-test-subscriptions) 1))
          ;; Recorded as handled, so the next render does not retry a
          ;; subscription the session has already refused.
          (should (gethash alpha
                           agent-shell-vertico-sidebar--subscriptions))
          (agent-shell-vertico-sidebar--render)
          (should (= (length agent-shell-test-subscriptions) 1)))))))

(ert-deftest agent-shell-vertico-sidebar-unwatches-a-killed-session ()
  "Killing a session unsubscribes it and forgets its metadata."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a"))))))
    (let ((agent-shell-test-buffers (list alpha)))
      (agent-shell-vertico-tests--with-sidebar
        (agent-shell-vertico-sidebar--watch-existing)
        (puthash alpha (list :kind 'done :time (float-time))
                 agent-shell-vertico-sidebar--attention)
        (should (= (length agent-shell-test-subscriptions) 1))
        (kill-buffer alpha)
        (should-not agent-shell-test-subscriptions)
        (should (zerop (hash-table-count
                        agent-shell-vertico-sidebar--subscriptions)))
        (should (zerop (hash-table-count
                        agent-shell-vertico-sidebar--attention)))))))

(ert-deftest agent-shell-vertico-sidebar-prunes-dead-subscriptions ()
  "A session killed without running its hook is pruned on the next pass."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a"))))))
    (let ((agent-shell-test-buffers (list alpha)))
      (agent-shell-vertico-tests--with-sidebar
        (let ((orphan (generate-new-buffer " *agent-shell-vertico-orphan*")))
          (puthash orphan 'stale agent-shell-vertico-sidebar--subscriptions)
          (puthash orphan (float-time) agent-shell-vertico-sidebar--activity)
          (kill-buffer orphan)
          (agent-shell-vertico-sidebar--watch-existing)
          (should-not (gethash orphan
                               agent-shell-vertico-sidebar--subscriptions))
          (should-not (gethash orphan
                               agent-shell-vertico-sidebar--activity)))))))

(ert-deftest agent-shell-vertico-sidebar-next-row-moves-past-detail-lines ()
  "Next-row moves to the following row's first line, not the current details."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha")))))
       (beta "Codex Agent @ beta" "/work/beta/"
             '((:session . ((:id . "b") (:title . "Review beta"))))))
    (let ((agent-shell-test-buffers (list alpha beta))
          (agent-shell-vertico-sidebar-group-by nil)
          (agent-shell-vertico-sidebar-show-details t)
          (agent-shell-vertico-sidebar-extra-info '(status))
          (agent-shell-vertico-sidebar-sort-by 'name))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (goto-char (point-min))
        (should (eq (agent-shell-vertico-sidebar--node-at-point) alpha))
        ;; From alpha's detail line, the next stop is still beta's own row.
        (forward-line 1)
        (should (eq (agent-shell-vertico-sidebar--node-at-point) alpha))
        (agent-shell-vertico-sidebar-next-row)
        (should (eq (agent-shell-vertico-sidebar--node-at-point) beta))
        (should (string-match-p "Review beta"
                                (buffer-substring-no-properties
                                 (line-beginning-position)
                                 (line-end-position))))
        ;; Point stays on the last session rather than falling off the list.
        (let ((position (point)))
          (should-error (agent-shell-vertico-sidebar-next-row)
                        :type 'user-error)
          (should (= (point) position)))))))

(ert-deftest agent-shell-vertico-sidebar-previous-row-leaves-current-row ()
  "Previous-row moves to the row before the one point sits in."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha")))))
       (beta "Codex Agent @ beta" "/work/beta/"
             '((:session . ((:id . "b") (:title . "Review beta"))))))
    (let ((agent-shell-test-buffers (list alpha beta))
          (agent-shell-vertico-sidebar-group-by nil)
          (agent-shell-vertico-sidebar-show-details t)
          (agent-shell-vertico-sidebar-extra-info '(status))
          (agent-shell-vertico-sidebar-sort-by 'name))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (should (agent-shell-vertico-sidebar--goto-node (cons 'session beta)))
        (forward-line 1)
        (agent-shell-vertico-sidebar-previous-row)
        (should (eq (agent-shell-vertico-sidebar--node-at-point) alpha))
        (should (string-match-p "Review alpha"
                                (buffer-substring-no-properties
                                 (line-beginning-position)
                                 (line-end-position))))
        (let ((position (point)))
          (should-error (agent-shell-vertico-sidebar-previous-row)
                        :type 'user-error)
          (should (= (point) position)))))))

(ert-deftest agent-shell-vertico-sidebar-row-motion-stops-on-project-headers ()
  "Row motion stops on each project header as well as each session.
Moving down onto a header's session and back up to that header must be
reversible, and only the ends of the list refuse to move."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha")))))
       (beta "Codex Agent @ beta" "/work/beta/"
             '((:session . ((:id . "b") (:title . "Review beta"))))))
    (let ((agent-shell-test-buffers (list alpha beta))
          (agent-shell-vertico-sidebar-group-by 'project)
          (agent-shell-vertico-sidebar-expand-by-default t)
          (agent-shell-vertico-sidebar-show-details nil)
          (agent-shell-vertico-sidebar-sort-by 'name))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (goto-char (point-min))
        (should (eq (agent-shell-vertico-sidebar--node-kind-at-point)
                    'project))
        ;; The first row is the top of the list, so nothing sits above it.
        (let ((position (point)))
          (should-error (agent-shell-vertico-sidebar-previous-row)
                        :type 'user-error)
          (should (= (point) position)))
        (agent-shell-vertico-sidebar-next-row)
        (should (eq (agent-shell-vertico-sidebar--node-at-point) alpha))
        ;; Back up onto alpha's own project header.
        (agent-shell-vertico-sidebar-previous-row)
        (should (eq (agent-shell-vertico-sidebar--node-kind-at-point)
                    'project))
        (agent-shell-vertico-sidebar-next-row)
        (agent-shell-vertico-sidebar-next-row)
        (should (eq (agent-shell-vertico-sidebar--node-kind-at-point)
                    'project))
        (agent-shell-vertico-sidebar-next-row)
        (should (eq (agent-shell-vertico-sidebar--node-at-point) beta))
        (agent-shell-vertico-sidebar-previous-row)
        (should (eq (agent-shell-vertico-sidebar--node-kind-at-point)
                    'project))))))

(ert-deftest agent-shell-vertico-sidebar-binds-row-motion-keys ()
  "Both key styles move between rows with `C-j' and `C-k'.
Refresh keeps bare `g' in the regular map, so the motion keys stay clear of
the `g' prefix Evil states use for `gr'."
  (should (eq (lookup-key agent-shell-vertico-sidebar-mode-map (kbd "C-j"))
              #'agent-shell-vertico-sidebar-next-row))
  (should (eq (lookup-key agent-shell-vertico-sidebar-mode-map (kbd "C-k"))
              #'agent-shell-vertico-sidebar-previous-row))
  (should (eq (lookup-key agent-shell-vertico-sidebar-mode-map (kbd "g"))
              #'agent-shell-vertico-sidebar-refresh))
  (should (eq (cdr (assoc "C-j" agent-shell-vertico-sidebar--evil-bindings))
              #'agent-shell-vertico-sidebar-next-row))
  (should (eq (cdr (assoc "C-k" agent-shell-vertico-sidebar--evil-bindings))
              #'agent-shell-vertico-sidebar-previous-row)))

(ert-deftest agent-shell-vertico-sidebar-render-keeps-point-on-a-row ()
  "Point stays on a session row when the row it was on disappears.
Searching for the remembered row walks to the end of the buffer, and
point left there reports no session at point for the next key pressed."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha")))))
       (beta "Codex Agent @ beta" "/work/beta/"
             '((:session . ((:id . "b") (:title . "Review beta"))))))
    (let ((agent-shell-test-buffers (list alpha beta))
          (agent-shell-vertico-sidebar-group-by nil)
          (agent-shell-vertico-sidebar-show-details nil))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (goto-char (point-min))
        (should (agent-shell-vertico-sidebar--goto-node (cons 'session beta)))
        ;; Beta goes away, as when its session is killed from the sidebar.
        (setq agent-shell-test-buffers (list alpha))
        (agent-shell-vertico-sidebar--render)
        (should (agent-shell-vertico-sidebar--node-at-point))
        (should (eq (agent-shell-vertico-sidebar--node-at-point) alpha))))))

(ert-deftest agent-shell-vertico-sidebar-render-ends-on-a-session-row ()
  "The rendered list ends without a blank line, and point there holds.
Every row is inserted with a closing newline, so the buffer would otherwise
end on a line carrying no session: point left there reports no session at
point, and a refresh would send it to the top of the list."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha")))))
       (beta "Codex Agent @ beta" "/work/beta/"
             '((:session . ((:id . "b") (:title . "Review beta"))))))
    (let ((agent-shell-test-buffers (list alpha beta))
          (agent-shell-vertico-sidebar-group-by nil)
          (agent-shell-vertico-sidebar-show-details t)
          (agent-shell-vertico-sidebar-extra-info '(status model mode))
          (agent-shell-vertico-sidebar-sort-by 'name))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (agent-shell-vertico-sidebar--render)
        (goto-char (point-max))
        (should-not (eq (char-before) ?\n))
        (should (eq (agent-shell-vertico-sidebar--node-at-point) beta))
        (let ((line (line-number-at-pos)))
          (agent-shell-vertico-sidebar--render)
          (should (eq (agent-shell-vertico-sidebar--node-at-point) beta))
          (should (= (line-number-at-pos) line)))))))

(ert-deftest agent-shell-vertico-sidebar-title-is-hoverable-to-its-last-character ()
  "The whole session title carries the hover highlight and its tooltip."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar-group-by nil)
          (agent-shell-vertico-sidebar-show-details nil))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (goto-char (point-min))
        (let ((last (1- (line-end-position))))
          (should (eq (get-text-property last 'mouse-face) 'highlight))
          (should (equal (get-text-property last 'help-echo)
                         (buffer-name alpha))))))))

(ert-deftest agent-shell-vertico-sidebar-cycle-global-view-spares-other-buffers ()
  "Cycling the fold level from M-x must not render into the current buffer.
Rendering erases the buffer it runs in, so the command has to reach the
sidebar buffer rather than whatever buffer the user called it from."
  (let ((other (generate-new-buffer " *agent-shell-vertico-other*")))
    (when-let ((stale (get-buffer "*Agent Shell Sessions*")))
      (kill-buffer stale))
    (unwind-protect
        (with-current-buffer other
          (insert "user content")
          (should-error (agent-shell-vertico-sidebar-cycle-global-view)
                        :type 'user-error)
          (should (equal (buffer-string) "user content")))
      (kill-buffer other))))

(ert-deftest agent-shell-vertico-sidebar-cycle-rejects-name-collision ()
  "A foreign buffer with the sidebar name must never be erased."
  (let ((other (generate-new-buffer " *agent-shell-vertico-other*"))
        (collision (get-buffer-create "*Agent Shell Sessions*")))
    (unwind-protect
        (progn
          (with-current-buffer collision
            (fundamental-mode)
            (insert "draft content"))
          (with-current-buffer other
            (should-error (agent-shell-vertico-sidebar-cycle-global-view)
                          :type 'user-error)
            (should-error (agent-shell-vertico-sidebar-toggle)
                          :type 'user-error))
          (with-current-buffer collision
            (should (derived-mode-p 'fundamental-mode))
            (should (equal (buffer-string) "draft content"))))
      (kill-buffer other)
      (kill-buffer collision))))

(ert-deftest agent-shell-vertico-sidebar-cycle-global-view-renders-the-sidebar ()
  "Cycling from another buffer folds and renders the sidebar itself."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (other (generate-new-buffer " *agent-shell-vertico-other*")))
      (unwind-protect
          (agent-shell-vertico-tests--with-sidebar
            (let ((agent-shell-vertico-sidebar-group-by nil)
                  (agent-shell-vertico-sidebar-show-details nil))
              (with-current-buffer other
                (insert "user content")
                (agent-shell-vertico-sidebar-cycle-global-view)
                (should (equal (buffer-string) "user content")))
              (should agent-shell-vertico-sidebar-show-details)
              (should (string-match-p
                       "Review alpha"
                       (with-current-buffer "*Agent Shell Sessions*"
                         (buffer-string))))))
        (kill-buffer other)))))

(ert-deftest agent-shell-vertico-sidebar-cycle-preserves-window-point ()
  "Cycling elsewhere keeps the visible sidebar window on the same session."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha")))))
       (beta "Codex Agent @ beta" "/work/beta/"
             '((:session . ((:id . "b") (:title . "Review beta"))))))
    (let ((agent-shell-test-buffers (list alpha beta))
          (agent-shell-vertico-sidebar-group-by nil)
          (agent-shell-vertico-sidebar-show-details nil)
          (other (generate-new-buffer " *agent-shell-vertico-other*")))
      (unwind-protect
          (save-window-excursion
            (delete-other-windows)
            (switch-to-buffer other)
            (let ((other-window (selected-window))
                  (sidebar-window (split-window-right)))
              (agent-shell-vertico-tests--with-sidebar
                (agent-shell-vertico-sidebar--render)
                (should
                 (agent-shell-vertico-sidebar--goto-node
                  (cons 'session beta)))
                (set-window-buffer sidebar-window (current-buffer))
                (set-window-point sidebar-window (point))
                (select-window other-window)
                (agent-shell-vertico-sidebar-cycle-global-view)
                (with-selected-window sidebar-window
                  (should (eq (agent-shell-vertico-sidebar--node-at-point)
                              beta))))))
        (kill-buffer other)))))

(ert-deftest agent-shell-vertico-sidebar-refresh-preserves-relative-screen-row ()
  "A session remains at the same visual row when another sorts above it."
  (agent-shell-vertico-tests--with-session-buffers
      ((aardvark "Codex Agent @ aardvark" "/work/aardvark/"
                 '((:session . ((:id . "aa") (:title . "Aardvark")))))
       (alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha")))))
       (beta "Codex Agent @ beta" "/work/beta/"
             '((:session . ((:id . "b") (:title . "Beta")))))
       (gamma "Codex Agent @ gamma" "/work/gamma/"
              '((:session . ((:id . "g") (:title . "Gamma"))))))
    (let ((agent-shell-test-buffers (list alpha beta gamma))
          (agent-shell-vertico-sidebar-group-by nil)
          (agent-shell-vertico-sidebar-show-details nil)
          (agent-shell-vertico-sidebar-sort-by 'name)
          (other (generate-new-buffer " *agent-shell-vertico-other*")))
      (unwind-protect
          (save-window-excursion
            (delete-other-windows)
            (switch-to-buffer other)
            (let ((sidebar-window (split-window-below -4)))
              (agent-shell-vertico-tests--with-sidebar
                (agent-shell-vertico-sidebar--render)
                (set-window-buffer sidebar-window (current-buffer))
                (should
                 (agent-shell-vertico-sidebar--goto-node
                  (cons 'session beta)))
                (set-window-start sidebar-window (point-min) t)
                (set-window-point sidebar-window (point))
                (let ((screen-row
                       (count-screen-lines
                        (window-start sidebar-window)
                        (window-point sidebar-window)
                        nil sidebar-window)))
                  (setq agent-shell-test-buffers
                        (list aardvark alpha beta gamma))
                  (agent-shell-vertico-sidebar--render)
                  (should
                   (eq (with-selected-window sidebar-window
                         (agent-shell-vertico-sidebar--node-at-point))
                       beta))
                  (should
                   (= (count-screen-lines
                       (window-start sidebar-window)
                       (window-point sidebar-window)
                       nil sidebar-window)
                      screen-row))))))
        (kill-buffer other)))))

(ert-deftest agent-shell-vertico-sidebar-refresh-anchors-mid-line-window-point ()
  "A window point in the middle of a line keeps its visual row on refresh.
The window is shorter than the list, so its scrolled start is a state the
fill clamp must leave alone."
  (agent-shell-vertico-tests--with-session-buffers
      ((aardvark "Codex Agent @ aardvark" "/work/aardvark/"
                 '((:session . ((:id . "aa") (:title . "Aardvark")))))
       (alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha")))))
       (beta "Codex Agent @ beta" "/work/beta/"
             '((:session . ((:id . "b") (:title . "Beta")))))
       (gamma "Codex Agent @ gamma" "/work/gamma/"
              '((:session . ((:id . "g") (:title . "Gamma"))))))
    (let ((agent-shell-test-buffers (list aardvark alpha beta gamma))
          (agent-shell-vertico-sidebar-group-by nil)
          (agent-shell-vertico-sidebar-show-details nil)
          (agent-shell-vertico-sidebar-sort-by 'name)
          (other (generate-new-buffer " *agent-shell-vertico-other*")))
      (unwind-protect
          (save-window-excursion
            (delete-other-windows)
            (switch-to-buffer other)
            (let ((sidebar-window (split-window-below -4)))
              (agent-shell-vertico-tests--with-sidebar
                (agent-shell-vertico-sidebar--render)
                (set-window-buffer sidebar-window (current-buffer))
                ;; Scroll aardvark above the window start so a one-line
                ;; drift has room to move the start upward.
                (should
                 (agent-shell-vertico-sidebar--goto-node
                  (cons 'session alpha)))
                (set-window-start sidebar-window (point) t)
                (should
                 (agent-shell-vertico-sidebar--goto-node
                  (cons 'session gamma)))
                (let ((screen-row
                       (count-screen-lines
                        (window-start sidebar-window) (point)
                        nil sidebar-window)))
                  (set-window-point sidebar-window (+ (point) 3))
                  (agent-shell-vertico-sidebar--render)
                  (should
                   (eq (with-selected-window sidebar-window
                         (agent-shell-vertico-sidebar--node-at-point))
                       gamma))
                  (should
                   (= (count-screen-lines
                       (window-start sidebar-window)
                       (window-point sidebar-window)
                       nil sidebar-window)
                      screen-row))))))
        (kill-buffer other)))))

(ert-deftest agent-shell-vertico-sidebar-refresh-fills-window-when-content-shrinks ()
  "Collapsing details scrolls the window back so the sessions fill it.
Keeping the old scrolled start would hide the top sessions behind blank
rows once the collapsed list fits the window."
  (agent-shell-vertico-tests--with-session-buffers
      ((aardvark "Codex Agent @ aardvark" "/work/aardvark/"
                 '((:session . ((:id . "aa") (:title . "Aardvark")))))
       (alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha")))))
       (beta "Codex Agent @ beta" "/work/beta/"
             '((:session . ((:id . "b") (:title . "Beta")))))
       (gamma "Codex Agent @ gamma" "/work/gamma/"
              '((:session . ((:id . "g") (:title . "Gamma"))))))
    (let ((agent-shell-test-buffers (list aardvark alpha beta gamma))
          (agent-shell-vertico-sidebar-group-by nil)
          (agent-shell-vertico-sidebar-show-details t)
          (agent-shell-vertico-sidebar-extra-info '(status project model mode))
          (agent-shell-vertico-sidebar-sort-by 'name)
          (other (generate-new-buffer " *agent-shell-vertico-other*")))
      (unwind-protect
          (save-window-excursion
            (delete-other-windows)
            (switch-to-buffer other)
            (let ((sidebar-window (split-window-below -10)))
              (agent-shell-vertico-tests--with-sidebar
                (agent-shell-vertico-sidebar--render)
                (set-window-buffer sidebar-window (current-buffer))
                (should
                 (agent-shell-vertico-sidebar--goto-node
                  (cons 'session beta)))
                (set-window-start sidebar-window (point) t)
                (should
                 (agent-shell-vertico-sidebar--goto-node
                  (cons 'session gamma)))
                (set-window-point sidebar-window (point))
                (agent-shell-vertico-sidebar-cycle-global-view)
                (should
                 (eq (with-selected-window sidebar-window
                       (agent-shell-vertico-sidebar--node-at-point))
                     gamma))
                (should (= (window-start sidebar-window) (point-min))))))
        (kill-buffer other)))))

(ert-deftest agent-shell-vertico-sidebar-refresh-fills-window-when-window-grows ()
  "A window enlarged past the list length scrolls back to the top.
Keeping the old scrolled start would leave the added rows blank while the
top sessions stay hidden."
  (agent-shell-vertico-tests--with-session-buffers
      ((aardvark "Codex Agent @ aardvark" "/work/aardvark/"
                 '((:session . ((:id . "aa") (:title . "Aardvark")))))
       (alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha")))))
       (beta "Codex Agent @ beta" "/work/beta/"
             '((:session . ((:id . "b") (:title . "Beta")))))
       (gamma "Codex Agent @ gamma" "/work/gamma/"
              '((:session . ((:id . "g") (:title . "Gamma"))))))
    (let ((agent-shell-test-buffers (list aardvark alpha beta gamma))
          (agent-shell-vertico-sidebar-group-by nil)
          (agent-shell-vertico-sidebar-show-details nil)
          (agent-shell-vertico-sidebar-sort-by 'name)
          (other (generate-new-buffer " *agent-shell-vertico-other*")))
      (unwind-protect
          (save-window-excursion
            (delete-other-windows)
            (switch-to-buffer other)
            (let ((sidebar-window (split-window-below -5)))
              (agent-shell-vertico-tests--with-sidebar
                (agent-shell-vertico-sidebar--render)
                (set-window-buffer sidebar-window (current-buffer))
                (should
                 (agent-shell-vertico-sidebar--goto-node
                  (cons 'session beta)))
                (set-window-start sidebar-window (point) t)
                (should
                 (agent-shell-vertico-sidebar--goto-node
                  (cons 'session gamma)))
                (set-window-point sidebar-window (point))
                (window-resize sidebar-window 8)
                (agent-shell-vertico-sidebar--render)
                (should
                 (eq (with-selected-window sidebar-window
                       (agent-shell-vertico-sidebar--node-at-point))
                     gamma))
                (should (= (window-start sidebar-window) (point-min))))))
        (kill-buffer other)))))

(ert-deftest agent-shell-vertico-sidebar-toggle-details-preserves-subline ()
  "Toggling details leaves point on a surviving line within the session."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha")))))
       (beta "Codex Agent @ beta" "/work/beta/"
             '((:session . ((:id . "b") (:title . "Beta")))))
       (gamma "Codex Agent @ gamma" "/work/gamma/"
              '((:session . ((:id . "g") (:title . "Gamma"))))))
    (let ((agent-shell-test-buffers (list alpha beta gamma))
          (agent-shell-vertico-sidebar-group-by nil)
          (agent-shell-vertico-sidebar-show-details nil)
          (agent-shell-vertico-sidebar-extra-info '(status project))
          (other (generate-new-buffer " *agent-shell-vertico-other*")))
      (unwind-protect
          (save-window-excursion
            (delete-other-windows)
            (switch-to-buffer other)
            (let ((sidebar-window (split-window-right)))
              (agent-shell-vertico-tests--with-sidebar
                (agent-shell-vertico-sidebar--render)
                (set-window-buffer sidebar-window (current-buffer))
                (select-window sidebar-window)
                (search-forward "⌂ beta")
                (beginning-of-line)
                (should (eq (agent-shell-vertico-sidebar--node-at-point) beta))
                (should (eq (agent-shell-vertico-sidebar--field-at-point)
                            'project))
                (set-window-start sidebar-window (point-min) t)
                (let ((screen-row
                       (count-screen-lines
                        (window-start sidebar-window) (point)
                        nil sidebar-window)))
                  (agent-shell-vertico-sidebar-toggle-at-point)
                  (should (eq (agent-shell-vertico-sidebar--node-at-point)
                              beta))
                  (should (eq (agent-shell-vertico-sidebar--field-at-point)
                              'project))
                  (should
                   (= (count-screen-lines
                       (window-start sidebar-window) (point)
                       nil sidebar-window)
                      screen-row))
                  (agent-shell-vertico-sidebar-toggle-at-point)
                  (should (eq (agent-shell-vertico-sidebar--node-at-point)
                              beta))
                  (should (eq (agent-shell-vertico-sidebar--field-at-point)
                              'project))
                  (should
                   (= (count-screen-lines
                       (window-start sidebar-window) (point)
                       nil sidebar-window)
                      screen-row))))))
        (kill-buffer other)))))

(ert-deftest agent-shell-vertico-sidebar-toggle-details-falls-back-to-title ()
  "Collapsing a removed detail line leaves point on its session title."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar-group-by nil)
          (agent-shell-vertico-sidebar-show-details t)
          (agent-shell-vertico-sidebar-extra-info '(status)))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (agent-shell-vertico-sidebar--render)
        (search-forward "Ready")
        (beginning-of-line)
        (agent-shell-vertico-sidebar-toggle-at-point)
        (should (eq (agent-shell-vertico-sidebar--node-at-point) alpha))
        (should (looking-at-p ".*Alpha"))))))

(ert-deftest agent-shell-vertico-sidebar-refresh-falls-back-to-row-index ()
  "Removing the selected session keeps selection at its former list index."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha")))))
       (beta "Codex Agent @ beta" "/work/beta/"
             '((:session . ((:id . "b") (:title . "Beta")))))
       (gamma "Codex Agent @ gamma" "/work/gamma/"
              '((:session . ((:id . "g") (:title . "Gamma"))))))
    (let ((agent-shell-test-buffers (list alpha beta gamma))
          (agent-shell-vertico-sidebar-group-by nil)
          (agent-shell-vertico-sidebar-show-details nil)
          (agent-shell-vertico-sidebar-sort-by 'name)
          (other (generate-new-buffer " *agent-shell-vertico-other*")))
      (unwind-protect
          (save-window-excursion
            (delete-other-windows)
            (switch-to-buffer other)
            (let ((sidebar-window (split-window-right)))
              (agent-shell-vertico-tests--with-sidebar
                (agent-shell-vertico-sidebar--render)
                (set-window-buffer sidebar-window (current-buffer))
                (should
                 (agent-shell-vertico-sidebar--goto-node
                  (cons 'session beta)))
                (set-window-point sidebar-window (point))
                (setq agent-shell-test-buffers (list alpha gamma))
                (agent-shell-vertico-sidebar--render)
                (should
                 (eq (with-selected-window sidebar-window
                       (agent-shell-vertico-sidebar--node-at-point))
                     gamma)))))
        (kill-buffer other)))))

(ert-deftest agent-shell-vertico-sidebar-hidden-events-do-not-schedule-refresh ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (timer-calls 0))
      (agent-shell-vertico-tests--with-sidebar
        (cl-letf (((symbol-function
                    'agent-shell-vertico-sidebar--sidebar-visible-p)
                   (lambda (&optional _buffer) nil))
                  ((symbol-function 'run-with-idle-timer)
                   (lambda (&rest _args)
                     (cl-incf timer-calls)
                     (timer-create))))
          (agent-shell-vertico-sidebar--handle-event
           alpha '((:event . chunk)))
          (should (= timer-calls 0))
          (should agent-shell-vertico-sidebar--dirty)
          (should-not (timerp agent-shell-vertico-sidebar--refresh-timer)))))))

(ert-deftest agent-shell-vertico-sidebar-dirty-state-renders-on-reopen ()
  "An event arriving while the sidebar is hidden renders once it is shown.
Nothing renders while there is no window, so the pending update has to
survive as the dirty flag until the next scheduled refresh runs."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (visible nil)
          (callbacks nil))
      (agent-shell-vertico-tests--with-sidebar
        (cl-letf (((symbol-function
                    'agent-shell-vertico-sidebar--sidebar-visible-p)
                   (lambda (&optional _buffer) visible))
                  ((symbol-function 'run-with-idle-timer)
                   (lambda (_delay _repeat function &rest _args)
                     (push function callbacks)
                     (timer-create))))
          (let ((inhibit-read-only t))
            (erase-buffer))
          (agent-shell-vertico-sidebar--handle-event
           alpha '((:event . chunk)))
          ;; Hidden: the update is recorded but nothing is scheduled.
          (should agent-shell-vertico-sidebar--dirty)
          (should-not callbacks)
          (should (string-empty-p (buffer-string)))
          ;; The window comes back and the next event schedules the refresh.
          (setq visible t)
          (agent-shell-vertico-sidebar--schedule-refresh)
          (should (= (length callbacks) 1))
          (funcall (car callbacks))
          (should-not agent-shell-vertico-sidebar--dirty)
          (should (string-match-p "Review alpha" (buffer-string))))))))

(ert-deftest agent-shell-vertico-sidebar-workspace-switch-reopens-sidebar ()
  "A visible sidebar is reopened in the workspace being switched to."
  (let ((agent-shell-vertico-sidebar-follow-workspaces t)
        (agent-shell-vertico-sidebar--visible-before-workspace-switch nil)
        (display-calls 0))
    (cl-letf (((symbol-function
                'agent-shell-vertico-sidebar--selected-frame-window)
               (lambda () t)))
      (agent-shell-vertico-sidebar--save-workspace-visibility 'frame))
    (should agent-shell-vertico-sidebar--visible-before-workspace-switch)
    (cl-letf (((symbol-function
                'agent-shell-vertico-sidebar--selected-frame-window)
               (lambda () nil))
              ((symbol-function
                'agent-shell-vertico-sidebar--display-buffer)
               (lambda () (cl-incf display-calls) nil)))
      (agent-shell-vertico-sidebar--restore-workspace-visibility 'frame))
    (should (= display-calls 1))))

(ert-deftest agent-shell-vertico-sidebar-workspace-switch-keeps-sidebar-closed ()
  "A sidebar closed before the switch is not reopened after it."
  (let ((agent-shell-vertico-sidebar-follow-workspaces t)
        (agent-shell-vertico-sidebar--visible-before-workspace-switch t)
        (display-calls 0))
    (cl-letf (((symbol-function
                'agent-shell-vertico-sidebar--selected-frame-window)
               (lambda () nil))
              ((symbol-function
                'agent-shell-vertico-sidebar--display-buffer)
               (lambda () (cl-incf display-calls) nil)))
      (agent-shell-vertico-sidebar--save-workspace-visibility 'frame)
      (should-not agent-shell-vertico-sidebar--visible-before-workspace-switch)
      (agent-shell-vertico-sidebar--restore-workspace-visibility 'frame))
    (should (= display-calls 0))))

(ert-deftest agent-shell-vertico-sidebar-workspace-switch-closes-sidebar ()
  "A sidebar brought back by the workspace's own layout is closed again.
persp-mode restores each workspace's saved window layout, so a workspace
last left with the sidebar open restores that window.  A sidebar hidden
before the switch stays hidden after it."
  (let ((agent-shell-vertico-sidebar-follow-workspaces t)
        (agent-shell-vertico-sidebar--visible-before-workspace-switch nil)
        (agent-shell-test-buffers nil))
    (agent-shell-vertico-tests--with-sidebar
      (save-window-excursion
        (let ((window (agent-shell-vertico-sidebar--display-buffer)))
          (should (window-live-p window))
          (agent-shell-vertico-sidebar--restore-workspace-visibility 'frame)
          (should-not (window-live-p window))
          (should-not (get-buffer-window sidebar)))))))

(ert-deftest agent-shell-vertico-sidebar-workspace-switch-close-can-be-disabled ()
  "Nil `agent-shell-vertico-sidebar-follow-workspaces' closes nothing."
  (let ((agent-shell-vertico-sidebar-follow-workspaces nil)
        (agent-shell-vertico-sidebar--visible-before-workspace-switch nil)
        (agent-shell-test-buffers nil))
    (agent-shell-vertico-tests--with-sidebar
      (save-window-excursion
        (let ((window (agent-shell-vertico-sidebar--display-buffer)))
          (agent-shell-vertico-sidebar--restore-workspace-visibility 'frame)
          (should (window-live-p window)))))))

(ert-deftest agent-shell-vertico-sidebar-workspace-switch-can-be-disabled ()
  "Nil `agent-shell-vertico-sidebar-follow-workspaces' reopens nothing."
  (let ((agent-shell-vertico-sidebar-follow-workspaces nil)
        (agent-shell-vertico-sidebar--visible-before-workspace-switch t)
        (display-calls 0))
    (cl-letf (((symbol-function
                'agent-shell-vertico-sidebar--selected-frame-window)
               (lambda () nil))
              ((symbol-function
                'agent-shell-vertico-sidebar--display-buffer)
               (lambda () (cl-incf display-calls) nil)))
      (agent-shell-vertico-sidebar--restore-workspace-visibility 'frame))
    (should (= display-calls 0))))

(ert-deftest agent-shell-vertico-sidebar-workspace-switch-keeps-visible-sidebar ()
  "A sidebar restored by the workspace's own layout is left alone."
  (let ((agent-shell-vertico-sidebar-follow-workspaces t)
        (agent-shell-vertico-sidebar--visible-before-workspace-switch t)
        (display-calls 0))
    (cl-letf (((symbol-function
                'agent-shell-vertico-sidebar--selected-frame-window)
               (lambda () t))
              ((symbol-function
                'agent-shell-vertico-sidebar--display-buffer)
               (lambda () (cl-incf display-calls) nil)))
      (agent-shell-vertico-sidebar--restore-workspace-visibility 'frame))
    (should (= display-calls 0))))

(ert-deftest agent-shell-vertico-sidebar-workspace-switch-ignores-window-scope ()
  "Per-window workspace activation does not save or restore visibility.
Only frame activation restores a window configuration, so only frame
activation can lose the sidebar's side window."
  (let ((agent-shell-vertico-sidebar-follow-workspaces t)
        (agent-shell-vertico-sidebar--visible-before-workspace-switch t)
        (display-calls 0))
    (cl-letf (((symbol-function
                'agent-shell-vertico-sidebar--selected-frame-window)
               (lambda () nil))
              ((symbol-function
                'agent-shell-vertico-sidebar--display-buffer)
               (lambda () (cl-incf display-calls) nil)))
      (agent-shell-vertico-sidebar--save-workspace-visibility 'window)
      (should agent-shell-vertico-sidebar--visible-before-workspace-switch)
      (agent-shell-vertico-sidebar--restore-workspace-visibility 'window))
    (should (= display-calls 0))))

(ert-deftest agent-shell-vertico-sidebar-loading-does-not-prebind-persp-hooks ()
  "Loading the package must not bind persp-mode's own hook variables.
A top-level `add-hook' would pre-bind them, clobbering the values
persp-mode's `defcustom' forms install when persp-mode loads later."
  (skip-unless (not (featurep 'persp-mode)))
  (should-not (boundp 'persp-activated-functions))
  (should-not (boundp 'persp-before-deactivate-functions)))

(ert-deftest agent-shell-vertico-sidebar-installs-workspace-hooks ()
  "Loading persp-mode installs the save and restore hooks."
  (let ((persp-before-deactivate-functions nil)
        (persp-activated-functions nil))
    (agent-shell-vertico-sidebar--install-workspace-hooks)
    (should (memq #'agent-shell-vertico-sidebar--save-workspace-visibility
                  persp-before-deactivate-functions))
    (should (memq #'agent-shell-vertico-sidebar--restore-workspace-visibility
                  persp-activated-functions))))

(ert-deftest agent-shell-vertico-sidebar-configuration-change-uses-real-hook ()
  "The configuration-change handler must sit on Emacs's own hook.
`add-hook' binds whatever variable name it is given, so a name Emacs does
not run leaves the handler installed on nothing and its timer cleanup
never happens."
  (should (memq #'agent-shell-vertico-sidebar--window-configuration-change
                window-configuration-change-hook))
  (should-not (boundp 'window-configuration-change-functions)))

(ert-deftest agent-shell-vertico-sidebar-side-window-survives-maximize ()
  "The sidebar's no-delete parameter survives a window state round-trip.
persp-mode saves and restores workspace layouts with `window-state-get'
and `window-state-put', which only carry parameters marked writable in
`window-persistent-parameters'."
  (should (eq (alist-get 'no-delete-other-windows
                         window-persistent-parameters)
              'writable)))

(ert-deftest agent-shell-vertico-sidebar-render-uses-one-live-snapshot ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha")))))
       (beta "Claude Agent @ beta" "/work/beta/"
             '((:session . ((:id . "b") (:title . "Review beta"))))))
    (let ((agent-shell-test-buffers (list alpha beta))
          (agent-shell-test-statuses (list (cons alpha 'ready)
                                           (cons beta 'busy)))
          (agent-shell-vertico-sidebar-group-by nil)
          (agent-shell-vertico-sidebar-show-details nil))
      (agent-shell-vertico-tests--with-sidebar
        (should (= agent-shell-test-buffer-query-count 1))
        (should (= agent-shell-test-status-query-count 2))
        (should (stringp header-line-format))
        (let ((agent-shell-test-buffer-query-count 0)
              (agent-shell-test-status-query-count 0))
          (format-mode-line header-line-format)
          (should (= agent-shell-test-buffer-query-count 0))
          (should (= agent-shell-test-status-query-count 0)))))))

(ert-deftest agent-shell-vertico-sidebar-empty-render-queries-sessions-once ()
  (let ((agent-shell-test-buffers nil)
        (agent-shell-test-buffer-query-count 0)
        (agent-shell-test-status-query-count 0))
    (agent-shell-vertico-tests--with-sidebar
      (should (= agent-shell-test-buffer-query-count 1))
      (should (= agent-shell-test-status-query-count 0)))))

(ert-deftest agent-shell-vertico-sidebar-age-refresh-repeats-every-minute ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (timer-args nil)
          (agent-shell-vertico-sidebar-extra-info '(activity))
          (agent-shell-vertico-sidebar-show-details t))
      (agent-shell-vertico-tests--with-sidebar
        (cl-letf (((symbol-function
                    'agent-shell-vertico-sidebar--sidebar-visible-p)
                   (lambda (&optional _buffer) t))
                  ((symbol-function 'run-with-timer)
                   (lambda (delay repeat function &rest args)
                     (setq timer-args (list delay repeat function args))
                     (timer-create))))
          (agent-shell-vertico-sidebar--ensure-age-refresh)
          (should (= (car timer-args) 60))
          (should (= (cadr timer-args) 60)))))))

(ert-deftest agent-shell-vertico-sidebar-age-refresh-skips-hidden-details ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (timer-calls 0)
          (agent-shell-vertico-sidebar-extra-info nil)
          (agent-shell-vertico-sidebar-show-details t))
      (agent-shell-vertico-tests--with-sidebar
        (cl-letf (((symbol-function
                    'agent-shell-vertico-sidebar--sidebar-visible-p)
                   (lambda (&optional _buffer) t))
                  ((symbol-function 'run-with-timer)
                   (lambda (&rest _args)
                     (cl-incf timer-calls)
                     (timer-create))))
          (agent-shell-vertico-sidebar--ensure-age-refresh)
          (should (= timer-calls 0)))))))

(ert-deftest agent-shell-vertico-sidebar-resize-events-coalesce ()
  (let ((callbacks nil)
        (timer-calls 0)
        (render-calls 0))
    (agent-shell-vertico-tests--with-sidebar
      (setq-local agent-shell-vertico-sidebar--last-rendered-width 20)
      (cl-letf (((symbol-function 'get-buffer-window)
                 (lambda (&rest _args) (selected-window)))
                ((symbol-function 'window-body-width)
                 (lambda (&rest _args) 30))
                ((symbol-function 'run-with-idle-timer)
                 (lambda (_delay _repeat function &rest _args)
                   (cl-incf timer-calls)
                   (push function callbacks)
                   (timer-create)))
                ((symbol-function 'agent-shell-vertico-sidebar--render)
                 (lambda () (cl-incf render-calls))))
        (dotimes (_ 10)
          (agent-shell-vertico-sidebar--window-size-change))
        (should (= timer-calls 1))
        (funcall (car callbacks))
        (should (= render-calls 1))
        (should (= agent-shell-vertico-sidebar--last-rendered-width 30))
        (agent-shell-vertico-sidebar--window-size-change)
        (should (= timer-calls 1))))))

(ert-deftest agent-shell-vertico-sidebar-display-caps-width-to-frame-share ()
  "Opening the sidebar on a narrow frame takes at most its column share.
The batch frame is 80 columns, so the default 40 exceeds the cap."
  (let ((agent-shell-vertico-sidebar-max-width-fraction 0.3)
        (agent-shell-test-buffers nil))
    (agent-shell-vertico-tests--with-sidebar
      (save-window-excursion
        (let ((window (agent-shell-vertico-sidebar--display-buffer)))
          (should (<= (window-total-width window)
                      (floor (* 0.3 (frame-width))))))))))

(ert-deftest agent-shell-vertico-sidebar-frame-shrink-caps-window-width ()
  "A sidebar wider than its frame's share is shrunk by the resize timer.
The sidebar opens uncapped, then the cap takes effect, standing in for a
frame that narrowed under an already-open sidebar."
  (let ((agent-shell-vertico-sidebar-max-width-fraction nil)
        (agent-shell-test-buffers nil)
        (callbacks nil))
    (agent-shell-vertico-tests--with-sidebar
      (save-window-excursion
        (let ((window (agent-shell-vertico-sidebar--display-buffer)))
          (should (>= (window-total-width window) 40))
          (let ((agent-shell-vertico-sidebar-max-width-fraction 0.3))
            (cl-letf (((symbol-function 'run-with-idle-timer)
                       (lambda (_delay _repeat function &rest _args)
                         (push function callbacks)
                         (timer-create))))
              (agent-shell-vertico-sidebar--window-size-change))
            (should (= (length callbacks) 1))
            (funcall (car callbacks))
            (should (<= (window-total-width window)
                        (floor (* 0.3 (frame-width)))))))))))

(ert-deftest agent-shell-vertico-sidebar-resize-restores-the-target-width ()
  "A sidebar left narrower than its target width is widened back.
Restoring a workspace recreates the window from a saved proportion and
drops its preserved size, so the width has to be re-applied in both
directions rather than only shrunk."
  (let ((agent-shell-vertico-sidebar-max-width-fraction 0.3)
        (agent-shell-test-buffers nil)
        (callbacks nil))
    (agent-shell-vertico-tests--with-sidebar
      (save-window-excursion
        (let* ((window (agent-shell-vertico-sidebar--display-buffer))
               (target (agent-shell-vertico-sidebar--clamp-width
                        agent-shell-vertico-sidebar-width (frame-width))))
          (should (= (window-total-width window) target))
          (window-preserve-size window t nil)
          (window-resize window (- 16 (window-total-width window)) t)
          (should (< (window-total-width window) target))
          (cl-letf (((symbol-function 'run-with-idle-timer)
                     (lambda (_delay _repeat function &rest _args)
                       (push function callbacks)
                       (timer-create))))
            (agent-shell-vertico-sidebar--window-size-change))
          (dolist (callback callbacks)
            (funcall callback))
          (should (= (window-total-width window) target)))))))

(ert-deftest agent-shell-vertico-sidebar-width-drift-ignores-normal-windows ()
  "A normal window showing the sidebar buffer is never resized.
Only genuine side windows carry the configured width."
  (let ((agent-shell-vertico-sidebar-max-width-fraction 0.3)
        (agent-shell-test-buffers nil))
    (agent-shell-vertico-tests--with-sidebar
      (save-window-excursion
        (delete-other-windows)
        (let ((window (split-window-right)))
          (set-window-buffer window (agent-shell-vertico-sidebar--sidebar-buffer))
          (let ((width (window-total-width window)))
            (should-not (agent-shell-vertico-sidebar--width-drifted-p window))
            (agent-shell-vertico-sidebar--enforce-window-width window)
            (should (= (window-total-width window) width))))))))

(ert-deftest agent-shell-vertico-sidebar-relative-time-calls-recent-now ()
  (should (equal (agent-shell-vertico-sidebar--relative-time
                  (float-time))
                 "now")))

(ert-deftest agent-shell-vertico-sidebar-relative-time-buckets-under-a-minute ()
  (should (equal (agent-shell-vertico-sidebar--relative-time
                  (- (float-time) 30))
                 "now")))

(ert-deftest agent-shell-vertico-sidebar-folds-project-headers ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar-group-by 'project))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (puthash "/work/alpha/" t agent-shell-vertico-sidebar--expanded-projects)
        (agent-shell-vertico-sidebar--render)
        (goto-char (point-min))
        (agent-shell-vertico-sidebar-toggle-project)
        (should-not (string-match-p "Review alpha" (buffer-string)))
        (agent-shell-vertico-sidebar-toggle-project)
        (should (string-match-p "Review alpha" (buffer-string)))))))

(ert-deftest agent-shell-vertico-sidebar-event-marks-hidden-completion ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (agent-shell-vertico-sidebar--handle-event
     alpha '((:event . turn-complete)))
    (should (eq (plist-get (gethash alpha
                                   agent-shell-vertico-sidebar--attention)
                           :kind)
                'done))))

(defmacro agent-shell-vertico-tests--with-frame-focus (focused &rest body)
  "Run BODY on a graphical frame whose input focus is FOCUSED.

Batch frames are terminal frames and report no focus at all, so both the
frame kind and its focus state are stated here rather than inherited."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
             ((symbol-function 'frame-focus-state)
              (lambda (&optional _) ,focused)))
     ,@body))

(ert-deftest agent-shell-vertico-sidebar-visible-viewport-counts-as-seen ()
  "A turn finishing in the selected window leaves no unread mark.

Users who interact through viewports never have the shell buffer itself
on screen, so asking whether that buffer is visible marked every finished
turn unread."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((viewport (generate-new-buffer " *viewport*")))
      (unwind-protect
          (let ((agent-shell-test-buffers (list alpha))
                (agent-shell-test-viewport-buffer viewport)
                (agent-shell-vertico-sidebar--attention
                 (make-hash-table :test #'eq)))
            (agent-shell-vertico-tests--with-frame-focus t
              (save-window-excursion
                (set-window-buffer (selected-window) viewport)
                (agent-shell-vertico-sidebar--handle-event
                 alpha '((:event . turn-complete)))
                (should-not
                 (gethash alpha
                          agent-shell-vertico-sidebar--attention)))))
        (kill-buffer viewport)))))

(ert-deftest agent-shell-vertico-sidebar-selected-session-counts-as-seen ()
  "A turn finishing in the session the reader has selected leaves no mark."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar--attention
           (make-hash-table :test #'eq)))
      (agent-shell-vertico-tests--with-frame-focus t
        (save-window-excursion
          (set-window-buffer (selected-window) alpha)
          (agent-shell-vertico-sidebar--handle-event
           alpha '((:event . turn-complete)))
          (should-not (gethash alpha
                               agent-shell-vertico-sidebar--attention)))))))

(ert-deftest agent-shell-vertico-sidebar-unselected-window-keeps-unread ()
  "A turn finishing in a window the reader has not selected stays unread.

The session is on screen, but the reader is working in another window, so
nobody has read the output yet."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar--attention
           (make-hash-table :test #'eq)))
      (agent-shell-vertico-tests--with-frame-focus t
        (save-window-excursion
          (set-window-buffer (split-window) alpha)
          (should-not (eq (window-buffer (selected-window)) alpha))
          (agent-shell-vertico-sidebar--handle-event
           alpha '((:event . turn-complete)))
          (should (eq (plist-get
                       (gethash alpha
                                agent-shell-vertico-sidebar--attention)
                       :kind)
                      'done)))))))

(ert-deftest agent-shell-vertico-sidebar-unfocused-frame-keeps-unread ()
  "A turn finishing while Emacs has no input focus stays unread.

The session sits in the selected window, but the reader is in another
application and has not seen the output."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar--attention
           (make-hash-table :test #'eq)))
      (agent-shell-vertico-tests--with-frame-focus nil
        (save-window-excursion
          (set-window-buffer (selected-window) alpha)
          (agent-shell-vertico-sidebar--handle-event
           alpha '((:event . turn-complete)))
          (should (eq (plist-get
                       (gethash alpha
                                agent-shell-vertico-sidebar--attention)
                       :kind)
                      'done)))))))

(ert-deftest agent-shell-vertico-sidebar-unfocused-viewport-keeps-unread ()
  "A turn finishing in a selected viewport with no input focus stays unread."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((viewport (generate-new-buffer " *viewport*")))
      (unwind-protect
          (let ((agent-shell-test-buffers (list alpha))
                (agent-shell-test-viewport-buffer viewport)
                (agent-shell-vertico-sidebar--attention
                 (make-hash-table :test #'eq)))
            (agent-shell-vertico-tests--with-frame-focus nil
              (save-window-excursion
                (set-window-buffer (selected-window) viewport)
                (agent-shell-vertico-sidebar--handle-event
                 alpha '((:event . turn-complete)))
                (should (eq (plist-get
                             (gethash alpha
                                      agent-shell-vertico-sidebar--attention)
                             :kind)
                            'done)))))
        (kill-buffer viewport)))))

(ert-deftest agent-shell-vertico-sidebar-terminal-frame-counts-as-focused ()
  "A terminal frame reports no focus, so window selection alone decides.

`frame-focus-state' answers nil on a terminal frame whether or not the
reader is looking at it, so treating that nil as \"away\" would mark every
finished turn unread for terminal users."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar--attention
           (make-hash-table :test #'eq)))
      (cl-letf (((symbol-function 'display-graphic-p)
                 (lambda (&optional _) nil))
                ((symbol-function 'frame-focus-state)
                 (lambda (&optional _) nil)))
        (save-window-excursion
          (set-window-buffer (selected-window) alpha)
          (agent-shell-vertico-sidebar--handle-event
           alpha '((:event . turn-complete)))
          (should-not (gethash alpha
                               agent-shell-vertico-sidebar--attention)))))))

(ert-deftest agent-shell-vertico-sidebar-selecting-viewport-marks-seen ()
  "Selecting a session's viewport clears its unread mark."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((viewport (generate-new-buffer " *viewport*")))
      (unwind-protect
          (let ((agent-shell-test-buffers (list alpha))
                (agent-shell-test-viewport-buffer viewport)
                (agent-shell-vertico-sidebar--attention
                 (make-hash-table :test #'eq)))
            (puthash alpha (list :kind 'done :time 10.0)
                     agent-shell-vertico-sidebar--attention)
            (with-current-buffer viewport
              (agent-shell-vertico-sidebar--window-selection-change))
            (should-not (gethash alpha
                                 agent-shell-vertico-sidebar--attention)))
        (kill-buffer viewport)))))

(ert-deftest agent-shell-vertico-sidebar-selection-change-reads-its-frame ()
  "The selected window of the frame Emacs names decides what was seen.

`window-selection-change-functions' passes the frame whose selected
window changed.  Reading the current buffer instead cleared the mark of
whichever session happened to be current, which is the wrong session as
soon as a second frame is involved."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar--attention
           (make-hash-table :test #'eq)))
      (puthash alpha (list :kind 'done :time 10.0)
               agent-shell-vertico-sidebar--attention)
      (save-window-excursion
        (set-window-buffer (selected-window) alpha)
        (with-temp-buffer
          (should-not (eq (current-buffer) alpha))
          (agent-shell-vertico-sidebar--window-selection-change
           (selected-frame)))
        (should-not (gethash alpha
                            agent-shell-vertico-sidebar--attention))))))

(ert-deftest agent-shell-vertico-sidebar-selecting-session-becomes-current ()
  "Selecting a session's window records it as the current session."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar--current-session nil))
      (save-window-excursion
        (set-window-buffer (selected-window) alpha)
        (agent-shell-vertico-sidebar--window-selection-change
         (selected-frame))
        (should (eq agent-shell-vertico-sidebar--current-session alpha))))))

(ert-deftest agent-shell-vertico-sidebar-current-session-survives-other-buffer ()
  "Selecting an unrelated buffer leaves the last current session in place.

The reader is still \"in\" the session they left, whether they moved to
the sidebar itself or to a file they are editing."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar--current-session alpha))
      (with-temp-buffer
        (let ((other (current-buffer)))
          (save-window-excursion
            (set-window-buffer (selected-window) other)
            (agent-shell-vertico-sidebar--window-selection-change
             (selected-frame))
            (should (eq agent-shell-vertico-sidebar--current-session
                       alpha))))))))

(ert-deftest agent-shell-vertico-sidebar-current-session-clears-on-kill ()
  "Unwatching the current session's buffer clears the tracked session."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-vertico-sidebar--current-session alpha))
      (with-current-buffer alpha
        (agent-shell-vertico-sidebar--unwatch-buffer))
      (should-not agent-shell-vertico-sidebar--current-session))))

(ert-deftest agent-shell-vertico-sidebar-render-marks-current-session-row ()
  "The current session's row carries the fringe marker; others do not."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha")))))
       (beta "Codex Agent @ beta" "/work/beta/"
             '((:session . ((:id . "b") (:title . "Review beta"))))))
    (let ((agent-shell-test-buffers (list alpha beta))
          (agent-shell-vertico-sidebar-group-by nil)
          (agent-shell-vertico-sidebar--current-session alpha))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (agent-shell-vertico-sidebar--render)
        (goto-char (point-min))
        (search-forward "Review alpha")
        (should (equal (get-text-property
                        0 'display
                        (get-text-property (line-beginning-position)
                                           'line-prefix))
                       '(left-fringe
                         agent-shell-vertico-sidebar-current-session-fringe
                         agent-shell-vertico-sidebar-current-session)))
        (goto-char (point-min))
        (search-forward "Review beta")
        (should-not (get-text-property (line-beginning-position)
                                       'line-prefix))))))

(ert-deftest
    agent-shell-vertico-sidebar-render-marks-current-session-in-project-group
    ()
  "The fringe marker applies inside an expanded project group too."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar-group-by 'project)
          (agent-shell-vertico-sidebar--current-session alpha))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (puthash "/work/alpha/" t agent-shell-vertico-sidebar--expanded-projects)
        (agent-shell-vertico-sidebar--render)
        (goto-char (point-min))
        (search-forward "Review alpha")
        (should (get-text-property (line-beginning-position)
                                   'line-prefix))))))

(ert-deftest agent-shell-vertico-sidebar-focus-change-ignores-terminal-frame ()
  "A GUI focus callback must not read a session selected in a terminal frame.

The terminal frame can report no focus while the package treats it as
focused for completion-time checks.  That exception must not make an
unrelated GUI focus change clear its unread mark."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((viewport (generate-new-buffer " *viewport*"))
          (other (generate-new-buffer " *other*"))
          (gui-frame (make-symbol "gui-frame"))
          (terminal-frame (make-symbol "terminal-frame"))
          (gui-window (make-symbol "gui-window"))
          (terminal-window (make-symbol "terminal-window"))
          (attention (make-hash-table :test #'eq)))
      (unwind-protect
          (let ((agent-shell-test-buffers (list alpha))
                (agent-shell-test-viewport-buffer viewport)
                (agent-shell-vertico-sidebar--attention attention))
            (puthash alpha (list :kind 'done :time 10.0) attention)
            (cl-letf (((symbol-function 'frame-list)
                       (lambda () (list gui-frame terminal-frame)))
                      ((symbol-function 'frame-live-p)
                       (lambda (frame)
                         (memq frame (list gui-frame terminal-frame))))
                      ((symbol-function 'display-graphic-p)
                       (lambda (frame) (eq frame gui-frame)))
                      ((symbol-function 'frame-focus-state)
                       (lambda (frame) (eq frame gui-frame)))
                      ((symbol-function 'window-live-p)
                       (lambda (window)
                         (memq window (list gui-window terminal-window))))
                      ((symbol-function 'frame-selected-window)
                       (lambda (frame)
                         (if (eq frame gui-frame)
                             gui-window
                           terminal-window)))
                      ((symbol-function 'window-buffer)
                       (lambda (window)
                         (if (eq window gui-window)
                             other
                           viewport))))
              (agent-shell-vertico-sidebar--focus-change)
              (should (eq (plist-get (gethash alpha attention) :kind)
                          'done))))
        (kill-buffer viewport)
        (kill-buffer other)))))

(ert-deftest agent-shell-vertico-sidebar-regained-focus-marks-seen ()
  "Returning to Emacs marks the session in the selected window seen.

A turn that finished while Emacs had no focus is unread, and coming back
to the frame is the moment it is read.  No window is selected then, so
`window-selection-change-functions' never runs for it."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar--attention
           (make-hash-table :test #'eq)))
      (puthash alpha (list :kind 'done :time 10.0)
               agent-shell-vertico-sidebar--attention)
      (agent-shell-vertico-tests--with-frame-focus t
        (save-window-excursion
          (set-window-buffer (selected-window) alpha)
          (agent-shell-vertico-sidebar--focus-change)
          (should-not (gethash alpha
                              agent-shell-vertico-sidebar--attention)))))))

(ert-deftest agent-shell-vertico-sidebar-regained-focus-marks-viewport-seen ()
  "Returning to a frame showing a viewport marks its session seen."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((viewport (generate-new-buffer " *viewport*")))
      (unwind-protect
          (let ((agent-shell-test-buffers (list alpha))
                (agent-shell-test-viewport-buffer viewport)
                (agent-shell-vertico-sidebar--attention
                 (make-hash-table :test #'eq)))
            (puthash alpha (list :kind 'done :time 10.0)
                     agent-shell-vertico-sidebar--attention)
            (agent-shell-vertico-tests--with-frame-focus t
              (save-window-excursion
                (set-window-buffer (selected-window) viewport)
                (agent-shell-vertico-sidebar--focus-change)
                (should-not
                 (gethash alpha
                          agent-shell-vertico-sidebar--attention)))))
        (kill-buffer viewport)))))

(ert-deftest agent-shell-vertico-sidebar-lost-focus-keeps-unread ()
  "Leaving Emacs does not mark the session in the selected window seen.

`after-focus-change-function' runs for focus loss too, and the reader is
now in another application."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar--attention
           (make-hash-table :test #'eq)))
      (puthash alpha (list :kind 'done :time 10.0)
               agent-shell-vertico-sidebar--attention)
      (agent-shell-vertico-tests--with-frame-focus nil
        (save-window-excursion
          (set-window-buffer (selected-window) alpha)
          (agent-shell-vertico-sidebar--focus-change)
          (should (eq (plist-get
                       (gethash alpha
                                agent-shell-vertico-sidebar--attention)
                       :kind)
                     'done)))))))

(ert-deftest agent-shell-vertico-sidebar-new-turn-clears-attention ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    ;; Submitting a new prompt means the user has seen whatever the previous
    ;; turn produced, whether that was a completion or an error.
    (dolist (kind '(done error blocked))
      (let ((agent-shell-vertico-sidebar--attention
             (make-hash-table :test #'eq)))
        (puthash alpha (list :kind kind :time 10.0)
                 agent-shell-vertico-sidebar--attention)
        (agent-shell-vertico-sidebar--handle-event
         alpha '((:event . input-submitted)))
        (should-not (gethash alpha
                             agent-shell-vertico-sidebar--attention))))))

(ert-deftest agent-shell-vertico-sidebar-error-icon-differs-from-attention ()
  (agent-shell-vertico-tests--with-session-buffers
      ((failed "Codex Agent @ failed" "/work/failed/"
               '((:session . ((:id . "f") (:title . "Failed")))))
       (blocked "Claude Agent @ blocked" "/work/blocked/"
                '((:session . ((:id . "b") (:title . "Blocked"))))))
    (let ((agent-shell-vertico-sidebar--attention
           (make-hash-table :test #'eq)))
      (puthash failed (list :kind 'error :time 10.0)
               agent-shell-vertico-sidebar--attention)
      (puthash blocked (list :kind 'blocked :time 10.0)
               agent-shell-vertico-sidebar--attention)
      (should (equal (agent-shell-vertico-sidebar--icon failed) "✖"))
      (should (equal (agent-shell-vertico-sidebar--icon blocked) "▲"))
      ;; An errored session still sorts into the attention tier.
      (should (= (agent-shell-vertico-sidebar--status-rank failed) 0)))))

(ert-deftest agent-shell-vertico-sidebar-renders-error-icon ()
  (agent-shell-vertico-tests--with-session-buffers
      ((failed "Codex Agent @ failed" "/work/failed/"
               '((:session . ((:id . "f") (:title . "Failed run"))))))
    (let ((agent-shell-test-buffers (list failed))
          (agent-shell-vertico-sidebar--attention
           (make-hash-table :test #'eq)))
      (puthash failed (list :kind 'error :time 10.0)
               agent-shell-vertico-sidebar--attention)
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (agent-shell-vertico-sidebar--render)
        (should (string-match-p "✖ Failed run" (buffer-string)))))))

(ert-deftest agent-shell-vertico-sidebar-done-icon-differs-from-blocked ()
  (agent-shell-vertico-tests--with-session-buffers
      ((finished "Codex Agent @ finished" "/work/finished/"
                 '((:session . ((:id . "f") (:title . "Finished")))))
       (waiting "Claude Agent @ waiting" "/work/waiting/"
                '((:session . ((:id . "w") (:title . "Waiting"))))))
    (let ((agent-shell-vertico-sidebar--attention
           (make-hash-table :test #'eq)))
      (puthash finished (list :kind 'done :time 10.0)
               agent-shell-vertico-sidebar--attention)
      (puthash waiting (list :kind 'blocked :time 10.0)
               agent-shell-vertico-sidebar--attention)
      (should (equal (agent-shell-vertico-sidebar--icon finished) "●"))
      (should (equal (agent-shell-vertico-sidebar--icon waiting) "▲")))))

(ert-deftest agent-shell-vertico-sidebar-icons-fall-back-to-text ()
  (let ((agent-shell-vertico-sidebar-use-nerd-icons nil))
    (should-not (agent-shell-vertico-sidebar--nerd-icons-p))
    (dolist (slot '((error . "✖") (blocked . "▲") (done . "●")
                    (working . "◆") (ready . "✓") (starting . "○")
                    (project . "⌂") (message . "↳") (sessions . "⧉")
                    (expanded . "▼") (collapsed . "▶")))
      (should (equal (agent-shell-vertico-sidebar--slot-icon (car slot))
                     (cdr slot))))))

(ert-deftest agent-shell-vertico-sidebar-uses-nerd-icons-when-enabled ()
  (cl-letf (((symbol-function 'nerd-icons-codicon)
             (lambda (name &rest _) (format "<cod:%s>" name)))
            ((symbol-function 'nerd-icons-mdicon)
             (lambda (name &rest _) (format "<md:%s>" name))))
    (let ((agent-shell-vertico-sidebar-use-nerd-icons t))
      (should (agent-shell-vertico-sidebar--nerd-icons-p))
      (should (equal (agent-shell-vertico-sidebar--slot-icon 'error)
                     "<cod:nf-cod-error>"))
      (should (equal (agent-shell-vertico-sidebar--slot-icon 'blocked)
                     "<cod:nf-cod-stop_circle>"))
      (should (equal (agent-shell-vertico-sidebar--slot-icon 'done)
                     "<cod:nf-cod-circle_large_filled>"))
      (should (equal (agent-shell-vertico-sidebar--slot-icon 'ready)
                     "<cod:nf-cod-circle_large>"))
      (should (equal (agent-shell-vertico-sidebar--slot-icon 'starting)
                     "<cod:nf-cod-dash>"))
      (should (equal (agent-shell-vertico-sidebar--slot-icon 'project)
                     "<cod:nf-cod-root_folder>"))
      (should (equal (agent-shell-vertico-sidebar--slot-icon 'message)
                     "<cod:nf-cod-arrow_small_right>"))
      (should (equal (agent-shell-vertico-sidebar--slot-icon 'sessions)
                     "<cod:nf-cod-layers>"))
      ;; The working icon is the one slot drawn from the Material set.
      (should (equal (agent-shell-vertico-sidebar--slot-icon 'working)
                     "<md:nf-md-dots_circle>"))
      ;; Folds keep their text characters whatever the icon setting.
      (should (equal (agent-shell-vertico-sidebar--slot-icon 'expanded) "▼"))
      (should (equal (agent-shell-vertico-sidebar--slot-icon 'collapsed)
                     "▶")))))

(ert-deftest agent-shell-vertico-sidebar-indents-with-line-prefix ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar-show-details t)
          (agent-shell-vertico-sidebar-extra-info '(project)))
      ;; Flat rows own column zero; their detail lines are indented for
      ;; display only, so copied text carries no leading spaces.
      (let ((agent-shell-vertico-sidebar-group-by nil))
        (with-temp-buffer
          (agent-shell-vertico-sidebar-mode)
          (goto-char (point-min))
          (should-not (get-text-property (point) 'line-prefix))
          (forward-line 1)
          (should (equal (get-text-property (point) 'line-prefix) "  "))
          (should (string-prefix-p "⌂" (buffer-substring-no-properties
                                        (point) (line-end-position))))))
      ;; Sessions under a project header reserve the fold columns.
      (let ((agent-shell-vertico-sidebar-group-by 'project)
            (agent-shell-vertico-sidebar-expand-by-default t))
        (with-temp-buffer
          (agent-shell-vertico-sidebar-mode)
          (goto-char (point-min))
          (should (string-prefix-p "▼ " (buffer-substring-no-properties
                                         (point) (line-end-position))))
          (should-not (get-text-property (point) 'line-prefix))
          (forward-line 1)
          (should (equal (get-text-property (point) 'line-prefix) "  "))
          (forward-line 1)
          (should (equal (get-text-property (point) 'line-prefix) "    ")))))))

(ert-deftest agent-shell-vertico-sidebar-icon-gap-widens-for-nerd-icons ()
  (cl-letf (((symbol-function 'nerd-icons-codicon)
             (lambda (name &rest _) (format "<cod:%s>" name)))
            ((symbol-function 'nerd-icons-mdicon)
             (lambda (name &rest _) (format "<md:%s>" name))))
    ;; Text characters sit comfortably one space from the title.
    (let ((agent-shell-vertico-sidebar-use-nerd-icons nil))
      (should (equal (agent-shell-vertico-sidebar--icon-gap) " ")))
    (let ((agent-shell-vertico-sidebar-use-nerd-icons t))
      ;; A terminal can only widen the gap by whole columns.
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
        (should (equal (agent-shell-vertico-sidebar--icon-gap) "  ")))
      ;; A graphical frame gets a fraction of a column instead.
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
        (let ((gap (agent-shell-vertico-sidebar--icon-gap)))
          (should (equal (substring-no-properties gap) "  "))
          (should (equal (get-text-property 1 'display gap)
                         '(space :width 0.5))))))))

(ert-deftest agent-shell-vertico-sidebar-content-width-accounts-for-gap ()
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
    ;; Text mode: one column for the character, one for its space.
    (let ((agent-shell-vertico-sidebar-use-nerd-icons nil))
      (should (= (agent-shell-vertico-sidebar--content-width 40 nil) 38))
      (should (= (agent-shell-vertico-sidebar--content-width 40 t) 36)))
    ;; Icons in a terminal spend one more column on the wider gap.
    (cl-letf (((symbol-function 'nerd-icons-codicon)
               (lambda (name &rest _) (format "<cod:%s>" name))))
      (let ((agent-shell-vertico-sidebar-use-nerd-icons t))
        (should (= (agent-shell-vertico-sidebar--content-width 40 nil) 37))
        (should (= (agent-shell-vertico-sidebar--content-width 40 t) 35))))))

(ert-deftest agent-shell-vertico-sidebar-header-counts-attention-kinds ()
  (agent-shell-vertico-tests--with-session-buffers
      ((failed "Codex Agent @ failed" "/work/failed/"
               '((:session . ((:id . "f") (:title . "Failed")))))
       (waiting "Claude Agent @ waiting" "/work/waiting/"
                '((:session . ((:id . "w") (:title . "Waiting")))))
       (finished "Codex Agent @ finished" "/work/finished/"
                 '((:session . ((:id . "d") (:title . "Finished"))))))
    (let ((agent-shell-test-buffers (list failed waiting finished))
          (agent-shell-test-statuses (list (cons failed 'ready)
                                           (cons waiting 'ready)
                                           (cons finished 'ready)))
          (agent-shell-vertico-sidebar--attention
           (make-hash-table :test #'eq))
          (agent-shell-vertico-sidebar-use-nerd-icons nil))
      (puthash failed (list :kind 'error :time 10.0)
               agent-shell-vertico-sidebar--attention)
      (puthash waiting (list :kind 'blocked :time 10.0)
               agent-shell-vertico-sidebar--attention)
      (puthash finished (list :kind 'done :time 10.0)
               agent-shell-vertico-sidebar--attention)
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        ;; Every count uses the icon its own rows use.
        (should (equal (substring-no-properties
                        (agent-shell-vertico-sidebar--header-line))
                       " ⧉ 3 : ✖ 1 · ▲ 1 · ● 1"))
        (agent-shell-vertico-sidebar--render)
        (should (equal (substring-no-properties header-line-format)
                       " ⧉ 3 : ✖ 1 · ▲ 1 · ● 1"))))))

(ert-deftest agent-shell-vertico-sidebar-header-counts-keep-icon-gap ()
  "A drawn glyph fills its cell, so its count needs the wider gap."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-test-statuses (list (cons alpha 'ready)))
          (agent-shell-vertico-sidebar-use-nerd-icons t))
      (cl-letf (((symbol-function 'nerd-icons-codicon)
                 (lambda (name &rest _) (format "<cod:%s>" name)))
                ((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
        (with-temp-buffer
          (agent-shell-vertico-sidebar-mode)
          (should (equal (substring-no-properties
                          (agent-shell-vertico-sidebar--header-line))
                         (concat " <cod:nf-cod-layers>  1"
                                 " : <cod:nf-cod-circle_large>  1"))))))))

(ert-deftest agent-shell-vertico-sidebar-project-header-marks-attention ()
  "A project header counts the sessions needing attention, and nothing else."
  (agent-shell-vertico-tests--with-session-buffers
      ((waiting "Codex Agent @ alpha" "/work/alpha/"
                '((:session . ((:id . "w") (:title . "Waiting")))))
       (ready "Claude Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "r") (:title . "Ready"))))))
    (let ((agent-shell-test-buffers (list waiting ready))
          (agent-shell-test-statuses (list (cons waiting 'ready)
                                           (cons ready 'ready)))
          (agent-shell-vertico-sidebar--attention
           (make-hash-table :test #'eq))
          (agent-shell-vertico-sidebar-use-nerd-icons nil)
          (agent-shell-vertico-sidebar-group-by 'project))
      (puthash waiting (list :kind 'blocked :time 10.0)
               agent-shell-vertico-sidebar--attention)
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (agent-shell-vertico-sidebar--render)
        (goto-char (point-min))
        (let ((line (buffer-substring-no-properties
                     (point) (line-end-position))))
          (should (string-prefix-p "▶ alpha " line))
          ;; The count holds the right edge of the row.
          (should (string-suffix-p "▲ 1" line))
          ;; The session total is the whole sidebar's header, not a
          ;; project's; a project states only what is waiting on the reader.
          (should-not (string-match-p "⧉" line))
          (should (= (string-width line)
                     agent-shell-vertico-sidebar-width)))))))

(ert-deftest agent-shell-vertico-sidebar-project-header-omits-quiet-counts ()
  "A project with nothing to report is only its fold mark and name."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha")))))
       (beta "Claude Agent @ alpha" "/work/alpha/"
             '((:session . ((:id . "b") (:title . "Review beta"))))))
    (let ((agent-shell-test-buffers (list alpha beta))
          (agent-shell-test-statuses (list (cons alpha 'ready)
                                           (cons beta 'busy)))
          (agent-shell-vertico-sidebar--attention
           (make-hash-table :test #'eq))
          (agent-shell-vertico-sidebar-use-nerd-icons nil)
          (agent-shell-vertico-sidebar-group-by 'project))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (agent-shell-vertico-sidebar--render)
        (goto-char (point-min))
        (should (equal (buffer-substring-no-properties
                        (point) (line-end-position))
                       "▶ alpha"))))))

(ert-deftest agent-shell-vertico-sidebar-project-header-truncates-name ()
  "A project name too long for its row loses columns, the count does not."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ long"
              "/work/a-very-long-project-directory-name-indeed/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-test-statuses (list (cons alpha 'ready)))
          (agent-shell-vertico-sidebar--attention
           (make-hash-table :test #'eq))
          (agent-shell-vertico-sidebar-use-nerd-icons nil)
          (agent-shell-vertico-sidebar-group-by 'project))
      (puthash alpha (list :kind 'blocked :time 10.0)
               agent-shell-vertico-sidebar--attention)
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (agent-shell-vertico-sidebar--render)
        (goto-char (point-min))
        (let ((line (buffer-substring-no-properties
                     (point) (line-end-position))))
          (should (string-suffix-p "▲ 1" line))
          (should (string-match-p "…" line))
          (should (= (string-width line)
                     agent-shell-vertico-sidebar-width)))))))

(ert-deftest agent-shell-vertico-sidebar-project-header-shows-one-attention ()
  "A project header names its most urgent attention kind and no other.

Every other kind is one line below on the session that has it, and the
header has room for one count."
  (agent-shell-vertico-tests--with-session-buffers
      ((failed "Codex Agent @ alpha" "/work/alpha/"
               '((:session . ((:id . "f") (:title . "Failed")))))
       (waiting "Claude Agent @ alpha" "/work/alpha/"
                '((:session . ((:id . "w") (:title . "Waiting")))))
       (finished "Codex Agent @ alpha" "/work/alpha/"
                 '((:session . ((:id . "d") (:title . "Finished"))))))
    (let ((agent-shell-test-buffers (list failed waiting finished))
          (agent-shell-test-statuses (list (cons failed 'ready)
                                           (cons waiting 'ready)
                                           (cons finished 'ready)))
          (agent-shell-vertico-sidebar--attention
           (make-hash-table :test #'eq))
          (agent-shell-vertico-sidebar-use-nerd-icons nil)
          (agent-shell-vertico-sidebar-group-by 'project))
      (puthash failed (list :kind 'error :time 10.0)
               agent-shell-vertico-sidebar--attention)
      (puthash waiting (list :kind 'blocked :time 10.0)
               agent-shell-vertico-sidebar--attention)
      (puthash finished (list :kind 'done :time 10.0)
               agent-shell-vertico-sidebar--attention)
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (agent-shell-vertico-sidebar--render)
        (goto-char (point-min))
        (let ((line (buffer-substring-no-properties
                     (point) (line-end-position))))
          (should (string-suffix-p "✖ 1" line))
          (should-not (string-match-p "▲" line))
          (should-not (string-match-p "●" line)))))))

(ert-deftest agent-shell-vertico-sidebar-opens-session-at-point ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar-group-by 'project))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (puthash "/work/alpha/" t agent-shell-vertico-sidebar--expanded-projects)
        (agent-shell-vertico-sidebar--render)
        (search-forward "Review alpha")
        (agent-shell-vertico-sidebar-open)
        (should (eq agent-shell-test-displayed-buffer alpha))))))

(ert-deftest agent-shell-vertico-sidebar-binds-both-return-events ()
  (should (eq (lookup-key agent-shell-vertico-sidebar-mode-map (kbd "RET"))
              #'agent-shell-vertico-sidebar-activate))
  (should (eq (lookup-key agent-shell-vertico-sidebar-mode-map
                           (kbd "<return>"))
              #'agent-shell-vertico-sidebar-activate))
  (should (eq (lookup-key agent-shell-vertico-sidebar-mode-map
                           (kbd "<mouse-1>"))
              #'agent-shell-vertico-sidebar-activate)))

(ert-deftest agent-shell-vertico-sidebar-mouse-face-stops-between-rows ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha")))))
       (beta "Codex Agent @ beta" "/work/beta/"
             '((:session . ((:id . "b") (:title . "Review beta"))))))
    (let ((agent-shell-test-buffers (list alpha beta))
          (agent-shell-vertico-sidebar-group-by nil)
          (agent-shell-vertico-sidebar-show-details nil))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (let ((boundary (next-single-property-change
                         (point-min) 'mouse-face nil (point-max))))
          (should (< boundary (point-max)))
          (should-not (get-text-property boundary 'mouse-face))
          (search-forward "Review beta")
          (beginning-of-line)
          (should (eq (get-text-property (point) 'mouse-face)
                      'highlight)))))))

(ert-deftest agent-shell-vertico-sidebar-dispatches-session-action ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar-group-by 'project))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (puthash "/work/alpha/" t agent-shell-vertico-sidebar--expanded-projects)
        (agent-shell-vertico-sidebar--render)
        (search-forward "Review alpha")
        (agent-shell-vertico-sidebar-view-traffic)
        (should (eq agent-shell-test-last-command 'agent-shell-view-traffic))
        (should (eq agent-shell-test-last-buffer alpha))))))

(ert-deftest agent-shell-vertico-tests-use-agent-shell-stub ()
  (should (bound-and-true-p agent-shell-test-stub-p)))

(ert-deftest agent-shell-vertico-tests-reject-real-agent-shell ()
  (cl-letf (((symbol-value 'agent-shell-test-stub-p) nil))
    (should-error
     (agent-shell-vertico-tests--ensure-agent-shell-stub)
     :type 'user-error)))

(ert-deftest agent-shell-vertico-tests-session-fixture-suppresses-mode-hook ()
  (let ((agent-shell-mode-hook
         (list (lambda () (ert-fail "agent-shell-mode-hook ran")))))
    (agent-shell-vertico-tests--with-session-buffers
        ((session "Agent @ project" "/work/project/" nil))
      (should
       (eq (buffer-local-value 'major-mode session)
           'agent-shell-mode)))))

(ert-deftest agent-shell-vertico-model-name-reads-config-options ()
  "Agents advertising the model only via config options must still resolve.
Claude Code leaves the session :model-id and :models fields nil."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "claude-agent @ alpha" "/work/alpha/"
              '((:session
                 . ((:id . "a")
                    (:model-id . nil)
                    (:models . nil)
                    (:config-options
                     . (((:id . "model") (:category . "model")
                         (:current-value . "opus[1m]")
                         (:options ((:value . "default")
                                    (:name . "Default (recommended)"))
                                   ((:value . "opus[1m]")
                                    (:name . "Opus (1M context)")))))))))))
    (should (equal (agent-shell-vertico--model-name alpha)
                   "Opus (1M context)"))))

(ert-deftest agent-shell-vertico-mode-name-prefers-config-option ()
  "The config option carries the live mode; session :mode-id can be stale.
Changing the mode through a config option updates only the option unless
the agent also sends a `current_mode_update' notification."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "claude-agent @ alpha" "/work/alpha/"
              '((:session
                 . ((:id . "a")
                    (:mode-id . "auto")
                    (:modes . [((:id . "auto") (:name . "Auto"))
                               ((:id . "plan") (:name . "Plan Mode"))])
                    (:config-options
                     . (((:id . "mode") (:category . "mode")
                         (:current-value . "plan")
                         (:options ((:value . "auto") (:name . "Auto"))
                                   ((:value . "plan")
                                    (:name . "Plan Mode")))))))))))
    (should (equal (agent-shell-vertico--mode-name alpha) "Plan Mode"))))

(ert-deftest agent-shell-vertico-model-name-falls-back-to-session-fields ()
  "Agents without config options keep resolving from session fields."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a")
                             (:model-id . "gpt-5")
                             (:models . [((:model-id . "gpt-5")
                                          (:name . "GPT-5"))])
                             (:mode-id . "plan")
                             (:modes . [((:id . "plan")
                                         (:name . "Plan"))]))))))
    (should (equal (agent-shell-vertico--model-name alpha) "GPT-5"))
    (should (equal (agent-shell-vertico--mode-name alpha) "Plan"))))

(ert-deftest agent-shell-vertico-sidebar-renders-config-option-model ()
  "The sidebar shows a real model name for config-option-only agents."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "claude-agent @ alpha" "/work/alpha/"
              '((:session
                 . ((:id . "a")
                    (:title . "Review alpha")
                    (:config-options
                     . (((:id . "model") (:category . "model")
                         (:current-value . "opus[1m]")
                         (:options ((:value . "opus[1m]")
                                    (:name . "Opus (1M context)")))))))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-vertico-sidebar-show-details t)
          (agent-shell-vertico-sidebar-extra-info '(model))
          (agent-shell-vertico-sidebar-width 60))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (agent-shell-vertico-sidebar--render)
        (should (string-match-p "Opus (1M context)" (buffer-string)))))))

(ert-deftest agent-shell-vertico-completion-table-adds-agent-shell-metadata ()
  (let ((metadata (funcall (agent-shell-vertico--completion-table 'all)
                           "" nil 'metadata)))
    (should (equal (cdr (assq 'category (cdr metadata)))
                   'agent-shell-session))
    (should (functionp (cdr (assq 'affixation-function (cdr metadata)))))))

(ert-deftest agent-shell-vertico-read-session-uses-completing-read ()
  "The core session reader keeps the plain completion behavior."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/"
              '((:session . ((:id . "a")))))
       (beta "Beta Agent @ beta" "/tmp/beta/"
             '((:session . ((:id . "b"))))))
    (setq agent-shell-test-buffers (list alpha beta))
    (let ((seen nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt collection &rest _)
                   (setq seen (list prompt
                                    (all-completions "" collection)))
                   (buffer-name beta))))
        (should (equal
                 (agent-shell-vertico--read-session
                  "Agent shell: " 'all)
                 (buffer-name beta))))
      (should (equal seen
                     (list "Agent shell: "
                           (list (buffer-name alpha)
                                 (buffer-name beta))))))))

(ert-deftest agent-shell-vertico-status-reports-working-while-busy ()
  "A shell with work in flight reports Working and sorts before the rest."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/"
              '((:session . ((:id . "a")))))
       (beta "Beta Agent @ beta" "/tmp/beta/"
             '((:session . ((:id . "b"))))))
    (let ((busy (list alpha)))
      (cl-letf (((symbol-function 'shell-maker-busy)
                 (lambda (&rest _) (memq (current-buffer) busy))))
        (should (equal (agent-shell-vertico--status alpha) "Working"))
        (should (equal (agent-shell-vertico--status beta) "Ready"))
        ;; Ready sorts ahead of Working, which sorts ahead of the rest.
        (let ((agent-shell-vertico-sort-by 'status))
          (should (equal (agent-shell-vertico--sort-candidates
                          (list (buffer-name alpha) (buffer-name beta)))
                         (list (buffer-name beta) (buffer-name alpha)))))))
    (should (equal (agent-shell-vertico--status alpha) "Ready"))))

(ert-deftest agent-shell-vertico-annotator-registered-for-the-category ()
  "The session annotator is registered against its completion category."
  (should (equal (assq 'agent-shell-session marginalia-annotators)
                 '(agent-shell-session agent-shell-vertico--annotate none))))

(ert-deftest agent-shell-vertico-annotator-matches-the-affixation ()
  "The Marginalia annotator renders exactly what the table's affixation does.
They are the two ways the same session columns reach the user, and a
difference between them shows up only in one completion framework."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/"
              '((:session . ((:id . "a")
                             (:title . "Review alpha")
                             (:mode-id . "plan")
                             (:modes . [((:id . "plan") (:name . "Plan"))])
                             (:model-id . "gpt-5")
                             (:models . [((:model-id . "gpt-5")
                                          (:name . "GPT-5"))]))))))
    (let* ((agent-shell-test-buffers (list alpha))
           (name (buffer-name alpha))
           (affixated (caddr (car (agent-shell-vertico--affixate (list name))))))
      (should (equal (agent-shell-vertico--annotate name) affixated))
      (should (string-match-p "Review alpha" affixated))))
  (should-not (agent-shell-vertico--annotate "No such session buffer")))

(ert-deftest agent-shell-vertico-annotation-keeps-marginalia-formatting ()
  "Annotations carry marginalia's align marker and per-column faces.
`marginalia--fields' expands where this package is compiled, so a test
stand-in that dropped either would be frozen into the compiled package
and every annotation would lose its columns for real users too."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha"))))))
    (let ((suffix (agent-shell-vertico--suffix alpha)))
      (should (text-property-any 0 (length suffix)
                                 'marginalia--align t suffix))
      (should (text-property-not-all 0 (length suffix) 'face nil suffix)))))

(ert-deftest agent-shell-vertico-all-scope-uses-agent-shell-buffers ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/"
              '((:session . ((:id . "a")
                             (:title . "Review alpha")
                             (:mode-id . "plan")
                             (:modes . [((:id . "plan") (:name . "Plan"))])
                             (:model-id . "gpt-5")
                             (:models . [((:model-id . "gpt-5") (:name . "GPT-5"))])))
                (:agent-config . ((:buffer-name . "Alpha Agent")))))
       (beta "Beta Agent @ beta" "/tmp/beta/"
             '((:session . ((:id . "b")
                            (:title . "Fix beta")
                            (:mode-id . "edit")
                            (:modes . [((:id . "edit") (:name . "Edit"))])
                            (:model-id . "sonnet")
                            (:models . [((:model-id . "sonnet") (:name . "Sonnet"))])))
               (:agent-config . ((:buffer-name . "Beta Agent"))))))
    (let* ((agent-shell-test-buffers (list alpha beta))
           (table (agent-shell-vertico--completion-table 'all))
           (candidates (all-completions "" table)))
      (should (equal candidates
                     '("Alpha Agent @ alpha" "Beta Agent @ beta")))
      (let* ((metadata (funcall table "" nil 'metadata))
             (affixation (cdr (assq 'affixation-function (cdr metadata))))
             (decorated (funcall affixation candidates)))
        (should (equal (mapcar #'car decorated) candidates))
        (should (string-match-p "Review alpha" (caddr (car decorated))))
        (should (string-match-p "GPT-5" (caddr (car decorated))))
        (should (string-match-p "Edit" (caddr (cadr decorated))))))))

(ert-deftest agent-shell-vertico-project-scope-uses-project-buffers ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/" '((:session . ((:id . "a")))))
       (beta "Beta Agent @ beta" "/tmp/beta/" '((:session . ((:id . "b"))))))
    (let* ((agent-shell-test-buffers (list alpha beta))
           (agent-shell-test-project-buffers (list beta))
           (table (agent-shell-vertico--completion-table 'project))
           (candidates (all-completions "" table)))
      (should (equal candidates '("Beta Agent @ beta"))))))

;;; Shell buffer picker

(ert-deftest agent-shell-vertico-setup-enables-integrations-once ()
  "The main setup command installs every package integration once."
  (let ((agent-shell-mode-hook nil)
        (agent-shell-viewport-view-mode-hook nil)
        (minibuffer-setup-hook nil)
        (consult-after-jump-hook nil)
        (marginalia-annotators '((imenu builtin none)))
        (after-load-alist nil))
    (unwind-protect
        (progn
          (agent-shell-vertico-setup)
          (agent-shell-vertico-setup)
          (should (= 1 (seq-count
                        (lambda (function)
                          (eq function #'agent-shell-vertico--imenu-setup))
                        agent-shell-mode-hook)))
          (should (= 1 (seq-count
                        (lambda (function)
                          (eq function #'agent-shell-vertico--imenu-setup))
                        agent-shell-viewport-view-mode-hook)))
          (should (= 1 (seq-count
                        (lambda (function)
                          (eq function
                              #'agent-shell-vertico-consult--plain-candidates))
                        minibuffer-setup-hook)))
          (should (= 1 (seq-count
                        (lambda (function)
                          (eq function
                              #'agent-shell-vertico-consult--expand-fold))
                        consult-after-jump-hook)))
          (should (string-match-p
                   "agent-shell-vertico--setup-embark-integrations"
                   (prin1-to-string after-load-alist)))
          (dolist (spec
                   '((agent-shell--read-shell-buffer
                      agent-shell-vertico--read-shell-buffer)
                     (agent-shell--prompt-select-session
                      agent-shell-vertico-resume--select-session)))
            (let ((installed 0))
              (advice-mapc
               (lambda (function _properties)
                 (when (eq function (cadr spec))
                   (cl-incf installed)))
               (car spec))
              (should (= installed 1)))))
      (advice-remove 'agent-shell--read-shell-buffer
                     #'agent-shell-vertico--read-shell-buffer)
      (advice-remove 'agent-shell--prompt-select-session
                     #'agent-shell-vertico-resume--select-session))))

(defmacro agent-shell-vertico-tests--with-shell-buffer-picker (&rest body)
  "Evaluate BODY with the shell buffer picker advice installed."
  (declare (indent 0))
  `(unwind-protect
       (progn (agent-shell-vertico-setup-shell-buffer-picker)
              ,@body)
     (advice-remove 'agent-shell--read-shell-buffer
                    #'agent-shell-vertico--read-shell-buffer)))

(ert-deftest agent-shell-vertico-read-shell-buffer-annotates-candidates ()
  "The prompt asking which shell to act on reads through the session table."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha")))))
       (beta "Beta Agent @ beta" "/tmp/beta/"
             '((:session . ((:id . "b") (:title . "Fix beta"))))))
    (setq agent-shell-test-buffers (list alpha beta))
    (let ((seen nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt collection &rest _)
                   (setq seen (list prompt
                                    (all-completions "" collection)
                                    (funcall collection "" nil 'metadata)))
                   (buffer-name beta))))
        (should (eq (agent-shell-vertico--read-shell-buffer
                     :prompt "Send region to shell: ")
                    beta)))
      (pcase-let ((`(,prompt ,candidates ,metadata) seen))
        (should (equal prompt "Send region to shell: "))
        (should (equal candidates
                       (list (buffer-name alpha) (buffer-name beta))))
        (should (equal (alist-get 'category (cdr metadata))
                       'agent-shell-session))
        (should (string-match-p
                 "Review alpha"
                 (caddr (car (funcall (alist-get 'affixation-function
                                                 (cdr metadata))
                                      (list (buffer-name alpha)))))))))))

(ert-deftest agent-shell-vertico-read-shell-buffer-keeps-callers-buffers ()
  "A caller naming the shells to choose from is offered only those, alive.
The session picker's other-shell branch reads that way."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/" '((:session . ((:id . "a")))))
       (beta "Beta Agent @ beta" "/tmp/beta/" '((:session . ((:id . "b"))))))
    (setq agent-shell-test-buffers (list alpha beta))
    (let ((dead (generate-new-buffer "Gone Agent @ gone"))
          (candidates nil))
      (kill-buffer dead)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (setq candidates (all-completions "" collection))
                   (buffer-name beta))))
        (should (eq (agent-shell-vertico--read-shell-buffer
                     :prompt "Switch to shell buffer: "
                     :buffers (list beta dead))
                    beta)))
      (should (equal candidates (list (buffer-name beta)))))))

(ert-deftest agent-shell-vertico-read-shell-buffer-without-shells-errors ()
  "With no shell to offer, the reader reports it rather than prompting."
  (let ((agent-shell-test-buffers nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) (error "Prompted with nothing to choose"))))
      (should-error (agent-shell-vertico--read-shell-buffer)
                    :type 'user-error))))

(ert-deftest agent-shell-vertico-read-shell-buffer-without-selection-errors ()
  "Leaving the prompt without choosing a shell is an error, not a nil buffer."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/" '((:session . ((:id . "a"))))))
    (setq agent-shell-test-buffers (list alpha))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "")))
      (should-error (agent-shell-vertico--read-shell-buffer)
                    :type 'user-error))))

(ert-deftest agent-shell-vertico-shell-buffer-picker-serves-agent-shell ()
  "End to end: agent-shell's own reader hands the prompt to the table."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/"
              '((:session . ((:id . "a") (:title . "Review alpha")))))
       (beta "Beta Agent @ beta" "/tmp/beta/"
             '((:session . ((:id . "b") (:title . "Fix beta"))))))
    (setq agent-shell-test-buffers (list alpha beta))
    (let ((category nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (setq category
                         (alist-get 'category
                                    (cdr (funcall collection "" nil 'metadata))))
                   (buffer-name beta))))
        (agent-shell-vertico-tests--with-shell-buffer-picker
          (should (eq (agent-shell--read-shell-buffer
                       :prompt "Send region to shell: ")
                      beta))))
      (should (equal category 'agent-shell-session)))))

(ert-deftest agent-shell-vertico-consult-registers-session-reader ()
  "Loading Consult upgrades the live-session reader to one with preview."
  (should (equal agent-shell-vertico-read-session-function
                 #'agent-shell-vertico-consult--read-session)))

(ert-deftest
    agent-shell-vertico-consult-session-reader-preserves-table-metadata ()
  "The Consult reader uses the session table and its configured sorting."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/"
              '((:session . ((:id . "a")))))
       (beta "Beta Agent @ beta" "/tmp/beta/"
             '((:session . ((:id . "b"))))))
    (setq agent-shell-test-buffers (list alpha beta))
    (let (table options)
      (cl-letf (((symbol-function 'consult--read)
                 (lambda (candidate-table &rest rest)
                   (setq table candidate-table
                         options rest)
                   (buffer-name beta))))
        (should (equal
                 (agent-shell-vertico-consult--read-session
                  "Agent shell: "
                  (agent-shell-vertico--completion-table 'all))
                 (buffer-name beta))))
      (should (equal (all-completions "" table)
                     (list (buffer-name alpha) (buffer-name beta))))
      (let ((metadata (funcall table "" nil 'metadata)))
        (should (equal (alist-get 'category (cdr metadata))
                       'agent-shell-session))
        (should (eq (alist-get 'display-sort-function (cdr metadata))
                    #'agent-shell-vertico--sort-candidates)))
      (should (equal (plist-get options :category)
                     'agent-shell-session))
      (should (functionp (plist-get options :state)))
      (should-not (plist-member options :sort)))))

(ert-deftest
    agent-shell-vertico-consult-session-preview-uses-existing-viewport ()
  "Session preview uses an existing viewport without creating one."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/"
              '((:session . ((:id . "a"))))))
    (let ((viewport (generate-new-buffer "Alpha Agent @ alpha [viewport]"))
          calls
          existing-only)
      (unwind-protect
          (cl-letf (((symbol-function 'consult--buffer-preview)
                     (lambda ()
                       (lambda (action candidate)
                         (push (list action candidate
                                     consult--buffer-display)
                               calls))))
                    ((symbol-function 'agent-shell-viewport--buffer)
                     (lambda (&rest arguments)
                       (setq existing-only
                             (plist-get arguments :existing-only))
                       (and existing-only viewport))))
            (let ((agent-shell-prefer-viewport-interaction t)
                  (state
                   (agent-shell-vertico-consult--session-state t)))
              (funcall state 'preview (buffer-name alpha))
              (funcall state 'preview nil))
            (should (equal (caar calls) 'preview))
            (should (null (cadar calls)))
            (should (eq (caddar calls) #'switch-to-buffer-other-window))
            (should existing-only)
            (should (eq (cadadr calls) viewport)))
        (kill-buffer viewport)))))

(ert-deftest agent-shell-vertico-consult-session-state-forwards-lifecycle ()
  "Session preview forwards lifecycle actions without performing selection."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/"
              '((:session . ((:id . "a"))))))
    (let (calls)
      (cl-letf (((symbol-function 'consult--buffer-preview)
                 (lambda ()
                   (lambda (action candidate)
                     (push (list action candidate consult--buffer-display)
                           calls))))
                ((symbol-function 'agent-shell-viewport--buffer)
                 (lambda (&rest _)
                   (ert-fail "Resolved a viewport while preference was nil"))))
        (let ((agent-shell-prefer-viewport-interaction nil)
              (state (agent-shell-vertico-consult--session-state t)))
          (funcall state 'setup nil)
          (funcall state 'preview (buffer-name alpha))
          (funcall state 'preview nil)
          (funcall state 'exit nil)
          (funcall state 'return (buffer-name alpha))))
      (should
       (equal
        (nreverse calls)
        `((setup nil ,#'switch-to-buffer-other-window)
          (preview ,alpha ,#'switch-to-buffer-other-window)
          (preview nil ,#'switch-to-buffer-other-window)
          (exit nil ,#'switch-to-buffer-other-window)
          (return nil ,#'switch-to-buffer-other-window)))))))

(ert-deftest agent-shell-vertico-consult-session-preview-falls-back-to-shell ()
  "Viewport preference does not create a viewport just for preview."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/"
              '((:session . ((:id . "a"))))))
    (let (candidate arguments)
      (cl-letf (((symbol-function 'consult--buffer-preview)
                 (lambda ()
                   (lambda (action value)
                     (when (eq action 'preview)
                       (setq candidate value)))))
                ((symbol-function 'agent-shell-viewport--buffer)
                 (lambda (&rest rest)
                   (setq arguments rest)
                   nil)))
        (let ((agent-shell-prefer-viewport-interaction t)
              (state (agent-shell-vertico-consult--session-state)))
          (funcall state 'preview (buffer-name alpha))))
      (should (eq candidate alpha))
      (should (eq (plist-get arguments :shell-buffer) alpha))
      (should (eq (plist-get arguments :existing-only) t)))))

(ert-deftest
    agent-shell-vertico-consult-session-preview-reset-restores-buffer ()
  "Resetting a live-session preview restores the original buffer."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/"
              '((:session . ((:id . "a"))))))
    (save-window-excursion
      (let ((original (generate-new-buffer "preview origin")))
        (unwind-protect
            (progn
              (switch-to-buffer original)
              (let ((agent-shell-prefer-viewport-interaction nil)
                    (state (agent-shell-vertico-consult--session-state)))
                (funcall state 'preview (buffer-name alpha))
                (should (eq (window-buffer) alpha))
                (funcall state 'preview nil)
                (should (eq (window-buffer) original))))
          (kill-buffer original))))))

(ert-deftest agent-shell-vertico-consult-switch-defers-final-action ()
  "Previewing does not display the session before selection."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/"
              '((:session . ((:id . "a"))))))
    (setq agent-shell-test-buffers (list alpha))
    (let ((agent-shell-vertico-read-session-function
           #'agent-shell-vertico-consult--read-session)
          (agent-shell-prefer-viewport-interaction nil)
          preview-calls)
      (cl-letf (((symbol-function 'consult--buffer-preview)
                 (lambda ()
                   (lambda (action candidate)
                     (push (list action candidate) preview-calls))))
                ((symbol-function 'consult--read)
                 (lambda (table &rest options)
                   (should (equal (all-completions "" table)
                                  (list (buffer-name alpha))))
                   (let ((state (plist-get options :state)))
                     (funcall state 'setup nil)
                     (funcall state 'preview (buffer-name alpha))
                     (should-not agent-shell-test-displayed-buffer)
                     (funcall state 'preview nil)
                     (funcall state 'exit nil)
                     (funcall state 'return (buffer-name alpha)))
                   (buffer-name alpha))))
        (agent-shell-vertico-switch))
      (should (eq agent-shell-test-displayed-buffer alpha))
      (should
       (equal
        (nreverse preview-calls)
        `((setup nil) (preview ,alpha) (preview nil) (exit nil)
          (return nil)))))))

(ert-deftest agent-shell-vertico-consult-shell-buffer-reader-previews-subset ()
  "The Consult shell-buffer reader keeps the caller's buffer subset."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/"
              '((:session . ((:id . "a")))))
       (beta "Beta Agent @ beta" "/tmp/beta/"
             '((:session . ((:id . "b"))))))
    (let ((agent-shell-vertico-read-session-function
           #'agent-shell-vertico-consult--read-session)
          (offered nil))
      (cl-letf (((symbol-function 'consult--read)
                 (lambda (table &rest _)
                   (setq offered (all-completions "" table))
                   (buffer-name beta))))
        (should (eq (agent-shell-vertico--read-shell-buffer
                     :prompt "Switch to shell buffer: "
                     :buffers (list beta))
                    beta)))
      (should (equal offered (list (buffer-name beta)))))))

(ert-deftest
    agent-shell-vertico-consult-shell-buffer-reader-drops-dead-buffer ()
  "A caller's buffer can die after the Consult prompt starts."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/"
              '((:session . ((:id . "a")))))
       (beta "Beta Agent @ beta" "/tmp/beta/"
             '((:session . ((:id . "b"))))))
    (let ((agent-shell-vertico-read-session-function
           #'agent-shell-vertico-consult--read-session)
          offered)
      (cl-letf (((symbol-function 'consult--read)
                 (lambda (table &rest _)
                   (kill-buffer alpha)
                   (setq offered (all-completions "" table))
                   (buffer-name beta))))
        (should (eq (agent-shell-vertico--read-shell-buffer
                     :buffers (list alpha beta))
                    beta)))
      (should (equal offered (list (buffer-name beta)))))))

(ert-deftest agent-shell-vertico-shell-buffer-picker-setup-installs-advice ()
  "Setup installs the reader advice once."
  (agent-shell-vertico-tests--with-shell-buffer-picker
    (agent-shell-vertico-setup-shell-buffer-picker)
    (let ((installed 0))
      (advice-mapc
       (lambda (function _properties)
         (when (eq function #'agent-shell-vertico--read-shell-buffer)
           (cl-incf installed)))
       'agent-shell--read-shell-buffer)
      (should (= installed 1)))))

;;; Project-scoped shell commands

(defmacro agent-shell-vertico-tests--with-project-shells (&rest body)
  "Evaluate BODY with two shells in one project and one in another.

Binds `alpha-one' and `alpha-two' in project alpha and `beta' in project
beta, with every shell live and `default-directory' in project alpha."
  (declare (indent 0))
  `(agent-shell-vertico-tests--with-session-buffers
       ((alpha-one "Alpha Agent @ one" "/work/alpha/"
                   '((:session . ((:id . "a1") (:title . "Alpha one")))))
        (alpha-two "Alpha Agent @ two" "/work/alpha/"
                   '((:session . ((:id . "a2") (:title . "Alpha two")))))
        (beta "Beta Agent @ beta" "/work/beta/"
              '((:session . ((:id . "b") (:title . "Beta"))))))
     (setq agent-shell-test-buffers (list alpha-one alpha-two beta))
     (setq agent-shell-test-project-buffers (list alpha-one alpha-two))
     (let ((default-directory "/work/alpha/"))
       ,@body)))

(ert-deftest agent-shell-vertico-consult-switch-project-keeps-project-scope ()
  "The Consult project switch offers and selects only project shells."
  (agent-shell-vertico-tests--with-project-shells
    (let ((agent-shell-vertico-read-session-function
           #'agent-shell-vertico-consult--read-session)
          (agent-shell-prefer-viewport-interaction nil)
          offered)
      (cl-letf (((symbol-function 'consult--read)
                 (lambda (table &rest _)
                   (setq offered (all-completions "" table))
                   (buffer-name alpha-two))))
        (agent-shell-vertico-switch-project))
      (should (equal offered (list (buffer-name alpha-one)
                                   (buffer-name alpha-two))))
      (should (eq agent-shell-test-displayed-buffer alpha-two)))))

(ert-deftest agent-shell-vertico-target-shell-uses-the-only-project-shell ()
  "One shell in the project answers without asking."
  (agent-shell-vertico-tests--with-project-shells
    (setq agent-shell-test-project-buffers (list alpha-one))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) (error "Asked with nothing to choose between"))))
      (should (eq (agent-shell-vertico--target-shell) alpha-one)))))

(ert-deftest agent-shell-vertico-target-shell-asks-within-the-project ()
  "Several shells in the project mean a prompt, offering only those shells."
  (agent-shell-vertico-tests--with-project-shells
    (let ((offered nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (setq offered (all-completions "" collection))
                   (buffer-name alpha-two))))
        (should (eq (agent-shell-vertico--target-shell) alpha-two)))
      (should (equal offered (list (buffer-name alpha-one)
                                   (buffer-name alpha-two)))))))

(ert-deftest agent-shell-vertico-target-shell-falls-back-to-every-shell ()
  "No shell in the project asks across every live shell instead."
  (agent-shell-vertico-tests--with-project-shells
    (setq agent-shell-test-project-buffers nil)
    (let ((offered nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (setq offered (all-completions "" collection))
                   (buffer-name beta))))
        (should (eq (agent-shell-vertico--target-shell) beta)))
      (should (equal offered (list (buffer-name alpha-one)
                                   (buffer-name alpha-two)
                                   (buffer-name beta)))))))

(ert-deftest agent-shell-vertico-target-shell-prefix-offers-every-shell ()
  "The escape hatch reaches shells outside the current project."
  (agent-shell-vertico-tests--with-project-shells
    (let ((offered nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (setq offered (all-completions "" collection))
                   (buffer-name beta))))
        (should (eq (agent-shell-vertico--target-shell t) beta)))
      (should (equal offered (list (buffer-name alpha-one)
                                   (buffer-name alpha-two)
                                   (buffer-name beta)))))))

(ert-deftest agent-shell-vertico-target-shell-without-any-shell ()
  "No live shell anywhere signals; these commands never start one."
  (agent-shell-vertico-tests--with-project-shells
    (setq agent-shell-test-buffers nil
          agent-shell-test-project-buffers nil)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) (error "Asked with no shell to offer"))))
      (should-error (agent-shell-vertico--target-shell t)
                    :type 'user-error))))

(ert-deftest agent-shell-vertico-target-shell-ignores-the-buffer-at-point ()
  "Standing in one shell does not decide the target for another project's work.
Sending from one session to another is the point of asking."
  (agent-shell-vertico-tests--with-project-shells
    (with-current-buffer beta
      (let ((default-directory "/work/alpha/"))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt collection &rest _)
                     (car (all-completions "" collection)))))
          (should (eq (agent-shell-vertico--target-shell) alpha-one)))))))

(ert-deftest agent-shell-vertico-with-target-shell-pins-resolution ()
  "The body sees the resolved shell wherever agent-shell resolves one."
  (agent-shell-vertico-tests--with-project-shells
    (setq agent-shell-test-project-buffers (list alpha-two))
    (should (eq (agent-shell-vertico--with-target-shell nil
                  (agent-shell--shell-buffer :no-create t))
                alpha-two))))

(ert-deftest agent-shell-vertico-with-target-shell-signals-without-a-shell ()
  "No live shell anywhere signals before the body runs, starting nothing."
  (agent-shell-vertico-tests--with-project-shells
    (setq agent-shell-test-buffers nil
          agent-shell-test-project-buffers nil)
    (let ((ran nil))
      (should-error (agent-shell-vertico--with-target-shell nil
                      (setq ran t))
                    :type 'user-error)
      (should-not ran))))

(ert-deftest agent-shell-vertico-commands-send-to-the-resolved-shell ()
  "Each command delegates to agent-shell with the resolved shell in place."
  (agent-shell-vertico-tests--with-project-shells
    (setq agent-shell-test-project-buffers (list alpha-two))
    (dolist (spec '((agent-shell-vertico-send-region
                     agent-shell-send-region (nil))
                    (agent-shell-vertico-send-file
                     agent-shell-send-file (nil nil))
                    (agent-shell-vertico-send-other-file
                     agent-shell-send-file (t nil))
                    (agent-shell-vertico-send-screenshot
                     agent-shell-send-screenshot (nil))
                    (agent-shell-vertico-send-clipboard-image
                     agent-shell-send-clipboard-image (nil))
                    (agent-shell-vertico-send-prompt
                     agent-shell-prompt-send-dwim (nil))
                    (agent-shell-vertico-queue-prompt
                     agent-shell-prompt-queue-dwim (nil))
                    (agent-shell-vertico-steer-prompt
                     agent-shell-prompt-steer-dwim (nil))
                    (agent-shell-vertico-compose
                     agent-shell-prompt-compose ())))
      (pcase-let ((`(,command ,delegate ,arguments) spec))
        (setq agent-shell-test-last-command nil
              agent-shell-test-last-args nil
              agent-shell-test-last-target nil)
        (call-interactively command)
        (should (equal (list command agent-shell-test-last-command)
                       (list command delegate)))
        (should (equal (list command agent-shell-test-last-args)
                       (list command arguments)))
        (should (equal (list command agent-shell-test-last-target)
                       (list command alpha-two)))))))

(ert-deftest agent-shell-vertico-commands-take-the-prefix-as-the-escape-hatch ()
  "A prefix argument sends to a shell chosen from every project."
  (agent-shell-vertico-tests--with-project-shells
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _)
                 (car (last (all-completions "" collection))))))
      (let ((current-prefix-arg '(4)))
        (call-interactively #'agent-shell-vertico-send-region))
      (should (eq agent-shell-test-last-target beta))
      ;; The prefix picks the shell; it never reaches the delegate, where
      ;; `agent-shell-send-file' would read it as "prompt for a file".
      (let ((current-prefix-arg '(4)))
        (call-interactively #'agent-shell-vertico-send-file))
      (should (equal agent-shell-test-last-args '(nil nil)))
      (should (eq agent-shell-test-last-target beta)))))

(ert-deftest agent-shell-vertico-commands-signal-without-any-shell ()
  "No live shell anywhere signals before the delegate could start one."
  (agent-shell-vertico-tests--with-project-shells
    (setq agent-shell-test-buffers nil
          agent-shell-test-project-buffers nil
          agent-shell-test-last-command nil)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) (error "Asked with no shell to offer"))))
      (dolist (command '(agent-shell-vertico-send-region
                         agent-shell-vertico-send-prompt
                         agent-shell-vertico-compose))
        (should-error (call-interactively command) :type 'user-error)))
    (should-not agent-shell-test-last-command)))

(ert-deftest agent-shell-vertico-loading-does-not-prebind-embark-keymap-alist ()
  "Loading the package must not bind `embark-keymap-alist'.
A top-level `defvar' with a value would pre-bind it to nil, which
prevents embark's own `defcustom' from installing its default target
type to keymap mappings when embark loads later."
  (skip-unless (not (featurep 'embark)))
  (should-not (boundp 'embark-keymap-alist)))

(ert-deftest agent-shell-vertico-embark-setup-registers-manager-like-actions ()
  (let ((embark-keymap-alist nil)
        (embark-default-action-overrides nil)
        (embark-target-finders nil))
    (agent-shell-vertico-setup-embark)
    (should (equal (assq 'agent-shell-session embark-keymap-alist)
                   '(agent-shell-session
                     agent-shell-vertico-embark-map
                     embark-buffer-map)))
    (should (eq (lookup-key agent-shell-vertico-embark-map (kbd "k"))
                #'agent-shell-vertico-kill-session))
    (should (eq (lookup-key agent-shell-vertico-embark-map (kbd "c"))
                #'agent-shell-vertico-new-shell))
    (should (eq (lookup-key agent-shell-vertico-embark-map (kbd "r"))
                #'agent-shell-vertico-restart-session))
    (should (eq (lookup-key agent-shell-vertico-embark-map (kbd "t"))
                #'agent-shell-vertico-view-traffic))
    (should (eq (lookup-key agent-shell-vertico-embark-map (kbd "T"))
                #'agent-shell-vertico-open-transcript))
    (should (eq (lookup-key agent-shell-vertico-embark-map (kbd "o"))
                #'agent-shell-vertico-switch-other-window))))

(ert-deftest agent-shell-vertico-open-transcript-dispatches-in-target-buffer ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/" '((:session . ((:id . "a"))))))
    (let (reader-buffer)
      (cl-letf (((symbol-function 'agent-shell-vertico-transcript-open-session)
                 (lambda (&optional other-window)
                   (setq reader-buffer (current-buffer))
                   (should-not other-window))))
        (agent-shell-vertico-open-transcript (buffer-name alpha)))
      (should (eq reader-buffer alpha))
      (should-not agent-shell-test-last-command))))

(ert-deftest agent-shell-vertico-kill-session-sends-eof-for-target-buffer ()
  "EOF is sent from the session's own buffer, and the buffer is killed.
`comint-send-eof' takes no argument and acts on the current buffer, so
which buffer it runs in is the whole of its behaviour."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/"
              '((:client . ((:process . fake-proc))))))
    (let ((eof-buffers nil))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                ((symbol-function 'process-live-p) (lambda (_process) t))
                ((symbol-function 'comint-send-eof)
                 (lambda () (push (current-buffer) eof-buffers))))
        (agent-shell-vertico-kill-session (buffer-name alpha))
        (should (equal eof-buffers (list alpha)))
        (should-not (buffer-live-p alpha))))))

(ert-deftest agent-shell-vertico-kill-session-declined-keeps-the-buffer ()
  "Declining the confirmation leaves the session running."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/"
              '((:client . ((:process . fake-proc))))))
    (let ((eof-buffers nil))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
                ((symbol-function 'process-live-p) (lambda (_process) t))
                ((symbol-function 'comint-send-eof)
                 (lambda () (push (current-buffer) eof-buffers))))
        (agent-shell-vertico-kill-session (buffer-name alpha))
        (should-not eof-buffers)
        (should (buffer-live-p alpha))))))

(ert-deftest agent-shell-vertico-restart-session-dispatches-in-target-buffer ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/"
              '((:client . ((:process . fake-proc))))))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (agent-shell-vertico-restart-session (buffer-name alpha))
      (should (eq agent-shell-test-last-command 'agent-shell-restart))
      (should (eq agent-shell-test-last-buffer alpha)))))

(ert-deftest agent-shell-vertico-new-shell-dispatches-to-agent-shell-new-shell ()
  (agent-shell-vertico-new-shell)
  (should (eq agent-shell-test-last-command 'agent-shell-new-shell)))

(ert-deftest agent-shell-vertico-sort-by-recency-most-recent-first ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/"
              '((:session . ((:id . "a")))))
       (beta "Beta Agent @ beta" "/tmp/beta/"
             '((:session . ((:id . "b"))))))
    (with-current-buffer alpha
      (setq-local buffer-display-time (encode-time 0 0 10 1 1 2026)))
    (with-current-buffer beta
      (setq-local buffer-display-time (encode-time 0 0 12 1 1 2026)))
    (let ((agent-shell-test-buffers (list alpha beta))
          (agent-shell-vertico-sort-by 'recency))
      (let* ((table (agent-shell-vertico--completion-table 'all))
             (metadata (funcall table "" nil 'metadata))
             (sort-fn (cdr (assq 'display-sort-function (cdr metadata)))))
        (should (equal (funcall sort-fn
                                '("Alpha Agent @ alpha" "Beta Agent @ beta"))
                       '("Beta Agent @ beta" "Alpha Agent @ alpha")))))))

(ert-deftest agent-shell-vertico-sort-by-creation-alphabetical ()
  (agent-shell-vertico-tests--with-session-buffers
      ((beta "Beta Agent @ beta" "/tmp/beta/"
             '((:session . ((:id . "b")))))
       (alpha "Alpha Agent @ alpha" "/tmp/alpha/"
              '((:session . ((:id . "a"))))))
    (let ((agent-shell-test-buffers (list beta alpha))
          (agent-shell-vertico-sort-by 'creation))
      (let* ((table (agent-shell-vertico--completion-table 'all))
             (metadata (funcall table "" nil 'metadata))
             (sort-fn (cdr (assq 'display-sort-function (cdr metadata)))))
        (should (equal (funcall sort-fn
                                '("Beta Agent @ beta" "Alpha Agent @ alpha"))
                       '("Alpha Agent @ alpha" "Beta Agent @ beta")))))))

(ert-deftest agent-shell-vertico-maybe-resolve-viewport-returns-shell-when-nil ()
  "When `agent-shell-prefer-viewport-interaction' is nil, return the shell buffer."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/" '((:session . ((:id . "a"))))))
    (let ((agent-shell-prefer-viewport-interaction nil))
      (should (eq (agent-shell-vertico--maybe-resolve-viewport alpha) alpha)))))

(ert-deftest agent-shell-vertico-maybe-resolve-viewport-returns-viewport-when-t ()
  "When `agent-shell-prefer-viewport-interaction' is t, return the viewport buffer."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/" '((:session . ((:id . "a")))))
       (vp "Alpha Agent @ alpha [viewport]" "/tmp/alpha/" nil))
    (let ((agent-shell-prefer-viewport-interaction t)
          (agent-shell-test-viewport-buffer vp))
      (should (eq (agent-shell-vertico--maybe-resolve-viewport alpha) vp)))))

(ert-deftest agent-shell-vertico-embark-setup-registers-default-action-override ()
  (let ((embark-keymap-alist nil)
        (embark-default-action-overrides nil)
        (embark-target-finders nil))
    (agent-shell-vertico-setup-embark)
    (should (eq (cdr (assq 'agent-shell-session
                           embark-default-action-overrides))
                #'agent-shell-vertico--display-session))))

(ert-deftest agent-shell-vertico-display-session-displays-shell-when-no-viewport-pref ()
  "`--display-session' displays the shell buffer when viewport pref is nil."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/" '((:session . ((:id . "a"))))))
    (let ((agent-shell-prefer-viewport-interaction nil))
      (agent-shell-vertico--display-session (buffer-name alpha))
      (should (eq agent-shell-test-displayed-buffer alpha)))))

(ert-deftest agent-shell-vertico-display-session-displays-viewport-when-pref-t ()
  "`--display-session' displays the viewport buffer when viewport pref is t."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/" '((:session . ((:id . "a")))))
       (vp "Alpha Agent @ alpha [viewport]" "/tmp/alpha/" nil))
    (let ((agent-shell-prefer-viewport-interaction t)
          (agent-shell-test-viewport-buffer vp))
      (agent-shell-vertico--display-session (buffer-name alpha))
      (should (eq agent-shell-test-displayed-buffer vp)))))

(ert-deftest agent-shell-vertico-live-session-buffer-finds-active-session ()
  "A live buffer is found by its active session id."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/" '((:session . ((:id . "a")))))
       (beta "Beta Agent @ beta" "/tmp/beta/" '((:session . ((:id . "b"))))))
    (let ((agent-shell-test-buffers (list alpha beta)))
      (should (eq (agent-shell-vertico--live-session-buffer "b") beta))
      (should (null (agent-shell-vertico--live-session-buffer "gone"))))))

(ert-deftest agent-shell-vertico-live-session-buffer-finds-resuming-session ()
  "A session still resuming is found through `:resume-session-id'.

The active `:session :id' is stamped only once the asynchronous
resume finishes, so a second jump to the same link must match the
pending resume rather than start another shell."
  (agent-shell-vertico-tests--with-session-buffers
      ((resuming "Alpha Agent @ alpha" "/tmp/alpha/"
                 '((:resume-session-id . "a"))))
    (let ((agent-shell-test-buffers (list resuming)))
      (should (eq (agent-shell-vertico--live-session-buffer "a")
                  resuming)))))

(ert-deftest agent-shell-vertico-sort-by-status-ready-before-starting ()
  (agent-shell-vertico-tests--with-session-buffers
      ((starting "Starting Agent @ start" "/tmp/start/" nil)
       (ready "Ready Agent @ ready" "/tmp/ready/"
              '((:session . ((:id . "r"))))))
    (let ((agent-shell-test-buffers (list starting ready))
          (agent-shell-vertico-sort-by 'status))
      (let* ((table (agent-shell-vertico--completion-table 'all))
             (metadata (funcall table "" nil 'metadata))
             (sort-fn (cdr (assq 'display-sort-function (cdr metadata)))))
        (should (equal (funcall sort-fn
                                '("Starting Agent @ start" "Ready Agent @ ready"))
                       '("Ready Agent @ ready" "Starting Agent @ start")))))))

(ert-deftest agent-shell-vertico-imenu-classifies-fragments ()
  ;; Agent messages are always included; so are navigatable non-infra blocks.
  (should (agent-shell-vertico--imenu-included-p "1-3-agent_message_chunk" nil))
  (should (agent-shell-vertico--imenu-included-p "1-call_abc" t))
  (should (agent-shell-vertico--imenu-included-p "1-2-agent_thought_chunk" t))
  ;; Excluded: non-navigatable non-message, infrastructure, and noise.
  (should-not (agent-shell-vertico--imenu-included-p "1-call_abc" nil))
  (should-not (agent-shell-vertico--imenu-included-p "bootstrapping-starting" t))
  (should-not (agent-shell-vertico--imenu-included-p "1-unhandled-notification" t))
  ;; Message detection and interaction id.
  (should (agent-shell-vertico--imenu-message-p "1-3-agent_message_chunk"))
  (should-not (agent-shell-vertico--imenu-message-p "1-call_abc"))
  (should (equal (agent-shell-vertico--imenu-interaction
                  "12-3-agent_message_chunk")
                 "12")))

(ert-deftest agent-shell-vertico-imenu-only-final-message-is-response ()
  (with-temp-buffer
    ;; Interaction 1 narrates, runs a tool, then answers; interaction 2 answers.
    (agent-shell-vertico-tests--insert-block
     :qid "1-1-agent_message_chunk" :body "Let me start" :navigatable nil)
    (agent-shell-vertico-tests--insert-block
     :qid "1-call_a" :label-left "completed read" :label-right "Read foo"
     :body "x" :navigatable t)
    (agent-shell-vertico-tests--insert-block
     :qid "1-3-agent_message_chunk" :body "Final answer one" :navigatable nil)
    (agent-shell-vertico-tests--insert-block
     :qid "2-5-agent_message_chunk" :body "Final answer two" :navigatable nil)
    (let* ((index (agent-shell-vertico--imenu-index))
           (activity (mapcar #'car (cdr (assoc "Activity" index))))
           (response (mapcar #'car (cdr (assoc "Response" index)))))
      ;; Intermediate narration and the tool are Activity; the last message
      ;; chunk of each interaction is the Response.
      (should (equal activity '("Let me start" "Read foo")))
      (should (equal response '("Final answer one" "Final answer two"))))))

(ert-deftest agent-shell-vertico-imenu-index-groups-activity-and-response ()
  (with-temp-buffer
    (agent-shell-vertico-tests--insert-block
     :qid "1-call_abc" :label-left "completed read"
     :label-right "Read README.org" :body "file contents" :navigatable t)
    (agent-shell-vertico-tests--insert-block
     :qid "1-2-agent_thought_chunk" :label-left "Thinking"
     :body "Let me look at the config\nand more" :navigatable t)
    (agent-shell-vertico-tests--insert-block
     :qid "1-plan" :label-left "Plan"
     :body "1. step one\n2. step two" :navigatable t)
    (agent-shell-vertico-tests--insert-block
     :qid "1-3-agent_message_chunk" :body "Here is the final answer"
     :navigatable nil)
    ;; Excluded noise: bootstrapping infra (navigatable) and an error
    ;; (not navigatable).
    (agent-shell-vertico-tests--insert-block
     :qid "bootstrapping-starting" :label-left "Starting agent"
     :body "Creating client" :navigatable t)
    (agent-shell-vertico-tests--insert-block
     :qid "1-Error" :body "boom" :navigatable nil)
    (let* ((index (agent-shell-vertico--imenu-index))
           (activity (cdr (assoc "Activity" index)))
           (response (cdr (assoc "Response" index))))
      (should (equal (mapcar #'car activity)
                     '("Read README.org"
                       "Let me look at the config"
                       "1. step one")))
      (should (equal (mapcar #'car response)
                     '("Here is the final answer")))
      (should (integerp (cdr (car activity))))
      ;; No requests outside `agent-shell-mode'.
      (should-not (assoc "Request" index)))))

(ert-deftest agent-shell-vertico-imenu-flattens-group-members-into-activity ()
  (with-temp-buffer
    ;; An activity-group header, its two tool-call members, then an
    ;; ungrouped plan and the interaction's final message.
    (agent-shell-vertico-tests--insert-block
     :qid "1-activity-0" :kind 'group :label-left "✓ Tool calls 2/2")
    (agent-shell-vertico-tests--insert-block
     :qid "1-call_a" :group-id "1-activity-0" :label-left "completed read"
     :label-right "Read README.org" :body "contents" :navigatable t)
    (agent-shell-vertico-tests--insert-block
     :qid "1-call_b" :group-id "1-activity-0" :label-left "completed edit"
     :label-right "Edit init.el" :body "diff" :navigatable t)
    (agent-shell-vertico-tests--insert-block
     :qid "1-plan" :label-left "Plan" :body "1. step one" :navigatable t)
    (agent-shell-vertico-tests--insert-block
     :qid "1-3-agent_message_chunk" :body "Final answer" :navigatable nil)
    (let* ((index (agent-shell-vertico--imenu-index))
           (activity (cdr (assoc "Activity" index)))
           (response (mapcar #'car (cdr (assoc "Response" index))))
           (group (assoc "✓ Tool calls 2/2" activity)))
      ;; The header and each member are selectable entries in one stream.
      (should group)
      (should (integerp (cdr group)))
      (should (equal (mapcar #'car activity)
                     '("✓ Tool calls 2/2"
                       "↳ Read README.org"
                       "↳ Edit init.el"
                       "1. step one")))
      ;; Members carry real buffer positions and their status annotation.
      (let ((member (nth 1 activity)))
        (should (integerp (cdr member)))
        (should (string-match-p
                 "completed read"
                 (agent-shell-vertico--imenu-annotation (car member)))))
      (should (equal response '("Final answer"))))))

(ert-deftest agent-shell-vertico-imenu-drops-empty-group-header ()
  (with-temp-buffer
    ;; A header whose only would-be member is excluded noise contributes
    ;; no submenu.
    (agent-shell-vertico-tests--insert-block
     :qid "1-activity-0" :kind 'group :label-left "Activity")
    (agent-shell-vertico-tests--insert-block
     :qid "1-Error" :group-id "1-activity-0" :body "boom" :navigatable nil)
    (should-not (agent-shell-vertico--imenu-index))))

(ert-deftest agent-shell-vertico-imenu-index-empty-without-items ()
  (with-temp-buffer
    (agent-shell-vertico-tests--insert-block
     :qid "1-permission-x" :label-left "Allow?" :body "..." :navigatable nil)
    (should-not (agent-shell-vertico--imenu-index))))

(ert-deftest agent-shell-vertico-imenu-requests-grouped-in-shell-mode ()
  (with-temp-buffer
    (agent-shell-mode)
    (setq-local imenu-generic-expression '((nil "^> \\(.*\\)$" 1)))
    (insert "> first request\nresponse text\n> second request\nmore\n")
    (let* ((index (agent-shell-vertico--imenu-index))
           (requests (mapcar #'car (cdr (assoc "Request" index)))))
      (should (= 2 (length requests)))
      (should (member "first request" requests))
      (should (member "second request" requests)))))

(ert-deftest agent-shell-vertico-imenu-annotation-only-for-our-candidates ()
  "Foreign candidates fall through to marginalia's own imenu annotator.
Marginalia consults only the first annotator registered for a category,
so returning nil here would leave every other mode's imenu unannotated."
  (should (equal (agent-shell-vertico--imenu-annotation "plain imenu item")
                 (marginalia-annotate-imenu "plain imenu item")))
  (with-temp-buffer
    (agent-shell-vertico-tests--insert-block
     :qid "1-call_abc" :label-left "completed read"
     :label-right "Read README.org" :body "x\ny\nz" :navigatable t)
    (let* ((index (agent-shell-vertico--imenu-index))
           (candidate (car (car (cdr (assoc "Activity" index)))))
           (annotation (agent-shell-vertico--imenu-annotation candidate)))
      (should (stringp annotation))
      (should (string-match-p "completed read" annotation)))))

(ert-deftest agent-shell-vertico-imenu-preserves-configured-annotator ()
  "Foreign imenu candidates retain the annotator active before setup."
  (let ((marginalia-annotators
         '((imenu agent-shell-vertico-tests--custom-imenu builtin none)))
        (agent-shell-vertico--imenu-fallback-annotator nil))
    (cl-letf (((symbol-function 'agent-shell-vertico-tests--custom-imenu)
               (lambda (candidate) (concat " custom:" candidate))))
      ;; Repeated setup must neither duplicate the category nor capture the
      ;; wrapper itself as its fallback.
      (agent-shell-vertico-setup-imenu)
      (agent-shell-vertico-setup-imenu)
      (should (= 1 (length (seq-filter
                            (lambda (entry) (eq (car entry) 'imenu))
                            marginalia-annotators))))
      (should (eq (cadr (assq 'imenu marginalia-annotators))
                  #'agent-shell-vertico--imenu-annotation))
      (should (equal (agent-shell-vertico--imenu-annotation "foreign")
                     " custom:foreign")))))

(ert-deftest agent-shell-vertico-imenu-setup-installs-index-function ()
  (with-temp-buffer
    (agent-shell-vertico--imenu-setup)
    (should (eq imenu-create-index-function
                #'agent-shell-vertico--imenu-index))
    (should imenu-auto-rescan)
    ;; imenu's own hard truncation is disabled so our ellipsized truncation
    ;; is authoritative.
    (should (null imenu-max-item-length))
    (should (local-variable-p 'imenu-after-jump-hook))
    (should (memq #'agent-shell-vertico--imenu-reveal-at-point
                  imenu-after-jump-hook))))

(ert-deftest agent-shell-vertico-setup-imenu-adds-mode-hooks ()
  (let ((agent-shell-mode-hook nil)
        (agent-shell-viewport-view-mode-hook nil))
    (agent-shell-vertico-setup-imenu)
    (should (memq #'agent-shell-vertico--imenu-setup agent-shell-mode-hook))
    (should (memq #'agent-shell-vertico--imenu-setup
                  agent-shell-viewport-view-mode-hook))))

(ert-deftest agent-shell-vertico-imenu-truncate-breaks-on-word-boundary ()
  (should (equal (agent-shell-vertico--imenu-truncate "short title") "short title"))
  (let* ((agent-shell-vertico-imenu-name-width 50)
         (long (mapconcat #'identity (make-list 30 "wordy") " "))
         (out (agent-shell-vertico--imenu-truncate long)))
    (should (string-suffix-p "…" out))
    (should (<= (length out) (1+ agent-shell-vertico-imenu-name-width)))
    (let ((head (substring out 0 (1- (length out)))))
      ;; The kept text is a whole-word prefix: it is followed by a space in
      ;; the original (we cut at a word boundary) and has no trailing space.
      (should (string-prefix-p (concat head " ") long))
      (should-not (string-suffix-p " " head)))))

(ert-deftest agent-shell-vertico-imenu-truncate-counts-display-columns ()
  "Wide characters count as the columns they occupy, not one each.
`agent-shell-vertico-imenu-name-width' exists to keep names clear of the
annotations, which a title of CJK text would otherwise overrun twice
over."
  (let* ((agent-shell-vertico-imenu-name-width 10)
         (wide (make-string 8 ?漢))
         (out (agent-shell-vertico--imenu-truncate wide)))
    (should (< (string-width out) (string-width wide)))
    (should (<= (string-width out) 10))
    (should (string-suffix-p "…" out))))

;;; Markdown links

(ert-deftest agent-shell-vertico-markdown-link-target-returns-url-and-bounds ()
  (with-temp-buffer
    (insert "see ")
    (let ((beg (point)) end)
      (insert "the config")
      (setq end (point))
      (put-text-property beg end 'agent-shell-markdown-url "file:foo.el#L10")
      (insert " now")
      (goto-char (1+ beg))
      (should (equal (agent-shell-vertico--markdown-link-target)
                     `(agent-shell-url "file:foo.el#L10" ,beg . ,end))))))

(ert-deftest agent-shell-vertico-markdown-link-target-nil-off-link ()
  (with-temp-buffer
    (insert "plain text")
    (goto-char (point-min))
    (should-not (agent-shell-vertico--markdown-link-target))))

(ert-deftest agent-shell-vertico-open-markdown-link-dispatches-to-opener ()
  (let ((agent-shell-test-opened-link nil)
        (agent-shell-test-file-display-action nil)
        (agent-shell-file-display-action 'default-action))
    (agent-shell-vertico-open-markdown-link "file:foo.el#L10")
    (should (equal agent-shell-test-opened-link "file:foo.el#L10"))
    (should (eq agent-shell-test-file-display-action 'default-action))))

(ert-deftest agent-shell-vertico-open-markdown-link-other-window-pops-up-a-window ()
  (let ((agent-shell-test-opened-link nil)
        (agent-shell-test-file-display-action nil)
        (agent-shell-file-display-action 'default-action))
    (agent-shell-vertico-open-markdown-link-other-window "file:foo.el#L10")
    (should (equal agent-shell-test-opened-link "file:foo.el#L10"))
    (should (equal agent-shell-test-file-display-action
                   '(display-buffer-pop-up-window)))
    (should (eq agent-shell-file-display-action 'default-action))))

(ert-deftest agent-shell-vertico-open-markdown-link-externally-resolves-file-link ()
  "A file link reaches Embark as a plain path, without its `#Lnnn' line."
  (let ((file (make-temp-file "agent-shell-vertico-link"))
        opened)
    (unwind-protect
        (cl-letf (((symbol-function 'embark-open-externally)
                   (lambda (arg) (setq opened arg)))
                  ((symbol-function 'find-file)
                   (lambda (&rest _) (error "Link must not open inside Emacs"))))
          (agent-shell-vertico-open-markdown-link-externally
           (concat "file://" file "#L10"))
          (should (equal opened file)))
      (delete-file file))))

(ert-deftest agent-shell-vertico-open-markdown-link-externally-resolves-relative-file-link ()
  "A relative `file:' link resolves against `default-directory'."
  (let* ((dir (file-name-as-directory (make-temp-file "agent-shell-vertico" t)))
         (file (expand-file-name "note.txt" dir))
         opened)
    (unwind-protect
        (progn
          (write-region "" nil file)
          (cl-letf (((symbol-function 'embark-open-externally)
                     (lambda (arg) (setq opened arg))))
            (let ((default-directory dir))
              (agent-shell-vertico-open-markdown-link-externally
               "file:note.txt#L3"))
            (should (equal opened file))))
      (delete-directory dir t))))

(ert-deftest agent-shell-vertico-open-markdown-link-externally-passes-url-through ()
  (let (opened)
    (cl-letf (((symbol-function 'embark-open-externally)
               (lambda (arg) (setq opened arg))))
      (agent-shell-vertico-open-markdown-link-externally "https://example.com")
      (should (equal opened "https://example.com")))))

(ert-deftest agent-shell-vertico-copy-markdown-link-kills-url ()
  (let ((kill-ring nil))
    (agent-shell-vertico-copy-markdown-link "file:foo.el#L10")
    (should (equal (current-kill 0) "file:foo.el#L10"))))

(ert-deftest agent-shell-vertico-embark-setup-registers-markdown-link-support ()
  (let ((embark-keymap-alist nil)
        (embark-default-action-overrides nil)
        (embark-target-finders nil))
    (agent-shell-vertico-setup-embark)
    (should (equal (assq 'agent-shell-url embark-keymap-alist)
                   '(agent-shell-url agent-shell-vertico-markdown-link-map)))
    (should (eq (cdr (assq 'agent-shell-url embark-default-action-overrides))
                #'agent-shell-vertico-open-markdown-link))
    (should (memq #'agent-shell-vertico--markdown-link-target
                  embark-target-finders))
    (should (eq (lookup-key agent-shell-vertico-markdown-link-map (kbd "o"))
                #'agent-shell-vertico-open-markdown-link-other-window))
    (should (eq (lookup-key agent-shell-vertico-markdown-link-map (kbd "x"))
                #'agent-shell-vertico-open-markdown-link-externally))
    (should (eq (lookup-key agent-shell-vertico-markdown-link-map (kbd "w"))
                #'agent-shell-vertico-copy-markdown-link))))

(ert-deftest agent-shell-vertico-loading-does-not-prebind-embark-target-finders ()
  "Loading the package must not bind `embark-target-finders'.
Same constraint as `embark-keymap-alist': a top-level `defvar' with a
value would pre-bind it, clobbering embark's own default finder list."
  (skip-unless (not (featurep 'embark)))
  (should-not (boundp 'embark-target-finders)))

;;; Transcripts

(ert-deftest agent-shell-vertico-transcript-directory-uses-agent-shell-resolver ()
  (let* ((project-root (make-temp-file "agent-shell-vertico-project-" t))
         (expected (expand-file-name "custom/transcripts" project-root))
         (agent-shell-dot-subdir-function
          (lambda (subdir)
            (should (equal subdir "transcripts"))
            (should (equal default-directory
                           (file-name-as-directory project-root)))
            expected)))
    (unwind-protect
        (progn
          (should
           (equal
            (agent-shell-vertico-transcript--directory project-root)
            expected))
          (should-not (file-exists-p expected)))
      (delete-directory project-root t))))

(ert-deftest agent-shell-vertico-transcript-project-roots-prefer-projectile ()
  (cl-progv
      '(projectile-mode projectile-current-project-on-switch)
      '(t remove)
    (cl-letf (((symbol-function 'projectile-project-root)
               (lambda (&optional _dir) "/work/current/"))
              ((symbol-function 'projectile-relevant-known-projects)
               (lambda ()
                 (should (eq projectile-current-project-on-switch 'keep))
                 '("/work/beta/" "/work/current/" "/work/beta/")))
              ((symbol-function 'project-known-project-roots)
               (lambda () (ert-fail "project.el fallback was used"))))
      (should
       (equal (agent-shell-vertico-transcript--project-roots)
              '("/work/current/" "/work/beta/"))))))

(ert-deftest agent-shell-vertico-transcript-project-roots-fall-back-to-project-el ()
  (let ((projectile-mode nil))
    (cl-letf (((symbol-function 'project-current)
               (lambda (&optional _maybe-prompt _dir)
                 'project))
              ((symbol-function 'project-root)
               (lambda (_project) "/work/current/"))
              ((symbol-function 'project-known-project-roots)
               (lambda () '("/work/alpha/" "/work/current/"))))
      (should
       (equal (agent-shell-vertico-transcript--project-roots)
              '("/work/current/" "/work/alpha/"))))))

(ert-deftest agent-shell-vertico-transcript-read-project-resolves-selection ()
  (cl-letf (((symbol-function
              'agent-shell-vertico-transcript--project-roots)
             (lambda () '("/work/project/")))
            ((symbol-function 'completing-read)
             (lambda (_prompt candidates &rest _args)
               (substring-no-properties
                (car (all-completions "" candidates))))))
    (should
     (equal
      (agent-shell-vertico-transcript--read-project)
      "/work/project/"))))

(ert-deftest agent-shell-vertico-transcript-read-record-resolves-selection ()
  (let ((record
         (agent-shell-vertico-transcript-record-create
          :file "/work/project/transcript.md"
          :started "2026-07-31 10:00:00"
          :preview "Fix completion selection")))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt candidates &rest _args)
                 (substring-no-properties
                  (car (all-completions "" candidates))))))
      (should
       (eq
        (agent-shell-vertico-transcript--completing-read-record
         "Transcript: " (list record))
        record)))))

(ert-deftest agent-shell-vertico-transcript-parse-current-markdown-format ()
  (let ((file (make-temp-file "agent-shell-vertico-transcript-" nil ".md")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "# Agent Shell Transcript\n\n"
                    "**Agent:** Codex\n"
                    "**Started:** 2026-07-30 10:20:30\n"
                    "**Working Directory:** /work/project\n"
                    "**Session ID:** provider/session:not-a-uuid\n"
                    "**Model:** gpt-5.6\n\n"
                    "---\n\n"
                    "## User (2026-07-30 10:20:31)\n\n"
                    "Find the viewport history implementation\n\n"
                    "## Agent (2026-07-30 10:21:00)\n\n"
                    "It is here.\n"))
          (let ((record
                 (agent-shell-vertico-transcript--parse-file
                  file "/work/project/")))
            (should
             (equal
              (agent-shell-vertico-transcript-record-agent record)
              "Codex"))
            (should
             (equal
              (agent-shell-vertico-transcript-record-session-id record)
              "provider/session:not-a-uuid"))
            (should
             (equal
              (agent-shell-vertico-transcript-record-working-directory record)
              "/work/project/"))
            (should
             (equal
              (agent-shell-vertico-transcript-record-preview record)
              "Find the viewport history implementation"))))
      (delete-file file))))

(ert-deftest agent-shell-vertico-transcript-parse-title-header ()
  (let ((file (make-temp-file "agent-shell-vertico-transcript-" nil ".md")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "# Agent Shell Transcript\n\n"
                    "**Agent:** Claude\n"
                    "**Started:** 2026-08-04 10:43:15\n"
                    "**Working Directory:** /work/project\n"
                    "**Session ID:** abc-123\n"
                    "**Title:** Understand session list display\n\n"
                    "---\n\n"
                    "## User (2026-08-04 10:43:15)\n\n"
                    "In agent-shell-vertico-transcript.el\n\n"
                    ;; The body quotes a header field; it must not be read
                    ;; as this transcript's own title.
                    "**Title:** quoted from somewhere else\n"))
          (let ((record
                 (agent-shell-vertico-transcript--parse-file
                  file "/work/project/")))
            (should
             (equal
              (agent-shell-vertico-transcript-record-title record)
              "Understand session list display"))
            (should
             (equal
              (agent-shell-vertico-transcript-record-preview record)
              "In agent-shell-vertico-transcript.el"))))
      (delete-file file))))

(ert-deftest agent-shell-vertico-transcript-parse-ignores-quoted-headers ()
  "Header fields are read from the header only.

Agents echo files and older transcripts, so bodies carry lines shaped
like a header field.  Reading one as this transcript's own field would
label it with someone else's agent or title."
  (let ((file (make-temp-file "agent-shell-vertico-transcript-" nil ".md")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "# Agent Shell Transcript\n\n"
                    "**Started:** 2026-08-04 10:43:15\n"
                    "**Working Directory:** /work/project\n\n"
                    "---\n\n"
                    "## User (2026-08-04 10:43:15)\n\n"
                    "Here is an older transcript:\n\n"
                    "**Agent:** Kiro\n"
                    "**Title:** someone else's session\n"
                    "**Session ID:** quoted-id\n"))
          (let ((record
                 (agent-shell-vertico-transcript--parse-file
                  file "/work/project/")))
            (should-not
             (agent-shell-vertico-transcript-record-agent record))
            (should-not
             (agent-shell-vertico-transcript-record-title record))
            (should-not
             (agent-shell-vertico-transcript-record-session-id record))))
      (delete-file file))))

(ert-deftest agent-shell-vertico-transcript-candidate-prefers-title ()
  (let ((titled
         (agent-shell-vertico-transcript-record-create
          :file "/tmp/transcripts/titled.md"
          :started "2026-08-04 10:43:15"
          :title "Understand session list display"
          :preview "In agent-shell-vertico-transcript.el"))
        (untitled
         (agent-shell-vertico-transcript-record-create
          :file "/tmp/transcripts/untitled.md"
          :started "2026-08-04 10:43:15"
          :preview "In agent-shell-vertico-transcript.el")))
    ;; The title is the candidate, with no timestamp: the list is ordered
    ;; by last change and the annotation carries the times.
    (should
     (equal
      (substring-no-properties
       (agent-shell-vertico-transcript--record-candidate titled 0))
      (concat "Understand session list display"
              (agent-shell-vertico--candidate-key 0))))
    ;; Without a title the first user message stands in.
    (should
     (equal
      (substring-no-properties
       (agent-shell-vertico-transcript--record-candidate untitled 0))
      (concat "In agent-shell-vertico-transcript.el"
              (agent-shell-vertico--candidate-key 0))))))

(ert-deftest agent-shell-vertico-transcript-candidates-stay-distinct ()
  "Records sharing a title must stay separately selectable.

Completion collapses candidates with equal text, so two sessions an
agent gave the same summary would leave one of them unreachable."
  (let* ((first-record
          (agent-shell-vertico-transcript-record-create
           :file "/tmp/transcripts/first.md"
           :title "Set up emacsclient configuration"))
         (second-record
          (agent-shell-vertico-transcript-record-create
           :file "/tmp/transcripts/second.md"
           :title "Set up emacsclient configuration"))
         (candidates
          (agent-shell-vertico-transcript--record-candidates
           (list first-record second-record) 200)))
    (should (= (length candidates) 2))
    ;; The strings differ, so neither candidate is collapsed.
    (should-not
     (equal (substring-no-properties (nth 0 candidates))
            (substring-no-properties (nth 1 candidates))))
    ;; What the user reads is the same title for both.
    (should
     (equal
      (mapcar
       (lambda (candidate)
         (replace-regexp-in-string
          "[\x100000-\x10fffd]+\\'" ""
          (substring-no-properties candidate)))
       candidates)
      '("Set up emacsclient configuration"
        "Set up emacsclient configuration")))
    ;; Each candidate still resolves to its own record.
    (should
     (eq (agent-shell-vertico-transcript--record-from-candidate
          (nth 1 candidates))
         second-record))))

(ert-deftest agent-shell-vertico-transcript-read-record-resolves-same-title ()
  "Selecting the second of two same-titled records returns that record."
  (let* ((first-record
          (agent-shell-vertico-transcript-record-create
           :file "/tmp/transcripts/first.md"
           :title "Set up emacsclient configuration"))
         (second-record
          (agent-shell-vertico-transcript-record-create
           :file "/tmp/transcripts/second.md"
           :title "Set up emacsclient configuration")))
    ;; A completion UI that preserves text properties, which is what
    ;; `minibuffer-allow-text-properties' buys.
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt candidates &rest _args)
                 (nth 1 (all-completions "" candidates)))))
      (should
       (eq
        (agent-shell-vertico-transcript--completing-read-record
         "Transcript: " (list first-record second-record))
        second-record)))
    ;; A UI that strips them still resolves, because the candidate
    ;; strings themselves are distinct.
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt candidates &rest _args)
                 (substring-no-properties
                  (nth 1 (all-completions "" candidates))))))
      (should
       (eq
        (agent-shell-vertico-transcript--completing-read-record
         "Transcript: " (list first-record second-record))
        second-record)))))

(ert-deftest agent-shell-vertico-transcript-annotation-orders-columns ()
  "Annotation columns run from most to least identifying."
  (let* ((record
          (agent-shell-vertico-transcript-record-create
           :file "/tmp/transcripts/session.md"
           :project-name "agent-shell-vertico"
           :agent "Claude"
           :session-id "abc-123"
           :title "Understand session list display"
           :preview "In agent-shell-vertico-transcript.el"
           :started "2026-08-04 10:43:15"
           :modified-time (encode-time 30 45 19 4 8 2026)))
         (candidate
          (agent-shell-vertico-transcript--record-candidate record 0))
         (annotation
          (substring-no-properties
           (agent-shell-vertico-transcript--record-annotation candidate))))
    ;; Assert the order the values appear in, not the padding between
    ;; them: an earlier version of this test pinned the exact string the
    ;; marginalia stub produced, which is what let the compiled package
    ;; lose its padding and faces unnoticed.
    (let ((positions
           (mapcar (lambda (value) (string-match-p (regexp-quote value)
                                                   annotation))
                   (list "agent-shell-vertico"
                         "Claude"
                         "Resumable"
                         (marginalia--time-relative
                          (encode-time 30 45 19 4 8 2026))
                         "2026-08-04 10:43"))))
      (should (seq-every-p #'identity positions))
      (should (equal positions (sort (copy-sequence positions) #'<))))))

(ert-deftest agent-shell-vertico-transcript-annotation-omits-first-message ()
  "The first user message is not a column.

It used to claim up to a third of the row.  The candidate itself shows it
whenever a transcript has no title, and the reader shows it in full."
  (let* ((record
          (agent-shell-vertico-transcript-record-create
           :file "/tmp/transcripts/session.md"
           :project-name "agent-shell-vertico"
           :agent "Claude"
           :session-id "abc-123"
           :title "Understand session list display"
           :preview "In agent-shell-vertico-transcript.el"
           :started "2026-08-04 10:43:15"
           :modified-time (encode-time 30 45 19 4 8 2026)))
         (candidate
          (agent-shell-vertico-transcript--record-candidate record 0))
         (annotation
          (substring-no-properties
           (agent-shell-vertico-transcript--record-annotation candidate))))
    (should-not
     (string-match-p "In agent-shell-vertico-transcript" annotation))))

(defun agent-shell-vertico-tests--annotation-for (project-name)
  "Return the annotation of a record named PROJECT-NAME."
  (agent-shell-vertico-transcript--record-annotation
   (agent-shell-vertico-transcript--record-candidate
    (agent-shell-vertico-transcript-record-create
     :file "/tmp/transcripts/session.md"
     :project-name project-name
     :agent "Claude"
     :session-id "abc-123"
     :title "Bootstrap the eval harness"
     :started "2025-04-11 09:03:22"
     :modified-time (encode-time 30 45 19 4 8 2026))
    0)))

(ert-deftest agent-shell-vertico-transcript-annotation-columns-line-up ()
  "Every column starts at the same offset whatever the project is called.

The columns are padded here rather than by `marginalia--fields', which is
a macro: compiling this package against the marginalia test stub would
otherwise freeze the stub's plain concatenation into the compiled file,
and every annotation would lose its padding, faces and alignment."
  (let* ((short (substring-no-properties
                 (agent-shell-vertico-tests--annotation-for "lyra")))
         (long (substring-no-properties
                (agent-shell-vertico-tests--annotation-for
                 "agent-shell-vertico"))))
    (should (equal (string-match-p "Claude" short)
                   (string-match-p "Claude" long)))
    (should (equal (string-match-p "Resumable" short)
                   (string-match-p "Resumable" long)))))

(ert-deftest agent-shell-vertico-transcript-annotation-carries-faces ()
  "Each column keeps the face that tells it apart from its neighbours."
  (let ((annotation (agent-shell-vertico-tests--annotation-for "lyra")))
    (should (eq (get-text-property (string-match-p "lyra" annotation)
                                   'face annotation)
                'marginalia-value))
    (should (eq (get-text-property (string-match-p "Resumable" annotation)
                                   'face annotation)
                'marginalia-type))))

(ert-deftest agent-shell-vertico-transcript-annotation-marks-alignment ()
  "The annotation carries the marker marginalia aligns candidates by."
  (let ((annotation (agent-shell-vertico-tests--annotation-for "lyra")))
    (should (get-text-property 0 'marginalia--align annotation))))

(ert-deftest agent-shell-vertico-transcript-annotation-keeps-change-relative ()
  "The last change stays a relative age however old the transcript is.

`marginalia--time' switches to an absolute stamp after two weeks, which
put two absolute times beside each other and made the last change and the
start time hard to tell apart."
  (let* ((record
          (agent-shell-vertico-transcript-record-create
           :file "/tmp/transcripts/session.md"
           :project-name "lyra-ask-hcp-eval"
           :agent "Claude"
           :session-id "abc-123"
           :title "Bootstrap the eval harness"
           :started "2025-04-11 09:03:22"
           :modified-time (time-subtract (current-time)
                                         (days-to-time 400))))
         (candidate
          (agent-shell-vertico-transcript--record-candidate record 0))
         (annotation
          (substring-no-properties
           (agent-shell-vertico-transcript--record-annotation candidate))))
    (should (string-match-p " ago " annotation))
    (should (string-suffix-p "2025-04-11 09:03" annotation))))

(ert-deftest agent-shell-vertico-transcript-candidate-width-fits-annotation ()
  "A candidate never pushes the annotation past the right edge.

Marginalia starts the annotation at the widest candidate rounded up to a
multiple of ten and never checks that the annotation still fits, so an
unbounded title left every column off screen."
  (dolist (window '(236 120 100))
    (let ((width (agent-shell-vertico-transcript--candidate-width window))
          (annotation
           (agent-shell-vertico-transcript--annotation-width window)))
      ;; One column short of a multiple of ten, because the invisible key
      ;; character counts toward the candidate width.
      (should (zerop (% (1+ width) 10)))
      (should (<= (+ width 1 annotation) window)))))

(ert-deftest agent-shell-vertico-transcript-project-column-fits-a-name ()
  "The project column shows an ordinary repository name whole.

Names of about twenty characters are the common case, and the column
used to cut them at sixteen on a wide frame."
  (let* ((field (min (/ 236 2) marginalia-field-width))
         (columns
          (round (* (agent-shell-vertico-transcript--column-width 'project)
                    field))))
    (should (>= columns 20))))

(ert-deftest agent-shell-vertico-transcript-candidate-width-has-a-floor ()
  "A window too narrow for both keeps the candidate readable.
The annotation is cut there rather than the title shrinking to nothing."
  (should (= (agent-shell-vertico-transcript--candidate-width 40) 19)))

(ert-deftest agent-shell-vertico-transcript-candidate-cut-to-width ()
  "A long candidate is cut to its budget and keeps the full text to hand."
  (let* ((title
          (concat "Investigate why for this pair of comparison between raw "
                  "subagent and previous subagent implementation, i think "
                  "this is a systematic issue with subagent design"))
         (record
          (agent-shell-vertico-transcript-record-create
           :file "/tmp/transcripts/session.md"
           :title title))
         (candidate
          (agent-shell-vertico-transcript--record-candidate record 0 39))
         (text
          (replace-regexp-in-string
           "[\x100000-\x10fffd]+\\'" ""
           (substring-no-properties candidate))))
    (should (<= (string-width text) 39))
    (should (string-prefix-p "Investigate why for this pair" text))
    (should (< (string-width text) (string-width title)))
    ;; The whole title stays reachable, which is what `help-echo' is for.
    (should (equal (get-text-property 0 'help-echo candidate) title))))

(ert-deftest agent-shell-vertico-transcript-annotation-falls-back-to-file-time ()
  "A transcript with no start header shows its file time as created."
  (let* ((record
          (agent-shell-vertico-transcript-record-create
           :file "/tmp/transcripts/session.md"
           :project-name "project"
           :preview "Hello"
           :modified-time (encode-time 30 45 19 4 8 2026)))
         (candidate
          (agent-shell-vertico-transcript--record-candidate record 0))
         (annotation
          (substring-no-properties
           (agent-shell-vertico-transcript--record-annotation candidate))))
    (should (string-suffix-p "2026-08-04 19:45" annotation))))

(ert-deftest agent-shell-vertico-transcript-marginalia-annotator-registered ()
  (should
   (equal
    (alist-get 'agent-shell-transcript marginalia-annotators)
    '(agent-shell-vertico-transcript--record-annotation none))))

(ert-deftest agent-shell-vertico-transcript-records-filter-shared-directory ()
  (let* ((root (make-temp-file "agent-shell-vertico-root-" t))
         (other-root (make-temp-file "agent-shell-vertico-other-" t))
         (transcript-dir (make-temp-file "agent-shell-vertico-shared-" t))
         (agent-shell-dot-subdir-function (lambda (_subdir) transcript-dir)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "matching.md" transcript-dir)
            (insert (format "**Working Directory:** %s\n"
                            (directory-file-name root))
                    "**Session ID:** matching\n\n---\n\n"
                    "## User\n\nMatching transcript\n"))
          (with-temp-file (expand-file-name "other.md" transcript-dir)
            (insert (format "**Working Directory:** %s\n"
                            (directory-file-name other-root))
                    "**Session ID:** other\n\n---\n\n"
                    "## User\n\nOther transcript\n"))
          (let ((records
                 (agent-shell-vertico-transcript--records-for-project root)))
            (should (= (length records) 1))
            (should
             (equal
              (agent-shell-vertico-transcript-record-session-id
               (car records))
              "matching"))))
      (delete-directory root t)
      (delete-directory other-root t)
      (delete-directory transcript-dir t))))

(ert-deftest agent-shell-vertico-transcript-records-keep-local-stale-and-subdir ()
  "A project-local store identifies its project despite header path drift."
  (let* ((root (make-temp-file "agent-shell-vertico-root-" t))
         (transcript-dir (expand-file-name ".agent-shell/transcripts" root))
         (subdir (expand-file-name "packages/api" root))
         (agent-shell-dot-subdir-function (lambda (_subdir) transcript-dir)))
    (unwind-protect
        (progn
          (make-directory transcript-dir t)
          (dolist (spec `(("stale.md" "/gone/old-machine" "stale")
                          ("subdir.md" ,subdir "subdir")))
            (with-temp-file (expand-file-name (car spec) transcript-dir)
              (insert (format "**Working Directory:** %s\n" (cadr spec))
                      (format "**Session ID:** %s\n\n---\n\n" (caddr spec))
                      "## User\n\nhello\n")))
          (let ((records
                 (agent-shell-vertico-transcript--records-for-project root)))
            (should (= (length records) 2))
            (should (equal
                     (sort (mapcar
                            #'agent-shell-vertico-transcript-record-session-id
                            records)
                           #'string<)
                     '("stale" "subdir")))))
      (delete-directory root t))))

(ert-deftest agent-shell-vertico-transcript-search-maps-project-subdirectory ()
  "Search assigns a shared-store transcript to its most specific project."
  (let* ((root (make-temp-file "agent-shell-vertico-root-" t))
         (nested-root (expand-file-name "packages/api" root))
         (transcript-dir (make-temp-file "agent-shell-vertico-shared-" t))
         (file (expand-file-name "subdir.md" transcript-dir))
         (working-directory (expand-file-name "services/auth" nested-root))
         (agent-shell-dot-subdir-function (lambda (_subdir) transcript-dir)))
    (unwind-protect
        (progn
          (make-directory nested-root t)
          (with-temp-file file
            (insert (format "**Working Directory:** %s\n" working-directory)
                    "**Session ID:** subdir\n\n---\n\n"
                    "## User\n\nneedle\n"))
          (let ((record
                 (agent-shell-vertico-transcript--record-for-match
                  file '(:count 1 :line 6 :text "needle")
                  (list root nested-root))))
            (should record)
            (should
             (agent-shell-vertico-transcript--same-directory-p
              (agent-shell-vertico-transcript-record-project-root record)
              nested-root))))
      (delete-directory root t)
      (delete-directory transcript-dir t))))

(ert-deftest agent-shell-vertico-transcript-current-record-parses-visited-file ()
  "A visited transcript with no record parses itself and takes its project.
The working directory in the header is the project the transcript
belongs to, whatever directory the file happens to be stored in."
  (let ((file (make-temp-file "agent-shell-vertico-transcript" nil ".md"))
        (buffer nil))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "**Agent:** Codex\n"
                    "**Working Directory:** /work/project\n"
                    "**Session ID:** visited\n\n---\n\n"
                    "## User\n\nhello\n"))
          (setq buffer (find-file-noselect file))
          (with-current-buffer buffer
            (let ((record (agent-shell-vertico-transcript--current-record)))
              (should (equal (agent-shell-vertico-transcript-record-session-id
                              record)
                             "visited"))
              (should (equal (agent-shell-vertico-transcript-record-project-name
                              record)
                             "project")))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (delete-file file))))

(ert-deftest agent-shell-vertico-transcript-current-record-requires-transcript ()
  "A buffer visiting no file is not a transcript."
  (with-temp-buffer
    (should-error (agent-shell-vertico-transcript--current-record)
                  :type 'user-error)))

(ert-deftest agent-shell-vertico-transcript-move-to-speaker-reports-the-end ()
  "Running out of headings says so rather than moving point."
  (with-temp-buffer
    (insert "**Agent:** Codex\n\n---\n\n## User\n\nhello\n")
    (goto-char (point-max))
    (should-error (agent-shell-vertico-transcript--move-to-speaker
                   '("User") 1)
                  :type 'user-error)))

(ert-deftest agent-shell-vertico-transcript-resume-current-uses-the-record ()
  "Resuming the current transcript resumes the record that buffer holds."
  (let ((shell-buffer (generate-new-buffer " *agent-shell-vertico-resume*"))
        (agent-shell-prefer-viewport-interaction t)
        (started-arguments nil))
    (unwind-protect
        (with-temp-buffer
          (setq-local agent-shell-vertico-transcript--record
                      (agent-shell-vertico-transcript-record-create
                       :file "/tmp/transcript.md"
                       :agent "Codex"
                       :session-id "current-session"
                       :working-directory "/work/project/"))
          (cl-letf (((symbol-function 'agent-shell--auto-preferred-config)
                     (lambda () '((:buffer-name . "Codex Agent"))))
                    ((symbol-function 'agent-shell--start)
                     (lambda (&rest arguments)
                       (setq started-arguments arguments)
                       shell-buffer))
                    ((symbol-function
                      'agent-shell--display-viewport-when-ready)
                     (lambda (&rest _arguments) nil)))
            (agent-shell-vertico-transcript-force-resume-current)
            (should (equal (plist-get started-arguments :session-id)
                           "current-session"))))
      (kill-buffer shell-buffer))))

(ert-deftest agent-shell-vertico-transcript-rg-match-decodes-byte-lines ()
  "rg reports a line it cannot decode as UTF-8 as base64 bytes.
A transcript holding binary tool output would otherwise stop the search
at the first such match."
  (let* ((line (json-encode
                '((type . "match")
                  (data . ((path . ((text . "/tmp/one.md")))
                           (line_number . 3)
                           (lines . ((bytes . "aGVsbG8gYnl0ZXMK"))))))))
         (entry (agent-shell-vertico-transcript--rg-match-from-json line)))
    (should (equal (car entry) "/tmp/one.md"))
    (should (equal (plist-get (cdr entry) :line) 3))
    (should (equal (plist-get (cdr entry) :text) "hello bytes"))))

(ert-deftest agent-shell-vertico-transcript-rg-match-skips-byte-paths ()
  "A match whose path is not valid UTF-8 is decoded rather than dropped."
  (let* ((line (json-encode
                '((type . "match")
                  (data . ((path . ((bytes . "L3RtcC90d28ubWQ=")))
                           (line_number . 1)
                           (lines . ((text . "hello\n"))))))))
         (entry (agent-shell-vertico-transcript--rg-match-from-json line)))
    (should (equal (car entry) "/tmp/two.md"))
    (should (equal (plist-get (cdr entry) :text) "hello"))))

(ert-deftest agent-shell-vertico-transcript-diagnostics-count-unlisted-files ()
  "The doctor counts transcripts the project filter drops.
A shared store cannot assign a stale Working Directory header to a known
project, and the doctor cannot read those files through the same filter
that omits them."
  (let* ((root (make-temp-file "agent-shell-vertico-root-" t))
         (transcript-dir (make-temp-file "agent-shell-vertico-store-" t))
         (agent-shell-dot-subdir-function (lambda (_subdir) transcript-dir)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "listed.md" transcript-dir)
            (insert (format "**Working Directory:** %s\n"
                            (directory-file-name root))
                    "**Session ID:** listed\n\n---\n\n"
                    "## User\n\nListed transcript\n"))
          (with-temp-file (expand-file-name "stale.md" transcript-dir)
            (insert "**Working Directory:** /gone/old-machine\n"
                    "**Session ID:** stale\n\n---\n\n"
                    "## User\n\nStale transcript\n"))
          (let* ((roots (list root))
                 (records
                  (agent-shell-vertico-transcript--all-records roots)))
            (should (= (length records) 1))
            (should (= (agent-shell-vertico-transcript--unlisted-file-count
                        roots records)
                       1))
            (should
             (seq-find
              (lambda (issue) (string-match-p "not listed" issue))
              (agent-shell-vertico-transcript--diagnostic-issues
               records roots)))))
      (delete-directory root t)
      (delete-directory transcript-dir t))))

(ert-deftest agent-shell-vertico-transcript-diagnostics-describe-missing-header ()
  "An unlisted shared-store file need not have a mismatched header."
  (let* ((root (make-temp-file "agent-shell-vertico-root-" t))
         (transcript-dir (make-temp-file "agent-shell-vertico-store-" t))
         (agent-shell-dot-subdir-function (lambda (_subdir) transcript-dir)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "missing.md" transcript-dir)
            (insert "**Session ID:** missing-working-directory\n\n---\n\n"
                    "## User\n\nhello\n"))
          (let ((issues
                 (agent-shell-vertico-transcript--diagnostic-issues
                  nil (list root))))
            (should
             (seq-find
              (lambda (issue)
                (string-match-p "missing or names another directory" issue))
              issues))
            (should-not
             (seq-find
              (lambda (issue)
                (string-match-p "header names another directory" issue))
              issues))))
      (delete-directory root t)
      (delete-directory transcript-dir t))))

(ert-deftest agent-shell-vertico-transcript-records-find-nested-files ()
  (let* ((root (make-temp-file "agent-shell-vertico-root-" t))
         (transcript-dir (make-temp-file "agent-shell-vertico-nested-" t))
         (session-dir
          (expand-file-name "2026/07/31/session/" transcript-dir))
         (file (expand-file-name "transcript.md" session-dir))
         (agent-shell-dot-subdir-function (lambda (_subdir) transcript-dir)))
    (unwind-protect
        (progn
          (make-directory session-dir t)
          (with-temp-file file
            (insert (format "**Working Directory:** %s\n"
                            (directory-file-name root))
                    "**Session ID:** nested\n\n---\n\n"
                    "## User\n\nNested transcript\n"))
          (let ((records
                 (agent-shell-vertico-transcript--records-for-project root)))
            (should (= (length records) 1))
            (should
             (equal
              (agent-shell-vertico-transcript-record-file (car records))
              file))))
      (delete-directory root t)
      (delete-directory transcript-dir t))))

(ert-deftest agent-shell-vertico-transcript-activate-switches-to-live-session ()
  (let ((buffer (generate-new-buffer " *agent-shell-vertico-live*"))
        displayed)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local
             agent-shell--state
             '((:session . ((:id . "live-session"))))))
          (cl-letf (((symbol-function 'agent-shell-buffers)
                     (lambda () (list buffer)))
                    ((symbol-function 'agent-shell-vertico--display-session)
                     (lambda (buffer-name)
                       (setq displayed buffer-name))))
            (agent-shell-vertico-transcript--activate
             (agent-shell-vertico-transcript-record-create
              :file "/tmp/transcript.md"
              :session-id "live-session"
              :working-directory "/work/project/")))
          (should (equal displayed (buffer-name buffer))))
      (kill-buffer buffer))))

(ert-deftest agent-shell-vertico-transcript-activate-resumes-in-recorded-directory ()
  (let* ((file "/tmp/transcript.md")
         (record
          (agent-shell-vertico-transcript-record-create
           :file file
           :session-id "past-session"
           :working-directory "/work/project/"))
         called-directory
         called-transcript-function)
    (cl-letf (((symbol-function 'agent-shell-resume-session)
               (lambda (session-id)
                 (setq called-directory default-directory
                       called-transcript-function
                       agent-shell-transcript-file-path-function)
                 (should (equal session-id "past-session")))))
      (agent-shell-vertico-transcript--activate record)
      (should (equal called-directory "/work/project/"))
      (should (equal (funcall called-transcript-function) file)))))

(ert-deftest agent-shell-vertico-transcript-browse-opens-record ()
  (let ((record
         (agent-shell-vertico-transcript-record-create
          :file "/tmp/transcript.md"))
        opened
        activated)
    (cl-letf
        (((symbol-function
           'agent-shell-vertico-transcript--records-for-project)
          (lambda (_root) (list record)))
         ((symbol-function 'agent-shell-vertico-transcript--read-record)
          (lambda (_prompt _records) record))
         ((symbol-function 'agent-shell-vertico-transcript--open-record)
          (lambda (selected &optional _other-window)
            (setq opened selected)))
         ((symbol-function 'agent-shell-vertico-transcript--activate)
          (lambda (selected)
            (setq activated selected))))
      (agent-shell-vertico-transcript--browse-project-root "/work/project/")
      (should (eq opened record))
      (should-not activated))))

(defmacro agent-shell-vertico-tests--with-displayed-transcript
    (&rest body)
  "Display a transcript in the selected window and evaluate BODY.
BODY runs with `file' bound to the transcript, `root' to its working
directory and `buffer' to the displayed transcript buffer."
  (declare (indent 0) (debug t))
  `(let* ((root (file-name-as-directory
                 (make-temp-file "agent-shell-vertico-browse-root-" t)))
          (file (expand-file-name "transcript.md" root))
          buffer)
     (unwind-protect
         (progn
           (with-temp-file file
             (insert "**Agent:** Codex\n"
                     (format "**Working Directory:** %s\n"
                             (directory-file-name root))
                     "**Session ID:** browse\n\n---\n\n"
                     "## User\n\nhello\n"))
           (switch-to-buffer "*scratch*")
           (cl-letf (((symbol-function
                       'agent-shell-vertico-transcript--markdown-major-mode)
                      #'ignore))
             (setq buffer
                   (agent-shell-vertico-transcript--open-record
                    (agent-shell-vertico-transcript--parse-file file root))))
           (should (eq (window-buffer) buffer))
           ,@body)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (set-buffer-modified-p nil))
         (kill-buffer buffer))
       (delete-directory root t))))

(ert-deftest agent-shell-vertico-transcript-browse-from-current-survives-abort ()
  "Aborting the browse prompt leaves the transcript on screen.
The reader must not bury the transcript before the prompt is answered,
or quitting the prompt drops the reader back to whatever preceded it."
  (agent-shell-vertico-tests--with-displayed-transcript
    (cl-letf (((symbol-function
                'agent-shell-vertico-transcript--records-for-project)
               (lambda (_root) (list (agent-shell-vertico-transcript-record-create
                                      :file file))))
              ((symbol-function
                'agent-shell-vertico-transcript--read-record)
               (lambda (_prompt _records) (signal 'quit nil))))
      ;; ERT treats a quit signal as an aborted test, so catch it here
      ;; rather than through `should-error'.
      (should (eq 'quit
                  (condition-case nil
                      (progn
                        (agent-shell-vertico-transcript-browse-from-current)
                        nil)
                    (quit 'quit)))))
    (should (eq (window-buffer) buffer))))

(ert-deftest agent-shell-vertico-transcript-browse-from-current-keeps-hop-back ()
  "A hop to another transcript leaves the previous one reachable.
Burying the transcript also drops it from the window's history, which is
what made `q' skip past every transcript hopped through."
  (agent-shell-vertico-tests--with-displayed-transcript
    (let ((other (expand-file-name "other.md" root)))
      (with-temp-file other
        (insert "**Agent:** Codex\n\n---\n\n## User\n\nsecond\n"))
      (cl-letf (((symbol-function
                  'agent-shell-vertico-transcript--records-for-project)
                 (lambda (_root) nil))
                ((symbol-function
                  'agent-shell-vertico-transcript--read-record)
                 (lambda (_prompt _records)
                   (agent-shell-vertico-transcript-record-create
                    :file other)))
                ((symbol-function
                  'agent-shell-vertico-transcript--markdown-major-mode)
                 #'ignore))
        (agent-shell-vertico-transcript-browse-from-current))
      (let ((opened (find-buffer-visiting other)))
        (unwind-protect
            (progn
              (should (eq (window-buffer) opened))
              (should (memq buffer (mapcar #'car (window-prev-buffers)))))
          (when (buffer-live-p opened)
            (kill-buffer opened)))))))

(ert-deftest agent-shell-vertico-transcript-markdown-mode-prefers-view-mode ()
  "The read-only tree-sitter view mode wins when its grammars are installed."
  (cl-letf (((symbol-function 'markdown-ts-view-mode) #'ignore)
            ((symbol-function 'markdown-mode) #'ignore)
            ((symbol-function 'treesit-language-available-p)
             (lambda (_language &optional _detail) t)))
    (should (eq (agent-shell-vertico-transcript--markdown-major-mode)
                'markdown-ts-view-mode))))

(ert-deftest agent-shell-vertico-transcript-markdown-mode-needs-both-grammars ()
  "A missing inline grammar falls back to `markdown-mode'.
`markdown-ts-mode' parses inline markup with its own grammar and drops
to Text mode without it."
  (cl-letf (((symbol-function 'markdown-ts-view-mode) #'ignore)
            ((symbol-function 'markdown-mode) #'ignore)
            ((symbol-function 'treesit-language-available-p)
             (lambda (language &optional _detail)
               (eq language 'markdown))))
    (should (eq (agent-shell-vertico-transcript--markdown-major-mode)
                'markdown-mode))))

(ert-deftest agent-shell-vertico-transcript-markdown-mode-without-tree-sitter ()
  "`markdown-mode' is used when the tree-sitter mode cannot be loaded."
  (cl-letf (((symbol-function 'markdown-ts-view-mode) nil)
            ((symbol-function 'markdown-mode) #'ignore)
            ((symbol-function 'require)
             (lambda (_feature &optional _file _noerror) nil)))
    (should (eq (agent-shell-vertico-transcript--markdown-major-mode)
                'markdown-mode))))

(ert-deftest agent-shell-vertico-transcript-markdown-mode-without-any-mode ()
  "No Markdown mode leaves the choice to the file itself."
  (cl-letf (((symbol-function 'markdown-ts-view-mode) nil)
            ((symbol-function 'markdown-mode) nil)
            ((symbol-function 'require)
             (lambda (_feature &optional _file _noerror) nil)))
    (should-not (agent-shell-vertico-transcript--markdown-major-mode))))

(ert-deftest agent-shell-vertico-transcript-open-record-sets-markdown-mode ()
  "Opening a transcript switches it to the chosen Markdown mode."
  (let ((file (make-temp-file "agent-shell-vertico-transcript" nil ".md"))
        (buffer nil))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "**Agent:** Codex\n\n---\n\n## User\n\nhello\n"))
          (cl-letf (((symbol-function
                      'agent-shell-vertico-transcript--markdown-major-mode)
                     (lambda () 'agent-shell-vertico-tests--markdown-mode)))
            (setq buffer
                  (agent-shell-vertico-transcript--open-record
                   (agent-shell-vertico-transcript-record-create
                    :file file))))
          (with-current-buffer buffer
            (should (eq major-mode 'agent-shell-vertico-tests--markdown-mode))
            (should agent-shell-vertico-transcript-mode)
            (should agent-shell-vertico-transcript--record)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-file file))))

(ert-deftest agent-shell-vertico-transcript-open-record-leaves-file-alone ()
  "The mode is set with the buffer-amending hook emptied.
Its default adds a final newline, which would mark every transcript that
ends without one modified."
  (let ((markdown-ts-view-mode-pre-init-hook '(ignore))
        seen)
    (cl-letf (((symbol-function
                'agent-shell-vertico-transcript--markdown-major-mode)
               (lambda () 'agent-shell-vertico-tests--markdown-mode))
              ((symbol-function 'agent-shell-vertico-tests--markdown-mode)
               (lambda ()
                 (setq seen markdown-ts-view-mode-pre-init-hook))))
      (with-temp-buffer
        (agent-shell-vertico-transcript--set-markdown-major-mode)))
    (should-not seen)
    (should (equal markdown-ts-view-mode-pre-init-hook '(ignore)))))

(ert-deftest agent-shell-vertico-transcript-open-record-keeps-derived-mode ()
  "A mode already derived from the chosen one is left alone."
  (let ((file (make-temp-file "agent-shell-vertico-transcript" nil ".md"))
        (buffer nil))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "**Agent:** Codex\n\n---\n\n## User\n\nhello\n"))
          (setq buffer (find-file-noselect file))
          (with-current-buffer buffer
            (agent-shell-vertico-tests--derived-markdown-mode))
          (cl-letf (((symbol-function
                      'agent-shell-vertico-transcript--markdown-major-mode)
                     (lambda () 'agent-shell-vertico-tests--markdown-mode)))
            (agent-shell-vertico-transcript--open-record
             (agent-shell-vertico-transcript-record-create :file file)))
          (with-current-buffer buffer
            (should (eq major-mode
                        'agent-shell-vertico-tests--derived-markdown-mode))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-file file))))

(ert-deftest agent-shell-vertico-transcript-record-from-file-takes-header-root ()
  "A record built from a file is scoped by the transcript's own header."
  (let ((file (make-temp-file "agent-shell-vertico-transcript" nil ".md")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "**Agent:** Codex\n"
                    "**Working Directory:** /work/project\n\n---\n\n"
                    "## User\n\nhello\n"))
          (let ((record
                 (agent-shell-vertico-transcript--record-from-file
                  file "/elsewhere/")))
            (should (equal (agent-shell-vertico-transcript-record-project-root
                            record)
                           "/work/project/"))
            (should (equal (agent-shell-vertico-transcript-record-project-name
                            record)
                           "project"))))
      (delete-file file))))

(ert-deftest agent-shell-vertico-transcript-record-from-file-keeps-given-root ()
  "Without a working directory header, the given root scopes the record."
  (let ((file (make-temp-file "agent-shell-vertico-transcript" nil ".md")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "**Agent:** Codex\n\n---\n\n## User\n\nhello\n"))
          (should (equal (agent-shell-vertico-transcript-record-project-root
                          (agent-shell-vertico-transcript--record-from-file
                           file "/elsewhere/"))
                         "/elsewhere/")))
      (delete-file file))))

(defmacro agent-shell-vertico-tests--with-session-transcript (&rest body)
  "Evaluate BODY with a shell buffer holding a transcript file.

Binds `shell' to the shell buffer, `file' to its transcript file, and
`opened' and `opened-other-window' to the arguments
`agent-shell-vertico-transcript--open-record' was called with."
  (declare (indent 0) (debug t))
  `(let ((file (make-temp-file "agent-shell-vertico-transcript" nil ".md"))
         opened opened-other-window)
     (unwind-protect
         (progn
           (with-temp-file file
             (insert "**Agent:** Codex\n"
                     "**Working Directory:** /work/project\n\n---\n\n"
                     "## User\n\nhello\n"))
           (agent-shell-vertico-tests--with-session-buffers
               ((shell "*claude*" "/work/project/" nil))
             (with-current-buffer shell
               (setq-local agent-shell--transcript-file file))
             (cl-letf (((symbol-function
                         'agent-shell-vertico-transcript--open-record)
                        (lambda (record &optional other-window)
                          (setq opened record
                                opened-other-window other-window))))
               ,@body)))
       (delete-file file))))

(ert-deftest agent-shell-vertico-transcript-open-session-reads-shell-transcript ()
  "The session's transcript opens through the transcript reader."
  (agent-shell-vertico-tests--with-session-transcript
    (with-current-buffer shell
      (agent-shell-vertico-transcript-open-session))
    (should (equal (agent-shell-vertico-transcript-record-file opened) file))
    (should (equal (agent-shell-vertico-transcript-record-project-root opened)
                   "/work/project/"))
    (should-not opened-other-window)))

(ert-deftest agent-shell-vertico-transcript-open-session-in-other-window ()
  "A prefix argument leaves the session in the window it is shown in."
  (agent-shell-vertico-tests--with-session-transcript
    (with-current-buffer shell
      (agent-shell-vertico-transcript-open-session t))
    (should (equal (agent-shell-vertico-transcript-record-file opened) file))
    (should opened-other-window)))

(ert-deftest agent-shell-vertico-transcript-open-session-reads-through-viewport ()
  "A viewport opens the transcript of the shell behind it."
  (agent-shell-vertico-tests--with-session-transcript
    (let ((viewport (generate-new-buffer
                     (concat (buffer-name shell)
                             agent-shell-viewport--suffix))))
      (unwind-protect
          (with-current-buffer viewport
            (agent-shell-viewport-view-mode)
            (agent-shell-vertico-transcript-open-session))
        (kill-buffer viewport)))
    (should (equal (agent-shell-vertico-transcript-record-file opened) file))))

(ert-deftest agent-shell-vertico-transcript-open-session-outside-a-session ()
  "Nothing to open outside an `agent-shell' session."
  (with-temp-buffer
    (should-error (agent-shell-vertico-transcript-open-session)
                  :type 'user-error)))

(ert-deftest agent-shell-vertico-transcript-open-session-without-transcript ()
  "A session recording no transcript has nothing to open."
  (agent-shell-vertico-tests--with-session-buffers
      ((shell "*claude*" "/work/project/" nil))
    (with-current-buffer shell
      (setq-local agent-shell--transcript-file nil)
      (should-error (agent-shell-vertico-transcript-open-session)
                    :type 'user-error))))

(ert-deftest agent-shell-vertico-transcript-open-session-with-missing-file ()
  "A transcript file that was never written has nothing to open."
  (agent-shell-vertico-tests--with-session-buffers
      ((shell "*claude*" "/work/project/" nil))
    (with-current-buffer shell
      (setq-local agent-shell--transcript-file "/work/project/missing.md")
      (should-error (agent-shell-vertico-transcript-open-session)
                    :type 'user-error))))

(ert-deftest agent-shell-vertico-transcript-resume-activates-record ()
  (let ((record
         (agent-shell-vertico-transcript-record-create
          :file "/tmp/transcript.md"
          :session-id "session"))
        opened
        activated)
    (cl-letf
        (((symbol-function
           'agent-shell-vertico-transcript--records-for-project)
          (lambda (_root) (list record)))
         ((symbol-function 'agent-shell-vertico-transcript--read-record)
          (lambda (_prompt _records) record))
         ((symbol-function 'agent-shell-vertico-transcript--open-record)
          (lambda (selected &optional _other-window)
            (setq opened selected)))
         ((symbol-function 'agent-shell-vertico-transcript--activate)
          (lambda (selected)
            (setq activated selected))))
      (agent-shell-vertico-transcript--resume-project-root "/work/project/")
      (should (eq activated record))
      (should-not opened))))

(defun agent-shell-vertico-tests--transcript-records (count)
  "Return COUNT transcript records, each with a session ID."
  (mapcar
   (lambda (index)
     (agent-shell-vertico-transcript-record-create
      :file (format "/tmp/transcript-%d.md" index)
      :session-id (format "session-%d" index)))
   (number-sequence 1 count)))

(ert-deftest agent-shell-vertico-transcript-read-records-keeps-newest-within-limit ()
  (let* ((records (agent-shell-vertico-tests--transcript-records 5))
         (agent-shell-vertico-transcript-candidate-limit 2)
         offered
         prompt)
    (cl-letf (((symbol-function 'agent-shell-vertico-transcript--read-record)
               (lambda (read-prompt read-records)
                 (setq prompt read-prompt
                       offered read-records)
                 (car read-records))))
      (agent-shell-vertico-transcript--read-records "Transcript: " records)
      (should (equal offered (seq-take records 2)))
      (should (equal prompt "Transcript (newest 2 of 5): ")))))

(ert-deftest agent-shell-vertico-transcript-read-records-keeps-prompt-under-limit ()
  (let* ((records (agent-shell-vertico-tests--transcript-records 5))
         (agent-shell-vertico-transcript-candidate-limit 10)
         offered
         prompt)
    (cl-letf (((symbol-function 'agent-shell-vertico-transcript--read-record)
               (lambda (read-prompt read-records)
                 (setq prompt read-prompt
                       offered read-records)
                 (car read-records))))
      (agent-shell-vertico-transcript--read-records "Transcript: " records)
      (should (equal offered records))
      (should (equal prompt "Transcript: ")))))

(ert-deftest agent-shell-vertico-transcript-read-records-offers-all-without-limit ()
  (let* ((records (agent-shell-vertico-tests--transcript-records 5))
         (agent-shell-vertico-transcript-candidate-limit nil)
         offered)
    (cl-letf (((symbol-function 'agent-shell-vertico-transcript--read-record)
               (lambda (_prompt read-records)
                 (setq offered read-records)
                 (car read-records))))
      (agent-shell-vertico-transcript--read-records "Transcript: " records)
      (should (equal offered records)))))

(ert-deftest agent-shell-vertico-transcript-read-records-omits-unresumable ()
  (let* ((resumable
          (agent-shell-vertico-transcript-record-create
           :file "/tmp/resumable.md" :session-id "past"))
         (transcript-only
          (agent-shell-vertico-transcript-record-create
           :file "/tmp/transcript-only.md"))
         offered)
    (cl-letf (((symbol-function 'agent-shell-vertico-transcript--read-record)
               (lambda (_prompt read-records)
                 (setq offered read-records)
                 (car read-records))))
      (agent-shell-vertico-transcript--read-records
       "Resume session: " (list resumable transcript-only) t)
      (should (equal offered (list resumable))))))

(ert-deftest agent-shell-vertico-transcript-browse-lists-every-known-project ()
  (let ((record
         (agent-shell-vertico-transcript-record-create
          :file "/tmp/transcript.md"))
        opened
        read-project)
    (cl-letf (((symbol-function 'agent-shell-vertico-transcript--all-records)
               (lambda (&optional _roots) (list record)))
              ((symbol-function 'agent-shell-vertico-transcript--read-project)
               (lambda () (setq read-project t) "/work/project/"))
              ((symbol-function 'agent-shell-vertico-transcript--read-record)
               (lambda (_prompt records) (car records)))
              ((symbol-function 'agent-shell-vertico-transcript--open-record)
               (lambda (selected &optional _other-window)
                 (setq opened selected))))
      (agent-shell-vertico-transcript-browse)
      (should (eq opened record))
      (should-not read-project))))

(ert-deftest agent-shell-vertico-transcript-browse-prefix-reads-project ()
  (let ((record
         (agent-shell-vertico-transcript-record-create
          :file "/tmp/transcript.md"))
        opened
        requested-root)
    (cl-letf (((symbol-function 'agent-shell-vertico-transcript--all-records)
               (lambda (&optional _roots) (error "Should not list all records")))
              ((symbol-function 'agent-shell-vertico-transcript--read-project)
               (lambda () "/work/project/"))
              ((symbol-function
                'agent-shell-vertico-transcript--records-for-project)
               (lambda (root)
                 (setq requested-root root)
                 (list record)))
              ((symbol-function 'agent-shell-vertico-transcript--read-record)
               (lambda (_prompt records) (car records)))
              ((symbol-function 'agent-shell-vertico-transcript--open-record)
               (lambda (selected &optional _other-window)
                 (setq opened selected))))
      (agent-shell-vertico-transcript-browse t)
      (should (eq opened record))
      (should (equal requested-root "/work/project/")))))

(ert-deftest agent-shell-vertico-transcript-resume-lists-every-known-project ()
  (let ((record
         (agent-shell-vertico-transcript-record-create
          :file "/tmp/transcript.md"
          :session-id "session"))
        activated
        read-project)
    (cl-letf (((symbol-function 'agent-shell-vertico-transcript--all-records)
               (lambda (&optional _roots) (list record)))
              ((symbol-function 'agent-shell-vertico-transcript--read-project)
               (lambda () (setq read-project t) "/work/project/"))
              ((symbol-function 'agent-shell-vertico-transcript--read-record)
               (lambda (_prompt records) (car records)))
              ((symbol-function 'agent-shell-vertico-transcript--activate)
               (lambda (selected) (setq activated selected))))
      (agent-shell-vertico-transcript-resume)
      (should (eq activated record))
      (should-not read-project))))

(ert-deftest agent-shell-vertico-transcript-resume-prefix-reads-project ()
  (let ((record
         (agent-shell-vertico-transcript-record-create
          :file "/tmp/transcript.md"
          :session-id "session"))
        activated
        requested-root)
    (cl-letf (((symbol-function 'agent-shell-vertico-transcript--all-records)
               (lambda (&optional _roots) (error "Should not list all records")))
              ((symbol-function 'agent-shell-vertico-transcript--read-project)
               (lambda () "/work/project/"))
              ((symbol-function
                'agent-shell-vertico-transcript--records-for-project)
               (lambda (root)
                 (setq requested-root root)
                 (list record)))
              ((symbol-function 'agent-shell-vertico-transcript--read-record)
               (lambda (_prompt records) (car records)))
              ((symbol-function 'agent-shell-vertico-transcript--activate)
               (lambda (selected) (setq activated selected))))
      (agent-shell-vertico-transcript-resume t)
      (should (eq activated record))
      (should (equal requested-root "/work/project/")))))

(ert-deftest agent-shell-vertico-transcript-search-aggregates-by-transcript ()
  (let* ((root (make-temp-file "agent-shell-vertico-search-root-" t))
         (directory (expand-file-name ".agent-shell/transcripts" root))
         (agent-shell-dot-subdir-function
          (lambda (subdir)
            (expand-file-name
             (file-name-concat ".agent-shell" subdir)
             default-directory))))
    (unwind-protect
        (progn
          (make-directory directory t)
          (with-temp-file (expand-file-name "first.md" directory)
            (insert (format "**Working Directory:** %s\n"
                            (directory-file-name root))
                    "**Session ID:** first\n\n---\n\n"
                    "## User\n\nviewport history\n\n"
                    "## Agent\n\nviewport history works\n"))
          (with-temp-file (expand-file-name "second.md" directory)
            (insert (format "**Working Directory:** %s\n"
                            (directory-file-name root))
                    "**Session ID:** second\n\n---\n\n"
                    "## User\n\nanother viewport history question\n"))
          (let* ((records
                  (agent-shell-vertico-transcript--search
                   (list root) "viewport history"))
                 (first
                  (seq-find
                   (lambda (record)
                     (equal
                      (agent-shell-vertico-transcript-record-session-id
                       record)
                      "first"))
                   records)))
            (should (= (length records) 2))
            (should (= 2
                       (agent-shell-vertico-transcript-record-match-count
                        first)))
            (should (= 8
                       (agent-shell-vertico-transcript-record-match-line
                        first)))
            (should
             (equal
              (agent-shell-vertico-transcript-record-match-text first)
              "viewport history"))))
      (delete-directory root t))))

(ert-deftest agent-shell-vertico-transcript-search-filters-shared-directory ()
  (let* ((root (make-temp-file "agent-shell-vertico-search-root-" t))
         (other-root (make-temp-file "agent-shell-vertico-search-other-" t))
         (directory (make-temp-file "agent-shell-vertico-search-shared-" t))
         (agent-shell-dot-subdir-function (lambda (_subdir) directory)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "matching.md" directory)
            (insert (format "**Working Directory:** %s\n"
                            (directory-file-name root))
                    "**Session ID:** matching\n\n---\n\n"
                    "## User\n\nshared query\n"))
          (with-temp-file (expand-file-name "other.md" directory)
            (insert (format "**Working Directory:** %s\n"
                            (directory-file-name other-root))
                    "**Session ID:** other\n\n---\n\n"
                    "## User\n\nshared query\n"))
          (let ((records
                 (agent-shell-vertico-transcript--search
                  (list root) "shared query")))
            (should (= (length records) 1))
            (should
             (equal
              (agent-shell-vertico-transcript-record-session-id
               (car records))
              "matching"))))
      (delete-directory root t)
      (delete-directory other-root t)
      (delete-directory directory t))))

(ert-deftest agent-shell-vertico-transcript-rg-command-builds-argument-list ()
  (should
   (equal
    (agent-shell-vertico-transcript--rg-command
     '("/tmp/one" "/tmp/two") "needle")
    '("rg" "--json" "--smart-case" "--hidden" "--no-ignore"
      "--glob" "*.md" "--" "needle" "/tmp/one" "/tmp/two")))
  (should-not
   (agent-shell-vertico-transcript--rg-command '("/tmp/one") "")))

(ert-deftest agent-shell-vertico-consult-async-candidates-aggregate-matches ()
  (let* ((root (make-temp-file "agent-shell-vertico-search-root-" t))
         (directory (make-temp-file "agent-shell-vertico-search-dir-" t))
         (file (expand-file-name "transcript.md" directory))
         (agent-shell-dot-subdir-function (lambda (_subdir) directory))
         actions)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert (format "**Working Directory:** %s\n"
                            (directory-file-name root))
                    "**Session ID:** session\n\n---\n\n"
                    "## User\n\nneedle\n"))
          (let* ((stage
                  (agent-shell-vertico-consult--async-candidates
                   (list root)))
                 (handler
                  (funcall
                   stage
                   (lambda (action)
                     (push action actions))))
                 (match
                  (lambda (line)
                    (json-encode
                     `((type . "match")
                       (data
                        (path (text . ,file))
                        (line_number . ,line)
                        (lines (text . "needle\n"))))))))
            (funcall handler "needle")
            (funcall handler 'flush)
            (setq actions nil)
            (funcall handler
                     (list (funcall match 7) (funcall match 9)))
            (let* ((candidates (car actions))
                   (record
                    (get-text-property
                     0 'agent-shell-vertico-transcript-record
                     (car candidates))))
              (should (= (length candidates) 1))
              (should
               (= (agent-shell-vertico-transcript-record-match-count
                   record)
                  2))
              (should
               (= (agent-shell-vertico-transcript-record-match-line
                   record)
                  7)))))
      (delete-directory root t)
      (delete-directory directory t))))

(ert-deftest agent-shell-vertico-consult-search-uses-process-and-opens-record ()
  (let* ((record
          (agent-shell-vertico-transcript-record-create
           :file "/tmp/transcript.md"
           :match-line 12))
         (candidate
          (agent-shell-vertico-consult--candidate record))
         process-called
         opened)
    (cl-letf
        (((symbol-function
           'agent-shell-vertico-transcript--search-directories)
          (lambda (_roots) '("/tmp/transcripts")))
         ((symbol-function 'consult--process-collection)
          (lambda (builder &rest _properties)
            (setq process-called
                  (funcall builder "needle"))
            'async-table))
         ((symbol-function 'consult--dynamic-collection)
          (lambda (&rest _arguments)
            (ert-fail "Synchronous dynamic collection was used")))
         ((symbol-function 'consult--read)
          (lambda (table &rest _options)
            (should (eq table 'async-table))
            candidate))
         ((symbol-function 'consult--temporary-files)
          (lambda () (lambda (&rest _arguments))))
         ((symbol-function 'consult--jump-preview)
          (lambda () (lambda (&rest _arguments))))
         ((symbol-function 'agent-shell-vertico-transcript--open-record)
          (lambda (selected &optional _other-window)
            (setq opened selected)))
         ((symbol-function 'agent-shell-vertico-transcript--activate)
          (lambda (_selected)
            (ert-fail "Search resumed a transcript"))))
      (agent-shell-vertico-consult--search '("/work/project/"))
      (should (equal (car process-called) "rg"))
      (should (eq opened record)))))

(ert-deftest agent-shell-vertico-consult-state-previews-without-visiting ()
  (let* ((record
          (agent-shell-vertico-transcript-record-create
           :file "/tmp/transcript.md"
           :match-line 7))
         (candidate
          (agent-shell-vertico-consult--candidate record))
         (temporary-buffer (generate-new-buffer " *transcript preview*"))
         actions
         previewed
         visited
         jumped)
    (unwind-protect
        (cl-letf
            (((symbol-function 'consult--temporary-files)
              (lambda ()
                (lambda (&optional name)
                  (when name (setq previewed name))
                  temporary-buffer)))
             ((symbol-function 'consult--jump-preview)
              (lambda ()
                (lambda (action _position) (push action actions))))
             ((symbol-function 'consult--jump-state)
              (lambda ()
                (lambda (action position)
                  (push action actions)
                  (when (and position (eq action 'return))
                    (setq jumped t)))))
             ((symbol-function 'consult--file-action)
              (lambda (file)
                (setq visited file)
                temporary-buffer))
             ((symbol-function 'consult--marker-from-line-column)
              (lambda (_buffer _line _column)
                (with-current-buffer temporary-buffer (point-marker)))))
          (let ((state (agent-shell-vertico-consult--state)))
            (funcall state 'preview candidate)
            (funcall state 'preview nil)
            (funcall state 'return candidate))
          (should (equal previewed "/tmp/transcript.md"))
          (should-not visited)
          (should-not jumped)
          (should-not (memq 'return actions)))
      (kill-buffer temporary-buffer))))

(ert-deftest agent-shell-vertico-consult-candidate-carries-preview-location ()
  (let* ((record
          (agent-shell-vertico-transcript-record-create
           :file "/tmp/transcript.md"
           :project-name "agent-shell"
           :started "2026-07-30 10:20:30"
           :match-count 3
           :match-line 42
           :match-text "matching transcript line"))
         (candidate
          (agent-shell-vertico-consult--candidate record)))
    (should (string-match-p "\\[agent-shell\\]" candidate))
    (should (string-match-p "\\[3\\]" candidate))
    (should (string-match-p "matching transcript line" candidate))
    (should
     (eq
      (get-text-property
       0 'agent-shell-vertico-transcript-record candidate)
      record))
    (should
     (equal
      (get-text-property
       0 'agent-shell-vertico-transcript-file candidate)
      "/tmp/transcript.md"))
    (should
     (= (get-text-property
         0 'agent-shell-vertico-transcript-line candidate)
        42))))

(ert-deftest agent-shell-vertico-consult-registers-browse-reader ()
  (should
   (eq agent-shell-vertico-transcript-read-record-function
       #'agent-shell-vertico-consult--read-record)))

(ert-deftest agent-shell-vertico-consult-browse-reader-returns-record ()
  (let* ((record
          (agent-shell-vertico-transcript-record-create
           :file "/tmp/transcript.md"
           :preview "Question"
           :started "2026-07-30"))
         (agent-shell-vertico-transcript-read-record-function
          #'agent-shell-vertico-consult--read-record))
    (cl-letf (((symbol-function 'consult--read)
               (lambda (candidates &rest _options)
                 (car candidates)))
              ((symbol-function 'consult--temporary-files)
               (lambda () (lambda (&rest _arguments))))
              ((symbol-function 'consult--jump-preview)
               (lambda () (lambda (&rest _arguments)))))
      (should
       (eq
        (agent-shell-vertico-transcript--read-record
         "Transcript: " (list record))
        record)))))

(ert-deftest agent-shell-vertico-consult-browse-reader-keeps-records-distinct ()
  "The Consult reader resolves same-titled records to the right one."
  (let* ((first-record
          (agent-shell-vertico-transcript-record-create
           :file "/tmp/first.md"
           :title "Set up emacsclient configuration"))
         (second-record
          (agent-shell-vertico-transcript-record-create
           :file "/tmp/second.md"
           :title "Set up emacsclient configuration"))
         (agent-shell-vertico-transcript-read-record-function
          #'agent-shell-vertico-consult--read-record))
    (cl-letf (((symbol-function 'consult--read)
               (lambda (candidates &rest _options)
                 (should (= (length candidates) 2))
                 ;; Consult looks the selection up with `member', which
                 ;; needs the candidate strings to differ.
                 (car (member (nth 1 candidates) candidates))))
              ((symbol-function 'consult--temporary-files)
               (lambda () (lambda (&rest _arguments))))
              ((symbol-function 'consult--jump-preview)
               (lambda () (lambda (&rest _arguments)))))
      (should
       (eq
        (agent-shell-vertico-transcript--read-record
         "Transcript: " (list first-record second-record))
        second-record)))))

(ert-deftest agent-shell-vertico-transcript-parser-accepts-session-header ()
  (let ((file (make-temp-file "agent-shell-vertico-transcript-" nil ".md")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "**Working Directory:** /work/project\n"
                    "**Session:** legacy-session\n\n---\n"))
          (should
           (equal
            (agent-shell-vertico-transcript-record-session-id
             (agent-shell-vertico-transcript--parse-file
              file "/work/project/"))
            "legacy-session")))
      (delete-file file))))

(ert-deftest agent-shell-vertico-transcript-navigation-by-speaker ()
  (with-temp-buffer
    (insert "## User (one)\n\nFirst\n\n"
            "## Agent (one)\n\nReply\n\n"
            "## User (two)\n\nSecond\n\n"
            "## Agent (two)\n\nReply two\n")
    (goto-char (point-min))
    (agent-shell-vertico-transcript-next-user)
    (should (looking-at-p "## User (one)"))
    (agent-shell-vertico-transcript-next-user)
    (should (looking-at-p "## User (two)"))
    (agent-shell-vertico-transcript-previous-user)
    (should (looking-at-p "## User (one)"))
    (agent-shell-vertico-transcript-next-agent)
    (should (looking-at-p "## Agent (one)"))
    (agent-shell-vertico-transcript-next-agent)
    (should (looking-at-p "## Agent (two)"))))

(ert-deftest agent-shell-vertico-transcript-navigation-by-message ()
  (with-temp-buffer
    (insert "## User (one)\n\nFirst\n\n"
            "## Agent (one)\n\nReply\n\n"
            "## User (two)\n\nSecond\n")
    (goto-char (point-min))
    (agent-shell-vertico-transcript-next-message)
    (should (looking-at-p "## User (one)"))
    (agent-shell-vertico-transcript-next-message)
    (should (looking-at-p "## Agent (one)"))
    (agent-shell-vertico-transcript-next-message)
    (should (looking-at-p "## User (two)"))
    (agent-shell-vertico-transcript-previous-message)
    (should (looking-at-p "## Agent (one)"))))

(ert-deftest agent-shell-vertico-transcript-mode-map-keeps-plain-bindings ()
  (should (eq (lookup-key agent-shell-vertico-transcript-mode-map (kbd "r"))
              #'agent-shell-vertico-transcript-resume-current))
  (should (eq (lookup-key agent-shell-vertico-transcript-mode-map (kbd "n"))
              #'agent-shell-vertico-transcript-next-user))
  (should (eq (lookup-key agent-shell-vertico-transcript-mode-map (kbd "]"))
              #'agent-shell-vertico-transcript-next-message))
  (should (eq (lookup-key agent-shell-vertico-transcript-mode-map (kbd "["))
              #'agent-shell-vertico-transcript-previous-message))
  (should (eq (lookup-key agent-shell-vertico-transcript-mode-map (kbd "?"))
              #'agent-shell-vertico-transcript-help)))

(ert-deftest agent-shell-vertico-transcript-evil-bindings-are-two-key ()
  "Evil bindings must not shadow single-key Evil commands or prefixes."
  (dolist (binding agent-shell-vertico-transcript--evil-bindings)
    (should (> (length (car binding)) 1)))
  (dolist (key '("r" "R" "c" "b" "i" "n" "p" "N" "P" "?" "g" "]" "["))
    (should-not (assoc key
                       agent-shell-vertico-transcript--evil-bindings))))

(ert-deftest agent-shell-vertico-transcript-evil-bindings-cover-actions ()
  (should (eq (cdr (assoc "gr"
                          agent-shell-vertico-transcript--evil-bindings))
              #'agent-shell-vertico-transcript-resume-current))
  (should (eq (cdr (assoc "gR"
                          agent-shell-vertico-transcript--evil-bindings))
              #'agent-shell-vertico-transcript-force-resume-current))
  (should (eq (cdr (assoc "gc"
                          agent-shell-vertico-transcript--evil-bindings))
              #'agent-shell-vertico-transcript-clean-view))
  (should (eq (cdr (assoc "gb"
                          agent-shell-vertico-transcript--evil-bindings))
              #'agent-shell-vertico-transcript-browse-from-current))
  (should (eq (cdr (assoc "gi"
                          agent-shell-vertico-transcript--evil-bindings))
              #'agent-shell-vertico-transcript-set-session-id))
  (should (eq (cdr (assoc "g?"
                          agent-shell-vertico-transcript--evil-bindings))
              #'agent-shell-vertico-transcript-help)))

(ert-deftest agent-shell-vertico-transcript-evil-bindings-cover-navigation ()
  (should (eq (cdr (assoc "]]"
                          agent-shell-vertico-transcript--evil-bindings))
              #'agent-shell-vertico-transcript-next-message))
  (should (eq (cdr (assoc "[["
                          agent-shell-vertico-transcript--evil-bindings))
              #'agent-shell-vertico-transcript-previous-message))
  (should (eq (cdr (assoc "]u"
                          agent-shell-vertico-transcript--evil-bindings))
              #'agent-shell-vertico-transcript-next-user))
  (should (eq (cdr (assoc "[u"
                          agent-shell-vertico-transcript--evil-bindings))
              #'agent-shell-vertico-transcript-previous-user))
  (should (eq (cdr (assoc "]a"
                          agent-shell-vertico-transcript--evil-bindings))
              #'agent-shell-vertico-transcript-next-agent))
  (should (eq (cdr (assoc "[a"
                          agent-shell-vertico-transcript--evil-bindings))
              #'agent-shell-vertico-transcript-previous-agent)))

(ert-deftest agent-shell-vertico-transcript-evil-bindings-install-per-state ()
  (let (bindings)
    (cl-letf (((symbol-function 'evil-local-set-key)
               (lambda (state key definition)
                 (push (list state key definition) bindings))))
      (agent-shell-vertico-transcript--bind-evil-keys)
      (dolist (state '(normal motion))
        (should
         (member (list state (kbd "gr")
                       #'agent-shell-vertico-transcript-resume-current)
                 bindings))
        (should
         (member (list state (kbd "]u")
                       #'agent-shell-vertico-transcript-next-user)
                 bindings))))))

(ert-deftest agent-shell-vertico-transcript-help-lists-both-key-sets ()
  (let ((help (agent-shell-vertico-transcript--help-text)))
    (should (string-match-p "^  r / R" help))
    (should (string-match-p "^  gr / gR" help))
    (should (string-match-p "\\]\\]" help))))

(ert-deftest agent-shell-vertico-transcript-header-line-follows-evil-state ()
  (let ((record
         (agent-shell-vertico-transcript-record-create
          :file "/tmp/transcript.md"
          :agent "Codex"
          :project-name "project"
          :session-id "session")))
    (with-temp-buffer
      (setq-local agent-shell-vertico-transcript--record record)
      (cl-letf (((symbol-function
                  'agent-shell-vertico--live-session-buffer)
                 (lambda (_session-id) nil)))
        (let ((evil-local-mode nil)
              (evil-state nil))
          (should
           (string-match-p
            "\\[r\\] Resume"
            (agent-shell-vertico-transcript--header-line)))
          (should
           (string-match-p
            "\\[c\\] Clean"
            (agent-shell-vertico-transcript--header-line)))
          (setq-local agent-shell-vertico-transcript--clean-view-p t)
          (should
           (string-match-p
            "\\[c\\] Full"
            (agent-shell-vertico-transcript--header-line))))
        (let ((evil-local-mode t)
              (evil-state 'normal))
          (should
           (string-match-p
            "\\[gr\\] Resume"
            (agent-shell-vertico-transcript--header-line))))))))

(defconst agent-shell-vertico-tests--resume-configs
  '(((:identifier . claude-code)
     (:mode-line-name . "Claude")
     (:buffer-name . "Claude Code"))
    ((:identifier . pi)
     (:mode-line-name . "Pi")
     (:buffer-name . "Pi")))
  "Agent configurations used by the resume tests.")

(ert-deftest agent-shell-vertico-transcript-resume-starts-transcript-agent ()
  "Resume with the agent that wrote the transcript, not the preferred one.

A session ID only means something to the agent that issued it, so
resuming a Pi transcript with Claude Code makes the session load fail."
  (let* ((record
          (agent-shell-vertico-transcript-record-create
           :file "/tmp/transcript.md"
           :agent "Pi"
           :session-id "past-session"
           :working-directory "/work/project/"))
         (shell-buffer (generate-new-buffer " *agent-shell-vertico-resume*"))
         (agent-shell-agent-configs agent-shell-vertico-tests--resume-configs)
         (agent-shell-prefer-viewport-interaction t)
         started-arguments)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-shell--auto-preferred-config)
                   (lambda () (car agent-shell-agent-configs)))
                  ((symbol-function 'agent-shell--start)
                   (lambda (&rest arguments)
                     (setq started-arguments arguments)
                     shell-buffer))
                  ((symbol-function
                    'agent-shell--display-viewport-when-ready)
                   (lambda (&rest _arguments) nil)))
          (agent-shell-vertico-transcript--resume-record record)
          (should (eq (plist-get started-arguments :config)
                      (nth 1 agent-shell-vertico-tests--resume-configs))))
      (kill-buffer shell-buffer))))

(ert-deftest agent-shell-vertico-transcript-config-for-agent-resolves-makers ()
  "Entries of `agent-shell-agent-configs' may be config-making functions.
That is agent-shell's own default value, so a transcript naming an agent
has to resolve entries before reading their fields."
  (let ((agent-shell-agent-configs
         (list (lambda ()
                 '((:mode-line-name . "Claude Code")
                   (:buffer-name . "Claude Agent"))))))
    (should (equal (map-elt (agent-shell-vertico-transcript--config-for-agent
                             "Claude Code")
                            :buffer-name)
                   "Claude Agent"))))

(ert-deftest agent-shell-vertico-transcript-config-for-agent-resolves-function ()
  "`agent-shell-agent-configs' may itself be a function returning the list."
  (let ((agent-shell-agent-configs
         (lambda ()
           (list '((:mode-line-name . "Codex")
                   (:buffer-name . "Codex Agent"))))))
    (should (equal (map-elt (agent-shell-vertico-transcript--config-for-agent
                             "Codex")
                            :buffer-name)
                   "Codex Agent"))))

(ert-deftest agent-shell-vertico-transcript-resume-prefers-configured-agent ()
  "Fall back to the preferred agent when the transcript agent is unknown."
  (let* ((record
          (agent-shell-vertico-transcript-record-create
           :file "/tmp/transcript.md"
           :agent "Retired agent"
           :session-id "past-session"
           :working-directory "/work/project/"))
         (shell-buffer (generate-new-buffer " *agent-shell-vertico-resume*"))
         (agent-shell-agent-configs agent-shell-vertico-tests--resume-configs)
         (agent-shell-prefer-viewport-interaction t)
         started-arguments)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-shell--auto-preferred-config)
                   (lambda () (car agent-shell-agent-configs)))
                  ((symbol-function 'agent-shell--start)
                   (lambda (&rest arguments)
                     (setq started-arguments arguments)
                     shell-buffer))
                  ((symbol-function
                    'agent-shell--display-viewport-when-ready)
                   (lambda (&rest _arguments) nil)))
          (agent-shell-vertico-transcript--resume-record record)
          (should (eq (plist-get started-arguments :config)
                      (car agent-shell-vertico-tests--resume-configs))))
      (kill-buffer shell-buffer))))

(ert-deftest agent-shell-vertico-transcript-resume-session-prefers-agent ()
  "`agent-shell-resume-session' picks the agent from the preference.
Bind the transcript's own agent over it so the shell it starts is the
one that issued the session ID."
  (let ((record
         (agent-shell-vertico-transcript-record-create
          :file "/tmp/transcript.md"
          :agent "Pi"
          :session-id "past-session"
          :working-directory "/work/project/"))
        (agent-shell-agent-configs agent-shell-vertico-tests--resume-configs)
        (agent-shell-prefer-viewport-interaction nil)
        preferred)
    (cl-letf (((symbol-function 'agent-shell-resume-session)
               (lambda (_session-id)
                 (setq preferred
                       (symbol-value
                        'agent-shell-preferred-agent-config)))))
      (agent-shell-vertico-transcript--resume-record record)
      (should (eq preferred
                  (nth 1 agent-shell-vertico-tests--resume-configs))))))

(ert-deftest agent-shell-vertico-transcript-resume-uses-resume-session ()
  "Without viewport interaction, resume through `agent-shell-resume-session'."
  (let ((record
         (agent-shell-vertico-transcript-record-create
          :file "/tmp/transcript.md"
          :session-id "past-session"
          :working-directory "/work/project/"))
        (agent-shell-prefer-viewport-interaction nil)
        resumed
        started)
    (cl-letf (((symbol-function 'agent-shell-resume-session)
               (lambda (session-id) (setq resumed session-id)))
              ((symbol-function 'agent-shell--start)
               (lambda (&rest _arguments) (setq started t))))
      (agent-shell-vertico-transcript--resume-record record)
      (should (equal resumed "past-session"))
      (should-not started))))

(ert-deftest agent-shell-vertico-transcript-resume-displays-viewport ()
  "With viewport interaction, resume unfocused and show the viewport.

`agent-shell-resume-session' always displays the shell buffer itself, so
the resumed session would otherwise appear in `agent-shell-mode'."
  (let* ((record
          (agent-shell-vertico-transcript-record-create
           :file "/tmp/transcript.md"
           :session-id "past-session"
           :working-directory "/work/project/"))
         (shell-buffer (generate-new-buffer " *agent-shell-vertico-resume*"))
         (agent-shell-prefer-viewport-interaction t)
         started-arguments
         viewport-arguments
         resumed)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-shell-resume-session)
                   (lambda (session-id) (setq resumed session-id)))
                  ((symbol-function 'agent-shell--auto-preferred-config)
                   (lambda () '((:buffer-name . "Codex"))))
                  ((symbol-function 'agent-shell--start)
                   (lambda (&rest arguments)
                     (setq started-arguments arguments)
                     shell-buffer))
                  ((symbol-function
                    'agent-shell--display-viewport-when-ready)
                   (lambda (&rest arguments)
                     (setq viewport-arguments arguments))))
          (agent-shell-vertico-transcript--resume-record record)
          (should-not resumed)
          (should (equal (plist-get started-arguments :session-id)
                         "past-session"))
          (should (plist-get started-arguments :no-focus))
          (should (plist-get started-arguments :new-session))
          (should (eq (plist-get viewport-arguments :shell-buffer)
                      shell-buffer)))
      (kill-buffer shell-buffer))))

(ert-deftest agent-shell-vertico-consult-preview-forces-plain-markdown ()
  "Preview opens transcripts in the preview mode, not the user's Markdown mode.

Consult previews files with `delay-mode-hooks' bound, which leaves a
Polymode Markdown buffer unable to fontify."
  (let (seen-mode)
    (cl-letf (((symbol-function
                'agent-shell-vertico-consult--preview-major-mode)
               (lambda () 'text-mode)))
      (agent-shell-vertico-consult--open-preview
       "/tmp/transcript.md"
       (lambda (_file)
         (setq seen-mode
               (assoc-default "/tmp/transcript.md" auto-mode-alist
                              #'string-match-p))
         nil))
      (should (eq seen-mode 'text-mode)))))

(ert-deftest agent-shell-vertico-consult-preview-follows-reader-mode ()
  "A preview uses the mode the reader opens a transcript in."
  (cl-letf (((symbol-function
              'agent-shell-vertico-transcript--markdown-major-mode)
             (lambda () 'agent-shell-vertico-tests--markdown-mode)))
    (should (eq (agent-shell-vertico-consult--preview-major-mode)
                'agent-shell-vertico-tests--markdown-mode))))

(ert-deftest agent-shell-vertico-consult-preview-falls-back-to-text-mode ()
  "Without a Markdown mode a preview is plain text."
  (cl-letf (((symbol-function
              'agent-shell-vertico-transcript--markdown-major-mode)
             #'ignore))
    (should (eq (agent-shell-vertico-consult--preview-major-mode)
                'text-mode))))

(ert-deftest agent-shell-vertico-consult-preview-turns-images-off ()
  "A preview runs no buffer-amending hook and turns inline images off.
Previews visit the real transcript, so the hook's default final newline
would modify the file's buffer, and images make a scanned preview noisy."
  (let ((markdown-ts-inline-images t)
        (markdown-ts-view-mode-pre-init-hook
         (list #'agent-shell-vertico-tests--fail-if-run))
        images)
    (cl-letf (((symbol-function
                'agent-shell-vertico-consult--preview-major-mode)
               (lambda () 'text-mode)))
      (agent-shell-vertico-consult--open-preview
       "/tmp/transcript.md"
       (lambda (_file)
         (with-current-buffer (generate-new-buffer " *preview*")
           (setq-local markdown-ts-inline-images t)
           (run-hooks 'markdown-ts-view-mode-pre-init-hook)
           (setq images markdown-ts-inline-images)
           (text-mode)
           (current-buffer)))))
    (should-not images)
    (should markdown-ts-inline-images)))

(ert-deftest agent-shell-vertico-consult-preview-disables-native-code-fontification ()
  "A preview turns off native code-block fontification.
Fontifying a code block natively runs the block's own major mode and a
whole-block `font-lock-ensure', the only step in the preview pipeline
that costs more than a few milliseconds.  A scanned preview does not
need it, so it is off only for the duration of the mode call, not for
the transcript the reader opens afterward."
  (let ((markdown-ts-fontify-code-blocks-natively t)
        natively)
    (cl-letf (((symbol-function
                'agent-shell-vertico-consult--preview-major-mode)
               (lambda () 'text-mode)))
      (agent-shell-vertico-consult--open-preview
       "/tmp/transcript.md"
       (lambda (_file)
         (with-current-buffer (generate-new-buffer " *preview*")
           (setq natively markdown-ts-fontify-code-blocks-natively)
           (text-mode)
           (current-buffer)))))
    (should-not natively)
    (should markdown-ts-fontify-code-blocks-natively)))

(ert-deftest agent-shell-vertico-consult-preview-sets-undetected-mode ()
  "A partial preview buffer has no file name, so set its mode explicitly."
  (let ((buffer (generate-new-buffer " *agent-shell-vertico-preview*")))
    (unwind-protect
        (cl-letf (((symbol-function
                    'agent-shell-vertico-consult--preview-major-mode)
                   (lambda () 'text-mode)))
          (with-current-buffer buffer
            (fundamental-mode))
          (should (eq (agent-shell-vertico-consult--open-preview
                       "/tmp/transcript.md"
                       (lambda (_file) buffer))
                      buffer))
          (should (eq (buffer-local-value 'major-mode buffer) 'text-mode)))
      (kill-buffer buffer))))

(ert-deftest agent-shell-vertico-consult-preview-keeps-detected-mode ()
  (let ((buffer (generate-new-buffer " *agent-shell-vertico-preview*")))
    (unwind-protect
        (cl-letf (((symbol-function
                    'agent-shell-vertico-consult--preview-major-mode)
                   (lambda () 'text-mode)))
          (with-current-buffer buffer
            (emacs-lisp-mode))
          (agent-shell-vertico-consult--open-preview
           "/tmp/transcript.md"
           (lambda (_file) buffer))
          (should (eq (buffer-local-value 'major-mode buffer)
                      'emacs-lisp-mode)))
      (kill-buffer buffer))))

(ert-deftest agent-shell-vertico-transcript-clean-view-toggles-in-place ()
  "The clean view hides text without replacing or modifying the buffer."
  (with-temp-buffer
    (insert "# Agent Shell Transcript\n\n---\n\n"
            "## User (2026-08-26 22:40:58)\n\nQuestion\n\n"
            "## Agent (2026-08-26 22:41:14)\n\nAnswer\n\n"
            "### Tool Call [completed]: rg\n\nInternal output\n\n"
            "## User (2026-08-26 23:14:27)\n\nFollow-up\n")
    (text-mode)
    (set-buffer-modified-p nil)
    (let ((buffer (current-buffer))
          (contents (buffer-string))
          (mode major-mode))
      (agent-shell-vertico-transcript-clean-view)
      (should (eq (current-buffer) buffer))
      (should (equal (buffer-string) contents))
      (should-not (buffer-modified-p))
      (should (eq major-mode mode))
      (goto-char (point-min))
      (should (invisible-p (point)))
      (re-search-forward "Question")
      (should-not (invisible-p (match-beginning 0)))
      (re-search-forward "Tool Call")
      (should (invisible-p (match-beginning 0)))
      (re-search-forward "Internal output")
      (should (invisible-p (match-beginning 0)))
      (re-search-forward "Follow-up")
      (should-not (invisible-p (match-beginning 0)))
      (agent-shell-vertico-transcript-clean-view)
      (should (equal (buffer-string) contents))
      (should-not (buffer-modified-p))
      (goto-char (point-min))
      (while (< (point) (point-max))
        (should-not (invisible-p (point)))
        (goto-char (next-overlay-change (point)))))))

(ert-deftest agent-shell-vertico-transcript-clean-view-keeps-message-headings ()
  "Markdown headings inside an agent message remain visible."
  (with-temp-buffer
    (insert "# Agent Shell Transcript\n\n---\n\n"
            "## Agent (2026-08-26 22:42:38)\n\n"
            "Opening sentence.\n\n"
            "## Summary\n\nSubstantive response.\n\n"
            "## The one correction\n\nCorrection.\n\n"
            "## Proposed change\n\nImplementation.\n\n"
            "#### Current-format heading\n\nCurrent body.\n\n"
            "## User (2026-08-26 23:14:27)\n\nNext question.\n")
    (agent-shell-vertico-transcript-clean-view)
    (dolist (text '("Opening sentence"
                    "Summary"
                    "Substantive response"
                    "The one correction"
                    "Correction"
                    "Proposed change"
                    "Implementation"
                    "Current-format heading"
                    "Current body"
                    "Next question"))
      (goto-char (point-min))
      (re-search-forward text)
      (should-not (invisible-p (match-beginning 0))))))

(ert-deftest agent-shell-vertico-transcript-clean-view-ignores-fenced-events ()
  "Transcript-like headings inside fenced message content remain visible."
  (with-temp-buffer
    (insert "# Agent Shell Transcript\n\n---\n\n"
            "## Agent (2026-08-26 22:42:38)\n\nBefore fence.\n\n"
            "````markdown\n"
            "## User (2026-08-26 22:42:39)\n"
            "### Tool Call [completed]: fake\n"
            "````\n\nAfter fence.\n\n"
            "### Tool Call [completed]: real\n\nHidden output.\n\n"
            "## Agent's Thoughts (2026-08-26 22:42:40)\n\n"
            "Hidden thought.\n\n"
            "## Agent (2026-08-26 22:42:41)\n\nFinal answer.\n")
    (agent-shell-vertico-transcript-clean-view)
    (dolist (text '("Before fence"
                    "## User (2026-08-26 22:42:39)"
                    "### Tool Call [completed]: fake"
                    "After fence"
                    "Final answer"))
      (goto-char (point-min))
      (re-search-forward (regexp-quote text))
      (should-not (invisible-p (match-beginning 0))))
    (dolist (text '("### Tool Call [completed]: real"
                    "Hidden output"
                    "Agent's Thoughts"
                    "Hidden thought"))
      (goto-char (point-min))
      (re-search-forward (regexp-quote text))
      (should (invisible-p (match-beginning 0))))))

(ert-deftest agent-shell-vertico-transcript-clean-view-starts-heading-lines ()
  "Every visible heading begins its own display line in the clean view.

A hidden region that reaches the heading's own line beginning puts the
heading on a display line that starts where the hidden region starts.
Emacs then has to scan and fontify the whole hidden region to find that
display line's start, which stalls `vertical-motion' and every command
built on it."
  (with-temp-buffer
    (insert "# Agent Shell Transcript\n\n---\n\n"
            "## Agent (2026-08-26 22:42:38)\n\nAnswer.\n\n"
            "### Tool Call [completed]: rg\n\nHidden output.\n\n"
            "## User (2026-08-26 23:14:27)\n\nFollow-up.\n")
    (agent-shell-vertico-transcript-clean-view)
    (save-window-excursion
      (set-window-buffer (selected-window) (current-buffer))
      (dolist (heading '("## Agent (2026-08-26 22:42:38)"
                         "## User (2026-08-26 23:14:27)"))
        (goto-char (point-min))
        (re-search-forward (regexp-quote heading))
        (goto-char (match-beginning 0))
        (let ((heading-start (point)))
          (vertical-motion 0)
          (should (equal (point) heading-start)))))))

(ert-deftest agent-shell-vertico-transcript-clean-view-hides-unterminated-tail ()
  "A hidden region reaching an unterminated last line hides all of it."
  (with-temp-buffer
    (insert "## User (2026-08-26 23:14:27)\n\nQuestion.\n\n"
            "### Tool Call [completed]: rg\n\nHidden output.")
    (agent-shell-vertico-transcript-clean-view)
    (goto-char (point-max))
    (should (invisible-p (1- (point))))))

(ert-deftest agent-shell-vertico-transcript-embark-clean-view-is-idempotent ()
  "The Embark clean action keeps an existing clean view clean."
  (with-temp-buffer
    (insert "# Header\n\n## User\n\nQuestion\n")
    (agent-shell-vertico-transcript-clean-view)
    (cl-letf (((symbol-function
                'agent-shell-vertico-transcript--embark-record)
               #'identity)
              ((symbol-function
                'agent-shell-vertico-transcript--open-record)
               #'ignore))
      (agent-shell-vertico-transcript-embark-clean-view 'record))
    (should agent-shell-vertico-transcript--clean-view-p)
    (goto-char (point-min))
    (should (invisible-p (point)))))

(ert-deftest agent-shell-vertico-transcript-stats-count-record-kinds ()
  (let* ((live
          (agent-shell-vertico-transcript-record-create
           :file "/tmp/live.md" :session-id "live"))
         (resumable
          (agent-shell-vertico-transcript-record-create
           :file "/tmp/resumable.md" :session-id "past"))
         (transcript-only
          (agent-shell-vertico-transcript-record-create
           :file "/tmp/plain.md"))
         (stats
          (cl-letf
              (((symbol-function
                 'agent-shell-vertico--live-session-buffer)
                (lambda (session-id)
                  (and (equal session-id "live") 'buffer))))
            (agent-shell-vertico-transcript--stats-for-records
             (list live resumable transcript-only)))))
    (should (= (plist-get stats :total) 3))
    (should (= (plist-get stats :live) 1))
    (should (= (plist-get stats :resumable) 1))
    (should (= (plist-get stats :transcript-only) 1))))

(ert-deftest agent-shell-vertico-transcript-embark-map-has-core-actions ()
  (should
   (eq
    (lookup-key agent-shell-vertico-transcript-embark-map (kbd "o"))
    #'agent-shell-vertico-transcript-embark-open))
  (should
   (eq
    (lookup-key agent-shell-vertico-transcript-embark-map (kbd "b"))
    #'agent-shell-vertico-transcript-embark-open))
  (should
   (eq
    (lookup-key agent-shell-vertico-transcript-embark-map (kbd "r"))
    #'agent-shell-vertico-transcript-embark-resume))
  (should
   (eq
   (lookup-key agent-shell-vertico-transcript-embark-map (kbd "R"))
    #'agent-shell-vertico-transcript-embark-force-resume))
  (should
   (eq
    (lookup-key agent-shell-vertico-transcript-embark-map (kbd "d"))
    #'agent-shell-vertico-transcript-embark-directory)))

(ert-deftest agent-shell-vertico-transcript-embark-directory-opens-working-directory ()
  (let* ((record
          (agent-shell-vertico-transcript-record-create
           :file "/tmp/transcripts/session.md"
           :working-directory "/work/project/"))
         (candidate
          (agent-shell-vertico-transcript--record-candidate record))
         opened)
    (cl-letf (((symbol-function 'dired)
               (lambda (directory)
                 (setq opened directory))))
      (agent-shell-vertico-transcript-embark-directory candidate)
      (should (equal opened "/work/project/")))))

(ert-deftest agent-shell-vertico-transcript-embark-default-opens-record ()
  (let (embark-keymap-alist embark-default-action-overrides)
    (agent-shell-vertico-transcript-setup-embark)
    (should
     (eq
      (alist-get
       'agent-shell-transcript embark-default-action-overrides)
      #'agent-shell-vertico-transcript-embark-open))))

(ert-deftest agent-shell-vertico-transcript-set-session-id-updates-legacy-header ()
  (should
   (equal
    (agent-shell-vertico-transcript--set-session-id-in-text
     (concat
      "**Working Directory:** /work/project\n"
      "**Session:** old-id\n\n---\n")
     "new-id")
    (concat
     "**Working Directory:** /work/project\n"
     "**Session ID:** new-id\n\n---\n"))))

(ert-deftest agent-shell-vertico-transcript-set-session-id-inserts-header ()
  (should
   (equal
    (agent-shell-vertico-transcript--set-session-id-in-text
     "**Agent:** Codex\n\n---\n"
     "new-id")
    "**Agent:** Codex\n\n**Session ID:** new-id\n---\n")))

(defun agent-shell-vertico-tests--header-value (text label)
  "Return LABEL's header value as the parser reads it from transcript TEXT."
  (with-temp-buffer
    (insert text)
    (agent-shell-vertico-transcript--header-value label)))

(ert-deftest agent-shell-vertico-transcript-set-session-id-ignores-quoted-header ()
  "A body that quotes a session header must not be rewritten.
Agents echo transcripts and files verbatim, so the quoted line is not
the header and rewriting it would leave the real header unset."
  (let* ((text (concat
                "**Agent:** Codex\n\n---\n\n"
                "## Agent\n\n"
                "```\n"
                "**Session ID:** quoted-id\n"
                "```\n"))
         (result (agent-shell-vertico-transcript--set-session-id-in-text
                  text "new-id")))
    (should (string-match-p "\\*\\*Session ID:\\*\\* quoted-id" result))
    (should (equal (agent-shell-vertico-tests--header-value result "Session ID")
                   "new-id"))))

(ert-deftest agent-shell-vertico-transcript-set-session-id-without-separator ()
  "Transcripts with no `---' separator keep the ID inside their header.
The header ends at the first speaker heading, and an ID written past it
could never be read back."
  (let* ((text (concat
                "**Agent:** Codex\n"
                "**Working Directory:** /work/project\n\n"
                "## User\n\nhello\n"))
         (result (agent-shell-vertico-transcript--set-session-id-in-text
                  text "new-id")))
    (should (equal (agent-shell-vertico-tests--header-value result "Session ID")
                   "new-id"))))

(ert-deftest agent-shell-vertico-transcript-header-stops-before-body-separator ()
  "A body horizontal rule must not extend a separator-less header."
  (let* ((text (concat
                "**Agent:** Codex\n\n"
                "## User\n\n"
                "Quoted field:\n"
                "**Session ID:** body-id\n\n"
                "---\n\nMore body\n"))
         (result (agent-shell-vertico-transcript--set-session-id-in-text
                  text "new-id")))
    (should (equal (agent-shell-vertico-tests--header-value result "Session ID")
                   "new-id"))
    (should (string-match-p
             "^\\*\\*Session ID:\\*\\* body-id$" result))))

(ert-deftest agent-shell-vertico-transcript-set-session-id-saves-whole-file ()
  "The command writes the whole transcript even from a narrowed buffer.
`erase-buffer' ignores the restriction, so reading the text narrowed
would save the accessible region alone and drop the rest of the file."
  (let ((file (make-temp-file "agent-shell-vertico-transcript" nil ".md"))
        (text (concat
               "**Agent:** Codex\n"
               "**Working Directory:** /work/project\n\n"
               "---\n\n"
               "## User\n\nhello\n"))
        (buffer nil))
    (unwind-protect
        (progn
          (with-temp-file file (insert text))
          (setq buffer (find-file-noselect file))
          (with-current-buffer buffer
            (narrow-to-region (point-min) (point-min))
            (agent-shell-vertico-transcript-set-session-id "new-id"))
          (let ((saved (with-temp-buffer
                         (insert-file-contents file)
                         (buffer-string))))
            (should (string-match-p "^## User$" saved))
            (should (equal (agent-shell-vertico-tests--header-value
                            saved "Session ID")
                           "new-id"))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-file file))))

(ert-deftest agent-shell-vertico-transcript-diagnostics-find-metadata-issues ()
  (let ((records
         (list
          (agent-shell-vertico-transcript-record-create
           :file "/tmp/one.md"
           :session-id "duplicate"
           :working-directory "/missing/one/")
          (agent-shell-vertico-transcript-record-create
           :file "/tmp/two.md"
           :session-id "duplicate"
           :working-directory "/missing/two/")
          (agent-shell-vertico-transcript-record-create
           :file "/tmp/three.md"))))
    (cl-letf (((symbol-function 'file-directory-p)
               (lambda (_directory) nil)))
      (let ((issues
             (agent-shell-vertico-transcript--diagnostic-issues
              records)))
        (should
         (seq-some
          (lambda (issue)
            (string-match-p "1 transcript.*session ID" issue))
          issues))
        (should
         (seq-some
          (lambda (issue)
            (string-match-p "duplicate.*2 transcripts" issue))
          issues))
        (should
         (seq-some
          (lambda (issue)
            (string-match-p "2 working director" issue))
          issues))))))

;;; Buffer search

(defun agent-shell-vertico-tests--folding-buffer (&optional collapsed)
  "Return a buffer with one fragment body, hidden when COLLAPSED is non-nil.
The body sits on line 2 and carries the `invisible' and
`agent-shell-ui-state' text properties agent-shell puts there."
  (let ((buffer (generate-new-buffer " *agent-shell-fold*")))
    (with-current-buffer buffer
      (agent-shell-mode)
      (setq agent-shell-ui-mode t)
      (insert "▶ Read file\nhidden body line\n")
      (put-text-property (point-min) (point-max)
                         'agent-shell-ui-state
                         (list :qualified-id "read-1" :collapsed collapsed))
      (when collapsed
        (put-text-property 13 (point-max) 'invisible t)))
    buffer))

(ert-deftest agent-shell-vertico-consult-folding-buffer-p-finds-fold-owner ()
  (let ((folding (agent-shell-vertico-tests--folding-buffer t))
        (plain (generate-new-buffer " *plain*")))
    (unwind-protect
        (progn
          (should (agent-shell-vertico-consult--folding-buffer-p folding))
          (should-not (agent-shell-vertico-consult--folding-buffer-p plain))
          (should-not (agent-shell-vertico-consult--folding-buffer-p nil)))
      (kill-buffer folding)
      (kill-buffer plain))
    (should-not (agent-shell-vertico-consult--folding-buffer-p folding))))

(ert-deftest agent-shell-vertico-consult-plain-candidates-stops-property-copy ()
  "Entering the minibuffer from a folding buffer turns off the face copy.

`consult--line-fontify' copies `face', `invisible' and `display' from
the source buffer onto each candidate, which blanks every line hidden
inside a collapsed block."
  (let ((folding (agent-shell-vertico-tests--folding-buffer t))
        (minibuffer (generate-new-buffer " *fake-minibuffer*")))
    (unwind-protect
        (cl-letf (((symbol-function 'minibuffer-selected-window)
                   (lambda () (selected-window))))
          (set-window-buffer (selected-window) folding)
          (with-current-buffer minibuffer
            (agent-shell-vertico-consult--plain-candidates)
            (should (local-variable-p 'consult-fontify-preserve))
            (should-not consult-fontify-preserve))
          (should (eq (default-value 'consult-fontify-preserve) t)))
      (kill-buffer minibuffer)
      (kill-buffer folding))))

(ert-deftest agent-shell-vertico-consult-plain-candidates-spares-others ()
  (let ((plain (generate-new-buffer " *plain*"))
        (minibuffer (generate-new-buffer " *fake-minibuffer*")))
    (unwind-protect
        (cl-letf (((symbol-function 'minibuffer-selected-window)
                   (lambda () (selected-window))))
          (set-window-buffer (selected-window) plain)
          (with-current-buffer minibuffer
            (agent-shell-vertico-consult--plain-candidates)
            (should-not (local-variable-p 'consult-fontify-preserve))))
      (kill-buffer minibuffer)
      (kill-buffer plain))))

(ert-deftest agent-shell-vertico-consult-plain-candidates-without-window ()
  "A minibuffer with no originating window leaves the option alone."
  (let ((minibuffer (generate-new-buffer " *fake-minibuffer*")))
    (unwind-protect
        (cl-letf (((symbol-function 'minibuffer-selected-window)
                   (lambda () nil)))
          (with-current-buffer minibuffer
            (agent-shell-vertico-consult--plain-candidates)
            (should-not (local-variable-p 'consult-fontify-preserve))))
      (kill-buffer minibuffer))))

(ert-deftest agent-shell-vertico-consult-expand-fold-opens-collapsed-body ()
  (let ((folding (agent-shell-vertico-tests--folding-buffer t))
        (agent-shell-test-toggle-fragment-count 0))
    (unwind-protect
        (with-current-buffer folding
          (goto-char (point-max))
          (forward-line -1)
          (should (invisible-p (point)))
          (agent-shell-vertico-consult--expand-fold)
          (should (= agent-shell-test-toggle-fragment-count 1)))
      (kill-buffer folding))))

(ert-deftest agent-shell-vertico-consult-expand-parent-group ()
  "A jump into a hidden activity member expands its parent group first."
  (let ((folding (generate-new-buffer " *agent-shell-group-fold*"))
        (agent-shell-test-group-collapse-calls nil)
        (agent-shell-test-toggle-fragment-count 0))
    (unwind-protect
        (with-current-buffer folding
          (agent-shell-mode)
          (setq agent-shell-ui-mode t)
          (agent-shell-vertico-tests--insert-block
           :qid "1-activity-0" :kind 'group :label-left "Activity")
          (let ((member
                 (agent-shell-vertico-tests--insert-block
                  :qid "1-call_a" :group-id "1-activity-0"
                  :label-left "completed read" :label-right "Read foo"
                  :body "contents" :navigatable t :invisible t)))
            (goto-char member)
            (should (invisible-p (point)))
            (agent-shell-vertico-consult--expand-fold)
            (should (equal agent-shell-test-group-collapse-calls
                           '(("1-activity-0" nil))))
            (should-not (invisible-p (point)))
            (should (= agent-shell-test-toggle-fragment-count 0))))
      (kill-buffer folding))))

(ert-deftest agent-shell-vertico-consult-expand-fold-opens-collapsed-member ()
  "Expanding a parent preserves and then opens a collapsed member."
  (let ((folding (generate-new-buffer " *agent-shell-member-fold*"))
        (agent-shell-test-group-collapse-calls nil)
        (agent-shell-test-toggle-fragment-count 0))
    (unwind-protect
        (with-current-buffer folding
          (agent-shell-mode)
          (setq agent-shell-ui-mode t)
          (agent-shell-vertico-tests--insert-block
           :qid "1-activity-0" :kind 'group :label-left "Activity")
          (let ((member
                 (agent-shell-vertico-tests--insert-block
                  :qid "1-call_a" :group-id "1-activity-0"
                  :label-left "completed read" :label-right "Read foo"
                  :body "contents" :navigatable t :collapsed t
                  :invisible t)))
            (goto-char member)
            (should (invisible-p (point)))
            (agent-shell-vertico-consult--expand-fold)
            (should (equal agent-shell-test-group-collapse-calls
                           '(("1-activity-0" nil))))
            (should (= agent-shell-test-toggle-fragment-count 1))))
      (kill-buffer folding))))

(ert-deftest agent-shell-vertico-consult-expand-fold-spares-visible-text ()
  (let ((folding (agent-shell-vertico-tests--folding-buffer t))
        (agent-shell-test-toggle-fragment-count 0))
    (unwind-protect
        (with-current-buffer folding
          (goto-char (point-min))
          (agent-shell-vertico-consult--expand-fold)
          (should (= agent-shell-test-toggle-fragment-count 0)))
      (kill-buffer folding))))

(ert-deftest agent-shell-vertico-consult-expand-fold-spares-expanded-fragment ()
  "Hidden text inside an expanded fragment is trailing whitespace, not a fold.
Toggling there would collapse the fragment the user just jumped into."
  (let ((folding (agent-shell-vertico-tests--folding-buffer nil))
        (agent-shell-test-toggle-fragment-count 0))
    (unwind-protect
        (with-current-buffer folding
          (put-text-property 13 (point-max) 'invisible t)
          (goto-char (point-max))
          (forward-line -1)
          (should (invisible-p (point)))
          (agent-shell-vertico-consult--expand-fold)
          (should (= agent-shell-test-toggle-fragment-count 0)))
      (kill-buffer folding))))

(ert-deftest agent-shell-vertico-consult-expand-fold-spares-other-buffers ()
  (let ((plain (generate-new-buffer " *plain*"))
        (agent-shell-test-toggle-fragment-count 0))
    (unwind-protect
        (with-current-buffer plain
          (insert "hidden\n")
          (put-text-property (point-min) (point-max) 'invisible t)
          (put-text-property (point-min) (point-max)
                             'agent-shell-ui-state (list :collapsed t))
          (goto-char (point-min))
          (agent-shell-vertico-consult--expand-fold)
          (should (= agent-shell-test-toggle-fragment-count 0)))
      (kill-buffer plain))))

(ert-deftest agent-shell-vertico-consult-setup-buffer-search-installs-hooks ()
  (let ((minibuffer-setup-hook nil)
        (consult-after-jump-hook (list #'recenter)))
    (agent-shell-vertico-consult-setup-buffer-search)
    (should (memq #'agent-shell-vertico-consult--plain-candidates
                  minibuffer-setup-hook))
    (should (memq #'agent-shell-vertico-consult--expand-fold
                  consult-after-jump-hook))
    (should (memq #'recenter consult-after-jump-hook))
    (agent-shell-vertico-consult-setup-buffer-search)
    (should (= (seq-count (lambda (fn)
                            (eq fn #'agent-shell-vertico-consult--expand-fold))
                          consult-after-jump-hook)
               1))))

;;; Links
;;
;; Bookmarks and Org links store a stable pointer to a session: the
;; session id, the agent identifier, and the working directory.  Opening
;; the pointer reuses a live buffer when one matches, and otherwise
;; resumes the session with the agent that issued it.

(defun agent-shell-vertico-tests--remove-strict-resume-advice ()
  "Remove strict resume advice and its installed flag.
The advice is process-global, so every test that resumes through a
link must take it back out."
  (advice-remove
   'agent-shell--initiate-new-session
   #'agent-shell-vertico-links--prevent-new-session-fallback)
  (setq agent-shell-vertico-links--strict-resume-advice-installed nil))

(ert-deftest agent-shell-vertico-links-current-session-reads-state ()
  "The session plist carries id, identifier, directory, and title."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ work" "/tmp/alpha/"
              '((:agent-config . ((:identifier . codex)))
                (:session . ((:id . "s1") (:title . "Fix the build"))))))
    (with-current-buffer alpha
      (let ((session (agent-shell-vertico-links--current-session)))
        (should (equal (plist-get session :session-id) "s1"))
        (should (eq (plist-get session :identifier) 'codex))
        (should (equal (plist-get session :dir) "/tmp/alpha/"))
        (should (equal (plist-get session :title) "Fix the build"))))))

(ert-deftest agent-shell-vertico-links-current-session-requires-session ()
  "No pointer outside `agent-shell-mode', or before a session exists."
  (with-temp-buffer
    (should-not (agent-shell-vertico-links--current-session)))
  (agent-shell-vertico-tests--with-session-buffers
      ((starting "Codex Agent @ start" "/tmp/start/" nil))
    (with-current-buffer starting
      (should-not (agent-shell-vertico-links--current-session)))))

(ert-deftest agent-shell-vertico-links-description-prefers-title ()
  "The session title names the pointer, with the id as fallback."
  (should (equal (agent-shell-vertico-links--description
                  '(:session-id "s1" :title "Fix the build"))
                 "Fix the build"))
  (should (equal (agent-shell-vertico-links--description
                  '(:session-id "s1" :title ""))
                 "agent-shell session s1")))

(ert-deftest agent-shell-vertico-links-build-and-parse-roundtrip ()
  "Link paths survive their own encoding round trip.
Session ids, agent identifiers, and directories may all contain the
characters that separate a link path from its query, or one query
parameter from the next."
  (let* ((dir (expand-file-name "/tmp/agent dir/#1/"))
         (path (agent-shell-vertico-links--build "s 1%2" 'codex dir)))
    (should (equal (agent-shell-vertico-links--parse path)
                   (list "s 1%2" "codex" dir)))))

(ert-deftest agent-shell-vertico-links-parse-plain-and-unknown-keys ()
  "A path may carry no query, empty values, or unknown parameters."
  (should (equal (agent-shell-vertico-links--parse "session-1")
                 '("session-1" nil nil)))
  (should (equal (agent-shell-vertico-links--parse
                  "session-1?agent=&other=x&dir=/tmp")
                 '("session-1" "" "/tmp"))))

(ert-deftest agent-shell-vertico-links-config-for-identifier-resolves-makers ()
  "Identifier lookup runs through the resolved agent configs.
`agent-shell-agent-configs' may hold config-making functions, which is
its default shape, so raw entries cannot be read directly."
  (let ((agent-shell-agent-configs
         (list (lambda () '((:identifier . claude-code)))
               '((:identifier . codex)))))
    (should (eq (map-elt (agent-shell-vertico-links--config-for-identifier
                          'codex)
                         :identifier)
                'codex))
    (should-not (agent-shell-vertico-links--config-for-identifier 'gone))))

(ert-deftest agent-shell-vertico-links-open-session-reuses-live-buffer ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ work" "/tmp/alpha/"
              '((:agent-config . ((:identifier . codex)))
                (:session . ((:id . "s1"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-prefer-viewport-interaction nil))
      (agent-shell-vertico-links-open-session "s1" 'codex "/tmp/alpha/")
      (should (eq agent-shell-test-displayed-buffer alpha))
      (should (null agent-shell-test-last-command))
      ;; A link without an agent parameter reuses the live buffer too.
      (setq agent-shell-test-displayed-buffer nil)
      (agent-shell-vertico-links-open-session "s1" nil nil)
      (should (eq agent-shell-test-displayed-buffer alpha)))))

(ert-deftest agent-shell-vertico-links-open-session-requires-identifier-match ()
  "A live buffer running another agent is not a match for the link.
The session id only means something to the agent that issued it, so
the link resumes with its own agent instead."
  (let ((dir (make-temp-file "agent-shell-vertico-links" t)))
    (unwind-protect
        (agent-shell-vertico-tests--with-session-buffers
            ((alpha "Claude Agent @ work" dir
                    '((:agent-config . ((:identifier . claude-code)))
                      (:session . ((:id . "s1"))))))
          (let* ((agent-shell-test-buffers (list alpha))
                 (agent-shell-test-start-buffer alpha)
                 (agent-shell-prefer-viewport-interaction t)
                 (agent-shell-agent-configs '(((:identifier . codex)))))
            (unwind-protect
                (cl-letf (((symbol-function
                            'agent-shell--display-viewport-when-ready)
                           (lambda (&rest _arguments) nil)))
                  (agent-shell-vertico-links-open-session "s1" 'codex dir)
                  (should (eq agent-shell-test-last-command
                              'agent-shell--start))
                  (should (equal (plist-get agent-shell-test-last-args
                                            :session-id)
                                 "s1")))
              (agent-shell-vertico-tests--remove-strict-resume-advice))))
      (delete-directory dir :recursive))))

(ert-deftest agent-shell-vertico-links-open-session-resumes-with-link-context ()
  "The resume uses the link's agent config and working directory."
  (let ((dir (make-temp-file "agent-shell-vertico-links" t)))
    (unwind-protect
        (agent-shell-vertico-tests--with-session-buffers
            ((shell "Codex Agent @ work" dir nil))
          (let* ((agent-shell-test-buffers nil)
                 (agent-shell-test-start-buffer shell)
                 (agent-shell-prefer-viewport-interaction t)
                 (agent-shell-agent-configs
                  (list (lambda () '((:identifier . claude-code)))
                        '((:identifier . codex))))
                 started-arguments started-directory)
            (unwind-protect
                (cl-letf (((symbol-function 'agent-shell--start)
                           (lambda (&rest arguments)
                             (setq started-arguments arguments
                                   started-directory default-directory)
                             shell))
                          ((symbol-function
                            'agent-shell--display-viewport-when-ready)
                           (lambda (&rest _arguments) nil)))
                  (agent-shell-vertico-links-open-session "s1" 'codex dir)
                  (should (eq (plist-get started-arguments :config)
                              (nth 1 agent-shell-agent-configs)))
                  (should (equal (file-name-as-directory started-directory)
                                 (file-name-as-directory dir))))
              (agent-shell-vertico-tests--remove-strict-resume-advice))))
      (delete-directory dir :recursive))))

(ert-deftest agent-shell-vertico-links-open-session-validates-directory ()
  "A pointer into a deleted directory errors before any shell starts."
  (let ((agent-shell-test-buffers nil))
    (should-error
     (agent-shell-vertico-links-open-session
      "s1" 'codex "/no/such/agent-shell-directory/")
     :type 'user-error)
    (should (null agent-shell-test-last-command))))

(ert-deftest agent-shell-vertico-links-open-session-requires-session-id ()
  (should-error (agent-shell-vertico-links-open-session nil)
                :type 'user-error)
  (should-error (agent-shell-vertico-links-open-session "")
                :type 'user-error))

(ert-deftest agent-shell-vertico-links-bookmark-make-record-shape ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ work" "/tmp/alpha/"
              '((:agent-config . ((:identifier . codex)))
                (:session . ((:id . "s1") (:title . "Ship it"))))))
    (with-current-buffer alpha
      (let ((record (agent-shell-vertico-links-bookmark-make-record)))
        (should (equal (car record) "Ship it"))
        (should (eq (cdr (assq 'handler record))
                    #'agent-shell-vertico-links-bookmark-jump))
        (should (equal (cdr (assq 'session-id record)) "s1"))
        (should (eq (cdr (assq 'agent record)) 'codex))
        (should (equal (cdr (assq 'filename record)) "/tmp/alpha/"))
        (should (equal (cdr (assq 'location record)) "Ship it"))))))

(ert-deftest agent-shell-vertico-links-bookmark-set-and-jump ()
  "`bookmark-set' and `bookmark-jump' round trip through the handler."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ work" "/tmp/alpha/"
              '((:agent-config . ((:identifier . codex)))
                (:session . ((:id . "s1"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (bookmark-alist nil)
          (bookmark-save-flag nil)
          (agent-shell-prefer-viewport-interaction nil))
      (with-current-buffer alpha
        (agent-shell-vertico-links-bookmark-enable)
        (bookmark-set "my agent")
        (should (equal (bookmark-get-filename "my agent") "/tmp/alpha/"))
        (setq agent-shell-test-displayed-buffer nil)
        (bookmark-jump "my agent")
        (should (eq agent-shell-test-displayed-buffer alpha))))))

(ert-deftest agent-shell-vertico-links-org-store-stores-link ()
  "Storing a link records type, link, and description for Org."
  (require 'ol)
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ work" "/tmp/alpha/"
              '((:agent-config . ((:identifier . codex)))
                (:session . ((:id . "s1") (:title . "Ship it"))))))
    (with-current-buffer alpha
      (let ((link (agent-shell-vertico-links-org-store)))
        ;; The store function returns the path and signals success; Org
        ;; reads the full link from the `:link' property.
        (should (equal link "s1?agent=codex&dir=/tmp/alpha/"))
        (should (equal (plist-get org-store-link-plist :type)
                       "agent-shell"))
        (should (equal (plist-get org-store-link-plist :link)
                       (concat "agent-shell:" link)))
        (should (equal (plist-get org-store-link-plist :description)
                       "Ship it"))))))

(ert-deftest agent-shell-vertico-links-org-store-requires-session ()
  "Storing declines outside a session so other stores still run."
  (with-temp-buffer
    (should-not (agent-shell-vertico-links-org-store))))

(ert-deftest agent-shell-vertico-links-current-session-reads-viewport ()
  "The session pointer also reads from a viewport showing a session.
The working directory comes from the shell buffer, whose session the
viewport displays, not from the viewport's own directory."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ work" "/tmp/alpha/"
              '((:agent-config . ((:identifier . codex)))
                (:session . ((:id . "s1") (:title . "Ship it"))))))
    (dolist (mode (list #'agent-shell-viewport-view-mode
                       #'agent-shell-viewport-edit-mode))
      (let ((viewport (generate-new-buffer "Codex Agent @ work [viewport]")))
        (unwind-protect
            (with-current-buffer viewport
              (funcall mode)
              (setq default-directory "/tmp/somewhere-else/")
              (let ((session (agent-shell-vertico-links--current-session)))
                (should (equal (plist-get session :session-id) "s1"))
                (should (eq (plist-get session :identifier) 'codex))
                (should (equal (plist-get session :dir) "/tmp/alpha/"))))
          (kill-buffer viewport))))))

(ert-deftest agent-shell-vertico-links-org-store-works-from-viewport ()
  "`org-store-link' from a viewport stores the session it shows."
  (require 'ol)
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ work" "/tmp/alpha/"
              '((:agent-config . ((:identifier . codex)))
                (:session . ((:id . "s1") (:title . "Ship it"))))))
    (let ((viewport (generate-new-buffer "Codex Agent @ work [viewport]")))
      (unwind-protect
          (with-current-buffer viewport
            (agent-shell-viewport-view-mode)
            (should (equal (agent-shell-vertico-links-org-store)
                           "s1?agent=codex&dir=/tmp/alpha/"))
            (should (equal (plist-get org-store-link-plist :description)
                           "Ship it")))
        (kill-buffer viewport)))))

(ert-deftest agent-shell-vertico-links-setup-covers-viewport-buffers ()
  "Setup installs bookmark support in viewports too, by hook and by
retrofitting the viewport an existing session already shows."
  (require 'ol)
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ work" "/tmp/alpha/"
              '((:agent-config . ((:identifier . codex)))
                (:session . ((:id . "s1"))))))
    (let ((viewport (generate-new-buffer "Codex Agent @ work [viewport]")))
      (with-current-buffer viewport
        (agent-shell-viewport-view-mode))
      (let ((agent-shell-test-buffers (list alpha))
            (agent-shell-test-viewport-buffer viewport)
            (agent-shell-mode-hook nil)
            (agent-shell-viewport-view-mode-hook nil)
            (agent-shell-viewport-edit-mode-hook nil)
            (org-link-parameters (copy-alist org-link-parameters)))
        (unwind-protect
            (progn
              (agent-shell-vertico-links-setup)
              (should (memq #'agent-shell-vertico-links-bookmark-enable
                            agent-shell-mode-hook))
              (should (memq #'agent-shell-vertico-links-bookmark-enable
                            agent-shell-viewport-view-mode-hook))
              (should (memq #'agent-shell-vertico-links-bookmark-enable
                            agent-shell-viewport-edit-mode-hook))
              (should (eq (buffer-local-value
                           'bookmark-make-record-function alpha)
                          #'agent-shell-vertico-links-bookmark-make-record))
              (should (eq (buffer-local-value
                           'bookmark-make-record-function viewport)
                          #'agent-shell-vertico-links-bookmark-make-record))
              ;; `bookmark-set' from the viewport stores the session.
              (let ((bookmark-alist nil)
                    (bookmark-save-flag nil))
                (with-current-buffer viewport
                  (bookmark-set "viewport session"))
                (should (equal (bookmark-prop-get "viewport session"
                                                  'session-id)
                               "s1"))))
          (kill-buffer viewport))))))

(ert-deftest agent-shell-vertico-links-org-follow-opens-session ()
  "Org's own link dispatch follows an `agent-shell' link."
  (require 'org)
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ work" "/tmp/alpha/"
              '((:agent-config . ((:identifier . codex)))
                (:session . ((:id . "s1"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-prefer-viewport-interaction nil)
          (org-link-parameters (copy-alist org-link-parameters)))
      (org-link-set-parameters
       "agent-shell"
       :follow #'agent-shell-vertico-links-org-follow)
      (with-temp-buffer
        (org-mode)
        (insert "[[agent-shell:s1?agent=codex&dir=/tmp/alpha/][Ship it]]")
        (goto-char (point-min))
        (org-open-at-point))
      (should (eq agent-shell-test-displayed-buffer alpha)))))

(ert-deftest agent-shell-vertico-links-setup-registers-everywhere ()
  "Setup installs the bookmark hook, retrofits live buffers, and
registers the Org link type."
  (require 'ol)
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ work" "/tmp/alpha/"
              '((:agent-config . ((:identifier . codex)))
                (:session . ((:id . "s1"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (org-link-parameters (copy-alist org-link-parameters)))
      (agent-shell-vertico-links-setup)
      (should (memq #'agent-shell-vertico-links-bookmark-enable
                    agent-shell-mode-hook))
      (should (eq (buffer-local-value 'bookmark-make-record-function alpha)
                  #'agent-shell-vertico-links-bookmark-make-record))
      (should (eq (org-link-get-parameter "agent-shell" :follow)
                  #'agent-shell-vertico-links-org-follow))
      (should (eq (org-link-get-parameter "agent-shell" :store)
                  #'agent-shell-vertico-links-org-store)))))

(ert-deftest agent-shell-vertico-links-strict-resume-blocks-fallback ()
  "A resume the agent cannot complete never starts a new session.
`agent-shell' falls back to a fresh session when the agent cannot
load the requested one, which would silently replace the linked
session with an empty one.  The fallback is blocked, the half-started
buffer is killed, and the failure is reported."
  (let ((dir (make-temp-file "agent-shell-vertico-links" t)))
    (unwind-protect
        (agent-shell-vertico-tests--with-session-buffers
            ((shell "Codex Agent @ work" dir nil))
          (let* ((agent-shell-test-buffers nil)
                 (agent-shell-test-start-buffer shell)
                 (agent-shell-prefer-viewport-interaction t)
                 (agent-shell-agent-configs '(((:identifier . codex))))
                 warnings)
            (unwind-protect
                (cl-letf (((symbol-function 'display-warning)
                           (lambda (_type message &rest _)
                             (push message warnings)))
                          ((symbol-function
                            'agent-shell--display-viewport-when-ready)
                           (lambda (&rest _arguments) nil)))
                  (agent-shell-vertico-links-open-session "dead" 'codex dir)
                  ;; agent-shell's fallback: resume failed, start new instead.
                  (agent-shell--initiate-new-session :shell-buffer shell)
                  (should-not (buffer-live-p shell))
                  ;; The stub records every call it receives, so the
                  ;; still-pending start proves the fallback never ran.
                  (should (eq agent-shell-test-last-command
                              'agent-shell--start))
                  (should (string-match-p "dead" (car warnings))))
              (agent-shell-vertico-tests--remove-strict-resume-advice))))
      (delete-directory dir :recursive))))

(ert-deftest agent-shell-vertico-links-strict-resume-clears-on-init-finished ()
  "The strict mark clears once the session initializes, and takes its
event subscription with it, so later restarts fall back normally."
  (let ((dir (make-temp-file "agent-shell-vertico-links" t)))
    (unwind-protect
        (agent-shell-vertico-tests--with-session-buffers
            ((shell "Codex Agent @ work" dir nil))
          (let* ((agent-shell-test-buffers nil)
                 (agent-shell-test-start-buffer shell)
                 (agent-shell-prefer-viewport-interaction t)
                 (agent-shell-agent-configs '(((:identifier . codex)))))
            (unwind-protect
                (progn
                  (agent-shell-vertico-links-open-session "s1" 'codex dir)
                  (should (equal
                           (buffer-local-value
                            'agent-shell-vertico-links--strict-resume-session-id
                            shell)
                           "s1"))
                  (let ((subscription (car agent-shell-test-subscriptions)))
                    (funcall (nth 2 subscription) 'init-finished)
                    (should
                     (null
                      (buffer-local-value
                       'agent-shell-vertico-links--strict-resume-session-id
                       shell)))
                    (should-not (memq subscription
                                      agent-shell-test-subscriptions)))
                  ;; With the mark cleared, the fallback path runs again.
                  (agent-shell--initiate-new-session :shell-buffer shell)
                  (should (eq agent-shell-test-last-command
                              'agent-shell--initiate-new-session)))
              (agent-shell-vertico-tests--remove-strict-resume-advice))))
      (delete-directory dir :recursive))))

(ert-deftest agent-shell-vertico-links-embark-target-finds-org-link ()
  "Embark targets the whole bracketed link as an `agent-shell-link'."
  (require 'org)
  (with-temp-buffer
    (insert "See [[agent-shell:s1?agent=codex&dir=/tmp/alpha/][Ship it]] now")
    (let ((bounds (progn (goto-char (point-min))
                         (re-search-forward org-link-any-re)
                         (cons (match-beginning 0) (match-end 0)))))
      ;; Point anywhere inside the link claims it.
      (goto-char (+ 2 (car bounds)))
      (should (equal (agent-shell-vertico-links--org-target)
                     `(agent-shell-link
                       "agent-shell:s1?agent=codex&dir=/tmp/alpha/"
                       ,(car bounds) . ,(cdr bounds)))))))

(ert-deftest agent-shell-vertico-links-embark-target-finds-plain-link ()
  "A bare `agent-shell:' address is also a target.
Plain links only match registered types, so the test registers the
link type the same way setup does."
  (require 'org)
  (let ((org-link-parameters (copy-alist org-link-parameters)))
    (org-link-set-parameters "agent-shell")
    (with-temp-buffer
      (insert "see agent-shell:s1?agent=codex end")
      (goto-char (point-min))
      (search-forward "shell")
      (should (equal (agent-shell-vertico-links--org-target)
                     '(agent-shell-link
                       "agent-shell:s1?agent=codex" 5 . 31))))))

(ert-deftest agent-shell-vertico-links-embark-target-skips-other-links ()
  "Other Org links and plain text are left for `embark-org' to claim."
  (require 'org)
  (with-temp-buffer
    (insert "[[file:/tmp/x][a file]]")
    (goto-char 3)
    (should-not (agent-shell-vertico-links--org-target)))
  (with-temp-buffer
    (insert "no links here")
    (goto-char 5)
    (should-not (agent-shell-vertico-links--org-target))))

(ert-deftest agent-shell-vertico-links-embark-map-has-core-actions ()
  (should (eq (lookup-key agent-shell-vertico-links-embark-map (kbd "RET"))
              #'agent-shell-vertico-links-embark-open))
  (should (eq (lookup-key agent-shell-vertico-links-embark-map (kbd "o"))
              #'agent-shell-vertico-links-embark-open))
  (should (eq (lookup-key agent-shell-vertico-links-embark-map (kbd "i"))
              #'agent-shell-vertico-links-embark-copy-session-id)))

(ert-deftest agent-shell-vertico-links-embark-open-opens-session ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ work" "/tmp/alpha/"
              '((:agent-config . ((:identifier . codex)))
                (:session . ((:id . "s1"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-prefer-viewport-interaction nil))
      (agent-shell-vertico-links-embark-open
       "agent-shell:s1?agent=codex&dir=/tmp/alpha/")
      (should (eq agent-shell-test-displayed-buffer alpha)))))

(ert-deftest agent-shell-vertico-links-embark-copy-session-id ()
  (let ((kill-ring nil)
        (interprogram-cut-function nil))
    (agent-shell-vertico-links-embark-copy-session-id
     "agent-shell:s1?agent=codex&dir=/tmp/alpha/")
    (should (equal (current-kill 0 t) "s1"))))

(ert-deftest agent-shell-vertico-links-embark-registration ()
  "Registration adds the finder, a map entry naming only defined
keymaps, and the default action override."
  (let ((embark-target-finders nil)
        (embark-keymap-alist nil)
        (embark-default-action-overrides nil))
    (agent-shell-vertico-links--register-embark)
    (should (memq 'agent-shell-vertico-links--org-target
                  embark-target-finders))
    (should (equal (assq 'agent-shell-link embark-keymap-alist)
                   '(agent-shell-link
                     agent-shell-vertico-links-embark-map)))
    (should (equal (assq 'agent-shell-link embark-default-action-overrides)
                   '(agent-shell-link
                     . agent-shell-vertico-links-embark-open)))))

(ert-deftest agent-shell-vertico-links-embark-composes-embark-org-map ()
  "Once `embark-org' is loaded, the generic Org link actions join the
entry.  Embark resolves every keymap an entry names, so joining
earlier would signal a void variable."
  (let ((embark-keymap-alist
         (list '(agent-shell-link agent-shell-vertico-links-embark-map))))
    (cl-letf (((symbol-function 'featurep)
               (lambda (feature &rest _)
                 (memq feature '(embark embark-org)))))
      (agent-shell-vertico-links--compose-embark-org-map)
      (should (equal (assq 'agent-shell-link embark-keymap-alist)
                     '(agent-shell-link
                       agent-shell-vertico-links-embark-map
                       embark-org-link-map))))))

;;; Prompt queue

(defun agent-shell-vertico-tests--queue-label (candidate)
  "Return CANDIDATE without the invisible key that keeps it distinct."
  (concat (seq-remove (lambda (char) (>= char #x100000)) candidate)))

(defun agent-shell-vertico-tests--queue-labels (candidates)
  "Return the visible text of each candidate in CANDIDATES."
  (mapcar #'agent-shell-vertico-tests--queue-label candidates))

(defmacro agent-shell-vertico-tests--with-queue (prompts &rest body)
  "Evaluate BODY in a session buffer whose queue holds PROMPTS.
Binds `shell' to the session buffer and `candidates' to its prompt
queue candidates, and leaves the session buffer current."
  (declare (indent 1) (debug t))
  `(agent-shell-vertico-tests--with-session-buffers
       ((shell "Codex Agent @ alpha" "/work/alpha/"
               (list (cons :session (list (cons :id "a")))
                     (cons :pending-prompts (copy-sequence ,prompts)))))
     (with-current-buffer shell
       (let ((candidates
              (agent-shell-vertico-prompt-queue--candidates shell)))
         (ignore candidates)
         ,@body))))

(defun agent-shell-vertico-tests--queue-set-pending (buffer prompts)
  "Replace BUFFER's pending prompts with PROMPTS.
Stands in for the queue draining or shrinking while a candidate is in
hand."
  (with-current-buffer buffer
    (setf (map-elt agent-shell--state :pending-prompts)
          (copy-sequence prompts))))

(defun agent-shell-vertico-tests--queue-record (candidates label)
  "Return the record of the candidate in CANDIDATES showing LABEL."
  (agent-shell-vertico-prompt-queue--record-from-candidate
   (seq-find (lambda (candidate)
               (equal label
                      (agent-shell-vertico-tests--queue-label candidate)))
             candidates)))

(ert-deftest agent-shell-vertico-prompt-queue-candidates-list-pending-prompts ()
  "Candidates are the session's pending prompts, queue actions last."
  (agent-shell-vertico-tests--with-queue '("First prompt" "Second prompt")
    (should (equal (agent-shell-vertico-tests--queue-labels candidates)
                   '("First prompt" "Second prompt"
                     "[Resume queue]" "[Remove all]")))))

(ert-deftest agent-shell-vertico-prompt-queue-candidates-empty-without-queue ()
  "An empty queue offers nothing, not even the queue-wide actions."
  (agent-shell-vertico-tests--with-queue '()
    (should-not candidates)
    (should-error (agent-shell-vertico-prompt-queue) :type 'user-error)))

(ert-deftest agent-shell-vertico-prompt-queue-resolves-shell-from-viewport ()
  "A viewport buffer acts on the shell it belongs to."
  (agent-shell-vertico-tests--with-queue '("First prompt")
    (let ((viewport
           (generate-new-buffer (concat (buffer-name shell) " [viewport]"))))
      (unwind-protect
          (with-current-buffer viewport
            (agent-shell-viewport-view-mode)
            (should (eq (agent-shell-vertico-prompt-queue--shell-buffer)
                        shell)))
        (kill-buffer viewport)))))

(ert-deftest agent-shell-vertico-prompt-queue-candidates-stay-distinct ()
  "Two identical prompts remain separately selectable."
  (agent-shell-vertico-tests--with-queue '("Same prompt" "Same prompt")
    (should (equal (agent-shell-vertico-tests--queue-labels
                    (seq-take candidates 2))
                   '("Same prompt" "Same prompt")))
    (should-not (equal (nth 0 candidates) (nth 1 candidates)))))

(ert-deftest agent-shell-vertico-prompt-queue-candidate-shows-first-line ()
  "A candidate shows the prompt's first line, truncated to fit."
  (agent-shell-vertico-tests--with-queue
      (list "Line one\nLine two" (make-string 100 ?x))
    (let ((labels (agent-shell-vertico-tests--queue-labels candidates)))
      (should (equal (nth 0 labels) "Line one"))
      (should (= (string-width (nth 1 labels)) 80))
      (should (string-suffix-p "…" (nth 1 labels))))))

(ert-deftest agent-shell-vertico-prompt-queue-annotation-shows-remainder ()
  "A multi-line prompt is annotated with its size and its remainder."
  (agent-shell-vertico-tests--with-queue
      '("Line one\nLine two\nLine three" "Single line")
    (let ((multi (agent-shell-vertico-prompt-queue--annotate
                  (nth 0 candidates)))
          (single (agent-shell-vertico-prompt-queue--annotate
                   (nth 1 candidates))))
      (should (string-match-p "3 lines" multi))
      (should (string-match-p "Line two Line three" multi))
      (should-not (string-match-p "lines" single)))))

(ert-deftest agent-shell-vertico-prompt-queue-affixation-matches-annotator ()
  "Both annotation paths render through one function, so cannot drift."
  (agent-shell-vertico-tests--with-queue '("Line one\nLine two")
    (should (equal (nth 2 (car (agent-shell-vertico-prompt-queue--affixate
                                candidates)))
                   (agent-shell-vertico-prompt-queue--annotate
                    (car candidates))))))

(ert-deftest agent-shell-vertico-prompt-queue-table-declares-category ()
  "The table declares the category Embark and Marginalia key on."
  (agent-shell-vertico-tests--with-queue '("First prompt")
    (let ((metadata (funcall (agent-shell-vertico-prompt-queue--table
                              candidates)
                             "" nil 'metadata)))
      (should (eq (completion-metadata-get metadata 'category)
                  'agent-shell-prompt-queue))
      (should (eq (completion-metadata-get metadata 'display-sort-function)
                  #'identity)))))

(ert-deftest agent-shell-vertico-prompt-queue-action-annotations ()
  "Queue-wide entries say what they do to the queue as a whole."
  (agent-shell-vertico-tests--with-queue '("First prompt" "Second prompt")
    (should (string-match-p
             "send the next pending prompt"
             (agent-shell-vertico-prompt-queue--annotate (nth 2 candidates))))
    (should (string-match-p
             "drop 2 pending prompts"
             (agent-shell-vertico-prompt-queue--annotate
              (nth 3 candidates))))))

(ert-deftest agent-shell-vertico-prompt-queue-resume-annotation-reports-busy ()
  "A busy shell resumes on its own, and the annotation says so."
  (agent-shell-vertico-tests--with-queue '("First prompt")
    (cl-letf (((symbol-function 'shell-maker-busy) (lambda () t)))
      (should (string-match-p
               "auto-resume"
               (agent-shell-vertico-prompt-queue--annotate
                (nth 1 candidates)))))))

(ert-deftest agent-shell-vertico-prompt-queue-resolve-index-keeps-position ()
  "An untouched queue resolves a candidate to its recorded position."
  (agent-shell-vertico-tests--with-queue '("First prompt" "Second prompt")
    (should (= (agent-shell-vertico-prompt-queue--resolve-index
                (agent-shell-vertico-tests--queue-record
                 candidates "Second prompt"))
               1))))

(ert-deftest agent-shell-vertico-prompt-queue-resolve-index-follows-drain ()
  "A prompt that moved up because the queue drained is found again."
  (agent-shell-vertico-tests--with-queue '("First prompt" "Second prompt")
    (let ((record (agent-shell-vertico-tests--queue-record
                   candidates "Second prompt")))
      (agent-shell-vertico-tests--queue-set-pending shell '("Second prompt"))
      (should (= (agent-shell-vertico-prompt-queue--resolve-index record) 0)))))

(ert-deftest agent-shell-vertico-prompt-queue-resolve-index-errors-when-sent ()
  "A prompt the agent already picked up cannot be acted on."
  (agent-shell-vertico-tests--with-queue '("First prompt" "Second prompt")
    (let ((record (agent-shell-vertico-tests--queue-record
                   candidates "Second prompt")))
      (agent-shell-vertico-tests--queue-set-pending shell '("First prompt"))
      (should-error (agent-shell-vertico-prompt-queue--resolve-index record)
                    :type 'user-error))))

(ert-deftest agent-shell-vertico-prompt-queue-edit-dispatches-to-agent-shell ()
  "Editing runs agent-shell's own command in the owning session."
  (agent-shell-vertico-tests--with-queue '("First prompt" "Second prompt")
    (agent-shell-vertico-prompt-queue-embark-edit (nth 1 candidates))
    (should (eq agent-shell-test-last-command 'agent-shell-prompt-queue-edit))
    (should (eq agent-shell-test-last-buffer shell))
    (should (equal agent-shell-test-last-args '(1)))))

(ert-deftest agent-shell-vertico-prompt-queue-remove-uses-resolved-index ()
  "Removal re-resolves the index the queue has now, not the one shown."
  (agent-shell-vertico-tests--with-queue '("First prompt" "Second prompt")
    (let ((candidate (nth 1 candidates)))
      (agent-shell-vertico-tests--queue-set-pending shell '("Second prompt"))
      (agent-shell-vertico-prompt-queue-embark-remove candidate)
      (should (eq agent-shell-test-last-command
                  'agent-shell-prompt-queue-remove))
      (should (eq agent-shell-test-last-buffer shell))
      (should (equal agent-shell-test-last-args '(0))))))

(ert-deftest agent-shell-vertico-prompt-queue-repeated-removals-shift ()
  "Removing several prompts in one session hits the intended ones.
`embark-act-all' holds every candidate from before the first removal, so
each later index has moved by the time its turn comes."
  (agent-shell-vertico-tests--with-queue '("First" "Second" "Third")
    (agent-shell-vertico-prompt-queue-embark-remove (nth 0 candidates))
    (should (equal agent-shell-test-last-args '(0)))
    (agent-shell-vertico-tests--queue-set-pending shell '("Second" "Third"))
    (agent-shell-vertico-prompt-queue-embark-remove (nth 2 candidates))
    (should (equal agent-shell-test-last-args '(1)))))

(ert-deftest agent-shell-vertico-prompt-queue-steer-uses-resolved-index ()
  "Steering re-resolves the index the same way removal does."
  (agent-shell-vertico-tests--with-queue '("First prompt" "Second prompt")
    (let ((candidate (nth 1 candidates)))
      (agent-shell-vertico-tests--queue-set-pending shell '("Second prompt"))
      (agent-shell-vertico-prompt-queue-embark-steer candidate)
      (should (eq agent-shell-test-last-command
                  'agent-shell-prompt-queue-steer))
      (should (eq agent-shell-test-last-buffer shell))
      (should (equal agent-shell-test-last-args '(0))))))

(ert-deftest agent-shell-vertico-prompt-queue-steer-needs-agent-shell-support ()
  "Steering arrived after the agent-shell version this package requires."
  (agent-shell-vertico-tests--with-queue '("First prompt")
    (cl-letf (((symbol-function 'agent-shell-prompt-queue-steer) nil))
      (should-error (agent-shell-vertico-prompt-queue-embark-steer
                     (car candidates))
                    :type 'user-error)
      (should-not agent-shell-test-last-command))))

(ert-deftest agent-shell-vertico-prompt-queue-steer-skips-queue-entry ()
  "A queue-wide entry has no prompt to steer, and says so quietly."
  (agent-shell-vertico-tests--with-queue '("First prompt")
    (agent-shell-vertico-prompt-queue-embark-steer (nth 1 candidates))
    (should-not agent-shell-test-last-command)))

(ert-deftest agent-shell-vertico-prompt-queue-resume-entry-resumes-queue ()
  "The resume entry resumes the whole queue."
  (agent-shell-vertico-tests--with-queue '("First prompt")
    (agent-shell-vertico-prompt-queue-embark-act (nth 1 candidates))
    (should (eq agent-shell-test-last-command
                'agent-shell-prompt-queue-resume))
    (should (eq agent-shell-test-last-buffer shell))))

(ert-deftest agent-shell-vertico-prompt-queue-remove-all-entry-drops-queue ()
  "The remove-all entry removes every pending prompt."
  (agent-shell-vertico-tests--with-queue '("First prompt")
    (agent-shell-vertico-prompt-queue-embark-act (nth 2 candidates))
    (should (eq agent-shell-test-last-command
                'agent-shell-prompt-queue-remove))
    (should (equal agent-shell-test-last-args '(nil)))))

(ert-deftest agent-shell-vertico-prompt-queue-prompt-action-skips-queue-entry ()
  "A per-prompt action on a queue-wide entry does nothing, quietly.
`embark-act-all' runs over every candidate, and an error would abort the
rest of the run."
  (agent-shell-vertico-tests--with-queue '("First prompt")
    (agent-shell-vertico-prompt-queue-embark-remove (nth 1 candidates))
    (should-not agent-shell-test-last-command)))

(ert-deftest agent-shell-vertico-prompt-queue-copy-yanks-whole-prompt ()
  "Copying puts the full prompt, not the shown line, in the kill ring."
  (agent-shell-vertico-tests--with-queue '("Line one\nLine two")
    (let ((kill-ring nil)
          (interprogram-cut-function nil))
      (agent-shell-vertico-prompt-queue-embark-copy (car candidates))
      (should (equal (current-kill 0 t) "Line one\nLine two")))))

(ert-deftest agent-shell-vertico-prompt-queue-view-shows-whole-prompt ()
  "Viewing renders the prompt verbatim in its own buffer."
  (agent-shell-vertico-tests--with-queue '("Line one\nLine two")
    (unwind-protect
        (progn
          (agent-shell-vertico-prompt-queue-embark-view (car candidates))
          (with-current-buffer agent-shell-vertico-prompt-queue--buffer
            (should (equal (buffer-string) "Line one\nLine two"))
            (should buffer-read-only)))
      (when-let* ((buffer (get-buffer
                           agent-shell-vertico-prompt-queue--buffer)))
        (kill-buffer buffer)))))

(ert-deftest agent-shell-vertico-prompt-queue-command-edits-selection ()
  "The command acts on whatever its reader returns."
  (agent-shell-vertico-tests--with-queue '("First prompt" "Second prompt")
    (let ((agent-shell-vertico-prompt-queue-read-function
           (lambda (_prompt read-candidates)
             (agent-shell-vertico-prompt-queue--record-from-candidate
              (nth 1 read-candidates)))))
      (agent-shell-vertico-prompt-queue)
      (should (eq agent-shell-test-last-command
                  'agent-shell-prompt-queue-edit))
      (should (equal agent-shell-test-last-args '(1))))))

(ert-deftest agent-shell-vertico-prompt-queue-loading-does-not-prebind-embark ()
  "Loading the module must not bind embark's own options.
A `defvar' with a value would pre-bind them, clobbering the defaults
embark installs when it loads later."
  (skip-unless (not (featurep 'embark)))
  (should-not (boundp 'embark-quit-after-action)))

(ert-deftest agent-shell-vertico-prompt-queue-setup-embark-registers ()
  "Registration names the map, the default action, and the view exception."
  (let ((embark-keymap-alist nil)
        (embark-default-action-overrides nil)
        (embark-quit-after-action t))
    (agent-shell-vertico-prompt-queue-setup-embark)
    (should (equal (assq 'agent-shell-prompt-queue embark-keymap-alist)
                   '(agent-shell-prompt-queue
                     agent-shell-vertico-prompt-queue-embark-map)))
    (should (equal (assq 'agent-shell-prompt-queue
                         embark-default-action-overrides)
                   '(agent-shell-prompt-queue
                     . agent-shell-vertico-prompt-queue-embark-act)))
    (should (eq (lookup-key agent-shell-vertico-prompt-queue-embark-map
                            (kbd "x"))
                #'agent-shell-vertico-prompt-queue-embark-remove))
    (should (eq (lookup-key agent-shell-vertico-prompt-queue-embark-map
                            (kbd "e"))
                #'agent-shell-vertico-prompt-queue-embark-edit))
    ;; Viewing is a peek: keep the completion session alive, and keep
    ;; whatever the user chose for every other action.
    (should (equal (alist-get 'agent-shell-vertico-prompt-queue-embark-view
                              embark-quit-after-action 'missing)
                   nil))
    (should (eq (alist-get t embark-quit-after-action) t))))

(ert-deftest agent-shell-vertico-prompt-queue-consult-reader-is-installed ()
  "Loading the Consult module upgrades the reader to a previewing one."
  (should (eq agent-shell-vertico-prompt-queue-read-function
              #'agent-shell-vertico-consult--read-prompt-queue)))

(ert-deftest agent-shell-vertico-prompt-queue-consult-read-keeps-queue-order ()
  "The Consult reader keeps the category and the queue's own order."
  (agent-shell-vertico-tests--with-queue '("First prompt" "Second prompt")
    (let (options)
      (cl-letf (((symbol-function 'consult--read)
                 (lambda (read-candidates &rest args)
                   (setq options args)
                   (nth 1 read-candidates))))
        (let ((record (agent-shell-vertico-consult--read-prompt-queue
                       "Pending prompt: " candidates)))
          (should (eq (map-elt record :buffer) shell))
          (should (equal (map-elt record :text) "Second prompt"))))
      (should (eq (plist-get options :category) 'agent-shell-prompt-queue))
      (should-not (plist-get options :sort))
      (should (plist-get options :state)))))

(ert-deftest agent-shell-vertico-prompt-queue-consult-state-previews-prompt ()
  "Preview shows the whole prompt and leaves nothing behind on exit."
  (agent-shell-vertico-tests--with-queue '("Line one\nLine two")
    (let ((state (agent-shell-vertico-consult--prompt-queue-state)))
      (unwind-protect
          (progn
            (funcall state 'preview (car candidates))
            (with-current-buffer agent-shell-vertico-prompt-queue--buffer
              (should (equal (buffer-string) "Line one\nLine two")))
            (funcall state 'exit nil)
            (should-not (get-buffer
                         agent-shell-vertico-prompt-queue--buffer)))
        (when-let* ((buffer (get-buffer
                             agent-shell-vertico-prompt-queue--buffer)))
          (kill-buffer buffer))))))

(ert-deftest agent-shell-vertico-prompt-queue-consult-state-previews-actions ()
  "Previewing a queue-wide entry describes it instead of showing a prompt."
  (agent-shell-vertico-tests--with-queue '("First prompt")
    (let ((state (agent-shell-vertico-consult--prompt-queue-state)))
      (unwind-protect
          (progn
            (funcall state 'preview (nth 2 candidates))
            (with-current-buffer agent-shell-vertico-prompt-queue--buffer
              (should (string-match-p "drop 1 pending prompt"
                                      (buffer-string)))))
        (funcall state 'exit nil)))))

;;; Resume picker enrichment

(defmacro agent-shell-vertico-tests--with-transcript-store (specs &rest body)
  "Write transcripts from SPECS into a store and evaluate BODY.

Each spec is (NAME SESSION-ID AGENT MODEL MESSAGE).  BODY runs with
`root' bound to a project root whose transcripts live in a shared store,
and `records' bound to that project's parsed records."
  (declare (indent 1) (debug t))
  `(let* ((root (file-name-as-directory
                 (make-temp-file "agent-shell-vertico-resume-root-" t)))
          (store (make-temp-file "agent-shell-vertico-resume-store-" t))
          (agent-shell-dot-subdir-function (lambda (_subdir) store)))
     (unwind-protect
         (progn
           (dolist (spec ,specs)
             (pcase-let ((`(,name ,session-id ,agent ,model ,message) spec))
               (with-temp-file (expand-file-name name store)
                 (insert (format "**Agent:** %s\n" agent)
                         (format "**Working Directory:** %s\n"
                                 (directory-file-name root))
                         (format "**Session ID:** %s\n" session-id)
                         (format "**Model:** %s\n\n---\n\n" model)
                         (format "## User\n\n%s\n" message)))))
           (let ((records
                  (agent-shell-vertico-transcript--records-for-project root)))
             (ignore records)
             ,@body))
       (delete-directory root t)
       (delete-directory store t))))

(defun agent-shell-vertico-tests--acp-session (session-id)
  "Return a stub ACP session alist for SESSION-ID."
  `((sessionId . ,session-id)
    (title . "Session title")
    (cwd . "/work/project")))

(ert-deftest agent-shell-vertico-resume-annotation-shows-transcript-fields ()
  "A listed session is annotated with its transcript's agent, model, message."
  (agent-shell-vertico-tests--with-transcript-store
      '(("one.md" "abc" "Claude" "opus" "make the sidebar wider"))
    (let* ((index (agent-shell-vertico-resume--record-index records))
           (session (agent-shell-vertico-tests--acp-session "abc"))
           (candidate
            (agent-shell-vertico-resume--candidate
             "project  Session title  Today, 10:00"
             session
             (gethash "abc" index)))
           (annotation (agent-shell-vertico-resume--annotate candidate)))
      (should (string-match-p "Claude" annotation))
      (should (string-match-p "opus" annotation))
      (should (string-match-p "make the sidebar wider" annotation))
      (should (string-match-p "Resumable" annotation)))))

(ert-deftest agent-shell-vertico-resume-annotation-marks-live-session ()
  "A session already held by a shell buffer is annotated as live."
  (agent-shell-vertico-tests--with-session-buffers
      ((shell "Claude Agent @ project" "/work/project/"
              '((:session . ((:id . "abc"))))))
    (setq agent-shell-test-buffers (list shell))
    (let* ((session (agent-shell-vertico-tests--acp-session "abc"))
           (candidate
            (agent-shell-vertico-resume--candidate "label" session nil)))
      (should (string-match-p
               "Live" (agent-shell-vertico-resume--annotate candidate))))))

(ert-deftest agent-shell-vertico-resume-annotation-without-transcript ()
  "A session with no transcript still annotates, with empty columns."
  (let* ((session (agent-shell-vertico-tests--acp-session "abc"))
         (candidate
          (agent-shell-vertico-resume--candidate "label" session nil))
         (annotation (agent-shell-vertico-resume--annotate candidate)))
    (should annotation)
    (should (string-match-p "Resumable" annotation))))

(ert-deftest agent-shell-vertico-resume-annotation-skips-non-session-choice ()
  "A choice that starts a new shell carries no session, so no annotation."
  (should-not (agent-shell-vertico-resume--annotate "New shell")))

(ert-deftest agent-shell-vertico-resume-affixation-matches-annotation ()
  "Both renderers go through one suffix, so they cannot drift apart."
  (let* ((session (agent-shell-vertico-tests--acp-session "abc"))
         (candidate
          (agent-shell-vertico-resume--candidate "label" session nil))
         (affixation
          (car (agent-shell-vertico-resume--affixate (list candidate)))))
    (should (equal (nth 0 affixation) candidate))
    (should (equal (nth 2 affixation)
                   (agent-shell-vertico-resume--annotate candidate)))))

(ert-deftest agent-shell-vertico-resume-index-prefers-newest-transcript ()
  "Two transcripts of one session resolve to the newest."
  (agent-shell-vertico-tests--with-transcript-store
      '(("old.md" "abc" "Claude" "opus" "first attempt")
        ("new.md" "abc" "Claude" "opus" "second attempt"))
    (let ((index (agent-shell-vertico-resume--record-index records)))
      (should (= (hash-table-count index) 1))
      (should
       (equal
        (agent-shell-vertico-transcript-record-preview (gethash "abc" index))
        (agent-shell-vertico-transcript-record-preview (car records)))))))

(ert-deftest agent-shell-vertico-resume-records-choices-against-sessions ()
  "The choices hook records each label with the transcript it resolves to."
  (agent-shell-vertico-tests--with-transcript-store
      '(("one.md" "abc" "Claude" "opus" "make the sidebar wider"))
    (let* ((index (agent-shell-vertico-resume--record-index records))
           (session (agent-shell-vertico-tests--acp-session "abc"))
           (agent-shell-vertico-resume--choices nil)
           (agent-shell-vertico-resume--index index)
           (hook (agent-shell-vertico-resume--choices-function nil))
           (choices (funcall hook (list (cons "New shell" :new-shell)
                                        (cons "Resume abc" session)))))
      (should (equal (mapcar #'car choices) '("New shell" "Resume abc")))
      (should (equal (cdr (assoc "New shell"
                                 agent-shell-vertico-resume--choices))
                     :new-shell))
      (should (equal (cdr (assoc "Resume abc"
                                 agent-shell-vertico-resume--choices))
                     session))
      (should
       (equal
        (agent-shell-vertico-transcript-record-session-id
         (agent-shell-vertico-resume--candidate-record
          (nth 1 (agent-shell-vertico-resume--candidates
                  '("New shell" "Resume abc")))))
        "abc")))))

(ert-deftest agent-shell-vertico-resume-choices-hook-keeps-user-transform ()
  "A user's own choices function still runs, and its result is what shows."
  (let* ((agent-shell-vertico-resume--choices nil)
         (user-function
          (lambda (choices)
            (seq-remove (lambda (choice) (eq (cdr choice) :temp-shell))
                        choices)))
         (hook (agent-shell-vertico-resume--choices-function user-function))
         (choices (funcall hook (list (cons "New shell" :new-shell)
                                      (cons "New temp shell" :temp-shell)))))
    (should (equal (mapcar #'car choices) '("New shell")))
    (should (equal (mapcar #'car agent-shell-vertico-resume--choices)
                   '("New shell")))))

(ert-deftest agent-shell-vertico-resume-read-delegates-foreign-prompt ()
  "A prompt the picker makes for something else reads as it always did."
  (let* ((agent-shell-vertico-resume--choices
          (list (cons "New shell" :new-shell)))
         (delegated nil)
         (inner (lambda (&rest args) (setq delegated args) "chosen buffer"))
         (agent-shell-vertico-resume-read-choice-function
          (lambda (&rest _) (error "Picker reader used for a foreign prompt"))))
    (should (equal (agent-shell-vertico-resume--read
                    inner "Switch to shell buffer: "
                    '("shell one" "shell two") nil t)
                   "chosen buffer"))
    (should (equal (car delegated) "Switch to shell buffer: "))))

(ert-deftest agent-shell-vertico-resume-read-enriches-picker-candidates ()
  "The picker's own prompt reads through the configured reader."
  (agent-shell-vertico-tests--with-transcript-store
      '(("one.md" "abc" "Claude" "opus" "make the sidebar wider"))
    (let* ((session (agent-shell-vertico-tests--acp-session "abc"))
           (agent-shell-vertico-resume--index
            (agent-shell-vertico-resume--record-index records))
           (agent-shell-vertico-resume--choices
            (list (cons "New shell" :new-shell)
                  (cons "Resume abc" session)))
           (seen nil)
           (agent-shell-vertico-resume-read-choice-function
            (lambda (_prompt candidates _default)
              (setq seen candidates)
              (nth 1 candidates))))
      (should (equal (agent-shell-vertico-resume--read
                      (lambda (&rest _) (error "Delegated a picker prompt"))
                      "Start shell: "
                      '(("New shell" . :new-shell) ("Resume abc" . session))
                      nil t nil nil "New shell")
                     "Resume abc"))
      (should (equal (mapcar #'substring-no-properties seen)
                     '("New shell" "Resume abc")))
      (should
       (agent-shell-vertico-transcript-record-p
        (get-text-property
         0 'agent-shell-vertico-transcript-record (nth 1 seen)))))))

(ert-deftest agent-shell-vertico-resume-picker-returns-selected-session ()
  "End to end: the advice enriches the prompt and returns what was chosen."
  (agent-shell-vertico-tests--with-transcript-store
      '(("one.md" "abc" "Claude" "opus" "make the sidebar wider"))
    (let* ((session (agent-shell-vertico-tests--acp-session "abc"))
           (annotations nil)
           (agent-shell-session-choices-function nil)
           (default-directory root)
           (agent-shell-vertico-resume-read-choice-function
            (lambda (_prompt candidates _default)
              (setq annotations
                    (mapcar #'agent-shell-vertico-resume--annotate candidates))
              (nth 1 candidates))))
      (advice-add 'agent-shell--prompt-select-session
                  :around #'agent-shell-vertico-resume--select-session)
      (unwind-protect
          (should (equal (agent-shell--prompt-select-session (list session))
                         session))
        (advice-remove 'agent-shell--prompt-select-session
                       #'agent-shell-vertico-resume--select-session))
      (should-not (nth 0 annotations))
      (should (string-match-p "make the sidebar wider" (nth 1 annotations))))))

(ert-deftest agent-shell-vertico-resume-picker-survives-store-failure ()
  "A transcript store that cannot be read leaves the picker working."
  (let* ((session (agent-shell-vertico-tests--acp-session "abc"))
         (agent-shell-dot-subdir-function nil)
         (agent-shell-session-choices-function nil)
         (reported nil)
         (annotation nil)
         (agent-shell-vertico-resume-read-choice-function
          (lambda (_prompt candidates _default)
            (setq annotation
                  (agent-shell-vertico-resume--annotate (nth 1 candidates)))
            (nth 1 candidates))))
    (cl-letf (((symbol-function 'message)
               (lambda (format &rest arguments)
                 (setq reported (apply #'format-message format arguments)))))
      (advice-add 'agent-shell--prompt-select-session
                  :around #'agent-shell-vertico-resume--select-session)
      (unwind-protect
          (should (equal (agent-shell--prompt-select-session (list session))
                         session))
        (advice-remove 'agent-shell--prompt-select-session
                       #'agent-shell-vertico-resume--select-session)))
    (should (string-match-p "no transcripts" reported))
    (should (string-match-p "Resumable" annotation))))

(ert-deftest agent-shell-vertico-resume-picker-skips-work-without-sessions ()
  "With no session to resume there is nothing to join, so nothing is read."
  (let ((parsed nil)
        (agent-shell-session-choices-function nil)
        (agent-shell-vertico-resume-read-choice-function
         (lambda (&rest _) (error "Enriched a prompt with no sessions"))))
    (cl-letf (((symbol-function
                'agent-shell-vertico-transcript--records-for-project)
               (lambda (&rest _) (setq parsed t) nil))
              ((symbol-function 'completing-read)
               (lambda (&rest _) "New shell")))
      (advice-add 'agent-shell--prompt-select-session
                  :around #'agent-shell-vertico-resume--select-session)
      (unwind-protect
          (should-not (agent-shell--prompt-select-session nil))
        (advice-remove 'agent-shell--prompt-select-session
                       #'agent-shell-vertico-resume--select-session)))
    (should-not parsed)))

(ert-deftest agent-shell-vertico-resume-setup-installs-advice ()
  "Setup installs the picker advice once."
  (unwind-protect
      (progn
        (agent-shell-vertico-resume-setup)
        (agent-shell-vertico-resume-setup)
        (let ((installed 0))
          (advice-mapc
           (lambda (function _properties)
             (when (eq function #'agent-shell-vertico-resume--select-session)
               (cl-incf installed)))
           'agent-shell--prompt-select-session)
          (should (= installed 1))))
    (advice-remove 'agent-shell--prompt-select-session
                   #'agent-shell-vertico-resume--select-session)))

(ert-deftest agent-shell-vertico-resume-table-declares-category ()
  "The fallback reader's table carries the category and keeps the order."
  (let* ((table (agent-shell-vertico-resume--table '("b" "a")))
         (metadata (funcall table "" nil 'metadata)))
    (should (equal (alist-get 'category (cdr metadata))
                   'agent-shell-session-choice))
    (should (equal (funcall (alist-get 'display-sort-function (cdr metadata))
                            '("b" "a"))
                   '("b" "a")))
    (should (equal (all-completions "" table) '("b" "a")))))

(ert-deftest agent-shell-vertico-resume-setup-embark-registers-choices ()
  "The picker's choices reach the transcript actions as they stand."
  (let ((embark-keymap-alist nil))
    (agent-shell-vertico-resume-setup-embark)
    (should (equal (assq 'agent-shell-session-choice embark-keymap-alist)
                   '(agent-shell-session-choice
                     agent-shell-vertico-transcript-embark-map)))))

(ert-deftest agent-shell-vertico-resume-setup-embark-keeps-picker-default ()
  "Acting with no key still selects the session, so no default is overridden."
  (let ((embark-keymap-alist nil)
        (embark-default-action-overrides nil))
    (agent-shell-vertico-resume-setup-embark)
    (should-not (assq 'agent-shell-session-choice
                      embark-default-action-overrides))))

(ert-deftest agent-shell-vertico-resume-embark-action-reads-choice-record ()
  "A picker choice carries what the transcript actions read off a candidate."
  (agent-shell-vertico-tests--with-transcript-store
      '(("one.md" "abc" "Claude" "opus" "make the sidebar wider"))
    (let* ((index (agent-shell-vertico-resume--record-index records))
           (session (agent-shell-vertico-tests--acp-session "abc"))
           (candidate
            (agent-shell-vertico-resume--candidate
             "project  Session title  Today, 10:00"
             session
             (gethash "abc" index)))
           (kill-ring nil))
      (agent-shell-vertico-transcript-embark-copy-session-id candidate)
      (should (equal (current-kill 0) "abc")))))

(ert-deftest agent-shell-vertico-resume-embark-action-without-transcript ()
  "A choice that starts a new shell has no record, so the action refuses."
  (should-error
   (agent-shell-vertico-transcript-embark-copy-session-id "New shell")
   :type 'user-error))

(ert-deftest agent-shell-vertico-setup-embark-integrations-covers-choices ()
  "Unified setup registers the picker's category with the others."
  (let ((embark-keymap-alist nil)
        (embark-default-action-overrides nil)
        (embark-target-finders nil)
        (embark-quit-after-action t))
    (agent-shell-vertico--setup-embark-integrations)
    (dolist (category '(agent-shell-session
                        agent-shell-transcript
                        agent-shell-prompt-queue
                        agent-shell-session-choice))
      (should (assq category embark-keymap-alist)))))

(ert-deftest agent-shell-vertico-resume-consult-registers-reader ()
  "Loading the Consult module makes the picker read with preview."
  (should (equal agent-shell-vertico-resume-read-choice-function
                 #'agent-shell-vertico-consult--read-session-choice)))

(ert-deftest agent-shell-vertico-resume-consult-picker-returns-selected-session ()
  "The advised picker lets Consult read once and returns the selected session."
  (agent-shell-vertico-tests--with-transcript-store
      '(("one.md" "abc" "Claude" "opus" "make the sidebar wider"))
    (let* ((session (agent-shell-vertico-tests--acp-session "abc"))
           (agent-shell-session-choices-function nil)
           (default-directory root)
           (consult-read-count 0)
           (agent-shell-vertico-resume-read-choice-function
            #'agent-shell-vertico-consult--read-session-choice))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &optional predicate &rest _)
                   (nth 1 (all-completions "" collection predicate))))
                ((symbol-function 'consult--read)
                 (lambda (candidates &rest options)
                   (cl-incf consult-read-count)
                   (when (> consult-read-count 1)
                     (error "Consult reader re-entered"))
                   (completing-read
                    (plist-get options :prompt)
                    candidates nil
                    (plist-get options :require-match)
                    nil nil (plist-get options :default))))
                ((symbol-function 'consult--temporary-files)
                 (lambda () #'ignore))
                ((symbol-function 'consult--jump-preview)
                 (lambda () #'ignore)))
        (agent-shell-vertico-resume-setup)
        (unwind-protect
            (should (equal (agent-shell--prompt-select-session (list session))
                           session))
          (advice-remove 'agent-shell--prompt-select-session
                         #'agent-shell-vertico-resume--select-session)))
      (should (= consult-read-count 1)))))

(ert-deftest agent-shell-vertico-resume-consult-reader-previews-transcript ()
  "The Consult reader previews the transcript of the candidate at point."
  (let* ((session (agent-shell-vertico-tests--acp-session "abc"))
         (record (agent-shell-vertico-transcript-record-create
                  :file "/store/one.md" :session-id "abc"))
         (candidate
          (agent-shell-vertico-resume--candidate "Resume abc" session record))
         (options nil))
    (cl-letf (((symbol-function 'consult--read)
               (lambda (candidates &rest rest)
                 (setq options rest)
                 (car candidates)))
              ((symbol-function 'consult--temporary-files) (lambda () #'ignore))
              ((symbol-function 'consult--jump-preview) (lambda () #'ignore)))
      (should (equal (agent-shell-vertico-consult--read-session-choice
                      "Start shell: " (list candidate) "Resume abc")
                     candidate))
      (should (equal (plist-get options :category) 'agent-shell-session-choice))
      (should (equal (plist-get options :default) "Resume abc"))
      (should-not (plist-get options :sort))
      (should (functionp (plist-get options :state))))))

;;; Out-of-turn bursts

(defmacro agent-shell-vertico-tests--with-settled-timers (&rest body)
  "Run BODY with timer creation captured instead of scheduled.

The settle timer is armed from event handling, so a real timer would fire
after the test has already finished.  Tests call
`agent-shell-vertico-sidebar--out-of-turn-settled' themselves instead."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'run-at-time)
              (lambda (&rest _args) 'agent-shell-test-timer))
             ((symbol-function 'cancel-timer) #'ignore)
             ((symbol-function 'timerp)
              (lambda (object) (eq object 'agent-shell-test-timer))))
     ,@body))

(ert-deftest agent-shell-vertico-sidebar-out-of-turn-chunk-reads-as-working ()
  "Output streaming with no turn in flight is work, not an idle session."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha"))))))
    (agent-shell-vertico-tests--with-settled-timers
      (let ((agent-shell-test-statuses (list (cons alpha 'ready))))
        (should (eq (agent-shell-vertico-sidebar--raw-status alpha) 'ready))
        (cl-letf (((symbol-function 'float-time) (lambda (&optional _) 10.0)))
          (agent-shell-vertico-sidebar--handle-event
           alpha '((:event . agent-message-chunk))))
        (should (eq (agent-shell-vertico-sidebar--raw-status alpha) 'busy))
        (should (equal (agent-shell-vertico-sidebar--status-name alpha)
                       "Working"))
        (should (= (gethash alpha agent-shell-vertico-sidebar--busy-since-times)
                   10.0))))))

(ert-deftest agent-shell-vertico-sidebar-out-of-turn-burst-keeps-its-start ()
  "Later chunks push the settle back without restarting the working age."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha"))))))
    (agent-shell-vertico-tests--with-settled-timers
      (let ((agent-shell-test-statuses (list (cons alpha 'ready)))
            (times '(10.0 20.0)))
        (cl-letf (((symbol-function 'float-time)
                   (lambda (&optional _) (pop times))))
          (agent-shell-vertico-sidebar--handle-event
           alpha '((:event . agent-message-chunk)))
          (agent-shell-vertico-sidebar--handle-event
           alpha '((:event . tool-call-update))))
        (should (= (gethash alpha agent-shell-vertico-sidebar--busy-since-times)
                   10.0))
        (should (= (plist-get (gethash alpha
                                       agent-shell-vertico-sidebar--out-of-turn)
                              :time)
                   20.0))))))

(ert-deftest agent-shell-vertico-sidebar-settled-out-of-turn-marks-done ()
  "A quiet burst leaves output nobody has read, so it is marked unread."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha"))))))
    (agent-shell-vertico-tests--with-settled-timers
      (let ((agent-shell-test-statuses (list (cons alpha 'ready))))
        (cl-letf (((symbol-function 'float-time) (lambda (&optional _) 10.0)))
          (agent-shell-vertico-sidebar--handle-event
           alpha '((:event . agent-message-chunk))))
        (agent-shell-vertico-sidebar--out-of-turn-settled alpha)
        (should (equal (gethash alpha agent-shell-vertico-sidebar--attention)
                       '(:kind done :time 10.0)))
        (should (eq (agent-shell-vertico-sidebar--raw-status alpha) 'ready))
        (should (equal (agent-shell-vertico-sidebar--status-name alpha) "Done"))
        (should-not (gethash alpha
                             agent-shell-vertico-sidebar--busy-since-times))))))

(ert-deftest agent-shell-vertico-sidebar-settled-out-of-turn-clears-when-seen ()
  "The unread mark is an ordinary `done', so reading the session clears it."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha"))))))
    (agent-shell-vertico-tests--with-settled-timers
      (let ((agent-shell-test-statuses (list (cons alpha 'ready))))
        (agent-shell-vertico-sidebar--handle-event
         alpha '((:event . agent-message-chunk)))
        (agent-shell-vertico-sidebar--out-of-turn-settled alpha)
        (agent-shell-vertico-sidebar--mark-seen alpha)
        (should-not (gethash alpha
                             agent-shell-vertico-sidebar--attention))))))

(ert-deftest agent-shell-vertico-sidebar-in-turn-chunk-is-not-out-of-turn ()
  "A chunk from a running turn belongs to that turn, not to a burst."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha"))))))
    (agent-shell-vertico-tests--with-settled-timers
      (let ((agent-shell-test-statuses (list (cons alpha 'busy))))
        (agent-shell-vertico-sidebar--handle-event
         alpha '((:event . agent-message-chunk)))
        (should-not (gethash alpha
                             agent-shell-vertico-sidebar--out-of-turn))))))

(ert-deftest agent-shell-vertico-sidebar-steering-round-trip-is-not-out-of-turn ()
  "A steered prompt's own request is in flight, so its updates are in turn."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha")))
                (:active-requests . (steering)))))
    (agent-shell-vertico-tests--with-settled-timers
      (let ((agent-shell-test-statuses (list (cons alpha 'ready))))
        (agent-shell-vertico-sidebar--handle-event
         alpha '((:event . agent-message-chunk)))
        (should-not (gethash alpha
                             agent-shell-vertico-sidebar--out-of-turn))
        (should (eq (agent-shell-vertico-sidebar--raw-status alpha) 'ready))))))

(ert-deftest agent-shell-vertico-sidebar-settled-out-of-turn-skips-read-session ()
  "Output that streamed into the selected window has already been read."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha"))))))
    (agent-shell-vertico-tests--with-settled-timers
      (let ((agent-shell-test-statuses (list (cons alpha 'ready))))
        (agent-shell-vertico-sidebar--handle-event
         alpha '((:event . agent-message-chunk)))
        (agent-shell-vertico-tests--with-frame-focus t
          (save-window-excursion
            (set-window-buffer (selected-window) alpha)
            (agent-shell-vertico-sidebar--out-of-turn-settled alpha)))
        (should-not (gethash alpha
                             agent-shell-vertico-sidebar--attention))))))

(ert-deftest agent-shell-vertico-sidebar-settled-out-of-turn-keeps-blocked ()
  "A session waiting on a permission answer must not be downgraded to done."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha"))))))
    (agent-shell-vertico-tests--with-settled-timers
      (let ((agent-shell-test-statuses (list (cons alpha 'ready))))
        (agent-shell-vertico-sidebar--handle-event
         alpha '((:event . agent-message-chunk)))
        (puthash alpha (list :kind 'blocked :time 5.0)
                 agent-shell-vertico-sidebar--attention)
        (agent-shell-vertico-sidebar--out-of-turn-settled alpha)
        (should (eq (plist-get (gethash alpha
                                        agent-shell-vertico-sidebar--attention)
                               :kind)
                    'blocked))))))

(ert-deftest agent-shell-vertico-sidebar-new-turn-cancels-out-of-turn-settle ()
  "A prompt submitted during the quiet window owns the session from then on."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha"))))))
    (agent-shell-vertico-tests--with-settled-timers
      (let ((agent-shell-test-statuses (list (cons alpha 'ready))))
        (agent-shell-vertico-sidebar--handle-event
         alpha '((:event . agent-message-chunk)))
        (agent-shell-vertico-sidebar--handle-event
         alpha '((:event . input-submitted)))
        (should-not (gethash alpha
                             agent-shell-vertico-sidebar--out-of-turn))
        (should (eq (agent-shell-vertico-sidebar--raw-status alpha) 'ready))))))

(ert-deftest agent-shell-vertico-sidebar-turn-complete-cancels-out-of-turn-settle ()
  "A real turn's completion supersedes any burst that preceded it."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha"))))))
    (agent-shell-vertico-tests--with-settled-timers
      (let ((agent-shell-test-statuses (list (cons alpha 'ready))))
        (agent-shell-vertico-sidebar--handle-event
         alpha '((:event . agent-message-chunk)))
        (agent-shell-vertico-sidebar--handle-event
         alpha '((:event . turn-complete)))
        (should-not (gethash alpha
                             agent-shell-vertico-sidebar--out-of-turn))))))

(ert-deftest agent-shell-vertico-sidebar-out-of-turn-sorts-into-working-tier ()
  "A burst puts its session above idle ones under priority sorting."
  (agent-shell-vertico-tests--with-session-buffers
      ((quiet "Codex Agent @ quiet" "/work/quiet/"
              '((:session . ((:id . "q") (:title . "Quiet")))))
       (streaming "Codex Agent @ streaming" "/work/streaming/"
                  '((:session . ((:id . "s") (:title . "Streaming"))))))
    (agent-shell-vertico-tests--with-settled-timers
      (let ((agent-shell-test-statuses (list (cons quiet 'ready)
                                             (cons streaming 'ready))))
        (puthash quiet 100.0 agent-shell-vertico-sidebar--activity)
        (agent-shell-vertico-sidebar--handle-event
         streaming '((:event . agent-message-chunk)))
        (should (equal (agent-shell-vertico-sidebar--sort-buffers
                        (list quiet streaming) 'priority)
                       (list streaming quiet)))))))

;;; Attention notifications

(ert-deftest agent-shell-vertico-sidebar-notifies-a-finished-turn ()
  "A turn nobody is watching reports itself, carrying the agent's reply."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha"))))))
    (let* ((agent-shell-test-buffers (list alpha))
           (agent-shell-test-statuses (list (cons alpha 'busy)))
           notifications
           (agent-shell-vertico-sidebar-notify-function
            (lambda (&rest arguments) (push arguments notifications))))
      (agent-shell-vertico-tests--with-sidebar
        (agent-shell-vertico-sidebar--handle-event
         alpha '((:event . agent-message-chunk)
                 (:data . ((:text-chunk . "All ")))))
        (agent-shell-vertico-sidebar--handle-event
         alpha '((:event . agent-message-chunk)
                 (:data . ((:text-chunk . "done.")))))
        (agent-shell-vertico-sidebar--handle-event
         alpha '((:event . turn-complete))))
      (should (equal notifications
                     (list (list :buffer alpha
                                 :status "Done"
                                 :last-message "All done.")))))))

(ert-deftest agent-shell-vertico-sidebar-does-not-notify-a-watched-session ()
  "Output on screen has already been seen, so it is not announced."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha"))))))
    (let* ((agent-shell-test-buffers (list alpha))
           (agent-shell-test-statuses (list (cons alpha 'busy)))
           notifications
           (agent-shell-vertico-sidebar-notify-function
            (lambda (&rest arguments) (push arguments notifications))))
      (cl-letf (((symbol-function
                  'agent-shell-vertico-sidebar--session-focused-p)
                 (lambda (_buffer) t)))
        (agent-shell-vertico-tests--with-sidebar
          (agent-shell-vertico-sidebar--handle-event
           alpha '((:event . turn-complete)))))
      (should-not notifications))))

(ert-deftest agent-shell-vertico-sidebar-notifies-a-permission-request ()
  "A session that cannot continue without an answer says so."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha"))))))
    (let* ((agent-shell-test-buffers (list alpha))
           (agent-shell-test-statuses (list (cons alpha 'blocked)))
           notifications
           (agent-shell-vertico-sidebar-notify-function
            (lambda (&rest arguments) (push arguments notifications))))
      (agent-shell-vertico-tests--with-sidebar
        (agent-shell-vertico-sidebar--handle-event
         alpha '((:event . permission-request))))
      ;; No agent message has arrived in this session yet.
      (should (equal notifications
                     (list (list :buffer alpha
                                 :status "Waiting"
                                 :last-message nil)))))))

(ert-deftest agent-shell-vertico-sidebar-notifies-a-failed-session ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha"))))))
    (let* ((agent-shell-test-buffers (list alpha))
           (agent-shell-test-statuses (list (cons alpha 'ready)))
           notifications
           (agent-shell-vertico-sidebar-notify-function
            (lambda (&rest arguments) (push arguments notifications))))
      (agent-shell-vertico-tests--with-sidebar
        (agent-shell-vertico-sidebar--handle-event alpha '((:event . error))))
      (should (equal (plist-get (car notifications) :status) "Error")))))

(ert-deftest agent-shell-vertico-sidebar-notifies-a-settled-burst ()
  "Output that arrived outside a turn is announced once it stops."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha"))))))
    (agent-shell-vertico-tests--with-settled-timers
      (let* ((agent-shell-test-buffers (list alpha))
             (agent-shell-test-statuses (list (cons alpha 'ready)))
             notifications
             (agent-shell-vertico-sidebar-notify-function
              (lambda (&rest arguments) (push arguments notifications))))
        (agent-shell-vertico-sidebar--handle-event
         alpha '((:event . agent-message-chunk)
                 (:data . ((:text-chunk . "Background note.")))))
        (should-not notifications)
        (agent-shell-vertico-sidebar--out-of-turn-settled alpha)
        (should (equal notifications
                       (list (list :buffer alpha
                                   :status "Done"
                                   :last-message "Background note."))))))))

(ert-deftest agent-shell-vertico-sidebar-message-ends-at-the-next-event ()
  "Chunks separated by another event belong to different messages."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-test-statuses (list (cons alpha 'busy))))
      (agent-shell-vertico-tests--with-sidebar
        (agent-shell-vertico-sidebar--handle-event
         alpha '((:event . agent-message-chunk)
                 (:data . ((:text-chunk . "First.")))))
        (agent-shell-vertico-sidebar--handle-event
         alpha '((:event . tool-call-update)))
        (agent-shell-vertico-sidebar--handle-event
         alpha '((:event . agent-message-chunk)
                 (:data . ((:text-chunk . "Second.")))))
        (should (equal (agent-shell-vertico-sidebar--last-message alpha)
                       "Second."))))))

(ert-deftest agent-shell-vertico-sidebar-clean-up-forgets-the-last-message ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-test-statuses (list (cons alpha 'busy))))
      (agent-shell-vertico-tests--with-sidebar
        (agent-shell-vertico-sidebar--handle-event
         alpha '((:event . agent-message-chunk)
                 (:data . ((:text-chunk . "Gone.")))))
        (agent-shell-vertico-sidebar--handle-event alpha '((:event . clean-up)))
        (should-not (agent-shell-vertico-sidebar--last-message alpha))))))

;;; Attention jump

(ert-deftest agent-shell-vertico-sidebar-jump-visits-oldest-attention-session ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha")))))
       (beta "Codex Agent @ beta" "/work/beta/"
             '((:session . ((:id . "b") (:title . "Beta"))))))
    (let ((agent-shell-test-buffers (list alpha beta))
          (agent-shell-test-statuses (list (cons alpha 'ready)
                                           (cons beta 'ready))))
      ;; The longest-waiting session is the one to answer first.
      (puthash beta (list :kind 'done :time 100.0)
               agent-shell-vertico-sidebar--attention)
      (puthash alpha (list :kind 'done :time 200.0)
               agent-shell-vertico-sidebar--attention)
      (agent-shell-vertico-sidebar-jump)
      (should (eq agent-shell-test-displayed-buffer beta)))))

(ert-deftest agent-shell-vertico-sidebar-jump-ranks-attention-above-working ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha")))))
       (beta "Codex Agent @ beta" "/work/beta/"
             '((:session . ((:id . "b") (:title . "Beta"))))))
    (let ((agent-shell-test-buffers (list alpha beta))
          (agent-shell-test-statuses (list (cons alpha 'busy)
                                           (cons beta 'ready))))
      (puthash beta (list :kind 'done :time 100.0)
               agent-shell-vertico-sidebar--attention)
      (agent-shell-vertico-sidebar-jump)
      (should (eq agent-shell-test-displayed-buffer beta)))))

(ert-deftest agent-shell-vertico-sidebar-jump-marks-visited-session-seen ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-test-statuses (list (cons alpha 'ready))))
      (puthash alpha (list :kind 'done :time 100.0)
               agent-shell-vertico-sidebar--attention)
      (agent-shell-vertico-sidebar-jump)
      (should (eq agent-shell-test-displayed-buffer alpha))
      (should-not (gethash alpha agent-shell-vertico-sidebar--attention)))))

(ert-deftest agent-shell-vertico-sidebar-jump-keeps-waiting-mark ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-test-statuses (list (cons alpha 'ready))))
      ;; A permission decision is still owed after the visit, so the mark
      ;; stays and the session keeps its place at the head of the list.
      (puthash alpha (list :kind 'blocked :time 100.0)
               agent-shell-vertico-sidebar--attention)
      (agent-shell-vertico-sidebar-jump)
      (should (eq agent-shell-test-displayed-buffer alpha))
      (should (gethash alpha agent-shell-vertico-sidebar--attention)))))

(ert-deftest agent-shell-vertico-sidebar-jump-reports-working-when-nothing-waits ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-test-statuses (list (cons alpha 'busy)))
          messages)
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest arguments)
                   (push (apply #'format format arguments) messages))))
        (agent-shell-vertico-sidebar-jump))
      (should-not agent-shell-test-displayed-buffer)
      (should (equal messages
                     (list "No session needs attention, 1 working"))))))

(ert-deftest agent-shell-vertico-sidebar-jump-reports-nothing-to-answer ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha"))))))
    (let ((agent-shell-test-buffers (list alpha))
          (agent-shell-test-statuses (list (cons alpha 'ready)))
          messages)
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest arguments)
                   (push (apply #'format format arguments) messages))))
        (agent-shell-vertico-sidebar-jump))
      (should-not agent-shell-test-displayed-buffer)
      (should (equal messages (list "No session needs attention"))))))

(ert-deftest agent-shell-vertico-sidebar-jump-prefix-reads-session ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a") (:title . "Alpha")))))
       (beta "Codex Agent @ beta" "/work/beta/"
             '((:session . ((:id . "b") (:title . "Beta"))))))
    (let* ((agent-shell-test-buffers (list alpha beta))
           (agent-shell-test-statuses (list (cons alpha 'ready)
                                            (cons beta 'ready)))
           (agent-shell-vertico-read-session-function
            (lambda (_prompt table &optional _other-window)
              ;; Reading covers every live session, not only the ones
              ;; needing attention.
              (should (equal (sort (all-completions "" table) #'string<)
                             (sort (list (buffer-name alpha)
                                         (buffer-name beta))
                                   #'string<)))
              (buffer-name beta))))
      (puthash alpha (list :kind 'done :time 100.0)
               agent-shell-vertico-sidebar--attention)
      (agent-shell-vertico-sidebar-jump t)
      (should (eq agent-shell-test-displayed-buffer beta)))))

;;; Narrowing and grouping

(ert-deftest agent-shell-vertico-narrow-agent-key-matches-name-prefix ()
  "An agent key matches every name it prefixes, whatever the case."
  (should (agent-shell-vertico--narrow-agent-match-p "Claude" ?c))
  (should (agent-shell-vertico--narrow-agent-match-p "Claude(token)" ?c))
  (should (agent-shell-vertico--narrow-agent-match-p "claude code" ?c))
  (should (agent-shell-vertico--narrow-agent-match-p "Gemini CLI" ?g))
  (should-not (agent-shell-vertico--narrow-agent-match-p "Codex" ?c))
  (should-not (agent-shell-vertico--narrow-agent-match-p "Cla" ?c))
  (should-not (agent-shell-vertico--narrow-agent-match-p nil ?c))
  (should-not (agent-shell-vertico--narrow-agent-match-p "Claude" ?z)))

(ert-deftest agent-shell-vertico-narrow-keys-end-with-the-agent-keys ()
  "A category offers its own keys first, then every configured agent."
  (let* ((agent-shell-vertico-narrow-agent-keys '((?c . "Claude")))
         (keys (agent-shell-vertico--narrow-keys
                agent-shell-vertico--session-narrow-keys)))
    (should (equal (alist-get ?r keys) "Ready"))
    (should (equal (alist-get ?c keys) "Claude"))
    (should (equal (car (last keys)) '(?c . "Claude")))))

(ert-deftest agent-shell-vertico-session-narrow-selects-by-status ()
  (agent-shell-vertico-tests--with-session-buffers
      ((ready "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a")))))
       (starting "Claude Agent @ beta" "/work/beta/" nil))
    (should (agent-shell-vertico--session-narrow-p
             ?r (buffer-name ready) nil))
    (should-not (agent-shell-vertico--session-narrow-p
                 ?r (buffer-name starting) nil))
    (should (agent-shell-vertico--session-narrow-p
             ?s (buffer-name starting) nil))
    (should-not (agent-shell-vertico--session-narrow-p
                 ?s (buffer-name ready) nil))))

(ert-deftest agent-shell-vertico-session-narrow-selects-working ()
  (agent-shell-vertico-tests--with-session-buffers
      ((working "Codex Agent @ alpha" "/work/alpha/"
                '((:session . ((:id . "a"))))))
    (cl-letf (((symbol-function 'shell-maker-busy) (lambda () t)))
      (should (agent-shell-vertico--session-narrow-p
               ?w (buffer-name working) nil))
      (should-not (agent-shell-vertico--session-narrow-p
                   ?r (buffer-name working) nil)))))

(ert-deftest agent-shell-vertico-session-narrow-selects-waiting ()
  "The waiting key finds the session agent-shell reports as blocked."
  (agent-shell-vertico-tests--with-session-buffers
      ((blocked "Codex Agent @ alpha" "/work/alpha/"
                '((:session . ((:id . "a")))))
       (ready "Claude Agent @ beta" "/work/beta/"
              '((:session . ((:id . "b"))))))
    (let ((agent-shell-test-statuses (list (cons blocked 'blocked)
                                           (cons ready 'ready))))
      (should (agent-shell-vertico--session-narrow-p
               ?! (buffer-name blocked) nil))
      (should-not (agent-shell-vertico--session-narrow-p
                   ?! (buffer-name ready) nil)))))

(ert-deftest agent-shell-vertico-session-narrow-selects-queued-prompts ()
  (agent-shell-vertico-tests--with-session-buffers
      ((queued "Codex Agent @ alpha" "/work/alpha/"
               '((:session . ((:id . "a")))
                 (:pending-prompts . ("Next prompt"))))
       (empty "Claude Agent @ beta" "/work/beta/"
              '((:session . ((:id . "b"))))))
    (should (agent-shell-vertico--session-narrow-p
             ?q (buffer-name queued) nil))
    (should-not (agent-shell-vertico--session-narrow-p
                 ?q (buffer-name empty) nil))))

(ert-deftest agent-shell-vertico-session-narrow-selects-by-agent ()
  (agent-shell-vertico-tests--with-session-buffers
      ((codex "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a")))
                (:agent-config . ((:mode-line-name . "Codex")))))
       (claude "Claude Agent @ beta" "/work/beta/"
               '((:session . ((:id . "b")))
                 (:agent-config . ((:mode-line-name . "Claude Code"))))))
    (should (agent-shell-vertico--session-narrow-p
             ?x (buffer-name codex) nil))
    (should (agent-shell-vertico--session-narrow-p
             ?c (buffer-name claude) nil))
    (should-not (agent-shell-vertico--session-narrow-p
                 ?c (buffer-name codex) nil))))

(ert-deftest agent-shell-vertico-session-narrow-reads-the-project-once ()
  "The project key answers for the buffer the command was called from.

The context is built before the minibuffer opens, because the project of
the minibuffer is not the project the reader was asked about."
  (agent-shell-vertico-tests--with-session-buffers
      ((mine "Codex Agent @ alpha" "/work/alpha/"
             '((:session . ((:id . "a")))))
       (other "Claude Agent @ beta" "/work/beta/"
              '((:session . ((:id . "b"))))))
    (let* ((agent-shell-test-project-buffers (list mine))
           (context (agent-shell-vertico--session-narrow-context)))
      (setq agent-shell-test-project-buffers (list other))
      (should (agent-shell-vertico--session-narrow-p
               ?p (buffer-name mine) context))
      (should-not (agent-shell-vertico--session-narrow-p
                   ?p (buffer-name other) context)))))

(ert-deftest agent-shell-vertico-session-narrow-keeps-everything-unnarrowed ()
  "No key in force matches every candidate; an unknown one matches none."
  (agent-shell-vertico-tests--with-session-buffers
      ((ready "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a"))))))
    (should (agent-shell-vertico--session-narrow-p
             nil (buffer-name ready) nil))
    (should-not (agent-shell-vertico--session-narrow-p
                 ?z (buffer-name ready) nil))
    (should-not (agent-shell-vertico--session-narrow-p
                 ?r "No such session" nil))))

(ert-deftest agent-shell-vertico-session-narrow-filters-the-table ()
  "A narrowing predicate reaches the completion table as its predicate."
  (agent-shell-vertico-tests--with-session-buffers
      ((ready "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a")))))
       (starting "Claude Agent @ beta" "/work/beta/" nil))
    (let ((agent-shell-test-buffers (list ready starting))
          (table (agent-shell-vertico--completion-table 'all)))
      (should (equal (all-completions
                      "" table
                      (lambda (candidate)
                        (agent-shell-vertico--session-narrow-p
                         ?r candidate nil)))
                     (list (buffer-name ready)))))))

(ert-deftest agent-shell-vertico-session-group-follows-group-by ()
  (agent-shell-vertico-tests--with-session-buffers
      ((session "Codex Agent @ alpha" "/work/alpha/"
                '((:session . ((:id . "a")))
                  (:agent-config . ((:mode-line-name . "Codex"))))))
    (let ((name (buffer-name session)))
      (let ((agent-shell-vertico-group-by nil))
        (should-not (agent-shell-vertico--session-group name nil)))
      (let ((agent-shell-vertico-group-by 'project))
        (should (equal (agent-shell-vertico--session-group name nil)
                       "/work/alpha/")))
      (let ((agent-shell-vertico-group-by 'agent))
        (should (equal (agent-shell-vertico--session-group name nil)
                       "Codex")))
      (let ((agent-shell-vertico-group-by 'status))
        (should (equal (agent-shell-vertico--session-group name nil)
                       "Ready"))
        (should (equal (agent-shell-vertico--session-group name t) name))))))

(ert-deftest agent-shell-vertico-table-groups-only-when-asked ()
  "The table declares a group function only while grouping is on."
  (let ((table (agent-shell-vertico--completion-table 'all)))
    (let ((agent-shell-vertico-group-by nil))
      (should-not (alist-get 'group-function
                             (cdr (funcall table "" nil 'metadata)))))
    (let ((agent-shell-vertico-group-by 'project))
      (should (eq (alist-get 'group-function
                             (cdr (funcall table "" nil 'metadata)))
                  #'agent-shell-vertico--session-group)))))

(defun agent-shell-vertico-tests--narrow-record (&rest overrides)
  "Return a transcript record for narrowing tests, amended by OVERRIDES."
  (let ((fields (list :file "/tmp/transcripts/session.md"
                      :project-root "/work/alpha/"
                      :project-name "alpha"
                      :agent "Claude"
                      :session-id "abc-123"
                      :modified-time (encode-time 0 0 12 4 8 2026))))
    (while overrides
      (setq fields (plist-put fields (pop overrides) (pop overrides))))
    (apply #'agent-shell-vertico-transcript-record-create fields)))

(ert-deftest agent-shell-vertico-transcript-narrow-selects-by-availability ()
  "The availability keys say the same thing the status column says."
  (let ((resumable (agent-shell-vertico-tests--narrow-record))
        (orphan (agent-shell-vertico-tests--narrow-record :session-id nil)))
    (should (agent-shell-vertico-transcript--record-narrow-p
             ?r resumable nil))
    (should-not (agent-shell-vertico-transcript--record-narrow-p
                 ?t resumable nil))
    (should (agent-shell-vertico-transcript--record-narrow-p ?t orphan nil))
    (should-not (agent-shell-vertico-transcript--record-narrow-p
                 ?l resumable nil))))

(ert-deftest agent-shell-vertico-transcript-narrow-selects-live ()
  "A transcript a shell already holds answers to the live key alone."
  (agent-shell-vertico-tests--with-session-buffers
      ((shell "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "abc-123"))))))
    (let ((agent-shell-test-buffers (list shell))
          (record (agent-shell-vertico-tests--narrow-record)))
      (should (agent-shell-vertico-transcript--record-narrow-p ?l record nil))
      (should-not (agent-shell-vertico-transcript--record-narrow-p
                   ?r record nil)))))

(ert-deftest agent-shell-vertico-transcript-narrow-selects-this-project ()
  (let ((context (list :project "/work/alpha/"))
        (mine (agent-shell-vertico-tests--narrow-record))
        (other (agent-shell-vertico-tests--narrow-record
                :project-root "/work/beta/")))
    (should (agent-shell-vertico-transcript--record-narrow-p ?p mine context))
    (should-not (agent-shell-vertico-transcript--record-narrow-p
                 ?p other context))
    (should-not (agent-shell-vertico-transcript--record-narrow-p ?p mine nil))))

(ert-deftest agent-shell-vertico-transcript-narrow-selects-by-age ()
  "Today means the same calendar day, and the week means seven days back."
  (let* ((now (encode-time 0 0 12 4 8 2026))
         (context (list :now now)))
    (should (agent-shell-vertico-transcript--record-narrow-p
             ?d (agent-shell-vertico-tests--narrow-record
                 :modified-time (encode-time 0 30 9 4 8 2026))
             context))
    (should-not (agent-shell-vertico-transcript--record-narrow-p
                 ?d (agent-shell-vertico-tests--narrow-record
                     :modified-time (encode-time 0 0 23 3 8 2026))
                 context))
    (should (agent-shell-vertico-transcript--record-narrow-p
             ?w (agent-shell-vertico-tests--narrow-record
                 :modified-time (encode-time 0 0 12 30 7 2026))
             context))
    (should-not (agent-shell-vertico-transcript--record-narrow-p
                 ?w (agent-shell-vertico-tests--narrow-record
                     :modified-time (encode-time 0 0 12 20 7 2026))
                 context))))

(ert-deftest agent-shell-vertico-transcript-narrow-selects-by-agent ()
  (should (agent-shell-vertico-transcript--record-narrow-p
           ?c (agent-shell-vertico-tests--narrow-record :agent "Claude Code")
           nil))
  (should-not (agent-shell-vertico-transcript--record-narrow-p
               ?c (agent-shell-vertico-tests--narrow-record :agent "Codex")
               nil))
  (should (agent-shell-vertico-transcript--record-narrow-p
           ?x (agent-shell-vertico-tests--narrow-record :agent "Codex")
           nil)))

(ert-deftest agent-shell-vertico-transcript-narrow-reads-the-candidate ()
  "A narrowing key is answered from the record the candidate carries."
  (let* ((record (agent-shell-vertico-tests--narrow-record))
         (candidate
          (agent-shell-vertico-transcript--record-candidate record 0)))
    (should (agent-shell-vertico-transcript--narrow-p ?r candidate nil))
    (should-not (agent-shell-vertico-transcript--narrow-p ?t candidate nil))
    (should (agent-shell-vertico-transcript--narrow-p nil candidate nil))
    (should-not (agent-shell-vertico-transcript--narrow-p ?r "Not a record"
                                                          nil))))

(ert-deftest agent-shell-vertico-transcript-group-follows-group-by ()
  (let* ((record (agent-shell-vertico-tests--narrow-record))
         (candidate
          (agent-shell-vertico-transcript--record-candidate record 0)))
    (let ((agent-shell-vertico-group-by nil))
      (should-not (agent-shell-vertico-transcript--group candidate nil)))
    (let ((agent-shell-vertico-group-by 'project))
      (should (equal (agent-shell-vertico-transcript--group candidate nil)
                     "alpha")))
    (let ((agent-shell-vertico-group-by 'agent))
      (should (equal (agent-shell-vertico-transcript--group candidate nil)
                     "Claude")))
    (let ((agent-shell-vertico-group-by 'status))
      (should (equal (agent-shell-vertico-transcript--group candidate nil)
                     "Resumable"))
      (should (equal (agent-shell-vertico-transcript--group candidate t)
                     candidate)))))

(ert-deftest agent-shell-vertico-transcript-read-groups-only-when-asked ()
  "The plain transcript reader declares a group function only when asked."
  (let ((records (list (agent-shell-vertico-tests--narrow-record)))
        metadata)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt table &rest _arguments)
                 (setq metadata (funcall table "" nil 'metadata))
                 (car (all-completions "" table)))))
      (let ((agent-shell-vertico-group-by nil))
        (agent-shell-vertico-transcript--completing-read-record
         "Transcript: " records)
        (should-not (alist-get 'group-function (cdr metadata))))
      (let ((agent-shell-vertico-group-by 'project))
        (agent-shell-vertico-transcript--completing-read-record
         "Transcript: " records)
        (should (eq (alist-get 'group-function (cdr metadata))
                    #'agent-shell-vertico-transcript--group))))))

(ert-deftest agent-shell-vertico-resume-narrow-selects-by-availability ()
  "The picker's keys separate taken sessions, and transcripts from strangers."
  (agent-shell-vertico-tests--with-session-buffers
      ((shell "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "live-1"))))))
    (let* ((agent-shell-test-buffers (list shell))
           (record (agent-shell-vertico-tests--narrow-record))
           (live (agent-shell-vertico-resume--candidate
                  "live-1  Alpha"
                  (agent-shell-vertico-tests--acp-session "live-1")
                  record))
           (resumable (agent-shell-vertico-resume--candidate
                       "abc-123  Alpha"
                       (agent-shell-vertico-tests--acp-session "abc-123")
                       record))
           (unknown (agent-shell-vertico-resume--candidate
                     "def-456  Elsewhere"
                     (agent-shell-vertico-tests--acp-session "def-456")
                     nil))
           (new-shell (agent-shell-vertico-resume--candidate
                       "Start a new shell" nil nil)))
      (should (agent-shell-vertico-resume--narrow-p ?l live nil))
      (should-not (agent-shell-vertico-resume--narrow-p ?r live nil))
      (should (agent-shell-vertico-resume--narrow-p ?r resumable nil))
      (should (agent-shell-vertico-resume--narrow-p ?h resumable nil))
      (should-not (agent-shell-vertico-resume--narrow-p ?n resumable nil))
      (should (agent-shell-vertico-resume--narrow-p ?n unknown nil))
      (should-not (agent-shell-vertico-resume--narrow-p ?h unknown nil))
      (should-not (agent-shell-vertico-resume--narrow-p ?r new-shell nil))
      (should (agent-shell-vertico-resume--narrow-p nil new-shell nil)))))

(ert-deftest agent-shell-vertico-resume-narrow-selects-by-agent ()
  "The picker narrows by agent through the transcript it was joined to."
  (let* ((candidate
          (agent-shell-vertico-resume--candidate
           "abc-123  Alpha"
           (agent-shell-vertico-tests--acp-session "abc-123")
           (agent-shell-vertico-tests--narrow-record :agent "Codex"))))
    (should (agent-shell-vertico-resume--narrow-p ?x candidate nil))
    (should-not (agent-shell-vertico-resume--narrow-p ?c candidate nil))))

(ert-deftest agent-shell-vertico-prompt-queue-narrow-separates-actions ()
  "Pending prompts and the queue-wide entries narrow apart."
  (agent-shell-vertico-tests--with-queue '("First prompt"
                                           "Second\nprompt line")
    (let ((prompt (nth 0 candidates))
          (multi-line (nth 1 candidates))
          (action (nth 2 candidates)))
      (should (agent-shell-vertico-prompt-queue--narrow-p ?p prompt nil))
      (should-not (agent-shell-vertico-prompt-queue--narrow-p ?a prompt nil))
      (should (agent-shell-vertico-prompt-queue--narrow-p ?a action nil))
      (should-not (agent-shell-vertico-prompt-queue--narrow-p ?p action nil))
      (should (agent-shell-vertico-prompt-queue--narrow-p ?m multi-line nil))
      (should-not (agent-shell-vertico-prompt-queue--narrow-p
                   ?m prompt nil)))))

(ert-deftest agent-shell-vertico-consult-session-reader-narrows-by-key ()
  "The session reader offers the session keys and answers for the key held."
  (agent-shell-vertico-tests--with-session-buffers
      ((ready "Codex Agent @ alpha" "/work/alpha/"
              '((:session . ((:id . "a")))))
       (starting "Claude Agent @ beta" "/work/beta/" nil))
    (let ((agent-shell-test-buffers (list ready starting))
          options)
      (cl-letf (((symbol-function 'consult--read)
                 (lambda (_table &rest arguments)
                   (setq options arguments)
                   (buffer-name ready))))
        (agent-shell-vertico-consult--read-session
         "Session: " (agent-shell-vertico--completion-table 'all)))
      (let ((narrow (plist-get options :narrow)))
        (should (equal (alist-get ?r (plist-get narrow :keys)) "Ready"))
        (should (equal (alist-get ?c (plist-get narrow :keys)) "Claude"))
        (let ((consult--narrow ?r))
          (should (funcall (plist-get narrow :predicate)
                           (buffer-name ready)))
          (should-not (funcall (plist-get narrow :predicate)
                               (buffer-name starting))))))))

(ert-deftest agent-shell-vertico-consult-record-reader-narrows-by-key ()
  (let ((records (list (agent-shell-vertico-tests--narrow-record)
                       (agent-shell-vertico-tests--narrow-record
                        :file "/tmp/transcripts/orphan.md"
                        :session-id nil)))
        options
        offered)
    (cl-letf (((symbol-function 'consult--temporary-files)
               (lambda () (lambda (&rest _arguments))))
              ((symbol-function 'consult--jump-preview)
               (lambda () (lambda (&rest _arguments))))
              ((symbol-function 'consult--read)
               (lambda (candidates &rest arguments)
                 (setq options arguments
                       offered candidates)
                 (car candidates))))
      (agent-shell-vertico-consult--read-record "Transcript: " records))
    (let ((narrow (plist-get options :narrow)))
      (should (equal (alist-get ?l (plist-get narrow :keys)) "Live"))
      (let ((consult--narrow ?r))
        (should (funcall (plist-get narrow :predicate) (nth 0 offered)))
        (should-not (funcall (plist-get narrow :predicate)
                             (nth 1 offered)))))))

(ert-deftest agent-shell-vertico-consult-readers-group-only-when-asked ()
  "A Consult reader passes a group function only while grouping is on."
  (let ((records (list (agent-shell-vertico-tests--narrow-record)))
        options)
    (cl-letf (((symbol-function 'consult--temporary-files)
               (lambda () (lambda (&rest _arguments))))
              ((symbol-function 'consult--jump-preview)
               (lambda () (lambda (&rest _arguments))))
              ((symbol-function 'consult--read)
               (lambda (candidates &rest arguments)
                 (setq options arguments)
                 (car candidates))))
      (let ((agent-shell-vertico-group-by nil))
        (agent-shell-vertico-consult--read-record "Transcript: " records)
        (should-not (plist-get options :group)))
      (let ((agent-shell-vertico-group-by 'project))
        (agent-shell-vertico-consult--read-record "Transcript: " records)
        (should (eq (plist-get options :group)
                    #'agent-shell-vertico-transcript--group))))))

(ert-deftest agent-shell-vertico-consult-choice-reader-narrows-by-key ()
  (let* ((candidate
          (agent-shell-vertico-resume--candidate
           "abc-123  Alpha"
           (agent-shell-vertico-tests--acp-session "abc-123")
           (agent-shell-vertico-tests--narrow-record)))
         options)
    (cl-letf (((symbol-function 'consult--temporary-files)
               (lambda () (lambda (&rest _arguments))))
              ((symbol-function 'consult--jump-preview)
               (lambda () (lambda (&rest _arguments))))
              ((symbol-function 'consult--read)
               (lambda (candidates &rest arguments)
                 (setq options arguments)
                 (car candidates))))
      (agent-shell-vertico-consult--read-session-choice
       "Session: " (list candidate) nil))
    (let ((narrow (plist-get options :narrow)))
      (should (equal (alist-get ?h (plist-get narrow :keys))
                     "Transcript here"))
      (let ((consult--narrow ?h))
        (should (funcall (plist-get narrow :predicate) candidate)))
      (let ((consult--narrow ?n))
        (should-not (funcall (plist-get narrow :predicate) candidate))))))

(ert-deftest agent-shell-vertico-consult-queue-reader-narrows-by-key ()
  (agent-shell-vertico-tests--with-queue '("First prompt")
    (let (options)
      (cl-letf (((symbol-function 'consult--read)
                 (lambda (offered &rest arguments)
                   (setq options arguments)
                   (car offered))))
        (agent-shell-vertico-consult--read-prompt-queue
         "Prompt: " candidates))
      (let ((narrow (plist-get options :narrow)))
        (should (equal (alist-get ?a (plist-get narrow :keys))
                       "Queue action"))
        (let ((consult--narrow ?p))
          (should (funcall (plist-get narrow :predicate) (nth 0 candidates)))
          (should-not (funcall (plist-get narrow :predicate)
                               (nth 1 candidates))))))))

(ert-deftest agent-shell-vertico-consult-search-narrows-by-key ()
  "Transcript search narrows over the same keys the browser does."
  (let* ((record (agent-shell-vertico-tests--narrow-record))
         (candidate (agent-shell-vertico-consult--candidate record))
         options)
    (cl-letf
        (((symbol-function
           'agent-shell-vertico-transcript--search-directories)
          (lambda (_roots) '("/tmp/transcripts")))
         ((symbol-function 'consult--process-collection)
          (lambda (_builder &rest _properties) 'async-table))
         ((symbol-function 'consult--read)
          (lambda (_table &rest arguments)
            (setq options arguments)
            candidate))
         ((symbol-function 'consult--temporary-files)
          (lambda () (lambda (&rest _arguments))))
         ((symbol-function 'consult--jump-preview)
          (lambda () (lambda (&rest _arguments))))
         ((symbol-function 'agent-shell-vertico-transcript--open-record)
          (lambda (_selected &optional _other-window) nil)))
      (agent-shell-vertico-consult--search '("/work/project/")))
    (let ((narrow (plist-get options :narrow)))
      (should (equal (alist-get ?r (plist-get narrow :keys)) "Resumable"))
      (let ((consult--narrow ?r))
        (should (funcall (plist-get narrow :predicate) candidate))))))

(provide 'agent-shell-vertico-tests)

;;; agent-shell-vertico-tests.el ends here
