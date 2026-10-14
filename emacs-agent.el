;;; emacs-agent.el --- Project-scoped agent entry points -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools, convenience

;;; Commentary:
;; Stage 1: capture editor context and queue turns by project identity.
;; No requests are sent yet; examples/emacs-agent-spike.el remains the
;; executable stage-zero gptel experiment.

;;; Code:
(require 'emacs-agent-session)
(require 'emacs-agent-context)

(defvar emacs-agent-prompt-history nil "History of user-written prompts only.")

(defvar emacs-agent-minibuffer-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map minibuffer-local-map)
    (define-key map (kbd "RET") #'exit-minibuffer)
    (define-key map (kbd "C-j") #'newline)
    (define-key map (kbd "M-p") #'previous-history-element)
    (define-key map (kbd "M-n") #'next-history-element)
    map)
  "Multiline prompt map: RET sends, C-j inserts newline, C-g aborts.")

(defconst emacs-agent-system-prompt
  "You are an agent inside a shared live Emacs. Your only tool is eval_elisp, which executes arbitrary Lisp without sandbox or approval. Discover functions using documentation and symbol-function, variables using boundp and symbol-value, buffers using buffer-list, projects using project.el. You may call shell functions and create asynchronous processes. Project sessions separate conversation history, not access. Editor context is diagnostic user-level data captured before prompt entry and may be stale. Tools default to the run's original working buffer if alive, otherwise its session/transport buffer, never necessarily the selected window. Use with-current-buffer explicitly. Buffers may be narrowed; widen when necessary. Buffer text is not automatically included: read the needed ranges. Never invent tool results."
  "Stable instruction for the future gptel adapter.")

(define-derived-mode emacs-agent-log-mode special-mode "Emacs-Agent"
  "Read-only session view; currently shows queued turns only.")

(defun emacs-agent--session-name (session)
  "Return a readable collision-resistant name for SESSION."
  (let ((root (emacs-agent-session-project-root session)))
    (if root
        (format "%s#%s" (file-name-nondirectory (directory-file-name root))
                (substring (secure-hash 'sha256 root) 0 10))
      "global")))

(defun emacs-agent--log-buffer (session)
  "Return SESSION's live journal buffer, creating it if needed."
  (or (and (buffer-live-p (emacs-agent-session-log-buffer session))
           (emacs-agent-session-log-buffer session))
      (let ((buffer (generate-new-buffer
                     (format "*emacs-agent: %s*" (emacs-agent--session-name session)))))
        (with-current-buffer buffer
          (emacs-agent-log-mode)
          (setq-local emacs-agent-session--owner session)
          (setq-local default-directory
                      (or (emacs-agent-session-project-root session) default-directory)))
        (setf (emacs-agent-session-log-buffer session) buffer)
        buffer)))

(defun emacs-agent--render-pending (session)
  "Refresh SESSION's temporary queued-turn view, not its API history."
  (with-current-buffer (emacs-agent--log-buffer session)
    (let ((inhibit-read-only t)
          (position (point)))
      (erase-buffer)
      (insert "Stage 1: turns are queued; no LLM requests are sent yet.\n\n")
      (dolist (run (emacs-agent-session-pending-runs session))
        (insert (format "User [%s, queued]\n%s\n\n"
                        (emacs-agent-run-id run) (emacs-agent-run-user-text run))))
      (goto-char (min position (point-max))))))

;;;###autoload
(defun emacs-agent-ask ()
  "Capture the working buffer, then read a multiline prompt and queue its turn.
Capture happens BEFORE entering the minibuffer; editing during prompt input
never changes that snapshot.  RET sends, C-j inserts a newline, C-g aborts.
M-p/M-n recall only user text.  Blank input does nothing.
From a journal, use its owning session and last live working buffer.
Stage 1 only queues turns; it does not send a gptel request yet."
  (interactive)
  (let* ((origin (emacs-agent-session-origin))
         (source (plist-get origin :buffer))
         (root (plist-get origin :root))
         (context (with-current-buffer source (emacs-agent-context-capture root)))
         (text (save-current-buffer
                 (read-from-minibuffer "Agent: " nil emacs-agent-minibuffer-map
                                       nil 'emacs-agent-prompt-history))))
    (unless (string-empty-p (string-trim text))
      (let* ((session (or (plist-get origin :session) (emacs-agent-session-get root)))
             (run (emacs-agent-session-enqueue session text context source
                                               (plist-get origin :window))))
        (emacs-agent--render-pending session)
        (message "Agent turn queued in %s (stage 1: not sent yet)"
                 (emacs-agent--session-name session))
        run))))

;;;###autoload
(defun emacs-agent-show ()
  "Show the current project/global session's read-only queued-turn view.
A journal always selects its owning session, even if its source buffer died."
  (interactive)
  (let* ((owner emacs-agent-session--owner)
         (session (or owner (emacs-agent-session-get (emacs-agent-session-resolve-root)))))
    (unless owner
      (setf (emacs-agent-session-last-source-buffer session) (current-buffer)))
    (emacs-agent--render-pending session)
    (display-buffer (emacs-agent--log-buffer session))))

(provide 'emacs-agent)
;;; emacs-agent.el ends here
