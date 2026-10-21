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
                :tick (buffer-chars-modified-tick)
                :total-lines (save-restriction
                               (widen)
                               (line-number-at-pos (point-max) t)))
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
positions.  Coordinates are absolute even when narrowed.  :total-lines is
also absolute for the whole buffer, including a terminal empty line after a
newline; an empty buffer has one line.  This does not grant access outside
narrowing."
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
         begin finish result)
    (save-excursion
      (save-restriction
        (widen)
        (unless (<= end (plist-get info :total-lines))
          (error "Requested lines %d–%d; buffer has %d lines (EOF)"
                 start end (plist-get info :total-lines)))
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
        ;; One literal substring, including separators: every continuation
        ;; starts exactly where the previous one ended, even on a newline.
        (let ((budget (min limit (- finish begin))) fitted)
          (while (not fitted)
            (let* ((stop (+ begin budget))
                   (next (and (< stop finish) stop)))
              (setq result
                    (append info extra
                            (list :requested-lines (list start end)
                                  :start begin :end stop
                                  :start-line (line-number-at-pos begin t)
                                  :end-line (line-number-at-pos stop t)
                                  :truncated (and next t) :next-position next
                                  :text (buffer-substring-no-properties begin stop))))
              (if (emacs-agent-helpers--fit result) (setq fitted t)
                (if (<= budget 1)
                    (error "eval output limit too small for helper metadata")
                  (setq budget (max 1 (/ budget 2))))))))))
    result))

(cl-defun emacs-agent-run-process (program args &key (directory default-directory))
  "Run PROGRAM synchronously with string ARGS in DIRECTORY.
ARGS is a proper list or vector.  No shell is used unless PROGRAM is one.
Bare names use native `process-file' lookup; paths with a directory
component are expanded against DIRECTORY, fixing relative executable
lookup.  A qualified remote PROGRAM must use DIRECTORY's host.  Arguments
are passed literally, without path expansion, quoting or unescaping.

Return :output (fresh combined stdout/stderr), :directory (expanded
cwd), :command (program and argv actually passed) and :exit (integer or
signal string).  :command names the invocation, not a resolved binary.
Output precedes metadata and :exit is last so F3 tails retain status.
`eval_elisp' applies its normal F3 limiter.  Launch errors and quit
propagate; no exit status is invented.

This does not save, edit or select the caller's buffer, infer which
file was checked, interpret success, retry commands or clean generated
files.  Process side effects are not rolled back.  The private output
buffer is always removed.  Use an existing asynchronous workflow for
long commands."
  (unless (and (stringp program) (> (length program) 0))
    (error "PROGRAM must be a nonempty string"))
  (unless (and (or (vectorp args) (proper-list-p args)) (cl-every #'stringp args))
    (error "ARGS must be a proper list or vector of strings"))
  (unless (stringp directory) (error "DIRECTORY must be a string"))
  (let* ((dir (file-name-as-directory (expand-file-name (substring-no-properties directory))))
         (program (substring-no-properties program))
         (remote (file-remote-p program))
         (argv (mapcar #'substring-no-properties args)))
    (when (and remote (not (equal remote (file-remote-p dir))))
      (error "Remote PROGRAM must use DIRECTORY's host"))
    (let ((command (cons (if (file-name-directory program)
                             (file-local-name (expand-file-name program dir))
                           program)
                         argv)))
      (with-temp-buffer
        (let* ((default-directory dir)
               (status (apply #'process-file (car command) nil '(t t) nil argv)))
          (list :output (buffer-substring-no-properties (point-min) (point-max))
                :directory dir :command command :exit status))))))

(cl-defun emacs-agent-read-lines (buffer start end &key widen (limit 4096) from tick)
  "Read inclusive absolute START..END lines of live BUFFER.
Preserve empty lines, including the terminal empty line after a newline.
Return one literal :text substring, with metadata once per range, no per-line
rows or numbering.  Internal newlines are preserved; the newline after END is
not included.  :start/:end are absolute positions, end exclusive;
:start-line/:end-line are the lines of those positions.  :total-lines is the
absolute whole-buffer line count even under narrowing; empty buffers have one
line and a terminal newline adds an empty line.  After a returned
newline, end may be at the beginning of the next line.  LIMIT bounds text
characters including newlines.  :next-position equals end when truncated:
resume with FROM and the same START/END, then concatenate :text without adding
separators.  Pass returned :tick as TICK to detect intervening edits.
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

(defun emacs-agent-helpers--replace-exact (start end old new)
  "Replace START..END from OLD to NEW despite hooks moving point.
Caller owns the atomic change group.  Check OLD after before-change hooks,
not just before invoking deletion.  Keep an anchor across deletion hooks.
Return actual inserted bounds as a (START . END) pair, tracked through hooks."
  (let* ((anchor (copy-marker start))
         end-marker
         (phase 'delete)
         (guard (lambda (beg finish)
                  (unless (and (= beg (marker-position anchor))
                               (if (eq phase 'delete)
                                   (and (= finish (+ beg (length old)))
                                        (equal old (buffer-substring-no-properties beg finish)))
                                 (= beg finish)))
                    (error "Change hook invalidated replacement; edit rolled back"))
                  ;; Before-change hooks may move point even without edits.
                  (goto-char anchor)))
         (before-change-functions (append before-change-functions (list guard))))
    (unwind-protect
        (progn
          (goto-char anchor)
          (delete-region start end)
          (setq phase 'insert
                end-marker (copy-marker anchor t))
          (goto-char anchor)
          (when (> (length new) 0)
            (insert (substring-no-properties new)))
          (cons (marker-position anchor) (marker-position end-marker)))
      (set-marker anchor nil)
      (when end-marker (set-marker end-marker nil)))))

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
  (unless (integerp start)
    (error "START must be an integer position; got %s" (emacs-agent-eval--brief start 80)))
  (unless (integerp end)
    (error "END must be an integer position; got %s" (emacs-agent-eval--brief end 80)))
  (unless (<= start end) (error "START %d exceeds END %d" start end))
  (unless (stringp old)
    (error "OLD must be a string; got %s" (emacs-agent-eval--brief old 80)))
  (unless (stringp new)
    (error "NEW must be a string; got %s" (emacs-agent-eval--brief new 80)))
  (unless (integerp tick)
    (error ":tick must be an explicit integer; got %s" (emacs-agent-eval--brief tick 80)))
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
        (let ((changed (not (equal old new))) (bounds (cons start end)) result)
          (unwind-protect
              (progn
                (when changed (undo-boundary))
                (atomic-change-group
                  (let ((handle (prepare-change-group)))
                    (when changed
                      (setq bounds (emacs-agent-helpers--replace-exact start end old new)))
                    (setq result
                          (list :buffer (buffer-name) :start (car bounds)
                                :end (cdr bounds)
                                :tick (buffer-chars-modified-tick)
                                :modified (buffer-modified-p) :changed changed))
                    (unless (emacs-agent-helpers--fit result)
                      (error "eval output limit too small for helper metadata"))
                    ;; Hooks may insert boundaries; keep this replacement one step.
                    (undo-amalgamate-change-group handle))))
            (when changed (undo-boundary)))
          result)))))

(cl-defun emacs-agent-replace-texts (buffer replacements &key tick widen)
  "Apply REPLACEMENTS to live BUFFER as one atomic undo step.
REPLACEMENTS is a nonempty list of (:old STRING :new STRING) plists.  Each
nonempty OLD must occur exactly once in the original accessible text, with
literal case-sensitive matching, including overlapping occurrences.  All
ranges are found before editing; overlaps/duplicates between ranges are
errors, adjacent ranges are allowed.  NEW may be empty to delete.  For an
insertion, include a unique OLD anchor in NEW.  OLD=NEW is a no-op.

TICK is a required integer expected modification tick from a fresh read.
Check it once for the whole batch, not after each edit.  Apply bottom-up,
independent of input order; do not match text introduced by another NEW.
WIDEN explicitly permits access outside narrowing, which is restored.
Read-only, disabled undo and external file conflicts are not overridden.

Return a compact plist with :buffer, final :tick, :modified and :changed
(the number of non-no-op replacements).  No automatic save or full diff.
Use `save-buffer' explicitly when intended.  All changes, including normal
change hooks in this buffer, roll back on error or a result-budget failure;
external hook side effects cannot be rolled back.  Recheck OLD before each
replacement in case a hook invalidates planned coordinates.  Point/mark and
restrictions track edits as markers; windows are not selected.  All-no-op
batches preserve tick, modified state and undo.  Use as the sole final form
without stdout to preserve metadata within the evaluator output budget."
  (unless (and replacements (proper-list-p replacements) (integerp tick))
    (error "Expected nonempty replacements list and explicit integer :tick"))
  (dolist (edit replacements)
    (unless (and (proper-list-p edit) (= (length edit) 4)
                 (cl-loop for key in edit by #'cddr always (memq key '(:old :new)))
                 (stringp (plist-get edit :old)) (> (length (plist-get edit :old)) 0)
                 (stringp (plist-get edit :new)))
      (error "Each replacement must contain nonempty :old and string :new")))
  (with-current-buffer (emacs-agent-helpers--buffer buffer)
    (emacs-agent-helpers--tick tick)
    (when buffer-read-only (error "Buffer is read-only"))
    (when (eq buffer-undo-list t) (error "Undo is disabled in buffer"))
    (when (and buffer-file-name (not (verify-visited-file-modtime)))
      (error "Visited file changed on disk; resolve conflict before editing"))
    (save-mark-and-excursion
      (save-restriction
        (save-match-data
          (when widen (widen))
          (let ((case-fold-search nil) planned previous-end (changed 0) result)
            (cl-loop for edit in replacements for index from 1 do
                     (goto-char (point-min))
                     (let ((old (plist-get edit :old)) (new (plist-get edit :new)))
                       (unless (search-forward old nil t)
                         (error "Replacement %d OLD not found; reread before retrying" index))
                       (let ((start (match-beginning 0)) (end (match-end 0)))
                         ;; Restart one character after the first match START,
                         ;; not END: \"aa\" is ambiguous in \"aaa\".
                         (goto-char (1+ start))
                         (when (search-forward old nil t)
                           (error "Replacement %d OLD is not unique; use more context" index))
                         (push (list start end old new) planned))))
            (setq planned (sort planned (lambda (a b) (< (car a) (car b)))))
            (dolist (edit planned)
              (when (and previous-end (< (car edit) previous-end))
                (error "Replacement ranges overlap or are duplicated"))
              (setq previous-end (cadr edit))
              (unless (equal (nth 2 edit) (nth 3 edit)) (cl-incf changed)))
            (unwind-protect
                (progn
                  (when (> changed 0) (undo-boundary))
                  (atomic-change-group
                    (let ((handle (prepare-change-group)))
                      (dolist (edit (reverse planned))
                        (pcase-let ((`(,start ,end ,old ,new) edit))
                          (unless (and (<= (point-min) start end (point-max))
                                       (equal old (buffer-substring-no-properties start end)))
                            (error "Planned OLD changed during batch; entire batch rolled back"))
                          (unless (equal old new)
                            (emacs-agent-helpers--replace-exact start end old new))))
                      (setq result (list :buffer (buffer-name) :tick (buffer-chars-modified-tick)
                                         :modified (buffer-modified-p) :changed changed))
                      (unless (emacs-agent-helpers--fit result)
                        (error "eval output limit too small for helper metadata"))
                      (undo-amalgamate-change-group handle))))
              (when (> changed 0) (undo-boundary)))
            result))))))

(provide 'emacs-agent-helpers)
;;; emacs-agent-helpers.el ends here
