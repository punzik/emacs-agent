;;; emacs-agent-spike.el --- Stage zero gptel experiment -*- lexical-binding: t; -*-

;;; Commentary:
;; Load with the repository on load-path.  This is NOT the finished agent UI.
;; Uses the current gptel backend/model, never asks for tool approval.

;;; Code:
(require 'gptel)
(require 'emacs-agent-eval)

(cl-defstruct emacs-agent-spike
  source transport log request (status 'requesting)
  (calls (make-hash-table :test #'equal)) events)

(defun emacs-agent-spike--event (run kind payload)
  "Record KIND and PAYLOAD for RUN separately from its rendered log."
  (push (list kind payload) (emacs-agent-spike-events run))
  (with-current-buffer (emacs-agent-spike-log run)
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (point-max))
        (insert (format "%s: %s\n\n" kind payload))))))

(defun emacs-agent-spike--ids (info)
  "Read tool IDs from INFO, isolating an undocumented gptel dependency.
The tested commit exposes :tool-use as ordered call plists."
  (mapcar (lambda (call) (plist-get call :id)) (plist-get info :tool-use)))

(defun emacs-agent-spike--callback (run response info)
  "Handle RESPONSE and INFO for RUN; ignore callbacks after cancellation."
  (unless (memq (emacs-agent-spike-status run) '(cancelled failed completed))
    (condition-case err
        (pcase response
          ('abort
           (setf (emacs-agent-spike-status run) 'cancelled)
           (emacs-agent-spike--event run 'cancelled "Request aborted"))
          ('nil
           (setf (emacs-agent-spike-status run) 'failed)
           (emacs-agent-spike--event run 'error (plist-get info :status)))
          (`(tool-call . ,calls)
           (let ((ids (emacs-agent-spike--ids info)))
             (unless (and (= (length ids) (length calls))
                          (cl-every #'identity ids))
               (error "Unsupported gptel tool ID format"))
             ;; The pinned gptel dispatch pushes pending entries in reverse
             ;; order; restore provider order before executing side effects.
             (cl-loop for (tool args continuation) in (reverse calls)
                      for id in ids
                      unless (or (eq (emacs-agent-spike-status run) 'cancelled)
                                 (gethash id (emacs-agent-spike-calls run)))
                      do
                      ;; Record before executing, including before any reentry.
                      (puthash id t (emacs-agent-spike-calls run))
                      (unless (equal (gptel-tool-name tool) "eval_elisp")
                        (error "Unexpected tool"))
                      (emacs-agent-spike--event run 'tool-call args)
                      (let* ((source (emacs-agent-spike-source run))
                             (buffer (if (buffer-live-p source) source
                                       (emacs-agent-spike-transport run)))
                             (result (with-current-buffer buffer
                                       (emacs-agent-eval (plist-get args :expression)))))
                        (emacs-agent-spike--event run 'tool-result result)
                        ;; Arbitrary Lisp could have cancelled this very run.
                        (unless (eq (emacs-agent-spike-status run) 'cancelled)
                          (funcall continuation result))))))
          (`(tool-result . ,_) nil) ; Already logged before continuing.
          (`(reasoning . ,text)
           (when (stringp text) (emacs-agent-spike--event run 'reasoning text)))
          ((pred stringp)
           (emacs-agent-spike--event run 'assistant response)
           ;; Non-streaming can emit text followed by tools in the same response.
           (unless (plist-get info :tool-use)
             (setf (emacs-agent-spike-status run) 'completed))))
      (error
       (setf (emacs-agent-spike-status run) 'failed)
       (emacs-agent-spike--event run 'error (error-message-string err))
       (gptel-abort (emacs-agent-spike-transport run))))))

;;;###autoload
(defun emacs-agent-spike-start (text)
  "Send TEXT through gptel and return the experimental run.
Tools execute in the calling buffer, or the transport buffer if it dies.
Run `emacs-agent-spike-cancel' with the returned object to cancel.
There are no sessions, persistence, metadata filtering or streaming yet."
  (interactive "sSpike prompt: ")
  (let* ((source (current-buffer))
         (backend gptel-backend)
         (model gptel-model)
         (transport (generate-new-buffer " *emacs-agent-spike-transport*"))
         (log (generate-new-buffer "*emacs-agent-spike*"))
         (run (make-emacs-agent-spike :source source :transport transport :log log)))
    (with-current-buffer log (special-mode))
    (emacs-agent-spike--event run 'user text)
    (with-current-buffer transport
      (setq-local default-directory (buffer-local-value 'default-directory source))
      (setq-local gptel-backend backend gptel-model model
                  gptel-use-tools t gptel-use-context nil
                  ;; Route tools to our callback, NOT a confirmation UI.
                  gptel-confirm-tool-calls t)
      (setq-local gptel-tools
                  (list (gptel-make-tool
                         :name "eval_elisp" :category "emacs-agent-spike"
                         :function #'emacs-agent-eval :confirm t
                         :description "Execute arbitrary Lisp in the live Emacs."
                         :args '((:name "expression" :type string
                                  :description "One or more Lisp forms.")))))
      (condition-case err
          (setf (emacs-agent-spike-request run)
                (gptel-request text :buffer transport :stream nil
                  :system "You run inside a shared live Emacs with unrestricted eval_elisp. Read needed buffers explicitly; they may be narrowed. Tools default to the initiating buffer (transport buffer if it was killed), not the selected window. Use with-current-buffer explicitly as needed. Never invent tool results."
                  :callback (apply-partially #'emacs-agent-spike--callback run)))
        (error
         (setf (emacs-agent-spike-status run) 'failed)
         (emacs-agent-spike--event run 'error (error-message-string err)))))
    (when (called-interactively-p 'interactive) (display-buffer log))
    run))

(defun emacs-agent-spike-cancel (run)
  "Cancel RUN without undoing Lisp effects or stopping subprocesses."
  (setf (emacs-agent-spike-status run) 'cancelled)
  (emacs-agent-spike--event run 'cancelled "Cancelled; existing effects remain")
  (gptel-abort (emacs-agent-spike-transport run)))

(provide 'emacs-agent-spike)
;;; emacs-agent-spike.el ends here
