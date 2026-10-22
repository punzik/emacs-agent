;;; emacs-agent-jobs.el --- Local asynchronous process helpers -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

;;; Commentary:
;; Ordinary helpers through eval_elisp, not additional tools.  Runtime-only
;; jobs share the live Emacs; no automatic polling, save, retry or resume.
;; Output is retained in memory until explicit forget, not bounded by reads.

;;; Code:
(require 'cl-lib)
(require 'emacs-agent-helpers)

(cl-defstruct emacs-agent-job
  id number process buffer state command directory created-at finished-at
  cancel-requested exit signal)

(defvar emacs-agent-job--registry (make-hash-table :test #'equal)
  "Runtime job ID to job object.  Never serialized with conversations.")
(defvar emacs-agent-job--counter 0)
(defvar emacs-agent-job--instance
  (substring (secure-hash 'sha256 (format "%s:%s:%s" (emacs-pid) (float-time) (random))) 0 16)
  "Runtime namespace so archived job IDs do not address jobs after restart.")

(defun emacs-agent-job--get (id)
  "Resolve an existing job by string ID, without creating one."
  (or (and (stringp id) (gethash id emacs-agent-job--registry))
      (error "Unknown job ID: %S" id)))

(defun emacs-agent-job--filter (job _process text)
  "Append decoded TEXT to JOB's private buffer, if it is still available."
  (when (buffer-live-p (emacs-agent-job-buffer job))
    (with-current-buffer (emacs-agent-job-buffer job)
      (let ((inhibit-read-only t))
        (save-restriction
          (widen)
          (save-excursion
            (goto-char (point-max))
            (insert text)))))))

(defun emacs-agent-job--sentinel (job process _event)
  "Record JOB's terminal state from PROCESS once, without adding output."
  (let ((status (process-status process)))
    (when (and (eq (emacs-agent-job-state job) 'running)
               (memq status '(exit signal failed closed)))
      (setf (emacs-agent-job-state job)
            (pcase status ('exit 'exited) ('signal 'signaled) (_ 'failed))
            (emacs-agent-job-exit job) (when (eq status 'exit) (process-exit-status process))
            (emacs-agent-job-signal job) (when (eq status 'signal) (process-exit-status process))
            (emacs-agent-job-finished-at job) (float-time)))))

(defun emacs-agent-job--status (job)
  "Copy JOB's descriptive metadata, without exposing runtime handles."
  (let ((buffer (emacs-agent-job-buffer job)))
    (list :id (copy-sequence (emacs-agent-job-id job))
          :state (emacs-agent-job-state job)
          :command (mapcar #'copy-sequence (emacs-agent-job-command job))
          :directory (copy-sequence (emacs-agent-job-directory job))
          :created-at (emacs-agent-job-created-at job)
          :finished-at (emacs-agent-job-finished-at job)
          :cancel-requested (emacs-agent-job-cancel-requested job)
          :exit (emacs-agent-job-exit job)
          :signal (emacs-agent-job-signal job)
          :output-size (when (buffer-live-p buffer) (with-current-buffer buffer (buffer-size)))
          :output-available (buffer-live-p buffer))))

(cl-defun emacs-agent-job-start (program args &key (directory default-directory))
  "Start local PROGRAM asynchronously with literal string ARGS in DIRECTORY.
Return a runtime job ID for `emacs-agent-job-status', `emacs-agent-job-read',
`emacs-agent-job-cancel' and `emacs-agent-job-forget'.  ARGS is a proper list
or vector.  Bare names use PATH; executable paths are relative to DIRECTORY.
Remote program/cwd is rejected before launch.  No shell is implied.

Combined stdout/stderr is decoded as UTF-8 into a private buffer without
undo, retained until forget/restart.  Memory is NOT bounded by read limits.
No save, retry, model continuation or conversation persistence occurs.
Cancellation of an agent run does not implicitly cancel its jobs.  Process
side effects are not rolled back.  Launch errors/quit propagate."
  (unless (and (stringp program) (> (length program) 0))
    (error "PROGRAM must be a nonempty string"))
  (unless (and (or (vectorp args) (proper-list-p args)) (cl-every #'stringp args))
    (error "ARGS must be a proper list or vector of strings"))
  (unless (stringp directory) (error "DIRECTORY must be a string"))
  (let* ((program (substring-no-properties program))
         (dir (file-name-as-directory (expand-file-name (substring-no-properties directory))))
         (argv (mapcar #'substring-no-properties args)))
    (when (or (file-remote-p program) (file-remote-p dir))
      (error "Async jobs support only local PROGRAM and DIRECTORY"))
    (unless (file-directory-p dir) (error "DIRECTORY does not exist: %s" dir))
    (let* ((command (cons (if (file-name-directory program)
                              (expand-file-name program dir) program) argv))
           (number (cl-incf emacs-agent-job--counter))
           (id (format "job-%s-%d" emacs-agent-job--instance number))
           (buffer (generate-new-buffer " *emacs-agent-job-output*"))
           (job (make-emacs-agent-job :id id :number number :buffer buffer
                                     :state 'running :command command :directory dir
                                     :created-at (float-time)))
           process published)
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (buffer-disable-undo)
              (setq buffer-read-only t))
            (let ((default-directory dir))
              (setq process
                    (make-process :name id :buffer buffer :command command
                                  :connection-type 'pipe :coding 'utf-8-unix
                                  :noquery t :stderr nil
                                  :filter (lambda (proc text)
                                            (emacs-agent-job--filter job proc text))
                                  :sentinel (lambda (proc event)
                                              (emacs-agent-job--sentinel job proc event)))))
            (setf (emacs-agent-job-process job) process)
            (puthash id job emacs-agent-job--registry)
            (setq published t)
            (copy-sequence id))
        (unless published
          (setq process (or process (get-buffer-process buffer)))
          (when (process-live-p process) (delete-process process))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(defun emacs-agent-job-status (id)
  "Return a copy of ID's metadata without waiting or reading process output.
:state is running until the terminal sentinel, then exited/signaled/failed.
Only ordinary exit sets integer :exit; a signal sets :signal instead.
:cancel-requested does not certify that all descendants stopped."
  (emacs-agent-job--status (emacs-agent-job--get id)))

(cl-defun emacs-agent-job-read (id &key (from 0) (limit 4096))
  "Read ID's currently available output, starting at zero-based FROM.
LIMIT is a positive character count, reduced to fit the printed eval budget
when this is the sole final value without stdout.  Offsets count decoded
characters, not bytes.  Resume with :next-offset, concatenating :text without
separators.  :truncated nil only means the end of currently available output;
:complete requires a terminal job and reaching that end.  Does not wait,
consume output or pump process events.  Missing output and invalid offsets
signal errors rather than silently returning an empty result."
  (unless (and (natnump from) (integerp limit) (> limit 0))
    (error "FROM must be nonnegative and LIMIT positive integers"))
  (let* ((job (emacs-agent-job--get id))
         (buffer (emacs-agent-job-buffer job)))
    (unless (buffer-live-p buffer) (error "Job output is unavailable: %s" id))
    (with-current-buffer buffer
      (save-restriction
        (widen)
        (let* ((size (buffer-size))
               (metadata (emacs-agent-job--status job))
               (count (min limit (- size from)))
               result fitted)
          (unless (<= from size) (error "FROM exceeds available output: %s" size))
          (while (not fitted)
            (let ((end (+ from count)))
              (setq result
                    (append metadata
                            (list :from from :next-offset end
                                  :truncated (< end size)
                                  :complete (and (not (eq (emacs-agent-job-state job) 'running))
                                                 (= end size))
                                  :text (buffer-substring-no-properties (1+ from) (1+ end)))))
              (if (emacs-agent-helpers--fit result) (setq fitted t)
                (if (<= count 1) (error "eval output limit too small for job metadata")
                  (setq count (max 1 (/ count 2)))))))
          result)))))

(defun emacs-agent-job-cancel (id)
  "Request cancellation of ID's owned process and return its status.
Idempotent for completed jobs.  Uses the stored process object, never a PID
or name lookup.  Does not guarantee stopping descendants, retaining all
pending output or undoing effects.  The actual terminal status is retained."
  (let* ((job (emacs-agent-job--get id))
         (process (emacs-agent-job-process job)))
    (when (and (eq (emacs-agent-job-state job) 'running) (process-live-p process))
      (setf (emacs-agent-job-cancel-requested job) t)
      (delete-process process))
    (emacs-agent-job--status job)))

(cl-defun emacs-agent-job-list (&key (from 0) (limit 20))
  "Return a bounded metadata page of runtime jobs, newest first.
FROM is a zero-based index; LIMIT is a positive number of jobs.  :jobs,
:total, :next-offset and :truncated describe the current list, not a stable
snapshot across new admissions/forget.  No output text is included."
  (unless (and (natnump from) (integerp limit) (> limit 0))
    (error "FROM must be nonnegative and LIMIT positive integers"))
  (let (jobs)
    (maphash (lambda (_ job) (push job jobs)) emacs-agent-job--registry)
    (setq jobs (sort jobs (lambda (a b) (> (emacs-agent-job-number a)
                                          (emacs-agent-job-number b)))))
    (let* ((total (length jobs))
           (count (min limit (- total from))) result fitted)
      (unless (<= from total) (error "FROM exceeds job count: %s" total))
      (setq jobs (mapcar #'emacs-agent-job--status (cl-subseq jobs from (+ from count))))
      (while (not fitted)
        (setq result (list :jobs (cl-subseq jobs 0 count) :total total
                           :next-offset (+ from count) :truncated (< (+ from count) total)))
        (if (emacs-agent-helpers--fit result) (setq fitted t)
          (if (<= count 1) (error "eval output limit too small for job metadata")
            (setq count (max 1 (/ count 2))))))
      result)))

(defun emacs-agent-job-forget (id)
  "Forget terminal job ID and its private output buffer; return t.
Reject active jobs; does not cancel processes or delete generated files."
  (let ((job (emacs-agent-job--get id)))
    (when (eq (emacs-agent-job-state job) 'running)
      (error "Cancel or finish job before forgetting it: %s" id))
    (when (buffer-live-p (emacs-agent-job-buffer job))
      (kill-buffer (emacs-agent-job-buffer job)))
    (remhash id emacs-agent-job--registry)
    t))

(provide 'emacs-agent-jobs)
;;; emacs-agent-jobs.el ends here
