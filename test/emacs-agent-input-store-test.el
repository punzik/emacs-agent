;;; emacs-agent-input-store-test.el --- Inert input persistence -*- lexical-binding: t; -*-
(require 'ert)
(require 'emacs-agent-store)

(defmacro emacs-agent-input-store-test--isolated (&rest body)
  "Run BODY with a disposable store and no user sessions or event hooks."
  (declare (indent 0) (debug t))
  `(let* ((private (make-temp-file "agent-input-store-" t))
          (emacs-agent-data-directory (expand-file-name "data/" private))
          (emacs-agent-auto-save nil)
          (emacs-agent-session--registry (make-hash-table :test #'equal))
          (emacs-agent-session--counter 0)
          (emacs-agent-session-event-functions nil)
          (emacs-agent-store--last-save (make-hash-table :test #'eq)))
     (unwind-protect (progn ,@body) (delete-directory private t))))

(defun emacs-agent-input-store-test--session ()
  "Construct an unregistered private session without opening any buffers."
  (make-emacs-agent-session :id "session-1" :key 'global :updated-at 1))

(defun emacs-agent-input-store-test--input (session id run-id kind state &optional target source)
  "Construct a frozen input fixture, without preparing or submitting a request."
  (let* ((backend (make-hash-table))
         (run (make-emacs-agent-run
               :id run-id :session session :user-text (concat "frozen " id)
               :editor-context '(:buffer "fixture" :point 7)
               :source-buffer source :model 'fixture-model :stream t
               :context-policy 'current :tool-budget 4
               :instructions '(:status loaded :root nil :path "/fixture/AGENTS.md"
                                :text "frozen instructions" :warnings nil)))
         (input (make-emacs-agent-input
                 :id id :run run :kind kind :state state :target-id target
                 :reason (and (eq state 'withdrawn) 'failed)
                 :backend-name "fixture-backend"
                 :source (when source (list :name (buffer-name source)
                                            :file (buffer-local-value 'buffer-file-name source))))))
    (puthash "api-key" "NEVER-SAVE-THIS-SECRET" backend)
    (setf (emacs-agent-run-backend run) backend
          (emacs-agent-run-input run) input
          (emacs-agent-session-inputs session)
          (append (emacs-agent-session-inputs session) (list input)))
    input))

(defun emacs-agent-input-store-test--read-text (file)
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun emacs-agent-input-store-test--write-data (file data)
  (with-temp-buffer
    (let ((print-length nil) (print-level nil)) (prin1 data (current-buffer)))
    (write-region (point-min) (point-max) file nil 'silent)))

(ert-deftest emacs-agent-input-store-roundtrip-recovery-never-executes ()
  (emacs-agent-input-store-test--isolated
    (let* ((session (emacs-agent-input-store-test--session))
           (ask (emacs-agent-input-store-test--input session "input-20" "run-21" 'ask 'queued))
           (_steer (emacs-agent-input-store-test--input session "input-30" "run-31" 'steer 'queued "run-900"))
           (_recovery (emacs-agent-input-store-test--input session "input-40" "run-41" 'steer 'withdrawn "run-999")))
      (setf (emacs-agent-session-pending-runs session) (list (emacs-agent-input-run ask)))
      (let* ((file (emacs-agent-store-save session))
             (before (mapcar #'emacs-agent-input-data (emacs-agent-session-inputs session))))
        (should-not (string-match-p "NEVER-SAVE-THIS-SECRET\\|#<\\|api-key"
                                    (emacs-agent-input-store-test--read-text file)))
        (should (= (logand (file-modes file) #o777) #o600))
        (should (= (logand (file-modes emacs-agent-data-directory) #o777) #o700))
        (cl-letf (((symbol-function 'emacs-agent-gptel-submit) (lambda (&rest _) (ert-fail "Submitted on restore")))
                  ((symbol-function 'gptel-request) (lambda (&rest _) (ert-fail "HTTP on restore")))
                  ((symbol-function 'emacs-agent-session-enqueue) (lambda (&rest _) (ert-fail "Queued on restore"))))
          (let* ((emacs-agent-session-event-functions (list (lambda (&rest _) (ert-fail "Restore ran event hooks"))))
                 (restored (emacs-agent-store--restore file))
                 (inputs (emacs-agent-session-inputs restored)))
            (should-not (emacs-agent-session-active-run restored))
            (should-not (emacs-agent-session-pending-runs restored))
            (should (= (length inputs) 3))
            (cl-mapc
             (lambda (saved input)
               (should (eq (emacs-agent-input-state input) 'withdrawn))
               (should (eq (emacs-agent-input-reason input) 'restart))
               (should-not (emacs-agent-run-backend (emacs-agent-input-run input)))
               (should-not (emacs-agent-input-target input))
               (should (equal (plist-get saved :run) (plist-get (emacs-agent-input-data input) :run)))
               (should (equal (plist-get saved :target-id) (emacs-agent-input-target-id input))))
             before inputs)
            (should (> emacs-agent-session--counter 999))
            (let ((events (copy-tree (emacs-agent-session-events restored))))
              (should (= (length events) 1))
              (should (eq (plist-get (car events) :type) 'interrupted))
              (should (> (string-to-number (substring (plist-get (car events) :id) 6)) 999))
              (emacs-agent-store-save restored)
              (setq emacs-agent-session--registry (make-hash-table :test #'equal))
              (let ((again (emacs-agent-store--restore file)))
                (should (equal events (emacs-agent-session-events again)))
                (should (equal (mapcar #'emacs-agent-input-data inputs)
                               (mapcar #'emacs-agent-input-data (emacs-agent-session-inputs again))))))))))))

(ert-deftest emacs-agent-input-store-source-identity-must-match ()
  (emacs-agent-input-store-test--isolated
    (let ((source (generate-new-buffer " *input-store-private*")))
      (unwind-protect
          (let* ((session (emacs-agent-input-store-test--session))
                 (_input (emacs-agent-input-store-test--input session "input-2" "run-3" 'ask 'withdrawn nil source))
                 (file (emacs-agent-store-save session)))
            (should (eq source (emacs-agent-run-source-buffer
                                (emacs-agent-input-run (car (emacs-agent-session-inputs
                                                            (emacs-agent-store--restore file)))))))
            (setq emacs-agent-session--registry (make-hash-table :test #'equal))
            (with-current-buffer source (setq buffer-file-name "/different/identity"))
            (should-not (emacs-agent-run-source-buffer
                         (emacs-agent-input-run (car (emacs-agent-session-inputs
                                                     (emacs-agent-store--restore file))))))
            (setq emacs-agent-session--registry (make-hash-table :test #'equal))
            (kill-buffer source)
            (should-not (emacs-agent-run-source-buffer
                         (emacs-agent-input-run (car (emacs-agent-session-inputs
                                                     (emacs-agent-store--restore file)))))))
        (when (buffer-live-p source) (kill-buffer source))))))

(ert-deftest emacs-agent-input-store-invalid-records-never-register ()
  (emacs-agent-input-store-test--isolated
    (let* ((session (emacs-agent-input-store-test--session))
           (_input (emacs-agent-input-store-test--input session "input-2" "run-3" 'ask 'withdrawn))
           (file (emacs-agent-store-save session))
           (valid (emacs-agent-store--snapshot session)))
      (dolist (mutate
               (list (lambda (data) (plist-put data :inputs 'bad))
                     (lambda (data) (plist-put data :inputs '(one . two)))
                     (lambda (data) (plist-put data :inputs (list nil)))
                     (lambda (data) (plist-put data :unknown t))
                     (lambda (data)
                       (plist-put (plist-get (car (plist-get data :inputs)) :run) :instructions "bad") data)
                     (lambda (data)
                       (plist-put data :messages '((:role user :run-id "other" :input-id "input-2" :text "old"))))
                     (lambda (data)
                       (plist-put data :messages '((:role user :run-id "run-3" :text "old"))))
                     (lambda (data) (plist-put (car (plist-get data :inputs)) :unknown t) data)
                     (lambda (data) (plist-put (plist-get (car (plist-get data :inputs)) :run) :unknown t) data)
                     (lambda (data) (plist-put (car (plist-get data :inputs)) :state 'delivered) data)
                     (lambda (data) (plist-put (car (plist-get data :inputs)) :state 'queued) data)
                     (lambda (data) (plist-put data :inputs (append (plist-get data :inputs)
                                                                 (copy-tree (plist-get data :inputs)))))
                     (lambda (data)
                       (let ((second (copy-tree (car (plist-get data :inputs)))))
                         (plist-put second :id "input-4")
                         (plist-put data :inputs (append (plist-get data :inputs) (list second)))))))
        (let ((bad (funcall mutate (copy-tree valid))))
          (emacs-agent-input-store-test--write-data file bad)
          (should-error (emacs-agent-store--restore file))
          (should (= (hash-table-count emacs-agent-session--registry) 0)))))))

(ert-deftest emacs-agent-input-store-legacy-optional-and-delivered-id-reservation ()
  (emacs-agent-input-store-test--isolated
    (let* ((session (emacs-agent-input-store-test--session))
           (file (emacs-agent-store--file 'global)))
      (make-directory emacs-agent-data-directory t)
      (setf (emacs-agent-session-messages session)
            '((:role user :run-id "run-2" :input-id "input-700" :text "delivered"))
            (emacs-agent-session-events session)
            '((:id "event-3" :run-id "run-2" :session-id "session-1" :time 1 :type input
               :payload (:id "input-800" :state delivered :target-id "run-900" :run (:id "run-901")))))
      (let ((data (emacs-agent-store--snapshot session)))
        (cl-remf data :inputs)
        (emacs-agent-input-store-test--write-data file data))
      (let ((restored (emacs-agent-store--restore file)))
        (should-not (emacs-agent-session-inputs restored))
        (should (= emacs-agent-session--counter 901)))
      (setq emacs-agent-session--registry (make-hash-table :test #'equal)
            emacs-agent-session--counter 0)
      (setf (emacs-agent-session-events session) nil)
      (emacs-agent-store-save session)
      (emacs-agent-store--restore file)
      (should (= emacs-agent-session--counter 700)))))

(ert-deftest emacs-agent-input-store-save-failure-preserves-file-and-fast-layout ()
  (emacs-agent-input-store-test--isolated
    (let* ((session (emacs-agent-input-store-test--session))
           (input (emacs-agent-input-store-test--input session "input-2" "run-3" 'ask 'withdrawn))
           (file (cl-letf (((symbol-function 'pp) (lambda (&rest _) (ert-fail "Pretty printer called"))))
                   (emacs-agent-store-save session)))
           (old (emacs-agent-input-store-test--read-text file)))
      (with-temp-buffer
        (insert old)
        (should (= (how-many "^  (" (point-min) (point-max)) 1)))
      (setf (emacs-agent-run-user-text (emacs-agent-input-run input)) "edited")
      (cl-letf (((symbol-function 'rename-file) (lambda (&rest _) (signal 'file-error '("injected")))))
        (should-error (emacs-agent-store-save session) :type 'file-error))
      (should (equal old (emacs-agent-input-store-test--read-text file)))
      (should (= (logand (file-modes file) #o777) #o600))
      (should-not (directory-files emacs-agent-data-directory nil "\\`\\.snapshot-"))
      (setf (emacs-agent-session-inputs session) '(bad . collection))
      (should-error (emacs-agent-store-save session))
      (should (equal old (emacs-agent-input-store-test--read-text file))))))

(provide 'emacs-agent-input-store-test)
;;; emacs-agent-input-store-test.el ends here
