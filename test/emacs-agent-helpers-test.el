;;; emacs-agent-helpers-test.el --- Live buffer helpers -*- lexical-binding: t; -*-
(require 'ert)
(require 'emacs-agent)

(defun emacs-agent-helpers-test--texts (result)
  "Split RESULT text while preserving all empty lines."
  (split-string (plist-get result :text) "\n" nil))

(ert-deftest emacs-agent-helpers-empty-lines-and-eof ()
  (dolist (case '(("" ("")) ("\n\na\n\nb\n" ("" "" "a" "" "b" ""))
                  ("a\nb" ("a" "b")) ("a\n" ("a" ""))))
    (with-temp-buffer
      (insert (car case))
      (let* ((texts (cadr case))
             (result (emacs-agent-read-lines (current-buffer) 1 (length texts))))
        (should (equal (emacs-agent-helpers-test--texts result) texts))
        (should (= (plist-get result :total-lines) (length texts)))
        (should (= (plist-get (emacs-agent-buffer-info (current-buffer)) :total-lines)
                   (length texts)))
        (should-not (plist-get result :truncated))
        (should (= (plist-get result :end) (point-max)))
        (should-not (plist-member result :lines))
        (should (= (plist-get result :start-line) 1))
        (should (= (plist-get result :end-line) (length texts)))
        (should (equal (plist-get result :text) (buffer-string)))
        (should-error (emacs-agent-read-lines (current-buffer) 1 (1+ (length texts))))
        (let ((around (emacs-agent-read-around (current-buffer) (point-max))))
          (should (= (plist-get around :total-lines) (length texts)))
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

(ert-deftest emacs-agent-helpers-total-lines-is-absolute-and-live ()
  (with-temp-buffer
    (insert "a\nb\nc\n")
    (narrow-to-region 2 4)
    (goto-char 3)
    (dolist (total '(4 5))
      (when (= total 5)
        (save-excursion
          (save-restriction (widen) (goto-char (point-max)) (insert "tail\n"))))
      (let ((state (list (point) (point-min) (point-max) (buffer-string)
                         (buffer-chars-modified-tick) (buffer-modified-p))))
        (dolist (result (list (emacs-agent-buffer-info (current-buffer))
                              (emacs-agent-read-lines (current-buffer) 2 2)
                              (emacs-agent-read-around (current-buffer) 3
                                                       :before 0 :after 0)))
          (should (= (plist-get result :total-lines) total))
          (should (plist-get result :narrowed)))
        (should (equal state (list (point) (point-min) (point-max) (buffer-string)
                                   (buffer-chars-modified-tick) (buffer-modified-p))))))))

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
               (push (cons (plist-get result :start) (plist-get result :text)) positions)
               (should (= (plist-get result :end)
                          (+ (plist-get result :start) (length (plist-get result :text)))))
               (setq from (plist-get result :next-position))))
      ;; Concatenation preserves every character, including all newlines.
      (setq positions (nreverse positions))
      (dolist (item positions) (setq joined (concat joined (cdr item))))
      (should (equal joined (buffer-string)))
      (should (equal (mapcar #'car positions) '(1 4 7 10 13)))
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
  "Many small budgets preserve every character, including newlines, once."
  (dolist (limit '(1 2 3 4 7 32))
    (with-temp-buffer
      (insert "\n\n\tλ\"abc\n\nend\n")
      (let ((seen (make-hash-table)) (steps 0) from result)
        (while (progn
                 (should (< (cl-incf steps) 100))
                 (setq result (emacs-agent-read-lines (current-buffer) 1 6
                                                      :limit limit :from from))
                 (should (equal (plist-get result :text)
                                (buffer-substring-no-properties
                                 (plist-get result :start) (plist-get result :end))))
                 (should (= (plist-get result :start-line)
                            (line-number-at-pos (plist-get result :start) t)))
                 (should (= (plist-get result :end-line)
                            (line-number-at-pos (plist-get result :end) t)))
                 (cl-loop for pos from (plist-get result :start) below (plist-get result :end)
                          do (should-not (gethash pos seen))
                          do (puthash pos (char-after pos) seen))
                 (let ((next (plist-get result :next-position)))
                   (when next
                     (should (= next (plist-get result :end)))
                     (should (> next (or from 0))))
                   (setq from next))))
        (cl-loop for pos from 1 below (point-max)
                 do (should (eql (gethash pos seen) (char-after pos))))))))

(ert-deftest emacs-agent-helpers-range-newline-and-empty-continuation ()
  (with-temp-buffer
    (insert "a\n\nb\n")
    (let* ((first (emacs-agent-read-lines (current-buffer) 1 2 :limit 1))
           (second (emacs-agent-read-lines (current-buffer) 1 2 :limit 1
                                          :from (plist-get first :next-position)
                                          :tick (plist-get first :tick)))
           (empty (emacs-agent-read-lines (current-buffer) 1 2
                                         :from (plist-get second :end))))
      (should (equal (plist-get first :text) "a"))
      (should (= (plist-get first :end) 2))
      (should (= (plist-get first :end-line) 1))
      (should (equal (plist-get second :text) "\n"))
      (should (= (plist-get second :end-line) 2))
      (should-not (plist-get second :truncated))
      (should (equal (plist-get empty :text) ""))
      (should-not (plist-get empty :truncated))
      ;; The newline after requested END is excluded, not silently consumed.
      (should (= (plist-get second :end) 3))
      (should (equal (plist-get (emacs-agent-read-lines (current-buffer) 2 2) :text) ""))
      (should (equal (plist-get (emacs-agent-read-lines (current-buffer) 1 4) :text)
                     (buffer-string))))))

(ert-deftest emacs-agent-helpers-printed-budget-continuation-is-lossless ()
  (with-temp-buffer
    (dotimes (_ 200) (insert "λ\"\\\t\n"))
    (put-text-property (point-min) (point-max) 'synthetic-property (make-string 5000 ?x))
    (let ((emacs-agent-eval-output-limit 600) (joined "") from (steps 0) result)
      (while (progn
               (should (< (cl-incf steps) 200))
               (setq result (emacs-agent-read-lines (current-buffer) 1 201 :from from))
               (let ((print-length nil) (print-level nil) (print-circle t))
                 (should (<= (+ 4 (length (prin1-to-string result))) 600)))
               (should-not (text-properties-at 0 (plist-get result :text)))
               (setq joined (concat joined (plist-get result :text))
                     from (plist-get result :next-position))))
      (should (> steps 1))
      (should (equal joined (buffer-substring-no-properties (point-min) (point-max)))))))

(ert-deftest emacs-agent-helpers-compact-output-size ()
  (with-temp-buffer
    (dotimes (i 100) (insert (format "int value_%d = %d;\n" i i)))
    (let* ((result (emacs-agent-read-lines (current-buffer) 1 100))
           (print-length nil) (print-level nil) (print-circle t)
           ;; Reconstruct the old per-line representation on synthetic text.
           (old (cl-loop for (key value) on result by #'cddr
                         unless (memq key '(:text :start-line :end-line))
                         append (list key value)))
           rows)
      (save-excursion
        (goto-char (point-min))
        (dotimes (i 100)
          (push (list :line (1+ i) :start (point) :end (line-end-position)
                      :line-end (line-end-position)
                      :text (buffer-substring-no-properties (point) (line-end-position))) rows)
          (forward-line 1)))
      (setq old (append old (list :lines (nreverse rows))))
      (let ((before (length (prin1-to-string old)))
            (after (length (prin1-to-string result))))
        (should (< after (/ before 2)))
        (should (< (- after (length (plist-get result :text))) 600))
        (message "F0c synthetic read: %d -> %d printed characters" before after)))))

(ert-deftest emacs-agent-helpers-loaded-with-one-tool ()
  (should (featurep 'emacs-agent-helpers))
  (should (string-match-p "emacs-agent-read-around" emacs-agent-system-prompt))
  (should (string-match-p "call emacs-agent-buffer-info instead of reading text again"
                          emacs-agent-system-prompt))
  (should (string-match-p "A newly obtained tick does not validate previously read text"
                          emacs-agent-system-prompt))
  (should (string-match-p
           (regexp-quote "(plist-get (emacs-agent-buffer-info \"example.el\") :tick)")
           emacs-agent-system-prompt))
  (should (string-match-p "It has no :fields argument" emacs-agent-system-prompt))
  (dolist (rule '("resume SAME START/END" "same :tick until :truncated nil"
                  "Never claim full verification from partial reads"
                  "explicitly scoped checks of changed ranges suffice"))
    (should (string-match-p (regexp-quote rule) emacs-agent-system-prompt))))

;;; emacs-agent-helpers-test.el ends here
