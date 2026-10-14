;;; emacs-agent-session.el --- Session identity and queued turns -*- lexical-binding: t; -*-

;;; Commentary:
;; Project identity partitions conversations, not access to the live editor.

;;; Code:
(require 'cl-lib)
(require 'project)
(require 'subr-x)
(require 'emacs-agent-eval)

(cl-defstruct emacs-agent-session
  id key project-root events messages log-buffer pending-runs active-run
  last-source-buffer updated-at)

(cl-defstruct emacs-agent-run
  id session user-text editor-context source-buffer source-window
  (status 'queued) request-handle
  (tool-call-ids (make-hash-table :test #'equal)))

(defvar emacs-agent-session--registry (make-hash-table :test #'equal)
  "Session registry keyed by canonical project directory or `global'.")
(defvar emacs-agent-session--counter 0)
(defvar-local emacs-agent-session--owner nil
  "Session associated with an agent journal buffer.")

(defun emacs-agent-session-resolve-root ()
  "Return the current buffer's canonical project root, or nil.
Remote identities are expanded but never passed through local truename
resolution.  If local truename resolution fails, keep the expanded root."
  (when-let* ((project (project-current nil)))
    (let ((root (file-name-as-directory (expand-file-name (project-root project)))))
      (if (file-remote-p root) root
        (condition-case nil
            (file-name-as-directory (file-truename root))
          (file-error root))))))

(defun emacs-agent-session-get (root)
  "Find or create the session for canonical ROOT; nil selects global."
  (let ((key (or root 'global)))
    (or (gethash key emacs-agent-session--registry)
        (let ((session (make-emacs-agent-session
                        :id (format "session-%d" (cl-incf emacs-agent-session--counter))
                        :key key :project-root root :updated-at (float-time))))
          (puthash key session emacs-agent-session--registry)
          session))))

(defun emacs-agent-session-origin ()
  "Resolve the calling buffer/window and session identity before minibuffer input.
A journal uses its owning session and last live working buffer.  Without one,
signal a user error rather than treating the journal as a working buffer.
This function does not create a session."
  (let* ((owner emacs-agent-session--owner)
         (source (if owner (emacs-agent-session-last-source-buffer owner)
                   (current-buffer)))
         (window (selected-window)))
    (unless (buffer-live-p source)
      (user-error "Session's working buffer is gone; ask from a working buffer"))
    (when (minibufferp source)
      (user-error "Invoke the agent from a working buffer"))
    (list :buffer source
          :window (if (and (window-live-p window) (eq (window-buffer window) source))
                      window (get-buffer-window source t))
          :session owner
          :root (if owner (emacs-agent-session-project-root owner)
                  (with-current-buffer source (emacs-agent-session-resolve-root))))))

(defun emacs-agent-session-enqueue (session text context source window)
  "Queue TEXT and captured CONTEXT in SESSION with SOURCE and WINDOW.
This stage only queues turns; the stage 2 adapter will consume the FIFO."
  (let ((run (make-emacs-agent-run
              :id (format "run-%d" (cl-incf emacs-agent-session--counter))
              :session session :user-text text :editor-context context
              :source-buffer source :source-window window)))
    (setf (emacs-agent-session-last-source-buffer session) source
          (emacs-agent-session-updated-at session) (float-time)
          (emacs-agent-session-pending-runs session)
          (nconc (emacs-agent-session-pending-runs session) (list run)))
    run))

(provide 'emacs-agent-session)
;;; emacs-agent-session.el ends here
