;;; emacs-agent-log.el --- Incremental read-only event journal -*- lexical-binding: t; -*-

;;; Commentary:
;; The buffer is a disposable view.  Events, not rendered text, are the source
;; of truth.  Closing it never cancels a run; show replays the retained events.

;;; Code:
(require 'button)
(require 'emacs-agent-session)
(require 'emacs-agent-usage)

(declare-function emacs-agent-ask "emacs-agent")
(declare-function emacs-agent-cancel "emacs-agent")
(declare-function emacs-agent-resume "emacs-agent")

(defcustom emacs-agent-show-reasoning t
  "Display supplied reasoning in newly rendered journal sections.
Data is still retained for replay/persistence.  Reopen a journal to apply
this setting to previously rendered sections."
  :type 'boolean :group 'emacs-agent)

(defcustom emacs-agent-log-collapse-tools t
  "Initially fold tool arguments/results in newly rendered journal sections."
  :type 'boolean :group 'emacs-agent)
(defcustom emacs-agent-log-collapse-reasoning nil
  "Initially fold reasoning that the provider actually supplied."
  :type 'boolean :group 'emacs-agent)

(defvar-local emacs-agent-log--cursor nil "Last consumed cons in the event list.")
(defvar-local emacs-agent-log--tail nil "Last appendable text section, or nil.")

(defvar emacs-agent-log-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "TAB") #'emacs-agent-log-toggle-section)
    (define-key map (kbd "g") #'emacs-agent-log-refresh)
    (define-key map (kbd "a") #'emacs-agent-ask)
    (define-key map (kbd "C-c C-k") #'emacs-agent-cancel)
    (define-key map (kbd "C-c C-c") #'emacs-agent-resume)
    map)
  "Local journal bindings; global bindings are never installed.")

(define-derived-mode emacs-agent-log-mode special-mode "Emacs-Agent"
  "Read-only incremental agent journal.
TAB or click a section header to fold/unfold tools and reasoning.
C-c C-k cancels, C-c C-c resumes a paused run, a asks from its working buffer.
Closing the buffer does not cancel the run."
  (add-to-invisibility-spec 'emacs-agent-fold)
  (setq-local header-line-format
              '(:eval (when emacs-agent-session--owner
                        (let ((run (emacs-agent-session-active-run emacs-agent-session--owner)))
                          (format " Agent: %s | queued: %d"
                                  (if run (emacs-agent-run-status run) 'idle)
                                  (length (emacs-agent-session-pending-runs emacs-agent-session--owner))))))))

(defun emacs-agent--session-name (session)
  "Return a readable collision-resistant name for SESSION."
  (let ((root (emacs-agent-session-project-root session)))
    (if root
        (format "%s#%s" (file-name-nondirectory (directory-file-name root))
                (substring (secure-hash 'sha256 root) 0 10))
      "global")))

(defun emacs-agent--log-buffer (session)
  "Return SESSION's live journal buffer, creating it if needed."
  (or (and (buffer-live-p (emacs-agent-session-log-buffer session))
           (emacs-agent-session-log-buffer session))
      (let ((buffer (generate-new-buffer
                     (format "*emacs-agent: %s*" (emacs-agent--session-name session)))))
        (with-current-buffer buffer
          (emacs-agent-log-mode)
          (setq-local emacs-agent-session--owner session)
          (setq-local default-directory
                      (or (emacs-agent-session-project-root session) default-directory)))
        (setf (emacs-agent-session-log-buffer session) buffer)
        buffer)))

(defun emacs-agent-log--toggle (overlay)
  "Toggle folding of OVERLAY's body; do not change canonical events."
  (unless (and (overlayp overlay) (overlay-buffer overlay))
    (user-error "No foldable section here"))
  (overlay-put overlay 'invisible
               (unless (overlay-get overlay 'invisible) 'emacs-agent-fold)))

(defun emacs-agent-log--button (button)
  "Toggle the section attached to BUTTON."
  (emacs-agent-log--toggle (button-get button 'emacs-agent-section)))

(defun emacs-agent-log-toggle-section ()
  "Fold/unfold the tool or reasoning section at point."
  (interactive)
  (emacs-agent-log--toggle
   (or (get-text-property (point) 'emacs-agent-section)
       (cl-find-if (lambda (overlay) (overlay-get overlay 'emacs-agent-section))
                   (overlays-at (point))))))

(defun emacs-agent-log--preserve-view (function)
  "Call FUNCTION preserving reader points, starts and pixel vscroll.
Only buffer/window points already at the old buffer end follow new text.
Do not select windows, steal focus, or force readers of old entries to scroll."
  (let* ((end (point-max))
         (follow (= (point) end))
         (windows (mapcar
                   (lambda (window)
                     (list window (= (window-point window) end)
                           (copy-marker (window-point window))
                           (copy-marker (window-start window))
                           (window-vscroll window t)))
                   (get-buffer-window-list (current-buffer) nil t))))
    (unwind-protect
        (progn
          (save-excursion (funcall function))
          (when follow (goto-char (point-max)))
          (dolist (entry windows)
            (pcase-let ((`(,window ,tail ,position ,start ,vscroll) entry))
              (when (and (window-live-p window) (eq (window-buffer window) (current-buffer)))
                (if tail
                    (progn
                      (set-window-point window (point-max))
                      ;; Let redisplay follow point; do not force a reader's
                      ;; window-start when its point is not at the end.
                      (set-window-start window (marker-position start) t))
                  (set-window-point window (marker-position position))
                  (set-window-start window (marker-position start) t)
                  (set-window-vscroll window vscroll t))))))
      (dolist (entry windows)
        (set-marker (nth 2 entry) nil)
        (set-marker (nth 3 entry) nil)))))

(defun emacs-agent-log--payload (type payload)
  "Return display text for TYPE and PAYLOAD, never evaluating their contents."
  (pcase type
    ('queued "Waiting in session FIFO")
    ((or 'usage 'usage-total) (emacs-agent-usage-format payload))
    ('instructions (emacs-agent-resources-summary payload))
    ('tool-call (format "eval_elisp %s\n%s" (plist-get payload :id)
                        (plist-get (plist-get payload :args) :expression)))
    ('tool-result (format "%s\n%s" (plist-get payload :id) (plist-get payload :result)))
    (_ (if (stringp payload) (substring-no-properties payload) (format "%s" payload)))))

(defun emacs-agent-log--face (type)
  "Choose a header face for TYPE."
  (pcase type
    ((or 'failed 'error 'cancelled) 'error)
    ((or 'paused 'interrupted) 'warning)
    ('completed 'success)
    ('reasoning 'font-lock-comment-face)
    (_ 'font-lock-keyword-face)))

(defun emacs-agent-log--section (event)
  "Append EVENT as a section, or append its delta to the last text section."
  (let* ((type (plist-get event :type))
         (run (plist-get event :run-id))
         (text (emacs-agent-log--payload type (plist-get event :payload)))
         (foldable (memq type '(tool-call tool-result reasoning))))
    (if (and (memq type '(assistant reasoning)) emacs-agent-log--tail
             (eq type (plist-get emacs-agent-log--tail :type))
             (equal run (plist-get emacs-agent-log--tail :run)))
        (progn
          (goto-char (plist-get emacs-agent-log--tail :end))
          (insert text))
      (goto-char (point-max))
      (let* ((header-start (point))
             (header (format "%s [%s]%s\n" type run (if foldable " (TAB to fold)" "")))
             (header-end (progn (insert header) (point)))
             (body-start (point))
             (body-end (progn (insert text) (copy-marker (point))))
             overlay)
        ;; Exclude the separator; later chunks extend only the body.
        (insert "\n\n")
        (set-marker-insertion-type body-end t)
        (when foldable
          (setq overlay (make-overlay body-start (marker-position body-end) nil nil t))
          (overlay-put overlay 'emacs-agent-section t)
          (overlay-put overlay 'invisible
                       (when (if (eq type 'reasoning) emacs-agent-log-collapse-reasoning
                               emacs-agent-log-collapse-tools)
                         'emacs-agent-fold))
          (make-text-button header-start (1- header-end)
                            'action #'emacs-agent-log--button
                            'emacs-agent-section overlay 'follow-link t))
        (add-text-properties header-start (1- header-end)
                             (list 'face (emacs-agent-log--face type)))
        (setq emacs-agent-log--tail
              (when (memq type '(assistant reasoning))
                (list :type type :run run :end body-end :overlay overlay)))))))

(defun emacs-agent--render-log (session)
  "Consume only newly appended SESSION events, preserving the visible reader.
A recreated journal starts with an empty cursor and replays every event.
Folding state remains local to the live view and never changes model history."
  (with-current-buffer (emacs-agent--log-buffer session)
    (emacs-agent-log--preserve-view
     (lambda ()
       (let ((inhibit-read-only t)
             (events (if emacs-agent-log--cursor (cdr emacs-agent-log--cursor)
                       (emacs-agent-session-events session))))
         (while events
           (let ((event (car events)))
             (if (or (memq (plist-get event :type) '(assistant-end reasoning-end))
                     (and (eq (plist-get event :type) 'reasoning)
                          (not emacs-agent-show-reasoning)))
                 (setq emacs-agent-log--tail nil)
               (emacs-agent-log--section event)))
           (setq emacs-agent-log--cursor events events (cdr events))))))
    (set-buffer-modified-p nil)
    (force-mode-line-update)))

(defun emacs-agent--refresh-log (session _event)
  "Update SESSION only if its journal is live; callbacks never resurrect it."
  (when (buffer-live-p (emacs-agent-session-log-buffer session))
    (emacs-agent--render-log session)))

(defun emacs-agent-log-refresh ()
  "Render any unconsumed events in the current journal."
  (interactive)
  (unless emacs-agent-session--owner (user-error "Not an agent journal"))
  (emacs-agent--render-log emacs-agent-session--owner))

(add-hook 'emacs-agent-session-event-functions #'emacs-agent--refresh-log)

(provide 'emacs-agent-log)
;;; emacs-agent-log.el ends here
