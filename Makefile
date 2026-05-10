EMACS ?= emacs

.PHONY: compile test check

compile:
	$(EMACS) -Q --batch -L . -L tests/support \
		-f batch-byte-compile agent-shell-vertico.el

test:
	$(EMACS) -Q --batch -L . -L tests/support -L tests \
		-l tests/agent-shell-vertico-tests.el \
		-f ert-run-tests-batch-and-exit

check: compile test
