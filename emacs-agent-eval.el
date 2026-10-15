;;; emacs-agent-eval.el --- Unrestricted evaluation for Emacs Agent -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

;;; Commentary:
;; Trusted endpoints only: this executes arbitrary Lisp in the live editor.

;;; Code:
(require 'cl-lib)
(require 'lisp-mode)

(defgroup emacs-agent nil "An agent in the live Emacs process." :group 'applications)

(defcustom emacs-agent-eval-output-limit 32768
  "Maximum characters in a tool result, including the truncation notice.
Values below the notice length are treated as the notice length."
  :type 'natnum :group 'emacs-agent)

(defun emacs-agent-eval--limit (text)
  "Limit TEXT without changing the computation that produced it."
  (let* ((notice "\n[truncated]")
         (limit (max (length notice) emacs-agent-eval-output-limit)))
    (if (<= (length text) limit) text
      (concat (substring text 0 (max 0 (- limit (length notice)))) notice))))

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
