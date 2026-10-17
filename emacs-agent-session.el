;;; emacs-agent-session.el --- Session identity and queued turns -*- lexical-binding: t; -*-

;;; Commentary:
;; Project identity partitions conversations, not access to the live editor.

;;; Code:
(require 'cl-lib)
(require 'project)
(require 'subr-x)
(require 'emacs-agent-eval)
(require 'emacs-agent-resources)

(autoload 'emacs-agent-store-load-session "emacs-agent-store")
(autoload 'emacs-agent-store-save "emacs-agent-store")
(autoload 'emacs-agent-store-select "emacs-agent-store")
(autoload 'emacs-agent-store--file "emacs-agent-store")
(autoload 'emacs-agent-store--data "emacs-agent-store")
(declare-function emacs-agent-input-state "emacs-agent-input" (input))
(defvar emacs-agent-store--last-save)

(cl-defstruct emacs-agent-session
  id key project-root events messages log-buffer pending-runs active-run
  last-source-buffer updated-at inputs compaction compaction-job usage-anchor
  name (created-at (float-time)) provenance)

(cl-defstruct emacs-agent-run
  id session user-text editor-context source-buffer source-window
  (status 'queued) request-handle transport-buffer backend model stream assistant-chunks
  (tool-count 0) tool-budget pending-tools
  (tool-call-ids (make-hash-table :test #'equal)) context-policy response-protocol
  usage-requests usage-current instructions input context-config)

(defvar emacs-agent-session--registry (make-hash-table :test #'equal)
  "Conversation ID to registered session object.")
(defvar emacs-agent-session--selected (make-hash-table :test #'equal)
  "Scope (canonical project root or `global') to selected conversation ID.")
(defvar emacs-agent-session--mutation nil
  "Non-nil during a short persistence/publication transaction.")
(defvar emacs-agent-session--counter (floor (* (float-time) 1000000)))
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

(defun emacs-agent-session-selected (root)
  "Return ROOT's selected registered object, without creation or IO."
  (gethash (gethash (or root 'global) emacs-agent-session--selected)
           emacs-agent-session--registry))

(defun emacs-agent-session-registered-p (session)
  "Whether SESSION is the registered object for its conversation ID."
  (and (emacs-agent-session-p session)
       (eq session (gethash (emacs-agent-session-id session)
                            emacs-agent-session--registry))))

(defun emacs-agent-session-idle-p (session)
  "Whether SESSION has no live work; withdrawn recovery inputs are inert."
  (and (not (emacs-agent-session-active-run session))
       (not (emacs-agent-session-pending-runs session))
       (not (emacs-agent-session-compaction-job session))
       (not (cl-some (lambda (input)
                       (memq (emacs-agent-input-state input) '(prepared queued)))
                     (emacs-agent-session-inputs session)))))

(defun emacs-agent-session--unlocked ()
  "Reject reentrant mutations."
  (when emacs-agent-session--mutation (user-error "Conversation mutation in progress")))

(defun emacs-agent-session--guard (session key)
  "Require a registered, idle SESSION in scope KEY."
  (unless (and (emacs-agent-session-registered-p session)
               (equal (emacs-agent-session-key session) key)
               (emacs-agent-session-idle-p session))
    (user-error "Conversation must be registered, idle and in the same scope")))

(defun emacs-agent-session--fresh (root &optional name)
  "Allocate an unpublished conversation in ROOT with NAME."
  (let (id)
    (while (or (null id) (gethash id emacs-agent-session--registry)
               (file-exists-p (emacs-agent-store--file id)))
      (setq id (concat "session-"
                       (secure-hash 'sha256
                                    (format "%s:%s:%s:%s:%s"
                                            (float-time) (cl-incf emacs-agent-session--counter)
                                            (random) (emacs-pid) (current-time))))))
    (make-emacs-agent-session :id id :key (or root 'global) :project-root root
                              :name name :updated-at (float-time))))

(defun emacs-agent-session--publish (session)
  "Register and select SESSION, after all persistence has succeeded."
  (puthash (emacs-agent-session-id session) session emacs-agent-session--registry)
  (puthash (emacs-agent-session-key session) (emacs-agent-session-id session)
           emacs-agent-session--selected)
  session)

(defun emacs-agent-session-get (root)
  "Return ROOT's selection, restore a project pointer, or create a fresh one.
Global selection is process-local and never restored implicitly."
  (or (emacs-agent-session-selected root)
      (progn
        (emacs-agent-session--unlocked)
        (let ((emacs-agent-session--mutation t))
          (or (and root (emacs-agent-store-load-session root))
              (let ((session (emacs-agent-session--fresh root)))
                (when root
                  (emacs-agent-store-save session)
                  (emacs-agent-store-select session))
                (emacs-agent-session--publish session)))))))

(defun emacs-agent-session--switch (candidate source)
  "Persist then publish CANDIDATE, guarding optional journal SOURCE.
Caller holds the mutation lock.  New candidates need not be registered."
  (let* ((key (emacs-agent-session-key candidate))
         (old (emacs-agent-session-selected (emacs-agent-session-project-root candidate))))
    (dolist (session (delete-dups (delq nil (list old source))))
      (emacs-agent-session--guard session key))
    (unless (emacs-agent-session-idle-p candidate)
      (user-error "Target conversation is busy"))
    (dolist (session (delete-dups (delq nil (list old source))))
      (unless (eq session candidate) (emacs-agent-store-save session)))
    (emacs-agent-store-save candidate)
    (emacs-agent-store-select candidate)
    (emacs-agent-session--publish candidate)))

(defun emacs-agent-session--new (root &optional name source)
  "Create and select a fresh conversation in ROOT with NAME.
SOURCE, when supplied, is the journal owner and must be idle in that scope."
  (emacs-agent-session--unlocked)
  (let ((emacs-agent-session--mutation t))
    (emacs-agent-session--switch (emacs-agent-session--fresh root name) source)))

(defun emacs-agent-session--select (session &optional source)
  "Select registered SESSION, guarding SOURCE and the old selection."
  (emacs-agent-session--unlocked)
  (let ((emacs-agent-session--mutation t))
    (emacs-agent-session--guard session (emacs-agent-session-key session))
    (emacs-agent-session--switch session source)))

(defun emacs-agent-session--rename (session name)
  "Save a preview with NAME before changing live SESSION metadata."
  (emacs-agent-session--unlocked)
  (let ((emacs-agent-session--mutation t))
    (emacs-agent-session--guard session (emacs-agent-session-key session))
    (let ((preview (copy-emacs-agent-session session)))
      (setf (emacs-agent-session-name preview) name)
      (unwind-protect
          (progn
            (emacs-agent-store-save preview)
            (setf (emacs-agent-session-name session) name))
        (remhash preview emacs-agent-store--last-save)))
    session))

(defun emacs-agent-session--clone (session &optional name)
  "Deep-copy idle SESSION's history into a fresh selected conversation.
Historical run/input/tool IDs stay historical.  No live authority is copied."
  (emacs-agent-session--unlocked)
  (let ((emacs-agent-session--mutation t))
    (emacs-agent-session--guard session (emacs-agent-session-key session))
    (let ((clone (emacs-agent-session--fresh (emacs-agent-session-project-root session) name)))
      (setf (emacs-agent-session-provenance clone)
            (list :source-id (emacs-agent-session-id session) :time (float-time))
            (emacs-agent-session-messages clone)
            (emacs-agent-store--data (emacs-agent-session-messages session))
            (emacs-agent-session-events clone)
            (emacs-agent-store--data (emacs-agent-session-events session))
            (emacs-agent-session-compaction clone)
            (emacs-agent-store--data (emacs-agent-session-compaction session)))
      (dolist (event (emacs-agent-session-events clone))
        (setf (plist-get event :session-id) (emacs-agent-session-id clone)))
      (emacs-agent-session--switch clone session))))

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

(defun emacs-agent-session-prepare (session text context source window)
  "Prepare TEXT, CONTEXT, SOURCE and WINDOW without scheduling execution."
  (emacs-agent-session--unlocked)
  (make-emacs-agent-run
   :id (format "run-%d" (cl-incf emacs-agent-session--counter))
   :session session :user-text text :editor-context context
   :source-buffer source :source-window window
   :instructions
   (with-current-buffer (if (buffer-live-p source) source (current-buffer))
     (emacs-agent-resources-capture (emacs-agent-session-project-root session)))))

(defun emacs-agent-session-enqueue (session text context source window)
  "Queue TEXT with frozen CONTEXT and saved instructions in SESSION.
SOURCE and WINDOW identify its original editor location."
  (emacs-agent-session--unlocked)
  (let ((run (emacs-agent-session-prepare session text context source window)))
    (setf (emacs-agent-session-last-source-buffer session) source
          (emacs-agent-session-updated-at session) (float-time)
          (emacs-agent-session-pending-runs session)
          (nconc (emacs-agent-session-pending-runs session) (list run)))
    run))

(defvar emacs-agent-session-event-functions nil
  "Functions called with SESSION and EVENT after a structured event is recorded.")

(defun emacs-agent-session-record (run type payload &optional model-message)
  "Record TYPE and serializable PAYLOAD for RUN.
If MODEL-MESSAGE is supplied, append it to the separate canonical API history.
The rendered journal is never used to reconstruct that history."
  (let* ((session (emacs-agent-run-session run))
         (event (list :id (format "event-%d" (cl-incf emacs-agent-session--counter))
                      :time (float-time) :session-id (emacs-agent-session-id session)
                      :run-id (emacs-agent-run-id run) :type type :payload payload)))
    (when model-message
      (setf (emacs-agent-session-messages session)
            (nconc (emacs-agent-session-messages session) (list model-message))))
    (setf (emacs-agent-session-events session)
          (nconc (emacs-agent-session-events session) (list event))
          (emacs-agent-session-updated-at session) (plist-get event :time))
    ;; A broken renderer must not lose tool results or strand the network loop.
    (run-hook-wrapped
     'emacs-agent-session-event-functions
     (lambda (function &rest args)
       (condition-case err (apply function args)
         ((error quit) (message "Emacs Agent event handler: %s" (error-message-string err))))
       nil)
     session event)
    event))

(provide 'emacs-agent-session)
;;; emacs-agent-session.el ends here
