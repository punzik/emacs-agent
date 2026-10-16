;;; emacs-agent-steering-spike-test.el --- F2 protocol seam regressions -*- lexical-binding: t; -*-
(require 'ert)
(require 'emacs-agent-gptel)
;; Adapter/history fixtures load first.  All HTTP is mocked.  The temporary
;; delivery handlers below are a prototype, not production steering commands.
(defvar emacs-agent-f2-spike-effects nil)

(defun emacs-agent-f2-spike--dry-fsm (run)
  "Initialize RUN's real private FSM and wire data without sending HTTP."
  (with-current-buffer (emacs-agent-run-transport-buffer run)
    (funcall emacs-agent-test--real-request
             (emacs-agent-gptel--history run)
             :system (emacs-agent-resources-system emacs-agent-system-prompt
                                                   (emacs-agent-run-instructions run))
             :dry-run t :stream nil :fsm (emacs-agent-run-request-handle run)
             :transforms '(ignore)
             :callback (apply-partially #'emacs-agent-gptel--callback run)))
  (emacs-agent-run-request-handle run))

(defun emacs-agent-f2-spike--contexts (messages)
  "Count rendered context blocks; gptel can merge adjacent user messages."
  (with-temp-buffer
    (dolist (message messages)
      (when (equal (plist-get message :role) "user")
        (insert (plist-get message :content) "\n")))
    (how-many "<emacs-context>" (point-min) (point-max))))

(ert-deftest emacs-agent-f2-spike-delivers-after-whole-batch-before-http ()
  (dolist (budget '(1 100))
    (dolist (policy '(nil current full))
      (emacs-agent-test-adapter
        (with-temp-buffer
          (insert "a\nb\n") (goto-char 1)
          (let* ((emacs-agent-max-tool-calls budget)
                 (emacs-agent-context-history policy)
                 (emacs-agent-f2-spike-effects nil)
                 (global-handlers (copy-tree gptel-request--handlers))
                 (source (current-buffer))
                 (run (emacs-agent-test--submit "initial"))
                 (initial (copy-tree (emacs-agent-run-editor-context run)))
                 (fsm (emacs-agent-f2-spike--dry-fsm run))
                 (info (gptel-fsm-info fsm))
                 pending wire)
            ;; A -> A -> B -> A: only the adjacent duplicate A may be elided.
            (push (emacs-agent-input-queue-steer run "steer-same-A" (copy-tree initial) source nil) pending)
            (goto-char 3)
            (push (emacs-agent-input-queue-steer run "steer-B" (emacs-agent-context-capture nil) source nil) pending)
            (goto-char 1)
            (push (emacs-agent-input-queue-steer run "steer-A" (emacs-agent-context-capture nil) source nil) pending)
            (setq pending (nreverse pending))
            ;; The production private WAIT wrapper owns delivery now.
            (gptel--parse-response
             (emacs-agent-run-backend run)
             '(:choices [(:message
                          (:role "assistant" :content :null
                           :tool_calls [(:id "spike-one" :type "function"
                                         :function (:name "eval_elisp" :arguments "{\"expression\":\"(push 'first emacs-agent-f2-spike-effects)\"}"))
                                        (:id "spike-two" :type "function"
                                         :function (:name "eval_elisp" :arguments "{\"expression\":\"(push 'second emacs-agent-f2-spike-effects)\"}"))])
                          :finish_reason "tool_calls")]) info)
            (let ((gptel-use-curl t))
              (cl-letf (((symbol-function 'gptel-curl-get-response)
                         (lambda (state) (setq wire (copy-tree (plist-get (gptel-fsm-info state) :data))))))
                (gptel--fsm-transition fsm 'TOOL)
                (when (= budget 1)
                  (should (eq (emacs-agent-run-status run) 'paused))
                  (should (equal emacs-agent-f2-spike-effects '(first)))
                  (should (= (length pending) 3))
                  (should-not wire)
                  (should (cl-every (lambda (i) (eq (emacs-agent-input-state i) 'queued)) pending))
                  (emacs-agent-gptel-resume (emacs-agent-run-session run)))))
            (when-let* ((failed (cl-find-if (lambda (e) (eq (plist-get e :type) 'failed))
                                            (emacs-agent-session-events (emacs-agent-run-session run)))))
              (ert-fail (plist-get failed :payload)))
            (should (equal (reverse emacs-agent-f2-spike-effects) '(first second)))
            (should (cl-every (lambda (i) (eq (emacs-agent-input-state i) 'delivered)) pending))
            (should-not (emacs-agent-session-inputs (emacs-agent-run-session run)))
            (should (= (emacs-agent-run-tool-count run) 2))
            (should (eq (emacs-agent-run-source-buffer run) source))
            (should (equal initial (emacs-agent-run-editor-context run)))
            (let* ((messages (append (plist-get wire :messages) nil))
                   (users (cl-remove-if-not (lambda (m) (equal (plist-get m :role) "user")) messages)))
              (should (= (length users) 4))
              (should (string-prefix-p "steer-same-A" (plist-get (nth 1 users) :content)))
              (should (string-prefix-p "steer-B" (plist-get (nth 2 users) :content)))
              (should (string-prefix-p "steer-A" (plist-get (nth 3 users) :content)))
              (should (= (emacs-agent-f2-spike--contexts messages)
                         (pcase policy ('full 4) ('current 3) (_ 0)))))
            (emacs-agent-test--complete run "done")
            (goto-char (point-max))
            (let* ((next (emacs-agent-test--submit "next independent"))
                   (messages (append (plist-get (emacs-agent-test--wire next policy) :messages) nil))
                   (users (cl-remove-if-not (lambda (m) (equal (plist-get m :role) "user")) messages)))
              ;; Actual parsing can merge the two consecutive steering inputs.
              (should (>= (length users) 3))
              (should (= (emacs-agent-f2-spike--contexts messages)
                         (pcase policy ('full 5) ('current 1) (_ 0)))))
            (should (equal global-handlers gptel-request--handlers))))))))

(ert-deftest emacs-agent-f2-spike-final-boundary-uses-new-run-and-fifo ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (insert "source")
      (let* ((first (emacs-agent-test--submit "first"))
             (session (emacs-agent-run-session first))
             (ordinary (emacs-agent-test--submit "already queued"))
             (fsm (emacs-agent-run-request-handle first))
             (source (current-buffer))
             (captured (emacs-agent-context-capture nil))
             (pending "steering on final boundary") converted)
        (setf (alist-get 'DONE (gptel-fsm-handlers fsm))
              (cons (lambda (_state)
                      ;; Prototype boundary policy only: production must also
                      ;; preserve prepared resource/config snapshots and limits.
                      (when pending
                        (setq converted (emacs-agent-session-enqueue session pending captured source nil)
                              pending nil)
                        (push converted emacs-agent-test--runs)
                        (emacs-agent-gptel-submit converted)))
                    (alist-get 'DONE (gptel-fsm-handlers fsm))))
        (emacs-agent-test--complete first "final answer")
        (should (eq (emacs-agent-run-status first) 'completed))
        (should-not pending)
        (should (eq (emacs-agent-session-active-run session) ordinary))
        (should (equal (emacs-agent-session-pending-runs session) (list converted)))
        (should-not (equal (emacs-agent-run-id first) (emacs-agent-run-id converted)))
        (should (equal (emacs-agent-run-editor-context converted) captured))
        (should-not (cl-find-if (lambda (m) (equal (plist-get m :text) "steering on final boundary"))
                               (emacs-agent-session-messages session)))
        (emacs-agent-test--complete ordinary "ordinary answer")
        (should (eq (emacs-agent-session-active-run session) converted))
        (let* ((messages (append (plist-get (emacs-agent-test--wire converted 'current) :messages) nil))
               (users (cl-remove-if-not (lambda (m) (equal (plist-get m :role) "user")) messages)))
          (should (= (length users) 3))
          (should (string-prefix-p "steering on final boundary" (plist-get (car (last users)) :content)))
          (should (= (cl-count-if (lambda (m) (string-match-p "<emacs-context>" (plist-get m :content))) users) 1)))
        ;; A repeated terminal transition cannot enqueue the same input again.
        (gptel--fsm-transition fsm 'DONE)
        (should-not (emacs-agent-session-pending-runs session))))))

(ert-deftest emacs-agent-f2-spike-history-input-identity-remains-strict ()
  (let ((initial '(:role user :run-id "run-A" :text "initial"))
        (steer '(:role user :run-id "run-A" :input-id "input-B" :text "steer"))
        (answer '(:role assistant :run-id "run-A" :text "answer"))
        (next '(:role user :run-id "run-C" :text "next")))
    (emacs-agent-gptel--validate-history (list initial steer answer next))
    (should-error (emacs-agent-gptel--validate-history (list initial initial)))
    (should-error (emacs-agent-gptel--validate-history (list initial steer steer)))
    (should-error (emacs-agent-gptel--validate-history (list initial next steer)))
    (should-error (emacs-agent-gptel--validate-history
                   (list initial (plist-put (copy-tree steer) :input-id ""))))
    (should-error (emacs-agent-gptel--validate-history
                   (list initial (plist-put (copy-tree steer) :input-id nil))))
    (should-error (emacs-agent-gptel--validate-history
                   (list initial (plist-put (copy-tree steer) :input-id 42))))))

(ert-deftest emacs-agent-f2-spike-dedup-compares-whole-snapshots-without-mutation ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "base"))
             (session (emacs-agent-run-session run))
             (base (copy-tree (emacs-agent-run-editor-context run)))
             (region-a (plist-put (copy-tree base) :region-active t))
             (region-b nil))
        (setq region-a (plist-put region-a :region-text "region A")
              region-b (plist-put (copy-tree region-a) :region-text "region B"))
        ;; All points equal; region text differs.  Only region-B -> region-B
        ;; elides metadata, and return to base remains visible.
        (cl-loop for context in (list region-a region-b (copy-tree region-b) base)
                 for index from 1 do
                 (emacs-agent-session-record
                  run 'steering-spike "clarification"
                  (list :role 'user :run-id (emacs-agent-run-id run)
                        :input-id (format "whole-snapshot-%s" index)
                        :text (format "clarification-%s" index) :context context)))
        (let ((stored (copy-tree (emacs-agent-session-messages session))))
          (dolist (policy '(nil current full))
            (let* ((history (emacs-agent-gptel--history run policy))
                   (texts (mapcar #'cadr history)))
              (should (= (length texts) 5))
              (should (= (cl-count-if (lambda (s) (string-match-p "<emacs-context>" s)) texts)
                         (pcase policy ('full 5) ('current 4) (_ 0))))
              (should (string-prefix-p "clarification-3" (nth 3 texts)))))
          (should (equal stored (emacs-agent-session-messages session))))))))

;;; emacs-agent-steering-spike-test.el ends here
