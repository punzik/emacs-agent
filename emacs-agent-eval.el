;;; emacs-agent-eval.el --- Unrestricted evaluation for Emacs Agent -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

;;; Commentary:
;; Trusted endpoints only: this executes arbitrary Lisp in the live editor.

;;; Code:
(require 'cl-lib)
(require 'lisp-mode)

(defgroup emacs-agent nil "An agent in the live Emacs process." :group 'applications)

(defcustom emacs-agent-data-directory (expand-file-name "emacs-agent/" user-emacs-directory)
  "Directory for session snapshots and full tool-output files.
History, reasoning and tool results can contain secrets.  Files are not
encrypted; full output files are not automatically deleted."
  :type 'directory :group 'emacs-agent)

(defcustom emacs-agent-eval-output-limit 32768
  "Maximum characters in a tool result, including the truncation notice.
Overflow returns a tail and saves full text under `emacs-agent-data-directory'.
On overflow the notice is never cut, even when it alone exceeds this limit."
  :type 'natnum :group 'emacs-agent)

(defun emacs-agent-eval--limit (text)
  "Return TEXT unchanged or a bounded tail and full-output file reference.
Save only after evaluation; a failed write never repeats the computation.
No registry or automatic cleanup is maintained."
  (if (<= (length text) emacs-agent-eval-output-limit) text
    (let* ((directory (expand-file-name "tool-output/" emacs-agent-data-directory))
           (print-length nil) (print-level nil) (print-escape-newlines t)
           file notice)
      (condition-case err
          (progn
            (dolist (dir (list emacs-agent-data-directory directory))
              (unless (file-directory-p dir)
                (make-directory dir t)
                (set-file-modes dir #o700)))
            (setq file (make-temp-file (expand-file-name "eval-" directory) nil ".txt"))
            (set-file-modes file #o600)
            (with-temp-buffer
              (insert text)
              (let ((coding-system-for-write 'utf-8-unix))
                (write-region (point-min) (point-max) file nil 'silent)))
            (setq notice (format "\n[truncated; showing tail. Full output: %S]" file)))
        ((error quit)
         (when file (ignore-errors (delete-file file)))
         (setq notice (format "\n[truncated; full output unavailable (evaluation already ran): %s]"
                              (error-message-string err)))))
      (let ((tail-length (max 0 (- emacs-agent-eval-output-limit (length notice)))))
        (concat (substring text (max 0 (- (length text) tail-length))) notice)))))

(defun emacs-agent-eval (expression)
  "Evaluate all forms in EXPRESSION, returning output and the final value.
Execution is unrestricted and synchronous, with lexical binding enabled.
Previously evaluated forms are not rolled back if a later form fails.
`princ' output is captured; `message' still goes to the normal message log.
Successful nil is printed as `nil'; errors and quits are explicitly labelled.
A string final value is printed without text properties, so ordinary buffer
reads do not serialize font-lock/eglot metadata.  The source value is not
mutated; inspect properties explicitly when needed.  Non-string values and
explicit printing inside EXPRESSION retain their normal Lisp semantics."
  (let ((output (generate-new-buffer " *emacs-agent-eval-output*"))
        (input (generate-new-buffer " *emacs-agent-eval-input*"))
        (source (current-buffer))
        value error-text)
    (unwind-protect
        (progn
          (with-current-buffer input
            (set-syntax-table emacs-lisp-mode-syntax-table)
            (insert expression)
            (goto-char (point-min)))
          (condition-case err
              (let ((standard-output output)
                    (more t))
                (while more
                  (let ((form
                         (with-current-buffer input
                           ;; Skip whitespace and comments, but do not mistake
                           ;; EOF inside an incomplete form for clean EOF.
                           (forward-comment (point-max))
                           (if (eobp) (setq more nil)
                             (read (current-buffer))))))
                    (when more
                      (setq value (with-current-buffer source (eval form t)))))))
            (quit (setq error-text "QUIT: evaluation interrupted"))
            (error (setq error-text
                         (format "ERROR %s: %s" (car err) (error-message-string err)))))
          (emacs-agent-eval--limit
           (concat (with-current-buffer output
                     (buffer-substring-no-properties (point-min) (point-max)))
                   (if error-text (concat "\n" error-text)
                     (let ((print-length nil) (print-level nil) (print-circle t))
                       (concat "\n=> "
                               (prin1-to-string
                                (if (stringp value)
                                    (substring-no-properties value)
                                  value))))))))
      (kill-buffer input)
      (kill-buffer output))))

(provide 'emacs-agent-eval)
;;; emacs-agent-eval.el ends here
