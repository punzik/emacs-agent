;;; manual-history-smoke.el --- Opt-in live replay probe -*- lexical-binding: t; -*-
;; Load in a running Emacs with a trusted Chat Completions backend.
;; Does not run on load.  Start, inspect after completion, then stop observer.
(require 'emacs-agent)
(require 'emacs-agent-gptel)

(defvar emacs-agent-history-smoke-runs nil)
(defvar emacs-agent-history-smoke-requests nil)

(defun emacs-agent-history-smoke--capture (run fsm)
  "Capture only outgoing messages, never backend credentials or headers."
  (push (list :run (emacs-agent-run-id run)
              :policy (emacs-agent-run-context-policy run)
              :messages (copy-tree (plist-get (plist-get (gptel-fsm-info fsm) :data) :messages) t))
        emacs-agent-history-smoke-requests))

(defun emacs-agent-history-smoke--observe (original run)
  "Observe a fixture's requests after replay restoration, before HTTP dispatch."
  (let ((fsm (funcall original run)))
    (when (eq (emacs-agent-session-key (emacs-agent-run-session run)) 'history-smoke)
      (let ((handlers (alist-get 'WAIT (gptel-fsm-handlers fsm))))
        (setf (alist-get 'WAIT (gptel-fsm-handlers fsm))
              (append (list (car handlers)
                            (apply-partially #'emacs-agent-history-smoke--capture run))
                      (cdr handlers)))))
    fsm))

(defun emacs-agent-history-smoke-start ()
  "Queue three real two-tool turns under nil/current/full, in an isolated fixture.
Only the test source buffer is used; model is asked for no files/shell/edits."
  (interactive)
  (when (seq-some (lambda (run) (memq (emacs-agent-run-status run)
                                     '(queued requesting streaming tool-running paused)))
                  emacs-agent-history-smoke-runs)
    (user-error "Previous smoke test still active"))
  (setq emacs-agent-history-smoke-runs nil emacs-agent-history-smoke-requests nil)
  (advice-add 'emacs-agent-gptel--make-fsm :around #'emacs-agent-history-smoke--observe)
  (let* ((root (file-name-as-directory (file-truename default-directory)))
         (session (make-emacs-agent-session :id "history-smoke" :key 'history-smoke :project-root root))
         (source (get-buffer-create "*emacs-agent-history-smoke*")))
    (puthash (emacs-agent-session-id session) session emacs-agent-session--registry)
    (with-current-buffer source
      (setq-local default-directory root)
      (erase-buffer)
      (insert "Test source only\n")
      (goto-char (point-min))
      (setf (emacs-agent-session-messages session)
            (list (list :role 'user :run-id "seed" :text "Synthetic earlier turn, no tool calls."
                        :context (emacs-agent-context-capture root))
                  (list :role 'assistant :run-id "seed" :text "No operations performed.")))
      (dolist (policy '(nil current full))
        (forward-char 1)
        (let* ((emacs-agent-context-history policy)
               (text "Harmless history smoke test. Make exactly two SEPARATE eval_elisp calls: first (+ 20 22), then (buffer-name). No files, shell or edits. Report the actual results in a short final answer.")
               (run (emacs-agent-session-enqueue session text (emacs-agent-context-capture root) source nil)))
          (push run emacs-agent-history-smoke-runs)
          (emacs-agent-gptel-submit run))))
    (setq emacs-agent-history-smoke-runs (nreverse emacs-agent-history-smoke-runs))
    session))

(defun emacs-agent-history-smoke-stop-observer ()
  "Remove fixture advice after inspection; never cancels user requests."
  (interactive)
  (advice-remove 'emacs-agent-gptel--make-fsm #'emacs-agent-history-smoke--observe))

;;; manual-history-smoke.el ends here
