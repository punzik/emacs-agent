;;; emacs-agent-spike-test.el --- Offline stage zero tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'emacs-agent-spike)

(ert-deftest emacs-agent-eval-forms-and-errors ()
  (should (equal (emacs-agent-eval ";comment\n(princ \"hello\") (+ 2 3) ;end") "hello\n=> 5"))
  (should (equal (emacs-agent-eval "nil") "\n=> nil"))
  (should (string-match-p "ERROR end-of-file" (emacs-agent-eval "(+ 1")))
  (should (string-match-p "ERROR void-function" (emacs-agent-eval "(no-such-agent-function)")))
  (should (string-match-p "QUIT" (emacs-agent-eval "(signal 'quit nil)"))))

(ert-deftest emacs-agent-eval-buffer-string-is-plain-without-source-changes ()
  (with-temp-buffer
    (insert "λ\tvalue\n\nend\n")
    (add-text-properties (point-min) (point-max)
                         '(face font-lock-keyword-face fontified t eglot--managed t))
    (buffer-enable-undo)
    (setq buffer-undo-list nil)
    (let ((text (buffer-string))
          (tick (buffer-chars-modified-tick))
          (position (point))
          (undo buffer-undo-list))
      (should (equal (emacs-agent-eval "(buffer-string)")
                     (concat "\n=> " (prin1-to-string (substring-no-properties text)))))
      (should-not (string-match-p (regexp-quote "#(") (emacs-agent-eval "(buffer-string)")))
      (should (equal-including-properties text (buffer-string)))
      (should (= tick (buffer-chars-modified-tick)))
      (should (= position (point)))
      (should (eq undo buffer-undo-list))
      (should (eq (get-text-property (point-min) 'face) 'font-lock-keyword-face)))))

(ert-deftest emacs-agent-eval-property-size-does-not-truncate-useful-text ()
  (with-temp-buffer
    (insert "small text")
    (put-text-property (point-min) (point-max) 'synthetic-metadata (make-string 50000 ?x))
    (let ((emacs-agent-eval-output-limit 64))
      (should (equal (emacs-agent-eval "(buffer-string)") "\n=> \"small text\""))
      (should (= (length (get-text-property (point-min) 'synthetic-metadata)) 50000)))))

(ert-deftest emacs-agent-eval-plain-string-scope-and-explicit-properties ()
  (should (equal (emacs-agent-eval "(propertize \"\" 'face 'bold)") "\n=> \"\""))
  ;; Explicit property inspection and non-string objects are still ordinary Lisp.
  (should (equal (emacs-agent-eval "(get-text-property 0 'face (propertize \"x\" 'face 'bold))")
                 "\n=> bold"))
  (should (equal (emacs-agent-eval "(list (propertize \"x\" 'face 'bold))")
                 "\n=> (#(\"x\" 0 1 (face bold)))"))
  (should (equal (emacs-agent-eval "(prin1 (propertize \"x\" 'face 'bold)) nil")
                 "#(\"x\" 0 1 (face bold))\n=> nil"))
  (should (equal (emacs-agent-eval "(princ (propertize \"λ\\n\" 'face 'bold)) \"ok\"")
                 "λ\n\n=> \"ok\"")))

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
          (should (string-prefix-p "\n=> \"changed\"" (cadr results)))
          (should (string-match-p "Source buffer changed" (cadr results)))
          (should (equal (car results) "\n=> 42"))
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
