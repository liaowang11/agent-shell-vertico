;;; agent-shell-vertico-tests.el --- Tests for agent-shell-vertico -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'map)

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
(require 'agent-shell-vertico-consult)

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
                    ((symbol-value 'agent-shell-test-statuses) nil)
                    ((symbol-value 'agent-shell-test-subscriptions) nil)
                    ((symbol-value 'agent-shell-test-displayed-buffer) nil)
                    ((symbol-value 'agent-shell-test-viewport-buffer) nil)
                    ((symbol-value 'agent-shell-agent-configs) nil)
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
       (mapc #'kill-buffer created))))

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
        (should (= (count-lines (point-min) (point-max)) 1))
        (should-not (eq (get-text-property
                         (point-min) 'agent-shell-vertico-sidebar-node-kind)
                        'project))))))

(ert-deftest agent-shell-vertico-sidebar-default-extra-info ()
  (should (equal
           (default-value 'agent-shell-vertico-sidebar-extra-info)
           '(status project model mode activity)))
  (should-not
   (memq 'last-user-message
         (default-value 'agent-shell-vertico-sidebar-extra-info))))

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
                 '("✓ Review alpha" "  ↳ Find the failing test")))))))

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
                 '("✓ Review alpha" "  Plan · Ready" "  GPT-5")))))))

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
          (should
           (equal (substring-no-properties header)
                  " 4 sessions · ▲1 · ◆1 · ✓1 · ○1"))
          (should (<= (string-width header) 34))
          (let ((position (string-match
                           "▲1" (substring-no-properties header))))
            (should position)
            (should (equal (get-text-property position 'help-echo header)
                           "attention"))))))))

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
          (agent-shell-vertico-sidebar-show-details nil))
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
          (agent-shell-vertico-sidebar-show-details nil))
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
          (agent-shell-vertico-sidebar-show-details nil))
      (with-temp-buffer
        (agent-shell-vertico-sidebar-mode)
        (agent-shell-vertico-sidebar--render)
        (search-forward "Review alpha")
        (beginning-of-line)
        (call-interactively
         (lookup-key agent-shell-vertico-sidebar-mode-map (kbd "TAB")))
        (should (= (how-many "Ready" (point-min) (point-max)) 1))
        (should (string-match-p "Ready · alpha" (buffer-string)))
        (should-not (string-match-p "Ready · beta" (buffer-string)))))))

(ert-deftest agent-shell-vertico-sidebar-binds-both-tab-events ()
  (should (eq (lookup-key agent-shell-vertico-sidebar-mode-map (kbd "TAB"))
              #'agent-shell-vertico-sidebar-toggle-at-point))
  (should (eq (lookup-key agent-shell-vertico-sidebar-mode-map
                           (kbd "<tab>"))
              #'agent-shell-vertico-sidebar-toggle-at-point)))

(ert-deftest agent-shell-vertico-sidebar-binds-both-shift-tab-events ()
  (should (eq (lookup-key agent-shell-vertico-sidebar-mode-map
                           (kbd "S-TAB"))
              #'agent-shell-vertico-sidebar-toggle-details))
  (should (eq (lookup-key agent-shell-vertico-sidebar-mode-map
                           (kbd "<backtab>"))
              #'agent-shell-vertico-sidebar-toggle-details))
  (should-not (lookup-key agent-shell-vertico-sidebar-mode-map (kbd "v"))))

(ert-deftest agent-shell-vertico-sidebar-action-prefix-preserves-k-navigation ()
  (should (eq (lookup-key agent-shell-vertico-sidebar-mode-map (kbd "k"))
              #'agent-shell-vertico-sidebar-kill))
  (should (eq (lookup-key agent-shell-vertico-sidebar-mode-map (kbd "C-c k"))
              #'agent-shell-vertico-sidebar-kill))
  (should (eq (lookup-key agent-shell-vertico-sidebar-mode-map (kbd "C-c o"))
              #'agent-shell-vertico-sidebar-open)))

(ert-deftest agent-shell-vertico-sidebar-evil-bindings-keep-jk-navigation ()
  (should (eq (cdr (assoc "j"
                          agent-shell-vertico-sidebar--evil-bindings))
              #'evil-next-line))
  (should (eq (cdr (assoc "k"
                          agent-shell-vertico-sidebar--evil-bindings))
              #'evil-previous-line))
  (should (eq (cdr (assoc "D"
                          agent-shell-vertico-sidebar--evil-bindings))
              #'agent-shell-vertico-sidebar-kill))
  (should (eq (cdr (assoc "TAB"
                          agent-shell-vertico-sidebar--evil-bindings))
              #'agent-shell-vertico-sidebar-toggle-at-point))
  (should (eq (cdr (assoc "S-TAB"
                          agent-shell-vertico-sidebar--evil-bindings))
              #'agent-shell-vertico-sidebar-toggle-details))
  (should (eq (cdr (assoc "<backtab>"
                          agent-shell-vertico-sidebar--evil-bindings))
              #'agent-shell-vertico-sidebar-toggle-details))
  (should-not (assoc "v" agent-shell-vertico-sidebar--evil-bindings)))

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

(ert-deftest agent-shell-vertico-sidebar-aligns-truncated-title-ellipsis ()
  (let* ((title (make-string 140 ?x))
         (display (agent-shell-vertico-sidebar--title-display-text title))
         (lines (agent-shell-vertico-sidebar--wrap-text display 34))
         (last-line (car (last lines))))
    (should (string-suffix-p "…" last-line))
    (should (= (string-width last-line) 34))))

(ert-deftest agent-shell-vertico-sidebar-relative-time-calls-recent-now ()
  (should (equal (agent-shell-vertico-sidebar--relative-time
                  (float-time))
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
              #'agent-shell-vertico-sidebar-open))
  (should (eq (lookup-key agent-shell-vertico-sidebar-mode-map
                           (kbd "<return>"))
              #'agent-shell-vertico-sidebar-open)))

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
          (should (eq (get-text-property (1+ boundary) 'mouse-face)
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

(ert-deftest agent-shell-vertico-transcript-clean-text-removes-tool-sections ()
  (let ((clean
         (agent-shell-vertico-transcript--clean-text
          (concat
           "# Agent Shell Transcript\n\n---\n\n"
           "## User (one)\n\nQuestion\n\n"
           "## Agent (one)\n\nAnswer\n\n"
           "### Tool Call: rg\n\nInternal output\n\n"
           "## User (two)\n\nFollow-up\n\n"
           "## Agent (two)\n\nFinal\n"))))
    (should (string-match-p "Question" clean))
    (should (string-match-p "Answer" clean))
    (should (string-match-p "Follow-up" clean))
    (should (string-match-p "Final" clean))
    (should-not (string-match-p "Tool Call" clean))
    (should-not (string-match-p "Internal output" clean))))

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
                 'agent-shell-vertico-transcript--live-buffer)
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

(provide 'agent-shell-vertico-tests)

;;; agent-shell-vertico-tests.el ends here
