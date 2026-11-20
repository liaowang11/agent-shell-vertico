;;; consult.el --- Test stub for Consult -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defvar consult-fontify-preserve t
  "Stubbed Consult option.
Non-nil copies buffer text properties onto completion candidates.")

(defvar consult-preview-partial-size (* 1024 1024)
  "Stubbed Consult option.
Files at least this large are previewed from their first chunk only.")

(defvar consult-line-start-from-top nil
  "Stubbed Consult option.")

(defvar consult-line-numbers-widen t
  "Stubbed Consult option.")

(defvar consult--line-history nil
  "Stubbed Consult line history.")

(defvar consult-point-placement 'match-beginning
  "Stubbed Consult option.")

(defface consult-line-number-prefix '((t :inherit line-number))
  "Stubbed Consult face.")

(defface consult-line-number-wrapped '((t :inherit consult-line-number-prefix))
  "Stubbed Consult face.")

(defface consult-preview-line '((t :inherit highlight))
  "Stubbed Consult face.")

(defface consult-preview-match '((t :inherit match))
  "Stubbed Consult face.")

;; Consult defines this with the same default.  It is a plain `defvar',
;; not a `defcustom', so a value here cannot keep the real package from
;; installing its own.
(defvar consult--buffer-display #'switch-to-buffer
  "Stubbed Consult option.
Function used to display a buffer, which preview reads on each call.")

(defconst consult--tofu-char #x100000
  "Stubbed Consult PUA-B base character.")

(defconst consult--tofu-range #xFFFE
  "Stubbed Consult PUA-B range.")

(defun consult--tofu-encode (n)
  "Stub: return tofu-encoded N."
  (let (str tofu)
    (while (progn
             (setq tofu (char-to-string
                         (+ consult--tofu-char (% n consult--tofu-range)))
                   str (if str (concat tofu str) tofu))
             (and (>= n consult--tofu-range)
                  (setq n (/ n consult--tofu-range)))))
    (add-text-properties 0 (length str) '(invisible t consult-strip t) str)
    str))

(defun consult--location-candidate (cand marker line tofu &rest props)
  "Stub: attach `consult-location' and TOFU suffix to CAND."
  (setq cand (concat cand (consult--tofu-encode tofu)))
  (add-text-properties 0 1 `(consult-location (,marker . ,line) ,@props) cand)
  cand)

(defun consult--get-location (candidate)
  "Return CANDIDATE's location, converting its lazy buffer position to a marker."
  (when-let* ((location (get-text-property 0 'consult-location candidate))
              (pos (car location)))
    (when (consp pos)
      (setq pos (set-marker (make-marker) (cdr pos) (car pos)))
      (setcar location pos))
    location))

(defun consult--buffer-preview ()
  "Stub of Consult's buffer preview state function.

Mirrors the real one where tests depend on it: the buffer showing in the
original window is remembered, `preview' displays the candidate buffer
through `consult--buffer-display', and `preview' with no candidate
restores the remembered buffer.  A candidate may be a buffer or a buffer
name, as `consult--buffer-preview' accepts both."
  (let ((original-buffer (window-buffer (selected-window)))
        (other-window nil))
    (lambda (action candidate)
      (when (eq action 'preview)
        (when (and (eq consult--buffer-display #'switch-to-buffer-other-window)
                   (not other-window))
          (switch-to-buffer-other-window original-buffer 'norecord)
          (setq other-window (selected-window)))
        (let ((window (or other-window (selected-window)))
              (buffer (or (and candidate (get-buffer candidate))
                          original-buffer)))
          (when (and (window-live-p window) (buffer-live-p buffer))
            (with-selected-window window
              (switch-to-buffer buffer 'norecord))))))))

(defvar-local consult--narrow nil
  "Stubbed Consult narrowing key currently in force.
Consult binds this while a narrowing predicate runs, which is how a
predicate learns which key the reader is narrowing with.")

(defvar consult-after-jump-hook (list #'recenter)
  "Stubbed Consult hook, run after a jump and after each preview.")

(defun consult--jump (pos)
  "Stub Consult's final jump to POS, including mark and jump hook."
  (when pos
    (when (consp pos) (setq pos (car pos)))
    (when (or (not (markerp pos)) (eq (current-buffer) (marker-buffer pos)))
      (setq pos (+ pos 0))
      (push-mark (point) t))
    (when (or (not (markerp pos))
              (when-let* ((buffer (marker-buffer pos)))
                (unless (and (eq (current-buffer) buffer)
                             (eq (window-buffer) buffer))
                  (if-let* ((window (get-buffer-window buffer)))
                      (select-window window 'norecord)
                    (switch-to-buffer buffer 'norecord)))
                t))
      (unless (= (goto-char pos) (point))
        (widen)
        (goto-char pos))
      (dolist (overlay (overlays-in (pos-bol) (pos-eol)))
        (when-let* ((open (overlay-get overlay 'isearch-open-invisible))
                    ((invisible-p (overlay-get overlay 'invisible))))
          (funcall open overlay)))
      (run-hooks 'consult-after-jump-hook)))
  nil)

(defun consult--invisible-open-temporarily ()
  "Stub: open no overlays and return no restore functions.
Consult calls this from its jump preview with point at the previewed
position and calls each function it returns when the preview moves on
or ends."
  nil)

(defun consult--jump-preview ()
  "Stub mirroring Consult's `consult--jump-preview'."
  (let (restore)
    (lambda (action cand)
      (when (eq action 'preview)
        (mapc #'funcall restore)
        (setq restore nil)
        (when-let* ((pos (or (car-safe cand) cand)))
          (when (markerp pos)
            (when-let* ((buf (marker-buffer pos)))
              (set-buffer buf)))
          (let ((saved-min (point-min-marker))
                (saved-max (point-max-marker))
                (saved-pos (point-marker)))
            (set-marker-insertion-type saved-max t)
            (push (lambda ()
                    (when-let* ((buf (marker-buffer saved-pos)))
                      (with-current-buffer buf
                        (narrow-to-region saved-min saved-max)
                        (goto-char saved-pos)
                        (set-marker saved-pos nil)
                        (set-marker saved-min nil)
                        (set-marker saved-max nil))))
                  restore))
          (unless (= (goto-char pos) (point))
            (widen)
            (goto-char pos))
          (setq restore (nconc (consult--invisible-open-temporarily) restore))
          (let ((ov (make-overlay (pos-bol) (min (1+ (pos-eol)) (point-max)))))
            (overlay-put ov 'face 'consult-preview-line)
            (push (lambda () (delete-overlay ov)) restore))
          (run-hooks 'consult-after-jump-hook))))))

(defun consult--lookup-cdr (selected candidates &rest _)
  "Stub mirroring `consult--lookup-cdr'."
  (cdr (assoc selected candidates)))

(defun consult--line-candidates (top curr-line)
  "Stub mirroring `consult--line-candidates'."
  (let ((buffer (current-buffer))
        (line (line-number-at-pos (point-min) consult-line-numbers-widen))
        default-cand candidates)
    (save-excursion
      (let ((beg (point-min))
            (max (point-max))
            end)
        (while (< beg max)
          (goto-char beg)
          (setq end (pos-eol))
          (unless (looking-at-p "^\\s-*$")
            (push (consult--location-candidate
                   (buffer-substring-no-properties beg end)
                   (cons buffer beg) line line)
                  candidates)
            (when (and (not default-cand) (>= line curr-line))
              (setq default-cand candidates)))
          (cl-incf line)
          (setq beg (1+ end)))))
    (unless candidates
      (user-error "No lines"))
    (nreverse
     (if (or top (not default-cand))
         candidates
       (let ((before (cdr default-cand)))
         (setcdr default-cand nil)
         (nconc before candidates))))))

(defun consult--line-match (selected candidates input &rest _)
  "Stub mirroring `consult--line-match'."
  (when-let* ((found (car (member selected candidates)))
              (loc (get-text-property 0 'consult-location found))
              (pos (car loc)))
    (when (consp pos)
      (setq pos (set-marker (make-marker) (cdr pos) (car pos)))
      (setcar loc pos))
    (when (and (markerp pos) (marker-buffer pos))
      (if (and (stringp input)
               (not (string-blank-p input))
               (let ((case-fold-search t))
                 (string-match (regexp-quote input)
                               (substring-no-properties selected))))
          (let* ((beg (match-beginning 0))
                 (end (match-end 0))
                 (dest (move-marker (make-marker)
                                    (+ pos beg)
                                    (marker-buffer pos))))
            (cons dest (list (cons 0 (- end beg)))))
        pos))))

(defvar agent-shell-test-consult-line-calls nil
  "Stub: recorded direct calls to `consult-line'.")

(defun consult-line (&optional initial start)
  "Stub for `consult-line'."
  (interactive (list nil (not (not current-prefix-arg))))
  (push (list (current-buffer) initial start current-prefix-arg)
        agent-shell-test-consult-line-calls)
  nil)

(provide 'consult)

;;; consult.el ends here
