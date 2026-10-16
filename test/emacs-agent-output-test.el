;;; emacs-agent-output-test.el --- Full output with a bounded tail -*- lexical-binding: t; -*-
(require 'ert)
(require 'emacs-agent-eval)

(defvar emacs-agent-output-test--effects 0)

(defmacro emacs-agent-output-test--private (&rest body)
  "Run BODY with disposable output storage."
  (declare (indent 0) (debug t))
  `(let* ((private (make-temp-file "agent-output-" t))
          (emacs-agent-data-directory (expand-file-name "data/" private))
          (emacs-agent-eval-output-limit 400))
     (unwind-protect (progn ,@body) (delete-directory private t))))

(defun emacs-agent-output-test--file (result)
  "Read only the quoted file name in RESULT's generated notice, never eval."
  (should (string-match "Full output: " result))
  (let ((file (car (read-from-string result (match-end 0)))))
    (should (stringp file))
    file))

(defun emacs-agent-output-test--read (file)
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(ert-deftest emacs-agent-output-no-overflow-does-not-touch-storage ()
  (emacs-agent-output-test--private
    (let ((emacs-agent-eval-output-limit 7))
      (should (equal (emacs-agent-eval "42") "\n=> 42"))
      (should (equal (emacs-agent-eval--limit "1234567") "1234567")))
    (should-not (file-exists-p emacs-agent-data-directory))))

(ert-deftest emacs-agent-output-tail-preserves-final-value-and-full-text ()
  (emacs-agent-output-test--private
    (let* ((emacs-agent-output-test--effects 0)
           (result (emacs-agent-eval
                    "(cl-incf emacs-agent-output-test--effects) (princ (make-string 2000 ?x)) 42"))
           (file (emacs-agent-output-test--file result))
           (full (concat (make-string 2000 ?x) "\n=> 42")))
      (should (= emacs-agent-output-test--effects 1))
      (should (<= (length result) emacs-agent-eval-output-limit))
      (should (string-match-p "\n=> 42\n\\[truncated" result))
      (should (equal (emacs-agent-output-test--read file) full))
      (should (= (logand (file-modes file) #o777) #o600))
      (should (= (logand (file-modes (file-name-directory file)) #o777) #o700))
      (should (= (logand (file-modes emacs-agent-data-directory) #o777) #o700)))))

(ert-deftest emacs-agent-output-errors-quits-and-nil-survive-noisy-stdout ()
  (emacs-agent-output-test--private
    (dolist (case '(("nil" . "\n=> nil")
                    ("(error \"END-ERROR\")" . "\nERROR error: END-ERROR")
                    ("(signal 'quit nil)" . "\nQUIT: evaluation interrupted")))
      (let* ((result (emacs-agent-eval (concat "(princ (make-string 2000 ?x)) " (car case))))
             (file (emacs-agent-output-test--file result)))
        (should (string-match-p (regexp-quote (cdr case)) result))
        (should (equal (emacs-agent-output-test--read file)
                       (concat (make-string 2000 ?x) (cdr case))))))))

(ert-deftest emacs-agent-output-huge-value-unicode-and-quoted-path ()
  (emacs-agent-output-test--private
    (let* ((emacs-agent-data-directory (expand-file-name "λ\"quoted\n/" emacs-agent-data-directory))
           (result (emacs-agent-eval "(make-string 2000 ?λ)"))
           (file (emacs-agent-output-test--file result)))
      (should (<= (length result) emacs-agent-eval-output-limit))
      (should (equal (emacs-agent-output-test--read file)
                     (concat "\n=> \"" (make-string 2000 ?λ) "\"")))
      (should (string-prefix-p "λ" result))
      (should (string-match-p "λ\"\n\\[truncated" result))
      ;; The notice quotes and escapes the path, so it remains readable Lisp.
      (should (string-match-p (regexp-quote "\\n") result)))))

(ert-deftest emacs-agent-output-tiny-budget-keeps-complete-reference ()
  (emacs-agent-output-test--private
    (dolist (limit '(0 1 20))
      (let* ((emacs-agent-eval-output-limit limit)
             (result (emacs-agent-eval "(make-string 1000 ?x)"))
             (file (emacs-agent-output-test--file result)))
        (should (string-prefix-p "\n[truncated" result))
        (should (file-exists-p file))
        (should (> (length result) limit))))))

(ert-deftest emacs-agent-output-file-creation-failure-does-not-repeat-eval ()
  (emacs-agent-output-test--private
    (let ((emacs-agent-output-test--effects 0))
      (cl-letf (((symbol-function 'make-temp-file)
                 (lambda (&rest _) (error "Cannot create output file"))))
        (let ((result (emacs-agent-eval
                       "(cl-incf emacs-agent-output-test--effects) (princ (make-string 2000 ?x)) 17")))
          (should (= emacs-agent-output-test--effects 1))
          (should (string-match-p "\n=> 17" result))
          (should (string-match-p "full output unavailable" result))
          (should-not (string-match-p "Full output:" result)))))))

(ert-deftest emacs-agent-output-partial-write-failure-cleans-file-and-keeps-error ()
  (emacs-agent-output-test--private
    (let ((emacs-agent-output-test--effects 0)
          (write (symbol-function 'write-region)))
      (cl-letf (((symbol-function 'write-region)
                 (lambda (start _end file &rest _)
                   (funcall write start (min (+ start 10) (point-max)) file nil 'silent)
                   (error "Disk full after partial write"))))
        (let ((result (emacs-agent-eval
                       "(cl-incf emacs-agent-output-test--effects) (princ (make-string 2000 ?x)) (error \"END-ERROR\")")))
          (should (= emacs-agent-output-test--effects 1))
          (should (string-match-p "ERROR error: END-ERROR" result))
          (should (string-match-p "full output unavailable" result))
          (should-not (string-match-p "Full output:" result))))
      (should-not (directory-files (expand-file-name "tool-output/" emacs-agent-data-directory)
                                  nil "\\.txt\\'")))))

(ert-deftest emacs-agent-output-save-quit-is-explicit-without-reexecution ()
  (emacs-agent-output-test--private
    (let ((emacs-agent-output-test--effects 0))
      (cl-letf (((symbol-function 'write-region) (lambda (&rest _) (signal 'quit nil))))
        (let ((result (emacs-agent-eval
                       "(cl-incf emacs-agent-output-test--effects) (princ (make-string 2000 ?x)) 42")))
          (should (= emacs-agent-output-test--effects 1))
          (should (string-match-p "full output unavailable" result))))
      (should-not (directory-files (expand-file-name "tool-output/" emacs-agent-data-directory)
                                  nil "\\.txt\\'")))))

(ert-deftest emacs-agent-output-separate-files-remain-until-explicitly-deleted ()
  (emacs-agent-output-test--private
    (let* ((first (emacs-agent-output-test--file (emacs-agent-eval "(make-string 2000 ?x)")))
           (second (emacs-agent-output-test--file (emacs-agent-eval "(make-string 2000 ?y)"))))
      (should-not (equal first second))
      (should (file-exists-p first))
      (should (file-exists-p second))
      (delete-file first)
      (should (file-exists-p second)))))

;;; emacs-agent-output-test.el ends here
