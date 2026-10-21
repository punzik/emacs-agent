;;; emacs-agent-log.el --- Incremental read-only event journal -*- lexical-binding: t; -*-

;;; Commentary:
;; The buffer is a disposable view.  Events, not rendered text, are the source
;; of truth.  Closing it never cancels a run; show replays the retained events.

;;; Code:
(require 'button)
(require 'seq)
(require 'emacs-agent-session)
(require 'emacs-agent-usage)

(declare-function emacs-agent-ask "emacs-agent")
(declare-function emacs-agent-cancel "emacs-agent")
(declare-function emacs-agent-resume "emacs-agent")
(declare-function emacs-agent-steer "emacs-agent")
(declare-function emacs-agent-pending "emacs-agent")

(defface emacs-agent-log-reasoning-face
  '((t (:inherit shadow)))
  "Face for supplied reasoning, including its foldable header and body."
  :group 'emacs-agent)

(defcustom emacs-agent-show-reasoning t
  "Display supplied reasoning in newly rendered journal sections.
Data is still retained for replay/persistence.  Reopen a journal to apply
this setting to previously rendered sections."
  :type 'boolean :group 'emacs-agent)

(defcustom emacs-agent-log-collapse-tools t
  "Initially fold tool arguments/results in newly rendered journal sections."
  :type 'boolean :group 'emacs-agent)
(defcustom emacs-agent-log-collapse-reasoning t
  "Initially fold reasoning that the provider actually supplied."
  :type 'boolean :group 'emacs-agent)

(defcustom emacs-agent-final-response-lines 3
  "Maximum screen lines of the final answer shown as a temporary message.
Zero disables the notification.  Full answers remain in the journal; previews
are not duplicated into *Messages*.  Only successful run completion notifies."
  :type 'natnum :group 'emacs-agent)

(defcustom emacs-agent-final-response-part 'start
  "Which part of a long final answer the temporary message shows."
  :type '(choice (const :tag "Beginning" start) (const :tag "End" end))
  :group 'emacs-agent)

(defun emacs-agent-log--response-preview (text lines part window)
  "Fit plain TEXT to LINES screen rows of WINDOW, taking PART.
Ellipses mark omitted text and count within the limit.  No editor window,
source buffer, journal or model message is modified."
  (let* ((plain (string-trim (substring-no-properties text)))
         (width (max 1 (1- (window-body-width window))))
         (marker (truncate-string-to-width "..." width)))
    (unless (string-empty-p plain)
      (with-temp-buffer
        (insert plain)
        (setq-local truncate-lines nil word-wrap nil)
        ;; Match echo-area tab expansion instead of inheriting a source mode.
        (setq-local tab-width 8)
        (untabify (point-min) (point-max))
        (goto-char (point-min))
        (vertical-motion lines window)
        (if (= (point) (point-max))
            (buffer-substring-no-properties (point-min) (point-max))
          (if (eq part 'end)
              (progn
                ;; Start on the last actual character, not a virtual empty
                ;; screen row when EOB sits exactly on a wrapping boundary.
                (goto-char (1- (point-max)))
                (vertical-motion (- (1- lines)) window)
                (let* ((start (point))
                       (row-end (save-excursion (vertical-motion 1 window) (point)))
                       (row (string-trim-right
                             (buffer-substring-no-properties start row-end) "\n"))
                       (overflow (max 0 (- (+ (string-width row) (string-width marker)) width))))
                  (move-to-column (+ (current-column) overflow))
                  (concat marker (buffer-substring-no-properties (point) (point-max)))))
            (goto-char (point-min))
            (vertical-motion (1- lines) window)
            (let ((column (+ (current-column) (- width (string-width marker)))))
              (move-to-column column)
              ;; A wide character can overshoot the requested column.
              (while (> (current-column) column) (backward-char)))
            (concat (buffer-substring-no-properties (point-min) (point)) marker)))))))

(defun emacs-agent--notify-final (run)
  "Temporarily echo RUN's final assistant answer, never tool-round commentary.
Skip a duplicate when the selected window shows this session's journal.
Notification failures cannot strand a completed run or its FIFO."
  (condition-case nil
      (let* ((lines emacs-agent-final-response-lines)
             (window (minibuffer-window))
             ;; Do not search backwards: an empty final response after tools
             ;; must not redisplay an earlier assistant/tool-round message.
             (last (car (last (emacs-agent-session-messages (emacs-agent-run-session run))))))
        (when (and (natnump lines) (> lines 0) (window-live-p window)
                   (not (eq (window-buffer (selected-window))
                            (emacs-agent-session-log-buffer (emacs-agent-run-session run))))
                   (eq (plist-get last :role) 'assistant)
                   (equal (plist-get last :run-id) (emacs-agent-run-id run)))
          (when-let* ((preview (emacs-agent-log--response-preview
                               (plist-get last :text) lines
                               emacs-agent-final-response-part window)))
            (let ((message-log-max nil) (max-mini-window-height lines)
                  (resize-mini-windows t) (message-truncate-lines nil))
              (message "%s" preview)))))
    ((error quit) nil)))

(defvar-local emacs-agent-log--cursor nil "Last consumed cons in the event list.")
(defvar-local emacs-agent-log--tail nil "Last appendable text section, or nil.")

(defvar-local emacs-agent-log-details nil
  "Whether this journal displays diagnostic event details.")
(defvar-local emacs-agent-log--tools nil)
(defvar-local emacs-agent-log--folds nil)
(defvar-local emacs-agent-log--locations nil)

(defvar emacs-agent-log-section-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map button-map)
    (define-key map (kbd "TAB") #'emacs-agent-log-toggle-section)
    (define-key map (kbd "<tab>") #'emacs-agent-log-toggle-section)
    map)
  "Button bindings that keep TAB on the current section.")

(defvar emacs-agent-log-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "TAB") #'emacs-agent-log-toggle-section)
    (define-key map (kbd "<tab>") #'emacs-agent-log-toggle-section)
    (define-key map (kbd "D") #'emacs-agent-log-toggle-details)
    (define-key map (kbd "g") #'emacs-agent-log-refresh)
    (define-key map (kbd "a") #'emacs-agent-ask)
    (define-key map (kbd "C-c C-s") #'emacs-agent-steer)
    (define-key map (kbd "C-c C-p") #'emacs-agent-pending)
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
  (setq-local emacs-agent-log--tools (make-hash-table :test #'equal)
              emacs-agent-log--folds (make-hash-table :test #'equal)
              emacs-agent-log--locations (make-hash-table :test #'equal))
  (setq-local header-line-format
              '(:eval (when emacs-agent-session--owner
                        (format " Agent %s%s"
                                (replace-regexp-in-string
                                 "%" "%%" (emacs-agent-log--label emacs-agent-session--owner))
                                (if emacs-agent-log-details " | Details" ""))))))

(defun emacs-agent-log--label (session)
  "Return a short display label for SESSION, not a selector identity."
  (let ((root (emacs-agent-session-project-root session))
        (name (emacs-agent-session-name session)))
    (format "%s / %s"
            (if root (file-name-nondirectory (directory-file-name root)) "global")
            (if (string-empty-p (or name "")) "conversation" name))))

(defun emacs-agent--session-name (session)
  "Return a readable collision-resistant name for SESSION."
  (let* ((root (emacs-agent-session-project-root session))
         (scope (if root
                    (format "%s#%s" (file-name-nondirectory (directory-file-name root))
                            (substring (secure-hash 'sha256 root) 0 10))
                  "global")))
    (format "%s/%s#%s" scope (if (string-empty-p (or (emacs-agent-session-name session) ""))
                                     "conversation" (emacs-agent-session-name session))
            (substring (secure-hash 'sha256 (emacs-agent-session-id session)) 0 10))))

(defun emacs-agent--log-buffer (session)
  "Return SESSION's live journal buffer, creating it if needed."
  (or (and (buffer-live-p (emacs-agent-session-log-buffer session))
           (emacs-agent-session-log-buffer session))
      (let ((buffer (generate-new-buffer
                     (format "*emacs-agent: %s*" (emacs-agent-log--label session)))))
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
  (let* ((inhibit-read-only t)
         (closed (not (overlay-get overlay 'invisible)))
         (header (overlay-get overlay 'header))
         (preview (overlay-get overlay 'preview)))
    (when (or (and closed (<= (overlay-start overlay) (point))
                   (< (point) (overlay-end overlay)))
              (and (not closed) preview
                   (<= (overlay-start preview) (point))
                   (< (point) (overlay-end preview))))
      (goto-char header))
    (overlay-put overlay 'invisible (and closed 'emacs-agent-fold))
    (when preview
      (overlay-put preview 'invisible (unless closed 'emacs-agent-fold)))
    (puthash (overlay-get overlay 'event-id) closed emacs-agent-log--folds)
    (save-excursion
      (goto-char header)
      (subst-char-in-region (point) (1+ (point)) (char-after)
                            (if closed ?▸ ?▾) t))
    (set-buffer-modified-p nil)))

(defun emacs-agent-log--button (button)
  "Toggle the section attached to BUTTON."
  (emacs-agent-log--toggle (button-get button 'emacs-agent-section)))

(defun emacs-agent-log-toggle-section ()
  "Fold/unfold the tool or reasoning section at point."
  (interactive)
  (let* ((section (or (get-text-property (point) 'emacs-agent-section)
                      (get-text-property (line-beginning-position) 'emacs-agent-section)
                      (cl-find-if (lambda (overlay) (overlay-get overlay 'emacs-agent-section))
                                  (overlays-at (point))))))
    (emacs-agent-log--toggle
     (if (and (overlayp section) (overlayp (overlay-get section 'emacs-agent-section)))
         (overlay-get section 'emacs-agent-section)
       section))))

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

(defun emacs-agent-log--tool-source (args)
  "Render ARGS as inert expression and indexed literal text payloads."
  (concat (format "%s" (plist-get args :expression))
          (when (plist-member args :texts)
            (let ((texts (plist-get args :texts)))
              (if (vectorp texts)
                  (if (zerop (length texts)) "\n\ntexts: []"
                    (mapconcat
                     (lambda (index)
                       (format "\n\ntexts[%d]:\n%s" index
                               (if (stringp (aref texts index))
                                   (substring-no-properties (aref texts index))
                                 (format "%S" (aref texts index)))))
                     (number-sequence 0 (1- (length texts))) ""))
                (format "\n\ntexts: %S" texts))))))

(defun emacs-agent-log--payload (type payload)
  "Return display text for TYPE and PAYLOAD, never evaluating their contents."
  (pcase type
    ('queued "Waiting in session FIFO")
    ('input (format "%s: %s (%s)\n%s"
                    (plist-get payload :id) (plist-get payload :state) (plist-get payload :kind)
                    (plist-get (plist-get payload :run) :user-text)))
    ((or 'steering 'input-recovery)
     (mapconcat (lambda (input) (emacs-agent-log--payload 'input input)) payload "\n\n"))
    ((or 'usage 'usage-total) (emacs-agent-usage-format payload))
    ('instructions (emacs-agent-resources-summary payload))
    ('inherited-summary (format "Inherited compaction summary (%s archived records).\n\n%s"
                                (plist-get payload :cut) (plist-get payload :summary)))
    ('compacted (format "Context compacted (estimated %s tokens before; %s original records summarized).\n\n%s"
                        (plist-get payload :tokens-before) (plist-get payload :cut)
                        (plist-get payload :summary)))
    ('tool-call (format "eval_elisp %s\n%s" (plist-get payload :id)
                        (emacs-agent-log--tool-source (plist-get payload :args))))
    ('tool-result (format "%s\n%s" (plist-get payload :id) (plist-get payload :result)))
    (_ (if (stringp payload) (substring-no-properties payload) (format "%s" payload)))))

(defun emacs-agent-log--face (type)
  "Choose a header face for TYPE."
  (pcase type
    ((or 'failed 'error 'cancelled) 'error)
    ((or 'paused 'interrupted 'input-recovery 'compaction-stopped 'instructions) 'warning)
    ('completed 'success)
    ('reasoning 'emacs-agent-log-reasoning-face)
    (_ 'font-lock-keyword-face)))

(defun emacs-agent-log--short (text &optional lines limit)
  "Bound TEXT to LINES (default one) and LIMIT (default 100) characters."
  (let* ((text (format "%s" (or text "")))
         (part (mapconcat #'identity
                          (seq-take (split-string text "\n") (or lines 1)) "\n"))
         (limit (or limit 100)))
    (if (or (> (length part) limit) (< (length part) (length text)))
        (concat (substring part 0 (min (length part) limit)) "…")
      part)))

(defun emacs-agent-log--tool-preview (result)
  "Bound RESULT's UI preview, retaining any capture-truncation notice.
This does not read the artifact named in a notice."
  (let ((text (format "%s" (or result ""))) (from 0) notice-start)
    ;; Prefer the final capture notice, not similar text printed in the body.
    (while (string-match "\n\\[truncated;" text from)
      (setq notice-start (match-beginning 0) from (match-end 0)))
    (let* ((notice (and notice-start (string-suffix-p "]" text)
                        (substring text (1+ notice-start))))
           (body (if notice (substring text 0 notice-start) text)))
      (concat (emacs-agent-log--short body 3 400)
              (when notice (concat "\n" notice))))))

(defun emacs-agent-log--block (event label text &optional foldable preview)
  "Insert a display block for EVENT with LABEL and retained TEXT.
FOLDABLE bodies have a separate optional PREVIEW visible only when closed.
Return local markers and overlays; never write to EVENT."
  (goto-char (point-max))
  (let* ((type (plist-get event :type))
         (id (plist-get event :id))
         (closed (gethash id emacs-agent-log--folds
                          (if (eq type 'reasoning) emacs-agent-log-collapse-reasoning
                            emacs-agent-log-collapse-tools)))
         (header (copy-marker (point)))
         (header-end (progn
                       (unless (string-empty-p label)
                         (insert (if foldable (if closed "▸ " "▾ ") "") label "\n"))
                       (point)))
         (preview-start (copy-marker (point)))
         (preview-end (progn (when preview (insert preview "\n")) (point)))
         (body-start (copy-marker (point)))
         (body-end (progn (insert text) (copy-marker (point))))
         overlay preview-overlay)
    (puthash id header emacs-agent-log--locations)
    ;; The separator is visible and belongs to this block for reader anchors.
    (insert "\n\n")
    (add-text-properties header (point) (list 'emacs-agent-event-id id))
    (set-marker-insertion-type body-end t)
    (when foldable
      (setq overlay (make-overlay body-start body-end nil nil t))
      (overlay-put overlay 'emacs-agent-section t)
      (when (eq type 'reasoning)
        (overlay-put overlay 'face 'emacs-agent-log-reasoning-face))
      (overlay-put overlay 'header header)
      (overlay-put overlay 'event-id id)
      (overlay-put overlay 'invisible (and closed 'emacs-agent-fold))
      (when preview
        (setq preview-overlay (make-overlay preview-start preview-end))
        (overlay-put preview-overlay 'invisible (unless closed 'emacs-agent-fold))
        (overlay-put preview-overlay 'emacs-agent-section overlay)
        (overlay-put overlay 'preview preview-overlay))
      (make-text-button header (1- header-end)
                        'keymap emacs-agent-log-section-map
                        'action #'emacs-agent-log--button
                        'emacs-agent-section overlay 'follow-link t))
    (when (> header-end (marker-position header))
      (add-text-properties header (1- header-end)
                           (list 'face (if (eq type 'user) 'font-lock-function-name-face
                                         (emacs-agent-log--face type)))))
    (list :type type :run (plist-get event :run-id) :id id :header header
          :preview-start preview-start :body-start body-start
          :end body-end :overlay overlay)))

(defun emacs-agent-log--tool-result (event block)
  "Update paired tool BLOCK with EVENT, without rebuilding other history."
  (let* ((result (plist-get (plist-get event :payload) :result))
         (overlay (plist-get block :overlay))
         (preview-overlay (overlay-get overlay 'preview))
         (start (marker-position (plist-get block :preview-start)))
         (end (plist-get block :end))
         (result-start (overlay-get overlay 'result-start)))
    ;; Replace only the bounded preview; keep the expression and reader markers.
    (goto-char start)
    (delete-region start (plist-get block :body-start))
    (insert-before-markers (emacs-agent-log--tool-preview result) "\n")
    (set-marker (plist-get block :preview-start) start)
    (set-marker (plist-get block :body-start) (point))
    (move-overlay preview-overlay start (point))
    (unless result-start
      (goto-char end)
      (insert "\n\n")
      (setq result-start (copy-marker (point)))
      (overlay-put overlay 'result-start result-start))
    (goto-char result-start)
    (delete-region result-start end)
    (insert (format "%s" result))
    (set-marker end (point))
    (move-overlay overlay (plist-get block :body-start) end)
    (add-text-properties start end (list 'emacs-agent-event-id (plist-get block :id)))
    (puthash (plist-get event :id) (plist-get block :header) emacs-agent-log--locations)))

(defun emacs-agent-log--section (event)
  "Consume EVENT incrementally in the selected display policy."
  (let* ((type (plist-get event :type))
         (run (plist-get event :run-id))
         (payload (plist-get event :payload)))
    (cond
     ((memq type '(assistant-end reasoning-end))
      (setq emacs-agent-log--tail nil)
      (when emacs-agent-log-details
        (emacs-agent-log--block event (format "%s [%s]" type run) (format "%S" event))))
     ((and (eq type 'reasoning) (not emacs-agent-show-reasoning))
      (setq emacs-agent-log--tail nil))
     (emacs-agent-log-details
      (setq emacs-agent-log--tail nil)
      (emacs-agent-log--block event (format "%s [%s] %s" type run (plist-get event :id))
                              (concat (when (memq type '(usage usage-total))
                                        (concat (emacs-agent-log--payload type payload) "\n\n"))
                                      (format "%S" event))
                              (memq type '(reasoning tool-call tool-result))))
     ((and (eq type 'instructions) (plist-get payload :warnings))
      (setq emacs-agent-log--tail nil)
      (emacs-agent-log--block event "Project instruction warning"
                              (string-join (plist-get payload :warnings) "\n")))
     ((not (memq type '(assistant reasoning user steering tool-call tool-result
                                 compacted inherited-summary input-recovery
                                 failed error cancelled paused interrupted compaction-stopped
                                 unsupported-protocol))) nil)
     ((and (memq type '(assistant reasoning)) emacs-agent-log--tail
           (eq type (plist-get emacs-agent-log--tail :type))
           (equal run (plist-get emacs-agent-log--tail :run)))
      (goto-char (plist-get emacs-agent-log--tail :end))
      (let ((start (point)))
        (insert (emacs-agent-log--payload type payload))
        (add-text-properties start (point)
                             (list 'emacs-agent-event-id (plist-get emacs-agent-log--tail :id))))
      (puthash (plist-get event :id) (plist-get emacs-agent-log--tail :header)
               emacs-agent-log--locations))
     (t
      (setq emacs-agent-log--tail nil)
      (pcase type
        ((or 'assistant 'reasoning)
         (setq emacs-agent-log--tail
               (emacs-agent-log--block event (if (eq type 'assistant) "" "Reasoning")
                                       (emacs-agent-log--payload type payload)
                                       (eq type 'reasoning))))
        ('user (emacs-agent-log--block event "You" (emacs-agent-log--payload type payload)))
        ('steering
         (emacs-agent-log--block
          event "You · steering"
          (mapconcat (lambda (input) (or (plist-get (plist-get input :run) :user-text) ""))
                     payload "\n\n")))
        ('tool-call
         (let* ((expression (format "%s" (plist-get (plist-get payload :args) :expression)))
                (block (emacs-agent-log--block
                        event (concat "eval_elisp  " (emacs-agent-log--short expression))
                        (emacs-agent-log--tool-source (plist-get payload :args))
                        t "Result not recorded.")))
           (puthash (list run (plist-get payload :id)) block emacs-agent-log--tools)))
        ('tool-result
         (let ((block (gethash (list run (plist-get payload :id)) emacs-agent-log--tools)))
           (if block (emacs-agent-log--tool-result event block)
             (emacs-agent-log--block event "Tool result · unmatched"
                                     (format "%s" (plist-get payload :result)) t
                                     (emacs-agent-log--tool-preview (plist-get payload :result))))))
        ((or 'compacted 'inherited-summary)
         (emacs-agent-log--block event
                                 (if (eq type 'compacted) "Context compacted" "Inherited summary")
                                 (if (listp payload) (or (plist-get payload :summary) "")
                                   (emacs-agent-log--payload type payload)) t))
        ('input-recovery
         (emacs-agent-log--block
          event "Unsent input · C-c C-p to inspect"
          (mapconcat (lambda (input) (or (plist-get (plist-get input :run) :user-text) ""))
                     payload "\n\n")))
        ((or 'failed 'error 'cancelled 'paused 'interrupted 'compaction-stopped
             'unsupported-protocol)
         (emacs-agent-log--block event (symbol-name type)
                                (emacs-agent-log--payload type payload))))))))

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
           (emacs-agent-log--section (car events))
           (setq emacs-agent-log--cursor events events (cdr events))))))
    (set-buffer-modified-p nil)))

(defun emacs-agent--refresh-log (session _event)
  "Update SESSION only if its journal is live; callbacks never resurrect it."
  (when (buffer-live-p (emacs-agent-session-log-buffer session))
    (emacs-agent--render-log session)))

(defun emacs-agent-log--anchor (position)
  "Describe POSITION relative to a stable first event in the view."
  (let* ((position (max (point-min) (min position (point-max))))
         (id (or (get-text-property position 'emacs-agent-event-id)
                 (and (> position (point-min))
                      (get-text-property (1- position) 'emacs-agent-event-id))))
         (marker (and id (gethash id emacs-agent-log--locations))))
    (list id (if marker (- position marker) 0) (= position (point-max)))))

(defun emacs-agent-log--anchor-position (anchor)
  "Resolve ANCHOR after a display-policy rebuild."
  (if (nth 2 anchor) (point-max)
    (let ((marker (gethash (car anchor) emacs-agent-log--locations)))
      ;; A details-only event may have disappeared.  Stay near the preceding
      ;; visible event, rather than jumping to the end of the conversation.
      (unless (or marker (null (car anchor)))
        (cl-loop for event in (emacs-agent-session-events emacs-agent-session--owner)
                 do (when (gethash (plist-get event :id) emacs-agent-log--locations)
                      (setq marker (gethash (plist-get event :id) emacs-agent-log--locations)))
                 until (equal (plist-get event :id) (car anchor))))
      (if marker
          (min (or (next-single-property-change marker 'emacs-agent-event-id) (point-max))
               (+ marker (max 0 (cadr anchor))))
        (point-min)))))

(defun emacs-agent-log-toggle-details ()
  "Rebuild this disposable view with diagnostic details toggled.
Retain fold choices by first event ID; never flush or modify session history."
  (interactive)
  (unless emacs-agent-session--owner (user-error "Not an agent journal"))
  (let ((anchor (emacs-agent-log--anchor (point)))
        (windows (mapcar (lambda (window)
                           (list window
                                 (emacs-agent-log--anchor (window-point window))
                                 (emacs-agent-log--anchor (window-start window))
                                 (window-vscroll window t)))
                         (get-buffer-window-list (current-buffer) nil t)))
        (inhibit-read-only t))
    (dolist (overlay (append (car (overlay-lists)) (cdr (overlay-lists))))
      (when (eq (overlay-get overlay 'emacs-agent-section) t)
        (puthash (overlay-get overlay 'event-id) (and (overlay-get overlay 'invisible) t)
                 emacs-agent-log--folds)))
    (setq emacs-agent-log-details (not emacs-agent-log-details)
          emacs-agent-log--cursor nil emacs-agent-log--tail nil)
    (clrhash emacs-agent-log--tools)
    (clrhash emacs-agent-log--locations)
    (remove-overlays)
    (erase-buffer)
    (emacs-agent--render-log emacs-agent-session--owner)
    (goto-char (emacs-agent-log--anchor-position anchor))
    (dolist (entry windows)
      (pcase-let ((`(,window ,position ,start ,vscroll) entry))
        (when (and (window-live-p window) (eq (window-buffer window) (current-buffer)))
          (set-window-point window (emacs-agent-log--anchor-position position))
          (set-window-start window (emacs-agent-log--anchor-position start) t)
          (set-window-vscroll window vscroll t))))
    (set-buffer-modified-p nil)
    (force-mode-line-update)))

(defun emacs-agent-log-refresh ()
  "Render any unconsumed events in the current journal."
  (interactive)
  (unless emacs-agent-session--owner (user-error "Not an agent journal"))
  (emacs-agent--render-log emacs-agent-session--owner))

(add-hook 'emacs-agent-session-event-functions #'emacs-agent--refresh-log)

(provide 'emacs-agent-log)
;;; emacs-agent-log.el ends here
