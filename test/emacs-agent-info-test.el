;;; emacs-agent-info-test.el --- Session information -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'emacs-agent)

(defmacro emacs-agent-info-test--fixture (&rest body)
  "Run BODY with isolated registry, selection, data dir and status cache."
  (declare (indent 0) (debug t))
  `(let ((emacs-agent-session--registry (make-hash-table :test #'equal))
         (emacs-agent-session--selected (make-hash-table :test #'equal))
         (emacs-agent-session--counter 0)
         (emacs-agent-session-event-functions nil)
         (emacs-agent-data-directory (make-temp-file "agent-info-test-" t)))
     (unwind-protect (progn ,@body)
       (delete-directory emacs-agent-data-directory t))))

(defun emacs-agent-info-test--session (id &rest slots)
  "Build, register and return a conversation with ID and SLOTS."
  (let ((session (apply #'make-emacs-agent-session :id id slots)))
    (puthash id session emacs-agent-session--registry)
    session))

(defun emacs-agent-info-test--usage-event (request available input output cached)
  "Build a durable journal usage event like `emacs-agent-usage-end' does."
  (list :id (format "event-%d" (cl-incf emacs-agent-session--counter))
        :time 100.0 :session-id "info" :run-id "run-1" :type 'usage
        :payload (list :request request :status 'completed :source 'gptel-normalized
                       :available available
                       :tokens (list :input input :output output :cached cached))))

(ert-deftest emacs-agent-info-fields-and-strict-usage ()
  (emacs-agent-info-test--fixture
    (let* ((source (generate-new-buffer "info-source"))
           (session (emacs-agent-info-test--session
                     "info-session" :name "named" :project-root "/tmp/proj/"
                     :updated-at 111.0
                     :messages '((:role user :text "a") (:role assistant :text "b"))
                     :events (list (emacs-agent-info-test--usage-event 1 t 100 10 50)
                                   (list :id "e2" :type 'assistant :payload nil))
                     :provenance '(:source-id "old" :time 55.0
                                   :boundary (:kind completed :end 7))
                     :usage-anchor '(:model "main" :backend "aiserver"))))
      (setf (emacs-agent-session-last-source-buffer session) source)
      (let ((info (emacs-agent-session-info session)))
        (should (string-prefix-p "proj#" (plist-get info :name)))
        (should (string-match-p "/named#" (plist-get info :name)))
        (should (equal (plist-get info :id) "info-session"))
        (should (equal (plist-get info :id-short)
                        (substring (secure-hash 'sha256 "info-session") 0 10)))
        (should (equal (plist-get info :scope) "/tmp/proj/"))
        (should (numberp (plist-get info :created-at)))
        (should (numberp (plist-get info :updated-at)))
        (should (eq (plist-get info :run-status) 'idle))
        (should (= (plist-get info :pending-runs) 0))
        (should (= (plist-get info :pending-inputs) 0))
        (should (equal (plist-get info :source-buffer) "info-source"))
        (should (plist-get info :source-buffer-alive))
        (should (= (plist-get info :messages) 2))
        (should (= (plist-get info :events) 2))
        (should (equal (plist-get info :provenance)
                       '(:source-id "old" :time 55.0
                         :boundary (:kind completed :end 7))))
        (should (equal (plist-get info :usage-anchor) '(:model "main" :backend "aiserver")))
        (should (equal (plist-get (plist-get info :usage) :requests) 1))
        (should (equal (plist-get (plist-get info :usage) :reported) 1))
        (should (equal (plist-get (plist-get info :usage) :tokens)
                       '(:input 100 :output 10 :cached 50)))
        (should (equal (plist-get (plist-get info :usage) :input-total) 150))
        (should (equal (plist-get (plist-get info :usage) :total) 160))
        (should (equal (plist-get info :saved-file)
                       (expand-file-name (concat "conversations/"
                                                (secure-hash 'sha256 "info-session") ".eld")
                                         emacs-agent-data-directory)))
        (should-not (plist-get info :saved))
        (should-not (plist-get info :log-buffer-alive)))
      (kill-buffer source))))

(ert-deftest emacs-agent-info-unknown-propagates-and-empty-is-unknown ()
  (emacs-agent-info-test--fixture
    (let ((session (emacs-agent-info-test--session
                    "unknown-session"
                    :events (list (emacs-agent-info-test--usage-event 1 t 100 10 50)
                                  (emacs-agent-info-test--usage-event 2 t 30 5 20)
                                  (emacs-agent-info-test--usage-event 3 nil 'unknown 'unknown 'unknown)))))
      (let* ((usage (plist-get (emacs-agent-session-info session) :usage))
             (tokens (plist-get usage :tokens)))
        (should (equal (plist-get usage :requests) 3))
        (should (equal (plist-get usage :reported) 2))
        (should (eq (plist-get tokens :input) 'unknown))
        (should (eq (plist-get tokens :cached) 'unknown))
        (should (eq (plist-get tokens :output) 'unknown))
        (should (eq (plist-get usage :input-total) 'unknown))
        (should (eq (plist-get usage :total) 'unknown))))
    (let* ((empty (emacs-agent-info-test--session "empty-usage"))
           (usage (plist-get (emacs-agent-session-info empty) :usage)))
      (should (equal (plist-get usage :requests) 0))
      (should (equal (plist-get usage :reported) 0))
      (should (eq (plist-get (plist-get usage :tokens) :input) 'unknown))
      (should (eq (plist-get usage :total) 'unknown)))))

(ert-deftest emacs-agent-info-file-name-and-short-id-match-canonical-id ()
  (emacs-agent-info-test--fixture
    (let* ((id (concat "session-" (secure-hash 'sha256 "canonical-handle")))
           (session (emacs-agent-info-test--session id))
           (info (emacs-agent-session-info session)))
      (should (equal (plist-get info :id-short) (substring id 8 18)))
      (should (equal (emacs-agent-session-id-handle session) (substring id 8)))
      (should (string-suffix-p
               (concat "#" (substring id 8 18))
               (plist-get info :name)))
      ;; The saved file is the same handle, so on-disk names visibly match.
      (should (equal (plist-get info :saved-file)
                     (expand-file-name (concat "conversations/" (substring id 8) ".eld")
                                       emacs-agent-data-directory)))))
  ;; Non-canonical IDs keep the previous hash fallback.
  (emacs-agent-info-test--fixture
    (let ((session (emacs-agent-info-test--session "legacy-id")))
      (should (equal (emacs-agent-session-id-handle session)
                     (secure-hash 'sha256 "legacy-id")))
      (should (equal (emacs-agent-store--file "legacy-id")
                     (expand-file-name (concat "conversations/" (secure-hash 'sha256 "legacy-id") ".eld")
                                       emacs-agent-data-directory))))))

(ert-deftest emacs-agent-info-compaction-and-job ()
  (emacs-agent-info-test--fixture
    (let ((session (emacs-agent-info-test--session
                    "compact-info"
                    :compaction '(:cut 12 :summary "sum text" :tokens-before 456
                                      :model "main" :backend "aiserver" :time 123.0))))
      (let ((compaction (plist-get (emacs-agent-session-info session) :compaction)))
        (should (equal compaction '(:cut 12 :summary-length 8 :tokens-before 456
                                        :model "main" :backend "aiserver" :time 123.0)))
        (should-not (plist-get (emacs-agent-session-info session) :compaction-job-state)))
      (should (string-match-p
               "Compaction: cut at message 12, summary 8 chars, tokens-before 456"
               (emacs-agent-session-info--format (emacs-agent-session-info session)))))))

(ert-deftest emacs-agent-info-resolution-and-errors ()
  (emacs-agent-info-test--fixture
    (let* ((session (emacs-agent-info-test--session "resolve-me" :name "target"))
           (by-id (emacs-agent-session-info "resolve-me")))
      (should (equal (plist-get by-id :id) "resolve-me"))
      (should (eq (plist-get (emacs-agent-session-info session) :id)
                  (emacs-agent-session-id session)))
      (should-error (emacs-agent-session-info "missing") :type 'error)
      (should-error (emacs-agent-session-info 7) :type 'error)
      (should-error (emacs-agent-session-info) :type 'user-error))
    ;; Owner resolution from a journal context, without any scope selection.
    (let* ((session (emacs-agent-info-test--session "owner" :name "owned"))
           (journal (emacs-agent--log-buffer session)))
      (with-current-buffer journal
        (should (equal (plist-get (emacs-agent-session-info) :id) "owner")))
      (kill-buffer journal))))

(ert-deftest emacs-agent-info-show-read-only-owner-and-content ()
  (emacs-agent-info-test--fixture
    (let* ((session (emacs-agent-info-test--session
                     "show-session" :name "shown" :project-root "/tmp/proj/"
                     :messages '((:role user :text "a"))
                     :events (list (emacs-agent-info-test--usage-event 1 t 100 10 50))
                     :usage-anchor '(:model "main" :backend "aiserver")))
           (journal (emacs-agent--log-buffer session))
           (displayed nil))
      (cl-letf (((symbol-function 'display-buffer)
                 (lambda (buffer &rest _) (push buffer displayed))))
        (with-current-buffer journal
          (emacs-agent-session-info-show)))
      (should (= (length displayed) 1))
      (let ((buffer (car displayed)))
        (should (string-prefix-p "*emacs-agent-info: proj#" (buffer-name buffer)))
        (with-current-buffer buffer
          (should (derived-mode-p 'special-mode))
          (should buffer-read-only)
          (should (eq emacs-agent-session--owner session))
          (should (equal default-directory "/tmp/proj/"))
          (should-not (buffer-modified-p))
          (goto-char (point-min))
          (should (looking-at "Session: proj#"))
          (should (search-forward "ID: show-session (short: " nil t))
          (should (search-forward "Scope: /tmp/proj/"))
          (should (search-forward "Active run: idle"))
          (should (search-forward "Last source buffer: none recorded"))
          (should (search-forward "Canonical messages: 1"))
          (should (search-forward "Compaction: none"))
          (should (search-forward "Usage anchor: model main, backend aiserver"))
          (should (search-forward "HTTP requests: 1 (1 with usage data)"))
          (should (search-forward "Input (uncached): 100"))
          (should (search-forward "Cache read: 50"))
          (should (search-forward "Output: 10"))
          (should (search-forward "Input total: 150"))
          (should (search-forward "Total: 160"))
          (should (search-forward "not saved yet"))
          (should (search-forward "Journal buffer: open")))
        ;; No run, selection change or gptel interaction happened.
        (should-not (emacs-agent-session-active-run session))
        (should-not (gethash "/tmp/proj/" emacs-agent-session--selected))
        (kill-buffer buffer))
      (kill-buffer journal))))

(ert-deftest emacs-agent-info-show-global-selection-and-updated-state ()
  (emacs-agent-info-test--fixture
    (let* ((session (emacs-agent-info-test--session "global-info" :name "picked"))
           (displayed nil)
           (file (emacs-agent-store--file "global-info")))
      (puthash 'global "global-info" emacs-agent-session--selected)
      (make-directory (file-name-directory file) t)
      (with-temp-file file (insert "schema marker"))
      (with-temp-buffer
        (setq default-directory emacs-agent-data-directory)
        (setf (emacs-agent-session-pending-runs session)
              (list (make-emacs-agent-run :session session :status 'requesting)))
        (cl-letf (((symbol-function 'display-buffer)
                   (lambda (buffer &rest _) (push buffer displayed))))
          (emacs-agent-session-info-show))
        (with-current-buffer (car displayed)
          (should (search-forward "Scope: global"))
          (should (search-forward "Active run: idle"))
          (should (search-forward "Pending runs: 1"))
          (should (search-forward "(saved)"))
          (should (search-forward "Journal buffer: not open")))
        (kill-buffer (car displayed))))))

(provide 'emacs-agent-info-test)
;;; emacs-agent-info-test.el ends here