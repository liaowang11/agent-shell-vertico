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
  sessions in Claude Code's agent-view states, driven by `agent-shell` event
  subscriptions; also owns which sessions need attention, pins and snoozes,
  the peek window, the command that jumps to them, the mode-line count, and
  the notification hook. Requires the core; loads the transcript module
  only when the reader resumes a past session from it.
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
`agent-shell-*-start-client` commands are for; the sidebar's dispatch
(below) is this package's one way to start a shell, and it starts one with a
prompt rather than resolving an existing one. The macro pins
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

**One walk over the sections.** `--walk-sections` is the only code that
finds section headings: it searches for `--section-regexp` (fences and
the three heading shapes) rather than visiting every line, tracks fences
so a `## User` echoed inside tool output is not a heading, and calls back
with the speaker at each heading. Both `--scan-sections` and the clean
view (`--show-clean-view`) are consumers of it, so the two cannot
disagree about what a section is. It is about twice as fast as walking
line by line (27 ms against 57 ms on a 12.9 MB transcript; 1.5 ms on the
150 KB median), which is within 2x of the disk read. Transcripts open in
the clean view by default (`agent-shell-vertico-transcript-default-view`),
decided by `--record-read-clean-p`: a match on a hidden line opens full,
and `--open-record` leaves a buffer that was already visiting the file in
whatever view its reader had chosen. Consult previews apply the same rule
in `agent-shell-vertico-consult--preview-buffer`, with the same two
guards: `find-buffer-visiting` before the opener runs, because Consult
previews in a reader's own buffer when there is one, and a toggle rather
than an unconditional show, because Consult keeps a previewed buffer for
the next candidate in the same file (a hidden match then a message match
must flip it full and back). This is why the clean view is a toggle on a
buffer and not a separate rendering: a preview of the 150 KB median
transcript costs 1.5 ms over the read, and Consult already truncates
files above 1 MB to a 10 KB chunk before the view is applied.

**Who wrote a match.** Search narrows by speaker, which means answering
which section of a transcript a matched line falls in.
`--scan-sections` answers it for a whole buffer as a vector of
`(LINE . SPEAKER)`, ascending, so `--section-for-line` finds a line's
section by halving rather than walking. Measured against this author's
store, a scan of all 2429 transcripts (654 MB, 11.1M lines) costs 5.2 s,
2.1 ms a file, so
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
is what makes the tests about echoed prompts mean anything. A candidate
is `N: PROMPT`, read through `--ordered-table`, which declares `identity`
for both sort functions because the history's order is the answer: a
table that declares none leaves the order to the reader, and Vertico's
default sorts by history and then by length. That helper serves every
reader whose order is the answer and which has no category of its own —
the project reader, whose `--project-roots` puts the current project
first, and the sidebar's sort-criterion reader, which lists its default
first. The number is right-aligned so the
prompts of a ten-page history keep one column, and it is also what tells
two exchanges opening with the same prompt apart, which the prompt alone
could not.

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

**Dispatching a prompt.** `agent-shell-vertico-sidebar-dispatch` is Claude
Code's dispatch box: a prompt that starts a new session working out of sight.
The target is settled before the prompt is read, so cancelling a picker loses
no typing (`--dispatch-target`): a session row gives its project and
`:agent-config`, a project header its project and agent-shell's preference
(`agent-shell--auto-preferred-config`, else `agent-shell-select-config`), and
anywhere else, or `C-u`, reads the project with the transcript module's
`--read-project` (loaded lazily, as resume-past does) and then the agent. The
prompt is read with its own map and history: `RET` dispatches, `C-RET`,
`M-RET` (which a terminal can send) and `M-<return>` dispatch and open, as
Claude Code's ctrl+enter, and `C-j` breaks a line; only an empty prompt is
refused. The shell starts with `agent-shell--new-shell :no-display t`, so no
window changes and neither the before-display hook nor the jump history hears
of it; opening goes through `--display-session`, so both see it once. The row
is marked before any render: the mode hook has set `fresh`, which would file a
session holding its prompt under Needs input as "Send a prompt to start", so
the command clears it and sets `detail` to `> PROMPT` and the `dispatched`
slot to the prompt; with no session id yet the status is `starting`, Working
and spinning, and `--detail-for` says `Queued: PROMPT` while the slot is set.
The wait for readiness is ours (`--dispatch-when-ready`): agent-shell's insert
would wait on `prompt-ready` itself, but a subscriber's error ends as a message
from `agent-shell--emit-event`, which would leave a row reading as sent. So
the prompt goes through `--send-prompt` only once the session has its id, now
or from our own `prompt-ready` subscription, where agent-shell submits at once
and never waits a second time; `--new-shell` starts with the `new` strategy,
so `prompt-ready` comes unasked. A send that signals, an `error` event
while `dispatched` is set (a session failing to start), or `--note-exits`
finding the agent dead while it is set, runs `--dispatch-failed`: the row
reads failed, the prompt goes on the kill ring and a message says so. Only
the failed send reports itself there, as any failed turn is reported:
`--stamp-terminal`, unread and `--notify` with `--settled-status` unless the
reader is in the session; the `error` arm and `--note-exits` report their
own. `prompt-ready` sends only while the slot still holds
the prompt, so a prompt given back is never sent later. `clean-up` reports
nothing: a session the reader kills on purpose is not a failed dispatch, and
its record and our subscription die with it. `input-submitted` clears the
slot. `:no-display` does not stop an agent that has to authenticate from
asking, so "out of sight" is not guaranteed there. Like every sidebar key,
`d` is bound in four places plus the help text: the mode map, the `C-c` action
map, the Evil bindings (as `gc` in `--evil-g-map`, listed in
`--evil-bindings` and skipped by the direct install as `gr` and `gh` are,
since Evil's `d` is its delete operator) and the `C-c` key list in
`--bind-evil-keys`.

**One record per session.** Everything the sidebar remembers about a session
that agent-shell does not keep is one `agent-shell-vertico-sidebar--session`
struct per buffer, in `--sessions`, read with `--get`, written with `--set` and
dropped with `--forget` when the buffer dies. The slot docstrings are the
reference for what each slot means. Setting a slot to nil on a session with no
record creates none, so the paths that tidy up after a killed buffer leave
nothing behind. The record used to be one hash table per fact; where the text
below names `unread`, `snoozed`, `pinned`, `state` and the like, it means a
slot.

**Status and unread are two axes.** What a session *is* and what it owes the
*reader* are separate questions, and conflating them was a bug: a finished
turn used to report a status that was really a read state, so a failure could
never be read away. `--raw-status` answers the first question with `starting`,
`new`, `busy`, `background`, `blocked`, `done`, `failed` or `stopped`, taking
what `agent-shell-status` reports and overlaying what it does not; its
docstring gives the order. That function answers about the turn in flight, so
whatever outlives a turn is the sidebar's own: `starting` is a session with no
ACP session id yet, recorded nowhere because the id's absence is the whole
answer; `new` is the `fresh` slot, a session the sidebar saw start that nobody
has prompted, which a dispatched session never is, since it starts with its
prompt; the `state` slot is how the last turn ended (see below), set by
the `turn-complete` and `error` events and set to `working`, a value no
overlay reads, by `input-submitted`, because agent-shell reports what a session
is doing and not how its last turn ended; `busy` covers an out-of-turn burst;
and `blocked` covers a permission request from a task that outlived its turn,
which `agent-shell-status` calls ready because it asks for a turn in flight as
well (`--permission-pending-p` puts agent-shell's own question rather than
repeating it, so the two cannot disagree about what is pending), and so does
a pending elicitation form raised outside a turn, which `--form-pending-p`
asks agent-shell about the same way). The overlays
only apply to an otherwise idle session, so a live `busy` or `blocked` always
wins, and the pending decision is asked first among them: a burst streaming
beside it is work the session does while it waits, not an answer to it.

**When the agent process dies.** One overlay comes before even agent-shell's
live status: a session whose agent process ran and exited (`--live-p` nil) is
answered by `--exited-status`, because a dead agent can neither be busy nor
answer a request, whatever agent-shell's records still say. When acp's
sentinel fails a prompt, agent-shell emits `error` before it clears busy and
leaves any pending permission in place, and a busy flag that outlived the
process would spin forever; asking about the process first settles both. The
rule is Claude Code's for a job whose worker died (`an()`, m0307.js:2009): a
turn that had ended keeps how it ended (`done`, `stopped`, `failed`), one that
ended on a `needs input:` question stays `blocked` and its NEEDS is that
question alone, never a request the dead agent left behind, and anything else
(a turn in flight, `starting`, `new`, an out-of-turn burst) is `failed`, which
`--error-for` says as `Failed: Agent process exited` when no `error` event gave
a message. Like the pending decision, it is derived rather than recorded: a
prompt to the dead buffer makes acp start the process again in place
(acp.el:456), so a stored flag would go stale. The one record is the
`exited-at` slot, which only says the exit has been reported:
`--note-exits` stamps it, and when the exit is what failed the session (the
state slot is not one of the four kept above) ends a snooze, marks the session
unread unless the reader is in it, and calls `--notify` once; a prompt still
`dispatched` is given back through `--dispatch-failed`. A turn the exit
cut short was already reported by its `error` event and so is skipped. The slot
clears when the process is seen alive again or on `input-submitted`. agent-shell
emits nothing for an idle exit, so `--note-exits` runs at the top of every
render, before any snapshot is taken, and from `--background-poll`; the
notification therefore waits for the sidebar to be shown, within a minute
thanks to the age refresh, which matches Claude Code checking only when its
list loads. The status, the counts and the jump need no render, since they are
derived. The stamp is set before `--notify`, which runs under
`with-demoted-errors`, so a notify function that renders again reports nothing
twice and one that signals does not abort the render.

**How a turn ended.** A cancelled turn is `stopped`, and a stop reason other
than `end_turn` (a refusal, a limit) is `failed` in agent-shell's own words.
A turn that ran to its end is read by `--classify-message` as Claude Code
reads a background job's last message. A marker counts only when it is the
message's last non-empty line outside code fences: a `result:`, `needs
input:`, `blocked:` or `failed:` line there (`--marker-regexp`,
case-insensitive) makes it `done` with that `result`, `blocked` with that
`needs`, or `failed` with that `error`. The same words on any earlier line
are ordinary text, because a reply's summary such as `Blocked: 2 jobs`
followed by `All done.` would otherwise park a finished session in Needs input
until the next prompt. Claude Code scans the last 800 characters for a
marker instead (m0303.js:149-218), and so reads that very summary as
blocked; this is where the two deliberately differ. When the last line is no
marker the turn is `done`, and that line is the result. There is no model
step, as there is in Claude Code; the markers are the whole convention.

The marker itself is read as Claude Code reads it (m0303.js:149-152), on
the last line only: `I'm blocked:` (or `I’m`) counts as `blocked:`; a `—`,
a `–` or a hyphen between spaces may stand for the colon, a bare hyphen
not, so `Failed-over nodes` stays a word; and what follows must be three
characters starting with a non-blank, so `Failed: 3` is text. Since the
word must start the line, a list item, quote, emphasis or table row that
mentions one is text too. The cost is the same as a colon's: a last line
`Blocked — nothing left; all done.` parks the session in Needs input just
as `Blocked: nothing left` always did. A fence is three or more backticks
or tildes at any indent, since a fence inside a list item is indented
(Claude Code allows three spaces), and as in Claude Code it closes only
on a run of its own character at least as long as the one that opened it
(m0303.js:76-106). Claude Code's prose rules for a turn with no marker,
such as a trailing question, are not ported.

**Claude Code's job fields and bands.** `--job-state` restates the status as
the three fields Claude Code keeps for every job: STATE (`working`,
`blocked`, `done`, `failed`, `stopped`), TEMPO (`active`, `blocked`, `idle`) and NEEDS (what the
reader is asked: `Allow: TITLE` from the pending tool call, a pending
elicitation form's question (`--elicitation-needs`), or the `needs input:`
line). The request named is the newest of its kind, the one agent-shell's own
keys answer: `--pending-permission` takes the first tool call carrying a
`:permission-request-id`, since agent-shell keeps the newest first, and
`--pending-form` the newest `elicitation/create` in `:active-requests`, since
storing a form moves it to the front of `:elicitations`. The peek reads the
same two functions, so the row and the peek never name different requests.
They are derived from the status rather than stored, so the two
cannot disagree. A session nobody has prompted follows Claude Code's rule: it
is working and blocked, with NEEDS `Send a prompt to start`, so it is filed in
the attention band and drawn yellow. A shell the reader has just opened asks
them nothing, though, so `--waits-p` leaves it out of the mode-line count and
a project header's count, `--needs-attention-p` leaves it out of the jump, and
`--notify` never reports it.
`--band-for` files a snapshot into a band, first match wins as in Claude
Code: snoozed and not active is `snoozed`; active is `working`; blocked is
`attention`; in flight (`background`) is `working`; anything else is `idle`.
Unread output does not change the band, so a finished turn nobody has read is
idle, as in the agent view, and says so with a bold title (`-unread-title`)
rather than a colour. `--section-for` is the band, unless the session is
pinned. `--job-fields` computes all of it once per snapshot as `:state :tempo
:needs :in-flight :band :pinned :section`, and `--band` and `--section` read
one field back for a buffer outside a render. Counting who waits asks
`--waits-p`, which asks `--band` (the mode line, a project's `✻` count), so a
pinned session still counts where its state puts it; placing a top-level row
asks `--family-section`: Pinned when the root is pinned, else the most urgent
`--band` in its family.

**The state view.** The sidebar has two views, and
`agent-shell-vertico-sidebar-group-by` names one: `state`, the default, or
`project`. Any other value, nil included, is the state view, because
`--view` is the only reader of the option and answers `project` for
`project` alone; the flat list it once also offered is gone, since a flat
list with headers is the state view. `=` toggles the two. `--render` draws
`--group-by-section` over the roots: a header for each non-empty section in
`--sections` order, sessions in the user's sort within it. The sections are
Claude Code's: Pinned, Needs input, Working, Completed and Snoozed. Their
symbols are the bands `--band-for` answers, so Completed is the `idle`
band and Needs input the `attention` one. A child is drawn under its
parent, so a root's section is its whole family's (`--family-section`):
Pinned when the root is pinned, otherwise the earliest section among the
bands of the root and every live descendant. A child waiting on the reader
therefore draws its idle parent under Needs input, and a working child puts
an idle family under Working. A header is ruled off by an underline the
header's newline extends to the window's edge (`--header-rule`), in
`-header-rule`'s colour, because `─` characters show gaps between glyphs
and an overline or a background band is lost in a terminal or a theme; it
is prepended, so the snoozed face's `:underline nil` cannot cut it. The
label takes its section's state colour (`--section-face`; Pinned keeps
`-section`), and there is no fold triangle: a folded header ends in `⋯`.
Rows under a section or project header are at depth 0, flush with it,
since colour and rule already tell the header apart and the sidebar is
narrow. Each header is a fold in `--section-folds`,
seeded from `agent-shell-vertico-sidebar-folded-sections`, and an open
section draws every session it holds: there is no cap and no "more" row.
Claude Code caps its Completed section, but the reasons do not carry
over: the sidebar lists only live buffers, rows span several lines in a
scrolling window, the `priority` order puts unread sessions at the head
of Completed so a cut by finish time would split them, and folding the
whole section already exists.
A fold lasts only while its header is drawn: every render runs
`--forget-empty-section-folds`, which drops the fold of a section holding
no root, because `S-TAB` folds empty sections too and an empty section
has no header to unfold, so a session arriving in Needs input found it
folded behind a fold nobody could see.
The header counts, folded or open, which `--header-counts` says (see the
header paragraph below). The project view puts a Pinned section above the
projects (`--split-pinned`), and its projects start open
(`agent-shell-vertico-sidebar-expand-by-default`). `--display-order`,
`--reveal-session`, `--view-level` and `--set-view-level` each have a state
arm, and each asks `--family-section` of a root, so stepping, revealing and
`S-TAB` see the sections the render draws. `S-TAB` steps both views through
headers alone, rows, then rows with details, and back to headers.
`agent-shell-vertico-sidebar-jump-by-key` keeps the configured view and opens
every project and section for the read: it temporarily binds
`--expanded-projects` and `--section-folds` to nil, `expand-by-default` to t
and `folded-sections` to nil around its render, so a folded session gets a
row and a key while the folds themselves stay as the reader left them.

**The detail line and the age.** Every row is a title line and, when
`--detail-for` has something to say, a detail line, as the agent view draws a
job; an idle session whose turn the sidebar never saw finish has none. The state
view adds a third, the `⌂ project` line: `--insert-section` passes `nested` nil
to `--insert-sessions`, so `--session-lines` draws it there, because a section
header does not name the project; the project view's Pinned section goes
through `--insert-section` too, so its rows carry the line as well. Only a
project header suppresses it, and so does leaving `project` out of
`agent-shell-vertico-sidebar-extra-info` (`--flat-project-line`, a name kept
from the flat view this line was first drawn in).
`--detail-for` picks the line as Claude Code does:
NEEDS while blocked, the newest entry while active, `Failed: REASON` or
`Stopped` for a turn that ended that way, and otherwise NEEDS, then the result,
then the newest entry. The newest entry is the `detail` slot: `> PROMPT` from
`input-submitted`, the symbol `message` while chunks stream, a tool call's
title, or `✗ TITLE` for a failed one (`--record-tool-call`); subagent events
never touch it. A tool call is drawn as Claude Code's tail describes the
latest tool use, whatever its status, but only its first titled update is a
new entry: ACP updates a call as it runs, and one finishing after the agent
wrote more is not newer than what it wrote. The `tool-calls` slot holds the
turn's recorded ids, and `detail-tool-call` the one the line shows, which its
later updates refresh.
`message` is resolved when drawn by `--message-last-line`, which joins only as
many of the newest chunks as hold a whole last line, so a long message costs no
more than its end. In the project view `--detail-line` starts with the status
word in the mark's face, because no section header says it there; `--view`
decides, so a nil `group-by` draws the detail alone. The
title line ends in `--age-text`: time in the current band (`--state-since`), not
the session's age, drawn yellow when `--stuck-p` says an active session has been
silent for `agent-shell-vertico-sidebar-stuck-after` seconds. A wait on a
permission request ages from the `waiting-since` slot, stamped by each
`permission-request` and cleared by `input-submitted` and the turn's end
(`--stamp-terminal`), because reading the request drops `unread` while the
session still waits; a turn that ends on `needs input:` ages from its end.
The `unread` slot is never an age: it is a place in the unread queue, which
`mark-unread` moves, so pressing it would otherwise reset the age it shows.
Titles stay one line, cut with `…`, unless
`agent-shell-vertico-sidebar-wrap-titles` is set, so every row has one height.
An expanded row (`TAB`) wraps its whole title instead, past
`title-max-length` too, since expanding is asking for more. It wraps its
detail too, in at most `agent-shell-vertico-sidebar-expanded-detail-lines`
lines (`--expanded-detail-lines`), and when the detail is the end of the
agent's message (`--detail-from-message-p`: the result, or `message`) it
shows the message's last lines from `--message-tail`, dropping the oldest
whole lines that do not fit; any other detail keeps its start. A row cut either
way is recorded whole by `--record-whole-text` in `--whole-texts`, cleared
each render, and read back by the title's tooltip and by `--echo-row` on
`post-command-hook`, which says it once when point reaches the row, never
over a message the command left, and takes it back when point leaves.
Since every row carries an age, `--ensure-age-refresh` runs whenever the sidebar
is visible and has sessions.

**The header and the mode line.** There is no summary line above the
sidebar: `header-line-format` stays nil, and every section and project
header counts for itself instead. The one exception is a filter, which
the header line names while it is on (see "Filtering the sidebar").
`--header-counts` writes what follows the label, `Completed · 5 · • 2`:
the rows drawn under the header, each root
with its live descendants, then, only when some hold unread output
(`--unread-p`), a `•` and how many, the two drawn together in
`agent-shell-vertico-sidebar-unread-dot`; the rest of the counts are
`-header-count` grey. `--insert-node-line` and `--insert-project` append
the label face, so the counts' own colours win. A
project header reads `NAME · N · • U` and keeps `--project-summary`'s `✻ A`
at its right edge; `--project-header-line` keeps both counts whole and
shortens the name. `A`
counts by `--waits-p` across each root's family: the attention band less the
sessions nobody has prompted. The three counts differ on purpose: a header's
`N` counts every row drawn under it, the Needs input tooltip names every
session of the attention band, the unprompted ones included, and `A` and the
mode line count only who asks the reader something. The state view places a
family by its most urgent band, so a session is drawn in its own band's
section or an earlier one: whoever is in the attention band sits under Needs
input unless its family is pinned. `--mark-attention-count` puts the
attention tooltip (`--attention-tooltip`, naming those sessions) and a
`keymap` running `agent-shell-vertico-sidebar-jump` on mouse-1 on the Needs
input count alone, so a click on the label still folds the section. The
jump visits `--needs-attention-p`, which also takes an unread idle session the
band does not count: the two answer different questions, and the jump was
left as it was. `agent-shell-vertico-sidebar-mode-line-mode` counts as `A`
does: `--attention-titles` keeps the live sessions `--waits-p` answers for,
pinned ones included and unprompted ones not, and the count goes into
`global-mode-string` as an `(:eval ...)` entry with its own tooltip and click,
read from the live sessions because the sidebar need not be open, and cached
for a second because a mode line redraws far more often than a session
changes. `--session-statistics`
and `--statistics-slots` remain only for the jump's message when nothing needs
the reader.

**Pinning a session.** `pinned` is the opposite of `snoozed`, and the two
cancel: pinning wakes a session and snoozing unpins one.
`--compare-buffers` asks whether a session is pinned before it asks whether it
is snoozed, so whatever the sort a pinned session leads. The state and project
views draw pinned sessions under a Pinned header, which counts them; the band,
and so the mode line's count, is unchanged.

**Resuming from the sidebar.** `agent-shell-vertico-sidebar-resume-past`
(`H`, `gh` under Evil) resumes a past session of a project through the
transcript module's reader, which it requires when called, as
`agent-shell-vertico-open-transcript` does, so the sidebar still loads with
the core alone. `--resume-project` picks the project: the session row or
project header at point, else the session in the window used last
(`get-mru-window`, as `-focus` returns to it; not
`--rendered-focused-session`, which is nil while the sidebar is selected),
else `--read-project`. A session's project is the directory it started in,
so a session started in a subdirectory offers the transcripts recorded
there. A prefix calls `(agent-shell-vertico-transcript-resume nil)`, which
offers every project; forwarding the prefix would instead ask for one.
Claude Code's picker was adopted and its past-session rows were not:
everything in the sidebar is keyed by a live buffer, and loading the store
does not belong on the render path.

**Peeking at a session.** `agent-shell-vertico-sidebar-peek` writes
`--peek-text` (title, status, age, NEEDS, the last message) into `*Agent
Shell Peek*` and shows it in a side window on the sidebar's side, slot 1,
which it selects. Showing the message is reading it, so it calls
`--mark-seen`. `r` reads one line and sends it with `--send-prompt`, so the
reader stays in the peek; `RET` opens the session through
`--display-session`. The peek remembers its session in `--peek-session` and
refuses once that buffer is dead.

**Answering from the peek.** Bill's rule is that the peek answers as
agent-shell's own prompt does, so it keys what it shows the way agent-shell
keys it: a permission request takes `y` (allow), `n` (reject) and `!` (always
allow), by option kind, the first option of a kind only; a form takes a digit
per option, numbered by agent-shell's `--option-controls`, and `d` declines.
agent-shell rejects with whatever key interrupts the shell, falling back to
`n`; the peek always uses `n`. Rejecting also stops the session with
`(agent-shell-interrupt t)`, as agent-shell's prompt does. A request the agent
marks `defaultToNo` gets no key for its allow options in agent-shell, so a
stray key cannot approve; the peek keeps the keys but asks `y-or-n-p` first
(`· asks first`), and shows the request's reason. The peek draws one request,
`--peek-ask-for`'s answer stored in `--peek-ask`: a permission before a form,
the newest of each (see the job fields), with `+N more` for the rest. A key
answers that drawn request, never one that arrived since, and the request is
checked to be still pending after any confirmation and right before sending,
because the shell, or an interrupt, can answer it while `y-or-n-p` waits.
Permissions go through the internal `agent-shell--send-permission-response`:
the public responder hook runs before a request is drawn, and pressing the
shell's button keymap cannot name a request. It needs no particular buffer,
but the interrupt after a reject does, so both run with the session current.
A form is answered from the peek only when it asks one pick-one question,
counted with agent-shell's `--answerable` (a free-text answer arrives as a
companion field folded into its select, so counting fields would refuse every
AskUserQuestion); a digit runs `agent-shell-elicitation--perform` with the
pick and then with `submit`, both with the session current because that is
the buffer `--perform` acts on. agent-shell's form waits for `y` after a pick;
the peek submits at once, as its permission keys do. Any other form says to
answer it in the session, and only `d` works on it. The peek draws `waiting
AGE` while the session waits, from the `waiting-since` slot (restamped by each
request, so it ages from the newest, which is the one drawn). `i`, and `I` in
evil, stops the session through `agent-shell-vertico-interrupt-session`, so
agent-shell's confirmation applies; a reply of `/stop` does the same when the
session is busy, blocked or in the background and is refused otherwise, as
agent-shell has no `/stop` to send. Both refuse a session whose agent is not
`--live-p`, as the answer keys do: the cancel goes through
`acp-send-notification`, which starts a client that is not running, so it
would bring a dead agent back for a session it never had.
Whether a `session/cancel` outside a turn
stops background work is the agent's business. The peek redraws itself:
`--handle-event` ends with `--peek-note-event`, which redraws at once on the
events that change what the session asks and coalesces the rest, streamed
chunks above all, on a half-second idle timer. `error` is the exception: it
redraws from a zero-delay timer, because agent-shell emits it before it
clears its busy flag, and a redraw inside the emit read the failed turn as
Working (`--settled-status` answers the same problem for the notification).
agent-shell runs subscribers
with the shell current and reduces their errors to a message, so the redraw
switches to the peek itself and is wrapped in `with-demoted-errors`.
`--peek-refresh` keeps point and every window's point and start by line and
column, draws `Session ended` once the session is gone, and is bound to `g`
(and is the peek's `revert-buffer-function`). The sidebar's minute timer runs
only while the sidebar is visible, so the peek has its own 30-second timer,
running while the peek is shown. A request that arrives while the peek is the
selected window still marks the session unread and notifies: the peek is not
the session, and `--session-focused-p` is left as it is.

**Sending a prompt from outside a shell.** Every prompt the package submits
from a buffer that is not the session's goes through
`agent-shell-vertico-sidebar--send-prompt`, which runs with the session
current. Do not simplify that away: `agent-shell-insert` decides where text
goes from the *current* buffer, and from anything but a shell buffer, with
`agent-shell-prefer-viewport-interaction` set (as Bill has it), it hands the
text to the viewport, which signals "Not yet supported" for `:submit` and
`:no-focus`. That is how `r` in the peek failed. The helper calls the fork's
`agent-shell--prompt-send`, the shell's own send: an idle session submits, a
busy one steers or queues by `agent-shell-busy-submit-default-function`
instead of failing with "Busy, try later", and a session with no ACP session
yet submits once `prompt-ready` arrives. Without that function it falls back
to `agent-shell-insert` from the shell buffer. The stub `agent-shell-insert`
keeps upstream's viewport rule, so a caller submitting from the wrong buffer
fails in the tests as it does for real.

**Which session needs attention.** `--unread` is the second axis: a buffer to
the time its unread output arrived, where presence is the whole record. It is
set from the `agent-shell` event subscription in `--handle-event` (a finished
turn, a permission request, an error), plus `--out-of-turn-settled` for output
that arrives with no turn in flight. It is cleared when the reader actually
looks at the session, which `--session-focused-p` decides by comparing against
the selected window's buffer on a focused frame. Being merely current is not
enough: any code that does `with-current-buffer` on a session would otherwise
mark it read. `--needs-attention-p` joins the two axes: unread output, or a
`blocked` status, unless the reader has snoozed the session (see below). A
session nobody has prompted sits in the attention band, but its status is
`new`, not `blocked`, so it needs attention only once it holds unread output;
`--waits-p` is the band-side counterpart that leaves it out of the counts.
Blocked is deliberately not recorded — the session reports itself blocked for
as long as it waits, so reading the status is the whole answer and no record
can go stale.
Reading a blocked session therefore drops its unread mark and leaves it in the
attention tier, which is right: it still owes a permission decision. The one
place the axes are not independent is that a working session is never unread.
A prompt clears the mark (`input-submitted`), and so does an out-of-turn burst
that makes the session `busy` (`--note-out-of-turn`): what it produced before
is superseded by what it is producing now. A burst beside a pending decision
leaves the mark, since the session still waits for the reader. When the burst
settles, `--out-of-turn-settled` marks the session again at the burst's own
time, so the row joins the back of the unread queue. It does so silently when
the burst cleared a mark, because quiet cannot tell a paused message from a
second wave; reading the session mid-burst (`--mark-seen`) forgets that, so
what the burst leaves is announced. This used to defer the mark instead,
handing it back at its old age once the session went quiet; the user chose
clearing. `--unread-for` still holds a record back while `--raw-status` says
`busy`, as a guard for any path that leaves one in place.
`mark-unread` refuses a `busy` session for the same reason. The `priority`
sort puts the attention sessions first, and they are two tiers rather than one
(`--status-rank-for`): unread output, then a `blocked` session the reader has
already seen. Ranking
them together oldest-first pinned every jump to the blocked one, whose wait
always began before any turn that has finished since, and arriving settles
nothing that a permission decision does not. Both tiers run oldest-first, as the
working and snoozed ones do (`--oldest-first-rank-p`), so
`agent-shell-vertico-sidebar-jump` visits the head of `--sort-buffers ...
'priority'` and nothing else has to rank them again. The jump passes over a
session the reader is already in, which after the split only a blocked one can
be, and says so rather than not moving (`--attention-here-message`);
`--statistics-slots` folds the two ranks back into one attention count for the
jump's message when nothing needs attention.
`agent-shell-vertico-sidebar-mark-unread` is the only mark the reader sets by
hand, and it writes the same record the events write, so status names, bold
titles, ranks, counters and the jump order need no case for it. The unread
tier is a queue in the order sessions became unread, and the jump pops its
head, so the command stamps the current time: the session joins the back,
behind every session already waiting, and one that is unread already moves
there too, which is how a row is put off without being read. That was the
user's call; an earlier version stamped the last activity time to undo an
accidental read in place. It refuses a `busy` session, whose turn has produced
nothing to miss. It does not fight the clear paths, which would still
read the mark away the next time the reader is seen in the session, so
marking the session the selected window shows moves the reader out of it
instead (`--leave-unread`): to the head of the attention queue, as the jump
picks it, else the session last left in the jump history, else the sidebar
on the marked row. A prefix argument stays, and marking from a sidebar row
or the jump's dispatch moves nobody, since the reader is not in the session.
`agent-shell-vertico-sidebar-mark-read` is the same record in reverse
and refuses nothing, because the unread mark is now the only thing it can drop:
a blocked session keeps its place through its status and a failed one stays
failed. Both commands resolve their session through `--attention-target`, which
reads the sidebar row at point when called there and the current buffer's
session, viewport included, anywhere else.

**Putting a session off.** Snoozing is a third record, `--snoozed`, beside
unread and failed, because the reader saying "later" is neither reading a
session nor being done with it: `mark-read` lost the reminder and leaving it
unread kept it at the head of the list. It is not a value of `--unread`, so
snoozing leaves that record alone, and waking a session hands back whatever it
held at the age it had. `--needs-attention-p` answers nil for a snoozed session,
which is the one change that takes it out of the jump and
`--attention-sessions`; `--band-for` files it `snoozed` before anything but an
active tempo, which takes it out of `--waits-p` and so the mode line and a
project header's `✻` count; `--notify` skips it too. The snoozed sessions
are a second party below the rest, whatever the sort: `--compare-buffers` asks
whether a session is snoozed before anything else, and each party keeps the
sort's own order. `--status-rank-for` still gives it a rank of its own, 4, so
the snoozed party runs oldest-snoozed first under `priority`, `--priority-time`
asking the snooze time before the unread one. `--insert-sessions` marks where
the party begins, in every sibling list (a section's sessions, a project's
sessions, a parent's children), with an overline on the first snoozed row's
first line rather than a line of its own, because a line with no session on
it is one every motion and row count would have to step over. The newline
carries it with `:extend`, since rows are not padded; its colour is the
foreground of `-snoozed-rule`, because a plain overline takes each glyph's
colour. A terminal
draws no overline, so there the split is the order alone. A project whose
sessions are all snoozed sorts below the others, since `--sort-groups` compares
groups by their first session. In the state view the snoozed sessions are a
section of their own, folded by default, and the rule is not drawn there: it
marks a snoozed row only below an awake sibling. What ends a
snooze is dealing with the session or a new ask: `input-submitted`, a
`permission-request` or an `error` (the agent cannot go on without the reader),
`mark-unread`, or the command again. Looking at it, `mark-read`, a finished turn
and settled out-of-turn output all leave it alone. `--snoozed-for` is to the
snooze what `--unread-for` is to unread: a working session is drawn and ranked
as working, the record kept for when it goes quiet; the command refuses one for
the same reason `mark-unread` does. A timed snooze was left for later: the
record's presence is the whole answer today, and a timer would only add a way to
end it.

**Work behind a prompt.** `background` is an idle session with a subagent or an
async task still running: `agent-shell-status` calls it ready, because no turn
is in flight, and it does take a prompt, which is what separates it from `busy`.
agent-shell emits no event when either kind starts or ends, and agent-shell is
not to be changed for it, so `--background-work` reads the session's state
directly — a subagent in `:native-subagents` runs until its record gains
`:ended-at`, an async task in `:async-tasks` until its `:state` is terminal —
and answers `(SUBAGENTS . TASKS)` or nil. Every kind counts alike, a dev server
with a subagent, because nothing in a task says whether it will end; that is
also why the unread mark is not held back by it: holding a mark back until the
work ends would hold it forever behind a server. What it does add is one
notification. A turn that ends with work running (`--background-at-turn-end`)
usually says only that the work started, and its mark would silence the report
that follows, since a burst that clears an unread mark announces nothing; so
the first burst to settle once nothing runs is announced anyway, once, and the
mark takes its time. A server that never ends never releases it, which leaves
the report silent as it would be without this, and blocks nothing.
`--raw-status` overlays it after every other idle overlay, in the order its
docstring gives:
a pending permission, an out-of-turn burst, `failed` (a failure says more),
`starting`, `stopped`, the `blocked` state and `new`; a dead agent process is
asked before all of them, and `--background-work` answers nil once the process
is gone, because nothing runs behind a dead agent though the records never
reach an end. That is also how the two-second poll notices an agent that died
with work running: the signature empties and the render reports the exit. It
stamps `--background-since` through `--track-background`, since async tasks carry no
spawn time of their own; the tier (rank 3, between working and snoozed) runs
oldest-first from that stamp. Polling was chosen over an `:after` advice on
`agent-shell-subagents--changed`, which would be exact, because it depends on
the state's shape rather than a function's name. Work starts inside a turn,
whose events render anyway; work ends silently as often as not, so
`--ensure-background-refresh` runs `--background-poll` every two seconds while a
render drew something running and the sidebar is visible, comparing
`--background-signature` against `--rendered-background` and scheduling a render
on a difference. The other internal read is `agent-shell--subagent-group`, which
agent-shell binds around the dispatch of a subagent's notification — the same
dynamic extent its subscribers run in — because it emits a subagent's messages
and tool calls as the root's events with nothing in them saying whose they are.
`--subagent-event-p` keeps those out of `--out-of-turn-p` and
`--record-message-chunk`, so a streaming subagent reads as `background` rather
than a Working burst, and never becomes the notification's `:last-message`.
`--background-line` draws `2 subagents · 1 task` under the row whenever
something runs, details shown or not, with the `subagents` and `tasks` slot
icons, and `S` runs upstream's `agent-shell-subagents` in the session, as
does activating that line (it is the `subagents` field), since a task has no
buffer to open and the list reaches every subagent's. In
Claude Code's terms a session in the background is in flight, so `--band-for`
files it as working, and its star is blue without spinning.

**Nesting a side conversation under its parent.** A side conversation
(`agent-shell-side`) is an ordinary `agent-shell` buffer, so without this it
would sit as its own row wherever the sort put it. `--render` partitions the
live buffer set into `roots` (everything with no live parent, via
`--parent-of`) and inserts each root through
`--insert-session-and-children`, which draws the root's own row and then
recurses over `--children-of` sorted by the same
`agent-shell-vertico-sidebar-sort-by`, one level deeper each time — so a
parent's children sort among themselves and never affect where the parent
lands among its own siblings. Grouping and the top-level sort run over
`roots` only, exactly as before this feature, with one exception: the state
view files a root by the most urgent band in its family (`--family-section`),
so a child's state can move its parent's section but never its place in the
sort.
Indentation, which used to be a boolean (`nested`, under a project header or
not), is now a depth count, one step per parent; a header adds none, since
headers stopped indenting what they hold; `--content-width`
and `--insert-row` both take the count directly, while `--session-lines`
keeps `nested` for the unrelated question of whether the row's own
project line would repeat what a header above it already says — a project
header and a parent's own row answer two different questions and can each be
present without the other. A child whose parent has died promotes itself for
free: nothing records the family relationship on this side, `--parent-of`
just stops finding a live parent on the next render, and the child falls
into `roots` like any other session. `agent-shell-side-parent-buffer` and
`agent-shell-side-children` are the only two functions this reads, added to
that package as public API for this purpose; both answer nil once
`agent-shell-side` is not loaded, so nesting is a silent no-op without it,
the same convention `--live-status` already uses for `agent-shell-status`.

**Jumping to a session by key.** `agent-shell-vertico-sidebar-jump-by-key` is
the `ace-window` model: assign labels at trigger time, show them where the
reader is already looking, read one key. The sidebar is the only rendering, so
`--read-jump-target` first draws it in the configured view with every project
and section open: a hidden sidebar is displayed for the read and its window
deleted after. Around the render, `--expanded-projects` and `--section-folds`
are let-bound to nil, `expand-by-default` to t and `folded-sections` to nil,
so a folded session has a row too, without writing to the reader's folds.
`--filter` is let-bound to nil beside them, so a filtered-out session
has a row and a key too: the keys count what `-jump-to-index` counts,
filtered or not, the rule "Keying a parent's children" records.
Every exit path renders again under the original folds, including the aborts,
which is also what repairs a sidebar shown on another frame: the buffer is
shared, so the open-folds render reached that frame too. The folds themselves are
never touched. Labels come from
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
could not be relied on to do. The label face inherits `default' last to hand
back the ordinary background and the frame's own font and size. The colour is
red, from `error', because `--dim-overlays' leaves nothing else in the mark
column red: the only other red there is a failed session's star, which is the
character a key replaces, and a row that carries no key is dimmed. The action
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
`--jump-in-progress` is bound; that flag is bound only after the open-sections
render the jump itself needs, and the cleanup render is what acts on the dirty
mark.
An erased buffer leaves each label overlay empty rather than gone, so the
tests assert the span and the character under it, not the overlay's existence.
Keys are positional on purpose: under `priority` sorting rows move, so a
per-session sticky key would need a persistent label column to be readable,
and that is a separate feature.

**Keying a parent's children.** `--read-jump-target` keys every session
row, a side conversation's as much as its parent's, so the keys count the
rows `-jump-to-index` counts and one press reaches any session. An earlier
version keyed only `roots` and drilled into a chosen parent's children in a
second read; that made a child unreachable by the key on screen while
`jump-to-N` landed on it directly, and the user chose the consistent answer.
Children therefore spend keys from `agent-shell-vertico-sidebar-jump-keys`
like any other row.

**Jumping to a session by position.** `--jump-to-index` is the blind jump the
`agent-shell-vertico-sidebar-jump-to-1' family is bound to, and it answers a
different question from `-jump-by-key': nothing is drawn, so there is nothing
to restrict to the rows on screen, and it reads `--display-order` rather
than a rendered sidebar it would have to open. It once read the flat
`--sort-buffers`, which agreed with the rows only while a flat view
existed; under the state view an unread finished session led that sort
while the sidebar drew it under Completed, so `jump-to-1` landed on a row
further down. A sidebar filter changes nothing here, as a fold changes
nothing: every live session counts. Positions count from 1,
so a command's number is the key a user binds it to, unlike
`+workspace/switch-to-N' which is 0-based behind 1-based keys. The commands
are generated with `defalias' over a `dotimes' exactly as that family is,
because a named command is bindable in a `map!' without a lambda and findable
through `execute-extended-command'; each closure captures its own index, which
a test pins by calling three of them. The index is deliberately not a stable
name for a session: a session moves between sections as its state
changes, and under `priority' the act of jumping reads the session and
moves it within its section, so the same key answers differently next
time. That was the user's call, a quick jump
rather than an address, and it is why the reading jump exists beside it.

**Stepping along the rows.** `agent-shell-vertico-sidebar-next-session`
and `-previous-session` move one row from the session in the selected
window (`agent-shell-vertico--current-session`, so a viewport counts),
wrapping at both ends; from a buffer that is no session they start at the
top or bottom row. The order is `--display-order`, the walk `--render`
makes without drawing it: the roots, grouped by state section or by project
as `agent-shell-vertico-sidebar-group-by` says, each followed depth-first
by its children, the same order `-jump-to-index` counts in. A folded
section or project still lists its sessions, because nothing is drawn, and
so does a filtered sidebar. The order is asked again on every step rather
than kept for a run of presses, so
under `priority` the session just read may have moved by the next step. That
was the user's call, the same trade the index jump makes.

**Retracing the jumps.** The jump history lives in the core module, not
the sidebar, because it is not the sidebar's question: `--jump-history`
is the sessions the reader has left, most recently left first, and
`agent-shell-vertico-jump-back`, `-jump-forward` and `-jump-history` walk
it as vim's `C-o`, `C-i` and `:jumps` walk theirs. What is recorded is a
*departure*, however it happened, which is evil's rule for a buffer
crossing: `--jump-track` runs from `window-selection-change-functions`
and `window-buffer-change-functions` (both, because switching buffers in
place leaves the selected window alone), compares the selected window's
session against `--jump-current`, the session the reader was last seen
in, and pushes the old one when they differ. So `C-x b`, `other-window`,
a click, a workspace restore and every package command all feed one list
and none of them records anything of its own. An earlier version
recorded inside `--display-session` instead, so only package commands
counted, and guessed the departing session from `buffer-list` when a
jump was taken from a file; the guess made standing beside a session the
same as standing in it, and back from a file skipped the session just
left. A viewport counts as its session (`--current-session` resolves it
through upstream's `agent-shell--current-shell`), and the minibuffer is
not a departure, or `M-x` and cancel would move the session to the head
and end a retrace.

A session is held once, `--jump-push` dropping its older entry, as vim
keeps one entry per position: two sessions read back and forth would
otherwise bury everything older under themselves.
`agent-shell-vertico-jump-history-size` is therefore close to
decorative — the list is bounded by how many sessions are live — and is
kept for the reader who has more than they care to retrace.
`--jump-position` names where the reader stands in the list, as a buffer
rather than an index, because entries drop out whenever a session is
killed and an index into a list that shrinks under it would point at
someone else. Nil means no retrace is in progress. A retrace
(`--jump-display`) sets `--jump-current` to the session it displayed, so
the redisplay that follows finds the window showing what the tracker
already expected and records nothing; that is how back and forward
retrace one list instead of each other's steps.
`--jump-pin-current` is what lets forward return: the session a retrace
starts from is pushed to the head and the position stood on it, exactly
as `C-o` pushes the position it starts from. It declines when the
position already names the session the reader is in, since re-pinning
would move that entry to the head and turn the next step back into a step
forward; a position naming another session is stale — they got there some
way the history cannot see — and pinning corrects it. It returns nil when
the selected window shows no session, and `jump-back` then goes to the
head of the list rather than to a neighbour: a file is not an entry, so
there is nothing to pin and nothing to step past, and the reader is
asking to be returned to the session they left. The one thing evil can
do here that this cannot is step forward from that session back to the
file, since a file is not an entry; that limit is accepted rather than
letting files into a list of sessions. The reader offered by
`-jump-history` leaves out the session being read, so its first
candidate is what back would display, and it passes `identity` to
`--table` (and binds `--group-by` to nil) because its own order is the
answer rather than `agent-shell-vertico-sort-by`.

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

**Drawing a session.** Every session is Claude Code's star, and the face
says the state; `--mark-glyph` and `--mark-face` read both from the
snapshot. The glyph is `✻`, a still `●` for an active session when
`agent-shell-vertico-sidebar-animate-busy` is off (so working keeps a shape
of its own), and `∙` when `--live-p` says the agent process ran and exited;
the dot takes the face of the status the exit overlay answers, so it is red
when the exit failed the session and keeps a finished turn's colour otherwise.
The face follows this table, first match wins: purple
(`-snoozed`) for a snoozed session, yellow (`-blocked`) while it waits for
the reader, a session nobody has prompted included since its tempo is
`blocked`, blue (`-working`) while active or in flight, red (`-failed`) for
a failed turn, green (`-ready`) for a finished one, and grey (`-detail`)
otherwise, which is a stopped turn. Yellow, red, green and grey are Claude
Code's (`jn`, m0744.js:3378-3385); blue is not. Claude Code draws a working
star in no colour (m0744.js:3382) and sets it apart by dimming every row but
the focused one, which this sidebar does not do, so blue is kept; the
`-working` face is the setting for anyone who wants Claude Code's look, and
its docstring says what that costs (a session with work behind a prompt does
not spin, so its star would read as idle). Purple
because grey was taken: `-snoozed` inherits `link-visited` for its colour
alone, and the row's title recedes into `-snoozed-title` (`shadow`) so the
rows still asking stand out. Unread is not a mark colour: it is a bold title
(`-unread-title`) and a `•` before the age (`--title-suffix`), so a snoozed
session holding unread output is both purple and bold. The dot has a colour
of its own, magenta (`-unread-dot` inherits `ansi-color-bright-magenta`, as
`-working` inherits the blue, with the background the ansi face would paint
taken away), because no mark is drawn in it: a dot in the mark's colour was
lost beside a green star. The dot exists
because the `priority` sort still lists unread sessions first, so a section or
project puts a green finished row far above another one; a bold title alone
did not say why. Every mark is a plain
character, so no icon font is needed and a terminal draws what a graphical
frame does. The other glyphs are slots in `--icons` drawn by `--slot-icon`:
`⌂` project, `↳` message, `◇` subagents and `$` tasks.
The
fringe marker for the sessions on screen is derived, not stored:
`--current-sessions` lists every session, or viewport, a window of the selected
frame shows, and nothing else. The selected window alone would be too narrow,
because moving to the sidebar, a file or magit beside a session does not leave
it; a session absent from the frame, or on another one, is unmarked. This is
only the marker: unread still needs the selected window (`--session-focused-p`),
because seeing a session in a side window is not reading it. The render caches
what it drew in `--rendered-current-sessions`, and the selection and
buffer-change hooks compare against that cache as a set, so a window
rearrangement showing the same sessions redraws nothing and the cache can never
disagree with the windows for longer than one idle refresh.

**Which of them you are in.** A frame showing several sessions leaves the
marker unable to say which one the reader is typing into, so the marker has
two tiers: `--focused-session` picks one out of `--current-sessions` and
`--current-session-marker` draws it differently. The two tiers share one
bitmap and differ in colour alone: `-focused-session` is magenta, the
unread dot's accent (`ansi-color-bright-magenta`, its background taken
away so the bitmap is not drawn on a block), and `-current-session` is
`shadow`. A colour a session's mark is drawn in, blue, yellow, red, green or
purple, would say something untrue about the session; `shadow` is what the
package already uses for what is present and not the answer. The focused
tier used to inherit `outline-1` as the one accent with no status meaning,
but many themes, snazzy among them, draw that level in the working blue.
Magenta is now the one accent in two senses, output owed to the reader on
the dot and where the reader is on the bar, and the two can meet on a row:
the bar follows the selected window, while unread clears only on a focused
frame. This
is `gptel-highlight-mode`'s own pair, which separates a response from a tool
call the same way, and one bitmap serves both: an earlier version drew the
focused tier on a four-pixel bar too, on the argument that a bar a pixel or
two wide cannot be trusted to carry a hue difference, but the wide bar read
as a block beside its neighbours rather than as the same mark drawn harder,
which is the fault a second hue was avoided for. The bar is solid: the thin
one used to be dashed, which at that width is a column of dots whose phase,
under `center` alignment, differed from one marked row to the next. The
focused session is read from the selected window and nothing else: the
session whose buffer or viewport it shows, and none beside a file, magit or
the sidebar, where every visible session is grey. An earlier version
remembered the last session window selected so that stepping into the
sidebar kept the accent, but the memory was one global across frames and
workspaces, so a workspace whose session had never been clicked into showed
grey while another with the same layout showed the accent; the accent meant
history, not state. Deriving it from the selected window makes the same
layout always draw the same way, and a session off the frame is not marked
at all, so the stronger marker never outlives the weaker one it
strengthens. It is the same question as `--session-focused-p` asks about
what has been *read*, without that one's insistence on a focused frame. The
render caches it in `--rendered-focused-session` and the hooks compare it
separately from the set, because moving between two sessions already on the
frame, or from a session to a file beside it, changes the drawing without
changing the set.

`agent-shell-vertico-sidebar-marker-method` says *where* the bar is drawn,
mirroring `gptel-highlight-methods` for the same reason gptel offers the
choice: a terminal frame has no fringes, so under `-nw` a `fringe` marker
draws nothing. The default, `auto`, is resolved by `--marker-method`:
`margin` while any window on a terminal frame shows the sidebar, `fringe`
otherwise. One answer serves every window, because the marker is text in
the one buffer, so a sidebar on a graphical and a terminal frame at once
spends a column in both; the choice cannot be made per frame in the
display spec, whose `when` condition is evaluated with the selected frame
rather than the one being drawn. A terminal frame starting to show the
sidebar runs the window-configuration hook, whose `--apply-marker-space`
reserves the margin and offers the frame to the resize render that redraws
the markers. `margin` draws the same two-tier bar as a
`▎` in the left display margin instead, at the cost of the column the
window reserves for it. Both are a `display` spec on one space used as a
`line-prefix`, so neither costs a column of the text area itself.
`--apply-marker-space` reserves the margin column, or a left fringe at least
as wide as the bitmap (`--fringe-bitmap-width`) in graphical sidebar
windows. It runs before the render measures `window-body-width`, which
excludes both areas. Margin changes re-show the buffer, because that is
when a window reads `left-margin-width`; an unchanged width leaves point and
window-start alone. Fringe repair uses `set-window-fringes` instead,
preserving wider left fringes, the right fringe's width, point and
window-start; what to set is decided by `--marker-fringes`, a plain function
of `window-fringes`'s answer, because batch Emacs has no graphical frame and
the tests that drive real fringes skip there. The window-configuration hook
also applies it to restored windows and offers every frame showing the
sidebar to the resize callback when a width changed (the hook names no
frame). That offer is required, not redundant: Emacs records window sizes
after the configuration hook runs, so `window-size-change-functions` never
sees a width the hook changed. Together they keep a workspace saved with no
fringe from hiding the marker indefinitely.

**Spinning a working mark.** An active session's star is animated by an
overlay over the still glyph, one per row whose TEMPO is `active` (`busy` and
`starting`), placed at the end of `--render` from the snapshots it already
has and redrawn by `--animate-busy` on a repeating timer. Overlaying rather
than re-rendering is what makes it affordable: a full render erases the
buffer, re-sorts, and re-anchors every window, while a beat only swaps each
overlay's `display'. The still glyph stays underneath, so a sidebar that never
animates — the setting off, no timer yet, a beat suppressed — reads exactly as
it did before. `--busy-frame` answers what a mark shows on a given beat, a
string from `agent-shell-vertico-sidebar-busy-frames`, by default Claude
Code's own spinner `· ✢ ✳ ✶ ✻ ✽`, which grows a dot into the star every other
session is drawn with. Every frame is one column, the width of every other
mark, so a beat never moves the title. The tick counter is one per sidebar,
so every working mark spins in step; a per-session phase would have to come
from `agent-shell''s heartbeat, which is its business rather than something
to read a frame number out of. A jump gives the cells up: `--read-jump-target`
clears the overlays and cancels the timer before binding
`--jump-in-progress`, because its keys are drawn over the same cells, and
`--animate-busy` returns early under that flag the way `--render` does. The
timer is armed by `--ensure-busy-refresh` from the same two questions that
stop it — an overlay to animate and a window to see it in — following
`--ensure-age-refresh`. Only rows spin: header counts are digits, and a
project's `✻` count reports only what asks for a reply.

**Where point rests.** A row's leading icon and the gap after it are one
field (`--mark-field`, the `agent-shell-vertico-sidebar-mark-field` text
property): the status mark, the home on a row's project line, the arrow on
a message line. Headers carry no icon, so none of a header is a field.
Standing on one says nothing, and the sidebar draws no cursor to say where
point is, so `--keep-point-off-marks` moves point past it from
`pre-redisplay-functions`, which answers for every way point arrives
there — a click, an arrow key, a workspace package restoring a layout.
It moves forward only; `cursor-intangible-mode`, which this was at
first, moves point in whichever direction it was already travelling, so
moving up a list carried point past the row it had moved to and the row
above answered for it. It also took the sidebar down: with `<` it
compares point against a window parameter that
`cursor-sensor-move-to-tangible` sets only after a run that did not
signal, and `window-state-put` does not carry that parameter, so a
window a workspace switch restored with point on an icon signalled on
every redisplay and never set it. Errors are demoted in the replacement
for that reason. `--row-point` is the same answer for code rather than
for redisplay: `--goto-node`, `--move-to-row` and the render's point and
window-point restores all land on the row's first character of text, so
a command never leaves point somewhere redisplay has to correct. What is
*not* a field is a project header's count, which sits at the right edge
with nothing after it to move point on to.

**Notifications.** `agent-shell-vertico-sidebar-notify-function` is called
wherever an attention mark is set, never for a focused session. It receives
`:buffer`, `:agent` (the agent's display name), `:status` (the same word
the sidebar shows for the session, never a read state), `:state` and
`:needs` (Claude Code's STATE and NEEDS from `--job-state`, so a channel can
say what a waiting session asks), `:unread` (whether the session holds output
nobody has read) and `:last-message`. An agent process that exits is reported
once by `--note-exits` when the exit is what failed the session (see "When the
agent process dies"). The `error` report passes `--notify` its status rather
than letting it read one: agent-shell emits `error` before it clears its busy
flag (agent-shell.el:5522 before 5534), so `--raw-status` would still answer
`busy`, and the report would say `Working` with `:unread` nil, since
`--unread-for` holds a mark back from a busy session. The branch asks
`--idle-status`, the idle arms of `--raw-status` split out for this, or
`--exited-status` once the process is gone. A request still pending when a
live agent's prompt fails would make that report `Waiting`. That stale request
is agent-shell's to clear, on its prompt's failure path as on the success
path, and the fix belongs in the agent-shell fork; the sidebar keeps no record
of its own for such requests.
The message is accumulated in `--record-message-chunk` from the events the
sidebar already subscribes to, because `agent-shell` emits one event per
streamed chunk and keeps none of them; any other event ends the message,
and so does a burst going quiet (`--close-message`), because two waves of
chunks carry no event between them and the second would otherwise repeat
the first.
Text is passed on unshortened, so trimming and markup stripping belong to
the caller's channel, not here.

**Filtering the sidebar.** `agent-shell-vertico-sidebar-filter` (`f`)
reads a filter in the minibuffer and applies it on Enter, one render, with
no live update; empty input clears it. The string is kept in the
buffer-local `--filter`, so it applies on every frame showing the sidebar,
and every render reapplies it, so a session that stops matching leaves.
`--filter-parse` reads Claude Code's prefixes, `s:` `n:` `o:` `a:`, plus
`p:` for the project; a prefix with nothing after it is dropped and an
unknown one is free text. `--filter-match-p` asks every part, case aside:
`s:` starts the status word or the label of the session's own section or
band, never the STATE field, which says `done` for a session waiting on
the reader, and a snoozed session answers to Snoozed alone, so `s:done`
keeps neither; `n:` is in the title or the last prompt, as Claude Code
matches a name or an intent; `o:` is in the newest message, the result or
the error, since only the newest message is kept; `a:` starts the agent's
name, the prefix rule the agent narrowing keys use, though not their
function, which takes a key character; `p:` is in the project name; free
text is in the title, the detail line as `--detail-for` draws it, the
project name or the last prompt. The snapshot answers all but the last
prompt and the newest message, which are read from the session.
`--render` calls `--forget-empty-section-folds` on every root before
filtering, so a section the filter hides keeps its fold, then keeps a root
when any member of its family matches and draws the family whole. A
family is still filed by `--family-section`, so a matching idle parent of a
working child is drawn under Working. Headers count what they draw. While
filtered, the insert phase let-binds the four fold variables the key jump
binds, so every header is open and no fold table is written; toggling a
header is refused, as Claude Code ignores Enter on a header while
filtering; `--view-level` has no header level and `--set-view-level`
writes no fold, so `S-TAB` steps between rows and details alone. A filter
matching nothing draws `No sessions match FILTER`. The header line names
the filter and how many sessions it shows of how many, a deliberate
exception to "header-line-format stays nil": it is no node, never scrolls
away, and goes when the filter does. Reveal (`-focus`, `--leave-unread`)
clears a filter hiding its target, since the reader asked for that
session. The jumps, the mode-line count and notifications ignore it; a
header's Needs input count follows it, since it counts what is drawn.

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
passes wins over the table's, and both name the same function. The
sidebar filter is their counterpart for the sidebar, whose rows no
minibuffer reads; it shares the agent prefix rule but not the functions
(see "Filtering the sidebar").

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
