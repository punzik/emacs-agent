;;; emacs-agent-store.el --- Versioned atomic session snapshots -*- lexical-binding: t; -*-

;;; Commentary:
;; Readable Lisp DATA, never loaded/evaluated as code.  Each canonical session
;; has one file.  Credentials and live editor/transport objects are excluded.

;;; Code:
(require 'emacs-agent-session)
(require 'emacs-agent-usage)
(require 'pp)

(defcustom emacs-agent-data-directory (expand-file-name "emacs-agent/" user-emacs-directory)
  "Directory for session snapshots, outside working projects by default.
History, reasoning and tool results can contain secrets.
Files are not encrypted."
  :type 'directory :group 'emacs-agent)
(defcustom emacs-agent-auto-save t
  "Save on meaningful session events, including terminal states and tools.
Streaming deltas are checkpointed at most once per five seconds; terminal
states and tool boundaries are always saved immediately."
  :type 'boolean :group 'emacs-agent)

(defconst emacs-agent-store--schema 2)
(defconst emacs-agent-store--adapter "chat-completions-v1")
(defvar emacs-agent-store--last-save (make-hash-table :test #'eq))

(defun emacs-agent-store--identity-p (key root)
  "Whether KEY/ROOT form a supported canonical session identity."
  (if root
      (and (stringp root) (file-name-absolute-p root)
           (equal root (file-name-as-directory root)) (equal key root))
    (eq key 'global)))

(defun emacs-agent-store--file (key)
  "Return the snapshot path for KEY, without touching the filesystem."
  (expand-file-name (if (eq key 'global) "global.eld"
                      (concat "project-" (secure-hash 'sha256 key) ".eld"))
                    emacs-agent-data-directory))

(defun emacs-agent-store--data (value &optional ancestors depth)
  "Copy serializable VALUE, stripping properties and rejecting live objects.
Reject cycles/closures instead of hanging or printing unreadable #<...> data."
  (when (> (or depth 0) 200) (error "Session data is too deeply nested"))
  (cond
   ((stringp value) (substring-no-properties value))
   ((or (null value) (numberp value) (symbolp value)) value)
   ((or (consp value) (vectorp value))
    (when (or (memq value ancestors) (and (consp value) (functionp value)))
      (error "Session data contains a cycle or closure"))
    (let ((parents (cons value ancestors)) (level (1+ (or depth 0))))
      (if (vectorp value)
          (apply #'vector (mapcar (lambda (item) (emacs-agent-store--data item parents level)) value))
        (unless (proper-list-p value) (error "Session data contains a non-list cons"))
        (mapcar (lambda (item) (emacs-agent-store--data item parents level)) value))))
   (t (error "Session data contains a live or unsupported object"))))

(defun emacs-agent-store--source (buffer)
  "Return serializable BUFFER identity, or nil when unavailable."
  (when (buffer-live-p buffer)
    (list :name (buffer-name buffer) :file (buffer-local-value 'buffer-file-name buffer))))

(defun emacs-agent-store--run (run)
  "Copy only durable fields of RUN; never copy backend objects/continuations."
  (unless (or (symbolp (emacs-agent-run-model run)) (stringp (emacs-agent-run-model run)))
    (error "Invalid model identifier in session state"))
  (list :id (emacs-agent-run-id run) :status (emacs-agent-run-status run)
        :user-text (emacs-agent-run-user-text run) :context (emacs-agent-run-editor-context run)
        :source (emacs-agent-store--source (emacs-agent-run-source-buffer run))
        :model (format "%s" (emacs-agent-run-model run))
        :context-policy (emacs-agent-run-context-policy run)
        :stream (emacs-agent-run-stream run) :tool-count (emacs-agent-run-tool-count run)
        :tool-budget (emacs-agent-run-tool-budget run)
        :usage (emacs-agent-usage-summary run)
        :instructions (emacs-agent-run-instructions run)))

(defun emacs-agent-store--text-event-p (event)
  "Whether EVENT is a string-valued assistant or reasoning fragment/block."
  (and (memq (plist-get event :type) '(assistant reasoning))
       (stringp (plist-get event :payload))))

(defun emacs-agent-store--plain-text-p (event)
  "Whether EVENT can be merged without discarding unknown metadata."
  (and (emacs-agent-store--text-event-p event)
       (cl-loop for key in event by #'cddr
                always (memq key '(:id :time :session-id :run-id :type :payload
                                  :last-id :last-time :state)))))

(defun emacs-agent-store--complete-p (event next)
  "Whether NEXT explicitly closes the text type of EVENT in the same run.
This is an accumulator boundary, not successful completion of an HTTP/run."
  (and (eq (plist-get next :type)
           (pcase (plist-get event :type)
             ('assistant 'assistant-end) ('reasoning 'reasoning-end)))
       (equal (plist-get event :session-id) (plist-get next :session-id))
       (equal (plist-get event :run-id) (plist-get next :run-id))))

(defun emacs-agent-store--compact-events (events)
  "Return durable blocks for validated EVENTS without mutating the input.
Only adjacent known string fragments of the same session/run/type merge.
Concatenate each block once, avoiding quadratic string accumulation."
  (let (result)
    (while events
      (let ((event (car events)))
        (setq events (cdr events))
        (if (not (emacs-agent-store--text-event-p event))
            (push event result)
          (let ((block (copy-sequence event))
                (mergeable (emacs-agent-store--plain-text-p event))
                (last event) (chunks (list (plist-get event :payload))))
            (while (and mergeable events
                        (emacs-agent-store--plain-text-p (car events))
                        (eq (plist-get event :type) (plist-get (car events) :type))
                        (equal (plist-get event :session-id) (plist-get (car events) :session-id))
                        (equal (plist-get event :run-id) (plist-get (car events) :run-id)))
              (setq last (car events) events (cdr events))
              (push (plist-get last :payload) chunks))
            (setq block (plist-put block :payload (mapconcat #'identity (nreverse chunks) ""))
                  block (plist-put block :last-id (or (plist-get last :last-id) (plist-get last :id)))
                  block (plist-put block :last-time (or (plist-get last :last-time) (plist-get last :time)))
                  block (plist-put block :state
                                   (if (emacs-agent-store--complete-p block (car events))
                                       'complete 'partial)))
            (push block result)))))
    (nreverse result)))

(defun emacs-agent-store--snapshot (session)
  "Build a pure snapshot of SESSION without changing its live state."
  (unless (emacs-agent-store--identity-p (emacs-agent-session-key session)
                                       (emacs-agent-session-project-root session))
    (error "Session has no canonical persistence identity"))
  (unless (proper-list-p (emacs-agent-session-pending-runs session))
    (error "Malformed pending run queue"))
  (let* ((active (emacs-agent-session-active-run session))
         (messages (emacs-agent-store--data (emacs-agent-session-messages session)))
         (runs (append (when active (list active)) (emacs-agent-session-pending-runs session))))
    ;; Unflushed text is already visible in events; checkpoint it as one partial
    ;; API message too.  Do NOT flush/mutate the live run or emit fake callbacks.
    (when (and active (emacs-agent-run-assistant-chunks active))
      (unless (and (proper-list-p (emacs-agent-run-assistant-chunks active))
                   (cl-every #'stringp (emacs-agent-run-assistant-chunks active)))
        (error "Malformed assistant stream chunks"))
      (setq messages
            (append messages
                    (list (list :role 'assistant :run-id (emacs-agent-run-id active)
                                :text (mapconcat #'identity
                                                 (reverse (emacs-agent-run-assistant-chunks active)) ""))))))
    (let ((data (emacs-agent-store--data
                 (list :schema emacs-agent-store--schema :adapter emacs-agent-store--adapter
                       :id (emacs-agent-session-id session) :key (emacs-agent-session-key session)
                       :project-root (emacs-agent-session-project-root session)
                       :updated-at (emacs-agent-session-updated-at session)
                       :source (emacs-agent-store--source (emacs-agent-session-last-source-buffer session))
                       :messages messages :events (emacs-agent-session-events session)
                       :runs (mapcar #'emacs-agent-store--run runs)))))
      ;; Validate every original identity/field before aggregation can hide it.
      (emacs-agent-store--validate data
                                   (emacs-agent-store--file (emacs-agent-session-key session)) t)
      (plist-put data :events (emacs-agent-store--compact-events (plist-get data :events)))
      data)))

(defun emacs-agent-store--print (data)
  "Print validated snapshot DATA without recursive pretty-print layout.
Keep top-level fields and individual messages/events/runs on separate lines.
The Lisp data and schema are unchanged; long strings stay escaped by the
caller's print settings.  Pretty layout in every network callback is costly."
  (insert "(")
  (cl-loop for (key value) on data by #'cddr do
           (insert "\n ")
           (prin1 key (current-buffer))
           (insert " ")
           (if (and value (memq key '(:messages :events :runs)))
               (progn
                 (insert "(")
                 (dolist (record value)
                   (insert "\n  ")
                   (prin1 record (current-buffer)))
                 (insert "\n )"))
             (prin1 value (current-buffer))))
  (insert "\n)\n"))

(defun emacs-agent-store-save (session)
  "Atomically save SESSION, returning its path; leave old data intact on error."
  (let* ((data (emacs-agent-store--snapshot session))
         (file (emacs-agent-store--file (emacs-agent-session-key session)))
         temporary)
    (emacs-agent-store--validate data file)
    (unless (file-directory-p emacs-agent-data-directory)
      (make-directory emacs-agent-data-directory t)
      (set-file-modes emacs-agent-data-directory #o700))
    (unwind-protect
        (progn
          (setq temporary (make-temp-file (expand-file-name ".snapshot-" emacs-agent-data-directory)))
          (set-file-modes temporary #o600)
          (with-temp-buffer
            (let ((print-length nil) (print-level nil) (print-circle nil)
                  (print-escape-newlines t) (coding-system-for-write 'utf-8-unix))
              (insert ";; Emacs Agent session data; contains potentially sensitive history.\n")
              (emacs-agent-store--print data)
              (write-region (point-min) (point-max) temporary nil 'silent)))
          (rename-file temporary file t)
          (puthash session (float-time) emacs-agent-store--last-save)
          file)
      (when (and temporary (file-exists-p temporary)) (delete-file temporary)))))

(defun emacs-agent-store--plist (value)
  "Require VALUE to be a keyword plist with no duplicate fields."
  (unless (and (proper-list-p value) (cl-evenp (length value)))
    (error "Malformed session record"))
  (let (keys)
    (cl-loop for key in value by #'cddr do
             (unless (and (keywordp key) (not (memq key keys)))
               (error "Malformed session fields"))
             (push key keys))))

(defun emacs-agent-store--validate (data file &optional live-events)
  "Check DATA schema and identity for FILE before modifying the registry.
LIVE-EVENTS allows raw deltas and not-yet-recomputed block states in a copied
live list.  Durable snapshots require complete, consistent block metadata."
  (emacs-agent-store--plist data)
  (cl-loop for key in data by #'cddr do
           (unless (memq key '(:schema :adapter :id :key :project-root :updated-at :source :messages :events :runs))
             (error "Unknown snapshot field")))
  (unless (eql (plist-get data :schema) emacs-agent-store--schema)
    (error "Unsupported session schema; no migration is provided, use a new data directory"))
  (unless (equal (plist-get data :adapter) emacs-agent-store--adapter)
    (error "Unsupported replay adapter"))
  (unless (and (stringp (plist-get data :id))
               (numberp (plist-get data :updated-at))
               (emacs-agent-store--identity-p (plist-get data :key) (plist-get data :project-root))
               (equal (expand-file-name file) (emacs-agent-store--file (plist-get data :key))))
    (error "Invalid session identity or filename"))
  (dolist (field '(:messages :events :runs))
    (unless (proper-list-p (plist-get data field)) (error "Malformed session collection")))
  (dolist (message (plist-get data :messages))
    (emacs-agent-store--plist message)
    (unless (and (memq (plist-get message :role) '(user assistant tool unsupported-protocol))
                 (stringp (plist-get message :run-id)))
      (error "Malformed history identity")))
  (cl-loop for tail on (plist-get data :events) for event = (car tail) do
    (emacs-agent-store--plist event)
    (unless (and (stringp (plist-get event :id)) (stringp (plist-get event :run-id))
                 (equal (plist-get event :session-id) (plist-get data :id))
                 (numberp (plist-get event :time)) (symbolp (plist-get event :type)))
      (error "Malformed event identity"))
    (when (and (emacs-agent-store--text-event-p event)
               (or (not live-events)
                   (cl-some (lambda (key) (plist-member event key))
                            '(:last-id :last-time :state))))
      (unless (and (stringp (plist-get event :last-id))
                   (numberp (plist-get event :last-time))
                   (memq (plist-get event :state) '(partial complete))
                   (or live-events
                       (eq (plist-get event :state)
                           (if (emacs-agent-store--complete-p event (cadr tail))
                               'complete 'partial))))
        (error "Malformed streaming block"))))
  (dolist (run (plist-get data :runs))
    (emacs-agent-store--plist run)
    (unless (and (stringp (plist-get run :id)) (stringp (plist-get run :user-text))
                 (memq (plist-get run :status)
                       '(queued requesting streaming tool-running paused completed failed cancelled)))
      (error "Malformed saved run")))
  data)

(defun emacs-agent-store--bump-id (id)
  "Avoid reusing numeric IDs found in restored ID."
  (when (and (stringp id) (string-match "\\`\\(?:session\\|run\\|event\\)-\\([0-9]+\\)\\'" id))
    (setq emacs-agent-session--counter
          (max emacs-agent-session--counter (string-to-number (match-string 1 id))))))

(defun emacs-agent-store--restore (file)
  "Read and validate FILE as data; register an idle session, never resume tasks."
  (let ((data (with-temp-buffer
                (insert-file-contents file)
                (goto-char (point-min))
                (let ((value (read (current-buffer))))
                  (forward-comment (point-max))
                  (unless (eobp) (error "Trailing data in session file"))
                  (emacs-agent-store--data value)))))
    (emacs-agent-store--validate data file)
    (or (gethash (plist-get data :key) emacs-agent-session--registry)
        (let* ((session (make-emacs-agent-session
                         :id (plist-get data :id) :key (plist-get data :key)
                         :project-root (plist-get data :project-root)
                         :updated-at (plist-get data :updated-at)
                         :messages (plist-get data :messages) :events (plist-get data :events)))
               (source (plist-get data :source))
               (buffer (and (stringp (plist-get source :name)) (get-buffer (plist-get source :name)))))
          (when (and buffer (equal (buffer-local-value 'buffer-file-name buffer) (plist-get source :file)))
            (setf (emacs-agent-session-last-source-buffer session) buffer))
          (emacs-agent-store--bump-id (emacs-agent-session-id session))
          (dolist (event (emacs-agent-session-events session))
            (emacs-agent-store--bump-id (plist-get event :id))
            (emacs-agent-store--bump-id (plist-get event :last-id))
            (emacs-agent-store--bump-id (plist-get event :run-id)))
          (dolist (message (emacs-agent-session-messages session))
            (emacs-agent-store--bump-id (plist-get message :run-id)))
          ;; Insert only after validation.  Interrupt records are generated
          ;; without event hooks, so restore neither autosaves nor sends HTTP.
          (dolist (saved (plist-get data :runs))
            (emacs-agent-store--bump-id (plist-get saved :id))
            (unless (memq (plist-get saved :status) '(completed failed cancelled))
              (let ((emacs-agent-session-event-functions nil))
                (plist-put
                 (emacs-agent-session-record
                  (make-emacs-agent-run :id (plist-get saved :id) :session session)
                  'interrupted
                  (format "Interrupted %s turn; nothing resumed automatically.%s"
                          (plist-get saved :status)
                          (if (eq (plist-get saved :status) 'queued)
                              (concat "\nPending user text: " (plist-get saved :user-text)) "")))
                 :saved-run saved))))
          (puthash (emacs-agent-session-key session) session emacs-agent-session--registry)
          session))))

(defun emacs-agent-store-load-session (root)
  "Lazily restore ROOT's saved session, or return nil if none exists.
Corrupt/unsupported files fail explicitly and are never replaced by a fresh
session as a side effect of asking.  Other sessions remain loadable."
  (let ((file (emacs-agent-store--file (or root 'global))))
    (when (file-exists-p file)
      (condition-case err (emacs-agent-store--restore file)
        (error (user-error "Cannot restore %s: %s" file (error-message-string err)))))))

(defun emacs-agent-store-load-all ()
  "Load independent snapshots; report bad files without losing good sessions."
  (when (file-directory-p emacs-agent-data-directory)
    (dolist (file (directory-files emacs-agent-data-directory t "\\.eld\\'"))
      (condition-case err (emacs-agent-store--restore file)
        (error (display-warning 'emacs-agent
                                (format "Cannot restore %s: %s" file (error-message-string err))))))))

(defun emacs-agent-store--auto-save (session event)
  "Checkpoint SESSION for EVENT without turning filesystem errors into tool errors."
  (when (and emacs-agent-auto-save
             (emacs-agent-store--identity-p (emacs-agent-session-key session)
                                            (emacs-agent-session-project-root session)))
    (let ((type (plist-get event :type)))
      (when (or (not (memq type '(assistant reasoning)))
                (>= (- (float-time) (gethash session emacs-agent-store--last-save 0)) 5))
        (condition-case err (emacs-agent-store-save session)
          ((error quit) (message "Emacs Agent autosave failed: %s" (error-message-string err))))))))

(add-hook 'emacs-agent-session-event-functions #'emacs-agent-store--auto-save t)

(provide 'emacs-agent-store)
;;; emacs-agent-store.el ends here
