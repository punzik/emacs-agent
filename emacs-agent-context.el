;;; emacs-agent-context.el --- Immutable editor snapshots -*- lexical-binding: t; -*-

;;; Commentary:
;; Only serializable values belong here, never buffers/windows/markers.

;;; Code:
(require 'json)
(require 'emacs-agent-eval)

(defcustom emacs-agent-context-history 'current
  "How automatically captured context will be sent to the model.
`current' keeps only the active user turn's snapshot, including tool
continuations.  `full' includes every turn; nil disables automatic context.
The history adapter implementing this policy is part of stage 4."
  :type '(choice (const :tag "Disabled" nil)
                 (const :tag "Current user turn only" current)
                 (const :tag "All user turns" full))
  :group 'emacs-agent)

(defcustom emacs-agent-region-text-limit 8192
  "Maximum characters of selected text to capture automatically.
Selections larger than this retain positions but omit their text.
Zero disables automatic selection text."
  :type 'natnum :group 'emacs-agent)

(defun emacs-agent-context-capture (root)
  "Capture the current working buffer with canonical project ROOT.
Positions are absolute Emacs buffer coordinates.  Line is 1-based and column
0-based, both measured in the widened buffer.  Narrowing bounds are retained.
Inactive marks are captured as positions, but do not imply an active region.
No complete buffer text is included."
  (let* ((position (point))
         (active (region-active-p))
         (start (and active (region-beginning)))
         (end (and active (region-end)))
         (bounds (list (point-min) (point-max)))
         (narrowed (buffer-narrowed-p))
         (line-column (save-restriction
                        (widen)
                        (list (line-number-at-pos position t) (current-column))))
         (context (list :session (if root "project" "global")
                        :project-root root :buffer (buffer-name)
                        :file buffer-file-name :major-mode (symbol-name major-mode)
                        :default-directory default-directory :point position
                        :line (car line-column) :column (cadr line-column)
                        :mark (mark t) :region-active (if active t :false)
                        :region-start start :region-end end
                        :narrowed (if narrowed t :false)
                        :point-min (car bounds) :point-max (cadr bounds))))
    (when (and active (> emacs-agent-region-text-limit 0)
               (<= (- end start) emacs-agent-region-text-limit))
      (setq context (append context
                            (list :region-text (buffer-substring-no-properties start end)))))
    context))

(defun emacs-agent-context-render (context)
  "Render CONTEXT as framed JSON, with no literal markup delimiters in data.
JSON null distinguishes an absent file from an empty file name.  This is
user-level diagnostic data, never a system instruction."
  (let ((json (json-serialize context :null-object nil :false-object :false)))
    (dolist (pair '(("&" . "\\u0026") ("<" . "\\u003c") (">" . "\\u003e")))
      (setq json (replace-regexp-in-string (car pair) (cdr pair) json t t)))
    (concat "<emacs-context>\n" json "\n</emacs-context>")))

(provide 'emacs-agent-context)
;;; emacs-agent-context.el ends here
