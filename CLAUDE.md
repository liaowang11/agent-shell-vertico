# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An Emacs Lisp package that adds a Vertico/`completing-read`-friendly session
switcher for [`agent-shell`](https://github.com/xenodium/agent-shell) buffers,
an Embark action map for controlling the selected session, a persistent
sidebar, and transcript browsing/search interfaces. The completion commands
lean on the user's existing Vertico/Marginalia/Embark stack.

Four modules form a small dependency graph:

- `agent-shell-vertico.el` — session completion table, annotations, Embark
  actions, and the conversation imenu index.
- `agent-shell-vertico-sidebar.el` — a persistent side window listing live
  sessions, driven by `agent-shell` event subscriptions; requires the core.
- `agent-shell-vertico-transcript.el` — browsing, searching, and resuming the
  Markdown transcripts `agent-shell` writes; requires the core independently
  of the sidebar.
- `agent-shell-vertico-resume.el` — annotations for `agent-shell`'s own
  session picker, joined to transcripts by session ID; requires the
  transcript module.
- `agent-shell-vertico-consult.el` — Consult sources over the transcript store,
  the previewing reader for the session picker, and the `consult-line`
  integration that keeps folded blocks in a live shell buffer readable;
  requires the transcript and resume modules, not the sidebar.

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

**External dependencies, stubbed in tests.** The real `agent-shell`,
`agent-shell-viewport`, Marginalia, and Consult packages are not loaded by the
test suite. `tests/support/agent-shell.el`, `tests/support/marginalia.el`, and
`tests/support/consult.el` are hand-written stubs. The agent-shell stub records
the last command/buffer/args into `agent-shell-test-*` dynamic variables, and
tests assert against those globals rather than real side effects. When you add
a feature that calls a new dependency API, add a matching realistic stub or
the test load or compilation will fail. Optional `nerd-icons-completion`
integration is exercised only when that package is present.

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

**Enriching the session picker.** `agent-shell--prompt-select-session` calls a
plain `completing-read` with no completion category, and the only supported
hook, `agent-shell-session-choices-function`, can relabel choices but cannot
change the reader. `agent-shell-vertico-resume-setup` therefore advises that
function. Inside the advice, three things are bound for the duration of the
call: the choices function (composed with the user's own, so it records the
label-to-token alist the picker will use), the session-ID-to-transcript index,
and `completing-read` itself. The replacement reader only takes over when every
candidate is one of the recorded labels, because the picker also reads other
things while it is installed, such as which shell buffer to switch to. The
labels are returned unchanged, so upstream's own dispatch on `:new-shell`,
`:other-shell` and the session alist is untouched. Layer the reader the way the
transcript module layers its own: the plain reader lives in
`agent-shell-vertico-resume-read-choice-function`, and loading the Consult
module replaces it with the previewing one.

**Project-scoped commands.** `agent-shell-vertico--target-shell` implements one
rule: a prefix argument reads across `agent-shell-buffers`, otherwise the
current project's only shell wins, several mean a project-scoped read, and
none falls back to reading across every live shell. With nothing live
anywhere, resolving signals a `user-error` instead: these commands pick an
existing shell and never start one, which is what `agent-shell` and the
`agent-shell-*-start-client` commands are for. The macro pins
`agent-shell--shell-buffer` with `cl-letf` for the duration of the body, which
is how the answer reaches an `agent-shell` command that takes no shell
argument. This works because every wrapped command resolves synchronously
inside its own call (agent-shell.el:9593 for the senders, agent-shell.el:9736
for the prompt family); a command that resolved inside an event callback could
not be wrapped this way. The commands themselves are generated by
`agent-shell-vertico--define-shell-command`, which appends the shared rule to
each docstring and gives each an `(interactive "P")` spec. The prefix is
consumed by the resolver and never reaches the delegate, which matters for
`agent-shell-send-file`, whose own prefix means "prompt for a file"; that
variant is the separate `-send-other-file` command.

**Enriching the shell buffer prompts.** Every `agent-shell` command that asks
which shell to act on reads through `agent-shell--read-shell-buffer`, which
takes no hook, so `agent-shell-vertico-setup-shell-buffer-picker` advises it
`:override` with `agent-shell-vertico--read-shell-buffer`. The replacement
completes over `agent-shell-vertico--table`, the same table the switch commands
read, so those prompts gain the annotations, the sort, and the
`agent-shell-session` category (hence the Embark actions). It keeps upstream's
contract: `:buffers` still names the shells to offer, the chosen buffer is
returned, and no shells or no selection is a `user-error`. `:force-short-names`
is accepted and ignored, because candidates are whole buffer names.

**Opening a live session's transcript.** `agent-shell-open-transcript` is a
bare `find-file`, so a transcript reached from a session misses the reader
that browsing gives it. `agent-shell-vertico-transcript-open-session` resolves
the shell with upstream's `agent-shell--current-shell` (so a viewport works
too), reads that buffer's `agent-shell--transcript-file`, and opens it through
`--record-from-file` and `--open-record`. Upstream's own commands are left
alone: this is a command to bind, not advice, so nothing changes for anyone
who has not bound it.

**Narrowing and grouping.** Each completion category answers two
questions of its own: `--narrow-keys` lists the keys it offers, and
`--narrow-p` says whether a candidate belongs to the key in force. Both
live in the Consult-free modules, so they are plain functions to test.
`agent-shell-vertico-consult--narrow` is the only place that knows about
Consult: it reads the key from `consult--narrow` and returns the
`(:predicate FN :keys ALIST)` plist Consult has taken since 2.4, which is
why the Consult module requires that version (there is no 2.0 through
2.3; Consult went from 1.8 straight to 2.4). Consult installs the
predicate as `minibuffer-completion-predicate`, and every table here
passes its predicate to `complete-with-action`, which is how the answer
reaches candidates. Anything a predicate needs to know about the buffer
the command was called from — the current project, today's date — is read
into a context beforehand, because the predicate itself runs with the
minibuffer current. `consult--type-narrow` is deliberately not used: it
keys off a `consult--type` text property, which would put Consult symbols
into modules that do not require it. Status keys are named after the
status they select, so one alist is both the key help and what a
candidate's status is compared against. Grouping is completion metadata
(`group-function`), so it also works without Consult; `consult--read`
puts its own metadata ahead of the table's, so the `:group` a reader
passes wins over the table's, and both name the same function.

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
