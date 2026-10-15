;;; emacs-agent-history-test.el --- Actual gptel replay contracts -*- lexical-binding: t; -*-
;; Loaded after emacs-agent-gptel-test.el, which supplies the isolated fixture.
(require 'ert)
(require 'emacs-agent-gptel)
(defvar emacs-agent-test--runs)
(defvar emacs-agent-test--requests)
(defvar emacs-agent-test--real-request)

(defun emacs-agent-test--wire (run policy)
  "Build actual gptel request data for RUN/POLICY without sending anything."
  (with-current-buffer (emacs-agent-run-transport-buffer run)
    (let ((fsm (funcall emacs-agent-test--real-request
                        (emacs-agent-gptel--history run policy)
                        :system emacs-agent-system-prompt :dry-run t :stream nil
                        :transforms '(ignore))))
      (emacs-agent-gptel--restore-protocol run fsm)
      (plist-get (gptel-fsm-info fsm) :data))))

(defun emacs-agent-test--real-tools (run)
  "Exercise real non-streaming parsing/dispatch with two reasoning-bearing calls."
  (let* ((fsm (with-current-buffer (emacs-agent-run-transport-buffer run)
                (funcall emacs-agent-test--real-request (emacs-agent-gptel--history run)
                         :dry-run t :stream nil :transforms '(ignore))))
         (info (gptel-fsm-info fsm))
         (backend (emacs-agent-run-backend run)))
    (plist-put info :callback (apply-partially #'emacs-agent-gptel--callback run))
    (gptel--parse-response
     backend
     '(:choices [(:message
                  (:role "assistant" :content :null :reasoning_content "actual protocol reasoning"
                   :tool_calls [(:id "pair-1" :type "function"
                                 :function (:name "eval_elisp" :arguments "{\"expression\":\"(+ 1 1)\"}"))
                                (:id "pair-2" :type "function"
                                 :function (:name "eval_elisp" :arguments "{\"expression\":\"(+ 2 2)\"}"))])
                  :finish_reason "tool_calls")])
     info)
    (cl-letf (((symbol-function 'gptel--fsm-transition) #'ignore))
      (gptel--handle-tool-use fsm))
    (should (= (emacs-agent-run-tool-count run) 2))))

(ert-deftest emacs-agent-history-real-wire-policies-preserve-pairs-and-reasoning ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (rename-buffer "stage4-old" t)
      (let* ((first (emacs-agent-test--submit "old user"))
             (session (emacs-agent-run-session first)))
        (emacs-agent-test--real-tools first)
        (emacs-agent-test--complete first "old answer")
        (rename-buffer "stage4-current" t)
        (let* ((next (emacs-agent-test--submit "new user"))
               (stored (copy-tree (emacs-agent-session-messages session))))
          (dolist (policy '(nil current full))
            (let* ((data (emacs-agent-test--wire next policy))
                   (messages (append (plist-get data :messages) nil))
                   (users (seq-filter (lambda (m) (equal (plist-get m :role) "user")) messages))
                   (seen (make-hash-table :test #'equal))
                   (results 0))
              (should (= (length users) 2))
              (should (eq (not (null (string-match-p "stage4-old" (plist-get (car users) :content))))
                          (eq policy 'full)))
              (should (eq (not (null (string-match-p "stage4-current" (plist-get (cadr users) :content))))
                          (not (null policy))))
              (dolist (message messages)
                (cl-loop for call across (or (plist-get message :tool_calls) []) do
                         (should (member (plist-get call :id) '("pair-1" "pair-2")))
                         (let ((args (json-parse-string (plist-get (plist-get call :function) :arguments)
                                                        :object-type 'plist)))
                           (should (member (plist-get args :expression) '("(+ 1 1)" "(+ 2 2)"))))
                         (puthash (plist-get call :id) t seen)
                         (should (equal (plist-get message :reasoning_content) "actual protocol reasoning"))
                         (should (equal (plist-get (plist-get call :function) :name) "eval_elisp")))
                (when (equal (plist-get message :role) "tool")
                  (cl-incf results)
                  (should (gethash (plist-get message :tool_call_id) seen))
                  (should (string-match-p "=> [24]" (plist-get message :content)))))
              (should (= results 2))))
          (should (equal stored (emacs-agent-session-messages session))))))))

(ert-deftest emacs-agent-history-policy-is-frozen-and-chat-transforms-are-isolated ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "user"))
             (gptel--num-messages-to-send 0)
             (gptel-prompt-transform-functions
              (list (lambda () (ert-fail "Ambient gptel transform executed"))))
             (emacs-agent-context-history nil)
             (request (car emacs-agent-test--requests)))
        (should (eq (emacs-agent-run-context-policy run) 'current))
        (should (string-match-p "emacs-context" (cadar (emacs-agent-gptel--history run))))
        (should (equal (plist-get request :transforms) '(ignore)))
        (with-current-buffer (emacs-agent-run-transport-buffer run)
          (should-not gptel--num-messages-to-send)
          (funcall emacs-agent-test--real-request (emacs-agent-gptel--history run)
                   :dry-run t :stream nil :transforms '(ignore)))))))

(ert-deftest emacs-agent-history-unsupported-backend-fails-before-network ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((gptel-backend (gptel-make-openai "unsupported-responses" :key "unused"))
             (run (emacs-agent-test--submit "unsupported")))
        (should (eq (emacs-agent-run-status run) 'failed))
        (should-not emacs-agent-test--requests)
        (should-not (emacs-agent-session-active-run (emacs-agent-run-session run)))))))

(ert-deftest emacs-agent-history-opaque-response-blocks-future-replay ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "opaque"))
             (session (emacs-agent-run-session run)))
        (emacs-agent-gptel--callback run '(reasoning . "visible") '(:signature "opaque-secret"))
        (should (eq (emacs-agent-run-status run) 'failed))
        (should (= (emacs-agent-run-tool-count run) 0))
        (should-not (string-match-p "opaque-secret" (prin1-to-string (emacs-agent-session-events session))))
        (let ((next (emacs-agent-test--submit "do not silently replay")))
          (should (eq (emacs-agent-run-status next) 'failed))
          (should (= (length emacs-agent-test--requests) 1)))))))

(ert-deftest emacs-agent-history-validation-rejects-inconsistent-or-opaque-records ()
  (let ((user '(:role user :run-id "run" :text "text" :context nil))
        (tool '(:role tool :run-id "run" :id "id" :name "eval_elisp"
                :args (:expression "nil") :result "=> nil")))
    (should-error (emacs-agent-gptel--validate-history (list tool)))
    (should-error (emacs-agent-gptel--validate-history (list user tool tool)))
    (should-error (emacs-agent-gptel--validate-history
                   (list user '(:role assistant :run-id "run" :text "ok" :signature "opaque"))))
    (should-error (emacs-agent-gptel--validate-history
                   (list user (append tool '(:protocol (:encrypted_content "opaque"))))))
    (should-not (emacs-agent-gptel--validate-history (list user tool)))))

(ert-deftest emacs-agent-history-stream-batch-order-uses-original-indices ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "ordered batch"))
             (tool (with-current-buffer (emacs-agent-run-transport-buffer run) (car gptel-tools)))
             (first '(:expression "(insert \"1\")"))
             (second '(:expression "(insert \"2\")")))
        ;; Actual streaming parser reverses :tool-use and callback dispatch
        ;; reverses it again; raw messages retain original :index positions.
        (emacs-agent-gptel--callback
         run (list 'tool-call (list tool first #'ignore) (list tool second #'ignore))
         (list :tool-use (list (list :id "second" :args second) (list :id "first" :args first))
               :data '(:messages [(:role "assistant" :tool_calls
                                   [(:id "second" :index 1) (:id "first" :index 0)])])))
        (should (equal (buffer-string) "12"))))))

(ert-deftest emacs-agent-history-nested-opaque-tool-field-fails-before-execution ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let ((run (emacs-agent-test--submit "opaque call")))
        (emacs-agent-gptel--callback
         run '(tool-call)
         '(:data (:messages [(:role "assistant" :tool_calls
                              [(:id "id" :thoughtSignature "not-to-be-discarded")])])))
        (should (eq (emacs-agent-run-status run) 'failed))
        (should (= (emacs-agent-run-tool-count run) 0))))))

(ert-deftest emacs-agent-history-plain-buffer-result-in-real-wire ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (insert "λ sample\n")
      (put-text-property (point-min) (point-max) 'synthetic-private-property
                         (make-string 40000 ?x))
      (let* ((run (emacs-agent-test--submit "read source"))
             (delivery (emacs-agent-test--calls run '(("plain-read" "(buffer-string)"))))
             (result (cdr (assoc "plain-read" (nth 2 delivery))))
             (data (emacs-agent-test--wire run nil))
             (tool (seq-find (lambda (m) (equal (plist-get m :role) "tool"))
                             (plist-get data :messages))))
        (should (equal result "\n=> \"λ sample\n\""))
        ;; Pinned gptel trims tool-result framing whitespace on the wire.
        (should (equal (plist-get tool :content) (string-trim result)))
        (should-not (string-match-p "synthetic-private-property" (gptel--json-encode data)))
        (should (= (length (get-text-property (point-min) 'synthetic-private-property)) 40000))))))

;;; emacs-agent-history-test.el ends here
