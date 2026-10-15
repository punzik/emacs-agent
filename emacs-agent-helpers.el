;;; emacs-agent-helpers.el --- Read and edit live buffers reliably -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

;;; Commentary:
;; Ordinary Lisp helpers, not additional tools.  Reads preserve editor state;
;; explicit replacements use native buffer undo, never direct disk writes.

;;; Code:
(require 'cl-lib)
(require 'thingatpt)
(require 'emacs-agent-eval)

(defun emacs-agent-helpers--buffer (buffer)
  "Resolve explicit live BUFFER (object or name), without creating it."
  (or (and (or (bufferp buffer) (stringp buffer))
           (let ((resolved (get-buffer buffer)))
             (and (buffer-live-p resolved) resolved)))
      (error "Not a live buffer: %S" buffer)))

(defun emacs-agent-helpers--tick (tick)
  "Reject stale expected modification TICK in the current buffer."
  (when (and tick (not (eql tick (buffer-chars-modified-tick))))
    (error "Stale buffer modification tick")))

(defun emacs-agent-helpers--coordinates (position)
  "Return absolute line and display column at POSITION."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char position)
      (list :line (line-number-at-pos position t) :column (current-column)))))

(defun emacs-agent-helpers--info ()
  "Return current buffer identity and live coordinates."
  (append (list :buffer (buffer-name) :file buffer-file-name
                :point (point) :point-min (point-min) :point-max (point-max)
                :narrowed (buffer-narrowed-p) :modified (buffer-modified-p)
                :tick (buffer-chars-modified-tick))
          (emacs-agent-helpers--coordinates (point))))

(defun emacs-agent-helpers--fit (result)
  "Check RESULT fits the evaluator's printed final-value budget.
No preceding stdout is budgeted; call helpers as the sole final form."
  (let ((print-length nil) (print-level nil) (print-circle t))
    (<= (+ 4 (length (prin1-to-string result)))
        emacs-agent-eval-output-limit)))

(cl-defun emacs-agent-buffer-info (buffer &key tick)
  "Describe live BUFFER without changing editor state.
TICK, when non-nil, must equal `buffer-chars-modified-tick'.  Lines are
1-based, columns 0-based display columns (tabs expanded), positions character
positions.  Coordinates are absolute even when narrowed."
  (with-current-buffer (emacs-agent-helpers--buffer buffer)
    (emacs-agent-helpers--tick tick)
    (let ((result (emacs-agent-helpers--info)))
      (unless (emacs-agent-helpers--fit result)
        (error "eval output limit too small for helper metadata"))
      result)))

(defun emacs-agent-helpers--read (start end from limit extra)
  "Read absolute START through END lines, resuming at FROM.
LIMIT bounds text characters; EXTRA is additional result metadata.
Caller has established the accessible restriction."
  (unless (and (integerp start) (integerp end) (<= 1 start end)
               (integerp limit) (> limit 0))
    (error "Invalid line range or text limit"))
  (let* ((low (point-min)) (high (point-max))
         (info (emacs-agent-helpers--info))
         begin finish rows next result)
    (save-excursion
      (save-restriction
        (widen)
        (unless (<= end (line-number-at-pos (point-max) t))
          (error "Line range exceeds EOF"))
        (goto-char (point-min))
        (forward-line (1- start))
        (setq begin (point))
        (goto-char (point-min))
        (forward-line (1- end))
        (setq finish (line-end-position))
        (unless (and (<= low begin) (<= finish high))
          (error "Line range exceeds narrowing; use :widen t explicitly"))
        (when from
          (unless (and (integerp from) (<= begin from finish))
            (error "Invalid continuation position"))
          (setq begin from))
        ;; Shrink by text budget until the *printed* plist fits as well.
        ;; Escaping Unicode, quotes and newlines is accounted for by printing.
        (let ((budget limit) fitted)
          (while (not fitted)
            (goto-char begin)
            (setq rows nil next nil)
            (let ((remaining budget) (done nil))
              (while (not done)
                (let* ((pos (point)) (eol (min finish (line-end-position)))
                       (stop (min eol (+ pos remaining))))
                  (push (list :line (line-number-at-pos pos t)
                              :start pos :end stop :line-end eol
                              :text (buffer-substring-no-properties pos stop)) rows)
                  (setq remaining (- remaining (- stop pos)))
                  (cond
                   ((< stop eol) (setq next stop done t))
                   ((= eol finish) (setq done t))
                   ((<= remaining 1) (setq next (1+ eol) done t))
                   (t (setq remaining (1- remaining)) (goto-char (1+ eol)))))))
            (setq result (append info extra
                                 (list :requested-lines (list start end)
                                       :start begin :end (plist-get (car rows) :end)
                                       :truncated (and next t) :next-position next
                                       :lines (nreverse rows))))
            (if (and (emacs-agent-helpers--fit result)
                     (not (eql next begin)))
                (setq fitted t)
              (if (= budget 0)
                  (error "eval output limit too small for helper metadata")
                (setq budget (/ budget 2))))))))
    result))

(cl-defun emacs-agent-read-lines (buffer start end &key widen (limit 4096) from tick)
  "Read inclusive absolute START..END lines of live BUFFER.
Preserve empty lines, including the terminal empty line after a newline.
Each row contains absolute :line, :start, exclusive :end, :line-end and :text
without newline.  :end may precede :line-end on truncation.  LIMIT bounds text
characters (newline separators count too).  :next-position resumes with FROM
and the same START/END; pass returned :tick as TICK to detect intervening edits.
WIDEN permits reading outside narrowing, which is always restored.  Without
it, even partially inaccessible lines are rejected.  No silent clamping.
The printed result fits `emacs-agent-eval-output-limit' when used as the sole
final form without stdout; impossibly small limits signal an error."
  (with-current-buffer (emacs-agent-helpers--buffer buffer)
    (emacs-agent-helpers--tick tick)
    (save-excursion
      (save-restriction
        (when widen (widen))
        (emacs-agent-helpers--read start end from limit nil)))))

(cl-defun emacs-agent-read-around (buffer position &key (before 2) (after 2)
                                         widen (limit 4096) tick)
  "Read lines around explicit character POSITION in live BUFFER.
BEFORE/AFTER are nonnegative line counts, bounded intentionally by accessible
complete lines and EOF.  Return :at with actual coordinates and symbol at
POSITION, not at the user's point.  Other options follow
`emacs-agent-read-lines'.  Out-of-range positions and stale TICK signal errors."
  (unless (and (integerp position) (natnump before) (natnump after))
    (error "Invalid position or context counts"))
  (with-current-buffer (emacs-agent-helpers--buffer buffer)
    (emacs-agent-helpers--tick tick)
    (save-excursion
      (save-restriction
        (when widen (widen))
        (unless (<= (point-min) position (point-max))
          (error "Position outside accessible buffer"))
        (let* ((low (point-min)) (high (point-max))
               (at (emacs-agent-helpers--coordinates position))
               (line (plist-get at :line))
               first last symbol)
          (setq symbol (save-excursion
                         (goto-char position)
                         (thing-at-point 'symbol t)))
          (save-excursion
            (save-restriction
              (widen)
              (goto-char low)
              (setq first (+ (line-number-at-pos low t)
                             (if (bolp) 0 1)))
              (goto-char high)
              (setq last (- (line-number-at-pos high t)
                            (if (> (line-end-position) high) 1 0)))))
          (unless (<= first line last)
            (error "Position's line exceeds narrowing; use :widen t explicitly"))
          (emacs-agent-helpers--read
           (max first (- line before)) (min last (+ line after)) nil limit
           (list :at (append (list :position position :symbol symbol) at))))))))

(cl-defun emacs-agent-replace-region (buffer start end old new &key tick widen)
  "Replace explicit START..END in live BUFFER from OLD to NEW, with undo.
END is exclusive; positions are absolute character positions.  OLD must match
exactly, without text properties.  For insertion use START=END and OLD empty;
for deletion use NEW empty.  TICK is a required integer expected modification
tick, as returned by reading helpers.  Buffer positions start at 1, but string
indices start at 0: index I in text captured from buffer position BASE maps to
BASE+I, even under narrowing.  Prefer coordinates from reading helpers.
On OLD mismatch, the error shows at most 160 actual text characters (escaped
for readability), the range and current tick.  Reread before retrying; do not
guess offsets or bypass the helper.  Stale text/tick, disabled undo, read-only
buffers and external visited-file changes signal errors before editing.
Narrowing is respected unless WIDEN is explicitly non-nil, and restored.

The replacement is one atomic undo step, separate from previous user edits.
Point/mark and restrictions track edits as Emacs markers, not frozen numbers.
Normal change hooks run; errors roll back this buffer's text, not arbitrary
hook side effects elsewhere.  Identical OLD/NEW is a no-op.  Return a plist
with :buffer, :start, :end of the new range, :tick, :modified and :changed.
The printed result is budgeted like reading helpers; a budget error rolls
back the replacement.  Use as the sole final form without stdout.

This does NOT save.  Save explicitly in BUFFER with `save-buffer', never
fake saving with `set-buffer-modified-p' or direct `write-region'.  A later
save error leaves the successfully edited buffer available for inspection.
Undo follows normal Emacs lifetime/size limits, not persistent disk history."
  (unless (and (integerp start) (integerp end) (<= start end)
               (stringp old) (stringp new) (integerp tick))
    (error "Expected positions, OLD/NEW strings and explicit integer :tick"))
  (with-current-buffer (emacs-agent-helpers--buffer buffer)
    (emacs-agent-helpers--tick tick)
    (when buffer-read-only (error "Buffer is read-only"))
    (when (eq buffer-undo-list t) (error "Undo is disabled in buffer"))
    (when (and buffer-file-name (not (verify-visited-file-modtime)))
      (error "Visited file changed on disk; resolve conflict before editing"))
    (save-mark-and-excursion
      (save-restriction
        (when widen (widen))
        (unless (<= (point-min) start end (point-max))
          (error "Replacement range outside accessible buffer"))
        (unless (equal old (buffer-substring-no-properties start end))
          (let* ((preview-end (min end (+ start 160)))
                 (print-length nil) (print-level nil)
                 (print-escape-newlines t) (print-escape-control-characters t)
                 (actual (prin1-to-string
                          (buffer-substring-no-properties start preview-end))))
            (error (concat "Replacement OLD text does not match at [%d,%d), tick %d; "
                           "actual=%s%s. Reread with emacs-agent-read-lines or "
                           "emacs-agent-read-around before retrying; do not guess offsets")
                   start end (buffer-chars-modified-tick) actual
                   (if (< preview-end end)
                       (format " [truncated: %d of %d characters]"
                               (- preview-end start) (- end start))
                     ""))))
        (let ((changed (not (equal old new))) result)
          (unwind-protect
              (progn
                (when changed (undo-boundary))
                (atomic-change-group
                  (let ((handle (prepare-change-group)))
                    (when changed
                      (goto-char start)
                      (delete-region start end)
                      (insert (substring-no-properties new)))
                    (setq result
                          (list :buffer (buffer-name) :start start
                                :end (+ start (length new))
                                :tick (buffer-chars-modified-tick)
                                :modified (buffer-modified-p) :changed changed))
                    (unless (emacs-agent-helpers--fit result)
                      (error "eval output limit too small for helper metadata"))
                    ;; Hooks may insert boundaries; keep this replacement one step.
                    (undo-amalgamate-change-group handle))))
            (when changed (undo-boundary)))
          result)))))

(provide 'emacs-agent-helpers)
;;; emacs-agent-helpers.el ends here
