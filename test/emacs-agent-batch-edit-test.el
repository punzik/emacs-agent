;;; emacs-agent-batch-edit-test.el --- Atomic exact-text batches -*- lexical-binding: t; -*-
;; Loaded after emacs-agent-edit-test.el for its isolated buffer/file fixtures.
(require 'ert)
(require 'emacs-agent)

(ert-deftest emacs-agent-batch-edit-one-undo-preserves-user-history ()
  (emacs-agent-edit-test--buffer "alpha beta gamma"
    (goto-char (point-max)) (insert " user") (undo-boundary)
    (let* ((tick (plist-get (emacs-agent-buffer-info (current-buffer)) :tick))
           (result (emacs-agent-replace-texts
                    (buffer-name) '((:old "alpha" :new "A") (:old "gamma" :new "ΓΓ")
                                    (:old "beta" :new "")) :tick tick)))
      (should (equal (buffer-string) "A  ΓΓ user"))
      (should (= (plist-get result :changed) 3))
      (should (equal (plist-get result :buffer) (buffer-name)))
      (should (= (plist-get result :tick) (buffer-chars-modified-tick)))
      (should (plist-get result :modified))
      (should (< (length (prin1-to-string result)) 200)))
    (undo-only 1)
    (should (equal (buffer-string) "alpha beta gamma user"))
    (let ((last-command 'undo)) (undo-only 1))
    (should (equal (buffer-string) "alpha beta gamma"))))

(ert-deftest emacs-agent-batch-edit-validation-is-before-any-edit ()
  (emacs-agent-edit-test--buffer "alpha beta gamma"
    (let ((tick (buffer-chars-modified-tick)) (undo buffer-undo-list) (position (point)))
      (dolist (edits '(nil ((:old "" :new "x")) ((:old "alpha"))
                      ((:old "alpha" :new "A" :unknown t)) ((:old "alpha" :new 1))
                      ((:old "alpha" :new "A") (:old "missing" :new "X"))
                      ((:old "alpha" :new "A") (:old "alpha" :new "B"))
                      ((:old "alpha beta" :new "A") (:old "beta" :new "B"))
                      ((:old "alpha" :new "created") (:old "created" :new "X"))))
        (should-error (emacs-agent-replace-texts (current-buffer) edits :tick tick)))
      (should-error (emacs-agent-replace-texts
                     (current-buffer) '((:old "alpha" :new "A"))))
      (should-error (emacs-agent-replace-texts
                     (current-buffer) '((:old "alpha" :new "A")) :tick (1- tick)))
      (let ((bad (list (list :old "alpha" :new "A"))))
        (setcdr bad bad)
        (should-error (emacs-agent-replace-texts (current-buffer) bad :tick tick)))
      (should (equal (buffer-string) "alpha beta gamma"))
      (should (= tick (buffer-chars-modified-tick)))
      (should (= position (point)))
      (should (eq undo buffer-undo-list))
      (should-not (buffer-modified-p)))))

(ert-deftest emacs-agent-batch-edit-unique-including-self-overlap-and-case ()
  (emacs-agent-edit-test--buffer "aaa"
    (should-error (emacs-agent-replace-texts (current-buffer) '((:old "aa" :new "x"))
                                            :tick (buffer-chars-modified-tick)))
    (should (equal (buffer-string) "aaa")))
  (emacs-agent-edit-test--buffer "alpha ALPHA"
    (let ((case-fold-search t))
      (emacs-agent-replace-texts (current-buffer)
                                 '((:old "ALPHA" :new "B") (:old "alpha" :new "A"))
                                 :tick (buffer-chars-modified-tick)))
    (should (equal (buffer-string) "A B"))))

(ert-deftest emacs-agent-batch-edit-adjacent-ranges-and-original-text ()
  (emacs-agent-edit-test--buffer "abcd"
    ;; First NEW contains the other OLD: no sequential re-search is permitted.
    (emacs-agent-replace-texts (current-buffer)
                               '((:old "ab" :new "cd") (:old "cd" :new "ab"))
                               :tick (buffer-chars-modified-tick))
    (should (equal (buffer-string) "cdab"))
    (undo-only 1)
    (should (equal (buffer-string) "abcd"))))

(ert-deftest emacs-agent-batch-edit-noop-insertion-and-new-properties ()
  (emacs-agent-edit-test--buffer "signature old"
    (let* ((tick (buffer-chars-modified-tick)) (undo buffer-undo-list)
           (result (emacs-agent-replace-texts
                    (current-buffer) '((:old "signature" :new "signature") (:old "old" :new "old"))
                    :tick tick)))
      (should (= (plist-get result :changed) 0))
      (should (= tick (buffer-chars-modified-tick)))
      (should (eq undo buffer-undo-list))
      (should-not (buffer-modified-p)))
    (emacs-agent-replace-texts
     (current-buffer) (list (list :old "signature" :new (propertize "doc\nsignature" 'face 'bold))
                           '(:old "old" :new "")) :tick (buffer-chars-modified-tick))
    (should (equal (buffer-string) "doc\nsignature "))
    (should-not (get-text-property (point-min) 'face))
    (undo-only 1)
    (should (equal (buffer-string) "signature old"))))

(ert-deftest emacs-agent-batch-edit-read-only-and-disabled-undo ()
  (emacs-agent-edit-test--buffer "left right"
    (let ((edits '((:old "left" :new "L") (:old "right" :new "R")))
          (tick (buffer-chars-modified-tick)))
      (let ((buffer-read-only t))
        (should-error (emacs-agent-replace-texts (current-buffer) edits :tick tick)))
      (let ((buffer-undo-list t))
        (should-error (emacs-agent-replace-texts (current-buffer) edits :tick tick)))
      (put-text-property 1 5 'read-only t)
      (setq buffer-undo-list nil)
      (set-buffer-modified-p nil)
      (let ((before (buffer-string)))
        ;; Right changes first; failure deleting protected left rolls both back.
        (should-error (emacs-agent-replace-texts (current-buffer) edits
                                                :tick (buffer-chars-modified-tick)))
        (should (equal-including-properties before (buffer-string)))
        (should-not (buffer-modified-p))))))

(ert-deftest emacs-agent-batch-edit-hook-error-rolls-back-all ()
  (emacs-agent-edit-test--buffer "left right"
    (let ((calls 0))
      (let ((after-change-functions
             (list (lambda (&rest _) (when (= (cl-incf calls) 3) (error "second edit fails"))))))
        (should-error (emacs-agent-replace-texts
                       (current-buffer) '((:old "left" :new "L") (:old "right" :new "R"))
                       :tick (buffer-chars-modified-tick))))
      (should (>= calls 3)))
    (should (equal (buffer-string) "left right"))
    (should-not (buffer-modified-p))))

(ert-deftest emacs-agent-batch-edit-hook-invalidates-planned-range ()
  (emacs-agent-edit-test--buffer "left right"
    (let ((calls 0))
      (let ((after-change-functions
             (list (lambda (&rest _)
                     (when (= (cl-incf calls) 1)
                       (save-excursion (goto-char (point-min)) (insert "!")))))))
        (should-error (emacs-agent-replace-texts
                       (current-buffer) '((:old "left" :new "L") (:old "right" :new "R"))
                       :tick (buffer-chars-modified-tick)))))
    (should (equal (buffer-string) "left right"))
    (should-not (buffer-modified-p))))

(ert-deftest emacs-agent-batch-edit-hooks-moving-point-cannot-misplace-new ()
  (emacs-agent-edit-test--buffer "left right"
    (let ((before-change-functions (list (lambda (&rest _) (goto-char (point-max)))))
          (after-change-functions (list (lambda (&rest _) (goto-char (point-max))))))
      (emacs-agent-replace-texts (current-buffer) '((:old "left" :new "L"))
                                 :tick (buffer-chars-modified-tick)))
    (should (equal (buffer-string) "L right"))
    (undo-only 1)
    (should (equal (buffer-string) "left right"))))

(ert-deftest emacs-agent-batch-edit-before-hook-current-old-rejects-and-keeps-history ()
  (emacs-agent-edit-test--buffer "left right"
    (goto-char (point-max)) (insert " user") (undo-boundary)
    (let ((calls 0))
      (let ((before-change-functions
             (list (lambda (beg end)
                     (when (and (> end beg) (= (cl-incf calls) 1))
                       (save-excursion (goto-char beg) (delete-char 1) (insert "!")))))))
        (should-error (emacs-agent-replace-texts
                       (current-buffer) '((:old "right" :new "R"))
                       :tick (buffer-chars-modified-tick)))))
    (should (equal (buffer-string) "left right user"))
    (undo-only 1)
    (should (equal (buffer-string) "left right"))))

(ert-deftest emacs-agent-batch-edit-deletion-hook-anchor-tracks-prefix-edit ()
  (emacs-agent-edit-test--buffer "left right"
    (let ((calls 0))
      (let ((after-change-functions
             (list (lambda (&rest _)
                     (when (= (cl-incf calls) 1)
                       (save-excursion (goto-char (point-min)) (insert "!")))))))
        (emacs-agent-replace-texts (current-buffer) '((:old "right" :new "R"))
                                   :tick (buffer-chars-modified-tick))))
    (should (equal (buffer-string) "!left R"))
    (undo-only 1)
    (should (equal (buffer-string) "left right"))))

(ert-deftest emacs-agent-batch-edit-hook-boundaries-still-one-step ()
  (emacs-agent-edit-test--buffer "left right"
    (let ((after-change-functions (list (lambda (&rest _) (undo-boundary)))))
      (emacs-agent-replace-texts
       (current-buffer) '((:old "left" :new "L") (:old "right" :new "R"))
       :tick (buffer-chars-modified-tick)))
    (should (equal (buffer-string) "L R"))
    (undo-only 1)
    (should (equal (buffer-string) "left right"))))

(ert-deftest emacs-agent-batch-edit-budget-rolls-back-all ()
  (emacs-agent-edit-test--buffer "left right"
    (let ((emacs-agent-eval-output-limit 20))
      (should-error (emacs-agent-replace-texts
                     (current-buffer) '((:old "left" :new "L") (:old "right" :new "R"))
                     :tick (buffer-chars-modified-tick))))
    (should (equal (buffer-string) "left right"))
    (should-not (buffer-modified-p))))

(ert-deftest emacs-agent-batch-edit-narrowing-state-and-search-data ()
  (save-window-excursion
    (emacs-agent-edit-test--buffer "before\nalpha beta\nafter"
      (set-window-buffer (selected-window) (current-buffer))
      (narrow-to-region 8 19) (goto-char 10) (set-mark 16) (setq mark-active t)
      (string-match "marker" "marker")
      (let ((window (selected-window)) (search-data (match-data t))
            (tick (buffer-chars-modified-tick))
            (edits '((:old "before" :new "BEFORE!") (:old "fter" :new "FTER"))))
        (should-error (emacs-agent-replace-texts (current-buffer) edits :tick tick))
        (emacs-agent-replace-texts (current-buffer) edits :tick tick :widen t)
        (should (equal search-data (match-data t)))
        (should (eq window (selected-window)))
        (should (= (point) 11)) (should (= (mark) 17)) (should mark-active)
        (should (= (point-min) 9)) (should (= (point-max) 20))
        (should (equal (buffer-string) "alpha beta\n")))))
  (emacs-agent-edit-test--buffer "alpha alpha"
    (narrow-to-region 1 6)
    (let ((tick (buffer-chars-modified-tick)))
      (should-error (emacs-agent-replace-texts (current-buffer) '((:old "alpha" :new "A"))
                                              :tick tick :widen t))
      (emacs-agent-replace-texts (current-buffer) '((:old "alpha" :new "A")) :tick tick)
      (should (equal (buffer-string) "A")))))

(ert-deftest emacs-agent-batch-edit-narrowing-boundary-follows-native-markers ()
  (let (native)
    (emacs-agent-edit-test--buffer "left right"
      (narrow-to-region 1 6)
      (save-restriction
        (widen) (goto-char 6) (delete-region 6 11) (insert "R"))
      (setq native (list (point-min) (point-max) (buffer-string))))
    (emacs-agent-edit-test--buffer "left right"
      (narrow-to-region 1 6)
      (emacs-agent-replace-texts (current-buffer) '((:old "right" :new "R"))
                                 :tick (buffer-chars-modified-tick) :widen t)
      (should (equal native (list (point-min) (point-max) (buffer-string)))))))

(ert-deftest emacs-agent-batch-edit-save-file-time-and-undo ()
  (emacs-agent-edit-test--file
    (emacs-agent-replace-texts buffer '((:old "orig" :new "new ") (:old "inal" :new "edit"))
                               :tick (buffer-chars-modified-tick))
    (should (equal (buffer-string) "new edit\n"))
    (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) "original\n"))
    (save-buffer)
    (should (verify-visited-file-modtime))
    (should-not (buffer-modified-p))
    (undo-only 1)
    (should (equal (buffer-string) "original\n")))
  (emacs-agent-edit-test--file
    (with-temp-file file (insert "external edit\n"))
    (should-error (emacs-agent-replace-texts buffer '((:old "original" :new "x"))
                                            :tick (buffer-chars-modified-tick)))
    (should (equal (buffer-string) "original\n"))))

;;; emacs-agent-batch-edit-test.el ends here
