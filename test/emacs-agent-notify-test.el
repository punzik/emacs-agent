;;; emacs-agent-notify-test.el --- Temporary final-answer messages -*- lexical-binding: t; -*-
(require 'ert)
(require 'emacs-agent)
;; Loaded after adapter fixtures by the Makefile.

(defun emacs-agent-notify-test--rows (text window)
  "Count preview TEXT's screen rows in WINDOW without displaying a buffer."
  (with-temp-buffer
    (insert text)
    (setq-local truncate-lines nil word-wrap nil)
    (count-screen-lines (point-min) (point-max) nil window)))

(ert-deftest emacs-agent-notify-short-text-and-source-state ()
  (with-temp-buffer
    (insert "source text") (goto-char 4) (set-mark 7) (narrow-to-region 2 9)
    (let* ((window (selected-window))
           (state (list (point) (mark) (point-min) (point-max) (buffer-string)
                        (selected-window) (window-buffer window) (window-point window)))
           (text (propertize "  100% ready\nsecond\n" 'face 'bold))
           (preview (emacs-agent-log--response-preview text 3 'start (minibuffer-window))))
      (should (equal preview "100% ready\nsecond"))
      (should-not (text-properties-at 0 preview))
      (should (get-text-property 0 'face text))
      (should-not (emacs-agent-log--response-preview " \n\t" 3 'start (minibuffer-window)))
      (should (equal state (list (point) (mark) (point-min) (point-max) (buffer-string)
                                (selected-window) (window-buffer window) (window-point window)))))))

(ert-deftest emacs-agent-notify-start-end-and-one-row ()
  (let ((text "one\ntwo\nthree\nfour\nfive") (window (minibuffer-window)))
    (should (equal (emacs-agent-log--response-preview text 3 'start window) "one\ntwo\nthree..."))
    (should (equal (emacs-agent-log--response-preview text 3 'end window) "...three\nfour\nfive"))
    (should (equal (emacs-agent-log--response-preview text 1 'start window) "one..."))
    (should (equal (emacs-agent-log--response-preview text 1 'end window) "...five"))))

(ert-deftest emacs-agent-notify-bounds-wrapped-unicode-tabs-and-eob ()
  (let* ((window (minibuffer-window))
         (width (window-body-width window))
         (texts (list (make-string (* width 4) ?a)
                      (apply #'concat (make-list (* width 2) "界é"))
                      (apply #'concat (make-list width "a\tb\t"))
                      (concat "intro\n" (make-string (* width 3) ?z)))))
    (dolist (text texts)
      (dolist (lines '(1 2 3))
        (dolist (part '(start end))
          (let ((preview (emacs-agent-log--response-preview text lines part window)))
            (let ((rows (emacs-agent-notify-test--rows preview window)))
              (when (> rows lines)
                (ert-fail (list :source-prefix (substring text 0 (min 10 (length text)))
                                :source-size (length text) :limit lines :part part
                                :width width :preview preview :rows rows))))
            (should (if (eq part 'start) (string-suffix-p "..." preview)
                      (string-prefix-p "..." preview)))
            (should (> (length preview) 3))))))))

(ert-deftest emacs-agent-notify-completed-once-and-full-answer-retained ()
  (dolist (status '(completed failed cancelled))
    (emacs-agent-test-adapter
      (with-temp-buffer
        (let* ((emacs-agent-final-response-lines 3)
               (run (emacs-agent-test--submit "notify"))
               (text "100% ready\none\ntwo\nthree\nfour")
               (old-height max-mini-window-height)
               (old-log message-log-max)
               calls)
          (cl-letf (((symbol-function 'message)
                     (lambda (format &rest args)
                       (push (list format args message-log-max max-mini-window-height) calls))))
            (emacs-agent-gptel--callback run text nil)
            (should-not calls)
            (emacs-agent-gptel--callback run t nil)
            (should-not calls)
            (emacs-agent-gptel--finish run status)
            (emacs-agent-gptel--finish run status)
            (emacs-agent-gptel--callback run "late" nil))
          (should (= (length calls) (if (eq status 'completed) 1 0)))
          (when calls
            (should (equal (caar calls) "%s"))
            (should (equal (cadar calls) '("100% ready\none\ntwo...")))
            (should-not (nth 2 (car calls)))
            (should (= (nth 3 (car calls)) 3)))
          (should (equal message-log-max old-log))
          (should (equal max-mini-window-height old-height))
          (should (equal (plist-get (car (last (emacs-agent-session-messages
                                               (emacs-agent-run-session run)))) :text) text)))))))

(ert-deftest emacs-agent-notify-no-empty-final-or-tool-round-fallback ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((emacs-agent-final-response-lines 3)
             (run (emacs-agent-test--submit "tools"))
             (session (emacs-agent-run-session run)) calls)
        (cl-letf (((symbol-function 'message) (lambda (&rest args) (push args calls))))
          (emacs-agent-gptel--callback run "intermediate commentary" nil)
          (emacs-agent-gptel--callback run t nil)
          ;; Tool result is the last canonical message; no final assistant text.
          (emacs-agent-test--calls run '(("echo-tool" "(+ 1 1)")))
          (emacs-agent-gptel--finish run 'completed)
          (should-not calls)
          (let ((empty (emacs-agent-test--submit "empty")))
            (emacs-agent-test--complete empty " \n\t")
            (should (eq (emacs-agent-run-status empty) 'completed))
            (should-not calls)))
        (should (eq (emacs-agent-session-active-run session) nil))))))

(ert-deftest emacs-agent-notify-zero-disables ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let ((run (emacs-agent-test--submit "disabled")) calls)
        (cl-letf (((symbol-function 'message) (lambda (&rest args) (push args calls))))
          (emacs-agent-test--complete run "full answer"))
        (should-not calls)))))

(ert-deftest emacs-agent-notify-failure-does-not-strand-fifo ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((emacs-agent-final-response-lines 3)
             (first (emacs-agent-test--submit "first"))
             (second (emacs-agent-test--submit "second")))
        (cl-letf (((symbol-function 'message) (lambda (&rest _) (error "Echo unavailable"))))
          (emacs-agent-test--complete first "answer"))
        (should (eq (emacs-agent-run-status first) 'completed))
        (should (eq (emacs-agent-session-active-run (emacs-agent-run-session first)) second))))))

(ert-deftest emacs-agent-notify-fifo-displays-each-run-before-next-user ()
  (emacs-agent-test-adapter
    (with-temp-buffer
      (let* ((emacs-agent-final-response-lines 3)
             (first (emacs-agent-test--submit "first"))
             (second (emacs-agent-test--submit "second")) calls)
        (cl-letf (((symbol-function 'message)
                   (lambda (_format text) (push text calls))))
          (emacs-agent-test--complete first "first answer")
          (emacs-agent-test--complete second "second answer"))
        (should (equal (nreverse calls) '("first answer" "second answer")))))))

;;; emacs-agent-notify-test.el ends here
