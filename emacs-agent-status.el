;;; emacs-agent-status.el --- Cached global activity indicator -*- lexical-binding: t; -*-

;;; Commentary:
;; Compact live activity across registered conversations, including outside a
;; journal.  Only runtime ownership is inspected, never transcript history.
;; Eventless runtime transitions call `emacs-agent-session-state-functions'
;; with the session.  Redisplay reads a string, without running any code.

;;; Code:
(require 'emacs-agent-session)
(declare-function emacs-agent-compact-job-p "emacs-agent-compact" (object))
(declare-function emacs-agent-compact-job-run "emacs-agent-compact" (job))
(declare-function emacs-agent-compact-job-state "emacs-agent-compact" (job))

(defun emacs-agent-status--set-option (symbol value)
  "Set status option SYMBOL to VALUE and refresh an enabled indicator."
  (set-default symbol value)
  (when (fboundp 'emacs-agent-status-update) (emacs-agent-status-update)))

(defcustom emacs-agent-status-prefix "AI"
  "Prefix before the activity labels; an empty string omits the prefix.
Use `emacs-agent-status-update' after changing this with `setq'."
  :type 'string :group 'emacs-agent :set #'emacs-agent-status--set-option)

(defcustom emacs-agent-status-labels
  '((waiting . "wait") (responding . "reply") (eval_elisp . "eval")
    (compacting . "compact") (paused . "pause") (queued . "q"))
  "Labels for live activity states and the ordinary pending queue.
Missing entries fall back to their state names.  Counts are added separately.
Use `emacs-agent-status-update' after changing this with `setq'."
  :type '(alist :key-type (choice (const waiting) (const responding)
                                 (const eval_elisp) (const compacting)
                                 (const paused) (const queued))
                :value-type string)
  :group 'emacs-agent :set #'emacs-agent-status--set-option)

(defvar emacs-agent-status--display nil
  "Cached mode-line string, or nil when all conversations are idle.")
(defvar emacs-agent-status--original-scalar nil
  "Original non-list value of `global-mode-string', if any.")
(defvar emacs-agent-status-mode)

(defun emacs-agent-status--state (session)
  "Return SESSION's live display state, ignoring terminal ownership slots."
  (let* ((run (emacs-agent-session-active-run session))
         (status (and run (eq (emacs-agent-run-session run) session)
                      (emacs-agent-run-status run)))
         (job (emacs-agent-session-compaction-job session)))
    (cond
     ((and (fboundp 'emacs-agent-compact-job-p)
           (emacs-agent-compact-job-p job)
           (eq (emacs-agent-run-session (emacs-agent-compact-job-run job)) session)
           (memq (emacs-agent-compact-job-state job) '(requesting committing)))
      'compacting)
     ((eq status 'requesting) 'waiting)
     ((eq status 'streaming) 'responding)
     ((eq status 'tool-running) 'eval_elisp)
     ((eq status 'paused) 'paused))))

(defun emacs-agent-status--render ()
  "Compute an aggregate from registered runtime objects, without history scans."
  (let ((counts (make-hash-table :test #'eq)) (queued 0) parts)
    (maphash
     (lambda (_id session)
       (when (emacs-agent-session-registered-p session)
         (when-let* ((state (emacs-agent-status--state session)))
           (puthash state (1+ (gethash state counts 0)) counts))
         (dolist (run (emacs-agent-session-pending-runs session))
           (when (and (eq (emacs-agent-run-session run) session)
                      (eq (emacs-agent-run-status run) 'queued))
             (cl-incf queued)))))
     emacs-agent-session--registry)
    (dolist (state '(waiting responding eval_elisp compacting paused))
      (let ((count (gethash state counts 0)))
        (when (> count 0)
          (let ((label (or (alist-get state emacs-agent-status-labels) (symbol-name state))))
            (push (if (= count 1) label (format "%s×%d" label count)) parts)))))
    (when (> queued 0)
      (push (format "%s:%d" (or (alist-get 'queued emacs-agent-status-labels) "queued") queued)
            parts))
    (when parts
      (concat " " (unless (string-empty-p emacs-agent-status-prefix)
                     (concat emacs-agent-status-prefix ":"))
              (mapconcat #'identity (nreverse parts) " ") " "))))

(defun emacs-agent-status-update (&optional session event)
  "Refresh the cached indicator from live runtime state.
Accept SESSION and optional EVENT for native session hooks.  Ignore events
from unregistered archives or replaced session objects.  With no SESSION,
refresh all registered conversations.  Unchanged text does not force redisplay."
  (when (and emacs-agent-status-mode
             ;; Native streaming transitions emit their own status event.
             ;; Text/usage deltas need neither a registry scan nor redisplay.
             (not (memq (plist-get event :type)
                        '(assistant reasoning usage instructions context-usage)))
             (or (null session) (emacs-agent-session-registered-p session)))
    (let ((display (emacs-agent-status--render)))
      (unless (equal display emacs-agent-status--display)
        (setq emacs-agent-status--display display)
        (force-mode-line-update t)))))

;;;###autoload
(define-minor-mode emacs-agent-status-mode
  "Show compact global activity for live Emacs Agent conversations.
Idle activity is hidden.  Queue counts include ordinary pending runs, not
historical inputs.  This mode does not change `mode-line-format'."
  :global t :group 'emacs-agent
  (if emacs-agent-status-mode
      (progn
        (let ((current (default-value 'global-mode-string)))
          (unless (and (listp current) (memq 'emacs-agent-status--display current))
            (setq emacs-agent-status--original-scalar (and (not (listp current)) current))
            (setq-default global-mode-string
                          (append (if (listp current) current (list current))
                                  '(emacs-agent-status--display)))))
        (add-hook 'emacs-agent-session-event-functions #'emacs-agent-status-update)
        (add-hook 'emacs-agent-session-state-functions #'emacs-agent-status-update)
        (emacs-agent-status-update))
    (remove-hook 'emacs-agent-session-event-functions #'emacs-agent-status-update)
    (remove-hook 'emacs-agent-session-state-functions #'emacs-agent-status-update)
    (let* ((current (default-value 'global-mode-string))
           (remaining (if (listp current)
                          (remq 'emacs-agent-status--display current)
                        current)))
      (setq-default global-mode-string
                    (if (and emacs-agent-status--original-scalar
                             (equal remaining (list emacs-agent-status--original-scalar)))
                        emacs-agent-status--original-scalar
                      remaining)))
    (setq emacs-agent-status--display nil
          emacs-agent-status--original-scalar nil)
    (force-mode-line-update t)))

(provide 'emacs-agent-status)
;;; emacs-agent-status.el ends here
