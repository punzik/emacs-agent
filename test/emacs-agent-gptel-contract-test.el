;;; emacs-agent-gptel-contract-test.el --- Pinned gptel contracts -*- lexical-binding: t; -*-
(require 'ert)
(require 'emacs-agent-spike)

(ert-deftest emacs-agent-gptel-multiple-call-order-contract ()
  "Exercise actual gptel tool dispatch; stub only its next FSM transition."
  (with-temp-buffer
    (let* ((gptel-backend (gptel-make-openai "contract-offline" :key "unused"))
           (source (current-buffer))
           (log (generate-new-buffer " *contract-log*"))
           (run (make-emacs-agent-spike :source source :transport source :log log))
           (tool (gptel-make-tool :name "eval_elisp" :function #'emacs-agent-eval
                                  :description "test" :confirm t
                                  :args '((:name "expression" :type string :description "Lisp"))))
           (calls '((:id "first" :name "eval_elisp" :args (:expression "(insert \"1\")"))
                    (:id "second" :name "eval_elisp" :args (:expression "(insert \"2\")"))))
           (fsm (gptel-make-fsm))
           (gptel-confirm-tool-calls t))
      (unwind-protect
          (progn
            (setf (gptel-fsm-info fsm)
                  (list :buffer source :backend gptel-backend :tools (list tool)
                        :tool-use (copy-tree calls)
                        :callback (apply-partially #'emacs-agent-spike--callback run)))
            (cl-letf (((symbol-function 'gptel--fsm-transition) #'ignore))
              (gptel--handle-tool-use fsm)
              (gptel--handle-tool-use fsm))
            ;; Adapter restores provider order despite reversed callback entries.
            (should (equal (buffer-string) "12"))
            (should (= (hash-table-count (emacs-agent-spike-calls run)) 2))
            (should (cl-every (lambda (call) (plist-get call :result))
                              (plist-get (gptel-fsm-info fsm) :tool-use))))
        (kill-buffer log)))))

;;; emacs-agent-gptel-contract-test.el ends here
