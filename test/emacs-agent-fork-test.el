;;; emacs-agent-fork-test.el --- Completed-boundary forks -*- lexical-binding: t; -*-
;; Loaded after adapter, history, store and conversation fixtures.  No HTTP.
(require 'ert)
(require 'emacs-agent)

(defun emacs-agent-fork-test--turn (text)
  "Append one successful whole turn and return its run."
  (let ((run (emacs-agent-test--submit text)))
    (emacs-agent-test--complete run (concat text " answer"))
    run))

(defun emacs-agent-fork-test--summary (session cut)
  "Install a valid summary projection at absolute canonical CUT."
  (setf (emacs-agent-session-compaction session)
        (list :cut cut :summary "INHERITED-SUMMARY" :tokens-before 100
              :model "gpt-4o" :backend "agent-offline" :time 1)))

(defun emacs-agent-fork-test--completed (session run)
  "Find RUN's successful terminal event in SESSION."
  (cl-find-if (lambda (e) (and (eq (plist-get e :type) 'completed)
                              (equal (plist-get e :run-id) (emacs-agent-run-id run))))
              (emacs-agent-session-events session)))

(ert-deftest emacs-agent-fork-command-namespace ()
  (should (commandp 'emacs-agent-session-fork))
  (dolist (function '(emacs-agent-session--fork emacs-agent-session--fork-points))
    (should (fboundp function))
    (should-not (commandp function))))

(ert-deftest emacs-agent-fork-points-whole-completed-turns-only ()
  (emacs-agent-conversation-test--fixture
    (with-temp-buffer
      (let* ((first (emacs-agent-fork-test--turn "first"))
             (session (emacs-agent-run-session first))
             (second (emacs-agent-fork-test--turn "second")))
        (should
         (equal (emacs-agent-session--fork-points session)
                (list (list :kind 'completed :end 2 :run-id (emacs-agent-run-id first)
                            :event-id (plist-get (emacs-agent-fork-test--completed session first) :id)
                            :text "first")
                      (list :kind 'completed :end 4 :run-id (emacs-agent-run-id second)
                            :event-id (plist-get (emacs-agent-fork-test--completed session second) :id)
                            :text "second"))))
        (dolist (end '(nil 0 -1 1 3 5 2.0 "2"))
          (should-error (emacs-agent-session--fork session end) :type 'user-error))
        (should (eq (emacs-agent-session-selected nil) session))))))

(ert-deftest emacs-agent-fork-points-require-canonical-run-and-completed-event ()
  (emacs-agent-conversation-test--fixture
    (with-temp-buffer
      (let* ((run (emacs-agent-fork-test--turn "canonical"))
             (session (emacs-agent-run-session run))
             (events (emacs-agent-session-events session))
             (messages (emacs-agent-session-messages session)))
        (setf (emacs-agent-session-events session)
              (cl-remove 'completed events :key (lambda (e) (plist-get e :type))))
        (should-not (emacs-agent-session--fork-points session))
        (setf (emacs-agent-session-events session) events
              (emacs-agent-session-messages session) nil)
        (should-not (emacs-agent-session--fork-points session))
        (setf (emacs-agent-session-messages session) messages)
        (should (= (length (emacs-agent-session--fork-points session)) 1))))))

(ert-deftest emacs-agent-fork-failed-and-cancelled-endpoints-not-offered ()
  (dolist (status '(failed cancelled))
    (emacs-agent-conversation-test--fixture
      (with-temp-buffer
        (let* ((good (emacs-agent-fork-test--turn "good"))
               (session (emacs-agent-run-session good))
               (bad (emacs-agent-test--submit "partial")))
          (emacs-agent-gptel--callback bad "partial answer" nil)
          (emacs-agent-gptel--finish bad status "not successful")
          (should (equal (mapcar (lambda (p) (plist-get p :end))
                                (emacs-agent-session--fork-points session)) '(2)))
          (should-error (emacs-agent-session--fork session
                                                   (length (emacs-agent-session-messages session)))
                        :type 'user-error))))))

(ert-deftest emacs-agent-fork-points-idle-and-registered-required ()
  (emacs-agent-conversation-test--fixture
    (with-temp-buffer
      (let* ((run (emacs-agent-fork-test--turn "done"))
             (session (emacs-agent-run-session run)))
        (dolist (slot '(active pending compaction))
          (unwind-protect
              (progn
                (pcase slot
                  ('active (setf (emacs-agent-session-active-run session) run))
                  ('pending (setf (emacs-agent-session-pending-runs session) (list run)))
                  ('compaction (setf (emacs-agent-session-compaction-job session) t)))
                (should-error (emacs-agent-session--fork-points session) :type 'user-error)
                (should-error (emacs-agent-session--fork session 2) :type 'user-error))
            (setf (emacs-agent-session-active-run session) nil
                  (emacs-agent-session-pending-runs session) nil
                  (emacs-agent-session-compaction-job session) nil)))
        (remhash (emacs-agent-session-id session) emacs-agent-session--registry)
        (should-error (emacs-agent-session--fork-points session) :type 'user-error)))))

(ert-deftest emacs-agent-fork-compaction-is-earliest-point-including-mid-run-cut ()
  (emacs-agent-conversation-test--fixture
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "tools"))
             (session (emacs-agent-run-session run)))
        (emacs-agent-test--real-tools run)
        (emacs-agent-test--complete run "tools done")
        (let ((end (length (emacs-agent-session-messages session))))
          (emacs-agent-fork-test--turn "future")
          ;; A valid F4 cut can lie inside a run, before atomic tool records.
          (emacs-agent-fork-test--summary session 1)
          (let ((points (emacs-agent-session--fork-points session)))
            (should (equal (car points) '(:kind summary :end 1)))
            (should (equal (mapcar (lambda (p) (plist-get p :end)) points)
                           (list 1 end (+ end 2))))))
        (emacs-agent-fork-test--summary session (length (emacs-agent-session-messages session)))
        (should (equal (emacs-agent-session--fork-points session)
                       (list (list :kind 'summary :end (length (emacs-agent-session-messages session))))))))))

(ert-deftest emacs-agent-fork-summary-only-retains-archive-but-no-raw-events ()
  (emacs-agent-conversation-test--fixture
    (with-temp-buffer
      (let* ((run (emacs-agent-fork-test--turn "summarized raw"))
             (session (emacs-agent-run-session run)))
        (emacs-agent-fork-test--turn "FUTURE-SECRET")
        (emacs-agent-fork-test--summary session 2)
        (let ((fork (emacs-agent-session--fork session 2 "summary only")))
          (should (equal (emacs-agent-session-messages fork)
                         (cl-subseq (emacs-agent-session-messages session) 0 2)))
          (should (equal (emacs-agent-session-compaction fork) (emacs-agent-session-compaction session)))
          (should (= (length (emacs-agent-session-events fork)) 1))
          (should (eq (plist-get (car (emacs-agent-session-events fork)) :type) 'inherited-summary))
          (should (equal (plist-get (emacs-agent-session-provenance fork) :boundary)
                         '(:kind summary :end 2)))
          (let ((view (copy-emacs-agent-run run)))
            (setf (emacs-agent-run-session view) fork)
            (let ((history (prin1-to-string (emacs-agent-gptel--history view))))
              (should (string-match-p "INHERITED-SUMMARY" history))
              (should-not (string-match-p "summarized raw\\|FUTURE-SECRET" history))))
          (should-not (string-match-p "FUTURE-SECRET" (prin1-to-string (emacs-agent-store--snapshot fork)))))))))

(ert-deftest emacs-agent-fork-filters-queued-future-audit-before-selected-completion ()
  (emacs-agent-conversation-test--fixture
    (with-temp-buffer
      (let* ((first (emacs-agent-test--submit "selected"))
             (session (emacs-agent-run-session first))
             (future (emacs-agent-test--submit "QUEUED-FUTURE-SECRET")))
        (should (cl-find (emacs-agent-run-id future) (emacs-agent-session-events session)
                         :key (lambda (e) (plist-get e :run-id)) :test #'equal))
        (emacs-agent-test--complete first "selected answer")
        (let ((boundary (emacs-agent-fork-test--completed session first)))
          (emacs-agent-test--complete future "FUTURE-ANSWER")
          (let ((fork (emacs-agent-session--fork session 2)))
            (should (equal (mapcar (lambda (e) (plist-get e :id)) (emacs-agent-session-events fork))
                           (mapcar (lambda (e) (plist-get e :id))
                                   (cl-remove-if-not
                                    (lambda (e) (equal (plist-get e :run-id) (emacs-agent-run-id first)))
                                    (cl-subseq (emacs-agent-session-events session) 0
                                               (1+ (cl-position boundary (emacs-agent-session-events session))))))))
            (should-not (string-match-p "QUEUED-FUTURE-SECRET\\|FUTURE-ANSWER"
                                        (prin1-to-string (emacs-agent-store--snapshot fork))))))))))

(ert-deftest emacs-agent-fork-deep-copy-historical-identities-and-inertness ()
  (emacs-agent-conversation-test--fixture
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "historical"))
             (session (emacs-agent-run-session run)))
        (emacs-agent-test--real-tools run)
        (emacs-agent-test--complete run "done")
        (emacs-agent-fork-test--summary session 1)
        (let* ((input (emacs-agent-input-prepare
                       (emacs-agent-session-prepare session "withdrawn" nil (current-buffer) nil) 'ask))
               (_ (emacs-agent-input-withdraw input))
               (before (emacs-agent-store--snapshot session))
               (requests (length emacs-agent-test--requests))
               (fork (cl-letf (((symbol-function 'emacs-agent-eval)
                                (lambda (&rest _) (ert-fail "Fork replayed tools")))
                               ((symbol-function 'gptel-request)
                                (lambda (&rest _) (ert-fail "Fork requested a model"))))
                       (emacs-agent-session--fork session (length (emacs-agent-session-messages session))))))
          (should (equal before (emacs-agent-store--snapshot session)))
          (should (= requests (length emacs-agent-test--requests)))
          (should-not (equal (emacs-agent-session-id fork) (emacs-agent-session-id session)))
          (should (equal (emacs-agent-session-messages fork) (emacs-agent-session-messages session)))
          (should-not (eq (emacs-agent-session-messages fork) (emacs-agent-session-messages session)))
          (should-not (eq (car (emacs-agent-session-messages fork)) (car (emacs-agent-session-messages session))))
          (dolist (accessor '(emacs-agent-session-inputs emacs-agent-session-active-run
                              emacs-agent-session-pending-runs emacs-agent-session-compaction-job
                              emacs-agent-session-last-source-buffer emacs-agent-session-usage-anchor
                              emacs-agent-session-log-buffer))
            (should-not (funcall accessor fork)))
          (should (cl-every (lambda (e) (equal (plist-get e :session-id) (emacs-agent-session-id fork)))
                            (emacs-agent-session-events fork)))
          (should (eq (plist-get (car (emacs-agent-session-events fork)) :type) 'inherited-summary))
          (should-not (plist-member (plist-get (emacs-agent-session-provenance fork) :boundary) :text))
          (setf (plist-get (car (emacs-agent-session-messages fork)) :text) "changed fork"
                (plist-get (emacs-agent-session-compaction fork) :summary) "changed summary")
          (should (equal before (emacs-agent-store--snapshot session))))))))

(ert-deftest emacs-agent-fork-real-wire-keeps-summary-tool-pairs-and-reasoning ()
  (emacs-agent-conversation-test--fixture
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "original tool goal"))
             (session (emacs-agent-run-session run)))
        (emacs-agent-test--real-tools run)
        (emacs-agent-test--complete run "selected done")
        (let ((end (length (emacs-agent-session-messages session))))
          (emacs-agent-fork-test--summary session 1)
          (let ((expected (mapcar (lambda (p) (emacs-agent-test--wire run p)) '(nil current full))))
            (emacs-agent-fork-test--turn "FUTURE-WIRE-SECRET")
            (let* ((fork (emacs-agent-session--fork session end))
                   (view (copy-emacs-agent-run run)))
              (setf (emacs-agent-run-session view) fork)
              (cl-mapc
               (lambda (policy wire)
                 (let ((actual (emacs-agent-test--wire view policy)))
                   (should (equal (gptel--json-encode actual) (gptel--json-encode wire)))
                   (dolist (text '("INHERITED-SUMMARY" "pair-1" "pair-2" "actual protocol reasoning"))
                     (should (string-match-p text (prin1-to-string actual))))
                   (should-not (string-match-p "FUTURE-WIRE-SECRET" (prin1-to-string actual)))))
               '(nil current full) expected))))))))

(ert-deftest emacs-agent-fork-save-and-selection-failures-do-not-publish ()
  (dolist (failure '(candidate pointer))
    (emacs-agent-conversation-test--fixture
      (with-temp-buffer
        (let* ((root (file-name-as-directory (expand-file-name "project" emacs-agent-data-directory)))
               (run (emacs-agent-test--submit "project goal" root))
               (session (emacs-agent-run-session run)))
          (emacs-agent-test--complete run "done")
          (emacs-agent-store-save session)
          (let* ((count (hash-table-count emacs-agent-session--registry))
                 (pointer (emacs-agent-store--selection-file root))
                 (before (emacs-agent-test-store--text pointer))
                 (save (symbol-function 'emacs-agent-store-save)) reached)
            (cl-letf (((symbol-function 'emacs-agent-store-save)
                       (lambda (candidate)
                         (if (and (eq failure 'candidate) (not (eq candidate session)))
                             (progn (setq reached t) (error "candidate disk full"))
                           (funcall save candidate))))
                      ((symbol-function 'emacs-agent-store-select)
                       (lambda (&rest _) (setq reached t) (error "selection disk full"))))
              (should-error (emacs-agent-session--fork session 2)))
            (should reached)
            (should (eq (emacs-agent-session-selected root) session))
            (should (= count (hash-table-count emacs-agent-session--registry)))
            (should (equal before (emacs-agent-test-store--text pointer)))))))))

(ert-deftest emacs-agent-fork-public-uses-journal-owner-not-selection ()
  (emacs-agent-conversation-test--fixture
    (with-temp-buffer
      (let* ((source (current-buffer))
             (run (emacs-agent-fork-test--turn "owner history"))
             (owner (emacs-agent-run-session run))
             (selected (emacs-agent-session--new nil "other"))
             (journal (emacs-agent--log-buffer owner)) shown)
        (with-current-buffer journal
          (cl-letf (((symbol-function 'pop-to-buffer) (lambda (buffer &rest _) (setq shown buffer))))
            (let ((fork (emacs-agent-session-fork 2 "owner fork")))
              (should (equal (plist-get (emacs-agent-session-provenance fork) :source-id)
                             (emacs-agent-session-id owner)))
              (should (eq (emacs-agent-session-selected nil) fork))
              (should (eq shown (emacs-agent-session-log-buffer fork)))
              (should (eq (emacs-agent-session-last-source-buffer fork) source))
              (with-current-buffer (emacs-agent-session-log-buffer fork)
                (cl-letf (((symbol-function 'read-from-minibuffer)
                           (lambda (&rest _) "continue from fork journal")))
                  (let ((next (emacs-agent-ask)))
                    (should (eq (emacs-agent-run-session next) fork))
                    (should (eq (emacs-agent-run-source-buffer next) source))
                    (emacs-agent-test--complete next "continued")))))))
        (should (eq (emacs-agent-session-last-source-buffer owner) source))
        (should-not (emacs-agent-session-messages selected))))))

(ert-deftest emacs-agent-fork-public-rejects-busy-other-selection ()
  (emacs-agent-conversation-test--fixture
    (with-temp-buffer
      (let* ((run (emacs-agent-fork-test--turn "owner"))
             (owner (emacs-agent-run-session run))
             (_ (emacs-agent-session--new nil "other"))
             (busy (emacs-agent-test--submit "busy")))
        (with-current-buffer (emacs-agent--log-buffer owner)
          (should-error (emacs-agent-session-fork 2) :type 'user-error))
        (should (eq (emacs-agent-session-selected nil) (emacs-agent-run-session busy)))))))

(ert-deftest emacs-agent-fork-minibuffer-rejects-stale-message-event-and-compaction ()
  (dolist (change '(messages events compaction selection))
    (emacs-agent-conversation-test--fixture
      (with-temp-buffer
        (let* ((run (emacs-agent-fork-test--turn "first"))
               (session (emacs-agent-run-session run))
               (before (hash-table-count emacs-agent-session--registry)))
          (emacs-agent-fork-test--summary session 1)
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_ choices &rest _)
                       (pcase change
                         ('messages
                          (setf (emacs-agent-session-messages session)
                                (append (emacs-agent-session-messages session)
                                        (list (list :role 'assistant :run-id (emacs-agent-run-id run) :text "new tail")))))
                         ('events (emacs-agent-session-record run 'audit "changed tail"))
                         ('compaction
                          (setf (emacs-agent-session-compaction session)
                                (copy-tree (emacs-agent-session-compaction session))))
                         ('selection (emacs-agent-session--new nil "reentrant")))
                       (let ((first (car choices))) (if (consp first) (car first) first)))))
            (should-error (emacs-agent-session-fork) :type 'user-error))
          (should (= (hash-table-count emacs-agent-session--registry)
                     (+ before (if (eq change 'selection) 1 0)))))))))

(ert-deftest emacs-agent-fork-completion-defaults-newest-and-prefix-asks-name ()
  (emacs-agent-conversation-test--fixture
    (with-temp-buffer
      (emacs-agent-fork-test--turn "first")
      (let* ((run (emacs-agent-fork-test--turn "newest"))
             (session (emacs-agent-run-session run))
             (current-prefix-arg '(4)) asked default)
        (emacs-agent-fork-test--summary session 2)
        (cl-letf (((symbol-function 'called-interactively-p) (lambda (&rest _) t))
                  ((symbol-function 'read-string) (lambda (&rest _) (setq asked t) "named fork"))
                  ((symbol-function 'completing-read)
                   (lambda (_ choices _predicate _require-match &optional _initial _history def &rest _)
                     (should (string-prefix-p "1: after compaction summary" (caar choices)))
                     (should (string-prefix-p "2: after " def))
                     (setq default def)
                     (or (if (listp def) (car def) def)
                         (let ((last (car (last choices)))) (if (consp last) (car last) last))))))
          (let ((fork (emacs-agent-session-fork)))
            (should asked)
            (should default)
            (should (equal (emacs-agent-session-name fork) "named fork"))
            (should (equal (plist-get (plist-get (emacs-agent-session-provenance fork) :boundary) :end) 4))
            (should (equal (emacs-agent-session-messages fork) (emacs-agent-session-messages session)))))))))

(ert-deftest emacs-agent-fork-provenance-validation-rejects-invalid-boundaries ()
  (emacs-agent-conversation-test--fixture
    (with-temp-buffer
      (let* ((run (emacs-agent-fork-test--turn "valid"))
             (session (emacs-agent-run-session run))
             (fork (emacs-agent-session--fork session 2))
             (data (emacs-agent-store--snapshot fork))
             (file (emacs-agent-store--file (emacs-agent-session-id fork)))
             (boundary (plist-get (emacs-agent-session-provenance fork) :boundary)))
        (should (emacs-agent-store--validate data file))
        (dolist (bad (list '(:kind summary :end 0) '(:kind summary :end -1)
                           '(:kind summary :end 3) '(:kind summary :end 2.0)
                           '(:kind summary :end "2") '(:kind unknown :end 2)
                           '(:kind completed :end 2 :run-id "missing" :event-id "missing")
                           (plist-put (copy-tree boundary) :end 1)
                           (plist-put (copy-tree boundary) :event-id "missing")
                           (plist-put (copy-tree boundary) :run-id 10)
                           (append (copy-tree boundary) '(:text "not provenance"))))
          (let ((copy (copy-tree data)))
            (setf (plist-get (plist-get copy :provenance) :boundary) bad)
            (ert-info ((format "Invalid boundary: %S" bad))
              (should-error (emacs-agent-store--validate copy file)))))
        ;; Existing F6 clone provenance remains valid, with no boundary at all.
        (let ((clone (emacs-agent-session--clone fork)))
          (should-not (plist-member (emacs-agent-session-provenance clone) :boundary))
          (should (emacs-agent-store--snapshot clone)))))))

(ert-deftest emacs-agent-fork-historical-summary-provenance-survives-growth-and-new-cut ()
  (emacs-agent-conversation-test--fixture
    (with-temp-buffer
      (let* ((run (emacs-agent-fork-test--turn "old"))
             (session (emacs-agent-run-session run)))
        (emacs-agent-fork-test--summary session 2)
        (let* ((fork (emacs-agent-session--fork session 2))
               (provenance (copy-tree (emacs-agent-session-provenance fork))))
          (emacs-agent-fork-test--turn "continuation")
          (emacs-agent-fork-test--summary fork 4)
          (should (equal provenance (emacs-agent-session-provenance fork)))
          (emacs-agent-store-save fork)
          (let ((restored (emacs-agent-test--restore-global fork)))
            (should (equal provenance (emacs-agent-session-provenance restored)))
            (should (= (length (emacs-agent-session-messages restored)) 4))
            (should (equal (emacs-agent-session--fork-points restored) '((:kind summary :end 4))))))))))

(ert-deftest emacs-agent-fork-fresh-offline-process-restores-and-forks-without-gptel ()
  (emacs-agent-conversation-test--fixture
    (with-temp-buffer
      (let* ((run (emacs-agent-fork-test--turn "old"))
             (session (emacs-agent-run-session run)))
        (emacs-agent-fork-test--summary session 2)
        (emacs-agent-store-save session)
        (let ((result
               (emacs-agent-conversation-test--child
                `(let ((emacs-agent-data-directory ,emacs-agent-data-directory))
                   (let* ((source (emacs-agent-store--restore
                                   (emacs-agent-store--file ,(emacs-agent-session-id session))))
                          (fork (emacs-agent-session--fork source 2 "offline"))
                          (file (emacs-agent-store-save fork))
                          (id (emacs-agent-session-id fork)))
                     (remhash id emacs-agent-session--registry)
                     (let ((restored (emacs-agent-store--restore file)))
                       (prin1 (list (featurep 'gptel) (emacs-agent-session-name restored)
                                    (emacs-agent-session--fork-points restored)
                                    (length (emacs-agent-session-messages restored))
                                    (null (emacs-agent-session-active-run restored))))))))))
          (should (equal result '(nil "offline" ((:kind summary :end 2)) 2 t))))))))

(ert-deftest emacs-agent-fork-paused-run-is-not-a-boundary ()
  (emacs-agent-conversation-test--fixture
    (with-temp-buffer
      (let* ((emacs-agent-max-tool-calls 0)
             (run (emacs-agent-test--submit "paused goal"))
             (session (emacs-agent-run-session run)))
        (emacs-agent-test--calls run '(("paused-call" "(error \"must not run\")")))
        (should (eq (emacs-agent-run-status run) 'paused))
        (should-error (emacs-agent-session--fork-points session) :type 'user-error)
        (should-error (emacs-agent-session--fork session 1) :type 'user-error)
        (emacs-agent-gptel-cancel session)
        (should-not (emacs-agent-session--fork-points session))))))

(ert-deftest emacs-agent-fork-name-minibuffer-rechecks-history-and-working-buffer-origin ()
  (emacs-agent-conversation-test--fixture
    (with-temp-buffer
      (let* ((source (current-buffer))
             (run (emacs-agent-fork-test--turn "working goal"))
             (session (emacs-agent-run-session run))
             (current-prefix-arg '(4)))
        (cl-letf (((symbol-function 'called-interactively-p) (lambda (&rest _) t))
                  ((symbol-function 'read-string)
                   (lambda (&rest _) (emacs-agent-session-record run 'audit "changed during name") "stale")))
          (should-error (emacs-agent-session-fork 2) :type 'user-error))
        (let ((current-prefix-arg nil)
              (fork (emacs-agent-session-fork 2 "working fork")))
          (should (eq (emacs-agent-session-last-source-buffer fork) source))
          (should (eq (emacs-agent-session-selected nil) fork)))))))

(ert-deftest emacs-agent-fork-rejects-commitments-after-completion-and-duplicates ()
  (dolist (type '(assistant-end completed))
    (emacs-agent-conversation-test--fixture
      (with-temp-buffer
        (let* ((run (emacs-agent-fork-test--turn "completed"))
               (session (emacs-agent-run-session run)))
          (emacs-agent-session-record
           run type nil
           (when (eq type 'assistant-end)
             (list :role 'assistant :run-id (emacs-agent-run-id run) :text "late commit")))
          (should-not (emacs-agent-session--fork-points session))
          (should-error (emacs-agent-session--fork session 2) :type 'user-error))))))

(ert-deftest emacs-agent-fork-summary-midrun-can-continue-and-fork-again ()
  (emacs-agent-conversation-test--fixture
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "before tools"))
             (session (emacs-agent-run-session run)))
        (emacs-agent-test--real-tools run)
        (emacs-agent-test--complete run "FUTURE-SUFFIX")
        (emacs-agent-fork-test--summary session 1)
        (let* ((before (emacs-agent-store--snapshot session))
               (first (emacs-agent-session--fork session 1)))
          (should (= (length (emacs-agent-session-messages first)) 1))
          (let ((next (emacs-agent-fork-test--turn "new branch")))
            (should (eq (emacs-agent-run-session next) first))
            (let ((second (emacs-agent-session--fork first 3)))
              (should (= (length (emacs-agent-session-messages second)) 3))
              (should (equal (plist-get (emacs-agent-session-provenance second) :source-id)
                             (emacs-agent-session-id first)))
              (should-not (string-match-p "pair-1\\|pair-2\\|FUTURE-SUFFIX"
                                          (prin1-to-string (emacs-agent-store--snapshot second))))))
          (should (equal before (emacs-agent-store--snapshot session))))))))

(ert-deftest emacs-agent-fork-earlier-prefix-excludes-unsupported-later-history ()
  (emacs-agent-conversation-test--fixture
    (with-temp-buffer
      (let* ((run (emacs-agent-fork-test--turn "good prefix"))
             (session (emacs-agent-run-session run))
             (future (emacs-agent-test--submit "future")))
        (emacs-agent-session-record
         future 'unsupported-protocol "FUTURE-UNSUPPORTED"
         (list :role 'unsupported-protocol :run-id (emacs-agent-run-id future)
               :reason "FUTURE-UNSUPPORTED"))
        (emacs-agent-gptel--finish future 'failed "FUTURE-UNSUPPORTED")
        (let* ((fork (emacs-agent-session--fork session 2))
               (view (copy-emacs-agent-run run)))
          (setf (emacs-agent-run-session view) fork)
          (should (emacs-agent-gptel--history view))
          (should-not (string-match-p "FUTURE-UNSUPPORTED"
                                      (prin1-to-string (emacs-agent-store--snapshot fork)))))))))

(ert-deftest emacs-agent-fork-dead-working-buffer-is-not-replaced-by-journal ()
  (emacs-agent-conversation-test--fixture
    (let ((working (generate-new-buffer " *fork-dead-source*")) owner)
      (unwind-protect
          (progn
            (with-current-buffer working
              (setq owner (emacs-agent-run-session (emacs-agent-fork-test--turn "owner"))))
            (kill-buffer working)
            (with-current-buffer (emacs-agent--log-buffer owner)
              (let ((fork (emacs-agent-session-fork 2)))
                (should-not (emacs-agent-session-last-source-buffer fork))
                (with-current-buffer (emacs-agent--log-buffer fork)
                  (should-error (emacs-agent-session-origin) :type 'user-error))
                (should-not (emacs-agent-session-active-run fork)))))
        (when (buffer-live-p working) (kill-buffer working))))))

(provide 'emacs-agent-fork-test)
;;; emacs-agent-fork-test.el ends here
