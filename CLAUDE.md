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
  sessions, driven by `agent-shell` event subscriptions; also owns which
  sessions need attention, the command that jumps to them, and the
  notification hook. Requires the core.
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
Embark reaches the picker through the
category the table declares, `agent-shell-session-choice`, registered by
`agent-shell-vertico-resume-setup-embark`. It reuses
`agent-shell-vertico-transcript-embark-map` rather than defining its own,
because `--candidate` stores the joined transcript under the same text
property the transcript actions read a candidate with. No default action
is registered, so acting without a key keeps the picker's own default of
selecting the session.

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

**Searching transcripts is per match, browsing is per transcript.** A
search row is one rg match, the way `consult-ripgrep` works, not one
transcript with a match count: which line a match is on is the answer the
reader is after. `--rg-matches` therefore returns one entry per match and
`--record-for-match` copies the transcript's record once per match,
stamping that match's line and text; a `cache` argument keeps the
transcript parsed once however many times it matches, and holds
`--unlisted` for a file belonging to no known project, because nil is
also how a hash table reports it knows nothing. Ordering is rg's:
`--rg-command` passes `--sortr modified`, so nothing sorts afterwards and
the Consult stage can stream each chunk straight through instead of
rebuilding and re-sorting the whole list on every chunk. That costs rg its
parallelism, which a store of transcripts is far too small to miss.

Match rows are their own completion category, `agent-shell-transcript-match`.
The row is `TITLE:LINE: TEXT` and the annotation is project, agent and
status — what the row cannot say for itself. Splitting the category is
what lets the two annotations differ; it reuses
`agent-shell-vertico-transcript-embark-map` rather than defining its own,
as the session picker's category does, because a match candidate carries
its record under the same text property. The candidate and the annotation
are built in the Consult-free module, so both are plain functions to test;
`agent-shell-vertico-consult--async-candidates` only turns rg's output
into calls to them.

**Who wrote a match.** Search narrows by speaker, which means answering
which section of a transcript a matched line falls in.
`--scan-sections` answers it for a whole buffer as a vector of
`(LINE . SPEAKER)`, ascending, so `--section-for-line` finds a line's
section by halving rather than walking. It tracks fences exactly as the
clean view does, and for the same reason: tool output is written inside a
fence, and an agent that fetches a page or reads an older transcript puts
`## User` lines in it. Measured against this author's store, a scan of
all 2429 transcripts (654 MB, 11.1M lines) costs 5.2 s, 2.1 ms a file, so
the scan is lazy and cached by file plus modification time in
`--sections-cache`: a transcript is read when one of its matches is first
asked about and never again while it is unchanged. Drawing a screenful
costs about 50 ms whatever the query matched; pressing a speaker key
scans every matched transcript once, which is 0.1 s on a real query and
2 s on a deliberately broad one. Nothing else in a search touches the
speaker, so nothing else pays for it.

**Jumping around a viewport's history.** A viewport shows one exchange at
a time and steps through them one at a time.
`agent-shell-vertico-viewport-goto-page` reads which exchange to show,
naming each by the prompt that started it. It counts pages the way
shell-maker does, so it uses shell-maker's own searchers rather than a
plain `re-search-forward`: a prompt only counts when it carries the
`comint-highlight-prompt` face, and an exchange only counts when its
end-of-prompt marker carries the `shell-maker--marker` property. Without
those two checks a prompt an agent echoed inside a response would become
a page of its own. `tests/support/shell-maker.el` keeps both rules, which
is what makes the tests about echoed prompts mean anything.

**Preparing where a session appears.** Every command that opens a session
goes through `--display-session` or `--display-session-other-window`, so
`agent-shell-vertico-before-display-function` is called there, once, with
the buffer actually about to be shown: the viewport when
`agent-shell-prefer-viewport-interaction' is set, the shell buffer
otherwise. That is the seam for a window-layout package that keeps one
layout per project and has to switch layouts before the session is
displayed. One setting covers the switch commands, the Embark actions and
the sidebar, which is why it is a variable here rather than advice in a
user's configuration.

**Status and unread are two axes.** What a session *is* and what it
*owes the reader* are separate questions, and conflating them was a bug:
a finished turn used to report the status `Done`, so an idle session
reported as busy-ish and a failure could never be read away. `--raw-status`
answers the first question with `starting`, `ready`, `busy`, `blocked` or
`failed`. `busy` and `blocked` come straight from `agent-shell-status`, which
never reports the other two: `starting` and `failed` are the sidebar's own
overlays on top of what `agent-shell-status` calls `ready`. `starting` is a
session with no ACP session id yet, recorded nowhere because the id's
absence is the whole answer; `failed` is recorded in `--failed` from the
`error` event and dropped when a new turn starts, because agent-shell
reports what a session is doing and not how its last turn ended. Both
overlays only apply to an otherwise idle session, so a live `busy` or
`blocked` always wins.

**Which session needs attention.** `--unread` is the second axis: a buffer
to the time its unread output arrived, where presence is the whole record.
It is set from the `agent-shell` event subscription in `--handle-event`
(a finished turn, a permission request, an error), plus
`--out-of-turn-settled` for output that arrives with no turn in flight.
It is cleared when the reader actually looks at the session, which
`--session-focused-p` decides by comparing against the selected window's
buffer on a focused frame. Being merely current is not enough: any code
that does `with-current-buffer` on a session would otherwise mark it read.
`--needs-attention-p` joins the two axes: unread output, or a `blocked`
status. Blocked is deliberately not recorded — the session reports itself
blocked for as long as it waits, so reading the status is the whole
answer and no record can go stale. Reading a blocked session therefore
drops its unread mark and leaves it in the attention tier, which is
right: it still owes a permission decision.
The `priority` sort puts the attention sessions first, oldest-first
within that tier, so `agent-shell-vertico-sidebar-jump` visits the head of
`--sort-buffers ... 'priority'` and nothing else has to rank them again.
`agent-shell-vertico-sidebar-mark-unread` is the only mark the reader sets
by hand, and it writes the same record the events write, so status names,
icons, ranks, counters and the jump order need no case for it. It stamps
the session's last activity time, not the current time, so the
oldest-first tier stays truthful; it refuses a `busy` session, whose turn
has produced nothing to miss; and it leaves an existing mark at its own
time. It deliberately does not fight the clear paths: marking a
session unread while sitting in it holds only until the reader is next seen
looking at it, which is a decision, not an oversight.
`--mark-read` is the same record in reverse and refuses nothing, because
the unread mark is now the only thing it can drop: a blocked session keeps
its place through its status and a failed one stays failed. Both commands
resolve their session through `--attention-target`, which reads the sidebar
row at point when called there and the current buffer's session, viewport
included, anywhere else.

**Jumping to a session by key.** `agent-shell-vertico-sidebar-jump-by-key` is
the `ace-window` model: assign labels at trigger time, show them where the
reader is already looking, read one key. The sidebar is the only rendering, so
`--read-jump-target` first makes it list the sessions flat: a hidden sidebar
is displayed for the read and its window deleted after, and
`agent-shell-vertico-sidebar-group-by` is let-bound to nil around a render so
a folded session has a row too. Every exit path renders again under the real
grouping, including the aborts, which is also what repairs a sidebar shown on
another frame: the buffer is shared, so the flat render reached that frame
too. The folds themselves are never touched. Labels come from
`--session-rows`, the rendered rows in display order, not from a separate
sort, so what is drawn is what is keyed, and `--visible-rows` then drops the
rows outside the window, because `read-key` blocks and a key nobody can scroll
to is a key nobody can press. It counts lines rather than asking `window-end`,
which is exact here because the sidebar truncates lines, and which
`window-end` cannot answer before a redisplay this code cannot force. Each
label is an overlay whose `display' replaces the row's mark character, so
nothing reflows. The face goes on the overlay rather than inside the display
string, as `aw-leading-char-face' does: an overlay face beats both the faces
the text carries and the dimming overlay below, which a face inside the string
could not be relied on to do. A nerd-icons mark carries the icon font's family
and height in its face, so the label face inherits `default' last to specify
both again and to hand back the ordinary background; without that the digit is
drawn in the icon font, on a block of colour. The colour is red, from `error',
because `--dim-overlays' leaves nothing else on the list red: the only other
red is the unread mark, and a row that carries no key is dimmed. The action
list keeps `font-lock-builtin-face', as `aw-key-face' does, both because the
echo area has nothing to confuse a colour with and because that colour is the
working status on a row. What dims is the inverse of ace-window: a window is
chosen by where it is, so ace-window can dim every window and let position
carry the choice, but a session is chosen by reading its title and project, so
dimming the list would take away the answer. The frame's other windows dim
instead, which is what makes the sidebar stand out, and within the sidebar
only the rows no key was drawn on. Each dim is one overlay, because an overlay
face takes precedence over the faces the text carries; a window's overlay
carries a `window' property so a buffer shown twice dims only where the reader
is not looking. Rows are compared against the labels rather than against the
visible rows, or a row on screen but past the last key would stay bright and
unpressable. Timers fire while `read-key` waits and a render erases the
buffer, so `--render` returns early, marking the sidebar dirty, while
`--jump-in-progress` is bound; that flag is bound only after the flat render
the jump itself needs, and the cleanup render is what acts on the dirty mark.
An erased buffer leaves each label overlay empty rather than gone, so the
tests assert the span and the character under it, not the overlay's existence.
Keys are positional on purpose: under `priority` sorting rows move, so a
per-session sticky key would need a persistent label column to be readable,
and that is a separate feature.

**Jumping to a session by position.** `--jump-to-index` is the blind jump the
`agent-shell-vertico-sidebar-jump-to-1' family is bound to, and it answers a
different question from `-jump-by-key': nothing is drawn, so there is nothing
to restrict to the rows on screen, and it reads `--sort-buffers' directly
rather than a rendered sidebar it would have to open. Positions count from 1,
so a command's number is the key a user binds it to, unlike
`+workspace/switch-to-N' which is 0-based behind 1-based keys. The commands
are generated with `defalias' over a `dotimes' exactly as that family is,
because a named command is bindable in a `map!' without a lambda and findable
through `execute-extended-command'; each closure captures its own index, which
a test pins by calling three of them. The index is deliberately not a stable
name for a session: the order is whatever
`agent-shell-vertico-sidebar-sort-by' says, and under `priority' the act of
jumping reads the session and moves it out of the attention tier, so the same
key answers differently next time. That was the user's call, a quick jump
rather than an address, and it is why the reading jump exists beside it.

**Dispatching an action from a jump.** `--read-jump-keys` is the loop
`ace-window` runs for `aw-dispatch-alist`: a key is either a session, an
action, or `?`. A session ends the read, an action records what the next
session key will mean and asks again, and `?` puts the action list above the
prompt and leaves it there for the rest of the read. That list is one action a
line with its key faced and its description not, which is what makes a column
of keys scannable; packing several to a line to save height read as a
paragraph instead. `ace-window` draws `aw-dispatch-alist` the same way.
Session keys are checked first, so a key that is both never makes a session
unreachable; the reverse order would instead loop, which is why the collision
test reads from a finite list rather than a constant. The reader returns
`(BUFFER . ACTION)` and runs neither, because the actions are commands that
prompt: `set model` needs a minibuffer and `kill` a confirmation, and both
want the borrowed sidebar window gone and the real layout back first. The
default action is `--jump-display`, and the prefix argument swaps it for the
other-window one by identity, which is also why an explicitly dispatched
action ignores the prefix. Most entries name the existing public
`agent-shell-vertico-*-session` commands, which accept a buffer because
`--session-buffer` goes through `get-buffer`; the two mark commands read their
own target instead, so `--jump-mark-unread` and `--jump-mark-read` run them
with the session current and let `--attention-target` answer.

**Drawing a session.** A row's mark is a `(STATUS . UNREAD)` cons, built by
`--mark-for` and cached in the render snapshot as `:mark`. The status picks
the glyph from `--status-icons`, which lists a filled and an outline
nerd-icons name plus one plain character per status, and unread picks
between the two. `--mark-face` colours it: red (`-attention`) for unread,
yellow (`-unresolved`) for a `blocked` or `failed` session already read,
then the status colours. Red therefore means exactly `--needs-attention-p`
minus the sessions the reader has already seen. The plain characters have
no filled twin for a check or a question mark, so in a terminal the colour
alone carries unread; that is a deliberate limit, not an oversight.
`--mark-counts` groups the header and project-header counts by mark, unread
first, so one status can be counted twice and `--mark-label` says which is
which in the tooltip. Slots that are not statuses (`project`, `message`,
`sessions`, the fold triangles) stay in `--icons` and are drawn by
`--slot-icon`; both go through `--draw-icon`.
The fringe marker for the sessions on screen is derived, not stored:
`--current-sessions` lists every session, or viewport, a window of the
selected frame shows, and nothing else. The selected window alone would be
too narrow, because moving to the sidebar, a file or magit beside a session
does not leave it; a session absent from the frame, or on another one, is
unmarked. This is only the marker: unread still needs the selected window
(`--session-focused-p`), because seeing a session in a side window is not
reading it. The render caches what it drew in `--rendered-current-sessions`,
and the selection and buffer-change hooks compare against that cache as a
set, so a window rearrangement showing the same sessions redraws nothing and
the cache can never disagree with the windows for longer than one idle
refresh.

**Which of them you are in.** A frame showing several sessions leaves the
marker unable to say which one the reader is typing into, so the marker has
two tiers: `--focused-session` picks one out of `--current-sessions` and
`--current-session-marker` draws it differently. They are one question
answered with two degrees, not two questions, so they share a hue family and
differ in strength: `-focused-session` is `outline-1`, the one accent with no
status meaning, on a solid bar, and `-current-session` is `shadow` on a
dashed one. Every other colour here already names a status, and a marker
that borrowed red, yellow, magenta or green would say something untrue about
the session; `shadow` is what the package already uses for what is present
and not the answer. The shape repeats what the colour says because a fringe
bitmap is two pixels wide and cannot be trusted to carry a hue difference on
its own. The focused session is *remembered* rather than read from the
selected window, in `--focused-session` (the variable): the selected window
answers nothing the moment the reader steps to a file or to the sidebar, and
the sidebar is the likeliest place to step to, so reading the list would be
what took the marker off the row being read. Only selecting a window on
another session changes it, and only while it is still in `--current-sessions`
does it mark a row, so the stronger marker never outlives the weaker one it
strengthens. That memory is deliberately looser than `--session-focused-p`,
which decides what has been *read* and must stay on the selected window. The
render caches it in `--rendered-focused-session` and the hooks compare it
separately from the set, because moving between two sessions already on the
frame changes the drawing without changing the set.

**Notifications.** `agent-shell-vertico-sidebar-notify-function` is called
wherever an attention mark is set, never for a focused session. It receives
`:buffer`, `:agent` (the agent's display name), `:status` (the same word
the sidebar shows for the session, never a read state), `:unread` (whether
the session holds output nobody has read) and `:last-message`.
The message is accumulated in `--record-message-chunk` from the events the
sidebar already subscribes to, because `agent-shell` emits one event per
streamed chunk and keeps none of them; any other event ends the message.
Text is passed on unshortened, so trimming and markup stripping belong to
the caller's channel, not here.

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
