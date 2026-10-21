;;; emacs-agent-eval-diagnostics-test.el --- Evaluation feedback -*- lexical-binding: t; -*-
(require 'ert)
(require 'emacs-agent-eval)

(defvar emacs-agent-eval-diagnostics-test--effects 0)

(ert-deftest emacs-agent-eval-diagnostics-reader-string-opener ()
  (with-temp-buffer
    (let ((result (emacs-agent-eval "; header\n(list\n  \"unfinished")))
      (should (string-match-p "Phase: read; form: 1; forms completed: 0" result))
      (should (string-match-p "open string at line 3, column 2, position 18" result))
      (should (string-match-p "Reader stopped: line 3" result))
      (should (string-match-p "Current form was not evaluated" result))
      (should (string-match-p "ERROR end-of-file" result)))))

(ert-deftest emacs-agent-eval-diagnostics-reader-character-coordinates ()
  (with-temp-buffer
    (let ((result (emacs-agent-eval "; λ\n\t(list")))
      (should (string-match-p "Top-level form starts: line 2, column 1, position 6" result))
      (should (string-match-p "Reader stopped: line 2, column 6, position 11" result))
      (should (string-match-p "open list at line 2, column 1, position 6" result)))))

(ert-deftest emacs-agent-eval-diagnostics-late-reader-failure-does-not-rollback ()
  (with-temp-buffer
    (let ((emacs-agent-eval-diagnostics-test--effects 0))
      (let ((result (emacs-agent-eval
                     "(cl-incf emacs-agent-eval-diagnostics-test--effects)\n(list")))
        (should (= emacs-agent-eval-diagnostics-test--effects 1))
        (should (string-match-p "Phase: read; form: 2; forms completed: 1" result))
        (should (string-match-p "earlier effects are not rolled back" result))))))

(ert-deftest emacs-agent-eval-diagnostics-error-from-nested-read-is-eval ()
  (with-temp-buffer
    (let ((result (emacs-agent-eval "(read \"(\")")))
      (should (string-match-p "Phase: eval; form: 1; forms completed: 0" result))
      (should (string-match-p "ERROR end-of-file" result))
      (should-not (string-match-p "Reader stopped\\|Syntax hint" result)))))

(ert-deftest emacs-agent-eval-diagnostics-failing-form-effects-remain ()
  (with-temp-buffer
    (buffer-enable-undo)
    (let ((result (emacs-agent-eval "(progn (insert \"abc\") (error \"partial\"))")))
      (should (equal (buffer-string) "abc"))
      (should (string-match-p "form: 1; forms completed: 0" result))
      (should (string-match-p "Failed form may have effects; no rollback" result))
      (should (string-match-p (regexp-quote ":whole-characters (0 3)") result))
      (should (string-match-p "ERROR error: partial" result))
      (should buffer-undo-list))))

(ert-deftest emacs-agent-eval-diagnostics-raw-erase-is-visible-on-success ()
  (with-temp-buffer
    (insert "live source")
    (let ((result (emacs-agent-eval "(erase-buffer)")))
      (should (string-prefix-p "\n=> nil" result))
      (should (string-match-p "Source buffer changed" result))
      (should (string-match-p (regexp-quote ":whole-characters (11 0)") result))
      (should (string-match-p "others unchecked" result)))))

(ert-deftest emacs-agent-eval-diagnostics-narrowing-and-reader-state-preserved ()
  (with-temp-buffer
    (insert "0123456789")
    (buffer-enable-undo)
    (setq buffer-undo-list nil)
    (narrow-to-region 3 6)
    (goto-char 4)
    (set-mark 5)
    (let ((tick (buffer-chars-modified-tick)))
      (emacs-agent-eval "(list")
      (should (= (point) 4))
      (should (= (mark) 5))
      (should (= (point-min) 3))
      (should (= (point-max) 6))
      (should (= (buffer-chars-modified-tick) tick))
      (should-not buffer-undo-list))
    (let ((result (emacs-agent-eval "(insert \"x\")")))
      (should (string-match-p (regexp-quote ":whole-characters (10 11)") result))
      (should (= (point-min) 3))
      (should (= (point-max) 7)))))

(ert-deftest emacs-agent-eval-diagnostics-source-rename-and-kill ()
  (let ((buffer (generate-new-buffer " *agent-diagnostics-source*")))
    (unwind-protect
        (with-current-buffer buffer
          (let ((result (emacs-agent-eval "(rename-buffer \" *agent-diagnostics-renamed*\" t)")))
            (should (string-match-p "Source buffer changed" result))
            (should (string-match-p "agent-diagnostics-source" result))
            (should (string-match-p "agent-diagnostics-renamed" result)))
          (let ((result (emacs-agent-eval "(kill-buffer (current-buffer))")))
            (should-not (buffer-live-p buffer))
            (should (string-match-p (regexp-quote ":live (t nil)") result))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest emacs-agent-eval-diagnostics-metadata-only-change ()
  (with-temp-buffer
    (set-buffer-modified-p t)
    (let ((result (emacs-agent-eval "(set-buffer-modified-p nil)")))
      (should (string-match-p "Source buffer changed" result))
      (should (string-match-p (regexp-quote ":modified (t nil)") result)))))

(ert-deftest emacs-agent-eval-diagnostics-other-buffers-not-claimed ()
  (with-temp-buffer
    (let ((other (generate-new-buffer " *agent-diagnostics-other*")))
      (unwind-protect
          (let ((result (emacs-agent-eval
                         (format "(with-current-buffer %S (insert \"other\")) (error \"stop\")"
                                 (buffer-name other)))))
            (should (equal (with-current-buffer other (buffer-string)) "other"))
            (should-not (string-match-p "Source buffer changed" result))
            (should (string-match-p "no rollback performed" result)))
        (kill-buffer other)))))

(ert-deftest emacs-agent-eval-diagnostics-brief-bounds-large-and-circular-values ()
  (let* ((cycle (list (make-string 100000 ?x)))
         (result (emacs-agent-eval--brief cycle 100)))
    (should (<= (length result) 101))
    (setcdr cycle cycle)
    (should (<= (length (emacs-agent-eval--brief cycle 100)) 101))))

(ert-deftest emacs-agent-eval-diagnostics-failure-does-not-reexecute ()
  (with-temp-buffer
    (let ((emacs-agent-eval-diagnostics-test--effects 0))
      (cl-letf (((symbol-function 'emacs-agent-eval--brief)
                 (lambda (&rest _) (error "diagnostic printer failed"))))
        (let ((result (emacs-agent-eval
                       "(cl-incf emacs-agent-eval-diagnostics-test--effects) (error \"original\")")))
          (should (= emacs-agent-eval-diagnostics-test--effects 1))
          (should (string-match-p "diagnostics unavailable" result))
          (should (string-match-p "ERROR error: original" result)))))))

(ert-deftest emacs-agent-eval-diagnostics-comments-and-empty-success-unchanged ()
  (should (equal (emacs-agent-eval " ; comment\n \t") "\n=> nil"))
  (should (equal (emacs-agent-eval "1 ; tail") "\n=> 1")))

(ert-deftest emacs-agent-eval-diagnostics-caught-errors-and-throws-unchanged ()
  (should (equal (emacs-agent-eval "(condition-case nil (error \"caught\") (error 'handled))")
                 "\n=> handled"))
  (should (equal (emacs-agent-eval
                  "(condition-case-unless-debug nil (error \"caught\") (error 'handled))")
                 "\n=> handled"))
  (should (= (catch 'outside (emacs-agent-eval "(throw 'outside 7)")) 7)))

(ert-deftest emacs-agent-eval-diagnostics-stack-repeated-errors-and-signature ()
  (dotimes (_ 3)
    (let ((result (emacs-agent-eval "(car 42)")))
      (should (string-match-p "Frames (names only" result))
      (should (string-match-p "innermost first" result))
      (should (string-match-p "Signature (names may be generic): (car " result))
      (should (string-match-p "ERROR wrong-type-argument" result)))))

(ert-deftest emacs-agent-eval-diagnostics-stack-arity-and-undefined-functions ()
  (dolist (case '(("(car)" "car" "wrong-number-of-arguments")
                  ("(agent-eval-no-such-function)" "agent-eval-no-such-function" "void-function")))
    (let ((result (emacs-agent-eval (car case))))
      (should (string-match-p "Frames (names only" result))
      (should (string-match-p (cadr case) result))
      (should (string-match-p (concat "ERROR " (nth 2 case)) result)))))

(ert-deftest emacs-agent-eval-diagnostics-stack-does-not-open-user-debugger ()
  (let ((debugger (lambda (&rest _) (ert-fail "user debugger called")))
        (debug-on-error nil)
        (before (get-buffer "*Backtrace*")))
    (should (string-match-p "ERROR" (emacs-agent-eval "(car 42)")))
    (should-not debug-on-error)
    (should (eq before (get-buffer "*Backtrace*")))
    (should (equal (emacs-agent-eval
                    "(condition-case nil (car 42) ((debug error) 'handled))")
                   "\n=> handled"))))

(ert-deftest emacs-agent-eval-diagnostics-stack-unwind-cleanup-once ()
  (let ((emacs-agent-eval-diagnostics-test--effects 0))
    (let ((result (emacs-agent-eval
                   "(unwind-protect (car 42) (cl-incf emacs-agent-eval-diagnostics-test--effects))")))
      (should (= emacs-agent-eval-diagnostics-test--effects 1))
      (should (string-match-p "Frames (names only" result)))
    (let ((result (emacs-agent-eval "(unwind-protect (error \"first\") (error \"cleanup\"))")))
      (should (string-suffix-p "ERROR error: cleanup" result))
      (should (string-match-p "Frames (names only" result)))))

(ert-deftest emacs-agent-eval-diagnostics-stack-stale-or-inhibited-is-unavailable ()
  (let ((result (emacs-agent-eval
                 "(progn (condition-case nil (error \"caught\") ((debug error) nil)) (let ((inhibit-debugger t)) (error \"final\")))")))
    (should (string-match-p "Stack: unavailable" result))
    (should-not (string-match-p "Frames (names only" result))
    (should (string-suffix-p "ERROR error: final" result))))

(ert-deftest emacs-agent-eval-diagnostics-quit-keeps-phase-and-effects ()
  (with-temp-buffer
    (let ((result (emacs-agent-eval "(insert \"x\") (signal 'quit nil)")))
      (should (equal (buffer-string) "x"))
      (should (string-match-p "Phase: eval; form: 2; forms completed: 1" result))
      (should (string-match-p "Source buffer changed" result))
      (should (string-suffix-p "QUIT: evaluation interrupted" result))
      (should-not (string-match-p "Frames (names only" result)))))

(ert-deftest emacs-agent-eval-diagnostics-stack-never-prints-closure-environments ()
  (let ((result (emacs-agent-eval
                 "(let ((private-context \"DO-NOT-PRINT-THIS-CLOSURE\")) (funcall (lambda (x) (car x)) 42))")))
    ;; The bounded source excerpt may show submitted text; stack frames must not.
    (should (string-match-p "Frames (names only" result))
    (let ((stack (substring result (string-match "Frames (names only" result))))
      (should-not (string-match-p "DO-NOT-PRINT-THIS-CLOSURE\\|closure\\|private-context" stack)))))

(ert-deftest emacs-agent-eval-diagnostics-signature-failure-keeps-stack ()
  (cl-letf (((symbol-function 'help-function-arglist)
             (lambda (&rest _) (error "signature unavailable"))))
    (let ((result (emacs-agent-eval "(car 42)")))
      (should (string-match-p "Frames (names only" result))
      (should-not (string-match-p "Signature (" result))
      (should (string-suffix-p "ERROR wrong-type-argument: Wrong type argument: listp, 42" result)))))

(ert-deftest emacs-agent-eval-diagnostics-capture-failure-keeps-original-error ()
  (cl-letf (((symbol-function 'backtrace-frame)
             (lambda (&rest _) (error "capture unavailable"))))
    (let ((result (emacs-agent-eval "(car 42)")))
      (should (string-match-p "Stack: unavailable" result))
      (should (string-match-p "ERROR wrong-type-argument" result)))))

(provide 'emacs-agent-eval-diagnostics-test)
;;; emacs-agent-eval-diagnostics-test.el ends here
