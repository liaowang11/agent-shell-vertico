;;; transcript-so-long-reproduction.el --- Reproduce transcript header issue -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'so-long)
(when (and (featurep 'agent-shell)
           (not (bound-and-true-p agent-shell-test-stub-p)))
  (user-error "Tests require isolated Emacs with the agent-shell stub"))
(require 'agent-shell)
(unless (bound-and-true-p agent-shell-test-stub-p)
  (user-error "Tests require isolated Emacs with the agent-shell stub"))
(require 'agent-shell-vertico-transcript)

(ert-deftest transcript-header-survives-so-long-on-open ()
  "A long-line transcript opened through the reader has its header."
  (let ((file (make-temp-file "transcript-so-long-" nil ".md"))
        (so-long-threshold 100)
        (so-long-target-modes '(text-mode))
        (so-long-minor-modes nil)
        (so-long-seen nil)
        buffer)
    (unwind-protect
        (save-window-excursion
          (with-temp-file file
            (insert "## User\n\n" (make-string 1000 ?x)
                    "\n\n## Agent's Thoughts\n\nsecret\n"
                    "\n## Agent\n\nanswer\n"))
          (let ((so-long-hook
                 (cons (lambda () (setq so-long-seen t)) so-long-hook)))
            (global-so-long-mode 1)
            (cl-letf (((symbol-function
                        'agent-shell-vertico-transcript--markdown-major-mode)
                       (lambda () 'text-mode)))
              (setq buffer
                    (agent-shell-vertico-transcript--open-record
                     (agent-shell-vertico-transcript-record-create
                      :file file :agent "Test")))
              (with-current-buffer buffer
                (should so-long-detected-p)
                (should header-line-format)
                ;; Batch Emacs does not redisplay.  Run the deferred window
                ;; hook that normally fires when the buffer is displayed.
                (should (memq #'so-long window-configuration-change-hook))
                (run-hooks 'window-configuration-change-hook)
                (should so-long-seen)
                (should header-line-format)
                (should agent-shell-vertico-transcript-mode)
                (should (eq major-mode 'so-long-mode))
                (should agent-shell-vertico-transcript--clean-view-p)
                (goto-char (point-min))
                (search-forward "secret")
                (should (invisible-p (1- (point))))
                (goto-char (point-min))
                (agent-shell-vertico-transcript-next-agent)
                (should (looking-at "## Agent"))
                (should buffer-read-only)
                (should (string-match-p
                         "Test"
                         (agent-shell-vertico-transcript--header-line)))
                (agent-shell-vertico-transcript-clean-view)
                (should-not agent-shell-vertico-transcript--clean-view-p)
                (so-long-revert)
                (should (eq major-mode 'text-mode))
                (should agent-shell-vertico-transcript-mode)
                (should header-line-format)
                (should-not agent-shell-vertico-transcript--clean-view-p)
                (should buffer-read-only)))))
      (global-so-long-mode -1)
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-file file))))

(ert-deftest transcript-header-survives-so-long-after-open ()
  "A transcript reader retains its header if so-long is invoked later."
  (let ((file (make-temp-file "transcript-so-long-" nil ".md")) buffer)
    (unwind-protect
        (save-window-excursion
          (with-temp-file file (insert "## User\n\nhello\n"))
          (cl-letf (((symbol-function
                      'agent-shell-vertico-transcript--markdown-major-mode)
                     (lambda () 'text-mode)))
            (setq buffer
                  (agent-shell-vertico-transcript--open-record
                   (agent-shell-vertico-transcript-record-create
                    :file file :agent "Test"))))
          (with-current-buffer buffer
            (should header-line-format)
            (so-long)
            (should header-line-format)
            (should agent-shell-vertico-transcript-mode)))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-file file))))

(ert-deftest transcript-reader-disabled-stays-disabled-with-so-long ()
  "Disabling the reader prevents it returning on a later mode change."
  (let ((file (make-temp-file "transcript-so-long-" nil ".md")) buffer)
    (unwind-protect
        (save-window-excursion
          (with-temp-file file (insert "## User\n\nhello\n"))
          (setq buffer
                (agent-shell-vertico-transcript--open-record
                 (agent-shell-vertico-transcript-record-create
                  :file file :agent "Test")))
          (with-current-buffer buffer
            (agent-shell-vertico-transcript-mode -1)
            (so-long)
            (should (eq major-mode 'so-long-mode))
            (should-not agent-shell-vertico-transcript-mode)
            (should-not header-line-format)))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-file file))))

(ert-deftest transcript-reader-preserves-immediate-so-long ()
  "The reader does not replace so-long when it activates during the visit."
  (let ((file (make-temp-file "transcript-so-long-" nil ".md"))
        (so-long-threshold 100)
        (so-long-target-modes '(text-mode))
        (so-long-invisible-buffer-function nil)
        buffer)
    (unwind-protect
        (save-window-excursion
          (with-temp-file file
            (insert "## User\n\n" (make-string 1000 ?x) "\n"))
          (global-so-long-mode 1)
          (cl-letf (((symbol-function
                      'agent-shell-vertico-transcript--markdown-major-mode)
                     (lambda () 'text-mode)))
            (setq buffer
                  (agent-shell-vertico-transcript--open-record
                   (agent-shell-vertico-transcript-record-create
                    :file file :agent "Test"))))
          (with-current-buffer buffer
            (should (eq major-mode 'so-long-mode))
            (should agent-shell-vertico-transcript-mode)
            (should header-line-format)
            (should buffer-read-only)))
      (global-so-long-mode -1)
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-file file))))

(ert-deftest transcript-reader-keeps-existing-so-long ()
  "Opening an already protected transcript retains its major mode."
  (let ((file (make-temp-file "transcript-so-long-" nil ".md")) buffer)
    (unwind-protect
        (save-window-excursion
          (with-temp-file file (insert "## User\n\nhello\n"))
          (setq buffer (find-file-noselect file))
          (with-current-buffer buffer (so-long))
          (cl-letf (((symbol-function
                      'agent-shell-vertico-transcript--markdown-major-mode)
                     (lambda () 'text-mode)))
            (agent-shell-vertico-transcript--open-record
             (agent-shell-vertico-transcript-record-create
              :file file :agent "Test")))
          (with-current-buffer buffer
            (should (eq major-mode 'so-long-mode))
            (should agent-shell-vertico-transcript-mode)
            (should header-line-format)))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-file file))))
