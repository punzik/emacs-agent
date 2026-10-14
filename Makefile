EMACS ?= emacs
ELPA ?= $(HOME)/.emacs.d/elpa
BATCH = $(EMACS) -Q --batch --eval '(setq package-user-dir "$(ELPA)")' --eval '(require (quote package))' --eval '(package-initialize)' -L . -L examples

.PHONY: test compile clean

test:
	$(BATCH) -l test/emacs-agent-spike-test.el -l test/emacs-agent-gptel-contract-test.el -l test/emacs-agent-session-test.el -l test/emacs-agent-context-test.el -l test/emacs-agent-gptel-test.el -f ert-run-tests-batch-and-exit

compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile emacs-agent-eval.el emacs-agent-session.el emacs-agent-context.el emacs-agent.el emacs-agent-gptel.el examples/emacs-agent-spike.el

clean:
	rm -f emacs-agent*.elc examples/emacs-agent-spike.elc
