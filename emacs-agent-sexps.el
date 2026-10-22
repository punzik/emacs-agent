;;; emacs-agent-sexps.el --- Inspect and safely edit Emacs Lisp forms -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

;;; Commentary:
;; Ordinary helpers for eval_elisp.  Read source copies, never evaluate forms.
;; All ranges are absolute character positions, with exclusive ends.

;;; Code:
(require 'emacs-agent-helpers)
(require 'lisp-mode)
(require 'json)

(defun emacs-agent-sexps--snapshot (buffer start end tick widen)
  "Copy explicit BUFFER's START..END, checking TICK and respecting WIDEN."
  (with-current-buffer (emacs-agent-helpers--buffer buffer)
    (emacs-agent-helpers--tick tick)
    (save-restriction
      (when widen (widen))
      (setq start (or start (point-min)) end (or end (point-max)))
      (unless (and (integerp start) (integerp end)
                   (<= (point-min) start end (point-max)))
        (error "Sexp range outside accessible buffer"))
      (list :buffer (buffer-name) :tick (buffer-chars-modified-tick)
            :start start :end end
            :text (buffer-substring-no-properties start end)))))

(defmacro emacs-agent-sexps--with-source (snapshot &rest body)
  "Run BODY in a private Elisp source buffer from SNAPSHOT."
  (declare (indent 1) (debug t))
  `(save-match-data
     (with-temp-buffer
       (set-syntax-table emacs-lisp-mode-syntax-table)
       (setq-local syntax-propertize-function #'elisp-mode-syntax-propertize)
       (setq-local kill-buffer-hook nil)
       (let ((inhibit-modification-hooks t))
         (insert (plist-get ,snapshot :text))
         (syntax-propertize (point-max)))
       (goto-char (point-min))
       ,@body)))

(defun emacs-agent-sexps--read ()
  "Read one source form with isolated symbols, without evaluation.
Keep this binding around the built-in reader ONLY: library autoloads need
normal symbol identity, including byte-code and CL function definitions."
  ;; Native #s(hash-table ...) can invoke user-defined hash tests when the
  ;; symbols come from the global obarray.  Generic records avoid callbacks.
  (let ((obarray (make-vector 151 0)) (read-symbol-shorthands nil))
    (read (current-buffer))))

(defun emacs-agent-sexps--skip ()
  "Skip Emacs Lisp whitespace and comments in the private source buffer."
  (forward-comment (point-max)))

(defun emacs-agent-sexps--forms ()
  "Read source forms without evaluation, retaining ranges and first error.
Ranges and diagnostics use private-buffer positions until translated."
  (let (forms failure done)
    (while (not done)
      (emacs-agent-sexps--skip)
      (if (eobp) (setq done t)
        (let ((start (point)))
          (condition-case err
              (progn
                (emacs-agent-sexps--read)
                (push (cons start (point)) forms))
            (error
             (let* ((stopped (point))
                    (incomplete (eq (car err) 'end-of-file))
                    (state (and incomplete
                                (save-excursion
                                  (parse-partial-sexp start (point-max)))))
                    (hint (and state (if (nth 3 state) (nth 8 state) (nth 1 state)))))
               (setq failure
                     (list :kind (if incomplete "incomplete-form" "reader-error")
                           :message (error-message-string err)
                           :form-start start :reader-position stopped
                           :position (if incomplete (or hint start)
                                       (max start (1- stopped)))
                           :hint (and hint (if (nth 3 state) "open-string" "open-list")))
                     done t)))))))
    (list :forms (nreverse forms) :diagnostic failure)))

(defun emacs-agent-sexps--diagnostic (snapshot diagnostic)
  "Translate private DIAGNOSTIC into live coordinates from SNAPSHOT."
  (when diagnostic
    (let* ((base (1- (plist-get snapshot :start)))
           (position (+ base (plist-get diagnostic :position)))
           (start (+ base (plist-get diagnostic :form-start)))
           (stopped (+ base (plist-get diagnostic :reader-position)))
           (low (max (plist-get snapshot :start) (- position 30)))
           (high (min (plist-get snapshot :end) (+ position 90))))
      (with-current-buffer (emacs-agent-helpers--buffer (plist-get snapshot :buffer))
        (append (list :kind (plist-get diagnostic :kind)
                      :message (plist-get diagnostic :message)
                      :position position :form-start start :reader-position stopped
                      :hint (plist-get diagnostic :hint))
                (emacs-agent-helpers--coordinates position)
                (list :context-start low :context-end high
                      :context (substring (plist-get snapshot :text)
                                          (- low (plist-get snapshot :start))
                                          (- high (plist-get snapshot :start)))))))))

(defun emacs-agent-sexps--metadata (snapshot)
  "Return public identity and scope from SNAPSHOT, without source text."
  (list :buffer (plist-get snapshot :buffer) :tick (plist-get snapshot :tick)
        :start (plist-get snapshot :start) :end (plist-get snapshot :end)))

(cl-defun emacs-agent-check-sexps (buffer &key start end tick widen)
  "Check BUFFER's START..END as standalone Emacs Lisp, without evaluation.
Default scope is the accessible buffer; WIDEN explicitly permits outside
narrowing.  TICK, when supplied, must be fresh.  Preserve live editor state.
Return a plist with :ok, :forms-read, :diagnostic, :buffer, :tick, :start,
:end.  Only the first reader failure is reported; preceding complete forms
are counted.  Diagnostic :position, :form-start and :reader-position are
absolute; :line is 1-based and :column a 0-based display column.  :context
is bounded literal text.  At EOF, :position/:hint are syntax-table hints,
not proof of the intended correction; reader position/start are separate.
Reading uses an isolated symbol table: no global symbol interning or custom
hash-test callbacks.  #s records are read generically, without native
constructor-specific checks.  This checks reader structure, not program
semantics or compilation.  A scoped success does not validate the rest of
the file.  No save or live text edits."
  (let* ((snapshot (emacs-agent-sexps--snapshot buffer start end tick widen))
         (parsed (emacs-agent-sexps--with-source snapshot
                   (emacs-agent-sexps--forms)))
         (diagnostic (emacs-agent-sexps--diagnostic snapshot (plist-get parsed :diagnostic)))
         (result (append (emacs-agent-sexps--metadata snapshot)
                         (list :ok (not diagnostic)
                               :forms-read (length (plist-get parsed :forms))
                               :diagnostic diagnostic))))
    (unless (emacs-agent-helpers--fit result)
      (error "eval output limit too small for sexp diagnostics"))
    result))

(defun emacs-agent-sexps--kind (start end)
  "Classify source at START..END without serializing reader objects."
  (let ((char (char-after start)))
    (cond ((eq char ?\() "list")
          ((eq char ?\[) "vector")
          ((eq char ?\") "string")
          ((eq char ??) "character")
          ((or (memq char '(?\' ?\` ?,))
               (and (eq char ?#) (eq (char-after (1+ start)) ?\'))) "prefix")
          ((and (eq char ?.) (= end (1+ start))) "dot")
          ((eq char ?#) "reader-form")
          (t "atom"))))

(defun emacs-agent-sexps--dot-p (end)
  "Whether point is a dotted-pair separator before END."
  (and (eq (char-after) ?.)
       (or (= (1+ (point)) end)
           (memq (char-after (1+ (point)))
                 '(?\s ?\t ?\n ?\r ?\f ?\( ?\[ ?\) ?\] ?\" ?\' ?\` ?, ?\;)))))

(defun emacs-agent-sexps--contextual-end ()
  "Advance one part of already validated source containing reader labels.
Independent `read' calls lose #N=/#N# scope.  Split those constructs and
prefixes by their source spelling, using the reader for atoms/strings/chars.
This is only a boundary fallback, never a replacement for reader validation."
  (emacs-agent-sexps--skip)
  (cond
   ((looking-at "#[0-9]+#") (goto-char (match-end 0)))
   ((or (looking-at "#[0-9]+=") (looking-at "#'\\|,@\\|['`,]"))
    (goto-char (match-end 0))
    (emacs-agent-sexps--contextual-end))
   ((looking-at "#\\(?:s\\|\\^\\^?\\)?\\((\\|\\[\\)")
    ;; Keep dispatch forms opaque, but include their complete source body.
    (goto-char (match-beginning 1))
    (emacs-agent-sexps--contextual-end))
   ((memq (char-after) '(?\( ?\[))
    (let ((close (if (eq (char-after) ?\() ?\) ?\])))
      (forward-char)
      (emacs-agent-sexps--skip)
      (while (not (eq (char-after) close))
        (when (eobp) (error "Incomplete contextual reader form"))
        (emacs-agent-sexps--contextual-end)
        (emacs-agent-sexps--skip))
      (forward-char)))
   ((emacs-agent-sexps--dot-p (point-max)) (forward-char))
   (t (emacs-agent-sexps--read))))

(defun emacs-agent-sexps--parts (start end &optional valid)
  "Read parts in START..END, preserving one unreadable tail.
Return (START END COMPLETE) triples in private-buffer coordinates.
A dotted-pair separator is retained as a one-character part.
VALID permits contextual label boundaries only for previously read source."
  (save-excursion
    (save-restriction
      (narrow-to-region start end)
      (goto-char start)
      (let (parts done)
        (while (not done)
          (emacs-agent-sexps--skip)
          (if (eobp) (setq done t)
            (let ((begin (point)))
              (if (emacs-agent-sexps--dot-p end)
                  (progn (forward-char) (push (list begin (point) t) parts))
                (condition-case nil
                    (progn
                      (condition-case err
                          (emacs-agent-sexps--read)
                        (error
                         (if (not valid) (signal (car err) (cdr err))
                           (goto-char begin)
                           (emacs-agent-sexps--contextual-end))))
                      (push (list begin (point) t) parts))
                  (error (push (list begin end nil) parts) (setq done t)))))))
        (nreverse parts)))))

(defun emacs-agent-sexps--child-range (start end complete)
  "Return child content range for START..END when expandable.
COMPLETE says whether the enclosing source was read successfully."
  (let ((kind (emacs-agent-sexps--kind start end)))
    (cond ((member kind '("list" "vector"))
           (cons (1+ start) (if complete (1- end) end)))
          ((equal kind "prefix")
           (cons (+ start (if (or (eq (char-after start) ?#)
                                 (and (eq (char-after start) ?,)
                                      (eq (char-after (1+ start)) ?@))) 2 1))
                 end)))))

(cl-defun emacs-agent-inspect-sexps (buffer &key start end tick widen (depth 1) (limit 64))
  "Return JSON describing BUFFER's START..END as standalone Emacs Lisp.
Scope, coordinates, TICK and WIDEN follow `emacs-agent-check-sexps'.
DEPTH is child expansion depth, 0..8.  LIMIT is the maximum number of nodes
in the entire result, 1..1000.  Each node has absolute :start/:end, :kind,
:complete, a literal preview of up to 80 characters, and :expandable.
Lists, vectors and quote prefixes can have :children.  Dotted-pair dots
are parts, not independently replaceable sexps.  Other reader constructs
remain leaves.  Incomplete forms retain readable children where possible.
:truncated and per-node :children-truncated expose node-budget omissions;
:next-position resumes omitted top-level forms, not nested children.
To explore omitted children, request their parent's explicit range with a
fresh tick and larger limit or smaller depth.  Depth-limited nodes remain
:expandable.  :ok/:diagnostic describe reader syntax of the entire scope,
even when node output is limited.  No forms are evaluated or buffers saved.
The JSON string must fit the evaluator's output budget as a sole final value;
otherwise signal an error, never return truncated/invalid JSON."
  (unless (and (integerp depth) (<= 0 depth 8)
               (integerp limit) (<= 1 limit 1000))
    (error "Expected :depth 0..8 and :limit 1..1000"))
  (let* ((snapshot (emacs-agent-sexps--snapshot buffer start end tick widen))
         (base (1- (plist-get snapshot :start)))
         (remaining limit) truncated next nodes parsed)
    (emacs-agent-sexps--with-source snapshot
      (setq parsed (emacs-agent-sexps--forms))
      (cl-labels
          ((emit (part level)
             (pcase-let* ((`(,begin ,finish ,complete) part)
                          (range (emacs-agent-sexps--child-range begin finish complete))
                          (preview-end (min finish (+ begin 80)))
                          (node (list :start (+ base begin) :end (+ base finish)
                                      :kind (emacs-agent-sexps--kind begin finish)
                                      :complete (if complete t :false)
                                      :preview (buffer-substring-no-properties begin preview-end)
                                      :preview-truncated (if (< preview-end finish) t :false)
                                      :expandable (if range t :false))))
               (cl-decf remaining)
               (when (and range (> level 0))
                 (let (children omitted)
                   (dolist (child (emacs-agent-sexps--parts (car range) (cdr range) complete))
                     (if (> remaining 0)
                         (push (emit child (1- level)) children)
                       (setq omitted t truncated t)))
                   (setq node (append node (list :children (vconcat (nreverse children))
                                                 :children-truncated (if omitted t :false))))))
               node)))
        (let ((parts (mapcar (lambda (range) (list (car range) (cdr range) t))
                             (plist-get parsed :forms)))
              (failure (plist-get parsed :diagnostic)))
          (when failure
            (setq parts (append parts (list (list (plist-get failure :form-start)
                                                  (point-max) nil)))))
          (dolist (part parts)
            (if (> remaining 0) (push (emit part depth) nodes)
              (setq truncated t)
              (unless next (setq next (+ base (car part)))))))))
    (let* ((diagnostic (emacs-agent-sexps--diagnostic snapshot (plist-get parsed :diagnostic)))
           (result (append (emacs-agent-sexps--metadata snapshot)
                           (list :ok (if diagnostic :false t) :diagnostic diagnostic
                                 :depth depth :limit limit :truncated (if truncated t :false)
                                 :next-position next :nodes (vconcat (nreverse nodes)))))
           (json (json-serialize result :null-object nil :false-object :false)))
      (unless (emacs-agent-helpers--fit json)
        (error "eval output limit too small for sexp JSON; reduce :limit or :depth"))
      json)))

(defun emacs-agent-sexps--valid (snapshot)
  "Read SNAPSHOT, signaling a located error on invalid syntax."
  (let* ((parsed (emacs-agent-sexps--with-source snapshot (emacs-agent-sexps--forms)))
         (failure (plist-get parsed :diagnostic)))
    (when failure
      (error "Invalid Emacs Lisp: %s at position %d (form starts %d, reader stopped %d): %s"
             (plist-get failure :kind)
             (+ (1- (plist-get snapshot :start)) (plist-get failure :position))
             (+ (1- (plist-get snapshot :start)) (plist-get failure :form-start))
             (+ (1- (plist-get snapshot :start)) (plist-get failure :reader-position))
             (plist-get failure :message)))
    parsed))

(defun emacs-agent-sexps--whole-p (snapshot start end)
  "Whether START..END identifies a whole supported sexp in valid SNAPSHOT."
  (let ((base (1- (plist-get snapshot :start))))
    (setq start (- start base) end (- end base))
    (emacs-agent-sexps--with-source snapshot
      (cl-labels
          ((find-part (part)
             (pcase-let ((`(,begin ,finish ,complete) part))
               (and complete (<= begin start end finish)
                    (not (equal (emacs-agent-sexps--kind begin finish) "dot"))
                    (or (and (= begin start) (= finish end))
                        (let ((range (emacs-agent-sexps--child-range begin finish t)))
                          (and range
                               (cl-some #'find-part
                                        (emacs-agent-sexps--parts (car range) (cdr range) t)))))))))
        (cl-some #'find-part (emacs-agent-sexps--parts (point-min) (point-max) t))))))

(cl-defun emacs-agent-replace-sexp (buffer start end old new &key tick widen repair)
  "Replace one whole Emacs Lisp sexp START..END in BUFFER from OLD to NEW.
TICK is required and OLD must match exactly, as in
`emacs-agent-replace-region'.  NEW is exactly one reader form without outer
whitespace/comments; NEW=\"\" deletes.  Ordinary lists, vectors and reader
prefixes expose nested expressions; opaque reader constructs can only be
replaced whole.  Atoms cannot be replaced in part, nor can list delimiters.
The entire accessible buffer must initially have valid reader syntax.

With REPAIR non-nil, allow an arbitrary original range in broken source and
any NEW text (including multiple forms).  In BOTH modes the entire accessible
buffer must have valid reader syntax after replacement.  Narrowed text is
checked as a standalone fragment, not as proof of whole-file validity; WIDEN
explicitly checks/edits outside narrowing.  Invalid candidates are rejected
before editing.  Actual text is checked again after normal change hooks,
inside the rollback group.  Syntax validity does not imply correct semantics.

Preserve all existing region-edit guards, one-step undo, state tracking,
no-op behavior and no implicit save.  Result is the region-edit plist.
Failures roll back target-buffer text, not external hook side effects.
Use as the sole final form without stdout for the evaluator output budget."
  (unless (and (integerp start) (integerp end) (< start end)
               (stringp old) (stringp new) (integerp tick))
    (error "Expected nonempty integer range, string OLD/NEW and explicit integer :tick"))
  (let* ((snapshot (emacs-agent-sexps--snapshot buffer nil nil tick widen))
         (low (plist-get snapshot :start))
         (high (plist-get snapshot :end))
         (text (plist-get snapshot :text)))
    (unless (<= low start end high)
      (error "Replacement range outside accessible buffer"))
    (unless (equal old (substring text (- start low) (- end low)))
      (error "Replacement OLD text does not match; reread before retrying"))
    (unless repair
      (emacs-agent-sexps--valid snapshot)
      (unless (emacs-agent-sexps--whole-p snapshot start end)
        (error "Range is not one whole supported sexp; inspect ranges before retrying"))
      (unless (equal new "")
        (let* ((replacement (list :start 1 :text new))
               (forms (plist-get (emacs-agent-sexps--valid replacement) :forms)))
          (unless (and (= (length forms) 1) (= (caar forms) 1)
                       (= (cdar forms) (1+ (length new))))
            (error "NEW must be exactly one sexp without outer whitespace/comments")))))
    (let ((candidate (copy-sequence snapshot)))
      (setq candidate (plist-put candidate :text
                                (concat (substring text 0 (- start low)) new
                                        (substring text (- end low)))))
      (emacs-agent-sexps--valid candidate))
    (with-current-buffer (emacs-agent-helpers--buffer buffer)
      ;; atomic-change-group enables undo itself, so check before entering it.
      (emacs-agent-helpers--tick tick)
      (when buffer-read-only (error "Buffer is read-only"))
      (when (eq buffer-undo-list t) (error "Undo is disabled in buffer"))
      (when (and buffer-file-name (not (verify-visited-file-modtime)))
        (error "Visited file changed on disk; resolve conflict before editing"))
      (save-mark-and-excursion
        (save-restriction
          (when widen (widen))
          (let ((changed (not (equal old new))) result)
            (unwind-protect
                (progn
                  (when changed (undo-boundary))
                  (atomic-change-group
                    (let ((handle (prepare-change-group)))
                      (setq result (save-restriction
                                     (emacs-agent-replace-region
                                      buffer start end old new :tick tick)))
                      (emacs-agent-sexps--valid
                       (emacs-agent-sexps--snapshot buffer nil nil nil nil))
                      (when changed (undo-amalgamate-change-group handle)))))
              (when changed (undo-boundary)))
            result))))))

(provide 'emacs-agent-sexps)
;;; emacs-agent-sexps.el ends here
