;;; agent-shell-vertico-tests.el --- Tests for agent-shell-vertico -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'map)

(add-to-list 'load-path (expand-file-name "tests/support" default-directory))
(add-to-list 'load-path default-directory)

(require 'agent-shell-vertico)
(require 'agent-shell-vertico-transcript)

;; Declare as a dynamic variable so `let' bindings below are dynamic and
;; visible to functions under test. Mirrors how the real `embark-keymap-alist'
;; is declared by embark.el.
(defvar embark-keymap-alist)
(defvar embark-default-action-overrides)
(defvar embark-target-finders)
(defvar agent-shell-viewport-view-mode-hook)

(cl-defun agent-shell-vertico-tests--insert-block
    (&key qid kind group-id label-left label-right body (navigatable t))
  "Insert a fragment block mimicking `agent-shell-ui--insert-fragment'.
QID is the qualified id; LABEL-LEFT, LABEL-RIGHT, and BODY are the
section texts; NAVIGATABLE sets the `:navigatable' state flag.  KIND is
the fragment `:kind' (`group' for an activity-group header); GROUP-ID is
the qualified id of the header this block nests under.  Return the block
start position."
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
                             (cons :collapsed nil)
                             (cons :navigatable navigatable)))
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
                    ((symbol-value 'agent-shell-test-displayed-buffer) nil)
                    ((symbol-value 'agent-shell-test-viewport-buffer) nil)
                    ((symbol-value 'agent-shell-agent-configs) nil))
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
       (mapc #'kill-buffer created))))

(ert-deftest agent-shell-vertico-completion-table-adds-agent-shell-metadata ()
  (let ((metadata (funcall (agent-shell-vertico--completion-table 'all)
                           "" nil 'metadata)))
    (should (equal (cdr (assq 'category (cdr metadata)))
                   'agent-shell-session))
    (should (functionp (cdr (assq 'affixation-function (cdr metadata)))))))

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
    (agent-shell-vertico-open-transcript (buffer-name alpha))
    (should (eq agent-shell-test-last-command 'agent-shell-open-transcript))
    (should (eq agent-shell-test-last-buffer alpha))))

(ert-deftest agent-shell-vertico-kill-session-sends-eof-for-target-buffer ()
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/"
              '((:client . ((:process . fake-proc)))))) 
    (let (called)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                ((symbol-function 'process-live-p) (lambda (_process) t))
                ((symbol-function 'comint-send-eof)
                 (lambda (&optional process)
                   (setq called process))))
        (agent-shell-vertico-kill-session (buffer-name alpha))
        (should (eq called nil))))))

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

(ert-deftest agent-shell-vertico-display-session-clears-attention-shell-buffer ()
  "Jumping clears `agent-shell-attention' state for the shell buffer.
Even when the viewport buffer is what gets displayed, the pending mark
keyed on the shell buffer must be cleared."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/" '((:session . ((:id . "a")))))
       (vp "Alpha Agent @ alpha [viewport]" "/tmp/alpha/" nil))
    (let ((agent-shell-prefer-viewport-interaction t)
          (agent-shell-test-viewport-buffer vp)
          cleared)
      (cl-letf (((symbol-function 'agent-shell-attention--clear-buffer)
                 (lambda (buffer) (setq cleared buffer)))
                ((symbol-function 'agent-shell-attention--permission-pending-p)
                 (lambda (_buffer) nil)))
        (agent-shell-vertico--display-session (buffer-name alpha))
        (should (eq agent-shell-test-displayed-buffer vp))
        (should (eq cleared alpha))))))

(ert-deftest agent-shell-vertico-display-session-keeps-pending-on-permission ()
  "A session awaiting a permission decision keeps its attention mark."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/" '((:session . ((:id . "a"))))))
    (let ((agent-shell-prefer-viewport-interaction nil)
          cleared)
      (cl-letf (((symbol-function 'agent-shell-attention--clear-buffer)
                 (lambda (buffer) (setq cleared buffer)))
                ((symbol-function 'agent-shell-attention--permission-pending-p)
                 (lambda (_buffer) t)))
        (agent-shell-vertico--display-session (buffer-name alpha))
        (should (eq agent-shell-test-displayed-buffer alpha))
        (should (null cleared))))))

(ert-deftest agent-shell-vertico-display-session-other-window-clears-attention ()
  "The other-window jump also clears `agent-shell-attention' state."
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/" '((:session . ((:id . "a")))))
       (vp "Alpha Agent @ alpha [viewport]" "/tmp/alpha/" nil))
    (let ((agent-shell-prefer-viewport-interaction t)
          (agent-shell-test-viewport-buffer vp)
          cleared)
      (cl-letf (((symbol-function 'switch-to-buffer-other-window) #'ignore)
                ((symbol-function 'agent-shell-attention--clear-buffer)
                 (lambda (buffer) (setq cleared buffer)))
                ((symbol-function 'agent-shell-attention--permission-pending-p)
                 (lambda (_buffer) nil)))
        (agent-shell-vertico--display-session-other-window (buffer-name alpha))
        (should (eq cleared alpha))))))

(ert-deftest agent-shell-vertico-display-session-without-attention-is-noop ()
  "Jumping still displays when `agent-shell-attention' is not loaded."
  (skip-unless (not (fboundp 'agent-shell-attention--clear-buffer)))
  (agent-shell-vertico-tests--with-session-buffers
      ((alpha "Alpha Agent @ alpha" "/tmp/alpha/" '((:session . ((:id . "a"))))))
    (let ((agent-shell-prefer-viewport-interaction nil))
      (agent-shell-vertico--display-session (buffer-name alpha))
      (should (eq agent-shell-test-displayed-buffer alpha)))))

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
           (internal (mapcar #'car (cdr (assoc "Internal" index))))
           (response (mapcar #'car (cdr (assoc "Response" index)))))
      ;; Intermediate narration and the tool are Internal; the last message
      ;; chunk of each interaction is the Response.
      (should (equal internal '("Let me start" "Read foo")))
      (should (equal response '("Final answer one" "Final answer two"))))))

(ert-deftest agent-shell-vertico-imenu-index-groups-internal-and-response ()
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
           (internal (cdr (assoc "Internal" index)))
           (response (cdr (assoc "Response" index))))
      (should (equal (mapcar #'car internal)
                     '("Read README.org"
                       "Let me look at the config"
                       "1. step one")))
      (should (equal (mapcar #'car response)
                     '("Here is the final answer")))
      (should (integerp (cdr (car internal))))
      ;; No requests outside `agent-shell-mode'.
      (should-not (assoc "Request" index)))))

(ert-deftest agent-shell-vertico-imenu-nests-group-members-under-header ()
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
           (internal (cdr (assoc "Internal" index)))
           (response (mapcar #'car (cdr (assoc "Response" index))))
           (group (assoc "✓ Tool calls 2/2" internal)))
      ;; The header is a submenu; its members nest beneath it in call order.
      (should group)
      (should (equal (mapcar #'car (cdr group))
                     '("Read README.org" "Edit init.el")))
      ;; Members carry real buffer positions and their status annotation.
      (should (integerp (cdr (cadr group))))
      (should (string-match-p
               "completed read"
               (agent-shell-vertico--imenu-annotation (car (cadr group)))))
      ;; The header and the ungrouped plan are the only top-level Internal
      ;; entries — members do not also appear flat.
      (should (equal (mapcar #'car internal)
                     '("✓ Tool calls 2/2" "1. step one")))
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
  (should-not (agent-shell-vertico--imenu-annotation "plain imenu item"))
  (with-temp-buffer
    (agent-shell-vertico-tests--insert-block
     :qid "1-call_abc" :label-left "completed read"
     :label-right "Read README.org" :body "x\ny\nz" :navigatable t)
    (let* ((index (agent-shell-vertico--imenu-index))
           (candidate (car (car (cdr (assoc "Internal" index)))))
           (annotation (agent-shell-vertico--imenu-annotation candidate)))
      (should (stringp annotation))
      (should (string-match-p "completed read" annotation)))))

(ert-deftest agent-shell-vertico-imenu-setup-installs-index-function ()
  (with-temp-buffer
    (agent-shell-vertico--imenu-setup)
    (should (eq imenu-create-index-function
                #'agent-shell-vertico--imenu-index))
    (should imenu-auto-rescan)
    ;; imenu's own hard truncation is disabled so our ellipsized truncation
    ;; is authoritative.
    (should (null imenu-max-item-length))))

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
        used)
    (cl-letf (((symbol-function 'find-file)
               (lambda (&rest _) (setq used 'same)))
              ((symbol-function 'find-file-other-window)
               (lambda (&rest _) (setq used 'other))))
      (agent-shell-vertico-open-markdown-link "file:foo.el#L10")
      (should (equal agent-shell-test-opened-link "file:foo.el#L10"))
      (should (eq used 'same)))))

(ert-deftest agent-shell-vertico-open-markdown-link-other-window-uses-other-window ()
  (let ((agent-shell-test-opened-link nil)
        used)
    (cl-letf (((symbol-function 'find-file)
               (lambda (&rest _) (setq used 'same)))
              ((symbol-function 'find-file-other-window)
               (lambda (&rest _) (setq used 'other))))
      (agent-shell-vertico-open-markdown-link-other-window "file:foo.el#L10")
      (should (equal agent-shell-test-opened-link "file:foo.el#L10"))
      (should (eq used 'other)))))

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
  (let ((projectile-mode t)
        (projectile-current-project-on-switch 'remove))
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

(provide 'agent-shell-vertico-tests)

;;; agent-shell-vertico-tests.el ends here
