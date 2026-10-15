;;; emacs-agent-helpers-test.el --- Live buffer helpers -*- lexical-binding: t; -*-
(require 'ert)
(require 'emacs-agent)

(defun emacs-agent-helpers-test--texts (result)
  "Extract row texts from RESULT."
  (mapcar (lambda (row) (plist-get row :text)) (plist-get result :lines)))

(ert-deftest emacs-agent-helpers-empty-lines-and-eof ()
  (dolist (case '(("" ("")) ("\n\na\n\nb\n" ("" "" "a" "" "b" ""))
                  ("a\nb" ("a" "b")) ("a\n" ("a" ""))))
    (with-temp-buffer
      (insert (car case))
      (let* ((texts (cadr case))
             (result (emacs-agent-read-lines (current-buffer) 1 (length texts))))
        (should (equal (emacs-agent-helpers-test--texts result) texts))
        (should-not (plist-get result :truncated))
        (should (= (plist-get result :end) (point-max)))
        (cl-loop for row in (plist-get result :lines) for n from 1 do
                 (should (= (plist-get row :line) n))
                 (should (equal (plist-get row :text)
                                (buffer-substring-no-properties
                                 (plist-get row :start) (plist-get row :end)))))
        (should-error (emacs-agent-read-lines (current-buffer) 1 (1+ (length texts))))
        (let ((around (emacs-agent-read-around (current-buffer) (point-max))))
          (should (= (plist-get (plist-get around :at) :line) (length texts))))))))

(ert-deftest emacs-agent-helpers-line-14-regression ()
  "Both broken approaches misread lines; helpers ignore the user's point."
  (with-temp-buffer
    (insert "\n\n")
    (cl-loop for n from 3 to 30 do (insert (format "line-%d\n" n)))
    (goto-char (point-min)) (forward-line 13)
    (should (equal (buffer-substring-no-properties
                    (line-beginning-position 14) (line-end-position 14)) "line-27"))
    (should-not (equal (nth 13 (split-string (buffer-string) "\n" t)) "line-14"))
    (dolist (position (list (point-min) (point) (point-max)))
      (goto-char position)
      (should (equal (emacs-agent-helpers-test--texts
                      (emacs-agent-read-lines (current-buffer) 14 14)) '("line-14"))))))

(ert-deftest emacs-agent-helpers-around-unicode-tabs-and-info ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "\n\tλ-symbol xyz\nlast")
    (let* ((position 4) (original (point))
           (result (emacs-agent-read-around (buffer-name) position :before 1 :after 0))
           (at (plist-get result :at)))
      (should (= (plist-get at :position) position))
      (should (= (plist-get at :line) 2))
      (should (= (plist-get at :column) 9))
      (should (equal (plist-get at :symbol) "λ-symbol"))
      (should (= (plist-get result :point) original))
      (should (equal (emacs-agent-helpers-test--texts result) '("" "\tλ-symbol xyz")))
      (let ((info (emacs-agent-buffer-info (current-buffer))))
        (should (equal (plist-get info :buffer) (buffer-name)))
        (should-not (plist-get info :file))
        (should (plist-get info :modified))
        (should (= (plist-get info :tick) (buffer-chars-modified-tick)))
        (should (= (plist-get info :line) 3))))))

(ert-deftest emacs-agent-helpers-state-and-narrowing ()
  (save-window-excursion
    (with-temp-buffer
      (insert "one\ntwo\nthree\nfour\n")
      (set-window-buffer (selected-window) (current-buffer))
      (narrow-to-region 5 15)
      (goto-char 7) (set-mark 10) (setq mark-active t)
      (let ((state (list (point) (mark) mark-active (point-min) (point-max)
                         (buffer-string) (buffer-modified-p) (buffer-chars-modified-tick)))
            (window (selected-window))
            (window-state (list (window-buffer) (window-start) (window-point))))
        (should (equal (emacs-agent-helpers-test--texts
                        (emacs-agent-read-lines (current-buffer) 2 3)) '("two" "three")))
        (should-error (emacs-agent-read-lines (current-buffer) 1 3))
        (should-error (emacs-agent-read-around (current-buffer) 1))
        (should (equal (emacs-agent-helpers-test--texts
                        (emacs-agent-read-lines (current-buffer) 1 1 :widen t)) '("one")))
        (should (= (plist-get (plist-get (emacs-agent-read-around
                                         (current-buffer) 1 :widen t) :at) :line) 1))
        (should (= (plist-get (emacs-agent-buffer-info (current-buffer)) :line) 2))
        (should (equal state (list (point) (mark) mark-active (point-min) (point-max)
                                   (buffer-string) (buffer-modified-p)
                                   (buffer-chars-modified-tick))))
        (should (eq window (selected-window)))
        (should (equal window-state (list (window-buffer) (window-start) (window-point))))))))

(ert-deftest emacs-agent-helpers-partial-line-restriction ()
  (with-temp-buffer
    (insert "abc\ndef\nghi")
    (narrow-to-region 2 7)
    (should-error (emacs-agent-read-lines (current-buffer) 1 1))
    (should-error (emacs-agent-read-lines (current-buffer) 2 2))
    (should (equal (emacs-agent-helpers-test--texts
                    (emacs-agent-read-lines (current-buffer) 1 2 :widen t)) '("abc" "def")))
    (should (= (point-min) 2)) (should (= (point-max) 7))
    (should-error (emacs-agent-read-around (current-buffer) 5))
    (widen) (narrow-to-region 2 10)
    (should (equal (emacs-agent-helpers-test--texts
                    (emacs-agent-read-around (current-buffer) 6)) '("def")))
    (should-error (emacs-agent-read-around (current-buffer) 3))))

(ert-deftest emacs-agent-helpers-errors-and-stale-coordinates ()
  (with-temp-buffer
    (insert "live unsaved\n")
    (let ((tick (buffer-chars-modified-tick)) (buffer (current-buffer)))
      (dolist (range '((0 1) (2 1) (1 9) (1.0 1) (nil 1)))
        (should-error (emacs-agent-read-lines buffer (car range) (cadr range))))
      (should-error (emacs-agent-read-lines buffer 1 1 :limit 0))
      (should-error (emacs-agent-read-lines buffer 1 1 :from 999))
      (should-error (emacs-agent-read-around buffer 0))
      (should-error (emacs-agent-read-around buffer 999))
      (should-error (emacs-agent-read-around buffer 1 :before -1))
      (should (equal (emacs-agent-helpers-test--texts
                      (emacs-agent-read-lines buffer 1 1 :tick tick)) '("live unsaved")))
      (insert "edit")
      (should-error (emacs-agent-buffer-info buffer :tick tick))
      (should-error (emacs-agent-read-lines buffer 1 1 :tick tick))
      (should-error (emacs-agent-read-around buffer 1 :tick tick))))
  (let ((dead (generate-new-buffer "dead-helper-test")))
    (kill-buffer dead)
    (should-error (emacs-agent-buffer-info dead)))
  (should-error (emacs-agent-buffer-info "nonexistent-helper-buffer"))
  (should-error (emacs-agent-buffer-info nil)))

(ert-deftest emacs-agent-helpers-truncation-and-continuation ()
  (with-temp-buffer
    (insert "\n\nabcdef\n\nλxyz\n")
    (let ((from nil) (joined "") result positions)
      (while (progn
               (setq result (emacs-agent-read-lines (current-buffer) 1 6
                                                    :limit 3 :from from))
               (dolist (row (plist-get result :lines))
                 (push (cons (plist-get row :start) (plist-get row :text)) positions))
               (setq from (plist-get result :next-position))))
      ;; Each character (including the empty lines) is represented at its
      ;; original coordinate; no returned fragment is duplicated or skipped.
      (setq positions (nreverse positions))
      (dolist (item positions) (setq joined (concat joined (cdr item))))
      (should (equal joined "abcdefλxyz"))
      (should (equal (mapcar #'car positions) '(1 2 3 4 7 10 11 13 16)))
      (should-not (plist-get result :truncated)))))

(ert-deftest emacs-agent-helpers-evaluator-budget ()
  (with-temp-buffer
    (insert (make-string 10000 ?\") "\nλ\tend\n")
    (let ((emacs-agent-eval-output-limit 900))
      (let* ((wire (emacs-agent-eval "(emacs-agent-read-lines (current-buffer) 1 3)"))
             (result (read (substring wire 4))))
        (should (<= (length wire) 900))
        (should-not (string-match-p "\\[truncated\\]" wire))
        (should (plist-get result :truncated))
        (should (> (plist-get result :next-position) 1))
        (should (plist-get result :tick))))
    (let ((emacs-agent-eval-output-limit 20))
      (should-error (emacs-agent-read-lines (current-buffer) 1 3))
      (should-error (emacs-agent-buffer-info (current-buffer))))))

(ert-deftest emacs-agent-helpers-continuation-coverage ()
  "Many small budgets preserve every non-newline character exactly once."
  (dolist (limit '(1 2 3 4 7 32))
    (with-temp-buffer
      (insert "\n\n\tλ\"abc\n\nend\n")
      (let ((seen (make-hash-table)) (steps 0) from result)
        (while (progn
                 (should (< (cl-incf steps) 100))
                 (setq result (emacs-agent-read-lines (current-buffer) 1 6
                                                      :limit limit :from from))
                 (dolist (row (plist-get result :lines))
                   (cl-loop for pos from (plist-get row :start) below (plist-get row :end)
                            do (should-not (gethash pos seen))
                            do (puthash pos (char-after pos) seen)))
                 (let ((next (plist-get result :next-position)))
                   (when next (should (> next (or from 0))))
                   (setq from next))))
        (cl-loop for pos from 1 below (point-max)
                 unless (= (char-after pos) ?\n)
                 do (should (eql (gethash pos seen) (char-after pos))))))))

(ert-deftest emacs-agent-helpers-loaded-with-one-tool ()
  (should (featurep 'emacs-agent-helpers))
  (should (string-match-p "emacs-agent-read-around" emacs-agent-system-prompt)))

;;; emacs-agent-helpers-test.el ends here
