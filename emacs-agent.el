;;; emacs-agent.el --- Project-scoped agent entry points -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools, convenience

;;; Commentary:
;; Capture editor context, queue project-scoped turns and run unrestricted
;; Lisp through gptel.  Sessions partition history, not editor access.

;;; Code:
(require 'emacs-agent-session)
(require 'emacs-agent-context)
(require 'emacs-agent-log)

(autoload 'emacs-agent-gptel-submit "emacs-agent-gptel")
(autoload 'emacs-agent-gptel-cancel "emacs-agent-gptel")
(autoload 'emacs-agent-gptel-resume "emacs-agent-gptel")

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
  "Stable instruction for the gptel adapter.")

;;;###autoload
(defun emacs-agent-ask ()
  "Capture the working buffer, then read a multiline prompt and queue its turn.
Capture happens BEFORE entering the minibuffer; editing during prompt input
never changes that snapshot.  RET sends, C-j inserts a newline, C-g aborts.
M-p/M-n recall only user text.  Blank input does nothing.
From a journal, use its owning session and last live working buffer.
Starts a gptel run immediately if this session is idle; otherwise queues it."
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
        (emacs-agent--log-buffer session)
        (emacs-agent-gptel-submit run)
        (message "Agent turn %s in %s" (emacs-agent-run-status run)
                 (emacs-agent--session-name session))
        run))))

;;;###autoload
(defun emacs-agent-show ()
  "Show the current project/global session's read-only event journal.
A journal always selects its owning session, even if its source buffer died."
  (interactive)
  (let* ((owner emacs-agent-session--owner)
         (session (or owner (emacs-agent-session-get (emacs-agent-session-resolve-root)))))
    (unless owner
      (setf (emacs-agent-session-last-source-buffer session) (current-buffer)))
    (emacs-agent--render-log session)
    (display-buffer (emacs-agent--log-buffer session))))

(defun emacs-agent--current-session ()
  "Resolve an existing current session without creating one for cancellation."
  (or emacs-agent-session--owner
      (gethash (or (emacs-agent-session-resolve-root) 'global)
               emacs-agent-session--registry)
      (user-error "No agent session here")))

;;;###autoload
(defun emacs-agent-cancel ()
  "Cancel the current session's active run, leaving prior Lisp effects intact.
The next queued turn may start; cancellation does not retry any tool call."
  (interactive)
  (emacs-agent-gptel-cancel (emacs-agent--current-session)))

;;;###autoload
(defun emacs-agent-resume ()
  "Continue the current session's paused run with another tool budget."
  (interactive)
  (emacs-agent-gptel-resume (emacs-agent--current-session)))

(provide 'emacs-agent)
;;; emacs-agent.el ends here
