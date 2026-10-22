EMACS ?= emacs
ELPA ?= $(HOME)/.emacs.d/elpa
BATCH = $(EMACS) -Q --batch --eval '(setq package-user-dir "$(ELPA)")' --eval '(require (quote package))' --eval '(package-initialize)' -L . -L examples

.PHONY: test compile clean

test:
	$(BATCH) -l test/emacs-agent-spike-test.el -l test/emacs-agent-eval-diagnostics-test.el -l test/emacs-agent-output-test.el -l test/emacs-agent-compaction-test.el -l test/emacs-agent-helpers-test.el -l test/emacs-agent-prompt-test.el -l test/emacs-agent-process-test.el -l test/emacs-agent-jobs-test.el -l test/emacs-agent-edit-test.el -l test/emacs-agent-batch-edit-test.el -l test/emacs-agent-gptel-contract-test.el -l test/emacs-agent-session-test.el -l test/emacs-agent-context-test.el -l test/emacs-agent-gptel-test.el -l test/emacs-agent-log-test.el -l test/emacs-agent-history-test.el -l test/emacs-agent-store-test.el -l test/emacs-agent-usage-test.el -l test/emacs-agent-resources-test.el -l test/emacs-agent-notify-test.el -l test/emacs-agent-steering-spike-test.el -l test/emacs-agent-input-test.el -l test/emacs-agent-input-store-test.el -l test/emacs-agent-input-ui-test.el -l test/emacs-agent-blocks-test.el -l test/emacs-agent-compact-test.el -l test/emacs-agent-conversation-test.el -l test/emacs-agent-fork-test.el -l test/emacs-agent-ui-test.el -l test/emacs-agent-status-test.el -l test/emacs-agent-texts-test.el -l test/emacs-agent-texts-history-test.el -l test/emacs-agent-info-test.el -f ert-run-tests-batch-and-exit

compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile emacs-agent-eval.el emacs-agent-helpers.el emacs-agent-jobs.el emacs-agent-resources.el emacs-agent-session.el emacs-agent-usage.el emacs-agent-context.el emacs-agent-compaction.el emacs-agent-input.el emacs-agent-log.el emacs-agent-status.el emacs-agent-store.el emacs-agent-compact.el emacs-agent.el emacs-agent-gptel.el examples/emacs-agent-spike.el

clean:
	rm -f emacs-agent*.elc examples/emacs-agent-spike.elc
