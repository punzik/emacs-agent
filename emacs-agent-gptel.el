;;; emacs-agent-gptel.el --- Run lifecycle and gptel adapter -*- lexical-binding: t; -*-

;;; Commentary:
;; Streaming run adapter.  Experimental gptel history/ID contracts
;; are isolated here; no gptel hooks or global selected tools are changed.

;;; Code:
(require 'gptel)
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
  (and (eq run (emacs-agent-session-active-run (emacs-agent-run-session run)))
       (memq (emacs-agent-run-status run) '(requesting streaming tool-running paused))))

(defun emacs-agent-gptel--history (run)
  "Convert RUN's session history into gptel's experimental prompt format.
Only plain assistant text and paired tool records are replayed.  Reasoning is
journal-only; opaque provider reasoning replay is not supported yet."
  (mapcar
   (lambda (message)
     (pcase (plist-get message :role)
       ('user
        (let ((text (plist-get message :text))
              (context (plist-get message :context)))
          (list 'prompt
                (if (and context
                         (or (eq emacs-agent-context-history 'full)
                             (and (eq emacs-agent-context-history 'current)
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
    (cl-mapcar (lambda (tuple spec) (cons (plist-get spec :id) tuple))
               (reverse calls) pending)))

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
                         :id id :name "eval_elisp" :args args :result result)))
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
    (dolist (state '(DONE ERRS ABRT))
      (setf (alist-get state (gptel-fsm-handlers fsm))
            (append (alist-get state (gptel-fsm-handlers fsm))
                    (list (apply-partially #'emacs-agent-gptel--terminal run)))))
    fsm))

(defun emacs-agent-gptel--callback (run response info)
  "Handle RESPONSE/INFO for RUN; stale and terminal callbacks are ignored."
  (when (emacs-agent-gptel--live-p run)
    (condition-case err
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
                 ((eq text t) (emacs-agent-session-record run 'reasoning-end nil))))
          ((pred stringp)
           (emacs-agent-gptel--streaming run)
           (push response (emacs-agent-run-assistant-chunks run))
           (emacs-agent-session-record run 'assistant response)))
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
      (emacs-agent-session-record run 'requesting
                                  (list :backend (and (emacs-agent-run-backend run)
                                                      (gptel-backend-name (emacs-agent-run-backend run)))
                                        :model (format "%s" (emacs-agent-run-model run))))
      (condition-case err
          (with-current-buffer (emacs-agent-run-transport-buffer run)
            (setq-local default-directory
                        (plist-get (emacs-agent-run-editor-context run) :default-directory))
            (setq-local gptel-backend (emacs-agent-run-backend run)
                        gptel-model (emacs-agent-run-model run)
                        gptel-use-tools t gptel-use-context nil gptel-confirm-tool-calls t
                        ;; Structured role/tool parsing must not inherit an
                        ;; unrelated user preference for untracked plain text.
                        gptel-track-response t)
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
                :fsm fsm :callback (apply-partially #'emacs-agent-gptel--callback run))))
        (quit (emacs-agent-gptel--finish run 'cancelled "Request setup interrupted"))
        (error (emacs-agent-gptel--finish run 'failed (error-message-string err)))))))

(defun emacs-agent-gptel-submit (run)
  "Capture source-buffer gptel configuration and schedule queued RUN.
Each run has its own transport, callback guard, tool registry and budget."
  (let ((source (emacs-agent-run-source-buffer run)))
    (with-current-buffer (if (buffer-live-p source) source (current-buffer))
      (setf (emacs-agent-run-backend run) gptel-backend
            (emacs-agent-run-model run) gptel-model
            (emacs-agent-run-stream run) emacs-agent-stream)))
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
