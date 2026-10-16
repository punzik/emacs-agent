;;; emacs-agent-input-test.el --- Offline F2 lifecycle and production seam -*- lexical-binding: t; -*-
(require 'ert)
(require 'emacs-agent-gptel)

(defun emacs-agent-input-test--steer (run text)
  "Queue TEXT for RUN from this buffer."
  (emacs-agent-input-queue-steer run text (emacs-agent-context-capture nil) (current-buffer) nil))

(defun emacs-agent-input-test--stream-tools (run)
  "Parse actual pinned SSE containing two indexed calls and token usage."
  (with-temp-buffer
    (dotimes (i 2)
      (insert "data: "
              (json-serialize
               (list :choices
                     (vector (list :delta
                                   (list :tool_calls
                                         (vector (list :index i :id (format "stream-%d" i) :type "function"
                                                       :function (list :name "eval_elisp"
                                                                       :arguments (format "{\"expression\":\"(+ %d 1)\"}" i)))))))))
              "\n\n"))
    (insert "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":10}}\n\n"
            "data: [DONE]\n\n")
    (goto-char (point-min))
    (gptel-curl--parse-stream (emacs-agent-run-backend run)
                             (gptel-fsm-info (emacs-agent-run-request-handle run)))))

(ert-deftest emacs-agent-input-stream-batch-pause-usage-and-repeat-wait ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((emacs-agent-max-tool-calls 1)
             (run (emacs-agent-test--submit "start"))
             (fsm (emacs-agent-f2-spike--dry-fsm run))
             (input (emacs-agent-input-test--steer run "clarify"))
             (gptel-use-curl t) (http 0) wire)
        (cl-letf (((symbol-function 'gptel-curl-get-response)
                   (lambda (state) (cl-incf http)
                     (setq wire (copy-tree (plist-get (gptel-fsm-info state) :data) t)))))
          (gptel--fsm-transition fsm 'WAIT)
          (should (= http 1))
          (should (eq (emacs-agent-input-state input) 'queued))
          (emacs-agent-input-test--stream-tools run)
          (gptel--fsm-transition fsm 'TOOL)
          (should (eq (emacs-agent-run-status run) 'paused))
          (should (= http 1))
          (should (eq (emacs-agent-input-state input) 'queued))
          (emacs-agent-gptel-resume (emacs-agent-run-session run))
          (should (= http 2))
          (should (= (emacs-agent-run-tool-count run) 2))
          (should (eq (emacs-agent-input-state input) 'delivered))
          (should (string-prefix-p "clarify" (plist-get (aref (plist-get wire :messages)
                                                              (1- (length (plist-get wire :messages)))) :content)))
          (should (= (length (emacs-agent-run-usage-requests run)) 2))
          (should (= (plist-get (plist-get (car (emacs-agent-run-usage-requests run)) :tokens) :input) 20))
          (gptel--fsm-transition fsm 'WAIT)
          (should (= http 2))
          (should (= (length (emacs-agent-run-usage-requests run)) 2))
          (should (= (cl-count (emacs-agent-input-id input)
                              (emacs-agent-session-messages (emacs-agent-run-session run))
                              :key (lambda (m) (plist-get m :input-id)) :test #'equal) 1)))))))

(ert-deftest emacs-agent-input-final-conversion-preserves-config-and-fifo ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "first"))
             (session (emacs-agent-run-session run))
             (ordinary (emacs-agent-test--submit "ordinary"))
             (input (let ((gptel-model 'frozen-model) (emacs-agent-stream nil)
                          (emacs-agent-context-history 'full) (emacs-agent-max-tool-calls 7))
                      (emacs-agent-input-test--steer run "final clarification")))
             (prepared (emacs-agent-input-run input))
             (snapshot (copy-tree (emacs-agent-run-editor-context prepared))))
        (push prepared emacs-agent-test--runs)
        (cl-letf (((symbol-function 'emacs-agent-resources-capture)
                   (lambda (&rest _) (ert-fail "Final conversion must not reread instructions"))))
          (emacs-agent-test--complete run "final"))
        (should (eq (emacs-agent-session-active-run session) ordinary))
        (should (equal (emacs-agent-session-pending-runs session) (list prepared)))
        (should (eq (emacs-agent-input-kind input) 'ask))
        (gptel--fsm-transition (emacs-agent-run-request-handle run) 'DONE)
        (should (= (length (emacs-agent-session-pending-runs session)) 1))
        (emacs-agent-test--complete ordinary "ordinary final")
        (should (eq (emacs-agent-session-active-run session) prepared))
        (should (eq (emacs-agent-run-model prepared) 'frozen-model))
        (should-not (emacs-agent-run-stream prepared))
        (should (eq (emacs-agent-run-context-policy prepared) 'full))
        (should (= (emacs-agent-run-tool-budget prepared) 7))
        (should (equal snapshot (emacs-agent-run-editor-context prepared)))
        (should (eq (emacs-agent-input-state input) 'delivered))))))

(ert-deftest emacs-agent-input-cancel-error-retains-only-targeted-steering ()
  (dolist (status '(cancelled failed))
    (emacs-agent-test-adapter
      (with-temp-buffer
        (let* ((run (emacs-agent-test--submit "first"))
               (session (emacs-agent-run-session run))
               (ordinary (emacs-agent-test--submit "independent"))
               (input (emacs-agent-input-test--steer run "keep me")))
          (emacs-agent-gptel--finish run status)
          (should (eq (emacs-agent-session-active-run session) ordinary))
          (should (eq (emacs-agent-input-state input) 'withdrawn))
          (should-not (cl-find "keep me" (emacs-agent-session-messages session)
                               :key (lambda (m) (plist-get m :text)) :test #'equal))
          (emacs-agent-test--complete ordinary "done")
          (should-not (emacs-agent-session-active-run session))
          (push (emacs-agent-input-run input) emacs-agent-test--runs)
          (emacs-agent-input-resubmit input "recover me")
          (should (eq (emacs-agent-input-kind input) 'ask))
          (should (eq (emacs-agent-session-active-run session) (emacs-agent-input-run input))))))))

(ert-deftest emacs-agent-input-limits-utf8-rejection-and-forget ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "first"))
             (session (emacs-agent-run-session run))
             (emacs-agent-pending-input-limit 1)
             (input (emacs-agent-input-test--steer run "retained"))
             (messages (copy-tree (emacs-agent-session-messages session))))
        (should-error (emacs-agent-input-test--steer run "overflow") :type 'user-error)
        (should-error (emacs-agent-test--submit "ordinary overflow") :type 'user-error)
        (should-not (emacs-agent-session-pending-runs session))
        (should (equal (emacs-agent-session-inputs session) (list input)))
        (should (equal messages (emacs-agent-session-messages session)))
        (emacs-agent-input-withdraw input)
        (let* ((payload (plist-get (emacs-agent-input-data input) :run))
               (print-length nil) (print-level nil) (print-escape-newlines t)
               (emacs-agent-pending-byte-limit
                (string-bytes (encode-coding-string (prin1-to-string payload) 'utf-8-unix))))
          (should-error (emacs-agent-input-resubmit input "retainedЖ") :type 'user-error)
          (should (equal (emacs-agent-run-user-text (emacs-agent-input-run input)) "retained"))
          (should (eq (emacs-agent-input-state input) 'withdrawn)))
        (emacs-agent-input-forget input)
        (should-not (emacs-agent-session-inputs session))
        (should-error (emacs-agent-input-resubmit input "stale") :type 'user-error)
        (should (emacs-agent-input-test--steer run "now fits"))))))

(ert-deftest emacs-agent-input-withdraw-edit-order-and-context-retention ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "first"))
             (one (emacs-agent-input-test--steer run "one"))
             (two (emacs-agent-input-test--steer run "two"))
             (context (copy-tree (emacs-agent-run-editor-context (emacs-agent-input-run one)))))
        (emacs-agent-input-withdraw one)
        (insert "new editor state")
        (emacs-agent-input-resubmit one "edited one")
        (should (equal (emacs-agent-input-for-run run) (list two one)))
        (should (equal context (emacs-agent-run-editor-context (emacs-agent-input-run one))))
        (should (= (length (emacs-agent-session-messages (emacs-agent-run-session run))) 1))))))

(ert-deftest emacs-agent-input-requesting-hook-cancel-prevents-request ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let ((emacs-agent-session-event-functions
             (list (lambda (session event)
                     (when (eq (plist-get event :type) 'requesting)
                       (emacs-agent-gptel-cancel session))))))
        (let ((run (emacs-agent-test--submit "cancel in hook")))
          (should (eq (emacs-agent-run-status run) 'cancelled))
          (should-not emacs-agent-test--requests))))))

(ert-deftest emacs-agent-input-delivery-failure-rolls-back-and-retains-recovery ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "first"))
             (fsm (emacs-agent-f2-spike--dry-fsm run))
             (input (emacs-agent-input-test--steer run "not launched"))
             (info (gptel-fsm-info fsm)))
        (plist-put info :tool-use '((:id "done" :result "=> 1")))
        (puthash "done" "=> 1" (emacs-agent-run-tool-call-ids run))
        (plist-put info :data '(:messages [(:role "tool" :tool_call_id "done" :content "=> 1")]))
        (setf (gptel-fsm-state fsm) 'TRET)
        (let ((gptel-use-curl t))
          (cl-letf (((symbol-function 'gptel-curl-get-response)
                     (lambda (_) (error "Launch failed"))))
            (gptel--fsm-transition fsm 'WAIT)))
        (should (eq (emacs-agent-run-status run) 'failed))
        (should (eq (emacs-agent-input-state input) 'withdrawn))
        (should (= (length (emacs-agent-session-messages (emacs-agent-run-session run))) 1))
        ;; Late continuation is inert.
        (let ((count 0) (gptel-use-curl t))
          (cl-letf (((symbol-function 'gptel-curl-get-response) (lambda (_) (cl-incf count))))
            (gptel--fsm-transition fsm 'WAIT))
          (should (= count 0)))))))

(ert-deftest emacs-agent-input-final-conversion-claims-whole-fifo-before-hooks ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "first"))
             (session (emacs-agent-run-session run))
             (ordinary (emacs-agent-test--submit "older ask"))
             (one (emacs-agent-input-test--steer run "one"))
             (two (emacs-agent-input-test--steer run "two"))
             late
             (emacs-agent-session-event-functions
              (list (lambda (_session event)
                      (when (and (not late) (eq (plist-get event :type) 'queued)
                                 (equal (plist-get event :run-id)
                                        (emacs-agent-run-id (emacs-agent-input-run one))))
                        (setq late (emacs-agent-input-test--steer run "late")))))))
        (emacs-agent-test--complete run "final")
        (should (eq (emacs-agent-session-active-run session) ordinary))
        (should (equal (emacs-agent-session-pending-runs session)
                       (mapcar #'emacs-agent-input-run (list one two late))))))))

(ert-deftest emacs-agent-input-pending-view-refresh-does-not-steal-window ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "first"))
             (session (emacs-agent-run-session run))
             (input (emacs-agent-input-test--steer run "pending"))
             (emacs-agent-session--owner session)
             (selected (selected-window))
             (buffer (emacs-agent-pending))
             (emacs-agent-session-event-functions '(emacs-agent-pending--refresh-event)))
        (unwind-protect
            (progn
              (with-current-buffer buffer (should (= (length tabulated-list-entries) 1)))
              (emacs-agent-input-withdraw input)
              (with-current-buffer buffer
                (should (equal (aref (cadar tabulated-list-entries) 0) "withdrawn")))
              (emacs-agent-input-forget input)
              (with-current-buffer buffer (should-not tabulated-list-entries))
              (should (eq selected (selected-window)))
              (should (eq run (emacs-agent-session-active-run session))))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest emacs-agent-input-reentrant-assistant-end-cannot-orphan-fifo ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((one (emacs-agent-test--submit "one"))
             (session (emacs-agent-run-session one))
             (two (emacs-agent-test--submit "two"))
             (emacs-agent-session-event-functions
              (list (lambda (s event)
                      (when (eq (plist-get event :type) 'assistant-end)
                        (emacs-agent-gptel-cancel s))))))
        (emacs-agent-gptel--callback one "partial" nil)
        (emacs-agent-gptel--finish one 'completed)
        (should (eq (emacs-agent-run-status one) 'completed))
        (should (eq (emacs-agent-session-active-run session) two))
        (should (eq (emacs-agent-run-status two) 'requesting))
        (emacs-agent-test--complete two "done")
        (should-not (emacs-agent-session-active-run session))))))

(ert-deftest emacs-agent-input-tool-call-cancellation-prevents-new-effect ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (insert "before")
      (let* ((run (emacs-agent-test--submit "cancel tool"))
             (emacs-agent-session-event-functions
              (list (lambda (s event)
                      (when (eq (plist-get event :type) 'tool-call)
                        (emacs-agent-gptel-cancel s)))))
             continued)
        (emacs-agent-gptel--execute
         run (list "cancelled-call"
                   (with-current-buffer (emacs-agent-run-transport-buffer run) (car gptel-tools))
                   '(:expression "(insert \"AFTER-CANCEL\")")
                   (lambda (&rest _) (setq continued t))))
        (should (eq (emacs-agent-run-status run) 'cancelled))
        (should (equal (buffer-string) "before"))
        (should (= (emacs-agent-run-tool-count run) 0))
        (should-not continued)))))

(ert-deftest emacs-agent-input-post-launch-hook-error-preserves-delivered-history ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "first"))
             (fsm (emacs-agent-f2-spike--dry-fsm run))
             (input (emacs-agent-input-test--steer run "already launched"))
             (info (gptel-fsm-info fsm))
             (gptel-post-request-hook (list (lambda () (error "Post-launch hook failed"))))
             (gptel-use-curl t) (http 0))
        (plist-put info :tool-use '((:id "done" :result "=> 1")))
        (puthash "done" "=> 1" (emacs-agent-run-tool-call-ids run))
        (plist-put info :data '(:messages [(:role "tool" :tool_call_id "done" :content "=> 1")]))
        (setf (gptel-fsm-state fsm) 'TRET)
        (cl-letf (((symbol-function 'gptel-curl-get-response) (lambda (_) (cl-incf http))))
          (gptel--fsm-transition fsm 'WAIT))
        (should (= http 1))
        (should (eq (emacs-agent-run-status run) 'failed))
        (should (eq (emacs-agent-input-state input) 'delivered))
        (should-not (emacs-agent-session-inputs (emacs-agent-run-session run)))
        (should (= (length (emacs-agent-session-messages (emacs-agent-run-session run))) 2))
        (should (cl-find 'steering (emacs-agent-session-events (emacs-agent-run-session run))
                         :key (lambda (event) (plist-get event :type))))))))

;;; emacs-agent-input-test.el ends here
