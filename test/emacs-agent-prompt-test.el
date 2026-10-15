;;; emacs-agent-prompt-test.el --- Execute the actual prompt examples -*- lexical-binding: t; -*-
(require 'ert)
(require 'emacs-agent)

(defun emacs-agent-prompt-test--examples ()
  "Extract actual fenced Elisp examples from the system prompt."
  (with-temp-buffer
    (insert emacs-agent-system-prompt)
    (goto-char (point-min))
    (let (examples)
      (while (re-search-forward "^```elisp\n" nil t)
        (let ((start (point)))
          (should (search-forward "\n```" nil t))
          (push (buffer-substring-no-properties start (- (point) 4)) examples)))
      (nreverse examples))))

(defmacro emacs-agent-prompt-test--fixture (&rest body)
  "Run BODY with a disposable visited example.el buffer and FILE."
  (declare (indent 0) (debug t))
  `(let* ((directory (make-temp-file "emacs-agent-prompt-" t))
          (file (expand-file-name "example.el" directory))
          (original "old-one\nold-two\nend\n")
          (make-backup-files nil)
          buffer)
     (unwind-protect
         (progn
           ;; Never let an executable example target a user's existing buffer.
           (should-not (get-buffer "example.el"))
           (with-temp-file file (insert original))
           (setq buffer (find-file-noselect file))
           (with-current-buffer buffer
             (should (equal (buffer-name) "example.el"))
             (buffer-enable-undo)
             (setq buffer-undo-list nil)
             ,@body))
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (set-buffer-modified-p nil))
         (kill-buffer buffer))
       (delete-directory directory t))))

(ert-deftest emacs-agent-prompt-all-examples-execute-with-real-evaluator ()
  (let ((examples (emacs-agent-prompt-test--examples)))
    (should (= (length examples) 7))
    (cl-loop for source in examples for index from 0 do
             (emacs-agent-prompt-test--fixture
               (when (= index 6) (goto-char (point-max)) (insert "unsaved\n"))
               (let* ((tick (buffer-chars-modified-tick))
                      (undo buffer-undo-list)
                      (wire (emacs-agent-eval source)))
                 (should (string-prefix-p "\n=> " wire))
                 (should-not (string-match-p "\\[truncated\\]" wire))
                 (let ((value (read (substring wire 4))))
                   (pcase index
                     (0 (should (integerp value)) (should (= value tick)))
                     (1 (should (equal (plist-get value :text) original))
                        (should (= (plist-get value :tick) tick))
                        (should (= (plist-get value :total-lines) 4))
                        (should (equal (plist-get value :requested-lines) '(1 4)))
                        (should (equal (plist-get value :file) file))
                        (should (plist-member value :start))
                        (should (plist-member value :end))
                        (should (plist-member value :truncated))
                        (should-not (plist-get value :next-position)))
                     (2 (should (equal (plist-get value :text) "old-one\nold-two\n"))
                        (should (= (plist-get value :tick) tick))
                        (should (plist-get value :truncated))
                        (should (= (plist-get value :next-position) 17)))
                     (3 (should (= (plist-get value :changed) 2))
                        (should (equal (buffer-string) "new-one\nnew-two\nend\n"))
                        (undo-only 1)
                        (should (equal (buffer-string) original)))
                     (4 (should (equal (plist-get value :text) "old-one\nold-two"))
                        (should (= (plist-get (plist-get value :at) :position) 1)))
                     (5 (should (eq (plist-get value :changed) t))
                        (should (equal (buffer-string) "new-one\nold-two\nend\n"))
                        (undo-only 1)
                        (should (equal (buffer-string) original)))
                     (6 (should-not value)
                        (should-not (buffer-modified-p))
                        (should (verify-visited-file-modtime))))
                   (when (< index 3)
                     (should (= tick (buffer-chars-modified-tick)))
                     (should (eq undo buffer-undo-list)))
                   (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                                  (if (= index 6) (concat original "unsaved\n") original)))))))))

(ert-deftest emacs-agent-prompt-first-read-is-eof-safe ()
  (let* ((rows (make-list 120 "row"))
         (source (nth 1 (emacs-agent-prompt-test--examples))))
    (dolist (case (list '("" 1 "") '("one" 1 "one") '("one\n" 2 "one\n")
                        (list (mapconcat #'identity rows "\n") 120
                              (mapconcat #'identity (make-list 100 "row") "\n"))))
      (emacs-agent-prompt-test--fixture
        (erase-buffer) (insert (car case))
        (let ((wire (emacs-agent-eval source)))
          (should (string-prefix-p "\n=> " wire))
          (let ((value (read (substring wire 4))))
            (should (= (plist-get value :total-lines) (cadr case)))
            (should (equal (plist-get value :text) (nth 2 case)))
            (should (equal (plist-get value :requested-lines)
                           (list 1 (min 100 (cadr case)))))
            (should-not (plist-get value :truncated))))))))

(ert-deftest emacs-agent-prompt-continuation-example-rejects-stale-tick ()
  (emacs-agent-prompt-test--fixture
    (let ((source (nth 2 (emacs-agent-prompt-test--examples)))
          (reader (symbol-function 'emacs-agent-read-lines))
          (calls 0))
      (cl-letf (((symbol-function 'emacs-agent-read-lines)
                 (lambda (&rest args)
                   ;; Simulate a user edit after first read, before continuation.
                   (when (= (cl-incf calls) 2)
                     (save-excursion (goto-char (point-max)) (insert " user")))
                   (apply reader args))))
        (should (string-match-p "ERROR.*Stale buffer modification tick"
                                (emacs-agent-eval source))))
      (should (= calls 2))
      (should (equal (buffer-string) (concat original " user"))))))

(ert-deftest emacs-agent-prompt-examples-replace-not-inflate-old-instructions ()
  ;; Recorded pre-rewrite length, not an estimate of token usage.
  (should (< (length emacs-agent-system-prompt) 5037)))

;;; emacs-agent-prompt-test.el ends here
