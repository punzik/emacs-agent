;;; emacs-agent-edit-test.el --- Native edits, saving and undo -*- lexical-binding: t; -*-
(require 'ert)
(require 'emacs-agent)

(defmacro emacs-agent-edit-test--buffer (text &rest body)
  "Create undo-enabled buffer containing TEXT, then evaluate BODY."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (insert ,text)
     (buffer-enable-undo)
     (setq buffer-undo-list nil)
     (set-buffer-modified-p nil)
     ,@body))

(defmacro emacs-agent-edit-test--file (&rest body)
  "Evaluate BODY with a temporary visited file BUFFER and FILE."
  (declare (indent 0) (debug t))
  `(let* ((file (make-temp-file "emacs-agent-edit-" nil ".txt" "original\n"))
          (buffer (find-file-noselect file))
          (make-backup-files nil))
     (unwind-protect
         (with-current-buffer buffer
           (setq buffer-undo-list nil)
           ,@body)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (set-buffer-modified-p nil))
         (kill-buffer buffer))
       (delete-file file))))

(ert-deftest emacs-agent-edit-log-save-pattern-regression ()
  "The logged write-region + fake modified leaves visited-file time stale."
  (emacs-agent-edit-test--file
    (erase-buffer) (insert "logged external-looking save\n")
    (write-region (point-min) (point-max) buffer-file-name)
    (set-buffer-modified-p nil)
    (should-not (verify-visited-file-modtime))
    (should (consp buffer-undo-list))
    (should (equal (buffer-string) "logged external-looking save\n"))))

(ert-deftest emacs-agent-edit-save-buffer-keeps-undo-and-file-time ()
  (emacs-agent-edit-test--file
    (let* ((result (emacs-agent-replace-region buffer 1 9 "original" "agent edit"
                                              :tick (buffer-chars-modified-tick)))
           (tick (plist-get result :tick)))
      (should (plist-get result :changed))
      (should (plist-get result :modified))
      (should (= (plist-get result :start) 1))
      (should (= (plist-get result :end) 11))
      (should (= tick (buffer-chars-modified-tick)))
      ;; Buffer-only edit: the disk has not been touched yet.
      (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                     "original\n"))
      (save-buffer)
      (should-not (buffer-modified-p))
      (should (verify-visited-file-modtime))
      (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                     "agent edit\n"))
      (undo-only 1)
      (should (equal (buffer-string) "original\n"))
      (should (buffer-modified-p)))))

(ert-deftest emacs-agent-edit-one-step-preserves-user-history ()
  (emacs-agent-edit-test--buffer "abc"
    (goto-char (point-max)) (insert " user") (undo-boundary)
    (emacs-agent-replace-region (buffer-name) 1 4 "abc" "first"
                               :tick (buffer-chars-modified-tick))
    (emacs-agent-replace-region (current-buffer) 1 6 "first" "second"
                               :tick (buffer-chars-modified-tick))
    (undo-only 1)
    (should (equal (buffer-string) "first user"))
    (let ((last-command 'undo)) (undo-only 1))
    (should (equal (buffer-string) "abc user"))
    (let ((last-command 'undo)) (undo-only 1))
    (should (equal (buffer-string) "abc"))))

(ert-deftest emacs-agent-edit-preconditions-no-changes ()
  (emacs-agent-edit-test--buffer "abc"
    (let ((tick (buffer-chars-modified-tick)) (undo buffer-undo-list))
      (dolist (form `((emacs-agent-replace-region (current-buffer) 1 4 "bad" "x" :tick ,tick)
                      (emacs-agent-replace-region (current-buffer) 1 4 "abc" "x" :tick ,(1- tick))
                      (emacs-agent-replace-region (current-buffer) 1 4 "abc" "x")
                      (emacs-agent-replace-region (current-buffer) 0 4 "abc" "x" :tick ,tick)
                      (emacs-agent-replace-region (current-buffer) 1 5 "abc" "x" :tick ,tick)
                      (emacs-agent-replace-region (current-buffer) 4 1 "abc" "x" :tick ,tick)))
        (should-error (eval form t)))
      (let ((buffer-read-only t))
        (should-error (emacs-agent-replace-region (current-buffer) 1 4 "abc" "x" :tick tick)))
      (let ((buffer-undo-list t))
        (should-error (emacs-agent-replace-region (current-buffer) 1 4 "abc" "x" :tick tick)))
      (should (equal (buffer-string) "abc"))
      (should (= tick (buffer-chars-modified-tick)))
      (should (eq undo buffer-undo-list))
      (should-not (buffer-modified-p)))))

(ert-deftest emacs-agent-edit-mismatch-diagnostic-is-bounded-and-read-only ()
  (emacs-agent-edit-test--buffer (concat "}\n\t\"λ" (make-string 2000 ?x))
    (let* ((tick (buffer-chars-modified-tick))
           (text (buffer-string))
           (undo buffer-undo-list)
           (state (list (point) (mark) (point-min) (point-max)))
           (err (should-error
                 (emacs-agent-replace-region (current-buffer) 1 (point-max)
                                             "wrong" "replacement" :tick tick)))
           (message (error-message-string err)))
      (should (string-match-p (regexp-quote (format "[1,%d), tick %d" (point-max) tick))
                              message))
      (let ((print-escape-newlines t) (print-escape-control-characters t))
        (should (string-match-p
                 (regexp-quote (concat "actual=" (prin1-to-string (substring text 0 160))))
                 message)))
      (should (string-match-p "truncated: 160 of 2005 characters" message))
      (should (string-match-p "Reread with emacs-agent-read-lines" message))
      (should (< (length message) 700))
      (should (equal text (buffer-string)))
      (should (= tick (buffer-chars-modified-tick)))
      (should (eq undo buffer-undo-list))
      (should-not (buffer-modified-p))
      (should (equal state (list (point) (mark) (point-min) (point-max)))))))

(ert-deftest emacs-agent-edit-string-index-regression-and-reread ()
  "A string offset is not a buffer position; rejection must not edit text."
  (emacs-agent-edit-test--buffer "prefix\n}\n/** comment */\n"
    (let* ((text (buffer-string))
           (index (string-match "\n/\\*\\*" text))
           (tick (buffer-chars-modified-tick))
           (err (should-error (emacs-agent-replace-region
                               (current-buffer) index (1+ index) "\n" "\n\n" :tick tick))))
      (should (string-match-p (regexp-quote "actual=\"}\"") (error-message-string err)))
      (should (equal text (buffer-string)))
      (should (= tick (buffer-chars-modified-tick)))
      ;; Reread and use row coordinates, rather than blindly shifting offsets.
      (let* ((read (emacs-agent-read-lines (current-buffer) 2 3))
             (position (+ (plist-get read :start)
                          (string-match "\n" (plist-get read :text)))))
        (emacs-agent-replace-region (current-buffer) position (1+ position) "\n" "\n\n"
                                   :tick (plist-get read :tick)))
      (should (equal (buffer-string) "prefix\n}\n\n/** comment */\n"))
      (undo-only 1)
      (should (equal text (buffer-string))))))

(ert-deftest emacs-agent-edit-narrowed-string-index-base ()
  (emacs-agent-edit-test--buffer "prefix\n}\n/** comment */\n"
    (narrow-to-region 8 (point-max))
    (let* ((base (point-min))
           (index (string-match "/\\*\\*" (buffer-string)))
           (position (+ base index)))
      (should (= index 2))
      (should (= position 10))
      (emacs-agent-replace-region (current-buffer) position position "" "\n"
                                 :tick (buffer-chars-modified-tick))
      (should (equal (buffer-string) "}\n\n/** comment */\n"))
      (should (= (point-min) base)))))

(ert-deftest emacs-agent-edit-external-file-conflict ()
  (emacs-agent-edit-test--file
    (with-temp-file file (insert "external change\n"))
    (should-error (emacs-agent-replace-region buffer 1 9 "original" "agent"
                                             :tick (buffer-chars-modified-tick)))
    (should (equal (buffer-string) "original\n"))
    (should-not (buffer-modified-p))
    (should-not buffer-undo-list)))

(ert-deftest emacs-agent-edit-insert-delete-and-noop ()
  (emacs-agent-edit-test--buffer "aλb"
    (let ((tick (buffer-chars-modified-tick)) (undo buffer-undo-list))
      (should-not (plist-get (emacs-agent-replace-region (current-buffer) 2 3 "λ" "λ"
                                                        :tick tick) :changed))
      (should (= tick (buffer-chars-modified-tick)))
      (should (eq undo buffer-undo-list))
      (should-not (buffer-modified-p)))
    (emacs-agent-replace-region (current-buffer) 2 2 "" "\n\t"
                               :tick (buffer-chars-modified-tick))
    (should (equal (buffer-string) "a\n\tλb"))
    (emacs-agent-replace-region (current-buffer) 2 4 "\n\t" ""
                               :tick (buffer-chars-modified-tick))
    (should (equal (buffer-string) "aλb"))
    (undo-only 1)
    (should (equal (buffer-string) "a\n\tλb"))))

(ert-deftest emacs-agent-edit-hooks-rollback-and-boundaries ()
  (emacs-agent-edit-test--buffer "abc user"
    ;; A hook error after deletion must not leave half the replacement behind.
    (let ((after-change-functions
           (list (lambda (&rest _) (error "test hook failure")))))
      (should-error (emacs-agent-replace-region (current-buffer) 1 4 "abc" "new"
                                               :tick (buffer-chars-modified-tick))))
    (should (equal (buffer-string) "abc user"))
    (should-not (buffer-modified-p))
    ;; Hooks may add undo boundaries; the replacement is still one undo step.
    (let ((calls 0))
      (let ((after-change-functions
             (list (lambda (&rest _) (cl-incf calls) (undo-boundary)))))
        (emacs-agent-replace-region (current-buffer) 1 4 "abc" "new text"
                                   :tick (buffer-chars-modified-tick)))
      (should (> calls 0)))
    (undo-only 1)
    (should (equal (buffer-string) "abc user"))))

(ert-deftest emacs-agent-edit-read-only-properties-and-budget-rollback ()
  (emacs-agent-edit-test--buffer "abc"
    (put-text-property 1 4 'read-only t)
    (should-error (emacs-agent-replace-region (current-buffer) 1 4 "abc" "x"
                                             :tick (buffer-chars-modified-tick)))
    (should (equal (buffer-substring-no-properties 1 4) "abc")))
  (emacs-agent-edit-test--buffer "abc"
    (let ((emacs-agent-eval-output-limit 20))
      (should-error (emacs-agent-replace-region (current-buffer) 1 4 "abc" "new"
                                               :tick (buffer-chars-modified-tick))))
    (should (equal (buffer-string) "abc"))
    (should-not (buffer-modified-p))))

(ert-deftest emacs-agent-edit-narrowing-and-editor-state ()
  (save-window-excursion
    (emacs-agent-edit-test--buffer "abc\ndef\nghi"
      (set-window-buffer (selected-window) (current-buffer))
      (narrow-to-region 5 9)
      (goto-char 7) (set-mark 8) (setq mark-active t)
      (let ((window (selected-window))
            (tick (buffer-chars-modified-tick)))
        (should-error (emacs-agent-replace-region (current-buffer) 1 4 "abc" "ABCD"
                                                 :tick tick))
        (emacs-agent-replace-region (current-buffer) 1 4 "abc" "ABCD" :tick tick :widen t)
        (should (eq window (selected-window)))
        (should (eq (window-buffer) (current-buffer)))
        (should (= (point) 8))
        (should (= (mark) 9))
        (should mark-active)
        (should (= (point-min) 6))
        (should (= (point-max) 10))
        (should (equal (buffer-string) "def\n"))))))

(ert-deftest emacs-agent-edit-save-failure-leaves-undoable-buffer-edit ()
  (emacs-agent-edit-test--file
    (emacs-agent-replace-region buffer 1 9 "original" "new edit"
                               :tick (buffer-chars-modified-tick))
    (cl-letf (((symbol-function 'write-region)
               (lambda (&rest _) (signal 'file-error '("test write failure")))))
      (should-error (save-buffer) :type 'file-error))
    (should (equal (buffer-string) "new edit\n"))
    (should (buffer-modified-p))
    (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                   "original\n"))
    (undo-only 1)
    (should (equal (buffer-string) "original\n"))))

(ert-deftest emacs-agent-edit-region-bounds-follow-deletion-hook-anchor ()
  (emacs-agent-edit-test--buffer "left right"
    (let ((calls 0) result)
      (let ((after-change-functions
             (list (lambda (&rest _)
                     (when (= (cl-incf calls) 1)
                       (save-excursion (goto-char (point-min)) (insert "!")))))))
        (setq result (emacs-agent-replace-region (current-buffer) 6 11 "right" "R"
                                                  :tick (buffer-chars-modified-tick))))
      (should (equal (buffer-string) "!left R"))
      (should (= (plist-get result :start) 7))
      (should (= (plist-get result :end) 8))
      (should (equal (buffer-substring-no-properties (plist-get result :start)
                                                    (plist-get result :end)) "R")))
    (undo-only 1)
    (should (equal (buffer-string) "left right"))))

(ert-deftest emacs-agent-edit-eval-and-prompt ()
  (emacs-agent-edit-test--buffer "abc"
    (let* ((wire (emacs-agent-eval
                  "(emacs-agent-replace-region (current-buffer) 1 4 \"abc\" \"xyz\" :tick (buffer-chars-modified-tick))"))
           (result (read (substring wire 4))))
      (should (plist-get result :changed))
      (should (equal (buffer-string) "xyz"))
      (undo-only 1)
      (should (equal (buffer-string) "abc"))))
  (should (string-match-p "emacs-agent-replace-region" emacs-agent-system-prompt))
  (should (string-match-p "save-buffer" emacs-agent-system-prompt))
  (should (string-match-p (regexp-quote "BASE+I") emacs-agent-system-prompt))
  (should (string-match-p "On mismatch/stale tick reread/recompute" emacs-agent-system-prompt))
  (should (string-match-p "never bypass rejection" emacs-agent-system-prompt)))

;;; emacs-agent-edit-test.el ends here
