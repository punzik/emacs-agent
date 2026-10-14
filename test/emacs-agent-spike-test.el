;;; emacs-agent-spike-test.el --- Offline stage zero tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'emacs-agent-spike)

(ert-deftest emacs-agent-eval-forms-and-errors ()
  (should (equal (emacs-agent-eval ";comment\n(princ \"hello\") (+ 2 3) ;end") "hello\n=> 5"))
  (should (equal (emacs-agent-eval "nil") "\n=> nil"))
  (should (string-match-p "ERROR end-of-file" (emacs-agent-eval "(+ 1")))
  (should (string-match-p "ERROR void-function" (emacs-agent-eval "(no-such-agent-function)")))
  (should (string-match-p "QUIT" (emacs-agent-eval "(signal 'quit nil)")))
  (let ((emacs-agent-eval-output-limit 20))
    (should (string-suffix-p "[truncated]" (emacs-agent-eval "(make-string 100 ?a)")))))

(ert-deftest emacs-agent-spike-fixed-tool-loop ()
  "Mock gptel-request, not Lisp execution: two calls, then final text."
  (let ((original-tools gptel-tools)
        (original-backend gptel-backend)
        run results callback)
    (unwind-protect
        (with-temp-buffer
          (cl-letf (((symbol-function 'gptel-request)
                     (lambda (_prompt &rest keys)
                       (setq callback (plist-get keys :callback))
                       (let ((tool (car gptel-tools)))
                         (cl-loop for id in '("call-1" "call-2")
                                  for expression in '("(insert \"changed\") (buffer-string)"
                                                      "(+ 20 22)")
                                  do (funcall callback
                                              (list 'tool-call
                                                    (list tool (list :expression expression)
                                                          (lambda (result) (push result results))))
                                              (list :tool-use (list (list :id id)))))
                         (funcall callback "Done" '(:status "200")))
                       'mock-request)))
            (setq run (emacs-agent-spike-start "Make a change and calculate")))
          (should (equal (buffer-string) "changed"))
          (should (equal (reverse results) '("\n=> \"changed\"" "\n=> 42")))
          (should (eq (emacs-agent-spike-status run) 'completed))
          (should (equal gptel-tools original-tools))
          (should (eq gptel-backend original-backend)))
      (when run
        (kill-buffer (emacs-agent-spike-log run))
        (kill-buffer (emacs-agent-spike-transport run))))))

(ert-deftest emacs-agent-spike-duplicate-and-late-callbacks ()
  (let* ((source (generate-new-buffer " *spike-test-source*"))
         (transport (generate-new-buffer " *spike-test-transport*"))
         (log (generate-new-buffer " *spike-test-log*"))
         (run (make-emacs-agent-spike :source source :transport transport :log log))
         (tool (gptel-make-tool :name "eval_elisp" :function #'emacs-agent-eval
                               :description "test" :args nil))
         (deliveries 0)
         (response (list 'tool-call
                         (list tool '(:expression "(insert \"x\")")
                               (lambda (_) (cl-incf deliveries)))))
         (info '(:tool-use ((:id "call-1")))))
    (unwind-protect
        (progn
          (emacs-agent-spike--callback run response info)
          (emacs-agent-spike--callback run response info)
          (should (= deliveries 1))
          (should (equal (with-current-buffer source (buffer-string)) "x"))
          (cl-letf (((symbol-function 'gptel-abort) #'ignore))
            (emacs-agent-spike-cancel run))
          (let ((events (copy-tree (emacs-agent-spike-events run))))
            (emacs-agent-spike--callback run response '(:tool-use ((:id "call-2"))))
            (emacs-agent-spike--callback run "Late" nil)
            (should (equal events (emacs-agent-spike-events run)))))
      (kill-buffer source) (kill-buffer transport) (kill-buffer log))))

(ert-deftest emacs-agent-spike-real-gptel-history-dry-run ()
  "Check experimental structured history against the installed adapter.
No API key is required and no network request is made."
  (with-temp-buffer
    (let* ((gptel-backend (gptel-make-openai "spike-offline" :key "unused"
                                              :host "offline.invalid" :endpoint "/v1/chat/completions"))
           (gptel-model 'gpt-4o)
           (gptel-use-context nil)
           (gptel-use-tools nil)
           (fsm (gptel-request
                    '((prompt "first") (response "checking")
                      (tool :id "call-1" :name "eval_elisp"
                            :args (:expression "(+ 1 1)") :result "2")
                      (prompt "second"))
                  :dry-run t :stream nil))
           (info (gptel-fsm-info fsm))
           (data (plist-get info :data))
           (messages (plist-get data :messages))
           (serialized (prin1-to-string messages)))
      (should (string-match-p "call-1" serialized))
      (should (string-match-p "tool_call_id" serialized))
      (should (string-match-p "eval_elisp" serialized))
      (should (string-match-p "second" serialized)))))

;;; emacs-agent-spike-test.el ends here
