;;; emacs-agent-gptel.el --- Run lifecycle and gptel adapter -*- lexical-binding: t; -*-

;;; Commentary:
;; Streaming run adapter.  Experimental gptel history/ID contracts
;; are isolated here; no gptel hooks or global selected tools are changed.

;;; Code:
(require 'gptel)
(require 'gptel-openai)
(require 'emacs-agent-session)
(require 'emacs-agent-context)

(defvar emacs-agent-system-prompt)

(defcustom emacs-agent-stream t
  "Request streaming text and supplied reasoning when the backend supports it.
Captured per run at submission.  Unsupported backends can return one response."
  :type 'boolean :group 'emacs-agent)

(defcustom emacs-agent-max-tool-calls 100
  "Number of tool calls allowed before pausing a run.
Resume grants another block of this size (at least one).  Zero pauses before
any execution.  Counts include evaluations returning errors or quit."
  :type 'natnum :group 'emacs-agent)

(defvar emacs-agent-gptel--executing-tool nil
  "Non-nil while any run is executing Lisp, including nested event loops.")

(defun emacs-agent-gptel--live-p (run)
  "Whether RUN still owns its session and may receive callbacks."
  (and (eq (gethash (emacs-agent-session-key (emacs-agent-run-session run))
                    emacs-agent-session--registry)
           (emacs-agent-run-session run))
       (eq run (emacs-agent-session-active-run (emacs-agent-run-session run)))
       (memq (emacs-agent-run-status run) '(requesting streaming tool-running paused))))

(defun emacs-agent-gptel--validate-protocol (protocol)
  "Validate replayable text reasoning PROTOCOL; do not discard unknown fields."
  (unless (and (proper-list-p protocol) (cl-evenp (length protocol)))
    (error "Malformed reasoning protocol fields"))
  (let (seen)
    (cl-loop for (key value) on protocol by #'cddr do
             (unless (and (memq key '(:reasoning :reasoning_content))
                          (not (memq key seen)) (or (stringp value) (eq value :null)))
               (error "Unsupported reasoning protocol field: %s" key))
             (push key seen))))

(defun emacs-agent-gptel--unsupported (run reason)
  "Make unsupported protocol loss explicit and block future replay for RUN."
  (emacs-agent-session-record
   run 'error reason
   (list :role 'unsupported-protocol :run-id (emacs-agent-run-id run) :reason reason))
  (error "%s" reason))

(defun emacs-agent-gptel--response-protocol (run info)
  "Capture known text reasoning from the original assistant tool message.
Unknown fields fail closed; the original gptel request remains authoritative
for continuations.  Persist only serializable, validated replay fields."
  (let* ((messages (plist-get (plist-get info :data) :messages))
         (last (and (vectorp messages) (> (length messages) 0)
                    (aref messages (1- (length messages)))))
         protocol)
    (when (and (plist-member info :data)
               (not (and (equal (plist-get last :role) "assistant") (plist-get last :tool_calls))))
      (emacs-agent-gptel--unsupported run "Unsupported assistant tool transcript shape"))
    (when (and (equal (plist-get last :role) "assistant") (plist-get last :tool_calls))
      (cl-loop for call across (plist-get last :tool_calls) do
               (cl-loop for key in call by #'cddr do
                        (unless (memq key '(:id :type :function :index))
                          (emacs-agent-gptel--unsupported run
                           (format "Unsupported tool protocol field: %s" key))))
               (cl-loop for key in (plist-get call :function) by #'cddr do
                        (unless (memq key '(:name :arguments))
                          (emacs-agent-gptel--unsupported run
                           (format "Unsupported function protocol field: %s" key)))))
      (cl-loop for (key value) on last by #'cddr do
               (cond ((memq key '(:role :content :tool_calls)) nil)
                     ((memq key '(:reasoning :reasoning_content))
                      (setq protocol (append protocol (list key value))))
                     ((and (eq key :refusal) (eq value :null)) nil)
                     (t (emacs-agent-gptel--unsupported
                         run (format "Unsupported assistant protocol field: %s" key))))))
    (condition-case err (emacs-agent-gptel--validate-protocol protocol)
      (error (emacs-agent-gptel--unsupported run (error-message-string err))))
    (setf (emacs-agent-run-response-protocol run) (copy-tree protocol))))

(defun emacs-agent-gptel--restore-protocol (run fsm)
  "Restore known reasoning fields to gptel-generated assistant tool messages.
Run before each WAIT transport handler.  gptel still owns all serialization,
call/result construction and the within-run transcript."
  (let ((protocols (make-hash-table :test #'equal))
        (data (plist-get (gptel-fsm-info fsm) :data)))
    (dolist (message (emacs-agent-session-messages (emacs-agent-run-session run)))
      (when (eq (plist-get message :role) 'tool)
        (let ((id (plist-get message :id)))
          (puthash id message protocols)
          (puthash (gptel--openai-format-tool-id id) message protocols))))
    (cl-loop for message across (plist-get data :messages) do
             (when (equal (plist-get message :role) "assistant")
               (cl-loop for call across (or (plist-get message :tool_calls) []) do
                        (let* ((record (gethash (plist-get call :id) protocols))
                               (protocol (plist-get record :protocol)))
                          (when record (plist-put call :id (plist-get record :id)))
                          (cl-loop for (key value) on protocol by #'cddr do
                                   (when (and (plist-member message key)
                                              (not (equal (plist-get message key) value)))
                                     (error "Conflicting assistant reasoning replay fields"))
                                   ;; Generated messages contain :role, so plist-put
                                   ;; extends the existing object without replacing it.
                                   (plist-put message key value)))))
             (when (equal (plist-get message :role) "tool")
               (when-let* ((record (gethash (plist-get message :tool_call_id) protocols)))
                 (plist-put message :tool_call_id (plist-get record :id)))))))

(defun emacs-agent-gptel--validate-history (messages)
  "Validate normalized MESSAGES without mutating or dropping fields.
Unknown protocol fields are rejected rather than silently stripped.  Each
assistant/tool record must belong to the preceding user turn."
  (unless (proper-list-p messages) (error "Malformed agent history list"))
  (let (turn seen-turns (ids (make-hash-table :test #'equal)))
    (dolist (message messages)
      (unless (and (proper-list-p message) (cl-evenp (length message)))
        (error "Malformed agent history record"))
      (let* ((role (plist-get message :role))
             (run-id (plist-get message :run-id))
             (allowed (pcase role
                        ('user '(:role :run-id :text :context))
                        ('assistant '(:role :run-id :text))
                        ('tool '(:role :run-id :id :name :args :result :protocol))
                        ('unsupported-protocol
                         (error "Session history is not replayable: %s" (plist-get message :reason)))
                        (_ (error "Unsupported agent history role: %s" role))))
             keys)
        (cl-loop for key in message by #'cddr do
                 (unless (and (memq key allowed) (not (memq key keys)))
                   (error "Unsupported or duplicate history field: %s" key))
                 (push key keys))
        (unless (and (stringp run-id) (not (string-empty-p run-id)))
          (error "Missing history turn ID"))
        (if (eq role 'user)
            (progn
              (when (member run-id seen-turns) (error "Duplicate history user turn"))
              (push run-id seen-turns)
              (setq turn run-id)
              (when (plist-get message :context)
                (emacs-agent-context-render (plist-get message :context))))
          (unless (equal run-id turn) (error "History record outside its user turn")))
        (if (eq role 'tool)
            (let ((id (plist-get message :id)) (args (plist-get message :args)))
              (unless (and (stringp id) (not (string-empty-p id))
                           (not (gethash (gptel--openai-format-tool-id id) ids))
                           (equal (plist-get message :name) "eval_elisp")
                           (proper-list-p args) (= (length args) 2)
                           (eq (car args) :expression) (stringp (cadr args))
                           (stringp (plist-get message :result)))
                (error "Malformed or duplicate paired tool record"))
              (emacs-agent-gptel--validate-protocol (plist-get message :protocol))
              (puthash (gptel--openai-format-tool-id id) t ids))
          (unless (stringp (plist-get message :text))
            (error "History text must be a string")))))))

(cl-defun emacs-agent-gptel--history (run &optional (policy (emacs-agent-run-context-policy run)))
  "Build RUN's gptel history using its frozen POLICY, or an explicit override.
Filter only editor context; never edit stored records or protocol pairs."
  (unless (memq policy '(nil current full)) (error "Invalid agent context policy: %s" policy))
  (emacs-agent-gptel--validate-history
   (emacs-agent-session-messages (emacs-agent-run-session run)))
  (mapcar
   (lambda (message)
     (pcase (plist-get message :role)
       ('user
        (let ((text (plist-get message :text))
              (context (plist-get message :context)))
          (list 'prompt
                (if (and context
                         (or (eq policy 'full)
                             (and (eq policy 'current)
                                  (equal (plist-get message :run-id) (emacs-agent-run-id run)))))
                    (concat text "\n\n" (emacs-agent-context-render context))
                  text))))
       ('assistant (list 'response (plist-get message :text)))
       ('tool (cons 'tool (cl-loop for key in '(:id :name :args :result)
                                  append (list key (plist-get message key)))))
       (_ (error "Unsupported agent history record"))))
   (emacs-agent-session-messages (emacs-agent-run-session run))))

(defun emacs-agent-gptel--tool-entries (calls info)
  "Pair pending CALLS with provider IDs from INFO.
Pinned gptel pushes callback tuples in reverse order.  :tool-use and its :id
are undocumented.  Prefer all entries for duplicate deliveries, otherwise
use only unfinished entries.  Fail closed when this contract changes."
  (let* ((specs (plist-get info :tool-use))
         (pending (if (= (length calls) (length specs)) specs
                    (cl-remove-if (lambda (spec) (plist-get spec :result)) specs))))
    (unless (and (= (length calls) (length pending))
                 (cl-every (lambda (spec) (stringp (plist-get spec :id))) pending))
      (error "Unsupported gptel tool ID contract"))
    (let* ((entries (cl-mapcar (lambda (tuple spec) (cons (plist-get spec :id) tuple))
                              (reverse calls) pending))
           (messages (plist-get (plist-get info :data) :messages))
           (last (and (vectorp messages) (> (length messages) 0)
                      (aref messages (1- (length messages)))))
           (indices (make-hash-table :test #'equal)))
      ;; Streaming Chat parsing pushes :tool-use in reverse array order.
      ;; Its original call indices restore provider order for side effects.
      (cl-loop for call across (or (plist-get last :tool_calls) []) do
               (puthash (plist-get call :id) (plist-get call :index) indices))
      (if (cl-every (lambda (entry) (integerp (gethash (car entry) indices))) entries)
          (cl-stable-sort entries #'< :key (lambda (entry) (gethash (car entry) indices)))
        entries))))

(defun emacs-agent-gptel--flush-assistant (run)
  "Commit accumulated assistant chunks for this HTTP response exactly once.
Streaming deltas are display events; replay uses one complete logical message."
  (when (emacs-agent-run-assistant-chunks run)
    (let ((text (apply #'concat (nreverse (emacs-agent-run-assistant-chunks run)))))
      (setf (emacs-agent-run-assistant-chunks run) nil)
      (emacs-agent-session-record
       run 'assistant-end nil
       (list :role 'assistant :run-id (emacs-agent-run-id run) :text text)))))

(defun emacs-agent-gptel--streaming (run)
  "Expose streaming status without overwriting a tool-budget pause."
  (when (eq (emacs-agent-run-status run) 'requesting)
    (setf (emacs-agent-run-status run) 'streaming)
    (emacs-agent-session-record run 'streaming "Receiving response")))

(defun emacs-agent-gptel--finish (run status &optional detail)
  "Terminalize RUN before abort callbacks, release its queue and start the next.
Previously executed Lisp is never undone.  Transport buffers remain until
reset/cleanup support is added, so gptel can finish its own FSM safely."
  (when (emacs-agent-gptel--live-p run)
    (emacs-agent-gptel--flush-assistant run)
    (setf (emacs-agent-run-status run) status
          (emacs-agent-run-pending-tools run) nil)
    (let ((session (emacs-agent-run-session run)))
      (emacs-agent-session-record run status (or detail (symbol-name status)))
      ;; Mark terminal BEFORE abort, whose callback can arrive synchronously.
      (when (and (not (eq status 'completed))
                 (buffer-live-p (emacs-agent-run-transport-buffer run)))
        (condition-case err
            (gptel-abort (emacs-agent-run-transport-buffer run))
          ((error quit) (message "Emacs Agent abort: %s" (error-message-string err)))))
      (setf (emacs-agent-session-active-run session) nil)
      (emacs-agent-gptel--start-next session))))

(defun emacs-agent-gptel--execute (run entry)
  "Execute one claimed ENTRY for RUN, then deliver its result exactly once."
  (pcase-let ((`(,id ,tool ,args ,continuation) entry))
    (unless (equal (gptel-tool-name tool) "eval_elisp")
      (error "Unexpected tool: %s" (gptel-tool-name tool)))
    (cl-incf (emacs-agent-run-tool-count run))
    (puthash id 'executing (emacs-agent-run-tool-call-ids run))
    (emacs-agent-session-record run 'tool-call (list :id id :args args))
    (let* ((source (emacs-agent-run-source-buffer run))
           (buffer (if (buffer-live-p source) source
                     (emacs-agent-run-transport-buffer run)))
           ;; No selected-window switch, widening, or stale point restoration.
           (result (with-current-buffer buffer
                     (emacs-agent-eval (plist-get args :expression))))
           (record (list :role 'tool :run-id (emacs-agent-run-id run)
                         :id id :name "eval_elisp" :args args :result result
                         :protocol (copy-tree (emacs-agent-run-response-protocol run)))))
      (puthash id result (emacs-agent-run-tool-call-ids run))
      ;; Preserve effects/results even if Lisp cancelled its own run.
      (emacs-agent-session-record run 'tool-result
                                  (list :id id :result result) record)
      (when (emacs-agent-gptel--live-p run)
        (funcall continuation result)))))

(defun emacs-agent-gptel--drain (run)
  "Execute pending tools sequentially for RUN or pause at its budget.
The global guard also prevents overlapping eval during `accept-process-output'
or another recursive event loop inside unrestricted tool Lisp."
  (when (and (emacs-agent-gptel--live-p run)
             (not (eq (emacs-agent-run-status run) 'paused))
             (not emacs-agent-gptel--executing-tool))
    (condition-case err
        (while (and (emacs-agent-gptel--live-p run)
                    (emacs-agent-run-pending-tools run)
                    (not (eq (emacs-agent-run-status run) 'paused)))
          (if (>= (emacs-agent-run-tool-count run) (emacs-agent-run-tool-budget run))
              (progn
                (setf (emacs-agent-run-status run) 'paused)
                (emacs-agent-session-record run 'paused "Tool budget reached; resume or cancel"))
            (setf (emacs-agent-run-status run) 'tool-running)
            (let ((emacs-agent-gptel--executing-tool t))
              (emacs-agent-gptel--execute run (pop (emacs-agent-run-pending-tools run))))
            (when (and (emacs-agent-gptel--live-p run)
                       (null (emacs-agent-run-pending-tools run)))
              (setf (emacs-agent-run-status run) 'requesting))))
      (quit (emacs-agent-gptel--finish run 'cancelled "Tool dispatch interrupted"))
      (error (emacs-agent-gptel--finish run 'failed (error-message-string err))))
    ;; A different session may have received tools while Lisp pumped events.
    (maphash (lambda (_key session)
               (emacs-agent-gptel--start-next session)
               (when-let* ((other (emacs-agent-session-active-run session)))
                 (when (and (not (eq other run)) (emacs-agent-run-pending-tools other)
                            (not (eq (emacs-agent-run-status other) 'paused)))
                   (emacs-agent-gptel--drain other))))
             emacs-agent-session--registry)))

(defun emacs-agent-gptel--terminal (run fsm)
  "Observe FSM terminal state even when a successful response has no text.
This is a request-local FSM handler: gptel's global handlers are untouched."
  (when (emacs-agent-gptel--live-p run)
    (let ((info (gptel-fsm-info fsm)))
      (pcase (gptel-fsm-state fsm)
        ('DONE (emacs-agent-gptel--finish run 'completed))
        ('ABRT (emacs-agent-gptel--finish run 'cancelled "Provider request aborted"))
        ('ERRS (emacs-agent-gptel--finish run 'failed
                                          (format "%s" (or (plist-get info :error)
                                                           (plist-get info :status)
                                                           "Request failed"))))))))

(defun emacs-agent-gptel--make-fsm (run)
  "Make RUN's private FSM with appended terminal handlers.
Slot access and terminal state names are isolated pinned-gptel contracts."
  (let ((fsm (gptel-make-fsm)))
    (setf (gptel-fsm-handlers fsm) (copy-tree (gptel-fsm-handlers fsm)))
    (setf (alist-get 'WAIT (gptel-fsm-handlers fsm))
          (cons (apply-partially #'emacs-agent-gptel--restore-protocol run)
                (alist-get 'WAIT (gptel-fsm-handlers fsm))))
    (dolist (state '(DONE ERRS ABRT))
      (setf (alist-get state (gptel-fsm-handlers fsm))
            (append (alist-get state (gptel-fsm-handlers fsm))
                    (list (apply-partially #'emacs-agent-gptel--terminal run)))))
    fsm))

(defun emacs-agent-gptel--callback (run response info)
  "Handle RESPONSE/INFO for RUN; stale and terminal callbacks are ignored."
  (when (emacs-agent-gptel--live-p run)
    (condition-case err
        (progn
          (dolist (key '(:signature :reasoning_details :encrypted_content :thoughtSignature))
            (when (plist-get info key)
              (emacs-agent-gptel--unsupported run (format "Unsupported opaque response field: %s" key))))
          (pcase response
          ('abort (emacs-agent-gptel--finish run 'cancelled "Provider request aborted"))
          ('nil (emacs-agent-gptel--finish run 'failed
                                         (format "%s" (or (plist-get info :status) "No response"))))
          ('t
           ;; End of ONE HTTP response, not necessarily the whole tool loop.
           (emacs-agent-gptel--flush-assistant run)
           (when (eq (emacs-agent-run-status run) 'streaming)
             (setf (emacs-agent-run-status run) 'requesting)))
          (`(tool-call . ,calls)
           (emacs-agent-gptel--response-protocol run info)
           (emacs-agent-gptel--flush-assistant run)
           (dolist (entry (emacs-agent-gptel--tool-entries calls info))
             (unless (gethash (car entry) (emacs-agent-run-tool-call-ids run))
               ;; Claim before dispatch, including tools held by a pause.
               (puthash (car entry) 'pending (emacs-agent-run-tool-call-ids run))
               (setf (emacs-agent-run-pending-tools run)
                     (nconc (emacs-agent-run-pending-tools run) (list entry)))))
           (emacs-agent-gptel--drain run))
          (`(tool-result . ,_) nil) ; Captured before continuation.
          (`(reasoning . ,text)
           (cond ((stringp text)
                  (emacs-agent-gptel--streaming run)
                  (emacs-agent-session-record run 'reasoning text))
                 ((eq text t) (emacs-agent-session-record run 'reasoning-end nil))
                 (t (emacs-agent-gptel--unsupported run "Unsupported reasoning callback data"))))
          ((pred stringp)
           (emacs-agent-gptel--streaming run)
           (push response (emacs-agent-run-assistant-chunks run))
           (emacs-agent-session-record run 'assistant response))
          (_ (emacs-agent-gptel--unsupported run "Unsupported gptel callback kind"))))
      (quit (emacs-agent-gptel--finish run 'cancelled "Callback interrupted"))
      (error (emacs-agent-gptel--finish run 'failed (error-message-string err))))))

(defun emacs-agent-gptel--start-next (session)
  "Start the head of SESSION's FIFO if it has no active run."
  (unless (or (emacs-agent-session-active-run session)
              emacs-agent-gptel--executing-tool)
    (when-let* ((run (pop (emacs-agent-session-pending-runs session))))
      (setf (emacs-agent-session-active-run session) run
            (emacs-agent-run-status run) 'requesting
            (emacs-agent-run-tool-budget run) emacs-agent-max-tool-calls
            (emacs-agent-run-transport-buffer run)
            (generate-new-buffer (format " *emacs-agent-transport: %s*" (emacs-agent-run-id run))))
      (emacs-agent-session-record
       run 'user (emacs-agent-run-user-text run)
       (list :role 'user :run-id (emacs-agent-run-id run)
             :text (emacs-agent-run-user-text run) :context (emacs-agent-run-editor-context run)))
      (condition-case err
          (progn
            (unless (equal gptel-version "0.9.9.5")
              (error "Unsupported gptel version %s; replay requires the tested 0.9.9.5 revision" gptel-version))
            (unless (eq (type-of (emacs-agent-run-backend run)) 'gptel-openai)
              (error "Unsupported replay backend %s; currently only Chat Completions is supported"
                     (type-of (emacs-agent-run-backend run))))
            (unless (or (symbolp (emacs-agent-run-model run)) (stringp (emacs-agent-run-model run)))
              (error "Invalid gptel model identifier"))
            (emacs-agent-session-record
             run 'requesting
             (list :backend (gptel-backend-name (emacs-agent-run-backend run))
                   :model (format "%s" (emacs-agent-run-model run))
                   :context-policy (emacs-agent-run-context-policy run)
                   :stream (emacs-agent-run-stream run)
                   :tool-budget (emacs-agent-run-tool-budget run)))
            (with-current-buffer (emacs-agent-run-transport-buffer run)
            (setq-local default-directory
                        (plist-get (emacs-agent-run-editor-context run) :default-directory))
            (setq-local gptel-backend (emacs-agent-run-backend run)
                        gptel-model (emacs-agent-run-model run)
                        gptel-use-tools t gptel-use-context nil gptel-confirm-tool-calls t
                        ;; Structured role/tool parsing must not inherit an
                        ;; unrelated user preference for untracked plain text.
                        gptel-track-response t
                        ;; Agent-owned history must not inherit chat UI truncation.
                        gptel--num-messages-to-send nil)
            (setq-local gptel-tools
                        (list (gptel-make-tool
                               :name "eval_elisp" :category "emacs-agent"
                               :function #'emacs-agent-eval :confirm t
                               :description "Execute arbitrary Lisp in the shared live Emacs."
                               :args '((:name "expression" :type string
                                        :description "One or more Lisp forms.")))))
            (let ((fsm (emacs-agent-gptel--make-fsm run)))
              (setf (emacs-agent-run-request-handle run) fsm)
              (gptel-request (emacs-agent-gptel--history run)
                :buffer (current-buffer) :stream (emacs-agent-run-stream run) :system emacs-agent-system-prompt
                :fsm fsm :transforms '(ignore)
                :callback (apply-partially #'emacs-agent-gptel--callback run)))))
        (quit (emacs-agent-gptel--finish run 'cancelled "Request setup interrupted"))
        (error (emacs-agent-gptel--finish run 'failed (error-message-string err)))))))

(defun emacs-agent-gptel-submit (run)
  "Capture source-buffer gptel configuration and schedule queued RUN.
Each run has its own transport, callback guard, tool registry and budget."
  (unless (eq (gethash (emacs-agent-session-key (emacs-agent-run-session run))
                      emacs-agent-session--registry)
              (emacs-agent-run-session run))
    (user-error "Stale agent session; reopen from a working buffer"))
  (let ((source (emacs-agent-run-source-buffer run)))
    (with-current-buffer (if (buffer-live-p source) source (current-buffer))
      (setf (emacs-agent-run-backend run) gptel-backend
            (emacs-agent-run-model run) gptel-model
            (emacs-agent-run-stream run) emacs-agent-stream
            (emacs-agent-run-context-policy run) emacs-agent-context-history)))
  (emacs-agent-session-record run 'queued (emacs-agent-run-user-text run))
  (emacs-agent-gptel--start-next (emacs-agent-run-session run))
  run)

(defun emacs-agent-gptel-cancel (session)
  "Cancel SESSION's active run; the next queued run is allowed to start."
  (if-let* ((run (emacs-agent-session-active-run session)))
      (emacs-agent-gptel--finish run 'cancelled "Cancelled; existing Lisp effects remain")
    (user-error "No active agent run")))

(defun emacs-agent-gptel-resume (session)
  "Grant another tool budget to SESSION's paused run without a network retry."
  (let ((run (emacs-agent-session-active-run session)))
    (unless (and run (eq (emacs-agent-run-status run) 'paused))
      (user-error "No paused agent run"))
    (cl-incf (emacs-agent-run-tool-budget run) (max 1 emacs-agent-max-tool-calls))
    (setf (emacs-agent-run-status run) 'requesting)
    (emacs-agent-session-record run 'resumed "Continuing pending tools; no retry")
    (emacs-agent-gptel--drain run)))

(provide 'emacs-agent-gptel)
;;; emacs-agent-gptel.el ends here
