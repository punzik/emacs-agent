;;; emacs-agent-store.el --- Versioned atomic session snapshots -*- lexical-binding: t; -*-

;;; Commentary:
;; Readable Lisp DATA, never loaded/evaluated as code.  Each canonical session
;; has one file.  Credentials and live editor/transport objects are excluded.

;;; Code:
(require 'emacs-agent-session)
(require 'emacs-agent-usage)
(require 'emacs-agent-input)
(declare-function emacs-agent-compact-job-run "emacs-agent-compact" (job))

(defcustom emacs-agent-auto-save t
  "Save on meaningful session events, including terminal states and tools.
Streaming deltas are checkpointed at most once per five seconds; terminal
states and tool boundaries are always saved immediately."
  :type 'boolean :group 'emacs-agent)

(defconst emacs-agent-store--schema 3)
(defconst emacs-agent-store--adapter "chat-completions-v1")
(defvar emacs-agent-store--last-save (make-hash-table :test #'eq))

(defun emacs-agent-store--identity-p (key root)
  "Whether KEY/ROOT form a supported canonical session identity."
  (if root
      (and (stringp root) (file-name-absolute-p root)
           (equal root (file-name-as-directory root)) (equal key root))
    (eq key 'global)))

(defun emacs-agent-store--file (id)
  "Return the new-namespace snapshot path for conversation ID, without IO."
  (expand-file-name (concat "conversations/" (secure-hash 'sha256 id) ".eld")
                    emacs-agent-data-directory))

(defun emacs-agent-store--selection-file (root)
  "Return the project selection pointer path for ROOT."
  (unless root (error "Global selection has no durable pointer"))
  (expand-file-name (concat "selections/" (secure-hash 'sha256 root) ".eld")
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
        :context-config (emacs-agent-run-context-config run)
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
  (unless (and (proper-list-p (emacs-agent-session-pending-runs session))
               (proper-list-p (emacs-agent-session-inputs session)))
    (error "Malformed pending run or input queue"))
  (let* ((active (emacs-agent-session-active-run session))
         (messages (emacs-agent-store--data (emacs-agent-session-messages session)))
         (runs (append (when active (list active)) (emacs-agent-session-pending-runs session)
                       (when (emacs-agent-session-compaction-job session)
                         (list (emacs-agent-compact-job-run (emacs-agent-session-compaction-job session)))))))
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
                       :name (emacs-agent-session-name session)
                       :created-at (emacs-agent-session-created-at session)
                       :provenance (emacs-agent-session-provenance session)
                       :updated-at (emacs-agent-session-updated-at session)
                       :source (emacs-agent-store--source (emacs-agent-session-last-source-buffer session))
                       :messages messages :events (emacs-agent-session-events session)
                       :compaction (emacs-agent-session-compaction session)
                       :usage-anchor (emacs-agent-session-usage-anchor session)
                       :runs (mapcar #'emacs-agent-store--run runs)
                       :inputs (mapcar #'emacs-agent-input-data
                                       (emacs-agent-session-inputs session))))))
      ;; Validate every original identity/field before aggregation can hide it.
      (emacs-agent-store--validate data
                                   (emacs-agent-store--file (emacs-agent-session-id session)) t)
      (plist-put data :events (emacs-agent-store--compact-events (plist-get data :events)))
      data)))

(defun emacs-agent-store--print (data)
  "Print validated snapshot DATA without recursive pretty-print layout.
Keep top-level fields and each message/event/run/input on separate lines.
The Lisp data and schema are unchanged; long strings stay escaped by the
caller's print settings.  Pretty layout in every network callback is costly."
  (insert "(")
  (cl-loop for (key value) on data by #'cddr do
           (insert "\n ")
           (prin1 key (current-buffer))
           (insert " ")
           (if (and value (memq key '(:messages :events :runs :inputs)))
               (progn
                 (insert "(")
                 (dolist (record value)
                   (insert "\n  ")
                   (prin1 record (current-buffer)))
                 (insert "\n )"))
             (prin1 value (current-buffer))))
  (insert "\n)\n"))

(defun emacs-agent-store--private-directory (directory)
  "Create DIRECTORY and missing parents privately."
  (unless (file-directory-p directory)
    (let ((parent (file-name-directory (directory-file-name directory))))
      (when (and parent (not (equal parent directory)))
        (emacs-agent-store--private-directory parent)))
    (make-directory directory)
    (set-file-modes directory #o700)))

(defun emacs-agent-store--write (data file)
  "Atomically write DATA to FILE privately; preserve existing FILE on error."
  (let ((directory (file-name-directory file)) temporary)
    (emacs-agent-store--private-directory directory)
    (unwind-protect
        (progn
          (setq temporary (make-temp-file (expand-file-name ".snapshot-" directory)))
          (set-file-modes temporary #o600)
          (with-temp-buffer
            (let ((print-length nil) (print-level nil) (print-circle nil)
                  (print-escape-newlines t) (coding-system-for-write 'utf-8-unix))
              (insert ";; Emacs Agent data; contains potentially sensitive history.\n")
              (emacs-agent-store--print data)
              (write-region (point-min) (point-max) temporary nil 'silent)))
          (rename-file temporary file t)
          file)
      (when (and temporary (file-exists-p temporary)) (delete-file temporary)))))

(defun emacs-agent-store-save (session)
  "Save SESSION's snapshot only; never change a selection pointer."
  (let* ((data (emacs-agent-store--snapshot session))
         (file (emacs-agent-store--file (emacs-agent-session-id session))))
    (emacs-agent-store--validate data file)
    (emacs-agent-store--write data file)
    (puthash session (float-time) emacs-agent-store--last-save)
    file))

(defun emacs-agent-store-select (session)
  "Persist SESSION's project selection pointer only; global is a no-op."
  (when-let* ((root (emacs-agent-session-project-root session)))
    (unless (emacs-agent-store--identity-p (emacs-agent-session-key session) root)
      (error "Invalid selection scope"))
    (emacs-agent-store--write
     (list :schema emacs-agent-store--schema :project-root root
           :id (emacs-agent-session-id session))
     (emacs-agent-store--selection-file root))))

(defun emacs-agent-store--plist (value)
  "Require VALUE to be a keyword plist with no duplicate fields."
  (unless (and (proper-list-p value) (cl-evenp (length value)))
    (error "Malformed session record"))
  (let (keys)
    (cl-loop for key in value by #'cddr do
             (unless (and (keywordp key) (not (memq key keys)))
               (error "Malformed session fields"))
             (push key keys))))

(defun emacs-agent-store--context (data)
  "Validate DATA's optional summary projection and accounting anchor."
  (let* ((count (length (plist-get data :messages)))
         (record (plist-get data :compaction))
         (anchor (plist-get data :usage-anchor)))
    (when record
      (emacs-agent-input--fields record '(:cut :summary :tokens-before :model :backend :time))
      (unless (and (integerp (plist-get record :cut)) (< 0 (plist-get record :cut))
                   (<= (plist-get record :cut) count)
                   (stringp (plist-get record :summary))
                   (not (string-empty-p (string-trim (plist-get record :summary))))
                   (natnump (plist-get record :tokens-before))
                   (stringp (plist-get record :model)) (stringp (plist-get record :backend))
                   (numberp (plist-get record :time)))
        (error "Malformed compaction projection")))
    (when anchor
      (emacs-agent-input--fields anchor '(:tokens :estimate :model :backend :cut :source))
      (unless (and (eq (plist-get anchor :source) 'gptel-normalized)
                   (integerp (plist-get anchor :tokens)) (< 0 (plist-get anchor :tokens))
                   (integerp (plist-get anchor :estimate)) (< 0 (plist-get anchor :estimate))
                   (stringp (plist-get anchor :model)) (stringp (plist-get anchor :backend))
                   (eql (plist-get anchor :cut) (or (plist-get record :cut) 0)))
        (error "Malformed context usage anchor")))))

(defun emacs-agent-store--validate (data file &optional live-events)
  "Check DATA schema and identity for FILE before modifying the registry.
LIVE-EVENTS allows raw deltas and not-yet-recomputed block states in a copied
live list.  Durable snapshots require complete, consistent block metadata."
  (emacs-agent-store--plist data)
  (cl-loop for key in data by #'cddr do
           (unless (memq key '(:schema :adapter :id :key :project-root :name :created-at :provenance :updated-at :source :messages :events :runs :inputs :compaction :usage-anchor))
             (error "Unknown snapshot field")))
  (unless (eql (plist-get data :schema) emacs-agent-store--schema)
    (error "Unsupported session schema; no migration is provided, use a new data directory"))
  (unless (equal (plist-get data :adapter) emacs-agent-store--adapter)
    (error "Unsupported replay adapter"))
  (unless (and (stringp (plist-get data :id))
               (not (string-empty-p (plist-get data :id)))
               (numberp (plist-get data :created-at))
               (numberp (plist-get data :updated-at))
               (emacs-agent-store--identity-p (plist-get data :key) (plist-get data :project-root))
               (equal (expand-file-name file) (emacs-agent-store--file (plist-get data :id))))
    (error "Invalid session identity or filename"))
  (let ((name (plist-get data :name)) (provenance (plist-get data :provenance)))
    (unless (or (null name) (and (stringp name) (not (string-match-p "[[:cntrl:]]" name))))
      (error "Invalid conversation name"))
    (when provenance
      (emacs-agent-input--fields provenance '(:source-id :time))
      (unless (and (stringp (plist-get provenance :source-id))
                   (not (string-empty-p (plist-get provenance :source-id)))
                   (not (equal (plist-get provenance :source-id) (plist-get data :id)))
                   (numberp (plist-get provenance :time)))
        (error "Invalid conversation provenance"))))
  (dolist (field '(:messages :events :runs :inputs))
    (unless (proper-list-p (plist-get data field)) (error "Malformed session collection")))
  (emacs-agent-store--context data)
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
      (error "Malformed saved run"))
    (when (plist-get run :context-config)
      (emacs-agent-compaction-config (plist-get run :context-config))))
  (let ((run-ids (make-hash-table :test #'equal))
        (input-ids (make-hash-table :test #'equal))
        (prepared-ids (make-hash-table :test #'equal))
        (delivered-inputs (make-hash-table :test #'equal))
        (delivered-runs (make-hash-table :test #'equal)))
    (dolist (message (plist-get data :messages))
      (when (eq (plist-get message :role) 'user)
        (puthash (plist-get message :run-id) t delivered-runs)
        (when (plist-get message :input-id)
          (puthash (plist-get message :input-id) t delivered-inputs))))
    (dolist (run (plist-get data :runs))
      (when (gethash (plist-get run :id) run-ids) (error "Duplicate saved run ID"))
      (puthash (plist-get run :id) run run-ids))
    (dolist (input (plist-get data :inputs))
      (emacs-agent-input-validate-data input)
      (let* ((id (plist-get input :id))
             (run-id (plist-get (plist-get input :run) :id)))
        (when (or (gethash id input-ids) (gethash run-id prepared-ids)
                  (gethash id delivered-inputs) (gethash run-id delivered-runs))
          (error "Duplicate or already delivered pending input/run ID"))
        (puthash id t input-ids)
        (puthash run-id t prepared-ids)
        (when (and (eq (plist-get input :state) 'queued)
                   (eq (plist-get input :kind) 'ask)
                   (not (eq (plist-get (gethash run-id run-ids) :status) 'queued)))
          (error "Queued ask has no queued run")))))
  data)

(defun emacs-agent-store--bump-id (id)
  "Avoid reusing numeric IDs found in restored ID."
  (when (and (stringp id) (string-match "\\`\\(?:session\\|run\\|event\\|input\\)-\\([0-9]+\\)\\'" id))
    (setq emacs-agent-session--counter
          (max emacs-agent-session--counter (string-to-number (match-string 1 id))))))

(defun emacs-agent-store--read (file)
  "Read FILE as inert data, rejecting trailing forms."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let ((value (read (current-buffer))))
      (forward-comment (point-max))
      (unless (eobp) (error "Trailing data in session file"))
      (emacs-agent-store--data value))))

(defun emacs-agent-store--restore (file &optional root id)
  "Validate FILE, then register an idle session without selecting it.
When ID is supplied, require that ID and ROOT match the pointer first."
  (let ((data (emacs-agent-store--read file)))
    (emacs-agent-store--validate data file)
    (when (and id (not (and (equal id (plist-get data :id))
                           (equal root (plist-get data :project-root)))))
      (error "Selection pointer does not match conversation"))
    (or (let ((existing (gethash (plist-get data :id) emacs-agent-session--registry)))
          (when existing
            (unless (and (equal (emacs-agent-session-key existing) (plist-get data :key))
                         (equal (emacs-agent-session-project-root existing)
                                (plist-get data :project-root)))
              (error "Registered conversation scope mismatch"))
            existing))
        (let* ((session (make-emacs-agent-session
                         :id (plist-get data :id) :key (plist-get data :key)
                         :project-root (plist-get data :project-root)
                         :name (plist-get data :name)
                         :created-at (plist-get data :created-at)
                         :provenance (plist-get data :provenance)
                         :updated-at (plist-get data :updated-at)
                         :messages (plist-get data :messages) :events (plist-get data :events)
                         :compaction (plist-get data :compaction)
                         :usage-anchor (plist-get data :usage-anchor)))
               (source (plist-get data :source))
               (buffer (and (stringp (plist-get source :name)) (get-buffer (plist-get source :name)))))
          (when (and buffer (equal (buffer-local-value 'buffer-file-name buffer) (plist-get source :file)))
            (setf (emacs-agent-session-last-source-buffer session) buffer))
          (emacs-agent-store--bump-id (emacs-agent-session-id session))
          (dolist (event (emacs-agent-session-events session))
            (emacs-agent-store--bump-id (plist-get event :id))
            (emacs-agent-store--bump-id (plist-get event :last-id))
            (emacs-agent-store--bump-id (plist-get event :run-id))
            (when (eq (plist-get event :type) 'input)
              (let ((payload (plist-get event :payload)))
                (when (and (proper-list-p payload) (cl-evenp (length payload)))
                  (emacs-agent-store--bump-id (plist-get payload :id))
                  (emacs-agent-store--bump-id (plist-get payload :input-id))
                  (emacs-agent-store--bump-id (plist-get payload :target-id))
                  (let ((run (plist-get payload :run)))
                    (when (and (proper-list-p run) (cl-evenp (length run)))
                      (emacs-agent-store--bump-id (plist-get run :id))))))))
          (dolist (message (emacs-agent-session-messages session))
            (emacs-agent-store--bump-id (plist-get message :run-id))
            (emacs-agent-store--bump-id (plist-get message :input-id)))
          ;; All durable IDs must be reserved before interruption events allocate
          ;; new ones.  Recovery inputs are inert and never enter the run queue.
          (setf (emacs-agent-session-inputs session)
                (mapcar (lambda (saved)
                          (emacs-agent-store--bump-id (plist-get saved :id))
                          (emacs-agent-store--bump-id (plist-get saved :target-id))
                          (emacs-agent-store--bump-id (plist-get (plist-get saved :run) :id))
                          (emacs-agent-input-restore saved session))
                        (plist-get data :inputs)))
          (dolist (saved (plist-get data :runs))
            (emacs-agent-store--bump-id (plist-get saved :id)))
          ;; Insert only after validation.  Interrupt records are generated
          ;; without event hooks, so restore neither autosaves nor sends HTTP.
          (dolist (saved (plist-get data :runs))
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
          (puthash (emacs-agent-session-id session) session emacs-agent-session--registry)
          session))))

(defun emacs-agent-store-load-session (root)
  "Restore ROOT's project pointer and select it; nil ROOT never restores.
Missing or corrupt pointer targets fail explicitly, never create a replacement."
  (when root
    (let ((pointer (emacs-agent-store--selection-file root)))
      (when (file-exists-p pointer)
        (condition-case err
            (let ((data (emacs-agent-store--read pointer)))
              (emacs-agent-input--fields data '(:schema :project-root :id))
              (unless (and (eql (plist-get data :schema) emacs-agent-store--schema)
                           (equal root (plist-get data :project-root))
                           (stringp (plist-get data :id))
                           (not (string-empty-p (plist-get data :id))))
                (error "Invalid project selection pointer"))
              (let ((session (emacs-agent-store--restore
                              (emacs-agent-store--file (plist-get data :id))
                              root (plist-get data :id))))
                (puthash root (emacs-agent-session-id session) emacs-agent-session--selected)
                session))
          (error (user-error "Cannot restore %s: %s" pointer (error-message-string err))))))))

(defun emacs-agent-store-load-all ()
  "Register only new-namespace snapshots, never select or load legacy archives."
  (let ((directory (expand-file-name "conversations/" emacs-agent-data-directory)))
    (when (file-directory-p directory)
      (dolist (file (directory-files directory t "\\.eld\\'"))
        (condition-case err (emacs-agent-store--restore file)
          (error (display-warning 'emacs-agent
                                  (format "Cannot restore %s: %s" file (error-message-string err)))))))))

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
