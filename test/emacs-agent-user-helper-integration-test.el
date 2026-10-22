;;; emacs-agent-user-helper-integration-test.el --- Frozen helper metadata -*- lexical-binding: t; -*-

(require 'ert)
(require 'emacs-agent)
;; Makefile loads adapter/history fixtures before this file.

(defun emacs-agent-user-helper-integration--register (text)
  "Advertise an existing function with descriptive TEXT, without calling it."
  (emacs-agent-register-helper 'emacs-agent-buffer-info
                              :description text :returns "Buffer metadata plist."))

(ert-deftest emacs-agent-user-helper-integration-fifo-wire ()
  (emacs-agent-test-adapter
    (let ((emacs-agent-user-helpers--registry (make-hash-table :test #'eq))
          (emacs-agent-project-instructions nil)
          (emacs-agent-context-history nil))
      (with-temp-buffer
        (emacs-agent-user-helper-integration--register "FROZEN-HELPER-ONE")
        (let* ((first (emacs-agent-test--submit "first"))
               (first-system (plist-get (car emacs-agent-test--requests) :system)))
          (emacs-agent-user-helper-integration--register "FROZEN-HELPER-TWO")
          (let ((second (emacs-agent-test--submit "second")))
            (emacs-agent-unregister-helper 'emacs-agent-buffer-info)
            (should (string-match-p "FROZEN-HELPER-ONE" first-system))
            (should-not (string-match-p "FROZEN-HELPER-TWO" first-system))
            (emacs-agent-test--complete first "answer")
            (let* ((data (emacs-agent-test--wire second nil))
                   (messages (append (plist-get data :messages) nil))
                   (system (plist-get (car messages) :content)))
              (should (equal system (plist-get (car emacs-agent-test--requests) :system)))
              (should (string-match-p "FROZEN-HELPER-TWO" system))
              (should-not (string-match-p "FROZEN-HELPER-ONE" system))
              (should (equal (plist-get (car (last messages)) :content) "second")))
            (should-not (plist-get (emacs-agent-resources-capture nil) :helpers))))))))

(ert-deftest emacs-agent-user-helper-integration-inert-restore-and-view ()
  (emacs-agent-test-adapter
    (let ((emacs-agent-user-helpers--registry (make-hash-table :test #'eq)))
      (with-temp-buffer
        (emacs-agent-user-helper-integration--register "SAVED-HELPER-ONE")
        (let* ((first (emacs-agent-test--submit "first"))
               (session (emacs-agent-run-session first)) view)
          (unwind-protect
              (progn
                (emacs-agent-user-helper-integration--register "SAVED-HELPER-TWO")
                (emacs-agent-test--submit "second")
                (let ((file (emacs-agent-store-save session)))
                  (clrhash emacs-agent-user-helpers--registry)
                  (remhash (emacs-agent-session-id session) emacs-agent-session--registry)
                  (cl-letf (((symbol-function 'emacs-agent-user-helpers--capture)
                             (lambda () (ert-fail "Restore/view consulted current registry"))))
                    (let* ((restored (emacs-agent-store--restore file))
                           (inputs (emacs-agent-session-inputs restored))
                           (helpers (mapcar (lambda (input)
                                              (plist-get (emacs-agent-run-instructions
                                                          (emacs-agent-input-run input)) :helpers))
                                            inputs)))
                      (should helpers)
                      (should (cl-some (lambda (text) (string-match-p "SAVED-HELPER-TWO" text)) helpers))
                      (should-not (emacs-agent-session-active-run restored))
                      (should-not (emacs-agent-session-pending-runs restored))
                      (with-temp-buffer
                        (setq-local emacs-agent-session--owner restored)
                        (cl-letf (((symbol-function 'display-buffer) #'ignore))
                          (setq view (emacs-agent-show-instructions))))
                      (with-current-buffer view
                        (should buffer-read-only)
                        (should (string-match-p "SAVED-HELPER-TWO" (buffer-string)))))))
                (should (zerop (hash-table-count emacs-agent-user-helpers--registry))))
            (when (buffer-live-p view) (kill-buffer view))))))))

(ert-deftest emacs-agent-user-helper-integration-pending-validation ()
  (let ((snapshot '(:status no-project :root nil :path nil :text nil :warnings nil
                            :helpers "User helpers: frozen text")))
    (emacs-agent-input--validate-instructions snapshot)
    (dolist (value '(nil 42 "" " \n\t" ("not a string")))
      (let ((copy (copy-tree snapshot)))
        (plist-put copy :helpers value)
        (should-error (emacs-agent-input--validate-instructions copy))))
    (should-error (emacs-agent-input--validate-instructions
                   (list :status 'missing :emacsagent snapshot)))))

(ert-deftest emacs-agent-user-helper-integration-byte-and-context-budget ()
  (emacs-agent-test-adapter
    (let ((emacs-agent-user-helpers--registry (make-hash-table :test #'eq)))
      (with-temp-buffer
        (emacs-agent-user-helper-integration--register (make-string 12000 ?x))
        (let ((emacs-agent-pending-byte-limit 1000))
          (should-error (emacs-agent-test--submit "too large") :type 'user-error)
          (should-not emacs-agent-test--requests))
        (let* ((run (emacs-agent-test--submit "budget"))
               (data (emacs-agent-test--wire run nil))
               (baseline (copy-tree data t))
               (system (aref (plist-get baseline :messages) 0)))
          (plist-put system :content emacs-agent-system-prompt)
          (let ((small (emacs-agent-compaction-estimate baseline)))
            (setf (emacs-agent-run-context-config run)
                  (list :window (+ small 612) :reserve 512 :keep 1 :automatic nil))
            (should (= (emacs-agent-compact-check run baseline) small))
            (should-error (emacs-agent-compact-check run data))))))))

(provide 'emacs-agent-user-helper-integration-test)
;;; emacs-agent-user-helper-integration-test.el ends here
