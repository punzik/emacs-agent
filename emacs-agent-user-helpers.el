;;; emacs-agent-user-helpers.el --- Compact user helper descriptions -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

;;; Commentary:
;; Descriptive metadata for ordinary functions called through eval_elisp.
;; Registration does not load or execute helpers, grant access, or add tools.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'help-fns)

(defvar emacs-agent-user-helpers--registry (make-hash-table :test #'eq)
  "Global runtime function-symbol to rendered helper description.
Snapshots copy the rendered block, never the registry or function code.")

(defun emacs-agent-user-helpers--signature (function)
  "Return FUNCTION's declared usage or introspected argument list.
Reject unavailable code and signatures instead of loading or guessing."
  (unless (and (symbolp function) function (not (keywordp function))
               (eq function (intern-soft (symbol-name function))))
    (error "Helper must be an interned function symbol"))
  (let ((definition (and (fboundp function) (indirect-function function))))
    (unless (and definition (functionp definition)
                 (not (autoloadp definition))
                 (not (macrop definition))
                 (not (special-form-p definition)))
      (error "Helper must be a loaded ordinary function: %S" function))
    ;; Symbol documentation properties may be Lisp expressions: even raw
    ;; `documentation' evaluates them.  Inspect the resolved definition only,
    ;; including for arglist fallback, so aliases cannot trigger such eval.
    (or (when-let* ((doc (documentation definition t)))
          (help-split-fundoc doc function 'usage))
        (let ((args (help-function-arglist definition t)))
          (unless (listp args)
            (error "Helper signature unavailable; define a Lisp wrapper: %S" function))
          (let ((print-length nil) (print-level nil))
            (prin1-to-string (cons function args)))))))

(defun emacs-agent-user-helpers--field (name value &optional example)
  "Validate and copy VALUE for metadata NAME; EXAMPLE preserves inner text."
  (unless (and (stringp value) (not (string-empty-p (string-trim value))))
    (error "%S must be a nonempty string" name))
  (let ((text (string-trim (substring-no-properties value))))
    (if example text (replace-regexp-in-string "[ \t\r\n]+" " " text))))

;;;###autoload
(cl-defun emacs-agent-register-helper (function &rest options
                                              &key description returns constraints example)
  "Describe loaded FUNCTION to the agent in a compact, uniform format.
FUNCTION is an interned ordinary function symbol, not an autoload, macro
or special form.  Load its code yourself before registering.  Name and
signature come from Emacs usage metadata or argument introspection; the
full docstring is NOT sent.  Symbol `function-documentation' overrides are
ignored, since they can evaluate Lisp; only the resolved definition is
inspected.  No helper or example is called or evaluated.

Required keyword strings:
  :description  Short purpose: what the helper does and when to use it.
  :returns      Result type/shape and meanings of important fields.  State
                how missing data and errors are represented.
Optional keyword strings (omit, rather than pass nil, if not needed):
  :constraints  Preconditions, side effects and limits.  Say which buffers
                or files can change, whether anything is saved, coordinate
                conventions, and how truncation/continuation works, when
                relevant.  Explicitly say if a read is non-mutating.
  :example      One short, valid Elisp call as literal text.  It is never
                parsed, tested or executed by registration.  Prefer a
                representative call showing required arguments/keywords.

Use concise English prose (or your chosen instruction language).  Do not
repeat the generated name/signature, paste the full docstring or repeat
shared eval/safety instructions.  Describe only actual behavior; registration
adds no guards, output limits, save, retry or permissions.  Put long details
in the function docstring for on-demand `documentation'.  Prose whitespace
is collapsed; inner example text is preserved.  Text properties are removed.
Empty/whitespace-only strings, unknown or repeated keywords are rejected.

Example setup (after defining/loading my-diagnostics):
  (emacs-agent-register-helper
   \='my-diagnostics
   :description \"Read current buffer diagnostics.\"
   :returns \"List of (:line :column :severity :message).\"
   :constraints \"Requires an active checker; does not save or modify buffers.\"
   :example \"(my-diagnostics \\\"main.ml\\\")\")

Return FUNCTION.  Re-registering atomically replaces its description and
signature; do so after redefining it.  Entries are global to this Emacs,
sorted by function name in the prompt, and independent of project-file
opt-out.  New inputs capture their own rendered snapshot; FIFO, ongoing
runs and restored inputs do not consult the registry again.  Saved text
never restores function code or registers helpers after restart.
Use `emacs-agent-unregister-helper' to stop advertising it to new inputs;
this does not restrict unrestricted eval or revoke older snapshots."
  (unless (cl-evenp (length options)) (error "Helper options must be keyword/value pairs"))
  (let (seen)
    (cl-loop for key in options by #'cddr do
             (unless (and (memq key '(:description :returns :constraints :example))
                          (not (memq key seen)))
               (error "Unknown or duplicate helper option: %S" key))
             (push key seen)))
  (let* ((signature (emacs-agent-user-helpers--signature function))
         (description (emacs-agent-user-helpers--field :description description))
         (returns (emacs-agent-user-helpers--field :returns returns))
         (constraints (when (plist-member options :constraints)
                        (emacs-agent-user-helpers--field :constraints constraints)))
         (example (when (plist-member options :example)
                    (emacs-agent-user-helpers--field :example example t)))
         (entry (concat signature "\n  " description "\n  Returns: " returns
                        (when constraints (concat "\n  Constraints: " constraints))
                        (when example (concat "\n  Example: " example)))))
    (puthash function entry emacs-agent-user-helpers--registry)
    function))

;;;###autoload
(defun emacs-agent-unregister-helper (function)
  "Stop advertising FUNCTION to future inputs; return t if it was registered.
Return nil when absent.  Do not undefine code, change older snapshots or
restrict access through eval_elisp.  The registry is global to this Emacs."
  (when (gethash function emacs-agent-user-helpers--registry)
    (remhash function emacs-agent-user-helpers--registry)
    t))

(defun emacs-agent-user-helpers--capture ()
  "Return a fresh sorted helper block, or nil for an empty registry.
Only already-rendered metadata is read; no code loading or introspection."
  (let (entries)
    (maphash (lambda (function text) (push (cons function text) entries))
             emacs-agent-user-helpers--registry)
    (when entries
      (concat "User helpers (via eval_elisp):\n"
              (mapconcat #'cdr
                         (sort entries (lambda (a b) (string-lessp (symbol-name (car a))
                                                                  (symbol-name (car b)))))
                         "\n")))))

(provide 'emacs-agent-user-helpers)
;;; emacs-agent-user-helpers.el ends here
