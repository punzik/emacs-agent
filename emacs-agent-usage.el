;;; emacs-agent-usage.el --- Per-HTTP usage accounting -*- lexical-binding: t; -*-

;;; Commentary:
;; Counts are gptel-normalized observations, not provider billing or context
;; size.  Unknown is never zero.  A cumulative snapshot is evidence, not an
;; additional contribution to totals.  Records live outside model history.

;;; Code:
(require 'emacs-agent-session)

(defun emacs-agent-usage--tokens (tokens)
  "Copy known counters from gptel TOKENS, leaving missing/invalid ones unknown."
  (cl-loop for key in '(:input :output :cached)
           for value = (and (proper-list-p tokens) (plist-get tokens key))
           append (list key (if (natnump value) value 'unknown))))

(defun emacs-agent-usage--sum (values)
  "Sum VALUES only if all are known and at least one exists."
  (if (and values (cl-every #'natnump values)) (apply #'+ values) 'unknown))

(defun emacs-agent-usage--derived (tokens)
  "Derive prompt and total tokens from normalized TOKENS without double cache."
  (let ((input (emacs-agent-usage--sum
                (list (plist-get tokens :input) (plist-get tokens :cached)))))
    (list :input-total input
          :total (emacs-agent-usage--sum (list input (plist-get tokens :output))))))

(defun emacs-agent-usage-summary (run)
  "Return strict per-field totals for RUN, including unknown pending requests.
:input excludes :cached in the supported Chat Completions adapter.  Summed
input is expenditure over requests, not a measurement of context size."
  (let* ((requests (emacs-agent-run-usage-requests run))
         (tokens (cl-loop for key in '(:input :output :cached)
                          append (list key (emacs-agent-usage--sum
                                            (mapcar (lambda (r)
                                                      (plist-get (plist-get r :tokens) key))
                                                    requests))))))
    (append (list :source 'gptel-normalized :requests (length requests)
                  :reported (cl-count-if (lambda (r) (plist-get r :available)) requests)
                  :tokens tokens)
            (emacs-agent-usage--derived tokens))))

(defun emacs-agent-usage-begin (run)
  "Open one HTTP request for RUN, called before the private WAIT handler."
  ;; Unexpected replacement of an unfinished request must not lose its cost.
  (emacs-agent-usage-end run 'interrupted)
  (let ((record (list :request (1+ (length (emacs-agent-run-usage-requests run)))
                      :status 'pending :source 'gptel-normalized :available nil
                      :tokens nil)))
    (setf (emacs-agent-run-usage-requests run)
          (nconc (emacs-agent-run-usage-requests run) (list record))
          (emacs-agent-run-usage-current run) record)))

(defun emacs-agent-usage-observe (run info)
  "Observe current INFO for RUN without recording stream deltas or adding sums.
Missing :tokens must not reuse the preceding request's :tokens-full.  gptel
normalizes some missing provider fields to zero; this provenance is retained."
  (when-let* ((record (emacs-agent-run-usage-current run))
              (tokens (plist-get info :tokens)))
    (plist-put record :available t)
    (plist-put record :tokens (emacs-agent-usage--tokens tokens))
    (plist-put record :gptel-cumulative
               (when (plist-get info :tokens-full)
                 (emacs-agent-usage--tokens (plist-get info :tokens-full))))))

(defun emacs-agent-usage-end (run status &optional info)
  "Close RUN's current HTTP request once, with STATUS and latest INFO.
Observe before tool dispatch/terminal callbacks can recurse into another WAIT."
  (emacs-agent-usage-observe run info)
  (when-let* ((record (emacs-agent-run-usage-current run)))
    (setf (emacs-agent-run-usage-current run) nil)
    (plist-put record :status status)
    (unless (plist-get record :tokens)
      (plist-put record :tokens (emacs-agent-usage--tokens nil)))
    (cl-loop for (key value) on (emacs-agent-usage--derived (plist-get record :tokens))
             by #'cddr do (plist-put record key value))
    (emacs-agent-session-record run 'usage (copy-tree record))))

(defun emacs-agent-usage-format (summary)
  "Format request or run usage SUMMARY with explicitly named normalized counts."
  (let ((tokens (plist-get summary :tokens)))
    (format "%s: input-uncached=%s cache-read=%s output=%s input-total=%s total=%s [gptel-normalized]"
            (if (plist-member summary :request)
                (format "HTTP #%s (%s)" (plist-get summary :request) (plist-get summary :status))
              (format "Run: %s requests, %s with usage"
                      (plist-get summary :requests) (plist-get summary :reported)))
            (or (plist-get tokens :input) 'unknown)
            (or (plist-get tokens :cached) 'unknown)
            (or (plist-get tokens :output) 'unknown)
            (or (plist-get summary :input-total) 'unknown)
            (or (plist-get summary :total) 'unknown))))

(provide 'emacs-agent-usage)
;;; emacs-agent-usage.el ends here
