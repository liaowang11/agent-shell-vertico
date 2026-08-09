# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An Emacs Lisp package that adds a Vertico/`completing-read`-friendly session
switcher for [`agent-shell`](https://github.com/xenodium/agent-shell) buffers,
plus an Embark action map for controlling the selected session. The package
itself ships no UI — it leans on the user's existing Vertico/Marginalia/Embark
stack.

Four modules, each requiring the ones above it:

- `agent-shell-vertico.el` — session completion table, annotations, Embark
  actions, and the conversation imenu index.
- `agent-shell-vertico-sidebar.el` — a persistent side window listing live
  sessions, driven by `agent-shell` event subscriptions.
- `agent-shell-vertico-transcript.el` — browsing, searching, and resuming the
  Markdown transcripts `agent-shell` writes.
- `agent-shell-vertico-consult.el` — Consult sources over the transcript store.

## Commands

```sh
make compile   # byte-compile every module (warnings matter — CI builds clean)
make test      # run the full ERT suite in batch
make check     # compile + test (what CI runs)
```

Run a single ERT test by name:

```sh
emacs -Q --batch -L . -L tests/support -L tests \
  -l tests/agent-shell-vertico-tests.el \
  --eval '(ert-run-tests-batch-and-exit "agent-shell-vertico-sort-by-recency-most-recent-first")'
```

The selector is a regexp, so you can match a group (e.g. `"sort-by"`). Override
the Emacs binary with `EMACS=/path/to/emacs make test`. CI runs on Emacs 30.1.

### Test isolation

Never load or run `tests/agent-shell-vertico-tests.el` in the user's primary
GUI Emacs server. That server may already have the real `agent-shell` package,
advice, and mode hooks loaded; running the suite there can invoke real package
behavior and stall the GUI.

Run tests only in an isolated Emacs process:

- Use `make check` for the complete compile and test verification.
- Use the `emacs -Q --batch` command above for a focused ERT selector.
- Do not use `emacsclient` connected to the primary GUI server for tests. This
  repository-specific rule is an explicit exception to general instructions
  that prefer `emacsclient` for Emacs operations.

The test file checks `agent-shell-test-stub-p` and fails immediately if the
real package is already loaded. Session-buffer fixtures also suppress
`agent-shell-mode-hook`. Do not weaken or bypass either safety measure.

## Architecture

**External dependency, stubbed in tests.** The real `agent-shell`,
`agent-shell-viewport`, and `nerd-icons-completion` are not present in this
repo. `tests/support/agent-shell.el` and `tests/support/marginalia.el` are
hand-written stubs that record the last command/buffer/args into
`agent-shell-test-*` dynamic variables. Tests assert against those globals
rather than real side effects. When you add a feature that calls a new
`agent-shell-*` function, you must add a matching stub to the support file or
the test load will fail.

**Reading session state.** Each live `agent-shell` buffer holds a buffer-local
`agent-shell--state` — a nested alist accessed with `map`/`map-nested-elt`. The
`agent-shell-vertico--*` accessors (`--session-field`, `--status`,
`--model-name`, `--mode-name`, `--title`, `--path`) all read from that
structure. Model/mode IDs are resolved to human names by looking the ID up in
the session's `:models`/`:modes` list (`--lookup-name`).

**The completion table** (`--completion-table`) is the core. It returns a
`metadata` form declaring category `agent-shell-session` plus affixation and
sort functions, and otherwise completes against live buffer names. `scope` is
`'all` (→ `agent-shell-buffers`) or `'project` (→ `agent-shell-project-buffers`).
Annotations reach the user two ways — `--affixate` (the `affixation-function`
in the table) and `--annotate` (the Marginalia annotator registered for the
category) — and both render through `--suffix`, so they cannot drift. The
columns are status, model, mode, title, path.

**Sorting** is user-configurable via `agent-shell-vertico-sort-by`
(`recency`/`creation`/`status`), implemented in `--sort-candidates` and wired
into the table's `display-sort-function`/`cycle-sort-function`.

**Embark actions** live in `agent-shell-vertico-embark-map`. Each action
(`-kill-session`, `-restart-session`, etc.) resolves the candidate string to a
live buffer, validates it is an `agent-shell-mode` buffer, then dispatches the
real `agent-shell-*` command with `call-interactively` inside that buffer.
`agent-shell-vertico-setup-embark` registers the category into
`embark-keymap-alist`.

## Critical constraint: do not pre-bind host-package variables

External variables (`embark-keymap-alist`, `marginalia-annotators`,
`agent-shell-agent-configs`, etc.) are declared with bare `defvar` and **no
value** (lines ~29–33). A `defvar` *with* a value would pre-bind the variable to
`nil` at load time, which prevents the host package's own `defcustom` from
installing its real default when it loads later. There is a regression test for
this (`...loading-does-not-prebind-embark-keymap-alist`) and a dedicated commit
that fixed it. Never give these `declare`/`defvar` forms a default value.

## Critical constraint: test stubs of macros must match upstream

`make compile` puts `tests/support` on the load path, because the real
`agent-shell` and `marginalia` are not in this repo. Anything a stub defines as
a **macro** therefore expands into the compiled output and ships to users.
`tests/support/marginalia.el` defines `marginalia--fields` and
`marginalia--field` exactly as marginalia does for this reason; a simplified
stand-in silently stripped every annotation's truncation, faces, and align
marker from the compiled files. Keep them in step with upstream, and prefer
plain functions in stubs wherever a macro is not required.

`agent-shell-vertico-transcript.el` sidesteps the same trap differently, by
building its annotation columns itself (`--field`/`--fields`) instead of using
the macro.

## Beware stale `.elc` files when running a focused test

`emacs -Q --batch -L .` loads `agent-shell-vertico.elc` in preference to the
`.el` when both exist, so a focused ERT run after an edit can test the previous
build and report a fix as failing. Run `make compile` first, or `make check`,
which compiles before testing.

## Conventions

- `.dir-locals.el` enforces `indent-tabs-mode nil` and `fill-column 80` for
  Emacs Lisp. Keep lines within 80 columns.
- Private helpers use the `agent-shell-vertico--` double-dash prefix; public
  commands use a single dash and carry `;;;###autoload` where appropriate.
- `skills-lock.json` / `.agents/` pin xenodium's emacs-skills; unrelated to the
  package code.
