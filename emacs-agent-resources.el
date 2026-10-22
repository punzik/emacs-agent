;;; emacs-agent-resources.el --- Root-only project instructions -*- lexical-binding: t; -*-

;;; Commentary:
;; Read common and agent-specific root instructions as data.  No discovery
;; outside the project root, templates,
;; visiting buffers, local-variable evaluation, or gptel configuration.

;;; Code:
(require 'cl-lib)
(require 'subr-x)

(defcustom emacs-agent-project-instructions t
  "Whether new submitted inputs capture instructions from the project root.
May be set buffer-locally in the source buffer.  Only saved file contents are
read.  Disabling editor context history does not disable instructions."
  :type 'boolean :group 'emacs-agent)

(defconst emacs-agent-resources--instruction-names
  '("AGENTS.override.md" "AGENTS.md" "AGENTS.MD" "CLAUDE.md" "CLAUDE.MD")
  "Priority for the single instruction file in the project root.")

(defun emacs-agent-resources--capture (root names)
  "Snapshot the first existing file among NAMES in ROOT, respecting opt-out.
Empty or unreadable candidates never fall back.  Read saved data only."
  (let ((snapshot (list :status (cond ((not emacs-agent-project-instructions) 'disabled)
                                     ((not root) 'no-project) (t 'missing))
                        :root root :path nil :text nil :warnings nil)))
    (when (and emacs-agent-project-instructions root)
      (condition-case err
          (when-let* ((path (cl-loop for name in names
                                    for path = (expand-file-name name root)
                                    when (or (file-exists-p path) (file-symlink-p path))
                                    return path)))
            (plist-put snapshot :path path)
            (unless (file-regular-p path) (error "Instruction path is not a regular file: %s" path))
            (plist-put snapshot :text
                       (with-temp-buffer
                         (insert-file-contents path)
                         (buffer-substring-no-properties (point-min) (point-max))))
            (plist-put snapshot :status 'loaded))
        (error
         (plist-put snapshot :status 'error)
         (plist-put snapshot :warnings (list (error-message-string err))))))
    snapshot))

(defun emacs-agent-resources-capture (root)
  "Snapshot ROOT's saved common instructions, then optional EMACSAGENT.md.
The common file is selected by `emacs-agent-resources--instruction-names'.
EMACSAGENT.md is independent: it also works without a common file, and an
error in one does not suppress the other.  Both respect the source opt-out.
No Lisp, mode hooks or file-local variables are executed."
  (let ((snapshot (emacs-agent-resources--capture
                   root emacs-agent-resources--instruction-names)))
    (when (and emacs-agent-project-instructions root)
      (let ((agent (emacs-agent-resources--capture root '("EMACSAGENT.md"))))
        (unless (eq (plist-get agent :status) 'missing)
          (setq snapshot (plist-put snapshot :emacsagent agent)))))
    snapshot))

(defun emacs-agent-resources-system (base snapshot)
  "Append captured common and agent-specific SNAPSHOT to BASE in order.
No resources are read.  Snapshots from older turns are audit only, never
replayed as user text.  Each loaded file has its own path heading."
  (dolist (part (list snapshot (plist-get snapshot :emacsagent)) base)
    (when (eq (plist-get part :status) 'loaded)
      (setq base (concat base "\n\nProject instructions from "
                         (format "%S" (plist-get part :path)) ":\n"
                         (plist-get part :text))))))

(defun emacs-agent-resources--summary (snapshot label)
  "Render one SNAPSHOT status, path and warnings under LABEL."
  (concat (format "%s: %s%s" label (plist-get snapshot :status)
                  (if (plist-get snapshot :path)
                      (format " — %s" (plist-get snapshot :path)) ""))
          (when (plist-get snapshot :warnings)
            (concat "\n" (string-join (plist-get snapshot :warnings) "\n")))))

(defun emacs-agent-resources-summary (snapshot)
  "Render both captured instruction statuses/paths/warnings, without text."
  (concat (emacs-agent-resources--summary snapshot "Project instructions")
          (when-let* ((agent (plist-get snapshot :emacsagent)))
            (concat "\n" (emacs-agent-resources--summary agent "Emacs agent instructions")))))

(provide 'emacs-agent-resources)
;;; emacs-agent-resources.el ends here
