;;; emacs-agent-compact.el --- Manual and pre-request compaction -*- lexical-binding: t; -*-
;;; Commentary:
;; Pigo-style budget gate and one summary transaction.  Original records remain
;; intact.  A summary request owns a session lock, never a tool registry.
;;; Code:
(require 'gptel)
(require 'gptel-openai)
(require 'seq)
(require 'emacs-agent-compaction)
(require 'emacs-agent-store)
(require 'emacs-agent-usage)

(declare-function emacs-agent-gptel--history "emacs-agent-gptel" (run &optional policy))
(declare-function emacs-agent-gptel--live-p "emacs-agent-gptel" (run))
(declare-function emacs-agent-gptel--finish "emacs-agent-gptel" (run status &optional detail))
(declare-function emacs-agent-gptel--start-next "emacs-agent-gptel" (session))
(declare-function emacs-agent-gptel--wait-ready "emacs-agent-gptel" (run handlers fsm))
(declare-function emacs-agent-gptel--restore-protocol "emacs-agent-gptel" (run fsm))
(declare-function emacs-agent-gptel--steering-record "emacs-agent-gptel" (run input))

(cl-defstruct emacs-agent-compact-job
  run owner config plan buffer fsm resume (state 'requesting) chunks)

(defun emacs-agent-compact--config (run)
  "Return RUN's frozen limits; legacy runs use explicit package defaults."
  (emacs-agent-compaction-config
   (or (emacs-agent-run-context-config run)
       '(:window 262144 :reserve 16384 :keep 20000 :automatic t))))

(defun emacs-agent-compact-invalidate (run)
  "Invalidate a prior provider anchor when RUN changes model or backend."
  (let* ((session (emacs-agent-run-session run))
         (anchor (emacs-agent-session-usage-anchor session)))
    (unless (and (gptel-backend-p (emacs-agent-run-backend run))
                 (equal (plist-get anchor :model) (format "%s" (emacs-agent-run-model run)))
                 (equal (plist-get anchor :backend) (gptel-backend-name (emacs-agent-run-backend run))))
      (setf (emacs-agent-session-usage-anchor session) nil))))

(defun emacs-agent-compact--anchor (run)
  "Return the valid normalized usage anchor for RUN, if any."
  (let* ((session (emacs-agent-run-session run))
         (anchor (emacs-agent-session-usage-anchor session)))
    (when (and (equal (plist-get anchor :model) (format "%s" (emacs-agent-run-model run)))
               (equal (plist-get anchor :backend) (gptel-backend-name (emacs-agent-run-backend run)))
               (eql (plist-get anchor :cut) (or (plist-get (emacs-agent-session-compaction session) :cut) 0)))
      anchor)))

(defun emacs-agent-compact--wire (run &optional end)
  "Serialize RUN's projection without HTTP; END bounds the original prefix."
  (when end
    (let ((session (copy-emacs-agent-session (emacs-agent-run-session run))))
      (setq run (copy-emacs-agent-run run))
      (setf (emacs-agent-session-messages session)
            (cl-subseq (emacs-agent-session-messages session) 0 end)
            (emacs-agent-run-session run) session)))
  (let ((data
         (with-temp-buffer
           (setq-local gptel-track-response t gptel-mode nil
                       gptel-backend (emacs-agent-run-backend run)
                       gptel-model (emacs-agent-run-model run))
           (gptel--parse-list-and-insert (emacs-agent-gptel--history run))
           (goto-char (point-max))
           (list :model (format "%s" (emacs-agent-run-model run))
                 :messages (vconcat (gptel--parse-buffer (emacs-agent-run-backend run) nil)))))
        (fsm (gptel-make-fsm)))
    (setf (gptel-fsm-info fsm) (list :data data))
    (emacs-agent-gptel--restore-protocol run fsm)
    data))

(defun emacs-agent-compact--pending-data (run fsm)
  "Preview undelivered steering for RUN/FSM without claiming any input."
  (let* ((data (copy-tree (plist-get (gptel-fsm-info fsm) :data) t))
         (inputs (and (eq (car (plist-get (gptel-fsm-info fsm) :history)) 'TRET)
                      (emacs-agent-input-for-run run))))
    (when inputs
      (let* ((preview (copy-emacs-agent-run run))
             (session (copy-emacs-agent-session (emacs-agent-run-session run))))
        (setf (emacs-agent-run-session preview) session
              (emacs-agent-session-messages session)
              (append (emacs-agent-session-messages session)
                      (mapcar (apply-partially #'emacs-agent-gptel--steering-record run) inputs)))
        (dolist (prompt (last (emacs-agent-gptel--history preview) (length inputs)))
          (gptel--inject-prompt (emacs-agent-run-backend run) data
                               (list :role "user" :content (cadr prompt))))))
    data))

(defun emacs-agent-compact-check (run data)
  "Reject RUN's over-budget DATA explicitly, without dropping any records."
  (let* ((config (emacs-agent-compact--config run))
         (tokens (emacs-agent-compaction-estimate data (emacs-agent-compact--anchor run)))
         (usable (- (plist-get config :window) (plist-get config :reserve))))
    (when (> tokens usable)
      (error "Estimated context %d exceeds usable budget %d; compact or increase the configured budget"
             tokens usable))
    tokens))

(defun emacs-agent-compact-observe (run fsm)
  "Anchor RUN's future estimates to this HTTP response's normalized usage."
  (when (emacs-agent-gptel--live-p run)
    (let* ((info (gptel-fsm-info fsm))
           (tokens (emacs-agent-usage--tokens (plist-get info :tokens)))
           (counts (emacs-agent-usage--derived tokens))
           (input (plist-get counts :input-total))
           (total (plist-get counts :total))
           (data (plist-get info :data))
           (session (emacs-agent-run-session run)))
      (when (and (natnump input) (> input 0) (natnump total)
                 (vectorp (plist-get data :messages))
                 (memq (gptel-fsm-state fsm) '(DONE TOOL)))
        (setq data (copy-tree data t))
        ;; gptel appends assistant calls to :data, but not a plain final answer.
        (when (and (eq (gptel-fsm-state fsm) 'DONE)
                   (eq (plist-get (car (last (emacs-agent-session-messages session))) :role) 'assistant))
          (plist-put data :messages
                     (vconcat (plist-get data :messages)
                              (vector (list :role "assistant" :content
                                            (plist-get (car (last (emacs-agent-session-messages session))) :text))))))
        (let ((anchor (list :source 'gptel-normalized :tokens total
                            :estimate (emacs-agent-compaction-estimate data)
                            :model (format "%s" (emacs-agent-run-model run))
                            :backend (gptel-backend-name (emacs-agent-run-backend run))
                            :cut (or (plist-get (emacs-agent-session-compaction session) :cut) 0))))
          (setf (emacs-agent-session-usage-anchor session) anchor)
          (emacs-agent-session-record run 'context-usage anchor))))))

(defun emacs-agent-compact-before-request (run handlers fsm)
  "Start at most one summary before RUN's WAIT HANDLERS/FSM launch HTTP."
  (emacs-agent-gptel--restore-protocol run fsm)
  (let* ((config (emacs-agent-compact--config run))
         (data (emacs-agent-compact--pending-data run fsm))
         (tokens (emacs-agent-compaction-estimate data (emacs-agent-compact--anchor run))))
    (when (> tokens (- (plist-get config :window) (plist-get config :reserve)))
      (unless (plist-get config :automatic)
        (emacs-agent-compact-check run data))
      (unless emacs-agent-auto-save
        (error "Automatic compaction requires autosave; compact manually or enable autosave"))
      (emacs-agent-compact-start
       run (plist-get config :keep) nil run
       (apply-partially #'emacs-agent-compact--resume run handlers fsm) tokens)
      t)))

(defun emacs-agent-compact--resume (run handlers fsm)
  "Rebuild RUN/FSM after one summary, recheck and resume WAIT HANDLERS."
  (when (emacs-agent-gptel--live-p run)
    (condition-case err
        (let* ((info (gptel-fsm-info fsm)) (data (plist-get info :data))
               (system (seq-take-while (lambda (m) (member (plist-get m :role) '("system" "developer")))
                                       (append (plist-get data :messages) nil))))
          (plist-put data :messages
                     (vconcat system (plist-get (emacs-agent-compact--wire run) :messages)))
          ;; Completed paired tool bundles may now be inside the summary.  The
          ;; pending specs/results still prove that this whole batch completed.
          (plist-put info :agent-compacted t)
          (emacs-agent-compact-check run (emacs-agent-compact--pending-data run fsm))
          (emacs-agent-gptel--wait-ready run handlers fsm))
      ((error quit)
       (emacs-agent-gptel--finish run (if (eq (car err) 'quit) 'cancelled 'failed)
                                 (error-message-string err))))))

(defun emacs-agent-compact--live-p (job)
  "Whether JOB still owns its session's cancellable summary request."
  (let ((session (emacs-agent-run-session (emacs-agent-compact-job-run job))))
    (and (eq (gethash (emacs-agent-session-key session) emacs-agent-session--registry) session)
         (eq (emacs-agent-session-compaction-job session) job)
         (eq (emacs-agent-compact-job-state job) 'requesting))))

(defun emacs-agent-compact--finish (job status &optional detail)
  "Claim JOB's terminal STATUS before events, abort or queue callbacks."
  (when (memq (emacs-agent-compact-job-state job) '(requesting committing))
    (setf (emacs-agent-compact-job-state job) status)
    (let* ((run (emacs-agent-compact-job-run job))
           (session (emacs-agent-run-session run))
           (owner (emacs-agent-compact-job-owner job)))
      (setf (emacs-agent-run-status run) status)
      (emacs-agent-usage-end (or owner run) status
                             (gptel-fsm-info (emacs-agent-compact-job-fsm job)))
      (unless (eq status 'completed)
        (condition-case nil (gptel-abort (emacs-agent-compact-job-buffer job)) ((error quit) nil)))
      (when (eq (emacs-agent-session-compaction-job session) job)
        (setf (emacs-agent-session-compaction-job session) nil))
      (emacs-agent-session-record run (if (eq status 'completed) 'compacted 'compaction-stopped)
                                  (or detail (symbol-name status)))
      (when (buffer-live-p (emacs-agent-compact-job-buffer job))
        (kill-buffer (emacs-agent-compact-job-buffer job)))
      (cond ((and owner (emacs-agent-gptel--live-p owner))
             (if (eq status 'completed) (funcall (emacs-agent-compact-job-resume job))
               (emacs-agent-gptel--finish owner status (or detail "Automatic compaction stopped"))))
            (t (emacs-agent-gptel--start-next session))))))

(defun emacs-agent-compact--commit (job info)
  "Persist JOB's complete, nonblank summary before publishing its projection."
  (when (emacs-agent-compact--live-p job)
    (condition-case err
        (let* ((summary (apply #'concat (nreverse (emacs-agent-compact-job-chunks job))))
               (run (emacs-agent-compact-job-run job))
               (session (emacs-agent-run-session run))
               (record (list :cut (plist-get (emacs-agent-compact-job-plan job) :cut)
                             :summary summary
                             :tokens-before (plist-get (emacs-agent-compact-job-plan job) :tokens-before)
                             :model (format "%s" (emacs-agent-run-model run))
                             :backend (gptel-backend-name (emacs-agent-run-backend run)) :time (float-time)))
               (preview (copy-emacs-agent-session session)))
          (unless (equal (plist-get info :stop-reason) "stop")
            (error "Summary did not complete: %s" (plist-get info :stop-reason)))
          (when (string-empty-p (string-trim summary)) (error "Provider returned an empty summary"))
          ;; Cancellation is accepted while generating, not after commit claim.
          (setf (emacs-agent-compact-job-state job) 'committing
                (emacs-agent-session-compaction preview) record
                (emacs-agent-session-updated-at preview) (plist-get record :time)
                (emacs-agent-session-usage-anchor preview) nil
                (emacs-agent-session-compaction-job preview) nil)
          (unwind-protect (emacs-agent-store-save preview)
            (remhash preview emacs-agent-store--last-save))
          (setf (emacs-agent-session-compaction session) record
                (emacs-agent-session-usage-anchor session) nil)
          (emacs-agent-compact--finish job 'completed record))
      ((error quit)
       (emacs-agent-compact--finish job (if (eq (car err) 'quit) 'cancelled 'failed)
                                  (error-message-string err))))))

(defun emacs-agent-compact--callback (job response info)
  "Collect only public summary text for JOB; never execute provider tools."
  (when (emacs-agent-compact--live-p job)
    (emacs-agent-usage-observe (or (emacs-agent-compact-job-owner job)
                                  (emacs-agent-compact-job-run job)) info)
    (pcase response
      ((pred stringp) (push response (emacs-agent-compact-job-chunks job)))
      ('abort (emacs-agent-compact--finish job 'cancelled "Compaction cancelled"))
      ('nil (emacs-agent-compact--finish job 'failed (format "%s" (or (plist-get info :error) "Summary request failed"))))
      ('t nil)
      (`(reasoning . ,_) nil)
      (_ (emacs-agent-compact--finish job 'failed "Summary requested tools or unsupported output")))))

(defun emacs-agent-compact--terminal (job fsm)
  "Handle JOB's provider terminal FSM, accepting only completed summaries."
  (when (emacs-agent-compact--live-p job)
    (pcase (gptel-fsm-state fsm)
      ('DONE (emacs-agent-compact--commit job (gptel-fsm-info fsm)))
      ('ABRT (emacs-agent-compact--finish job 'cancelled "Compaction aborted"))
      ('ERRS (emacs-agent-compact--finish job 'failed "Compaction provider error")))))

(defun emacs-agent-compact--wait (job handlers fsm)
  "Launch JOB's bounded summary request with no tools, even from custom params."
  (when (emacs-agent-compact--live-p job)
    (condition-case err
        (let* ((info (gptel-fsm-info fsm))
               (window (plist-get (emacs-agent-compact-job-config job) :window))
               (data (cl-loop for (key value) on (plist-get info :data) by #'cddr
                              unless (memq key '(:tools :tool_choice :parallel_tool_calls))
                              append (list key value))))
          (when (> (emacs-agent-compaction-estimate data) (- window (min 1024 (/ window 8))))
            (error "Summary input exceeds configured context budget"))
          (plist-put info :data data)
          (plist-put info :tools nil)
          (let ((accounting (or (emacs-agent-compact-job-owner job)
                                (emacs-agent-compact-job-run job))))
            (emacs-agent-usage-begin accounting)
            (plist-put (emacs-agent-run-usage-current accounting) :purpose 'compaction))
          (dolist (handler handlers)
            (when (emacs-agent-compact--live-p job) (funcall handler fsm))))
      ((error quit) (emacs-agent-compact--finish job (if (eq (car err) 'quit) 'cancelled 'failed)
                                               (error-message-string err))))))

(defun emacs-agent-compact-start (source-run keep instructions &optional owner resume tokens-before)
  "Summarize SOURCE-RUN's session, retaining KEEP tokens, without any tool use.
OWNER and RESUME describe an automatic pre-generation pause; nil means manual.
INSTRUCTIONS is optional additional summary focus, not a system replacement."
  (let* ((session (emacs-agent-run-session source-run))
         (config (emacs-agent-compact--config source-run))
         (plan (emacs-agent-compaction-plan (emacs-agent-session-messages session)
                                            (emacs-agent-session-compaction session) keep))
         (run (make-emacs-agent-run :id (format "run-%d" (cl-incf emacs-agent-session--counter))
                                   :session session :user-text "Context compaction" :status 'requesting
                                   :source-buffer (emacs-agent-run-source-buffer source-run)
                                   :backend (emacs-agent-run-backend source-run) :model (emacs-agent-run-model source-run)
                                   :context-config config :tool-budget 0))
         (buffer (generate-new-buffer " *emacs-agent-summary*"))
         (fsm (gptel-make-fsm))
         (job (make-emacs-agent-compact-job :run run :owner owner :config config
                                           :plan plan :buffer buffer :fsm fsm :resume resume)))
    (when (or (emacs-agent-session-compaction-job session)
              (and (not owner)
                   (or (emacs-agent-session-active-run session)
                       (emacs-agent-session-pending-runs session))))
      (kill-buffer buffer)
      (user-error "Compaction requires an idle session"))
    (unless (and (equal gptel-version "0.9.9.5")
                 (eq (type-of (emacs-agent-run-backend run)) 'gptel-openai))
      (kill-buffer buffer)
      (user-error "Compaction requires the supported gptel Chat Completions backend"))
    (when (or (< keep 0) (>= keep (- (plist-get config :window) (plist-get config :reserve))))
      (kill-buffer buffer)
      (user-error "Invalid compaction retention target"))
    (condition-case err
        (plist-put plan :tokens-before (or tokens-before
                                         (emacs-agent-compaction-estimate (emacs-agent-compact--wire source-run))))
      ((error quit) (kill-buffer buffer) (signal (car err) (cdr err))))
    (setf (emacs-agent-session-compaction-job session) job)
    (setf (gptel-fsm-handlers fsm) (copy-tree (gptel-fsm-handlers fsm)))
    (setf (alist-get 'WAIT (gptel-fsm-handlers fsm))
          (list (apply-partially #'emacs-agent-compact--wait job (alist-get 'WAIT (gptel-fsm-handlers fsm)))))
    (setf (alist-get 'TOOL (gptel-fsm-handlers fsm))
          (list (lambda (_) (emacs-agent-compact--finish job 'failed "Summary must not call tools"))))
    (dolist (state '(DONE ERRS ABRT))
      (setf (alist-get state (gptel-fsm-handlers fsm))
            (append (alist-get state (gptel-fsm-handlers fsm))
                    (list (apply-partially #'emacs-agent-compact--terminal job)))))
    (condition-case err
        (progn
          (emacs-agent-session-record run 'compacting (list :keep keep :tokens-before (plist-get plan :tokens-before)))
          (when (emacs-agent-compact--live-p job)
            (with-current-buffer buffer
              (setq-local gptel-backend (emacs-agent-run-backend run) gptel-model (emacs-agent-run-model run)
                          gptel-use-tools nil gptel-tools nil gptel-use-context nil
                          gptel-track-response t gptel--num-messages-to-send nil)
              (gptel-request
                  (emacs-agent-compaction-transcript
                   (plist-get (emacs-agent-compact--wire source-run (plist-get plan :cut)) :messages)
                   (plist-get config :window))
                :buffer buffer :stream nil :fsm fsm :transforms '(ignore)
                :system (concat emacs-agent-compaction-system-prompt
                                (when (and instructions (not (string-empty-p (string-trim instructions))))
                                  (concat "\nFocus additionally on: " (emacs-agent-compaction-clip instructions 4096))))
                :callback (apply-partially #'emacs-agent-compact--callback job)))))
      ((error quit) (emacs-agent-compact--finish job (if (eq (car err) 'quit) 'cancelled 'failed)
                                               (error-message-string err))))
    job))

(defun emacs-agent-compact-cancel (session)
  "Cancel SESSION's in-flight summary; return non-nil if one was cancelled."
  (when-let* ((job (emacs-agent-session-compaction-job session)))
    (when (emacs-agent-compact--live-p job)
      (emacs-agent-compact--finish job 'cancelled "Compaction cancelled; previous projection retained")
      t)))

(defun emacs-agent-compact-abort-owned (run)
  "Stop an automatic summary if its original RUN terminalizes."
  (let ((job (emacs-agent-session-compaction-job (emacs-agent-run-session run))))
    (when (and job (eq (emacs-agent-compact-job-owner job) run))
      (emacs-agent-compact-cancel (emacs-agent-run-session run)))))

(provide 'emacs-agent-compact)
;;; emacs-agent-compact.el ends here
