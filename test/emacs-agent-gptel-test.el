;;; emacs-agent-gptel-test.el --- Offline adapter lifecycle tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'emacs-agent)
(require 'emacs-agent-gptel)

(defvar emacs-agent-test--runs nil)
(defvar emacs-agent-test--requests nil)
(defvar emacs-agent-test--real-request nil)

(defmacro emacs-agent-test-adapter (&rest body)
  "Run BODY with mocked HTTP entry point and real gptel tool objects."
  (declare (indent 0) (debug t))
  `(let ((emacs-agent-session--registry (make-hash-table :test #'equal))
         (emacs-agent-session--counter 0)
         (emacs-agent-data-directory (make-temp-file "agent-adapter-test-" t))
         (emacs-agent-auto-save nil)
         (emacs-agent-session-event-functions nil)
         (emacs-agent-gptel--executing-tool nil)
         (emacs-agent-max-tool-calls 100)
         (emacs-agent-stream t)
         (emacs-agent-context-history 'current)
         (gptel-backend (gptel-make-openai "agent-offline" :host "offline.invalid" :key "unused"))
         (gptel-model 'gpt-4o)
         (emacs-agent-test--runs nil)
         (emacs-agent-test--requests nil)
         (emacs-agent-test--real-request (symbol-function 'gptel-request)))
     (unwind-protect
         (cl-letf (((symbol-function 'gptel-request)
                    (lambda (prompt &rest keys)
                      (push (list :prompt prompt :callback (plist-get keys :callback)
                                  :buffer (plist-get keys :buffer)
                                  :stream (plist-get keys :stream)
                                  :system (plist-get keys :system)
                                  :transforms (plist-get keys :transforms)) emacs-agent-test--requests)
                      'mock-request))
                   ((symbol-function 'gptel-abort) #'ignore))
           ,@body)
       (dolist (run emacs-agent-test--runs)
         (when (buffer-live-p (emacs-agent-run-transport-buffer run))
           (kill-buffer (emacs-agent-run-transport-buffer run))))
       (maphash (lambda (_key session)
                  (when (buffer-live-p (emacs-agent-session-log-buffer session))
                    (kill-buffer (emacs-agent-session-log-buffer session))))
                emacs-agent-session--registry)
       (delete-directory emacs-agent-data-directory t))))

(defun emacs-agent-test--submit (text &optional root)
  "Create and submit TEXT from the current buffer for ROOT."
  (let ((run (emacs-agent-session-enqueue
              (emacs-agent-session-get root) text (emacs-agent-context-capture root)
              (current-buffer) nil)))
    (push run emacs-agent-test--runs)
    (emacs-agent-gptel-submit run)))

(defun emacs-agent-test--calls (run specs)
  "Deliver provider-ordered SPECS of (ID EXPRESSION) to RUN.
Mock only the gptel dispatch callback tuples, including their reversed order."
  (let ((tool (with-current-buffer (emacs-agent-run-transport-buffer run) (car gptel-tools)))
        calls uses results)
    (dolist (spec specs)
      (let ((id (car spec)) (args (list :expression (cadr spec))))
        (push (list tool args (lambda (result) (push (cons id result) results))) calls)
        (push (list :id id :args args) uses)))
    (let ((response (cons 'tool-call calls))
          (info (list :tool-use (reverse uses))))
      (emacs-agent-gptel--callback run response info)
      (list response info results))))

(defun emacs-agent-test--complete (run text)
  "Deliver final TEXT and then the real gptel terminal transition to RUN."
  (emacs-agent-gptel--callback run text nil)
  (gptel--fsm-transition (emacs-agent-run-request-handle run) 'DONE))

(ert-deftest emacs-agent-adapter-fifo-and-independent-sessions ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((first (emacs-agent-test--submit "first"))
             (session (emacs-agent-run-session first))
             (second (emacs-agent-test--submit "second"))
             (other (emacs-agent-test--submit "other" "/tmp/project/")))
        (should (= (length emacs-agent-test--requests) 2))
        (should (eq (emacs-agent-session-active-run session) first))
        (should (eq (emacs-agent-run-status second) 'queued))
        (emacs-agent-test--complete first "first answer")
        (should (eq (emacs-agent-run-status first) 'completed))
        (should (eq (emacs-agent-session-active-run session) second))
        (should (= (length emacs-agent-test--requests) 3))
        (let ((history (plist-get (car emacs-agent-test--requests) :prompt)))
          (should (equal (caar history) 'prompt))
          (should (equal (cadar history) "first")) ; old context dropped
          (should (equal (nth 1 history) '(response "first answer")))
          (should (string-match-p "emacs-context" (cadr (nth 2 history)))))
        (should (eq (emacs-agent-run-status other) 'requesting))
        (should-not (emacs-agent-session-pending-runs session))))))

(ert-deftest emacs-agent-adapter-tools-errors-duplicates-and-late-callbacks ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "tools"))
             (packet (emacs-agent-test--calls run
                                            '(("one" "(insert \"1\") nil")
                                              ("two" "(insert \"2\") (error \"expected\")")))))
        (should (equal (buffer-string) "12"))
        (should (= (emacs-agent-run-tool-count run) 2))
        (should (equal (gethash "one" (emacs-agent-run-tool-call-ids run)) "\n=> nil"))
        (should (string-match-p "ERROR" (gethash "two" (emacs-agent-run-tool-call-ids run))))
        (emacs-agent-gptel--callback run (car packet) (cadr packet))
        (should (equal (buffer-string) "12"))
        (should (= (emacs-agent-run-tool-count run) 2))
        (emacs-agent-test--complete run "Recovered")
        (let ((events (copy-tree (emacs-agent-session-events (emacs-agent-run-session run)))))
          (emacs-agent-gptel--callback run (car packet) (cadr packet))
          (emacs-agent-gptel--callback run "late" nil)
          (should (equal events (emacs-agent-session-events (emacs-agent-run-session run)))))))))

(ert-deftest emacs-agent-adapter-pause-resume-and-queued-turn ()
  (emacs-agent-test-adapter
    (let ((emacs-agent-max-tool-calls 1))
      (with-temp-buffer
        (let* ((run (emacs-agent-test--submit "tools"))
               (session (emacs-agent-run-session run))
               (next (emacs-agent-test--submit "next"))
               (packet (emacs-agent-test--calls run '(("one" "(insert \"1\")")
                                                     ("two" "(insert \"2\")")))))
          (should (equal (buffer-string) "1"))
          (should (eq (emacs-agent-run-status run) 'paused))
          (should (eq (emacs-agent-run-status next) 'queued))
          (emacs-agent-gptel--callback run (car packet) (cadr packet))
          (should (= (length (emacs-agent-run-pending-tools run)) 1))
          (emacs-agent-gptel-resume session)
          (should (equal (buffer-string) "12"))
          (should (= (emacs-agent-run-tool-count run) 2))
          (should (= (length emacs-agent-test--requests) 1))
          (emacs-agent-test--complete run "done")
          (should (eq (emacs-agent-session-active-run session) next))
          (should-error (emacs-agent-gptel-resume session) :type 'user-error))))))

(ert-deftest emacs-agent-adapter-cancel-paused-and-ignore-late ()
  (emacs-agent-test-adapter
    (let ((emacs-agent-max-tool-calls 0))
      (with-temp-buffer
        (let* ((run (emacs-agent-test--submit "pause"))
               (session (emacs-agent-run-session run))
               (next (emacs-agent-test--submit "next"))
               (packet (emacs-agent-test--calls run '(("one" "(insert \"BAD\")")))))
          (should (eq (emacs-agent-run-status run) 'paused))
          (emacs-agent-gptel-cancel session)
          (should (eq (emacs-agent-run-status run) 'cancelled))
          (should (eq (emacs-agent-session-active-run session) next))
          (emacs-agent-gptel--callback run (car packet) (cadr packet))
          (emacs-agent-gptel--callback run 'abort nil)
          (should (equal (buffer-string) ""))
          (should (eq (emacs-agent-run-status next) 'requesting)))))))

(ert-deftest emacs-agent-adapter-self-cancellation-retains-result-before-next-turn ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "cancel self"))
             (session (emacs-agent-run-session run))
             (next (emacs-agent-test--submit "next")))
        (emacs-agent-test--calls
         run '(("one" "(insert \"effect\") (emacs-agent-gptel-cancel (emacs-agent-session-get nil)) 42")
               ("two" "(insert \"BAD\")")))
        (should (equal (buffer-string) "effect"))
        (should (eq (emacs-agent-run-status run) 'cancelled))
        (should (eq (emacs-agent-session-active-run session) next))
        (should (= (emacs-agent-run-tool-count run) 1))
        (should (equal (mapcar (lambda (msg) (plist-get msg :role))
                              (emacs-agent-session-messages session)) '(user tool user)))
        (should (string-match-p "42" (gethash "one" (emacs-agent-run-tool-call-ids run))))))))

(ert-deftest emacs-agent-adapter-dead-source-fallback-and-dead-window ()
  (emacs-agent-test-adapter
    (let ((source (generate-new-buffer " *agent-dead-source*")))
      (unwind-protect
          (let ((run (with-current-buffer source (emacs-agent-test--submit "fallback"))))
            (kill-buffer source)
            ;; A stale or absent source-window is never selected for tool execution.
            (setf (emacs-agent-run-source-window run) nil)
            (emacs-agent-test--calls run '(("one" "(insert \"fallback\") (buffer-string)")))
            (should (equal (with-current-buffer (emacs-agent-run-transport-buffer run)
                             (buffer-string)) "fallback"))
            (should (eq (emacs-agent-run-status run) 'requesting)))
        (when (buffer-live-p source) (kill-buffer source))))))

(ert-deftest emacs-agent-adapter-network-failure-and-configuration-isolation ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (setq-local gptel-tools '(user-selected-tools))
      (let* ((backend gptel-backend)
             (run (emacs-agent-test--submit "failure"))
             (session (emacs-agent-run-session run))
             (next (emacs-agent-test--submit "next")))
        (should (equal gptel-tools '(user-selected-tools)))
        (should (eq backend gptel-backend))
        (emacs-agent-gptel--callback run nil '(:status "503 unavailable"))
        (should (eq (emacs-agent-run-status run) 'failed))
        (should (eq (emacs-agent-session-active-run session) next))
        (should (= (length emacs-agent-test--requests) 2))
        (let ((gptel-model 'another-model))
          (let ((third (emacs-agent-test--submit "third")))
            (should (eq (emacs-agent-run-model third) 'another-model))
            (should (eq (emacs-agent-run-model next) 'gpt-4o))))))))

(ert-deftest emacs-agent-adapter-global-tool-execution-guard ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let ((first (emacs-agent-test--submit "first"))
            (other (emacs-agent-test--submit "other" "/tmp/other/")))
        (let ((emacs-agent-gptel--executing-tool t))
          (emacs-agent-test--calls other '(("other-call" "(insert \"O\")")))
          (should (equal (buffer-string) "")))
        (emacs-agent-test--calls first '(("first-call" "(insert \"F\")")))
        (should (equal (buffer-string) "FO"))
        (should (= (emacs-agent-run-tool-count other) 1))))))

(ert-deftest emacs-agent-adapter-history-policies-preserve-tool-linkage ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((first (emacs-agent-test--submit "first"))
             (session (emacs-agent-run-session first)))
        (emacs-agent-test--calls first '(("id-1" "(+ 1 1)")))
        (emacs-agent-test--complete first "two")
        (let* ((second (emacs-agent-test--submit "second"))
               (messages (copy-tree (emacs-agent-session-messages session))))
          (dolist (policy '(nil current full))
            (let* ((emacs-agent-context-history policy)
                   (history (emacs-agent-gptel--history second policy))
                   (tool (nth 1 history)))
              (should (eq (car tool) 'tool))
              (should (equal (plist-get (cdr tool) :id) "id-1"))
              (should (equal (plist-get (cdr tool) :result) "\n=> 2"))
              (should (eq (not (null (string-match-p "emacs-context" (cadar history))))
                          (eq policy 'full)))
              (should (eq (not (null (string-match-p "emacs-context" (cadr (car (last history))))))
                          (not (null policy))))))
          (should (equal messages (emacs-agent-session-messages session))))))))

(ert-deftest emacs-agent-adapter-empty-success-releases-queue ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "empty"))
             (session (emacs-agent-run-session run))
             (next (emacs-agent-test--submit "next")))
        ;; Actual pinned gptel may not call the text callback at all.
        (gptel--fsm-transition (emacs-agent-run-request-handle run) 'DONE)
        (should (eq (emacs-agent-run-status run) 'completed))
        (should (eq (emacs-agent-session-active-run session) next))))))

(ert-deftest emacs-agent-adapter-renderer-quit-does-not-strand-run ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "first"))
             (session (emacs-agent-run-session run))
             (next (emacs-agent-test--submit "next"))
             (emacs-agent-session-event-functions
              (list (lambda (_session event)
                      (when (eq (plist-get event :type) 'completed)
                        (signal 'quit nil))))))
        (emacs-agent-test--complete run "done")
        (should (eq (emacs-agent-run-status run) 'completed))
        (should (eq (emacs-agent-session-active-run session) next))))))

(ert-deftest emacs-agent-adapter-tracking-disabled-still-preserves-real-wire-history ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((gptel-track-response nil)
             (run (emacs-agent-test--submit "first")))
        (emacs-agent-test--calls run '(("linked-id" "(+ 1 1)")))
        (emacs-agent-test--complete run "two")
        (let* ((next (emacs-agent-test--submit "second"))
               (real-request (car emacs-agent-test--requests))
               (fsm (with-current-buffer (plist-get real-request :buffer)
                      (should gptel-track-response)
                      ;; Use actual gptel request construction, not the fixture.
                      (funcall emacs-agent-test--real-request
                               (plist-get real-request :prompt)
                               :dry-run t :stream nil)))
               (wire (prin1-to-string (plist-get (gptel-fsm-info fsm) :data))))
          (should (string-match-p "tool_call_id" wire))
          (should (string-match-p "linked-id" wire))
          (should (string-match-p "assistant" wire))
          (should-not gptel-track-response)
          (should (eq (emacs-agent-run-status next) 'requesting)))))))

(ert-deftest emacs-agent-adapter-stream-http-end-does-not-end-tool-loop ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "stream"))
             (session (emacs-agent-run-session run))
             (next (emacs-agent-test--submit "next")))
        (should (plist-get (car (last emacs-agent-test--requests)) :stream))
        (emacs-agent-gptel--callback run "Before " nil)
        (emacs-agent-gptel--callback run "tool" nil)
        (should (eq (emacs-agent-run-status run) 'streaming))
        (emacs-agent-gptel--callback run t nil)
        (should (eq (emacs-agent-session-active-run session) run))
        (should (eq (emacs-agent-run-status next) 'queued))
        (emacs-agent-test--calls run '(("call" "(+ 1 1)")))
        (emacs-agent-gptel--callback run "After " nil)
        (emacs-agent-gptel--callback run "tool" nil)
        (emacs-agent-gptel--callback run t nil)
        (emacs-agent-gptel--callback run t nil) ; completion signal is idempotent
        (should (equal (mapcar (lambda (message) (plist-get message :role))
                              (emacs-agent-session-messages session))
                       '(user assistant tool assistant)))
        (should (equal (plist-get (nth 1 (emacs-agent-session-messages session)) :text) "Before tool"))
        (should (equal (plist-get (nth 3 (emacs-agent-session-messages session)) :text) "After tool"))
        (gptel--fsm-transition (emacs-agent-run-request-handle run) 'DONE)
        (should (eq (emacs-agent-run-status run) 'completed))
        (should (eq (emacs-agent-session-active-run session) next))))))

(ert-deftest emacs-agent-adapter-stream-reasoning-only-is-not-fabricated-history ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "reason"))
             (session (emacs-agent-run-session run)))
        (emacs-agent-gptel--callback run '(reasoning . "actual ") nil)
        (emacs-agent-gptel--callback run '(reasoning . "reasoning") nil)
        (emacs-agent-gptel--callback run '(reasoning . t) nil)
        (emacs-agent-gptel--callback run t nil)
        (gptel--fsm-transition (emacs-agent-run-request-handle run) 'DONE)
        (should (eq (emacs-agent-run-status run) 'completed))
        (should (= (length (emacs-agent-session-messages session)) 1))
        (should (= (length (seq-filter (lambda (event) (eq (plist-get event :type) 'reasoning))
                                      (emacs-agent-session-events session))) 2))))))

(ert-deftest emacs-agent-adapter-stream-cancellation-retains-partial-once ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "cancel"))
             (session (emacs-agent-run-session run)))
        (emacs-agent-gptel--callback run "partial" nil)
        (emacs-agent-gptel-cancel session)
        (let ((events (copy-tree (emacs-agent-session-events session))))
          (emacs-agent-gptel--callback run "late" nil)
          (emacs-agent-gptel--callback run t nil)
          (gptel--fsm-transition (emacs-agent-run-request-handle run) 'DONE)
          (should (equal events (emacs-agent-session-events session))))
        (should (eq (emacs-agent-run-status run) 'cancelled))
        (should (equal (plist-get (car (last (emacs-agent-session-messages session))) :text) "partial"))
        (should-not (emacs-agent-run-assistant-chunks run))))))

(ert-deftest emacs-agent-adapter-stream-failure-retains-partial-and-unblocks ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "error"))
             (session (emacs-agent-run-session run))
             (next (emacs-agent-test--submit "next")))
        (emacs-agent-gptel--callback run "partial" nil)
        (emacs-agent-gptel--callback run nil '(:status "connection lost"))
        (should (eq (emacs-agent-run-status run) 'failed))
        (should (eq (emacs-agent-session-active-run session) next))
        (should (equal (plist-get (nth 1 (emacs-agent-session-messages session)) :text) "partial"))))))

(ert-deftest emacs-agent-adapter-stream-disabled-fallback-commits-at-terminal ()
  (emacs-agent-test-adapter
    (let ((emacs-agent-stream nil))
      (with-temp-buffer
        (let* ((run (emacs-agent-test--submit "nonstream"))
               (session (emacs-agent-run-session run)))
          (should-not (plist-get (car emacs-agent-test--requests) :stream))
          (emacs-agent-test--complete run "single response")
          (should (eq (emacs-agent-run-status run) 'completed))
          (should (equal (plist-get (nth 1 (emacs-agent-session-messages session)) :text)
                         "single response")))))))

(ert-deftest emacs-agent-adapter-incompatible-version-and-live-model-object-fail-safely ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let ((gptel-version "future-version"))
        (should (eq (emacs-agent-run-status (emacs-agent-test--submit "old contract")) 'failed)))
      (let* ((gptel-model (current-buffer))
             (run (emacs-agent-test--submit "invalid model")))
        (should (eq (emacs-agent-run-status run) 'failed))
        (should-not (string-match-p "#<" (prin1-to-string
                                         (emacs-agent-session-events (emacs-agent-run-session run)))))))
    (should-not emacs-agent-test--requests)))

(ert-deftest emacs-agent-adapter-helpers-use-single-eval-tool ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (insert "\n\nlive text\n")
      (let* ((run (emacs-agent-test--submit "read line 3"))
             (transport (emacs-agent-run-transport-buffer run)))
        (with-current-buffer transport
          (should (= (length gptel-tools) 1))
          (should (equal (gptel-tool-name (car gptel-tools)) "eval_elisp")))
        (let* ((delivery (emacs-agent-test--calls
                          run '(("helper-1" "(emacs-agent-read-lines (current-buffer) 3 3)"))))
               (wire (cdr (assoc "helper-1" (nth 2 delivery))))
               (result (read (substring wire 4))))
          (should (equal (plist-get result :text) "live text"))
          (should-not (plist-member result :lines))
          (should (equal (plist-get result :buffer) (buffer-name)))
          (should (= (plist-get result :start-line) 3)))))))

;;; emacs-agent-gptel-test.el ends here
