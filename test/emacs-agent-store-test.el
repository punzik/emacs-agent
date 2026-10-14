;;; emacs-agent-store-test.el --- Disk persistence without live LLM -*- lexical-binding: t; -*-
(require 'ert)
(require 'emacs-agent)
(defvar emacs-agent-test--executed nil)

(defmacro emacs-agent-test-store (&rest body)
  "Run BODY in a temporary store with an isolated registry."
  (declare (indent 0) (debug t))
  `(let ((emacs-agent-data-directory (make-temp-file "agent-store-test-" t))
         (emacs-agent-auto-save nil)
         (emacs-agent-session--registry (make-hash-table :test #'equal))
         (emacs-agent-session--counter 0)
         (emacs-agent-session-event-functions nil)
         (emacs-agent-store--last-save (make-hash-table :test #'eq)))
     (unwind-protect (progn ,@body)
       (maphash (lambda (_ session)
                  (when (buffer-live-p (emacs-agent-session-log-buffer session))
                    (kill-buffer (emacs-agent-session-log-buffer session))))
                emacs-agent-session--registry)
       (delete-directory emacs-agent-data-directory t))))

(defun emacs-agent-test-store--text (file)
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun emacs-agent-test-store--write (file data)
  (with-temp-buffer (insert data) (write-region (point-min) (point-max) file nil 'silent)))

(ert-deftest emacs-agent-store-roundtrip-and-lazy-project-mapping ()
  (emacs-agent-test-store
    (let* ((root "/tmp/same-name/project/")
           (session (emacs-agent-session-get root))
           (messages '((:role user :run-id "run-10" :text "user"
                        :context (:buffer "source" :file nil))
                       (:role tool :run-id "run-10" :id "call-original" :name "eval_elisp"
                        :args (:expression "(+ 1 1)") :result "=> 2"
                        :protocol (:reasoning_content "provider text"))
                       (:role assistant :run-id "run-10" :text "two"))))
      (setf (emacs-agent-session-messages session) messages)
      (emacs-agent-session-record (make-emacs-agent-run :id "run-10" :session session)
                                  'completed "Done")
      (let ((file (emacs-agent-store-save session)))
        (should (= (logand (file-modes file) #o777) #o600))
        (setq emacs-agent-session--registry (make-hash-table :test #'equal)
              emacs-agent-session--counter 0)
        (let ((restored (emacs-agent-session-get root)))
          (should-not (eq restored session))
          (should (equal (emacs-agent-session-id restored) (emacs-agent-session-id session)))
          (should (equal (emacs-agent-session-messages restored) messages))
          (should (equal (emacs-agent-session-project-root restored) root))
          (should-not (emacs-agent-session-active-run restored))
          (should-not (emacs-agent-session-pending-runs restored))
          (should-not (emacs-agent-session-last-source-buffer restored))
          (should (>= emacs-agent-session--counter 10))
          (should (eq restored (emacs-agent-session-get root))))))))

(ert-deftest emacs-agent-store-interrupted-partial-and-queue-never-resume ()
  (emacs-agent-test-store
    (let ((source (generate-new-buffer " *durable-agent-source*")))
      (unwind-protect
          (with-current-buffer source
            (let* ((session (emacs-agent-session-get nil))
                   (active (emacs-agent-session-enqueue session "active" nil source nil))
                   (pending (emacs-agent-session-enqueue session "pending" nil source nil)))
              (setf (emacs-agent-session-pending-runs session) (list pending)
                    (emacs-agent-session-active-run session) active
                    (emacs-agent-run-status active) 'streaming
                    (emacs-agent-run-backend active) '(:key "SECRET-API-KEY")
                    (emacs-agent-run-request-handle active) (lambda () (error "do not persist"))
                    (emacs-agent-run-transport-buffer active) source
                    (emacs-agent-run-model active) 'main
                    (emacs-agent-run-assistant-chunks active) '("tail" "head"))
              (emacs-agent-session-record active 'user "active"
                                         (list :role 'user :run-id (emacs-agent-run-id active) :text "active"))
              (let* ((chunks (copy-tree (emacs-agent-run-assistant-chunks active)))
                     (file (emacs-agent-store-save session)))
                (should (equal chunks (emacs-agent-run-assistant-chunks active)))
                (should-not (string-match-p "SECRET-API-KEY\\|#<" (emacs-agent-test-store--text file)))
                (kill-buffer source)
                (setq emacs-agent-session--registry (make-hash-table :test #'equal))
                (let ((restored (emacs-agent-session-get nil)))
                  (should-not (emacs-agent-session-active-run restored))
                  (should-not (emacs-agent-session-pending-runs restored))
                  (should-not (emacs-agent-session-last-source-buffer restored))
                  (should (equal (plist-get (car (last (emacs-agent-session-messages restored))) :text) "headtail"))
                  (should (= (cl-count-if (lambda (event) (eq (plist-get event :type) 'interrupted))
                                         (emacs-agent-session-events restored)) 2))
                  (should (seq-some (lambda (event) (plist-get event :saved-run))
                                    (emacs-agent-session-events restored)))
                  ;; Future saves retain the interruption audit, not executable queues.
                  (emacs-agent-store-save restored)))))
        (when (buffer-live-p source) (kill-buffer source))))))

(ert-deftest emacs-agent-store-atomic-failure-keeps-old-file-and-cleans-temp ()
  (emacs-agent-test-store
    (let* ((session (emacs-agent-session-get nil))
           (file (emacs-agent-store-save session))
           (old (emacs-agent-test-store--text file)))
      (setf (emacs-agent-session-updated-at session) 123)
      (cl-letf (((symbol-function 'rename-file)
                 (lambda (&rest _) (signal 'file-error '("injected rename failure")))))
        (should-error (emacs-agent-store-save session) :type 'file-error))
      (should (equal old (emacs-agent-test-store--text file)))
      (should-not (directory-files emacs-agent-data-directory nil "\\`\\.snapshot-")))))

(ert-deftest emacs-agent-store-corrupt-file-is-isolated-and-never-overwritten ()
  (emacs-agent-test-store
    (let* ((global (emacs-agent-session-get nil))
           (good (emacs-agent-session-get "/tmp/good/"))
           (bad-file (emacs-agent-store-save global))
           (warnings 0))
      (emacs-agent-store-save good)
      (emacs-agent-test-store--write bad-file "(:schema")
      (setq emacs-agent-session--registry (make-hash-table :test #'equal))
      (cl-letf (((symbol-function 'display-warning) (lambda (&rest _) (cl-incf warnings))))
        (emacs-agent-store-load-all))
      (should (= warnings 1))
      (should (gethash "/tmp/good/" emacs-agent-session--registry))
      (should-not (gethash 'global emacs-agent-session--registry))
      (should-error (emacs-agent-session-get nil) :type 'user-error)
      (should (equal (emacs-agent-test-store--text bad-file) "(:schema")))))

(ert-deftest emacs-agent-store-schema-and-data-reader-do-not-evaluate-code ()
  (emacs-agent-test-store
    (let* ((session (emacs-agent-session-get nil))
           (file (emacs-agent-store-save session))
           (data (emacs-agent-store--snapshot session))
           (emacs-agent-test--executed nil))
      (setq emacs-agent-session--registry (make-hash-table :test #'equal))
      (emacs-agent-test-store--write file "(progn (setq emacs-agent-test--executed t))")
      (should-error (emacs-agent-session-get nil) :type 'user-error)
      (should-not emacs-agent-test--executed)
      (plist-put data :schema 999)
      (emacs-agent-test-store--write file (prin1-to-string data))
      (should-error (emacs-agent-session-get nil) :type 'user-error)
      (should (= (hash-table-count emacs-agent-session--registry) 0)))))

(ert-deftest emacs-agent-store-rejects-live-objects-and-cycles ()
  (emacs-agent-test-store
    (should-error (emacs-agent-store--data (current-buffer)))
    (should-error (emacs-agent-store--data (point-marker)))
    (should-error (emacs-agent-store--data (lambda () nil)))
    (let ((cycle (list 'x)))
      (setcdr cycle cycle)
      (should-error (emacs-agent-store--data cycle)))
    (should (equal (emacs-agent-store--data (propertize "text" 'keymap (make-sparse-keymap))) "text"))))

(ert-deftest emacs-agent-store-autosave-survives-broken-renderer ()
  (emacs-agent-test-store
    (let* ((session (emacs-agent-session-get nil))
           (run (make-emacs-agent-run :id "run-10" :session session))
           (emacs-agent-auto-save t)
           (emacs-agent-session-event-functions
            (list (lambda (&rest _) (signal 'quit nil)) #'emacs-agent-store--auto-save)))
      (emacs-agent-session-record run 'completed "Done")
      (should (file-exists-p (emacs-agent-store--file 'global))))))

(ert-deftest emacs-agent-store-remote-root-restores-without-opening-files ()
  (emacs-agent-test-store
    (let* ((root "/ssh:example:/work/project/")
           (session (emacs-agent-session-get root)))
      (emacs-agent-store-save session)
      (setq emacs-agent-session--registry (make-hash-table :test #'equal))
      (cl-letf (((symbol-function 'find-file-noselect) (lambda (&rest _) (ert-fail "File auto-opened"))))
        (should (equal (emacs-agent-session-project-root (emacs-agent-session-get root)) root))))))

(ert-deftest emacs-agent-store-restored-tool-history-replays-and-old-callback-is-stale ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "persist tools"))
             (session (emacs-agent-run-session run)))
        (emacs-agent-test--real-tools run)
        (emacs-agent-test--complete run "two and four")
        (emacs-agent-store-save session)
        (setq emacs-agent-session--registry (make-hash-table :test #'equal))
        (let* ((restored (emacs-agent-session-get nil))
               (events (copy-tree (emacs-agent-session-events restored)))
               (next (emacs-agent-test--submit "continue")))
          ;; Even an old object deliberately changed back to requesting cannot
          ;; receive callbacks after registry replacement.
          (setf (emacs-agent-run-status run) 'requesting
                (emacs-agent-session-active-run session) run)
          (emacs-agent-gptel--callback run "stale" nil)
          (should (equal events (seq-take (emacs-agent-session-events restored) (length events))))
          (should-not (emacs-agent-run-assistant-chunks run))
          (let ((wire (prin1-to-string (emacs-agent-test--wire next 'current))))
            (should (string-match-p "pair-1" wire))
            (should (string-match-p "pair-2" wire))
            (should (string-match-p "actual protocol reasoning" wire))))))))

(ert-deftest emacs-agent-store-session-list-loads-and-shows-restored-journal ()
  (emacs-agent-test-store
    (let ((session (emacs-agent-session-get nil)))
      (emacs-agent-store-save session)
      (setq emacs-agent-session--registry (make-hash-table :test #'equal))
      (with-temp-buffer
        (emacs-agent-session-list-mode)
        (emacs-agent-session-list--entries)
        (tabulated-list-print t)
        (should (= (length tabulated-list-entries) 1))
        (goto-char (point-min))
        (cl-letf (((symbol-function 'display-buffer) #'ignore))
          (emacs-agent-session-list-show))
        (should (buffer-live-p (emacs-agent-session-log-buffer
                               (gethash 'global emacs-agent-session--registry))))))))

(ert-deftest emacs-agent-store-save-rejects-cycles-before-copying-and-keeps-file ()
  (emacs-agent-test-store
    (let* ((session (emacs-agent-session-get nil))
           (file (emacs-agent-store-save session))
           (old (emacs-agent-test-store--text file))
           (cycle (list '(:role user :run-id "run" :text "bad"))))
      (setcdr cycle cycle)
      (setf (emacs-agent-session-messages session) cycle)
      (should-error (emacs-agent-store-save session))
      (should (equal old (emacs-agent-test-store--text file)))
      (setf (emacs-agent-session-messages session) nil
            (emacs-agent-session-pending-runs session) cycle)
      (should-error (emacs-agent-store-save session))
      (setf (emacs-agent-session-pending-runs session) nil
            (emacs-agent-session-active-run session)
            (make-emacs-agent-run :id "run" :session session :user-text "bad"
                                  :model (current-buffer)))
      (should-error (emacs-agent-store-save session))
      (should (equal old (emacs-agent-test-store--text file))))))

;;; emacs-agent-store-test.el ends here
