;;; emacs-agent-texts-history-test.el --- Literal payload protocol tests -*- lexical-binding: t; -*-
;; Loaded last: reuse the offline adapter, native-wire and FSM fixtures.
(require 'ert)
(require 'emacs-agent-gptel)

(defconst emacs-agent-texts-test--payload
  ["quote: \"; slash: \\; literal escapes: \\n \\t \\u03bb"
   "actual newline\nactual tab\tCR\rNUL\0 λ 世界"
   "#.(error \"must remain data\") (insert \"BAD\")" ""])

(defun emacs-agent-texts-test--native (run arguments &optional stream)
  "Parse and dispatch JSON ARGUMENTS using pinned gptel for RUN.
When STREAM is non-nil, split the arguments between real SSE deltas.
Return the actual callback packet for a duplicate-delivery test."
  ;; HTTP's outer JSON reader supplies decoded text, not json-serialize's
  ;; unibyte UTF-8 transport bytes (which cannot safely be nested in JSON).
  (unless (multibyte-string-p arguments)
    (setq arguments (decode-coding-string arguments 'utf-8-unix)))
  (let* ((fsm (emacs-agent-f2-spike--dry-fsm run))
         (info (gptel-fsm-info fsm))
         packet)
    (plist-put info :callback
               (lambda (response metadata)
                 (when (eq (car-safe response) 'tool-call)
                   (setq packet (list response metadata)))
                 (emacs-agent-gptel--callback run response metadata)))
    (if stream
        (with-temp-buffer
          (let ((split (/ (length arguments) 2)))
            (dolist (call
                     (list (list :index 0 :id "literal-call" :type "function"
                                 :function (list :name "eval_elisp" :arguments (substring arguments 0 split)))
                           (list :index 0 :function (list :arguments (substring arguments split)))))
              (insert "data: "
                      (decode-coding-string
                       (json-serialize (list :choices (vector (list :delta (list :tool_calls (vector call))))))
                       'utf-8-unix)
                      "\n\n")))
          (insert "data: [DONE]\n\n")
          (goto-char (point-min))
          (gptel-curl--parse-stream (emacs-agent-run-backend run) info))
      (gptel--parse-response
       (emacs-agent-run-backend run)
       (list :choices
             (vector (list :message
                           (list :role "assistant" :content :null
                                 :tool_calls
                                 (vector (list :id "literal-call" :type "function"
                                               :function (list :name "eval_elisp" :arguments arguments))))
                           :finish_reason "tool_calls")))
       info))
    ;; Dispatch real gptel tool objects; suppress only the subsequent HTTP FSM.
    (cl-letf (((symbol-function 'gptel--fsm-transition) #'ignore))
      (gptel--handle-tool-use fsm))
    packet))

(defun emacs-agent-texts-test--wire (run)
  "Return native dry-run request data after a JSON encode/decode round trip."
  (json-parse-string (gptel--json-encode (emacs-agent-test--wire run nil))
                     :object-type 'plist :array-type 'array :null-object nil))

(defun emacs-agent-texts-test--wire-args (run)
  "Read the arguments of RUN's single historical tool call from native JSON."
  (let* ((messages (plist-get (emacs-agent-texts-test--wire run) :messages))
         (assistant (seq-find (lambda (m) (plist-get m :tool_calls)) messages))
         (call (aref (plist-get assistant :tool_calls) 0)))
    (json-parse-string (plist-get (plist-get call :function) :arguments)
                       :object-type 'plist :array-type 'array :null-object nil)))

(ert-deftest emacs-agent-texts-history-native-json-and-sse-exact-once ()
  (dolist (stream '(nil t))
    (emacs-agent-test-adapter
      (with-temp-buffer
        (let* ((emacs-agent-texts '("outer binding"))
               (run (emacs-agent-test--submit "literal payload"))
               (expression "(mapc #'insert emacs-agent-texts) (length emacs-agent-texts)")
               (args (list :texts emacs-agent-texts-test--payload :expression expression))
               (packet (emacs-agent-texts-test--native run (json-serialize args) stream))
               (session (emacs-agent-run-session run)))
          (should packet)
          (should (equal (buffer-string) (mapconcat #'identity emacs-agent-texts-test--payload "")))
          (should (equal emacs-agent-texts '("outer binding")))
          (should (= (emacs-agent-run-tool-count run) 1))
          (should (string-prefix-p "\n=> 4" (gethash "literal-call" (emacs-agent-run-tool-call-ids run))))
          (let ((events (copy-tree (emacs-agent-session-events session) t)))
            (apply #'emacs-agent-gptel--callback run packet)
            (should (equal events (emacs-agent-session-events session)))
            (should (= (emacs-agent-run-tool-count run) 1))
            (should (equal (buffer-string) (mapconcat #'identity emacs-agent-texts-test--payload ""))))
          (let ((wire-args (emacs-agent-texts-test--wire-args run))
                (record (seq-find (lambda (m) (eq (plist-get m :role) 'tool))
                                  (emacs-agent-session-messages session))))
            (should (equal (plist-get wire-args :expression) expression))
            (should (equal (plist-get wire-args :texts) emacs-agent-texts-test--payload))
            (should (vectorp (plist-get (plist-get record :args) :texts)))
            (should (equal (plist-get (plist-get record :args) :texts) emacs-agent-texts-test--payload))))))))

(ert-deftest emacs-agent-texts-history-schema-is-optional-array ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "schema"))
             (tools (plist-get (emacs-agent-texts-test--wire run) :tools))
             (function (plist-get (aref tools 0) :function))
             (parameters (plist-get function :parameters))
             (properties (plist-get parameters :properties))
             (texts (plist-get properties :texts)))
        (should (= (length tools) 1))
        (should (equal (plist-get function :name) "eval_elisp"))
        (should (equal (plist-get parameters :required) ["expression"]))
        (should (equal (plist-get (plist-get properties :expression) :type) "string"))
        (should (equal (plist-get texts :type) "array"))
        (should (equal (plist-get (plist-get texts :items) :type) "string"))))))

(ert-deftest emacs-agent-texts-history-empty-array-distinct-from-omitted ()
  (dolist (present '(nil t))
    (emacs-agent-test-adapter
      (with-temp-buffer
        (let* ((emacs-agent-texts '("must not leak"))
               (run (emacs-agent-test--submit "empty or legacy"))
               (args (append '(:expression "(insert (if emacs-agent-texts \"BAD\" \"empty\"))")
                             (when present '(:texts [])))))
          (emacs-agent-texts-test--native run (json-serialize args))
          (should (equal (buffer-string) "empty"))
          (should (= (emacs-agent-run-tool-count run) 1))
          (let ((wire (emacs-agent-texts-test--wire-args run)))
            (should (eq (not (null (plist-member wire :texts))) present))
            (when present (should (equal (plist-get wire :texts) []))))
          (should (equal emacs-agent-texts '("must not leak"))))))))

(ert-deftest emacs-agent-texts-history-native-malformed-payloads-do-not-poison ()
  (dolist (value '("null" "[1]" "[\"ok\",null]" "[[\"nested\"]]" "\"not array\"" "{}"))
    (emacs-agent-test-adapter
      (with-temp-buffer
        (let* ((run (emacs-agent-test--submit "invalid"))
               (session (emacs-agent-run-session run)))
          (emacs-agent-texts-test--native
           run (concat "{\"expression\":\"(insert \\\"BAD\\\")\",\"texts\":" value "}"))
          (should (eq (emacs-agent-run-status run) 'failed))
          (should (equal (buffer-string) ""))
          (should (= (emacs-agent-run-tool-count run) 0))
          (should-not (seq-find (lambda (m) (eq (plist-get m :role) 'tool))
                                (emacs-agent-session-messages session)))
          (should-not (seq-find (lambda (e) (eq (plist-get e :type) 'tool-call))
                                (emacs-agent-session-events session)))
          ;; A new turn must still serialize, with no rejected call in its wire.
          (let* ((next (emacs-agent-test--submit "recover"))
                 (wire (emacs-agent-texts-test--wire next)))
            (should (eq (emacs-agent-run-status next) 'requesting))
            (should-not (seq-find (lambda (m) (plist-get m :tool_calls)) (plist-get wire :messages)))))))))

(ert-deftest emacs-agent-texts-history-structural-invalid-args-before-audit ()
  (dolist (args '((:expression "(insert \"BAD\")" :texts ("list"))
                  (:expression "(insert \"BAD\")" :texts ["ok"] :texts [])
                  (:expression "(insert \"BAD\")" :expression "nil")
                  (:expression "(insert \"BAD\")" :texts [] :extra t)
                  (:texts ["missing expression"])
                  (:expression 12 :texts [])
                  (:expression "(insert \"BAD\")" :texts)))
    (emacs-agent-test-adapter
      (with-temp-buffer
        (let* ((run (emacs-agent-test--submit "invalid structure"))
               (tool (with-current-buffer (emacs-agent-run-transport-buffer run) (car gptel-tools))))
          (emacs-agent-gptel--callback
           run (list 'tool-call (list tool args #'ignore))
           (list :tool-use (list (list :id "bad" :args args))))
          (should (eq (emacs-agent-run-status run) 'failed))
          (should (equal (buffer-string) ""))
          (should (zerop (emacs-agent-run-tool-count run)))
          (should-not (seq-find (lambda (e) (eq (plist-get e :type) 'tool-call))
                                (emacs-agent-session-events (emacs-agent-run-session run)))))))))

(ert-deftest emacs-agent-texts-history-save-restore-and-inherited-wire-are-inert ()
  (emacs-agent-conversation-test--fixture
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "persist payload"))
             (session (emacs-agent-run-session run))
             (args (list :expression "(mapc #'insert emacs-agent-texts)" :texts emacs-agent-texts-test--payload)))
        (emacs-agent-texts-test--native run (json-serialize args))
        (emacs-agent-test--complete run "done")
        (let ((before (buffer-string))
              (wire (emacs-agent-texts-test--wire-args run))
              (end (length (emacs-agent-session-messages session))))
          (cl-letf (((symbol-function 'emacs-agent-eval)
                     (lambda (&rest _) (ert-fail "History operation evaluated Lisp")))
                    ((symbol-function 'gptel-curl-get-response)
                     (lambda (&rest _) (ert-fail "History operation sent HTTP"))))
            (emacs-agent-store-save session)
            (let* ((restored (emacs-agent-test--restore-global session))
                   (clone (emacs-agent-session--clone restored "literal clone"))
                   (fork (emacs-agent-session--fork restored end "literal fork")))
              (dolist (copy (list restored clone fork))
                (let ((view (copy-emacs-agent-run run)))
                  (setf (emacs-agent-run-session view) copy)
                  (should (equal (emacs-agent-texts-test--wire-args view) wire)))
                (should-not (emacs-agent-session-active-run copy))
                (should-not (emacs-agent-session-pending-runs copy))
                (emacs-agent-store-save copy)
                (let* ((again (emacs-agent-test--restore-global copy))
                       (view (copy-emacs-agent-run run)))
                  (setf (emacs-agent-run-session view) again)
                  (should (equal (emacs-agent-texts-test--wire-args view) wire))))))
          (should (equal (buffer-string) before)))))))

(ert-deftest emacs-agent-texts-history-compaction-charges-payload-and-transcribes-wire ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "summarize"))
             (payload (vector (concat "PAYLOAD-HEAD " (make-string 6000 ?世) " PAYLOAD-TAIL")))
             (args (list :expression "nil" :texts payload)))
        (emacs-agent-texts-test--native run (json-serialize args))
        (emacs-agent-test--complete run "done")
        (let* ((records (emacs-agent-session-messages (emacs-agent-run-session run)))
               (tool (seq-find (lambda (m) (eq (plist-get m :role) 'tool)) records))
               (without (copy-tree tool t))
               (messages (plist-get (emacs-agent-texts-test--wire run) :messages)))
          (setf (plist-get without :args) '(:expression "nil"))
          (should (> (- (emacs-agent-compaction--record-cost tool)
                        (emacs-agent-compaction--record-cost without)) 1400))
          ;; Same retention budget keeps a tiny call, but must summarize the payload call.
          (let* ((budget (apply #'+ (mapcar #'emacs-agent-compaction--record-cost
                                            (list without (car (last records))))))
                 (small (list (car records) without (car (last records)))))
            (should (= (plist-get (emacs-agent-compaction-plan small nil budget) :cut) 1))
            (should (= (plist-get (emacs-agent-compaction-plan records nil budget) :cut) 2)))
          (let ((transcript (emacs-agent-compaction-transcript messages 262144)))
            (should (string-match-p "PAYLOAD-HEAD" transcript))
            (should (string-match-p "texts" transcript))
            (should (string-match-p "truncated" transcript)))
          (dolist (context '(1024 3000 262144))
            (let* ((text (emacs-agent-compaction-transcript messages context))
                   (bytes (encode-coding-string text 'utf-8-unix)))
              (should (<= (length bytes) (min (* 128 1024) (/ context 3))))
              (should (equal text (decode-coding-string bytes 'utf-8-unix)))
              (should-not (string-match-p "�" text)))))))))

(ert-deftest emacs-agent-texts-history-clone-and-fork-inherit-native-args ()
  (emacs-agent-conversation-test--fixture
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "inherit"))
             (session (emacs-agent-run-session run))
             (args (list :texts emacs-agent-texts-test--payload :expression "nil")))
        (emacs-agent-texts-test--native run (json-serialize args))
        (emacs-agent-test--complete run "done")
        (let ((wire (emacs-agent-texts-test--wire-args run)))
          (cl-letf (((symbol-function 'emacs-agent-eval)
                     (lambda (&rest _) (ert-fail "Inheritance executed Lisp"))))
            (dolist (copy (list (emacs-agent-session--clone session "clone")
                               (emacs-agent-session--fork
                                session (length (emacs-agent-session-messages session)) "fork")))
              (let ((view (copy-emacs-agent-run run)))
                (setf (emacs-agent-run-session view) copy)
                (should (equal (emacs-agent-texts-test--wire-args view) wire)))
              (should-not (eq (emacs-agent-session-messages copy)
                              (emacs-agent-session-messages session)))
              (should-not (emacs-agent-session-active-run copy)))))))))

(ert-deftest emacs-agent-texts-history-fresh-offline-child-restore-is-inert ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((run (emacs-agent-test--submit "restart"))
             (session (emacs-agent-run-session run))
             ;; Also cover the UTF-8/NUL regression in an independent process.
             (args '(:expression "(error \"never replay this expression\")"
                     :texts ["世界 λ\nquote \" and slash \\ NUL\0" "#.(error \"inert\")" ""])))
        (emacs-agent-texts-test--native run (json-serialize args))
        (emacs-agent-test--complete run "handled error")
        (let* ((file (emacs-agent-store-save session))
               (program
                `(progn
                   (setq load-prefer-newer t load-path ',load-path)
                   (require 'emacs-agent-gptel)
                   (setq emacs-agent-data-directory ,emacs-agent-data-directory
                         emacs-agent-auto-save nil)
                   (cl-letf (((symbol-function 'emacs-agent-eval)
                              (lambda (&rest _) (error "Restore evaluated Lisp")))
                             ((symbol-function 'gptel-request)
                              (lambda (&rest _) (error "Restore requested HTTP")))
                             ((symbol-function 'gptel-curl-get-response)
                              (lambda (&rest _) (error "Restore sent HTTP"))))
                     (let* ((restored (emacs-agent-store--restore ,file))
                            (tool (seq-find (lambda (m) (eq (plist-get m :role) 'tool))
                                            (emacs-agent-session-messages restored))))
                       (unless (and (equal (plist-get tool :args) ',args)
                                    (not (emacs-agent-session-active-run restored))
                                    (not (emacs-agent-session-pending-runs restored)))
                         (error "Restore did not preserve inert literal arguments"))
                       (princ "literal-restore-ok"))))))
          (with-temp-buffer
            (should (= 0 (call-process (expand-file-name invocation-name invocation-directory)
                                       nil (current-buffer) nil "-Q" "--batch"
                                       "--eval" (let ((print-escape-control-characters t)
                                                      (print-escape-newlines t))
                                                  (prin1-to-string program)))))
            (should (string-match-p "literal-restore-ok" (buffer-string)))))))))

;;; emacs-agent-texts-history-test.el ends here
