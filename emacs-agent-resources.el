;;; emacs-agent-resources.el --- Root-only project instructions -*- lexical-binding: t; -*-

;;; Commentary:
;; Read one project file as data.  No global/ancestor discovery, templates,
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

(defun emacs-agent-resources-capture (root)
  "Snapshot ROOT's saved project instructions using the source opt-out.
A missing root/file is normal.  The first existing candidate wins even when
empty or unreadable: errors are visible warnings, never hidden fallback.
No Lisp, mode hooks or file-local variables are executed."
  (let ((snapshot (list :status (cond ((not emacs-agent-project-instructions) 'disabled)
                                     ((not root) 'no-project) (t 'missing))
                        :root root :path nil :text nil :warnings nil)))
    (when (and emacs-agent-project-instructions root)
      (condition-case err
          (when-let* ((path (cl-loop for name in emacs-agent-resources--instruction-names
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

(defun emacs-agent-resources-system (base snapshot)
  "Append captured project SNAPSHOT to BASE, without reading any resources.
Snapshots from older turns are audit only, never replayed as user text."
  (if (eq (plist-get snapshot :status) 'loaded)
      (concat base "\n\nProject instructions from "
              (format "%S" (plist-get snapshot :path)) ":\n"
              (plist-get snapshot :text))
    base))

(defun emacs-agent-resources-summary (snapshot)
  "Render captured SNAPSHOT status, path and warnings without its full text."
  (concat (format "Project instructions: %s%s"
                  (plist-get snapshot :status)
                  (if (plist-get snapshot :path)
                      (format " — %s" (plist-get snapshot :path)) ""))
          (when (plist-get snapshot :warnings)
            (concat "\n" (string-join (plist-get snapshot :warnings) "\n")))))

(provide 'emacs-agent-resources)
;;; emacs-agent-resources.el ends here
