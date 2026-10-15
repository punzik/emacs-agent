;;; emacs-agent.el --- Project-scoped agent entry points -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (gptel "0.9.9.5"))
;; Keywords: tools, convenience

;;; Commentary:
;; Capture editor context, queue project-scoped turns and run unrestricted
;; Lisp through gptel.  Sessions partition history, not editor access.

;;; Code:
(require 'emacs-agent-session)
(require 'emacs-agent-context)
(require 'emacs-agent-helpers)
(require 'emacs-agent-log)
(require 'emacs-agent-store)
(require 'tabulated-list)

(autoload 'emacs-agent-gptel-submit "emacs-agent-gptel")
(autoload 'emacs-agent-gptel-cancel "emacs-agent-gptel")
(autoload 'emacs-agent-gptel-resume "emacs-agent-gptel")

(defvar emacs-agent-prompt-history nil "History of user-written prompts only.")

(defvar emacs-agent-minibuffer-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map minibuffer-local-map)
    (define-key map (kbd "RET") #'exit-minibuffer)
    (define-key map (kbd "C-j") #'newline)
    (define-key map (kbd "M-p") #'previous-history-element)
    (define-key map (kbd "M-n") #'next-history-element)
    map)
  "Multiline prompt map: RET sends, C-j inserts newline, C-g aborts.")

(defconst emacs-agent-system-prompt
  "You are an agent inside a shared live Emacs. Your only tool, eval_elisp, executes arbitrary Lisp without sandbox or approval; shell/process APIs are available. Sessions separate history, not access. Captured editor context may be stale. Tools default to the original source buffer if alive, otherwise session/transport, not necessarily the selected window. Choose buffers explicitly with with-current-buffer. Discover APIs via documentation/symbol-function and variables via boundp/symbol-value; never invent options or tool results.

Reading
Read needed ranges, not repeated whole files. Verification must not mutate text: never erase-buffer to inspect it. For plain text use buffer-substring-no-properties; string final values are printed without properties.
For metadata alone, call emacs-agent-buffer-info instead of reading text again. Reuse read metadata. It has no :fields argument. A newly obtained tick does not validate previously read text.
Helpers take a live buffer or its exact name. Read :text is literal, unnumbered, preserving empty lines/internal newlines but excluding the newline after requested END. Metadata includes :total-lines (whole buffer, even narrowed; empty buffer = 1, terminal newline adds an empty line). Never guess an end beyond :total-lines. :start/:end are positions (end exclusive); :start-line/:end-line describe those positions. For :truncated t, resume SAME START/END using :from = :next-position and same :tick until :truncated nil; join :text without separators. Never claim full verification from partial reads; explicitly scoped checks of changed ranges suffice. Helpers budget their own printed result; wrappers/stdout may exceed that budget.
Coordinates: absolute lines/positions start at 1; display columns start at 0 (tabs expanded). String index I maps to BASE+I; for buffer-string BASE is point-min at capture, not always 1 under narrowing. line-beginning-position/line-end-position take relative arguments, not absolute line numbers. Helpers preserve editor state; :widen t explicitly permits access outside narrowing. Coordinates are not live markers.

Editing
Prefer one emacs-agent-replace-texts batch with one tick from a fresh read. Every nonempty OLD must match exactly once in original accessible text; ranges cannot overlap. All changes apply bottom-up as one atomic undo step. Empty NEW deletes; insertion uses a unique OLD anchor retained in NEW. Use emacs-agent-replace-region only for explicit coordinates. On OLD mismatch or stale tick, reread the affected range and recompute; do not guess offsets or bypass a rejected replacement. Preserve user edits, undo and read-only protections.
Neither helper saves. Save explicitly with save-buffer; it saves all buffer changes. Report save errors: successful buffer edits remain. Never fake saving with set-buffer-modified-p nil or write-region; do not synchronize visited files using shell writes or revert-buffer. Visit files with find-file-noselect, respecting conflicts.

Independent examples use live example.el with lines old-one, old-two, end; adapt to real data. Local variables do not survive tool calls.
Metadata only (integer tick, not the whole plist):
```elisp
(plist-get (emacs-agent-buffer-info \"example.el\") :tick)
```
First read: bound by EOF and return the helper result intact, not selected fields:
```elisp
(let ((i (emacs-agent-buffer-info \"example.el\")))
  (emacs-agent-read-lines \"example.el\" 1 (min 100 (plist-get i :total-lines))
                         :tick (plist-get i :tick)))
```
Continuation demo with two tiny chunks; for real follow-ups reuse the PREVIOUS result's next-position/tick instead of rereading the first chunk:
```elisp
(let* ((r (emacs-agent-read-lines \"example.el\" 1 3 :limit 8))
       (next (plist-get r :next-position)))
  (if (not next) r
    (let ((s (emacs-agent-read-lines \"example.el\" 1 3 :limit 8
                                    :from next :tick (plist-get r :tick))))
      (list :text (concat (plist-get r :text) (plist-get s :text))
            :tick (plist-get s :tick) :truncated (plist-get s :truncated)
            :next-position (plist-get s :next-position)))))
```
Extract fields locally: read then batch with that tick, no per-edit ticks:
```elisp
(let ((r (emacs-agent-read-lines \"example.el\" 1 3)))
  (emacs-agent-replace-texts \"example.el\"
    '((:old \"old-one\" :new \"new-one\") (:old \"old-two\" :new \"new-two\"))
    :tick (plist-get r :tick)))
```
Around an explicit captured point (result also has :at with position/line/column/symbol):
```elisp
(emacs-agent-read-around \"example.el\" 1 :before 0 :after 1)
```
Explicit-region alternative using actual read bounds/text:
```elisp
(let ((r (emacs-agent-read-lines \"example.el\" 1 1)))
  (emacs-agent-replace-region \"example.el\" (plist-get r :start) (plist-get r :end)
                              (plist-get r :text) \"new-one\" :tick (plist-get r :tick)))
```
Separate save, only when intended:
```elisp
(with-current-buffer \"example.el\" (save-buffer))
```"
  "Stable instruction for the gptel adapter.")

;;;###autoload
(defun emacs-agent-ask ()
  "Capture editor context, read a multiline prompt and queue its turn.
Editor capture happens BEFORE the minibuffer; editing during prompt input
never changes that snapshot.  Saved instructions are captured on submission.
RET sends, C-j inserts a newline, C-g aborts.
M-p/M-n recall only user text.  Blank input does nothing.
From a journal, use its owning session and last live working buffer.
Starts a gptel run immediately if this session is idle; otherwise queues it."
  (interactive)
  (let* ((origin (emacs-agent-session-origin))
         (source (plist-get origin :buffer))
         (root (plist-get origin :root))
         (context (with-current-buffer source (emacs-agent-context-capture root)))
         (text (save-current-buffer
                 (read-from-minibuffer "Agent: " nil emacs-agent-minibuffer-map
                                       nil 'emacs-agent-prompt-history))))
    (unless (string-empty-p (string-trim text))
      (let* ((session (or (plist-get origin :session) (emacs-agent-session-get root)))
             (run (emacs-agent-session-enqueue session text context source
                                               (plist-get origin :window))))
        (emacs-agent--log-buffer session)
        (emacs-agent-gptel-submit run)
        (message "Agent turn %s in %s" (emacs-agent-run-status run)
                 (emacs-agent--session-name session))
        run))))

;;;###autoload
(defun emacs-agent-show-instructions ()
  "Show captured project instructions for the active or last submitted run.
This is a saved disk snapshot, not a live preview.  No resources are reread.
The view includes the selected path, status and any loading warnings."
  (interactive)
  (let* ((session (emacs-agent--current-session))
         (active (emacs-agent-session-active-run session))
         (event (unless active
                  (cl-find-if (lambda (e) (eq (plist-get e :type) 'instructions))
                              (reverse (emacs-agent-session-events session)))))
         (snapshot (if active (emacs-agent-run-instructions active) (plist-get event :payload)))
         (run-id (if active (emacs-agent-run-id active) (plist-get event :run-id))))
    (unless snapshot (user-error "No submitted instruction snapshot in this session"))
    (let ((buffer (get-buffer-create
                   (format "*emacs-agent-instructions: %s*" (emacs-agent--session-name session)))))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "Instructions snapshot for %s\nRoot: %S\n%s\n\n"
                          run-id (plist-get snapshot :root)
                          (emacs-agent-resources-summary snapshot)))
          (insert (or (plist-get snapshot :text) ""))
          (goto-char (point-min)))
        (special-mode)
        (setq-local emacs-agent-session--owner session)
        (setq-local default-directory (or (emacs-agent-session-project-root session)
                                          default-directory))
        (set-buffer-modified-p nil))
      (display-buffer buffer)
      buffer)))

;;;###autoload
(defun emacs-agent-show ()
  "Show the current project/global session's read-only event journal.
A journal always selects its owning session, even if its source buffer died."
  (interactive)
  (let* ((owner emacs-agent-session--owner)
         (session (or owner (emacs-agent-session-get (emacs-agent-session-resolve-root)))))
    (unless owner
      (setf (emacs-agent-session-last-source-buffer session) (current-buffer)))
    (emacs-agent--render-log session)
    (display-buffer (emacs-agent--log-buffer session))))

(defun emacs-agent--current-session ()
  "Resolve an existing current session without creating one for cancellation."
  (or emacs-agent-session--owner
      (gethash (or (emacs-agent-session-resolve-root) 'global)
               emacs-agent-session--registry)
      (user-error "No agent session here")))

;;;###autoload
(defun emacs-agent-cancel ()
  "Cancel the current session's active run, leaving prior Lisp effects intact.
The next queued turn may start; cancellation does not retry any tool call."
  (interactive)
  (emacs-agent-gptel-cancel (emacs-agent--current-session)))

;;;###autoload
(defun emacs-agent-resume ()
  "Continue the current session's paused run with another tool budget."
  (interactive)
  (emacs-agent-gptel-resume (emacs-agent--current-session)))

;;;###autoload
(defun emacs-agent-save ()
  "Atomically save the current session, including a checkpoint of partial text.
Does not stop or resume any run.  Snapshots may contain secrets."
  (interactive)
  (let ((file (emacs-agent-store-save (emacs-agent--current-session))))
    (message "Saved agent session to %s" file)
    file))

(defvar emacs-agent-session-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'emacs-agent-session-list-show)
    map))

(define-derived-mode emacs-agent-session-list-mode tabulated-list-mode "Agent-Sessions"
  "Read-only session list.  RET opens a journal; g refreshes saved sessions."
  (setq tabulated-list-format [("Session" 32 t) ("Status" 16 t) ("Updated" 20 t) ("Root" 0 t)]
        tabulated-list-padding 2
        tabulated-list-sort-key '("Updated" . t))
  (add-hook 'tabulated-list-revert-hook #'emacs-agent-session-list--entries nil t)
  (tabulated-list-init-header))

(defun emacs-agent-session-list--entries ()
  "Load independent files and populate the list without starting any run."
  (emacs-agent-store-load-all)
  (setq tabulated-list-entries nil)
  (maphash
   (lambda (key session)
     (when (emacs-agent-store--identity-p key (emacs-agent-session-project-root session))
       (let* ((run (emacs-agent-session-active-run session))
              (last (car (last (emacs-agent-session-events session))))
              (status (if run (emacs-agent-run-status run) (or (plist-get last :type) 'idle))))
         (push (list key (vector (emacs-agent--session-name session) (format "%s" status)
                                 (format-time-string "%Y-%m-%d %H:%M:%S"
                                                     (seconds-to-time (emacs-agent-session-updated-at session)))
                                 (or (emacs-agent-session-project-root session) "global")))
               tabulated-list-entries))))
   emacs-agent-session--registry))

(defun emacs-agent-session-list-show ()
  "Show the session on the selected row without creating or resuming tasks."
  (interactive)
  (let ((session (gethash (tabulated-list-get-id) emacs-agent-session--registry)))
    (unless session (user-error "No session on this row"))
    (emacs-agent--render-log session)
    (display-buffer (emacs-agent--log-buffer session))))

;;;###autoload
(defun emacs-agent-session-list ()
  "List in-memory and saved sessions; isolate corrupt snapshots as warnings."
  (interactive)
  (let ((buffer (get-buffer-create "*emacs-agent sessions*")))
    (with-current-buffer buffer
      (emacs-agent-session-list-mode)
      (emacs-agent-session-list--entries)
      (tabulated-list-print t))
    (display-buffer buffer)))

(provide 'emacs-agent)
;;; emacs-agent.el ends here
