;;; emacs-agent-input.el --- Frozen pending inputs -*- lexical-binding: t; -*-

;;; Code:
(require 'emacs-agent-session)
(require 'emacs-agent-context)
(require 'emacs-agent-compaction)

(declare-function gptel-backend-name "gptel-request" (backend))
(defvar gptel-backend)
(defvar gptel-model)
(defvar emacs-agent-stream)
(defvar emacs-agent-max-tool-calls)
(autoload 'emacs-agent-gptel-submit "emacs-agent-gptel")

(defcustom emacs-agent-pending-input-limit 8
  "Maximum undelivered inputs, including withdrawn recovery entries, per session."
  :type 'natnum :group 'emacs-agent)
(defcustom emacs-agent-pending-byte-limit (* 256 1024)
  "Maximum UTF-8 serialized bytes of all undelivered input data per session.
Includes text, context and instructions, not backend objects or credentials."
  :type 'natnum :group 'emacs-agent)

(cl-defstruct emacs-agent-input
  id kind (state 'prepared) run target target-id reason backend-name source)

(defun emacs-agent-input-data (input)
  "Return durable INPUT data, without live backend/editor objects or credentials."
  (let ((run (emacs-agent-input-run input)))
    (list :id (emacs-agent-input-id input) :kind (emacs-agent-input-kind input)
          :state (emacs-agent-input-state input) :target-id (emacs-agent-input-target-id input)
          :reason (emacs-agent-input-reason input)
          :run (list :id (emacs-agent-run-id run) :user-text (emacs-agent-run-user-text run)
                     :context (emacs-agent-run-editor-context run)
                     :source (emacs-agent-input-source input)
                     :backend-name (emacs-agent-input-backend-name input)
                     :model (emacs-agent-run-model run) :stream (emacs-agent-run-stream run)
                     :context-policy (emacs-agent-run-context-policy run)
                     :tool-budget (emacs-agent-run-tool-budget run)
                     :context-config (emacs-agent-run-context-config run)
                     :instructions (emacs-agent-run-instructions run)))))

(defun emacs-agent-input--fields (data allowed)
  "Require a proper keyword plist DATA with only unique ALLOWED fields."
  (unless (and (proper-list-p data) (cl-evenp (length data))) (error "Malformed input data"))
  (let (seen)
    (cl-loop for key in data by #'cddr do
             (unless (and (memq key allowed) (not (memq key seen)))
               (error "Unknown or duplicate pending input field"))
             (push key seen))))

(defun emacs-agent-input--validate-instructions (instructions &optional agent-file)
  "Validate an instruction snapshot INSTRUCTIONS without reading any file.
AGENT-FILE validates the leaf EMACSAGENT.md snapshot, forbidding nesting."
  (emacs-agent-input--fields
   instructions (if agent-file '(:status :root :path :text :warnings)
                  '(:status :root :path :text :warnings :emacsagent :helpers)))
  (unless (and (memq (plist-get instructions :status) '(loaded missing disabled no-project error))
               (or (null (plist-get instructions :root)) (stringp (plist-get instructions :root)))
               (or (null (plist-get instructions :path)) (stringp (plist-get instructions :path)))
               (if (eq (plist-get instructions :status) 'loaded)
                   (stringp (plist-get instructions :text))
                 (null (plist-get instructions :text)))
               (proper-list-p (plist-get instructions :warnings))
               (cl-every #'stringp (plist-get instructions :warnings)))
    (error "Malformed input instructions"))
  (when (plist-member instructions :helpers)
    (unless (and (stringp (plist-get instructions :helpers))
                 (not (string-empty-p (string-trim (plist-get instructions :helpers)))))
      (error "Malformed user helper descriptions")))
  (when-let* ((agent (plist-get instructions :emacsagent)))
    (emacs-agent-input--validate-instructions agent t)))

(defun emacs-agent-input-validate-data (data)
  "Validate durable input DATA without resolving or executing anything."
  (emacs-agent-input--fields data '(:id :kind :state :target-id :reason :run))
  (let ((run (plist-get data :run)))
    (emacs-agent-input--fields
     run '(:id :user-text :context :source :backend-name :model :stream :context-policy
           :tool-budget :context-config :instructions))
    (unless (and (stringp (plist-get data :id)) (not (string-empty-p (plist-get data :id)))
                 (memq (plist-get data :kind) '(ask steer))
                 (memq (plist-get data :state) '(prepared queued withdrawn))
                 (or (null (plist-get data :target-id)) (stringp (plist-get data :target-id)))
                 (or (not (eq (plist-get data :kind) 'steer))
                     (and (stringp (plist-get data :target-id))
                          (not (string-empty-p (plist-get data :target-id)))))
                 (symbolp (plist-get data :reason))
                 (stringp (plist-get run :id)) (not (string-empty-p (plist-get run :id)))
                 (stringp (plist-get run :user-text))
                 (not (string-empty-p (string-trim (plist-get run :user-text))))
                 (stringp (plist-get run :backend-name))
                 (or (symbolp (plist-get run :model)) (stringp (plist-get run :model)))
                 (memq (plist-get run :stream) '(nil t))
                 (memq (plist-get run :context-policy) '(nil current full))
                 (natnump (plist-get run :tool-budget)))
      (error "Malformed pending input"))
    (when (plist-get run :context) (emacs-agent-context-render (plist-get run :context)))
    (when (plist-get run :context-config)
      (emacs-agent-compaction-config (plist-get run :context-config)))
    (when-let* ((source (plist-get run :source)))
      (emacs-agent-input--fields source '(:name :file))
      (unless (and (stringp (plist-get source :name))
                   (not (string-empty-p (plist-get source :name)))
                   (or (null (plist-get source :file)) (stringp (plist-get source :file))))
        (error "Malformed input source")))
    (when-let* ((instructions (plist-get run :instructions)))
      (emacs-agent-input--validate-instructions instructions)))
  data)

(defun emacs-agent-input-restore (data session)
  "Rebuild DATA as recovery-only input in SESSION, never scheduling a request."
  (emacs-agent-input-validate-data data)
  (let* ((saved (plist-get data :run))
         (source (plist-get saved :source))
         (buffer (and source (get-buffer (plist-get source :name))))
         (run (make-emacs-agent-run
               :id (plist-get saved :id) :session session :user-text (plist-get saved :user-text)
               :editor-context (plist-get saved :context)
               :source-buffer (when (and buffer (equal (buffer-local-value 'buffer-file-name buffer)
                                                       (plist-get source :file))) buffer)
               :model (plist-get saved :model) :stream (plist-get saved :stream)
               :context-policy (plist-get saved :context-policy)
               :tool-budget (plist-get saved :tool-budget)
               :context-config (plist-get saved :context-config)
               :instructions (plist-get saved :instructions)))
         (input (make-emacs-agent-input
                 :id (plist-get data :id) :kind (plist-get data :kind) :state 'withdrawn
                 :reason 'restart :run run :target-id (plist-get data :target-id)
                 :source source :backend-name (plist-get saved :backend-name))))
    (setf (emacs-agent-run-input run) input)
    input))

(defun emacs-agent-input--session (input)
  "Return INPUT's registered session, rejecting stale or retired handles."
  (when emacs-agent-session--mutation
    (user-error "Conversation mutation in progress"))
  (let ((session (emacs-agent-run-session (emacs-agent-input-run input))))
    (unless (and (emacs-agent-session-registered-p session)
                 (memq input (emacs-agent-session-inputs session)))
      (user-error "Stale pending input; reopen its session"))
    session))

(defun emacs-agent-input--check (input)
  "Reject INPUT overflow without modifying existing session inputs."
  (let* ((session (emacs-agent-run-session (emacs-agent-input-run input)))
         (inputs (cons input (delq input (copy-sequence (emacs-agent-session-inputs session)))))
         (print-length nil) (print-level nil) (print-circle nil) (print-escape-newlines t)
         (bytes (cl-loop for item in inputs sum
                         (string-bytes (encode-coding-string
                                        (prin1-to-string (plist-get (emacs-agent-input-data item) :run)) 'utf-8-unix)))))
    (when (or (> (length inputs) emacs-agent-pending-input-limit)
              (> bytes emacs-agent-pending-byte-limit))
      (user-error "Pending input limit exceeded (%d entries, %d bytes); reuse/forget existing input"
                  (length inputs) bytes))))

(defun emacs-agent-input-prepare (run kind &optional target)
  "Freeze RUN configuration once; create bounded KIND input targeting TARGET."
  (when (and emacs-agent-session--mutation (not (emacs-agent-run-input run)))
    (user-error "Conversation selection is being saved; submit again afterward"))
  (or (emacs-agent-run-input run)
      (let* ((source (emacs-agent-run-source-buffer run))
             (input (make-emacs-agent-input
                     :id (format "input-%d" (cl-incf emacs-agent-session--counter))
                     :kind kind :run run :target target
                     :target-id (and target (emacs-agent-run-id target))
                     :source (when (buffer-live-p source)
                               (list :name (buffer-name source)
                                     :file (buffer-local-value 'buffer-file-name source))))))
        (with-current-buffer (if (buffer-live-p source) source (current-buffer))
          (setf (emacs-agent-run-backend run) gptel-backend
                (emacs-agent-input-backend-name input) (gptel-backend-name gptel-backend)
                (emacs-agent-run-model run) gptel-model
                (emacs-agent-run-stream run) emacs-agent-stream
                (emacs-agent-run-context-policy run) emacs-agent-context-history
                (emacs-agent-run-tool-budget run) emacs-agent-max-tool-calls
                (emacs-agent-run-context-config run) (emacs-agent-compaction-config)))
        (emacs-agent-input--check input)
        (setf (emacs-agent-run-input run) input
              (emacs-agent-session-inputs (emacs-agent-run-session run))
              (nconc (emacs-agent-session-inputs (emacs-agent-run-session run)) (list input)))
        input)))

(defun emacs-agent-input-record (input)
  "Audit INPUT state without adding anything to canonical model history."
  (emacs-agent-session-record (emacs-agent-input-run input) 'input
                              (emacs-agent-input-data input)))

(defun emacs-agent-input-delivered (input)
  "Claim INPUT once before hooks or reentrant callbacks can run."
  (setf (emacs-agent-input-state input) 'delivered
        (emacs-agent-session-inputs (emacs-agent-run-session (emacs-agent-input-run input)))
        (delq input (emacs-agent-session-inputs
                     (emacs-agent-run-session (emacs-agent-input-run input))))))

(defun emacs-agent-input-for-run (run)
  "Return queued steering inputs owned by RUN, in submission order."
  (cl-remove-if-not
   (lambda (input) (and (eq (emacs-agent-input-state input) 'queued)
                        (eq (emacs-agent-input-kind input) 'steer)
                        (eq (emacs-agent-input-target input) run)))
   (emacs-agent-session-inputs (emacs-agent-run-session run))))

(defun emacs-agent-input-queue-steer (target text context source window)
  "Prepare TEXT with CONTEXT at SOURCE/WINDOW for TARGET, without changing it.
A completed target converts to FIFO; cancelled/failed targets retain recovery."
  (let* ((session (emacs-agent-run-session target))
         (_ (unless (emacs-agent-session-registered-p session)
              (user-error "Stale target session")))
         (run (emacs-agent-session-prepare session text context source window))
         (input (emacs-agent-input-prepare run 'steer target)))
    (setf (emacs-agent-input-state input) 'queued)
    (cond ((eq (emacs-agent-run-status target) 'completed)
           (emacs-agent-input-convert input))
          ((not (and (eq target (emacs-agent-session-active-run session))
                     (memq (emacs-agent-run-status target)
                           '(requesting streaming tool-running paused))))
           (setf (emacs-agent-input-state input) 'withdrawn
                 (emacs-agent-input-reason input) 'stopped)))
    (emacs-agent-input-record input)
    input))

(defun emacs-agent-input--convert-claim (inputs)
  "Claim queued steering INPUTS in order without publishing event hooks."
  (let ((eligible (cl-remove-if-not
                   (lambda (input) (and (eq (emacs-agent-input-state input) 'queued)
                                        (eq (emacs-agent-input-kind input) 'steer))) inputs)))
    (dolist (input eligible)
      (let* ((run (emacs-agent-input-run input)) (session (emacs-agent-run-session run)))
        (setf (emacs-agent-input-kind input) 'ask
              (emacs-agent-input-reason input) 'final-boundary
              (emacs-agent-session-pending-runs session)
              (nconc (emacs-agent-session-pending-runs session) (list run)))))
    eligible))

(defun emacs-agent-input--publish-converted (inputs)
  "Publish already claimed INPUTS, tolerating withdrawal by earlier hooks."
  (dolist (input inputs)
    (when (eq (emacs-agent-input-state input) 'queued)
      (emacs-agent-gptel-submit (emacs-agent-input-run input)))))

(defun emacs-agent-input-convert-batch (inputs)
  "Claim queued steering INPUTS in order before publishing event hooks."
  (emacs-agent-input--publish-converted (emacs-agent-input--convert-claim inputs)))

(defun emacs-agent-input-convert (input)
  "Convert queued steering INPUT to ordinary FIFO using its frozen run."
  (emacs-agent-input-convert-batch (list input)))

(defun emacs-agent-input-withdraw (input)
  "Remove INPUT from automatic delivery before opening any recursive editor."
  (emacs-agent-input--session input)
  (unless (memq (emacs-agent-input-state input) '(queued prepared withdrawn))
    (user-error "Input already delivered"))
  (let* ((run (emacs-agent-input-run input)) (session (emacs-agent-run-session run)))
    (setf (emacs-agent-session-pending-runs session)
          (delq run (emacs-agent-session-pending-runs session))
          (emacs-agent-input-state input) 'withdrawn
          (emacs-agent-input-reason input) 'withdrawn)
    (emacs-agent-input-record input))
  input)

(defun emacs-agent-input-forget (input)
  "Forget withdrawn INPUT from the pending view; its audit remains intact."
  (emacs-agent-input--session input)
  (unless (eq (emacs-agent-input-state input) 'withdrawn)
    (user-error "Withdraw input before forgetting it"))
  (emacs-agent-input-delivered input)
  (setf (emacs-agent-input-state input) 'forgotten)
  (emacs-agent-input-record input)
  input)

(defun emacs-agent-input-resubmit (input text)
  "Explicitly resubmit withdrawn INPUT with TEXT and its original snapshots.
Live steering stays steering; stopped/restarted inputs become new FIFO tasks.
The caller must explicitly rebind unavailable source/backend before recovery."
  (emacs-agent-input--session input)
  (unless (eq (emacs-agent-input-state input) 'withdrawn) (user-error "Withdraw input first"))
  (when (string-empty-p (string-trim text)) (user-error "Blank input"))
  (let* ((run (emacs-agent-input-run input)) (target (emacs-agent-input-target input))
         (session (emacs-agent-run-session run))
         (old-text (emacs-agent-run-user-text run)))
    (unless (and (buffer-live-p (emacs-agent-run-source-buffer run)) (emacs-agent-run-backend run))
      (user-error "Recovery needs a live source buffer and configured backend"))
    (setf (emacs-agent-run-user-text run) text)
    (condition-case err (emacs-agent-input--check input)
      (error (setf (emacs-agent-run-user-text run) old-text) (signal (car err) (cdr err))))
    ;; Move to the end.  Never resurrect a stopped target's steering.
    (setf (emacs-agent-session-inputs session)
          (nconc (delq input (emacs-agent-session-inputs session)) (list input))
          (emacs-agent-input-state input) 'queued
          (emacs-agent-input-reason input) nil)
    (if (and (eq (emacs-agent-input-kind input) 'steer) target
             (eq target (emacs-agent-session-active-run session))
             (memq (emacs-agent-run-status target) '(requesting streaming tool-running paused)))
        (emacs-agent-input-record input)
      (setf (emacs-agent-input-kind input) 'ask
            (emacs-agent-session-pending-runs session)
            (nconc (emacs-agent-session-pending-runs session) (list run)))
      (emacs-agent-gptel-submit run))
    input))

(provide 'emacs-agent-input)
;;; emacs-agent-input.el ends here
