EMACS ?= emacs
ELPA ?= $(HOME)/.emacs.d/elpa
BATCH = $(EMACS) -Q --batch --eval '(setq package-user-dir "$(ELPA)")' --eval '(require (quote package))' --eval '(package-initialize)' -L . -L examples

.PHONY: test compile clean

test:
	$(BATCH) -l test/emacs-agent-spike-test.el -l test/emacs-agent-gptel-contract-test.el -f ert-run-tests-batch-and-exit

compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile emacs-agent-eval.el examples/emacs-agent-spike.el

clean:
	rm -f emacs-agent-eval.elc examples/emacs-agent-spike.elc
