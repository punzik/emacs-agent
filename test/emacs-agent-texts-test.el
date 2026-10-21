;;; emacs-agent-texts-test.el --- Scoped text data -*- lexical-binding: t; -*-
(require 'ert)
(require 'emacs-agent-eval)
(require 'emacs-agent-helpers)

(defvar emacs-agent-texts-test--effects 0)

(defun emacs-agent-texts-test--value (expression &optional texts)
  (let ((wire (emacs-agent-eval expression texts)))
    (should (string-prefix-p "\n=> " wire))
    (read (substring wire 4))))

(ert-deftest emacs-agent-texts-verbatim-data-not-code-or-unescape ()
  (let* ((emacs-agent-texts-test--effects 0)
         (text "(setq emacs-agent-texts-test--effects 99)\n\"quote\" \\n \\r\nλ界\r\n\0")
         (texts (vector text)))
    (should (equal (emacs-agent-texts-test--value "(car emacs-agent-texts)" texts) text))
    (should (zerop emacs-agent-texts-test--effects))
    (should (equal (aref texts 0) text))))

(ert-deftest emacs-agent-texts-scope-and-omitted-empty-calls ()
  (let ((emacs-agent-texts '("outside")))
    (should (equal (emacs-agent-texts-test--value "emacs-agent-texts" ["inside"])
                   '("inside")))
    (should (equal emacs-agent-texts '("outside")))
    (should-not (emacs-agent-texts-test--value "emacs-agent-texts"))
    (should-not (emacs-agent-texts-test--value "emacs-agent-texts" []))
    (should (equal (emacs-agent-texts-test--value "emacs-agent-texts" '("list" "input"))
                   '("list" "input")))
    (should (equal emacs-agent-texts '("outside")))))

(ert-deftest emacs-agent-texts-scope-restored-on-error-quit-and-throw ()
  (let ((emacs-agent-texts '("outside")))
    (dolist (source '("(error \"stop\")" "(signal 'quit nil)" "(list"))
      (emacs-agent-eval source ["inside"])
      (should (equal emacs-agent-texts '("outside"))))
    (should (= (catch 'outside (emacs-agent-eval "(throw 'outside 7)" ["inside"])) 7))
    (should (equal emacs-agent-texts '("outside")))))

(ert-deftest emacs-agent-texts-nested-eval-does-not-inherit-payload ()
  (should (equal
           (emacs-agent-texts-test--value
            "(list (car emacs-agent-texts) (emacs-agent-eval \"emacs-agent-texts\") (emacs-agent-eval \"emacs-agent-texts\" [\"nested\"]) (car emacs-agent-texts))"
            ["outer"])
           '("outer" "\n=> nil" "\n=> (\"nested\")" "outer"))))

(ert-deftest emacs-agent-texts-fresh-list-and-strings-cannot-mutate-arguments ()
  (dolist (input (list (vector (copy-sequence "original"))
                       (list (copy-sequence "original"))))
    (should (equal (emacs-agent-texts-test--value
                    "(aset (car emacs-agent-texts) 0 ?X) (setcar emacs-agent-texts \"changed\") emacs-agent-texts"
                    input)
                   '("changed")))
    (should (equal (elt input 0) "original"))))

(ert-deftest emacs-agent-texts-plain-copies-omit-properties-without-mutating-input ()
  (let ((text (propertize "literal" 'face 'bold)))
    (should (emacs-agent-texts-test--value
             "(not (text-properties-at 0 (car emacs-agent-texts)))" (vector text)))
    (should (eq (get-text-property 0 'face text) 'bold))))

(ert-deftest emacs-agent-texts-invalid-payload-rejected-before-effects ()
  (let ((cycle (list "cycle")) (emacs-agent-texts-test--effects 0))
    (setcdr cycle cycle)
    (dolist (input (list "not array" ["good" 7] '("good" . "bad") cycle :null :json-false))
      (should-error (emacs-agent-eval "(cl-incf emacs-agent-texts-test--effects)" input)))
    (should (zerop emacs-agent-texts-test--effects))))

(ert-deftest emacs-agent-texts-json-args-validation ()
  (dolist (args '((:expression "nil") (:expression "nil" :texts [])
                  (:texts ["old" "new"] :expression "nil")))
    (should (emacs-agent-eval--args-p args)))
  (dolist (args '((:expression "nil" :texts nil) (:expression "nil" :texts [7])
                  (:expression "nil" :texts ("not a JSON vector"))
                  (:expression "nil" :texts "string") (:expression "nil" :texts :json-false)
                  (:expression "nil" :expression "nil")
                  (:expression "nil" :texts [] :texts [])
                  (:expression "nil" :extra "bad") (:texts []) (:expression 7)
                  (:expression "nil" :texts)))
    (should-not (emacs-agent-eval--args-p args))))

(ert-deftest emacs-agent-texts-works-across-buffers-and-native-functions ()
  (with-temp-buffer
    (should (equal (emacs-agent-texts-test--value
                    "(with-temp-buffer (insert (nth 0 emacs-agent-texts)) (concat (buffer-string) (nth 1 emacs-agent-texts)))"
                    ["first\n" "second"])
                   "first\nsecond"))
    (should (zerop (buffer-size)))))

(ert-deftest emacs-agent-texts-region-old-new-preserve-native-undo ()
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "old\n")
    (undo-boundary)
    (let* ((tick (buffer-chars-modified-tick))
           (texts ["old" "new \"quoted\"\\n\n界"]))
      (emacs-agent-eval
       (format "(emacs-agent-replace-region (current-buffer) 1 4 (nth 0 emacs-agent-texts) (nth 1 emacs-agent-texts) :tick %d)" tick)
       texts)
      (should (equal (buffer-string) (concat (aref texts 1) "\n")))
      (undo-only 1)
      (should (equal (buffer-string) "old\n")))))

(ert-deftest emacs-agent-texts-batch-data-and-guards-unchanged ()
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "left right")
    (undo-boundary)
    (let* ((tick (buffer-chars-modified-tick))
           (source (format "(emacs-agent-replace-texts (current-buffer) (list (list :old (nth 0 emacs-agent-texts) :new (nth 1 emacs-agent-texts)) (list :old (nth 2 emacs-agent-texts) :new (nth 3 emacs-agent-texts))) :tick %d)" tick)))
      (emacs-agent-eval source ["left" "L" "right" "R"])
      (should (equal (buffer-string) "L R"))
      (undo-only 1)
      (should (equal (buffer-string) "left right"))
      (let ((wire (emacs-agent-eval source ["left" "L" "right" "R"])))
        (should (string-match-p "ERROR.*Stale" wire)))
      (should (equal (buffer-string) "left right"))
      (let ((buffer-read-only t))
        (should (string-match-p
                 "ERROR"
                 (emacs-agent-eval
                  "(emacs-agent-replace-region (current-buffer) 1 5 (nth 0 emacs-agent-texts) (nth 1 emacs-agent-texts))"
                  ["left" "nope"]))))
      (should (equal (buffer-string) "left right")))))

(ert-deftest emacs-agent-texts-failed-old-never-overwrites-or-saves ()
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "user's newer text")
    (let ((tick (buffer-chars-modified-tick))
          (undo buffer-undo-list))
      (let ((wire (emacs-agent-eval
                   (format "(emacs-agent-replace-region (current-buffer) 1 %d (nth 0 emacs-agent-texts) (nth 1 emacs-agent-texts) :tick %d)"
                           (point-max) tick)
                   ["stale old" "replacement"])))
        (should (string-match-p "OLD text does not match" wire)))
      (should (equal (buffer-string) "user's newer text"))
      (should (= tick (buffer-chars-modified-tick)))
      (should (eq undo buffer-undo-list)))))

(ert-deftest emacs-agent-texts-ui-retains-payload-on-result-and-details ()
  (emacs-agent-ui-test--journal
    (let ((emacs-agent-texts-test--effects 0)
          (texts ["FIRST\n\"quote\"" "PAYLOAD (setq emacs-agent-texts-test--effects 99)"]))
      (emacs-agent-session-record run 'tool-call
                                  (list :id "texts" :args (list :expression "emacs-agent-texts" :texts texts)))
      (goto-char (point-min))
      (emacs-agent-log-toggle-section)
      (should (string-match-p "texts\\[0\\]:\nFIRST" (buffer-string)))
      (search-forward "PAYLOAD")
      (let ((position (copy-marker (point))))
        (emacs-agent-session-record run 'tool-result '(:id "texts" :result "done"))
        (should (= (point) (marker-position position)))
        (should (equal (buffer-substring-no-properties (- (point) 7) (point)) "PAYLOAD"))
        (set-marker position nil))
      (emacs-agent-log-toggle-details)
      (should (string-match-p "PAYLOAD" (buffer-string)))
      (should (zerop emacs-agent-texts-test--effects)))))

(provide 'emacs-agent-texts-test)
;;; emacs-agent-texts-test.el ends here
