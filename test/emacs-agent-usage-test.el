;;; emacs-agent-usage-test.el --- Usage lifecycle contracts -*- lexical-binding: t; -*-
(require 'ert)
(require 'emacs-agent-usage)
(require 'emacs-agent-gptel)

;; Adapter/store test fixtures are loaded first by the Makefile.
(defun emacs-agent-usage-test--open (run)
  "Open RUN's private WAIT accounting without starting a network transport."
  (let ((fsm (emacs-agent-run-request-handle run)))
    (unless (gptel-fsm-info fsm)
      (setf (gptel-fsm-info fsm)
            (list :buffer (emacs-agent-run-transport-buffer run)
                  :backend (emacs-agent-run-backend run)
                  :callback (apply-partially #'emacs-agent-gptel--callback run))))
    ;; WAIT now wraps the transport as well; isolate accounting here.
    (emacs-agent-gptel--usage-begin run fsm)
    (gptel-fsm-info fsm)))

(defun emacs-agent-usage-test--events (run type)
  "Return RUN's usage events of TYPE."
  (cl-remove-if-not (lambda (e) (and (equal (plist-get e :run-id) (emacs-agent-run-id run))
                                    (eq (plist-get e :type) type)))
                    (emacs-agent-session-events (emacs-agent-run-session run))))

(ert-deftest emacs-agent-usage-zero-unknown-and-invalid-fields ()
  (should (equal (emacs-agent-usage--tokens nil)
                 '(:input unknown :output unknown :cached unknown)))
  (should (equal (emacs-agent-usage--tokens '(:input 0 :output -1 :cached "5"))
                 '(:input 0 :output unknown :cached unknown)))
  (should (equal (emacs-agent-usage--derived '(:input 0 :output 0 :cached 0))
                 '(:input-total 0 :total 0)))
  (should (eq (plist-get (emacs-agent-usage-summary (make-emacs-agent-run)) :total)
              'unknown)))

(ert-deftest emacs-agent-usage-real-tool-recursion-closes-before-next-wait ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((handlers (copy-tree gptel-request--handlers))
             (run (emacs-agent-test--submit "usage"))
             (fsm (emacs-agent-run-request-handle run))
             (info (emacs-agent-usage-test--open run))
             (tool (with-current-buffer (emacs-agent-run-transport-buffer run) (car gptel-tools)))
             (http 0))
        (plist-put info :tools (list tool))
        (plist-put info :tool-use '((:id "usage-tool" :name "eval_elisp" :args (:expression "(+ 17 25)"))))
        (plist-put info :data
                   '(:messages [(:role "user" :content "usage")
                                (:role "assistant" :content :null
                                 :tool_calls [(:id "usage-tool" :type "function"
                                               :function (:name "eval_elisp" :arguments "{}"))])]))
        ;; Real pinned normalization, including input minus cached input.
        (gptel--openai-update-tokens '(:prompt_tokens 100 :completion_tokens 20
                                      :prompt_tokens_details (:cached_tokens 40)) info)
        (emacs-agent-gptel--callback run "thinking" info)
        (emacs-agent-gptel--callback run t info)
        (emacs-agent-gptel--callback run t info) ; duplicate observation, not another charge
        (let ((gptel-use-curl t))
          (cl-letf (((symbol-function 'gptel-curl-get-response)
                     (lambda (_fsm)
                       (cl-incf http)
                       (should (= (length (emacs-agent-usage-test--events run 'usage)) 1))
                       (should (= (length (emacs-agent-run-usage-requests run)) 2))
                       (should-not (plist-get info :tokens)))))
            ;; Real TOOL -> TRET -> WAIT recursion, with only HTTP stubbed.
            (gptel--fsm-transition fsm 'TOOL)))
        (should (= http 1))
        (should (= (emacs-agent-run-tool-count run) 1))
        (should (eq (plist-get (emacs-agent-usage-summary run) :total) 'unknown))
        (gptel--openai-update-tokens '(:prompt_tokens 160 :completion_tokens 30
                                      :prompt_tokens_details (:cached_tokens 80)) info)
        ;; Empty final response: no text callback needed to account for it.
        (gptel--fsm-transition fsm 'DONE)
        (should (eq (emacs-agent-run-status run) 'completed))
        (should (= (length (emacs-agent-usage-test--events run 'usage)) 2))
        (should (= (length (emacs-agent-usage-test--events run 'usage-total)) 1))
        (let ((summary (emacs-agent-usage-summary run)))
          (should (= (plist-get summary :requests) 2))
          (should (= (plist-get summary :reported) 2))
          (should (equal (plist-get summary :tokens) '(:input 140 :output 50 :cached 120)))
          (should (= (plist-get summary :input-total) 260))
          (should (= (plist-get summary :total) 310)))
        (should (equal handlers gptel-request--handlers))
        ;; Late data cannot change either request or summary events.
        (let ((events (copy-tree (emacs-agent-session-events (emacs-agent-run-session run)))))
          (emacs-agent-gptel--callback run t info)
          (emacs-agent-gptel--usage-end run fsm)
          (should (equal events (emacs-agent-session-events (emacs-agent-run-session run)))))))))

(ert-deftest emacs-agent-usage-missing-request-does-not-reuse-cumulative ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "usage"))
             (info (emacs-agent-usage-test--open run)))
        (gptel--openai-update-tokens '(:prompt_tokens 100 :completion_tokens 20) info)
        (emacs-agent-usage-end run 'received info)
        (emacs-agent-usage-end run 'received info)
        (emacs-agent-usage-test--open run)
        (should (plist-get info :tokens-full))
        (should-not (plist-get info :tokens))
        (gptel--fsm-transition (emacs-agent-run-request-handle run) 'DONE)
        (let ((summary (emacs-agent-usage-summary run)))
          (should (= (plist-get summary :requests) 2))
          (should (= (plist-get summary :reported) 1))
          (should (eq (plist-get summary :total) 'unknown)))
        (should (= (length (emacs-agent-usage-test--events run 'usage)) 2))))))

(ert-deftest emacs-agent-usage-type-is-not-stream-completion ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "stream"))
             (info (emacs-agent-usage-test--open run)))
        (gptel--fsm-transition (emacs-agent-run-request-handle run) 'TYPE)
        (should (emacs-agent-run-usage-current run))
        (should-not (emacs-agent-usage-test--events run 'usage))
        (emacs-agent-gptel--callback run '(reasoning . "partial") info)
        (emacs-agent-gptel--callback run "partial" info)
        (emacs-agent-gptel--callback run nil info)
        (should (eq (emacs-agent-run-status run) 'failed))
        (should (= (length (emacs-agent-usage-test--events run 'usage)) 1))
        (should (eq (plist-get (emacs-agent-usage-summary run) :total) 'unknown))))))

(ert-deftest emacs-agent-usage-cancel-retains-parsed-counts-without-callback ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "cancel"))
             (info (emacs-agent-usage-test--open run)))
        (gptel--openai-update-tokens '(:prompt_tokens 10 :completion_tokens 2) info)
        ;; Stream [DONE] may parse usage without producing another callback.
        (should-not (plist-get (emacs-agent-run-usage-current run) :available))
        (emacs-agent-gptel-cancel (emacs-agent-run-session run))
        (should (eq (emacs-agent-run-status run) 'cancelled))
        (should (= (plist-get (emacs-agent-usage-summary run) :total) 12))
        (should (eq (plist-get (car (emacs-agent-run-usage-requests run)) :status) 'cancelled))))))

(ert-deftest emacs-agent-usage-nonstream-text-block-closes-before-usage ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "nonstream"))
             (info (emacs-agent-usage-test--open run)))
        (emacs-agent-gptel--callback run "answer" info)
        (gptel--fsm-transition (emacs-agent-run-request-handle run) 'DONE)
        (let* ((events (plist-get (emacs-agent-store--snapshot (emacs-agent-run-session run)) :events))
               (text (cl-find-if (lambda (e) (eq (plist-get e :type) 'assistant)) events)))
          (should (eq (plist-get text :state) 'complete))
          (should (equal (plist-get text :payload) "answer")))))))

(ert-deftest emacs-agent-usage-independent-sessions ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((a (emacs-agent-test--submit "a"))
             (b (emacs-agent-test--submit "b" "/tmp/usage-other/")))
        (dolist (pair (list (cons a 10) (cons b 20)))
          (let ((info (emacs-agent-usage-test--open (car pair))))
            (gptel--openai-update-tokens (list :prompt_tokens (cdr pair) :completion_tokens 1) info)
            (gptel--fsm-transition (emacs-agent-run-request-handle (car pair)) 'DONE)))
        (should (= (plist-get (emacs-agent-usage-summary a) :total) 11))
        (should (= (plist-get (emacs-agent-usage-summary b) :total) 21))))))

(ert-deftest emacs-agent-usage-pending-request-restores-as-unknown-interruption ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "interrupted"))
             (session (emacs-agent-run-session run))
             (info (emacs-agent-usage-test--open run)))
        (gptel--openai-update-tokens '(:prompt_tokens 10 :completion_tokens 2) info)
        (emacs-agent-usage-end run 'received info)
        (emacs-agent-usage-test--open run)
        (emacs-agent-store-save session)
        (remhash 'global emacs-agent-session--registry)
        (let* ((restored (emacs-agent-session-get nil))
               (interrupted (cl-find-if (lambda (e) (eq (plist-get e :type) 'interrupted))
                                        (emacs-agent-session-events restored)))
               (summary (plist-get (plist-get interrupted :saved-run) :usage)))
          (should (= (plist-get summary :requests) 2))
          (should (= (plist-get summary :reported) 1))
          (should (eq (plist-get summary :total) 'unknown))
          (should-not (emacs-agent-session-active-run restored))
          (should-not (emacs-agent-session-pending-runs restored)))))))

(ert-deftest emacs-agent-usage-roundtrip-and-journal-do-not-affect-history ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "persist usage"))
             (session (emacs-agent-run-session run))
             (history (copy-tree (emacs-agent-session-messages session)))
             (info (emacs-agent-usage-test--open run)))
        (gptel--openai-update-tokens '(:prompt_tokens 0 :completion_tokens 0) info)
        ;; An open request's known/unknown counts are checkpointed too.
        (emacs-agent-usage-observe run info)
        (should (= (plist-get (plist-get (emacs-agent-store--run run) :usage) :total) 0))
        (gptel--fsm-transition (emacs-agent-run-request-handle run) 'DONE)
        (should (equal history (emacs-agent-session-messages session)))
        (emacs-agent-store-save session)
        (remhash 'global emacs-agent-session--registry)
        (let ((restored (emacs-agent-session-get nil)))
          (should (equal history (emacs-agent-session-messages restored)))
          (emacs-agent--render-log restored)
          (with-current-buffer (emacs-agent-session-log-buffer restored)
            (should (string-match-p "HTTP #1 (received)" (buffer-string)))
            (should (string-match-p "Run: 1 requests, 1 with usage" (buffer-string)))
            (should (string-match-p "cache-read=0" (buffer-string)))
            (should (string-match-p "gptel-normalized" (buffer-string)))))))))

;;; emacs-agent-usage-test.el ends here
