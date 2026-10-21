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

(defun emacs-agent-eval--brief (value &optional limit)
  "Print VALUE with bounded depth, length and at most LIMIT characters.
This is diagnostic display text, not a readable serialization."
  (let ((print-level 3) (print-length 16) (print-circle nil)
        (print-escape-newlines t) (print-escape-control-characters t)
        (count 0) (limit (or limit 240)) clipped)
    (with-temp-buffer
      (catch 'full
        (prin1 value (lambda (character)
                       (when (>= count limit)
                         (setq clipped t)
                         (throw 'full nil))
                       (insert-char character)
                       (cl-incf count))))
      (concat (buffer-string) (if clipped "…" "")))))

(defvar emacs-agent-eval--stack-condition nil)
(defvar emacs-agent-eval--stack-frames nil)

(defun emacs-agent-eval--debugger (&rest reason)
  "Capture only function names for an error REASON, without opening a debugger."
  (when (eq (car reason) 'error)
    (setq emacs-agent-eval--stack-condition (cadr reason)
          emacs-agent-eval--stack-frames nil)
    (let ((debug-on-error nil) (debug-on-signal nil) (debug-on-quit nil)
          (inhibit-debugger t) (inhibit-quit t))
      (save-match-data
        (condition-case nil
            (let ((index 1) frame done)
              (while (and (not done) (<= index 8)
                          (setq frame (backtrace-frame index 'emacs-agent-eval--debugger)))
                (let ((name (nth 1 frame)))
                  (push (if (symbolp name) name :anonymous) emacs-agent-eval--stack-frames)
                  (when (eq name 'eval) (setq done t)))
                (cl-incf index))
              (setq emacs-agent-eval--stack-frames (nreverse emacs-agent-eval--stack-frames)))
          ((error quit) (setq emacs-agent-eval--stack-frames nil))))))
  ;; Emacs otherwise suppresses repeated debugger entry without keyboard input.
  ;; This variable is bound locally by the evaluator; capture cannot recurse.
  (setq internal-when-entered-debugger -1)
  nil)

(defun emacs-agent-eval--stack-diagnostic (err)
  "Describe matching ERR's innermost available frames, never their arguments."
  (condition-case nil
      (save-match-data
        (if (not (and emacs-agent-eval--stack-frames
                      (eq (car err) (car emacs-agent-eval--stack-condition))
                      (eq (cdr err) (cdr emacs-agent-eval--stack-condition))))
            "\nStack: unavailable."
          (let* ((name (car emacs-agent-eval--stack-frames))
                 (definition (and (symbolp name) (fboundp name) (indirect-function name)))
                 ;; No autoload or dynamic documentation evaluation for diagnostics.
                 (arguments (and definition (not (autoloadp definition))
                                 (condition-case nil (help-function-arglist definition)
                                   ((error quit) :unknown))))
                 (signature (and definition (not (autoloadp definition)) (listp arguments)
                                 (emacs-agent-eval--brief (cons name arguments)))))
            (concat "\nFrames (names only, innermost first; not an exact source location): "
                    (emacs-agent-eval--brief emacs-agent-eval--stack-frames)
                    (when signature (concat "\nSignature (names may be generic): " signature))))))
    ((error quit) "\nStack/signature diagnostics unavailable.")))

(defun emacs-agent-eval--source-state (buffer)
  "Describe BUFFER without reading text, moving point or widening."
  (condition-case nil
      (if (not (buffer-live-p buffer)) '(:live nil)
        (with-current-buffer buffer
          (list :live t :characters (buffer-size) :tick (buffer-chars-modified-tick)
                :modified (buffer-modified-p) :buffer (buffer-name)
                :file (if (stringp buffer-file-name)
                          (substring-no-properties buffer-file-name) buffer-file-name))))
    ((error quit) '(:unavailable t))))

(defun emacs-agent-eval--source-change (buffer before)
  "Describe net changes to BUFFER since BEFORE, never other buffers."
  (condition-case nil
      (let ((after (emacs-agent-eval--source-state buffer)))
        (cond ((or (plist-get before :unavailable) (plist-get after :unavailable))
               "\nSource buffer state unavailable; other buffers not checked.")
              ((not (equal before after))
               (let (changes)
                 (dolist (key '(:live :characters :tick :modified :buffer :file))
                   (unless (equal (plist-get before key) (plist-get after key))
                     (setq changes
                           (append changes
                                   (list (if (eq key :characters) :whole-characters key)
                                         (list (plist-get before key) (plist-get after key)))))))
                 (format "\nSource buffer changed (others unchecked): %s %s"
                         (emacs-agent-eval--brief
                          (list :buffer (plist-get before :buffer) :file (plist-get before :file)))
                         (emacs-agent-eval--brief changes 360))))
              (t "")))
    ((error quit) "\nSource buffer diagnostics unavailable; other buffers not checked.")))

(defun emacs-agent-eval--location (position)
  "Describe character POSITION in the current expression buffer."
  (save-excursion
    (goto-char position)
    (format "line %d, column %d, position %d"
            (line-number-at-pos) (- (point) (line-beginning-position)) (point))))

(defun emacs-agent-eval--diagnostic (phase completed start input condition)
  "Describe failure PHASE, COMPLETED forms, START in INPUT and CONDITION.
Reader hints are syntax-table diagnostics, not a second execution or reader."
  (condition-case nil
      (with-current-buffer input
        (let ((stopped (point)) (anchor start) (hint ""))
          (when (eq phase 'read)
            (save-excursion
              (syntax-propertize (point-max))
              (let* ((state (parse-partial-sexp start (point-max)))
                     (opener (if (nth 3 state) (nth 8 state) (nth 1 state))))
                (when opener
                  (setq anchor opener
                        hint (format "\nSyntax hint: open %s at %s"
                                     (if (nth 3 state) "string" "list")
                                     (emacs-agent-eval--location opener)))))))
          (format "\nPhase: %s; form: %d; forms completed: %d; condition: %s\nLocations: 1-based character positions/lines, 0-based character columns.\nTop-level form starts: %s%s%s\nSource excerpt: %s\n%s"
                  phase (1+ completed) completed (emacs-agent-eval--brief condition 80)
                  (emacs-agent-eval--location start)
                  (if (eq phase 'read)
                      (concat "\nReader stopped: " (emacs-agent-eval--location stopped)) "")
                  hint
                  (emacs-agent-eval--brief
                   (buffer-substring-no-properties (max (point-min) (- anchor 30))
                                                   (min (point-max) (+ anchor 90))))
                  (if (eq phase 'eval)
                      "Failed form may have effects; no rollback performed."
                    "Current form was not evaluated; earlier effects are not rolled back."))))
    ((error quit) "\nEvaluation diagnostics unavailable; effects are not rolled back.")))

(defvar emacs-agent-texts nil
  "Text strings supplied to the current `emacs-agent-eval' invocation.
Dynamically bound to a fresh list during each call, including across buffers.
Texts are data, never implicitly read as Lisp or unescaped.  The default is nil.")

(defun emacs-agent-eval--texts-p (texts)
  "Whether TEXTS is a proper list or vector containing only strings."
  (and (or (vectorp texts) (proper-list-p texts))
       (cl-every #'stringp texts)))

(defun emacs-agent-eval--args-p (args)
  "Whether ARGS is a supported JSON tool argument plist.
JSON arrays are vectors; explicit null is not an array.  Direct Lisp callers
of `emacs-agent-eval' may also supply a proper list as its optional argument."
  (and (proper-list-p args) (cl-evenp (length args))
       (stringp (plist-get args :expression))
       (let (seen)
         (cl-loop for key in args by #'cddr
                  always (and (memq key '(:expression :texts))
                              (not (memq key seen)) (push key seen))))
       (or (not (plist-member args :texts))
           (and (vectorp (plist-get args :texts))
                (emacs-agent-eval--texts-p (plist-get args :texts))))))

(defun emacs-agent-eval (expression &optional texts)
  "Evaluate all forms in EXPRESSION, returning output and the final value.
Execution is unrestricted and synchronous, with lexical binding enabled.
Optional TEXTS is a vector or proper list of strings, exposed as a fresh list
in `emacs-agent-texts' during this invocation only.  Characters are copied
verbatim, without properties, unescaping or evaluation.  Omitted TEXTS means an
empty list, never inherited payload from an outer invocation.  Any helper or
Elisp function can consume these ordinary strings; no editing guards change.
Invalid TEXTS signals before evaluating any form.
Previously evaluated forms are not rolled back if a later form fails.
`princ' output is captured; `message' still goes to the normal message log.
Successful nil is printed as `nil'; errors and quits are explicitly labelled.
A string final value is printed without text properties, so ordinary buffer
reads do not serialize font-lock/eglot metadata.  The source value is not
mutated; inspect properties explicitly when needed.  Non-string values and
explicit printing inside EXPRESSION retain their normal Lisp semantics.
Errors include phase, form count and character locations.  Net changes to the
source buffer are reported separately; other buffers and external effects are
not inspected.  Diagnostics never restore or roll back editor state."
  (unless (emacs-agent-eval--texts-p texts)
    (error "TEXTS must be an array or proper list of strings"))
  (let ((emacs-agent-texts (mapcar #'substring-no-properties texts))
        (output (generate-new-buffer " *emacs-agent-eval-output*"))
        (input (generate-new-buffer " *emacs-agent-eval-input*"))
        (source (current-buffer))
        (before (emacs-agent-eval--source-state (current-buffer)))
        (phase 'read) (completed 0) (start 1)
        (debugger #'emacs-agent-eval--debugger)
        (debug-on-error t) (debug-on-signal nil) (debug-on-quit nil)
        (debug-ignored-errors nil) (internal-when-entered-debugger -1)
        (emacs-agent-eval--stack-condition nil) (emacs-agent-eval--stack-frames nil)
        value failure error-text diagnostic)
    (unwind-protect
        (progn
          (with-current-buffer input
            (set-syntax-table emacs-lisp-mode-syntax-table)
            (setq-local syntax-propertize-function #'elisp-mode-syntax-propertize)
            (insert expression)
            (goto-char (point-min)))
          (condition-case err
              (let ((standard-output output)
                    (more t))
                (while more
                  (setq phase 'read)
                  (let ((form
                         (with-current-buffer input
                           ;; Skip whitespace and comments, but do not mistake
                           ;; EOF inside an incomplete form for clean EOF.
                           (setq start (point))
                           (forward-comment (point-max))
                           (setq start (point))
                           (if (eobp) (setq more nil)
                             (read (current-buffer))))))
                    (when more
                      (setq phase 'eval
                            value (with-current-buffer source (eval form t)))
                      (cl-incf completed)))))
            (quit (setq failure err error-text "QUIT: evaluation interrupted"))
            ((debug error)
             (setq failure err error-text
                   (format "ERROR %s: %s" (car err) (error-message-string err)))))
          (setq diagnostic
                (save-match-data
                  (concat
                   (when error-text
                     (concat (emacs-agent-eval--diagnostic phase completed start input (car failure))
                             (when (and (eq phase 'eval) (not (eq (car failure) 'quit)))
                               (emacs-agent-eval--stack-diagnostic failure))))
                   (emacs-agent-eval--source-change source before))))
          (emacs-agent-eval--limit
           (concat (with-current-buffer output
                     (buffer-substring-no-properties (point-min) (point-max)))
                   (if error-text (concat diagnostic "\n" error-text)
                     (let ((print-length nil) (print-level nil) (print-circle t))
                       (concat "\n=> "
                               (prin1-to-string
                                (if (stringp value)
                                    (substring-no-properties value)
                                  value))
                               diagnostic))))))
      (kill-buffer input)
      (kill-buffer output))))

(provide 'emacs-agent-eval)
;;; emacs-agent-eval.el ends here
