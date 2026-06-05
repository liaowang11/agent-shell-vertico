;;; agent-shell-vertico-tests.el --- Tests for agent-shell-vertico -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'map)

(add-to-list 'load-path (expand-file-name "tests/support" default-directory))
(add-to-list 'load-path default-directory)

(require 'agent-shell-vertico)

;; Declare as a dynamic variable so `let' bindings below are dynamic and
;; visible to functions under test. Mirrors how the real `embark-keymap-alist'
;; is declared by embark.el.
(defvar embark-keymap-alist)
(defvar embark-default-action-overrides)

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
        (embark-default-action-overrides nil))
    (agent-shell-vertico-setup-embark)
    (should (equal (car embark-keymap-alist)
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
        (embark-default-action-overrides nil))
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

(provide 'agent-shell-vertico-tests)

;;; agent-shell-vertico-tests.el ends here
