;;; emacs-agent-resources-test.el --- Root-only instructions -*- lexical-binding: t; -*-
(require 'ert)
(require 'emacs-agent)
;; Loaded after adapter/history fixtures by the Makefile.
(defvar emacs-agent-resources-test--executed nil)

(defmacro emacs-agent-resources-test--project (&rest body)
  "Run BODY with disposable PARENT, ROOT and CHILD directories."
  (declare (indent 0) (debug t))
  `(let* ((parent (make-temp-file "agent-instructions-" t))
          (root (file-name-as-directory (expand-file-name "project" parent)))
          (child (expand-file-name "nested" root))
          (emacs-agent-project-instructions t)
          (comp-enable-subr-trampolines nil))
     (unwind-protect
         (progn (make-directory child t) ,@body)
       (delete-directory parent t))))

(defun emacs-agent-resources-test--write (root name text)
  "Write TEXT to ROOT/NAME as data, without visiting the file."
  (with-temp-file (expand-file-name name root) (insert text)))

(ert-deftest emacs-agent-resources-priority-selects-exactly-one ()
  (emacs-agent-resources-test--project
    (dolist (name emacs-agent-resources--instruction-names)
      (emacs-agent-resources-test--write root name (concat "RULE " name)))
    (dolist (name emacs-agent-resources--instruction-names)
      (let ((snapshot (emacs-agent-resources-capture root)))
        (should (eq (plist-get snapshot :status) 'loaded))
        (should (equal (plist-get snapshot :path) (expand-file-name name root)))
        (should (equal (plist-get snapshot :text) (concat "RULE " name)))
        (delete-file (plist-get snapshot :path))))
    (should (eq (plist-get (emacs-agent-resources-capture root) :status) 'missing))))

(ert-deftest emacs-agent-resources-no-global-parent-or-child-discovery ()
  (emacs-agent-resources-test--project
    (emacs-agent-resources-test--write parent "AGENTS.md" "PARENT")
    (emacs-agent-resources-test--write child "AGENTS.md" "CHILD")
    (emacs-agent-resources-test--write parent "EMACSAGENT.md" "PARENT-AGENT")
    (emacs-agent-resources-test--write child "EMACSAGENT.md" "CHILD-AGENT")
    (let ((default-directory (file-name-as-directory child)) (checked nil)
          (exists (symbol-function 'file-exists-p)))
      (cl-letf (((symbol-function 'file-exists-p)
                 (lambda (path) (push path checked) (funcall exists path))))
        (should (eq (plist-get (emacs-agent-resources-capture root) :status) 'missing)))
      (should (= (length checked) 6))
      (dolist (path checked) (should (equal (file-name-directory path) root))))))

(ert-deftest emacs-agent-resources-disabled-and-no-project-do-no-io ()
  (let ((comp-enable-subr-trampolines nil))
    (cl-letf (((symbol-function 'file-exists-p) (lambda (&rest _) (ert-fail "Unexpected I/O")))
              ((symbol-function 'file-symlink-p) (lambda (&rest _) (ert-fail "Unexpected I/O"))))
      (let ((emacs-agent-project-instructions nil))
        (should (eq (plist-get (emacs-agent-resources-capture "/unused/") :status) 'disabled)))
      (let ((emacs-agent-project-instructions t))
        (should (eq (plist-get (emacs-agent-resources-capture nil) :status) 'no-project))))))

(ert-deftest emacs-agent-resources-empty-override-does-not-fall-back ()
  (emacs-agent-resources-test--project
    (emacs-agent-resources-test--write root "AGENTS.override.md" "")
    (emacs-agent-resources-test--write root "AGENTS.md" "FALLBACK")
    (let ((snapshot (emacs-agent-resources-capture root)))
      (should (eq (plist-get snapshot :status) 'loaded))
      (should (equal (plist-get snapshot :text) ""))
      (should-not (string-match-p "FALLBACK" (emacs-agent-resources-system "BASE" snapshot))))))

(ert-deftest emacs-agent-resources-bad-candidates-warn-without-fallback ()
  (emacs-agent-resources-test--project
    (let ((path (expand-file-name "AGENTS.override.md" root)))
      (emacs-agent-resources-test--write root "AGENTS.md" "FALLBACK")
      (make-directory path)
      (let ((snapshot (emacs-agent-resources-capture root)))
        (should (eq (plist-get snapshot :status) 'error))
        (should (equal (plist-get snapshot :path) path))
        (should (plist-get snapshot :warnings))
        (should (equal (emacs-agent-resources-system "BASE" snapshot) "BASE")))
      (delete-directory path)
      (make-symbolic-link "missing-target" path)
      (should (eq (plist-get (emacs-agent-resources-capture root) :status) 'error))
      (delete-file path)
      (emacs-agent-resources-test--write root "AGENTS.override.md" "unreadable")
      (let ((reader (symbol-function 'insert-file-contents)))
        (cl-letf (((symbol-function 'insert-file-contents)
                   (lambda (file &rest args)
                     (if (equal file path) (signal 'file-error '("permission denied"))
                       (apply reader file args)))))
          (let ((snapshot (emacs-agent-resources-capture root)))
            (should (eq (plist-get snapshot :status) 'error))
            (should (equal (plist-get snapshot :warnings) '("permission denied")))
            (should-not (plist-get snapshot :text))))))))

(ert-deftest emacs-agent-resources-reads-disk-as-data-preserves-editor ()
  (emacs-agent-resources-test--project
    (let ((text "# Привет \"quoted\"\nLocal Variables:\neval: (setq emacs-agent-resources-test--executed t)\nEnd:\n")
          (emacs-agent-resources-test--executed nil))
      (emacs-agent-resources-test--write parent "external.md" text)
      (make-symbolic-link (expand-file-name "external.md" parent) (expand-file-name "AGENTS.md" root))
      (with-temp-buffer
        ;; An unsaved instruction buffer must not replace saved contents.
        (setq buffer-file-name (expand-file-name "AGENTS.md" root))
        (insert "UNSAVED") (narrow-to-region 2 5) (goto-char 3) (set-mark 4)
        (let* ((state (list (point) (mark) (point-min) (point-max) (buffer-string)))
               (snapshot (emacs-agent-resources-capture root)))
          (should (equal (plist-get snapshot :text) text))
          (should (equal state (list (point) (mark) (point-min) (point-max) (buffer-string))))
          (should-not emacs-agent-resources-test--executed))))))

(ert-deftest emacs-agent-resources-fifo-frozen-wire-independent-of-context ()
  (emacs-agent-test-adapter
    (emacs-agent-resources-test--project
      (with-temp-buffer
        (let ((emacs-agent-context-history nil))
          (emacs-agent-resources-test--write root "AGENTS.md" "RULE-A")
          (emacs-agent-resources-test--write root "EMACSAGENT.md" "AGENT-A")
          (let* ((first (emacs-agent-test--submit "first" root))
                 (first-system (plist-get (car emacs-agent-test--requests) :system)))
            (emacs-agent-resources-test--write root "AGENTS.md" "RULE-B\n\"quoted\"\n")
            (emacs-agent-resources-test--write root "EMACSAGENT.md" "AGENT-B")
            (let* ((second (emacs-agent-test--submit "second" root))
                   (snapshot (copy-tree (emacs-agent-run-instructions second)))
                   (emacs-agent-project-instructions nil))
              (emacs-agent-resources-test--write root "AGENTS.override.md" "RULE-C")
              (emacs-agent-resources-test--write root "EMACSAGENT.md" "AGENT-C")
              (should (string-match-p "RULE-A" first-system))
              (emacs-agent-test--complete first "first answer")
              (let* ((system (plist-get (car emacs-agent-test--requests) :system))
                     (data (emacs-agent-test--wire second nil))
                     (messages (append (plist-get data :messages) nil)))
                (should (string-prefix-p emacs-agent-system-prompt system))
                (should (string-match-p "RULE-B" system))
                (should (string-match-p "AGENT-B" system))
                (should (< (string-match "RULE-B" system)
                           (string-match "\nAGENT-B" system)))
                (should-not (string-match-p "RULE-A\\|RULE-C\\|AGENT-A\\|AGENT-C"
                                             (substring system (length emacs-agent-system-prompt))))
                (should (equal system (plist-get (car messages) :content)))
                (should (equal (plist-get (car messages) :role) "system"))
                (should (equal (plist-get (car (last messages)) :content) "second"))
                (should-not (string-match-p "emacs-context" (plist-get (car (last messages)) :content))))
              (should (equal snapshot (emacs-agent-run-instructions second)))
              (should (equal (mapcar (lambda (m) (plist-get m :text))
                                    (cl-remove-if-not (lambda (m) (eq (plist-get m :role) 'user))
                                                      (emacs-agent-session-messages (emacs-agent-run-session first))))
                             '("first" "second"))))))))))

(ert-deftest emacs-agent-resources-ask-uses-original-source-opt-out ()
  (emacs-agent-test-with-registry
    (emacs-agent-resources-test--project
      (let ((other (generate-new-buffer " *instructions-other*")))
        (unwind-protect
            (with-temp-buffer
              (setq-local emacs-agent-project-instructions nil)
              (emacs-agent-resources-test--write root "AGENTS.md" "RULE")
              (cl-letf (((symbol-function 'emacs-agent-session-resolve-root) (lambda () root))
                        ((symbol-function 'read-from-minibuffer)
                         (lambda (&rest _) (set-buffer other) "user")))
                (let ((run (emacs-agent-ask)))
                  (should (eq (plist-get (emacs-agent-run-instructions run) :status) 'disabled)))))
          (kill-buffer other))))))

(ert-deftest emacs-agent-resources-capture-at-submit-keeps-preinput-editor-context ()
  (emacs-agent-test-with-registry
    (emacs-agent-resources-test--project
      (with-temp-buffer
        (insert "source text") (goto-char 3)
        (emacs-agent-resources-test--write root "AGENTS.md" "BEFORE")
        (cl-letf (((symbol-function 'emacs-agent-session-resolve-root) (lambda () root))
                  ((symbol-function 'read-from-minibuffer)
                   (lambda (&rest _)
                     (goto-char (point-max))
                     (emacs-agent-resources-test--write root "AGENTS.md" "AT-SUBMIT")
                     "user")))
          (let ((run (emacs-agent-ask)))
            (should (= (plist-get (emacs-agent-run-editor-context run) :point) 3))
            (should (equal (plist-get (emacs-agent-run-instructions run) :text) "AT-SUBMIT"))))))))

(ert-deftest emacs-agent-resources-view-requires-submitted-snapshot ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let ((session (emacs-agent-session-get nil)))
        (with-current-buffer (emacs-agent--log-buffer session)
          (should-error (emacs-agent-show-instructions) :type 'user-error))))))

(ert-deftest emacs-agent-resources-tool-continuation-keeps-system-snapshot ()
  (emacs-agent-test-adapter
    (emacs-agent-resources-test--project
      (with-temp-buffer
        (emacs-agent-register-helper 'emacs-agent-buffer-info
                                    :description "FROZEN-HELPER" :returns "Metadata plist.")
        (emacs-agent-resources-test--write root "AGENTS.md" "FROZEN-RULE")
        (emacs-agent-resources-test--write root "EMACSAGENT.md" "FROZEN-AGENT")
        (let* ((run (emacs-agent-test--submit "use one tool" root))
               (system (plist-get (car emacs-agent-test--requests) :system))
               (fsm (emacs-agent-run-request-handle run))
               next-data)
          (with-current-buffer (emacs-agent-run-transport-buffer run)
            (funcall emacs-agent-test--real-request (emacs-agent-gptel--history run)
                     :system system :dry-run t :fsm fsm :stream nil :transforms '(ignore)
                     :callback (apply-partially #'emacs-agent-gptel--callback run)))
          (gptel--parse-response
           (emacs-agent-run-backend run)
           '(:choices [(:message (:role "assistant" :content :null
                                 :tool_calls [(:id "instruction-tool" :type "function"
                                               :function (:name "eval_elisp"
                                                          :arguments "{\"expression\":\"(+ 1 1)\"}"))])
                        :finish_reason "tool_calls")])
           (gptel-fsm-info fsm))
          (emacs-agent-resources-test--write root "AGENTS.md" "CHANGED-RULE")
          (emacs-agent-resources-test--write root "EMACSAGENT.md" "CHANGED-AGENT")
          (emacs-agent-register-helper 'emacs-agent-buffer-info
                                      :description "CHANGED-HELPER" :returns "Metadata plist.")
          (let ((gptel-use-curl t) (emacs-agent-project-instructions nil))
            (cl-letf (((symbol-function 'gptel-curl-get-response)
                       (lambda (next-fsm) (setq next-data (copy-tree (plist-get (gptel-fsm-info next-fsm) :data))))))
              (gptel--fsm-transition fsm 'TOOL)))
          (should (= (emacs-agent-run-tool-count run) 1))
          (let* ((messages (append (plist-get next-data :messages) nil))
                 (systems (cl-remove-if-not (lambda (m) (equal (plist-get m :role) "system")) messages)))
            (should (= (length systems) 1))
            (should (equal (plist-get (car systems) :content) system))
            (should (string-match-p "FROZEN-AGENT" system))
            (should (string-match-p "FROZEN-HELPER" system))
            (should-not (string-match-p "CHANGED-RULE\\|CHANGED-AGENT\\|CHANGED-HELPER"
                                        (plist-get (car systems) :content)))))))))

(ert-deftest emacs-agent-resources-warning-visible-after-restore ()
  (emacs-agent-test-adapter
    (emacs-agent-resources-test--project
      (with-temp-buffer
        (make-directory (expand-file-name "AGENTS.md" root))
        (let* ((run (emacs-agent-test--submit "warn" root))
               (session (emacs-agent-run-session run)) view)
          (unwind-protect
              (progn
                (should (equal (plist-get (car emacs-agent-test--requests) :system)
                               emacs-agent-system-prompt))
                (emacs-agent-store-save session)
                (remhash (emacs-agent-session-id session) emacs-agent-session--registry)
                (remhash root emacs-agent-session--selected)
                (let ((restored (emacs-agent-session-get root)))
                  (emacs-agent--render-log restored)
                  (with-current-buffer (emacs-agent-session-log-buffer restored)
                    (should (string-match-p "not a regular file" (buffer-string)))
                    (cl-letf (((symbol-function 'display-buffer) #'ignore))
                      (setq view (emacs-agent-show-instructions))))
                  (with-current-buffer view
                    (should (string-match-p "not a regular file" (buffer-string)))
                    (should (string-match-p "Project instructions: error" (buffer-string))))))
            (when (buffer-live-p view) (kill-buffer view))))))))

(ert-deftest emacs-agent-resources-snapshot-survives-pending-restart-and-view ()
  (emacs-agent-test-adapter
    (emacs-agent-resources-test--project
      (with-temp-buffer
        (emacs-agent-resources-test--write root "AGENTS.md" "RULE-A")
        (emacs-agent-resources-test--write root "EMACSAGENT.md" "AGENT-A")
        (let* ((first (emacs-agent-test--submit "first" root))
               (session (emacs-agent-run-session first))
               view)
          (unwind-protect
              (progn
                (emacs-agent-resources-test--write root "AGENTS.md" "RULE-B")
                (emacs-agent-resources-test--write root "EMACSAGENT.md" "AGENT-B")
                (emacs-agent-test--submit "second" root)
                (with-current-buffer (emacs-agent--log-buffer session)
                  (cl-letf (((symbol-function 'display-buffer) #'ignore))
                    (setq view (emacs-agent-show-instructions))))
                (with-current-buffer view
                  (should buffer-read-only)
                  (should-not (buffer-modified-p))
                  (should (string-match-p "RULE-A" (buffer-string)))
                  (should-not (string-match-p "RULE-B" (buffer-string)))
                  (should (string-match-p "AGENT-A" (buffer-string)))
                  (should-not (string-match-p "AGENT-B" (buffer-string))))
                (emacs-agent-store-save session)
                (emacs-agent-resources-test--write root "AGENTS.md" "RULE-C")
                (emacs-agent-resources-test--write root "EMACSAGENT.md" "AGENT-C")
                (remhash (emacs-agent-session-id session) emacs-agent-session--registry)
                (remhash root emacs-agent-session--selected)
                (cl-letf (((symbol-function 'emacs-agent-resources-capture)
                           (lambda (&rest _) (ert-fail "Restore reread instructions"))))
                  (let* ((restored (emacs-agent-session-get root))
                         (saved (cl-loop for e in (emacs-agent-session-events restored)
                                         when (eq (plist-get e :type) 'interrupted)
                                         collect (plist-get (plist-get e :saved-run) :instructions))))
                    (should (equal (mapcar (lambda (s) (plist-get s :text)) saved) '("RULE-A" "RULE-B")))
                    (should (equal (mapcar (lambda (s) (plist-get (plist-get s :emacsagent) :text)) saved)
                                   '("AGENT-A" "AGENT-B")))
                    (with-current-buffer (emacs-agent--log-buffer restored)
                      (cl-letf (((symbol-function 'display-buffer) #'ignore))
                        (setq view (emacs-agent-show-instructions))))
                    (with-current-buffer view
                      (should (string-match-p "RULE-B" (buffer-string)))
                      (should-not (string-match-p "RULE-C" (buffer-string)))
                      (should (string-match-p "AGENT-B" (buffer-string)))
                      (should-not (string-match-p "AGENT-C" (buffer-string))))))
                (let* ((next (emacs-agent-test--submit "after restart" root))
                       (messages (plist-get (emacs-agent-test--wire next nil) :messages))
                       (system (plist-get (aref messages 0) :content)))
                  (should (string-match-p "RULE-C" system))
                  (should (string-match-p "AGENT-C" system))
                  (should-not (string-match-p "RULE-A\\|RULE-B\\|AGENT-A\\|AGENT-B"
                                               (substring system (length emacs-agent-system-prompt))))))
            (when (buffer-live-p view) (kill-buffer view))
            (when (buffer-live-p (emacs-agent-session-log-buffer session))
              (kill-buffer (emacs-agent-session-log-buffer session)))))))))

(ert-deftest emacs-agent-resources-emacsagent-appends-after-common-priority ()
  (emacs-agent-resources-test--project
    (emacs-agent-resources-test--write root "EMACSAGENT.md" "SPECIFIC")
    (dolist (name emacs-agent-resources--instruction-names)
      (emacs-agent-resources-test--write root name (concat "COMMON " name)))
    (dolist (name emacs-agent-resources--instruction-names)
      (let* ((snapshot (emacs-agent-resources-capture root))
             (agent (plist-get snapshot :emacsagent))
             (system (emacs-agent-resources-system "BASE" snapshot)))
        (should (equal (plist-get snapshot :path) (expand-file-name name root)))
        (should (eq (plist-get agent :status) 'loaded))
        (should (equal (plist-get agent :path) (expand-file-name "EMACSAGENT.md" root)))
        (should (equal system (format "BASE\n\nProject instructions from %S:\nCOMMON %s\n\nProject instructions from %S:\nSPECIFIC"
                                     (plist-get snapshot :path) name (plist-get agent :path))))
        (should (string-match-p "EMACSAGENT.md" (emacs-agent-resources-summary snapshot)))
        (delete-file (plist-get snapshot :path))))))

(ert-deftest emacs-agent-resources-emacsagent-standalone-saved-data ()
  (emacs-agent-resources-test--project
    (let ((emacs-agent-resources-test--executed nil)
          (text "λ\nLocal Variables:\neval: (setq emacs-agent-resources-test--executed t)\nEnd:\n"))
      (emacs-agent-resources-test--write root "EMACSAGENT.md" text)
      (with-temp-buffer
        (setq buffer-file-name (expand-file-name "EMACSAGENT.md" root))
        (insert "UNSAVED")
        (let* ((snapshot (emacs-agent-resources-capture root))
               (agent (plist-get snapshot :emacsagent)))
          (should (eq (plist-get snapshot :status) 'missing))
          (should (equal (plist-get agent :text) text))
          (should (string-suffix-p text (emacs-agent-resources-system "BASE" snapshot)))
          (should (equal (buffer-string) "UNSAVED"))
          (should-not emacs-agent-resources-test--executed))))))

(ert-deftest emacs-agent-resources-emacsagent-errors-are-independent ()
  (emacs-agent-resources-test--project
    (let ((path (expand-file-name "EMACSAGENT.md" root)))
      (emacs-agent-resources-test--write root "AGENTS.md" "COMMON")
      (make-directory path)
      (let* ((snapshot (emacs-agent-resources-capture root))
             (system (emacs-agent-resources-system "BASE" snapshot)))
        (should (eq (plist-get snapshot :status) 'loaded))
        (should (eq (plist-get (plist-get snapshot :emacsagent) :status) 'error))
        (should (string-match-p "COMMON" system))
        (should (string-match-p "not a regular file" (emacs-agent-resources-summary snapshot))))
      (delete-directory path)
      (make-symbolic-link "missing-target" path)
      (should (eq (plist-get (plist-get (emacs-agent-resources-capture root) :emacsagent) :status) 'error))
      (delete-file path)
      (emacs-agent-resources-test--write root "EMACSAGENT.md" "SPECIFIC")
      (let ((reader (symbol-function 'insert-file-contents)))
        (cl-letf (((symbol-function 'insert-file-contents)
                   (lambda (file &rest args)
                     (if (equal file path) (signal 'file-error '("permission denied"))
                       (apply reader file args)))))
          (let ((snapshot (emacs-agent-resources-capture root)))
            (should (equal (plist-get (plist-get snapshot :emacsagent) :warnings)
                           '("permission denied")))
            (should (string-match-p "COMMON" (emacs-agent-resources-system "BASE" snapshot))))))
      ;; A bad common override does not suppress independent agent instructions.
      (make-directory (expand-file-name "AGENTS.override.md" root))
      (let ((snapshot (emacs-agent-resources-capture root)))
        (should (eq (plist-get snapshot :status) 'error))
        (should (string-match-p "SPECIFIC" (emacs-agent-resources-system "BASE" snapshot)))
        (should-not (string-match-p "COMMON" (emacs-agent-resources-system "BASE" snapshot))))
      (delete-directory (expand-file-name "AGENTS.override.md" root))
      (emacs-agent-resources-test--write root "AGENTS.override.md" "")
      (let ((system (emacs-agent-resources-system "BASE" (emacs-agent-resources-capture root))))
        (should (string-match-p "SPECIFIC" system))
        (should-not (string-match-p "COMMON" system))))))

(ert-deftest emacs-agent-resources-emacsagent-pending-validation ()
  (let* ((agent '(:status loaded :root "/project/" :path "/project/EMACSAGENT.md"
                         :text "SPECIFIC" :warnings nil))
         (snapshot (list :status 'missing :root "/project/" :path nil :text nil
                         :warnings nil :emacsagent agent)))
    (emacs-agent-input--validate-instructions snapshot)
    (dolist (bad (list 42 '(:status loaded :text 42)
                       '(:status error :text "not allowed")
                       '(:status loaded :text "ok" :warnings (42))
                       '(:status loaded :text "ok" :unknown t)
                       (append agent (list :emacsagent agent))
                       (append agent '(:text "duplicate"))))
      (let ((copy (copy-tree snapshot)))
        (plist-put copy :emacsagent bad)
        (should-error (emacs-agent-input--validate-instructions copy))))))

;;; emacs-agent-resources-test.el ends here
