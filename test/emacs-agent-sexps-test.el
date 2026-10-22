;;; emacs-agent-sexps-test.el --- Reader and structural editing helpers -*- lexical-binding: t; -*-
(require 'ert)
(require 'emacs-agent-sexps)

(defmacro emacs-agent-sexps-test--buffer (text &rest body)
  "Evaluate BODY in an undo-enabled buffer containing TEXT."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (insert ,text)
     (buffer-enable-undo)
     (setq buffer-undo-list nil)
     (set-buffer-modified-p nil)
     ,@body))

(ert-deftest emacs-agent-sexps-check-reader-syntax ()
  (dolist (text '("" "; only a comment (\n" "(a [b]) \"(not a list)\" ; )\n"
                  "?\\( ?\\) ?\\\" ?\"" "'(a . b) #'ignore `[,x ,@y]"
                  "#1=(a . #1#)"))
    (emacs-agent-sexps-test--buffer text
      (should (plist-get (emacs-agent-check-sexps (current-buffer)) :ok))))
  (dolist (text '("(]" "([)]" ")" "[a)" "(a . b c)" "#.(error \"never run\")"))
    (emacs-agent-sexps-test--buffer text
      (let ((result (emacs-agent-check-sexps (current-buffer))))
        (should-not (plist-get result :ok))
        (should (equal (plist-get (plist-get result :diagnostic) :kind) "reader-error"))))))

(ert-deftest emacs-agent-sexps-check-incomplete-and-complete-prefix ()
  (dolist (case '(("(ok)\n(foo" 6 "open-list")
                  ("(ok)\n\"foo" 6 "open-string")
                  ("(ok)\n(foo \"bar" 11 "open-string")))
    (emacs-agent-sexps-test--buffer (car case)
      (let* ((result (emacs-agent-check-sexps (current-buffer)))
             (diagnostic (plist-get result :diagnostic)))
        (should-not (plist-get result :ok))
        (should (= (plist-get result :forms-read) 1))
        (should (equal (plist-get diagnostic :kind) "incomplete-form"))
        (should (= (plist-get diagnostic :position) (cadr case)))
        (should (= (plist-get diagnostic :form-start) 6))
        (should (= (plist-get diagnostic :reader-position) (point-max)))
        (should (equal (plist-get diagnostic :hint) (nth 2 case)))))))

(ert-deftest emacs-agent-sexps-check-coordinates-and-bounded-context ()
  (emacs-agent-sexps-test--buffer (concat "; λ\n\t)" (make-string 400 ?x))
    (let* ((r (emacs-agent-check-sexps (current-buffer)))
           (d (plist-get r :diagnostic)))
      (should (= (plist-get d :position) 6))
      (should (= (plist-get d :line) 2))
      (should (= (plist-get d :column) tab-width))
      (should (<= (length (plist-get d :context)) 120))
      (should (equal (plist-get d :context)
                     (buffer-substring-no-properties (plist-get d :context-start)
                                                     (plist-get d :context-end)))))))

(ert-deftest emacs-agent-sexps-check-scope-state-and-tick ()
  (emacs-agent-sexps-test--buffer ")\n(ok)\n("
    (narrow-to-region 3 7)
    (goto-char 4) (set-mark 5) (setq mark-active t)
    (set-match-data '(1 2))
    (let ((state (list (current-buffer) (point) (mark) mark-active
                       (point-min) (point-max) (buffer-chars-modified-tick)
                       buffer-undo-list (buffer-modified-p) (match-data))))
      (let ((r (emacs-agent-check-sexps (current-buffer))))
        (should (plist-get r :ok))
        (should (= (plist-get r :start) 3))
        (should (= (plist-get r :end) 7)))
      (should-not (plist-get (emacs-agent-check-sexps (current-buffer) :widen t) :ok))
      (should (plist-get (emacs-agent-check-sexps (current-buffer) :start 3 :end 7) :ok))
      (should-error (emacs-agent-check-sexps (current-buffer) :start 1))
      (should-error (emacs-agent-check-sexps (current-buffer)
                                            :tick (1- (buffer-chars-modified-tick))))
      (should (equal state (list (current-buffer) (point) (mark) mark-active
                                (point-min) (point-max) (buffer-chars-modified-tick)
                                buffer-undo-list (buffer-modified-p) (match-data)))))))

(ert-deftest emacs-agent-sexps-check-never-evaluates ()
  (let ((emacs-agent-sexps-test--executed nil))
    (emacs-agent-sexps-test--buffer "(setq emacs-agent-sexps-test--executed t)"
      (should (plist-get (emacs-agent-check-sexps (current-buffer)) :ok)))
    (should-not emacs-agent-sexps-test--executed)))

(ert-deftest emacs-agent-sexps-check-budget ()
  (emacs-agent-sexps-test--buffer "("
    (let ((emacs-agent-eval-output-limit 20))
      (should-error (emacs-agent-check-sexps (current-buffer))))
    (should (equal (buffer-string) "("))
    (should-not (buffer-modified-p))))

(defun emacs-agent-sexps-test--inspect (&rest args)
  "Parse JSON inspection of the current buffer with ARGS."
  (json-parse-string (apply #'emacs-agent-inspect-sexps (current-buffer) args)
                     :object-type 'plist :array-type 'list :false-object nil))

(ert-deftest emacs-agent-sexps-inspect-tree-and-source-ranges ()
  (emacs-agent-sexps-test--buffer "'(foo [1 \"λ\"] . bar) ; comment\n(baz)"
    (let* ((r (emacs-agent-sexps-test--inspect :depth 3))
           (prefix (car (plist-get r :nodes)))
           (list-node (car (plist-get prefix :children)))
           (parts (plist-get list-node :children)))
      (should (plist-get r :ok))
      (should-not (plist-get r :truncated))
      (should (= (length (plist-get r :nodes)) 2))
      (should (equal (plist-get prefix :kind) "prefix"))
      (should (equal (plist-get list-node :kind) "list"))
      (should (equal (mapcar (lambda (p) (plist-get p :kind)) parts)
                     '("atom" "vector" "dot" "atom")))
      (should (equal (mapcar (lambda (p) (plist-get p :kind))
                            (plist-get (nth 1 parts) :children)) '("atom" "string")))
      (cl-labels ((check (node)
                    (should (equal (plist-get node :preview)
                                   (buffer-substring-no-properties
                                    (plist-get node :start)
                                    (min (plist-get node :end)
                                         (+ (plist-get node :start) 80)))))
                    (mapc #'check (plist-get node :children))))
        (mapc #'check (plist-get r :nodes))))))

(ert-deftest emacs-agent-sexps-inspect-broken-form-retains-children ()
  (emacs-agent-sexps-test--buffer "(ok) (broken (good) [tail"
    (let* ((r (emacs-agent-sexps-test--inspect :depth 3))
           (nodes (plist-get r :nodes))
           (broken (nth 1 nodes))
           (children (plist-get broken :children)))
      (should-not (plist-get r :ok))
      (should (= (length nodes) 2))
      (should (plist-get (car nodes) :complete))
      (should-not (plist-get broken :complete))
      (should (equal (mapcar (lambda (n) (plist-get n :preview)) children)
                     '("broken" "(good)" "[tail")))
      (should-not (plist-get (nth 2 children) :complete))
      (should (equal (plist-get (car (plist-get (nth 2 children) :children)) :preview)
                     "tail")))))

(ert-deftest emacs-agent-sexps-inspect-depth-node-and-preview-limits ()
  (emacs-agent-sexps-test--buffer "(a (b c)) (d)"
    (let* ((r (emacs-agent-sexps-test--inspect :depth 0))
           (first (car (plist-get r :nodes))))
      (should-not (plist-member first :children))
      (should (plist-get first :expandable))
      (should-not (plist-get r :truncated)))
    (let* ((r (emacs-agent-sexps-test--inspect :depth 3 :limit 2))
           (first (car (plist-get r :nodes))))
      (should (plist-get r :truncated))
      (should (= (plist-get r :next-position) 11))
      (should (= (length (plist-get first :children)) 1))
      (should (plist-get first :children-truncated)))
    (dolist (args '((:depth -1) (:depth 9) (:limit 0) (:limit 1001)))
      (should-error (apply #'emacs-agent-sexps-test--inspect args))))
  (emacs-agent-sexps-test--buffer (make-string 200 ?x)
    (let ((node (car (plist-get (emacs-agent-sexps-test--inspect) :nodes))))
      (should (= (length (plist-get node :preview)) 80))
      (should (plist-get node :preview-truncated)))))

(ert-deftest emacs-agent-sexps-inspect-circular-reader-data-and-prefixes ()
  (emacs-agent-sexps-test--buffer "#1=(a . #1#) #'foo `(,x ,@y)"
    (let ((r (emacs-agent-sexps-test--inspect :depth 8)))
      (should (plist-get r :ok))
      (should (equal (plist-get (car (plist-get r :nodes)) :kind) "reader-form"))
      (should-not (plist-get r :truncated)))))

(ert-deftest emacs-agent-sexps-inspect-narrowing-json-and-evaluator ()
  (emacs-agent-sexps-test--buffer ")\n(\"quoted \\\" λ\")\n("
    (narrow-to-region 3 (- (point-max) 2))
    (let* ((tick (buffer-chars-modified-tick))
           (r (emacs-agent-sexps-test--inspect))
           (node (car (plist-get r :nodes)))
           (wire (emacs-agent-eval "(emacs-agent-inspect-sexps (current-buffer))")))
      (should (plist-get r :ok))
      (should (= (plist-get node :start) 3))
      (should (= tick (plist-get r :tick)))
      (should (string-prefix-p "\n=> " wire))
      (should (json-parse-string (read (substring wire 4)) :object-type 'plist))
      (should (= tick (buffer-chars-modified-tick)))
      (should-not buffer-undo-list)
      (should-not (buffer-modified-p))
      (let ((emacs-agent-eval-output-limit 20))
        (should-error (emacs-agent-inspect-sexps (current-buffer)))))))

(ert-deftest emacs-agent-sexps-replace-nested-expression-and-undo ()
  (emacs-agent-sexps-test--buffer "(foo (bar) baz)"
    (goto-char (point-max)) (insert " ; user") (undo-boundary)
    (let ((r (emacs-agent-replace-sexp (current-buffer) 6 11 "(bar)" "[quux]"
                                        :tick (buffer-chars-modified-tick))))
      (should (plist-get r :changed))
      (should (plist-get r :modified))
      (should (= (plist-get r :end) 12))
      (should (= (plist-get r :tick) (buffer-chars-modified-tick)))
      (should (equal (buffer-string) "(foo [quux] baz) ; user")))
    (undo-only 1)
    (should (equal (buffer-string) "(foo (bar) baz) ; user"))
    (let ((last-command 'undo)) (undo-only 1))
    (should (equal (buffer-string) "(foo (bar) baz)"))))

(ert-deftest emacs-agent-sexps-replace-rejects-invalid-boundaries-and-new ()
  (dolist (case '((2 4 "fo" "bar") (1 2 "(" "[]")
                  (2 5 "foo" "a b") (2 5 "foo" "(bar")
                  (2 5 "foo" "\"unterminated") (2 5 "foo" " bar")
                  (2 5 "foo" "bar ; comment") (2 5 "foo" ")(")
                  (2 5 "wrong" "bar")))
    (emacs-agent-sexps-test--buffer "(foo bar)"
      (let ((tick (buffer-chars-modified-tick)))
        (should-error (emacs-agent-replace-sexp
                       (current-buffer) (nth 0 case) (nth 1 case) (nth 2 case) (nth 3 case)
                       :tick tick))
        (should (equal (buffer-string) "(foo bar)"))
        (should (= tick (buffer-chars-modified-tick)))
        (should-not buffer-undo-list)
        (should-not (buffer-modified-p))))))

(ert-deftest emacs-agent-sexps-replace-repair-and-deletion ()
  (emacs-agent-sexps-test--buffer "(foo bar"
    (should-error (emacs-agent-replace-sexp (current-buffer) 6 9 "bar" "bar)"
                                            :tick (buffer-chars-modified-tick)))
    (emacs-agent-replace-sexp (current-buffer) 6 9 "bar" "baz) (quux)"
                              :tick (buffer-chars-modified-tick) :repair t)
    (should (equal (buffer-string) "(foo baz) (quux)"))
    (undo-only 1)
    (should (equal (buffer-string) "(foo bar")))
  (emacs-agent-sexps-test--buffer "(foo bar)"
    (emacs-agent-replace-sexp (current-buffer) 2 5 "foo" ""
                              :tick (buffer-chars-modified-tick))
    (should (equal (buffer-string) "( bar)")))
  ;; Repair cannot bless one fixed fragment while leaving another broken.
  (emacs-agent-sexps-test--buffer ") (foo"
    (should-error (emacs-agent-replace-sexp (current-buffer) 1 2 ")" ""
                                            :tick (buffer-chars-modified-tick) :repair t))
    (should (equal (buffer-string) ") (foo"))))

(ert-deftest emacs-agent-sexps-replace-validates-surrounding-reader-context ()
  ;; A balanced atom alone can still invalidate a dotted pair on deletion.
  (emacs-agent-sexps-test--buffer "(a . b)"
    (should-error (emacs-agent-replace-sexp (current-buffer) 6 7 "b" ""
                                            :tick (buffer-chars-modified-tick)))
    (should (equal (buffer-string) "(a . b)")))
  (emacs-agent-sexps-test--buffer "'(foo)"
    (emacs-agent-replace-sexp (current-buffer) 2 7 "(foo)" "bar"
                              :tick (buffer-chars-modified-tick))
    (should (equal (buffer-string) "'bar"))))

(ert-deftest emacs-agent-sexps-replace-noop-preserves-state ()
  (emacs-agent-sexps-test--buffer "(foo)"
    (let ((tick (buffer-chars-modified-tick)) (undo buffer-undo-list))
      (should-not (plist-get
                   (emacs-agent-replace-sexp (current-buffer) 1 6 "(foo)" "(foo)" :tick tick)
                   :changed))
      (should (= tick (buffer-chars-modified-tick)))
      (should (eq undo buffer-undo-list))
      (should-not (buffer-modified-p)))))

(ert-deftest emacs-agent-sexps-replace-hooks-invalid-result-rolls-back ()
  (emacs-agent-sexps-test--buffer "(foo)"
    (let ((calls 0))
      (let ((after-change-functions
             (list (lambda (&rest _)
                     (when (= (cl-incf calls) 2)
                       (save-excursion (goto-char (point-max)) (insert ")")))))))
        (should-error (emacs-agent-replace-sexp (current-buffer) 2 5 "foo" "bar"
                                                :tick (buffer-chars-modified-tick)))))
    (should (equal (buffer-string) "(foo)"))
    (should-not (buffer-modified-p))))

(ert-deftest emacs-agent-sexps-replace-hook-error-and-budget-roll-back ()
  (emacs-agent-sexps-test--buffer "(foo)"
    (let ((after-change-functions (list (lambda (&rest _) (error "hook failure")))))
      (should-error (emacs-agent-replace-sexp (current-buffer) 2 5 "foo" "bar"
                                              :tick (buffer-chars-modified-tick))))
    (should (equal (buffer-string) "(foo)"))
    (should-not (buffer-modified-p))
    (let ((emacs-agent-eval-output-limit 20))
      (should-error (emacs-agent-replace-sexp (current-buffer) 2 5 "foo" "bar"
                                              :tick (buffer-chars-modified-tick))))
    (should (equal (buffer-string) "(foo)"))
    (should-not (buffer-modified-p))))

(ert-deftest emacs-agent-sexps-replace-old-edit-guards ()
  (emacs-agent-sexps-test--buffer "(foo)"
    (let ((tick (buffer-chars-modified-tick)))
      (should-error (emacs-agent-replace-sexp (current-buffer) 2 5 "foo" "bar"))
      (should-error (emacs-agent-replace-sexp (current-buffer) 2 5 "foo" "bar" :tick (1- tick)))
      (let ((buffer-read-only t))
        (should-error (emacs-agent-replace-sexp (current-buffer) 2 5 "foo" "bar" :tick tick)))
      (let ((buffer-undo-list t))
        (should-error (emacs-agent-replace-sexp (current-buffer) 2 5 "foo" "bar" :tick tick)))
      (should (equal (buffer-string) "(foo)"))
      (should (= tick (buffer-chars-modified-tick)))
      (should-not buffer-undo-list))))

(ert-deftest emacs-agent-sexps-replace-narrowing-and-state-tracking ()
  (emacs-agent-sexps-test--buffer ")\n(foo)\n("
    (narrow-to-region 3 8)
    (goto-char 6) (set-mark 8) (setq mark-active t)
    (emacs-agent-replace-sexp (current-buffer) 4 7 "foo" "longer"
                              :tick (buffer-chars-modified-tick))
    (should (equal (buffer-string) "(longer)"))
    (should (= (point-min) 3))
    (should (= (point-max) 11))
    (should (= (point) 4))
    (should (= (mark) 11))
    (should mark-active)
    (should-not (plist-get (emacs-agent-check-sexps (current-buffer) :widen t) :ok))))

(ert-deftest emacs-agent-sexps-reader-constructors-never-call-user-functions ()
  (let* ((name (make-temp-name "agent-sexps-hash-"))
         (test (intern name))
         (calls 0))
    (unwind-protect
        (progn
          (define-hash-table-test test
            (lambda (a b) (cl-incf calls) (equal a b))
            (lambda (_) (cl-incf calls) 0))
          (emacs-agent-sexps-test--buffer
              (format "(#s(hash-table test %s data (a 1 b 2)) x)" name)
            (let ((tick (buffer-chars-modified-tick)))
              (should (plist-get (emacs-agent-check-sexps (current-buffer)) :ok))
              (should (plist-get (emacs-agent-sexps-test--inspect :depth 3) :ok))
              (should (= tick (buffer-chars-modified-tick))))
            (let ((pos (- (point-max) 2)))
              (emacs-agent-replace-sexp (current-buffer) pos (1+ pos) "x" "y"
                                        :tick (buffer-chars-modified-tick)))
            (should (zerop calls))))
      (unintern name))))

(ert-deftest emacs-agent-sexps-readers-isolate-symbols-and-change-hooks ()
  (let* ((name (make-temp-name "agent-sexps-uninterned-"))
         (text (format "(%s)" name)))
    (emacs-agent-sexps-test--buffer text
      (let ((after-change-functions
             (list (lambda (&rest _) (ert-fail "Inspection ran change hooks")))))
        (should (plist-get (emacs-agent-check-sexps (current-buffer)) :ok))
        (should (plist-get (emacs-agent-sexps-test--inspect) :ok)))
      (should-not (intern-soft name)))))

(ert-deftest emacs-agent-sexps-contextual-reader-label-parts ()
  (dolist (text '("(#1=(a) #1# z)" "(#1=foo '#1# z)"
                  "(#1=foo (#2=(#1#) ?\") z)" "(#1=foo #s(record #1#) z)"))
    (emacs-agent-sexps-test--buffer text
      (let* ((r (emacs-agent-sexps-test--inspect :depth 3))
             (parts (plist-get (car (plist-get r :nodes)) :children)))
        (should (plist-get r :ok))
        (should (= (length parts) 3))
        (should (cl-every (lambda (n) (plist-get n :complete)) parts))
        (should (equal (plist-get (nth 2 parts) :preview) "z")))
      (let ((pos (- (point-max) 2)))
        (emacs-agent-replace-sexp (current-buffer) pos (1+ pos) "z" "new"
                                  :tick (buffer-chars-modified-tick)))
      (should (string-suffix-p " new)" (buffer-string))))))

(ert-deftest emacs-agent-sexps-dotted-pair-reader-delimiters ()
  (dolist (tail '("(b)" "[b]" "'b" "\"b\"" "`b" "; comment\nb"))
    (emacs-agent-sexps-test--buffer (concat "(a ." tail ")")
      (let* ((r (emacs-agent-sexps-test--inspect :depth 2))
             (parts (plist-get (car (plist-get r :nodes)) :children))
             (last (nth 2 parts)))
        (should (plist-get r :ok))
        (should (= (length parts) 3))
        (should (equal (plist-get (nth 1 parts) :kind) "dot"))
        (should (plist-get last :complete))
        (emacs-agent-replace-sexp (current-buffer)
                                  (plist-get last :start) (plist-get last :end)
                                  (plist-get last :preview) "new"
                                  :tick (plist-get r :tick))
        (should (plist-get (emacs-agent-check-sexps (current-buffer)) :ok))))))

(ert-deftest emacs-agent-sexps-hook-narrowing-cannot-hide-invalid-result ()
  (emacs-agent-sexps-test--buffer "(foo)"
    (let ((calls 0))
      (let ((after-change-functions
             (list (lambda (&rest _)
                     (when (= (cl-incf calls) 2)
                       (save-excursion (goto-char (point-max)) (insert ")"))
                       (narrow-to-region 1 6))))))
        (should-error (emacs-agent-replace-sexp (current-buffer) 2 5 "foo" "bar"
                                                :tick (buffer-chars-modified-tick)))))
    (should-not (buffer-narrowed-p))
    (should (equal (buffer-string) "(foo)"))
    (should-not (buffer-modified-p))))

(ert-deftest emacs-agent-sexps-replace-external-file-conflict ()
  (let* ((file (make-temp-file "agent-sexps-" nil ".el" "(foo)"))
         (buffer (find-file-noselect file)))
    (unwind-protect
        (with-current-buffer buffer
          (setq buffer-undo-list nil)
          (with-temp-file file (insert "(external-change)"))
          (should-error (emacs-agent-replace-sexp buffer 2 5 "foo" "bar"
                                                  :tick (buffer-chars-modified-tick)))
          (should (equal (buffer-string) "(foo)"))
          (should-not (buffer-modified-p))
          (should-not buffer-undo-list))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-file file))))

(ert-deftest emacs-agent-sexps-failed-hook-validation-keeps-user-undo ()
  (emacs-agent-sexps-test--buffer "(foo)"
    (goto-char (point-max)) (insert " ; user") (undo-boundary)
    (let ((calls 0))
      (let ((after-change-functions
             (list (lambda (&rest _)
                     (when (= (cl-incf calls) 2)
                       (save-excursion (goto-char 1) (insert ")")))))))
        (should-error (emacs-agent-replace-sexp (current-buffer) 2 5 "foo" "bar"
                                                :tick (buffer-chars-modified-tick)))))
    (should (equal (buffer-string) "(foo) ; user"))
    (undo-only 1)
    (should (equal (buffer-string) "(foo)"))))

(ert-deftest emacs-agent-sexps-real-evaluator-edit-with-literal-texts ()
  (emacs-agent-sexps-test--buffer "(foo)"
    (let* ((tick (buffer-chars-modified-tick))
           (wire (emacs-agent-eval
                  (format "(emacs-agent-replace-sexp (current-buffer) 2 5 (nth 0 emacs-agent-texts) (nth 1 emacs-agent-texts) :tick %d)" tick)
                  '["foo" "\"quoted \\\" λ\""])))
      (should (string-prefix-p "\n=> " wire))
      (should (plist-get (read (substring wire 4)) :changed))
      (should (equal (buffer-string) "(\"quoted \\\" λ\")")))
    (undo-only 1)
    (should (equal (buffer-string) "(foo)"))))

(ert-deftest emacs-agent-sexps-clean-process-autoloads-use-normal-symbols ()
  ;; ERT preloads cl-extra, masking obarray bindings that break its autoload.
  (let* ((directory (file-name-directory (locate-library "emacs-agent-sexps")))
         (emacs (expand-file-name invocation-name invocation-directory))
         (expression
          "(progn
             (when (featurep 'cl-extra) (error \"cl-extra unexpectedly preloaded\"))
             (with-temp-buffer
               (insert \"(foo)\") (buffer-enable-undo)
               (emacs-agent-replace-sexp (current-buffer) 2 5 \"foo\" \"bar\"
                 :tick (buffer-chars-modified-tick))
               (unless (equal (buffer-string) \"(bar)\") (error \"Edit failed\"))
               (unless (plist-get (emacs-agent-check-sexps (current-buffer)) :ok)
                 (error \"Check failed\"))
               (json-parse-string (emacs-agent-inspect-sexps (current-buffer))))
             (princ \"sexps-clean-ok\"))"))
    (dolist (load (list (list "-l" (expand-file-name "emacs-agent-sexps.el" directory))
                       '("--eval" "(require 'emacs-agent-sexps)")))
      (with-temp-buffer
        (let ((status (apply #'call-process emacs nil t nil
                             (append (list "-Q" "--batch" "-L" directory)
                                     load (list "--eval" expression)))))
          (should (equal (list status (buffer-string)) '(0 "sexps-clean-ok"))))))))

;;; emacs-agent-sexps-test.el ends here
