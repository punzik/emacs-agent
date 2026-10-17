;;; emacs-agent-conversation-test.el --- F6 UI, ownership and restart -*- lexical-binding: t; -*-
(require 'ert)
(require 'emacs-agent)

(defvar emacs-agent-conversation-test--effects nil)

(defmacro emacs-agent-conversation-test--fixture (&rest body)
  (declare (indent 0) (debug t))
  `(emacs-agent-test-adapter
     (let ((default-directory emacs-agent-data-directory)
           (emacs-agent-conversation-test--effects nil))
       (cl-letf (((symbol-function 'display-buffer) #'ignore)
                 ((symbol-function 'pop-to-buffer) #'ignore))
         (unwind-protect (progn ,@body)
           (when (get-buffer "*emacs-agent sessions*")
             (kill-buffer "*emacs-agent sessions*")))))))

(ert-deftest emacs-agent-conversation-command-namespace ()
  (dolist (command '(emacs-agent-session-new emacs-agent-session-rename
                     emacs-agent-session-select emacs-agent-session-search
                     emacs-agent-session-clone))
    (should (commandp command)))
  (dolist (function '(emacs-agent-session--new emacs-agent-session--rename
                      emacs-agent-session--select emacs-agent-session--clone))
    (should (fboundp function))
    (should-not (commandp function)))
  (dolist (old '(emacs-agent-new emacs-agent-rename emacs-agent-select
                emacs-agent-search emacs-agent-clone))
    (should-not (fboundp old))))

(ert-deftest emacs-agent-conversation-public-commands-and-nonselected-journal-execution ()
  (emacs-agent-conversation-test--fixture
    (with-temp-buffer
      (let* ((source (current-buffer))
             (first (emacs-agent-test--submit "first goal"))
             (old (emacs-agent-run-session first)))
        (emacs-agent-test--complete first "first answer")
        (emacs-agent-session-rename "old")
        (let* ((new (emacs-agent-session-new "new"))
               (journal (emacs-agent--log-buffer old))
               old-run new-run)
          (should-not (equal (emacs-agent-session-id old) (emacs-agent-session-id new)))
          (should-not (equal (emacs-agent--session-name old) (emacs-agent--session-name new)))
          (should (eq (emacs-agent-session-last-source-buffer new) source))
          (with-current-buffer journal
            (should (eq (emacs-agent--current-session) old))
            (cl-letf (((symbol-function 'read-from-minibuffer) (lambda (&rest _) "old continuation")))
              (setq old-run (emacs-agent-ask))))
          (should (eq (emacs-agent-session-selected nil) new))
          (setq new-run (emacs-agent-test--submit "new goal"))
          (should (emacs-agent-gptel--live-p old-run))
          (should (emacs-agent-gptel--live-p new-run))
          (let ((fsm (emacs-agent-f2-spike--dry-fsm old-run)) (gptel-use-curl t))
            (gptel--parse-response
             (emacs-agent-run-backend old-run)
             '(:choices [(:message (:role "assistant" :content :null
                                    :tool_calls [(:id "old-effect" :type "function"
                                                 :function (:name "eval_elisp" :arguments "{\"expression\":\"(push 'old emacs-agent-conversation-test--effects)\"}"))])
                           :finish_reason "tool_calls")])
             (gptel-fsm-info fsm))
            (cl-letf (((symbol-function 'gptel-curl-get-response) #'ignore))
              (gptel--fsm-transition fsm 'TOOL)))
          (should (equal emacs-agent-conversation-test--effects '(old)))
          (should (cl-find 'tool (emacs-agent-session-messages old) :key (lambda (m) (plist-get m :role))))
          (should-not (cl-find 'tool (emacs-agent-session-messages new) :key (lambda (m) (plist-get m :role))))
          (should-error (emacs-agent-session-new))
          (should-error (emacs-agent-session-rename "busy"))
          (should-error (emacs-agent-session-clone))
          (emacs-agent-test--complete old-run "old done")
          (emacs-agent-test--complete new-run "new done")
          (let (shown)
            (cl-letf (((symbol-function 'pop-to-buffer) (lambda (buffer &rest _) (setq shown buffer))))
              (should (eq (emacs-agent-session-select (emacs-agent-session-id old)) old)))
            (should (eq shown (emacs-agent-session-log-buffer old))))
          (should (eq (emacs-agent-session-selected nil) old))
          (should-not (string-match-p "new goal" (prin1-to-string (emacs-agent-session-messages old))))
          (let ((copy (emacs-agent-session-clone "public copy")))
            (should (eq (emacs-agent-session-selected nil) copy))
            (should (eq (emacs-agent-session-last-source-buffer copy) source))
            (should (equal (emacs-agent-session-messages copy) (emacs-agent-session-messages old)))))))))

(ert-deftest emacs-agent-conversation-ask-captures-existing-target-before-minibuffer ()
  (emacs-agent-conversation-test--fixture
    (with-temp-buffer
      (let ((old (emacs-agent-session-get nil)) new run)
        (cl-letf (((symbol-function 'read-from-minibuffer)
                   (lambda (&rest _)
                     (setq new (emacs-agent-session--new nil "switched")) "captured target")))
          (setq run (emacs-agent-ask)))
        (should (eq (emacs-agent-run-session run) old))
        (should (eq (emacs-agent-session-selected nil) new))
        (should (emacs-agent-gptel--live-p run))
        (should-not (emacs-agent-session-messages new))))))

(ert-deftest emacs-agent-conversation-first-ask-rejects-a-changed-selection ()
  (emacs-agent-conversation-test--fixture
    (with-temp-buffer
      (let (new)
        (cl-letf (((symbol-function 'read-from-minibuffer)
                   (lambda (&rest _) (setq new (emacs-agent-session-get nil)) "do not retarget")))
          (should-error (emacs-agent-ask) :type 'user-error))
        (should-not (emacs-agent-session-messages new))
        (should-not emacs-agent-test--requests)))))

(ert-deftest emacs-agent-conversation-select-does-not-overwrite-minibuffer-choice-change ()
  (emacs-agent-conversation-test--fixture
    (with-temp-buffer
      (let* ((a (emacs-agent-session-get nil))
             (b (emacs-agent-session--new nil "b")) c)
        (emacs-agent-session--select a)
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_ choices &rest _)
                     (setq c (emacs-agent-session--new nil "reentrant"))
                     (car (cl-find b choices :key #'cdr)))))
          (should-error (emacs-agent-session-select) :type 'user-error))
        (should (eq (emacs-agent-session-selected nil) c))
        (should-not emacs-agent-test--requests)))))

(ert-deftest emacs-agent-conversation-mutation-lock-does-not-corrupt-recovery ()
  (emacs-agent-conversation-test--fixture
    (with-temp-buffer
      (let* ((session (emacs-agent-session-get nil))
             (run (emacs-agent-session-prepare session "recovery" nil (current-buffer) nil))
             (input (emacs-agent-input-prepare run 'ask)))
        (emacs-agent-input-withdraw input)
        (let ((before (copy-tree (emacs-agent-input-data input)))
              (emacs-agent-session--mutation t))
          (should-error (emacs-agent-input-resubmit input "changed") :type 'user-error)
          (should-error (emacs-agent-input-forget input) :type 'user-error)
          (should-error (emacs-agent-session-enqueue session "new" nil (current-buffer) nil) :type 'user-error)
          (should (equal before (emacs-agent-input-data input)))
          (should-not (emacs-agent-session-pending-runs session)))
        ;; Already accepted F2 conversions in OTHER conversations must still run.
        (let ((emacs-agent-session--mutation t))
          (should (eq (emacs-agent-input-prepare run 'ask) input)))))))

(ert-deftest emacs-agent-conversation-other-run-final-boundary-survives-mutation-lock ()
  (emacs-agent-conversation-test--fixture
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "other active conversation"))
             (session (emacs-agent-run-session run))
             (input (emacs-agent-input-queue-steer run "accepted steering" nil (current-buffer) nil))
             (project (emacs-agent-session-get (file-name-as-directory
                                               (expand-file-name "idle-project" emacs-agent-data-directory))))
             (save (symbol-function 'emacs-agent-store-save)) once)
        (cl-letf (((symbol-function 'emacs-agent-store-save)
                   (lambda (preview)
                     (prog1 (funcall save preview)
                       (unless once
                         (setq once t)
                         (should emacs-agent-session--mutation)
                         (emacs-agent-test--complete run "other run done"))))))
          (emacs-agent-session--rename project "renamed"))
        (let ((converted (emacs-agent-input-run input)))
          (push converted emacs-agent-test--runs)
          (should (eq (emacs-agent-session-active-run session) converted))
          (should (eq (emacs-agent-input-state input) 'delivered))
          (should-not (emacs-agent-session-pending-runs session))
          (should (equal (emacs-agent-session-name project) "renamed")))))))

(ert-deftest emacs-agent-conversation-clone-preserves-real-wire-without-authority ()
  (emacs-agent-conversation-test--fixture
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "old goal"))
             (old (emacs-agent-run-session run)))
        (emacs-agent-test--real-tools run)
        (emacs-agent-test--complete run "done")
        (setf (emacs-agent-session-compaction old)
              '(:cut 1 :summary "old goal summarized" :tokens-before 100
                :model "gpt-4o" :backend "agent-offline" :time 1))
        (let ((input (emacs-agent-input-prepare
                      (emacs-agent-session-prepare old "not delivered" nil (current-buffer) nil) 'ask)))
          (emacs-agent-input-withdraw input))
        (let* ((wire (mapcar (lambda (policy) (gptel--json-encode (emacs-agent-test--wire run policy))) '(nil current full)))
               (clone (cl-letf (((symbol-function 'emacs-agent-eval) (lambda (&rest _) (ert-fail "Clone executed Lisp"))))
                        (emacs-agent-session--clone old "copy")))
               (view (copy-emacs-agent-run run)))
          (setf (emacs-agent-run-session view) clone)
          (should (equal wire (mapcar (lambda (policy) (gptel--json-encode (emacs-agent-test--wire view policy))) '(nil current full))))
          (should (equal (plist-get (emacs-agent-session-provenance clone) :source-id) (emacs-agent-session-id old)))
          (should-not (emacs-agent-session-inputs clone))
          (should-not (emacs-agent-session-last-source-buffer clone))
          (should-not (emacs-agent-session-usage-anchor clone))
          (should-not (eq (emacs-agent-session-messages old) (emacs-agent-session-messages clone)))
          (should (cl-every (lambda (e) (equal (plist-get e :session-id) (emacs-agent-session-id clone)))
                            (emacs-agent-session-events clone)))
          (let ((new-run (emacs-agent-test--submit "continue clone")))
            (should (eq (emacs-agent-run-session new-run) clone))
            (should-not (equal (emacs-agent-run-id new-run) (emacs-agent-run-id run)))))))))

(ert-deftest emacs-agent-conversation-search-is-local-and-does-not-select ()
  (emacs-agent-conversation-test--fixture
    (with-temp-buffer
      (let* ((a (emacs-agent-session--new nil "alpha"))
             (run (emacs-agent-test--submit "rare-λ-history")))
        (emacs-agent-test--complete run "answer")
        (let ((b (emacs-agent-session-new "beta")))
          (cl-letf (((symbol-function 'gptel-request) (lambda (&rest _) (ert-fail "Search used model")))
                    ((symbol-function 'emacs-agent-eval) (lambda (&rest _) (ert-fail "Search evaluated history"))))
            (emacs-agent-session-search "rare-λ"))
          (with-current-buffer "*emacs-agent sessions*"
            (should (= (length tabulated-list-entries) 1))
            (should (equal (caar tabulated-list-entries) (emacs-agent-session-id a)))
            (goto-char (point-min))
            (emacs-agent-session-list-show))
          (should (eq (emacs-agent-session-selected nil) b))
          (should (string-match-p "alpha" (emacs-agent--session-name a)))
          (emacs-agent-session-search "")
          (with-current-buffer "*emacs-agent sessions*"
            (should (= (length tabulated-list-entries) 2))))))))

(defun emacs-agent-conversation-test--child (form)
  "Run trusted FORM in a fresh backend-free Emacs; read only its result data."
  (with-temp-buffer
    (let ((status (call-process (expand-file-name invocation-name invocation-directory)
                                nil (current-buffer) nil "-Q" "--batch" "-L"
                                (file-name-directory (locate-library "emacs-agent-store"))
                                "-l" "emacs-agent-store" "--eval" (prin1-to-string form))))
      (unless (zerop status) (ert-fail (buffer-string)))
      (goto-char (point-min))
      (read (current-buffer)))))

(ert-deftest emacs-agent-conversation-fresh-process-global-and-project-selection ()
  (emacs-agent-conversation-test--fixture
    (let* ((old (emacs-agent-session-get nil))
           (root (file-name-as-directory (expand-file-name "project" emacs-agent-data-directory)))
           (_project (emacs-agent-session-get root))
           (selected (emacs-agent-session--new root "project-selected")))
      (emacs-agent-store-save old)
      (let* ((form `(let ((emacs-agent-data-directory ,emacs-agent-data-directory))
                     (emacs-agent-store-load-all)
                     (let* ((unset (emacs-agent-session-selected nil))
                            (before (hash-table-count emacs-agent-session--registry))
                            (fresh (emacs-agent-session-get nil))
                            (again (emacs-agent-session-get nil))
                            (project (emacs-agent-session-get ,root)))
                       (load "emacs-agent-session" nil t)
                       (let ((same (eq fresh (emacs-agent-session-get nil)))
                             (project-id (emacs-agent-session-id project))
                             (old (gethash ,(emacs-agent-session-id old) emacs-agent-session--registry)))
                         (unless (= (hash-table-count emacs-agent-session--registry) (1+ before))
                           (error "Reload created a duplicate conversation"))
                         (emacs-agent-session--select old)
                         (prin1 (list (emacs-agent-session-id fresh) unset
                                      (null (emacs-agent-session-messages fresh)) (eq fresh again) same
                                      project-id (emacs-agent-session-id (emacs-agent-session-get nil))
                                      (featurep 'gptel)))))))
             (first (emacs-agent-conversation-test--child form))
             (second (emacs-agent-conversation-test--child form)))
        (should-not (equal (car first) (car second)))
        (dolist (result (list first second))
          (should-not (equal (car result) (emacs-agent-session-id old)))
          (should-not (nth 1 result))
          (should (nth 2 result)) (should (nth 3 result)) (should (nth 4 result))
          (should (equal (nth 5 result) (emacs-agent-session-id selected)))
          (should (equal (nth 6 result) (emacs-agent-session-id old)))
          (should-not (nth 7 result)))))))

;;; emacs-agent-conversation-test.el ends here
