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
(require 'emacs-agent-input)
(require 'emacs-agent-status)
(require 'tabulated-list)

(declare-function emacs-agent-input-forget "emacs-agent-input" (input))
(declare-function gptel-backend-name "gptel-request" (backend))
(declare-function emacs-agent-compact-start "emacs-agent-compact" (source-run keep instructions &optional owner resume tokens-before))
(declare-function emacs-agent-compact-job-state "emacs-agent-compact" (job))
(defvar gptel--known-backends)

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
         (session (or (plist-get origin :session)
                      (emacs-agent-session-selected root)
                      (and root (emacs-agent-store-load-session root))))
         (context (with-current-buffer source (emacs-agent-context-capture root)))
         (text (save-current-buffer
                 (read-from-minibuffer "Agent: " nil emacs-agent-minibuffer-map
                                       nil 'emacs-agent-prompt-history))))
    (unless (string-empty-p (string-trim text))
      (unless session
        (when (emacs-agent-session-selected root)
          (user-error "Conversation selection changed during input; submit again"))
        (setq session (emacs-agent-session-get root)))
      (let ((run (emacs-agent-session-enqueue session text context source
                                             (plist-get origin :window))))
        (emacs-agent--log-buffer session)
        (emacs-agent-gptel-submit run)
        (message "Agent turn %s in %s" (emacs-agent-run-status run)
                 (emacs-agent--session-name session))
        run))))

;;;###autoload
(defun emacs-agent-steer ()
  "Capture context and queue a clarification for the current active run.
Paused runs accept clarifications too.  RET sends, C-j inserts a newline;
blank input and C-g leave the run unchanged."
  (interactive)
  (let* ((session (emacs-agent--current-session))
         (target (emacs-agent-session-active-run session)))
    (unless (and target (memq (emacs-agent-run-status target)
                              '(requesting streaming tool-running paused)))
      (user-error "No active agent run here"))
    (let* ((origin (emacs-agent-session-origin))
           (source (plist-get origin :buffer))
           (context (with-current-buffer source
                      (emacs-agent-context-capture (plist-get origin :root))))
           (text (save-current-buffer
                   (read-from-minibuffer "Steer: " nil emacs-agent-minibuffer-map
                                         nil 'emacs-agent-prompt-history))))
      (unless (string-empty-p (string-trim text))
        (emacs-agent-input-queue-steer target text context source
                                       (plist-get origin :window))))))

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
      (emacs-agent-session-selected (emacs-agent-session-resolve-root))
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
(defun emacs-agent-compact (&optional keep instructions)
  "Summarize this idle session, retaining a recent token target KEEP.
With a prefix argument, ask for KEEP and optional summary focus INSTRUCTIONS.
Zero retains no raw suffix.  Original history is never deleted."
  (interactive
   (when current-prefix-arg
     (list (read-number "Keep recent tokens (0 summarizes all): " emacs-agent-compaction-keep-recent)
           (read-string "Summary focus (optional): "))))
  (emacs-agent-session--unlocked)
  (require 'emacs-agent-gptel)
  (let* ((origin (emacs-agent-session-origin))
         (source (plist-get origin :buffer))
         (session (or (plist-get origin :session)
                      (emacs-agent-session-selected (plist-get origin :root))
                      (emacs-agent-store-load-session (plist-get origin :root))
                      (user-error "No agent session here")))
         (run (with-current-buffer source
                (make-emacs-agent-run
                 :session session :source-buffer source
                 :id (plist-get (car (last (emacs-agent-session-messages session))) :run-id)
                 :backend gptel-backend :model gptel-model
                 :context-policy emacs-agent-context-history
                 :context-config (emacs-agent-compaction-config))))
         (job (emacs-agent-compact-start
               run (or keep (plist-get (emacs-agent-run-context-config run) :keep)) instructions)))
    (message "Compaction %s" (emacs-agent-compact-job-state job))
    job))

;;;###autoload
(defun emacs-agent-save ()
  "Atomically save the current session, including a checkpoint of partial text.
Does not stop or resume any run.  Snapshots may contain secrets."
  (interactive)
  (let ((file (emacs-agent-store-save (emacs-agent--current-session))))
    (message "Saved agent session to %s" file)
    file))

(defun emacs-agent--conversation-origin ()
  "Capture the explicit owner/scope and current choice before user input."
  (emacs-agent-session--unlocked)
  (let* ((owner emacs-agent-session--owner)
         (root (if owner (emacs-agent-session-project-root owner)
                 (emacs-agent-session-resolve-root)))
         (selected (or (emacs-agent-session-selected root)
                       (and root (emacs-agent-store-load-session root)))))
    (list :root root :session (or owner selected) :selected selected
          :source (unless owner (current-buffer)))))

(defun emacs-agent--conversation-check (origin)
  "Reject a changed selection while reading input for captured ORIGIN."
  (unless (eq (plist-get origin :selected)
              (emacs-agent-session-selected (plist-get origin :root)))
    (user-error "Conversation selection changed; try again"))
  (when-let* ((session (plist-get origin :session)))
    (unless (emacs-agent-session-registered-p session)
      (user-error "Conversation was retired; try again"))))

(defun emacs-agent--conversation-show (session source)
  "Focus SESSION after a user selection, explicitly binding working SOURCE.
This helper is for user commands, never asynchronous callbacks."
  (when (buffer-live-p source)
    (setf (emacs-agent-session-last-source-buffer session) source))
  (emacs-agent--render-log session)
  (pop-to-buffer (emacs-agent--log-buffer session))
  session)

;;;###autoload
(defun emacs-agent-session-new (&optional name)
  "Save the old conversation and select a new empty one in this scope.
With a prefix argument, ask for optional NAME.  Requires idle conversations."
  (interactive)
  (let ((origin (emacs-agent--conversation-origin)))
    (when (and (called-interactively-p 'interactive) current-prefix-arg)
      (setq name (read-string "New conversation name (optional): ")))
    (emacs-agent--conversation-check origin)
    (emacs-agent--conversation-show
     (emacs-agent-session--new (plist-get origin :root) name (plist-get origin :session))
     (plist-get origin :source))))

;;;###autoload
(defun emacs-agent-session-rename (&optional name)
  "Save a new NAME for the explicit current idle conversation."
  (interactive)
  (let ((session (or (plist-get (emacs-agent--conversation-origin) :session)
                     (user-error "No conversation here"))))
    (setq name (or name (read-string "Conversation name (empty clears): "
                                    (emacs-agent-session-name session))))
    (emacs-agent-session--rename session name)
    (when (buffer-live-p (emacs-agent-session-log-buffer session))
      (with-current-buffer (emacs-agent-session-log-buffer session)
        (rename-buffer (format "*emacs-agent: %s*" (emacs-agent-log--label session)) t)
        (force-mode-line-update)))
    session))

;;;###autoload
(defun emacs-agent-session-select (&optional conversation)
  "Select an idle CONVERSATION in this scope, saving the old choice first.
CONVERSATION can be a registered object or its ID; interactively use completion.
Opening a journal alone does not select it."
  (interactive)
  (let* ((origin (emacs-agent--conversation-origin))
         (key (or (plist-get origin :root) 'global)) choices)
    (emacs-agent-store-load-all)
    (maphash
     (lambda (_ session)
       (when (equal key (emacs-agent-session-key session))
         (push (cons (format "%s [%s]" (emacs-agent--session-name session)
                             (emacs-agent-session-id session)) session) choices)))
     emacs-agent-session--registry)
    (unless choices (user-error "No saved conversations in this scope; use emacs-agent-session-new"))
    (let ((target (cond ((emacs-agent-session-p conversation) conversation)
                        ((stringp conversation) (gethash conversation emacs-agent-session--registry))
                        ((null conversation)
                         (cdr (assoc (completing-read "Conversation: " choices nil t) choices))))))
      (unless (and target (equal key (emacs-agent-session-key target)))
        (user-error "Conversation must belong to this scope"))
      (emacs-agent--conversation-check origin)
      (emacs-agent--conversation-show
       (emacs-agent-session--select target (plist-get origin :session)) (plist-get origin :source)))))

;;;###autoload
(defun emacs-agent-session-clone (&optional name)
  "Clone the explicit idle conversation into a selected independent archive.
With a prefix argument, ask for NAME.  Copy no runtime queue or authority."
  (interactive)
  (let* ((origin (emacs-agent--conversation-origin))
         (source (or (plist-get origin :session) (user-error "No conversation here"))))
    (when (and (called-interactively-p 'interactive) current-prefix-arg)
      (setq name (read-string "Clone name (optional): ")))
    (emacs-agent--conversation-check origin)
    (emacs-agent--conversation-show (emacs-agent-session--clone source name) (plist-get origin :source))))

;;;###autoload
(defun emacs-agent-session-fork (&optional end name)
  "Fork the explicit idle conversation after a completed turn or summary.
END is an absolute canonical-message count; interactively choose a boundary.
With a prefix argument, ask for NAME.  Editor/files are NOT rolled back."
  (interactive)
  (let* ((origin (emacs-agent--conversation-origin))
         (source (or (plist-get origin :session) (user-error "No conversation here")))
         ;; User-initiated journal fork keeps its owner's live working context,
         ;; not a buffer reconstructed from copied history or event payloads.
         (working-source (or (plist-get origin :source)
                             (emacs-agent-session-last-source-buffer source)))
         (points (emacs-agent-session--fork-points source))
         (messages-tail (last (emacs-agent-session-messages source)))
         (events-tail (last (emacs-agent-session-events source)))
         (compaction (emacs-agent-session-compaction source))
         (number 0)
         (choices
          (mapcar (lambda (point)
                    (cl-incf number)
                    (cons (if (eq (plist-get point :kind) 'summary)
                              (format "%d: after compaction summary" number)
                            (format "%d: after %s — %s" number
                                    (plist-get point :run-id)
                                    (truncate-string-to-width
                                     (replace-regexp-in-string "[\n\r\t]+" " " (plist-get point :text))
                                     70 nil nil "…")))
                          (plist-get point :end)))
                  points)))
    (unless choices (user-error "No completed turns or compaction summary to fork"))
    (unless end
      (setq end (cdr (assoc (completing-read "Fork after (no editor rollback): " choices nil t
                                           nil nil (caar (last choices))) choices))))
    (when (and (called-interactively-p 'interactive) current-prefix-arg)
      (setq name (read-string "Fork name (optional): ")))
    (emacs-agent--conversation-check origin)
    (unless (and (eq messages-tail (last (emacs-agent-session-messages source)))
                 (eq events-tail (last (emacs-agent-session-events source)))
                 (eq compaction (emacs-agent-session-compaction source)))
      (user-error "Conversation history changed; choose the fork point again"))
    (let ((fork (emacs-agent-session--fork source end name)))
      (emacs-agent--conversation-show fork working-source)
      (message "Fork selected; buffers, files and processes were NOT rolled back")
      fork)))

(defun emacs-agent--conversation-matches-p (session regexp)
  "Search SESSION's local name, summary and archive text using REGEXP.
Do not follow artifact paths or execute saved expressions."
  (let ((case-fold-search t))
    (cl-labels ((matches (value)
                  (cond ((stringp value) (string-match-p regexp value))
                        ((consp value) (cl-some #'matches value))
                        ((vectorp value) (cl-some #'matches (append value nil))))))
      (or (matches (emacs-agent-session-id session))
          (matches (emacs-agent-session-name session))
          (matches (emacs-agent-session-project-root session))
          (matches (emacs-agent-session-provenance session))
          (matches (emacs-agent-session-compaction session))
          (matches (emacs-agent-session-messages session))
          (matches (emacs-agent-session-events session))))))

;;;###autoload
(defun emacs-agent-session-search (regexp)
  "Search local conversation names and full archive text with REGEXP.
Search all scopes without changing their selections or using a model."
  (interactive (list (read-string "Search conversations (regexp): ")))
  (condition-case nil (string-match-p regexp "")
    (invalid-regexp (user-error "Invalid search regexp")))
  (emacs-agent-session-list regexp))

(defvar-local emacs-agent-session-list--query nil)

(defvar emacs-agent-session-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'emacs-agent-session-list-show)
    map))

(define-derived-mode emacs-agent-session-list-mode tabulated-list-mode "Agent-Sessions"
  "Read-only session list.  RET opens a journal; g refreshes saved sessions."
  (setq tabulated-list-format [("Conversation" 48 t) ("Current" 7 t) ("Status" 16 t) ("Updated" 20 t) ("Root" 0 t)]
        tabulated-list-padding 2
        tabulated-list-sort-key '("Updated" . t))
  (add-hook 'tabulated-list-revert-hook #'emacs-agent-session-list--entries nil t)
  (tabulated-list-init-header))

(defun emacs-agent-session-list--entries ()
  "Load independent files and populate the list without starting any run."
  (emacs-agent-store-load-all)
  (setq tabulated-list-entries nil)
  (maphash
   (lambda (id session)
     (when (and (emacs-agent-store--identity-p (emacs-agent-session-key session)
                                             (emacs-agent-session-project-root session))
                (or (null emacs-agent-session-list--query)
                    (emacs-agent--conversation-matches-p session emacs-agent-session-list--query)))
       (let* ((run (emacs-agent-session-active-run session))
              (last (car (last (emacs-agent-session-events session))))
              (status (if run (emacs-agent-run-status run) (or (plist-get last :type) 'idle))))
         (push (list id (vector (emacs-agent--session-name session)
                                (if (eq session (emacs-agent-session-selected
                                                 (emacs-agent-session-project-root session))) "*" "")
                                (format "%s" status)
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
(defun emacs-agent-session-list (&optional query)
  "List conversations, optionally filtering archive text with regexp QUERY.
No selection, model request, artifact read or legacy snapshot import occurs."
  (interactive)
  (let ((buffer (get-buffer-create "*emacs-agent sessions*")))
    (with-current-buffer buffer
      (emacs-agent-session-list-mode)
      (setq emacs-agent-session-list--query query)
      (emacs-agent-session-list--entries)
      (tabulated-list-print t))
    (display-buffer buffer)))

(defvar emacs-agent-pending-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "g") #'emacs-agent-pending-refresh)
    (define-key map (kbd "e") #'emacs-agent-pending-edit)
    (define-key map (kbd "d") #'emacs-agent-pending-withdraw)
    (define-key map (kbd "r") #'emacs-agent-pending-recover)
    (define-key map (kbd "D") #'emacs-agent-pending-forget)
    (define-key map (kbd "RET") #'emacs-agent-pending-show)
    map))

(define-derived-mode emacs-agent-pending-mode tabulated-list-mode "Agent-Pending"
  "Undelivered inputs: e edit, d withdraw, r recover, D forget, RET full text."
  (setq tabulated-list-format [("State" 12 t) ("Kind" 8 t) ("Text" 50 t) ("ID" 24 t)]
        tabulated-list-padding 2)
  (add-hook 'tabulated-list-revert-hook #'emacs-agent-pending--entries nil t)
  (tabulated-list-init-header))

(defun emacs-agent-pending--entries ()
  "Populate rows from this view's owning session only."
  (setq tabulated-list-entries
        (cl-loop for input in (emacs-agent-session-inputs emacs-agent-session--owner)
                 when (and (memq (emacs-agent-input-state input) '(prepared queued withdrawn))
                           (memq (emacs-agent-input-kind input) '(ask steer)))
                 collect
                 (list (emacs-agent-input-id input)
                       (vector (symbol-name (emacs-agent-input-state input))
                               (symbol-name (emacs-agent-input-kind input))
                               (car (split-string (emacs-agent-run-user-text
                                                   (emacs-agent-input-run input)) "\n"))
                               (emacs-agent-input-id input))))))

(defun emacs-agent-pending-refresh ()
  "Refresh this pending view without changing windows or scheduling work."
  (interactive)
  (when (derived-mode-p 'emacs-agent-pending-mode)
    (emacs-agent-pending--entries)
    (tabulated-list-print t)))

(defun emacs-agent-pending--refresh-event (session event)
  "Refresh an existing SESSION pending view only for lifecycle EVENT changes."
  (unless (memq (plist-get event :type) '(assistant reasoning assistant-end reasoning-end))
    (when-let* ((buffer (get-buffer (format "*emacs-agent-pending: %s*"
                                           (emacs-agent-session-id session)))))
      (with-current-buffer buffer
        (when (eq emacs-agent-session--owner session) (emacs-agent-pending-refresh))))))

(add-hook 'emacs-agent-session-event-functions #'emacs-agent-pending--refresh-event)

(defun emacs-agent-pending--selected (input)
  "Return INPUT or the input on the current pending row."
  (or input
      (and (derived-mode-p 'emacs-agent-pending-mode)
           (cl-find (tabulated-list-get-id)
                    (emacs-agent-session-inputs emacs-agent-session--owner)
                    :key #'emacs-agent-input-id :test #'equal))
      (user-error "Select a pending input row first")))

(defun emacs-agent-pending--working-buffer-p (buffer)
  "Whether BUFFER is a live working buffer, not an agent view or minibuffer."
  (when (consp buffer) (setq buffer (car buffer)))
  (when (stringp buffer) (setq buffer (get-buffer buffer)))
  (and (buffer-live-p buffer) (not (minibufferp buffer))
       (not (buffer-local-value 'emacs-agent-session--owner buffer))))

(defun emacs-agent-pending--rebind (input)
  "Explicitly rebind missing source/backend for INPUT; never recapture snapshots."
  (emacs-agent-session--unlocked)
  (require 'emacs-agent-gptel)
  (let* ((run (emacs-agent-input-run input))
         (source (emacs-agent-run-source-buffer run))
         (backend (emacs-agent-run-backend run))
         changed)
    (unless (emacs-agent-pending--working-buffer-p source)
      (setq source (get-buffer (read-buffer "Recovery source buffer: " nil t
                                            #'emacs-agent-pending--working-buffer-p)))
      (unless (emacs-agent-pending--working-buffer-p source)
        (user-error "Choose a live working buffer, not an agent view or minibuffer"))
      (push "source" changed))
    (unless backend
      (setq backend (cdr (assoc (emacs-agent-input-backend-name input) gptel--known-backends)))
      (unless backend
        (setq backend
              (cdr (assoc (completing-read "Recovery backend: " gptel--known-backends nil t)
                          gptel--known-backends))))
      (unless backend (user-error "No configured backend selected"))
      (push "backend configuration" changed))
    (setf (emacs-agent-run-source-buffer run) source
          (emacs-agent-run-backend run) backend)
    (when (member "source" changed)
      (setf (emacs-agent-run-source-window run) (get-buffer-window source t)
            (emacs-agent-input-source input)
            (list :name (buffer-name source)
                  :file (buffer-local-value 'buffer-file-name source))))
    (when (member "backend configuration" changed)
      (setf (emacs-agent-input-backend-name input) (gptel-backend-name backend)))
    (when changed
      (message "Rebound %s; original context, instructions and model settings retained (not reread)"
               (mapconcat #'identity (nreverse changed) " and ")))))

(defun emacs-agent-pending-edit (&optional input)
  "Withdraw INPUT before editing; C-g leaves it withdrawn with its original text."
  (interactive)
  (setq input (emacs-agent-pending--selected input))
  (emacs-agent-input-withdraw input)
  (unwind-protect
      (let ((text (save-current-buffer
                    (read-from-minibuffer
                     "Edit pending: " (emacs-agent-run-user-text (emacs-agent-input-run input))
                     emacs-agent-minibuffer-map nil 'emacs-agent-prompt-history))))
        (unless (string-empty-p (string-trim text))
          (emacs-agent-pending--rebind input)
          (emacs-agent-input-resubmit input text)))
    (emacs-agent-pending-refresh)))

(defun emacs-agent-pending-withdraw (&optional input)
  "Withdraw INPUT from automatic delivery, retaining it for recovery."
  (interactive)
  (emacs-agent-input-withdraw (emacs-agent-pending--selected input))
  (emacs-agent-pending-refresh))

(defun emacs-agent-pending-recover (&optional input)
  "Explicitly resubmit withdrawn INPUT using its original snapshots.
Stopped/restarted steering becomes a new ask.
Still-live steering stays steering."
  (interactive)
  (setq input (emacs-agent-pending--selected input))
  (unless (eq (emacs-agent-input-state input) 'withdrawn)
    (user-error "Withdraw this input before recovery"))
  (emacs-agent-pending--rebind input)
  (emacs-agent-input-resubmit input (emacs-agent-run-user-text (emacs-agent-input-run input)))
  (emacs-agent-pending-refresh))

(defun emacs-agent-pending-forget (&optional input)
  "Forget a withdrawn INPUT after confirmation, retaining its audit history."
  (interactive)
  (setq input (emacs-agent-pending--selected input))
  (unless (eq (emacs-agent-input-state input) 'withdrawn)
    (user-error "Withdraw this input before forgetting it"))
  (when (yes-or-no-p (format "Forget input %s? " (emacs-agent-input-id input)))
    (emacs-agent-input-forget input)
    (emacs-agent-pending-refresh)))

(defun emacs-agent-pending-show (&optional input)
  "Show INPUT's full, untruncated user text, without dumping API data."
  (interactive)
  (setq input (emacs-agent-pending--selected input))
  (let* ((session (emacs-agent-run-session (emacs-agent-input-run input)))
         (buffer (get-buffer-create (format "*emacs-agent-input: %s*" (emacs-agent-input-id input)))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (emacs-agent-run-user-text (emacs-agent-input-run input)))
        (goto-char (point-min)))
      (special-mode)
      (setq-local emacs-agent-session--owner session))
    (display-buffer buffer)
    buffer))

;;;###autoload
(defun emacs-agent-pending ()
  "Show the existing session's undelivered and withdrawn ask/steer inputs."
  (interactive)
  (let* ((session (emacs-agent--current-session))
         (buffer (get-buffer-create
                  (format "*emacs-agent-pending: %s*" (emacs-agent-session-id session)))))
    (with-current-buffer buffer
      (emacs-agent-pending-mode)
      (setq-local emacs-agent-session--owner session)
      (emacs-agent-pending-refresh))
    (display-buffer buffer)
    buffer))

;; Enable once on initial package load, preserving a user's later opt-out.
(unless (featurep 'emacs-agent) (emacs-agent-status-mode 1))

(provide 'emacs-agent)
;;; emacs-agent.el ends here
