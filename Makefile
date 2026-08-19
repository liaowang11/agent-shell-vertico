EMACS ?= emacs

.PHONY: compile test check

compile:
	$(EMACS) -Q --batch -L . -L tests/support \
		-f batch-byte-compile agent-shell-vertico.el \
		agent-shell-vertico-sidebar.el \
		agent-shell-vertico-transcript.el \
		agent-shell-vertico-resume.el \
		agent-shell-vertico-prompt-queue.el \
		agent-shell-vertico-consult.el \
		agent-shell-vertico-links.el

test:
	$(EMACS) -Q --batch -L . -L tests/support -L tests \
		-l tests/agent-shell-vertico-tests.el \
		-f ert-run-tests-batch-and-exit

check: compile test
