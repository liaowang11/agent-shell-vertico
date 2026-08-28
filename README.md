# agent-shell-vertico

`agent-shell-vertico` adds Vertico-friendly live-session switching and
project-aware transcript recall to `agent-shell`.

Transcript recall reads the Markdown files already managed by `agent-shell`.
It does not build or maintain an index. Project discovery comes from
Projectile when it is active, with `project.el` as the fallback, and transcript
locations are resolved through `agent-shell-dot-subdir-function`.

## Live session commands

- `M-x agent-shell-vertico-switch`
  Switch across all live `agent-shell` buffers returned by
  `agent-shell-buffers`.
- `M-x agent-shell-vertico-switch-project`
  Switch across `agent-shell` buffers in the current project via
  `agent-shell-project-buffers`.
- `M-x agent-shell-vertico-setup`
  Enable every Agent Shell Vertico integration.

Candidates keep the recent ordering from `agent-shell-buffers` and show
consult-style annotations for status, model, mode, title, and path.

Loading `agent-shell-vertico-consult` adds live previews to these commands,
project-scoped send commands when they ask for a session, and the shell picker
used by `agent-shell` commands. A preview reuses an existing viewport when
viewport interaction is preferred, but does not create one. The other-window
command previews in that window. Selecting a session still uses the normal
switch path, including attention handling.

## Prompt queue

`agent-shell` queues a prompt whenever the shell is busy and sends the
queue on once the agent is free. `agent-shell-vertico-prompt-queue`
offers that queue as an annotated completion category with Embark
actions.

- `M-x agent-shell-vertico-prompt-queue`
  Act on a prompt queued in the current session. Works from the shell
  buffer, from its viewport, and from any other buffer in a project that
  has a shell.

`agent-shell-vertico-setup` registers the `agent-shell-prompt-queue`
Embark category.

Candidates are the pending prompts in queue order, each showing its
first line, annotated with the line count and whatever of the prompt the
line could not show. After them come two queue-wide entries:

- `[Resume queue]` send the next pending prompt now; when the shell is
  busy the annotation says the queue resumes on its own
- `[Remove all]` drop every pending prompt, with agent-shell's own
  confirmation

Choosing a prompt edits it. With Embark:

- `e` edit the prompt
- `i` inject it into the running turn, the key agent-shell gives Inject
  in the queue's own button row. The prompt leaves the queue only once
  the agent takes it, so an agent that declines, or one without mid-turn
  injection, leaves it pending. Needs an agent-shell with
  `agent-shell-prompt-queue-inject`; an older one reports that instead
  of failing
- `x` remove it
- `w` copy the whole prompt to the kill ring
- `v` read the whole prompt in a buffer, without ending the completion
  session

Every change runs through agent-shell's own commands, so editing follows
`agent-shell-prefer-viewport-interaction` and removal keeps its
confirmation. The queue moves on its own while the minibuffer is open,
so each action locates its prompt in the queue as it stands before
acting; a prompt the agent has already picked up reports that instead of
touching its neighbour.

Loading `agent-shell-vertico-consult` upgrades the reader to a Consult
one that previews the prompt under point.

## Session sidebar

`agent-shell-vertico-sidebar` provides a compact side window for jumping
between live sessions without opening a minibuffer.  It shows a flat list by
default; `=` switches to project groups.  In flat mode, the default `project`
metadata entry is promoted to a compact context line below each title (for
example, `⌂ agent-shell-vertico`); labels prefer agent-shell's configured
project name and fall back to the directory basename.  Hover shows the full
working directory.

`agent-shell-vertico-sidebar-toggle` shows a hidden sidebar without selecting
its window and closes a visible sidebar; use
`agent-shell-vertico-sidebar-focus` to enter it.

`TAB` folds or expands a project header, or toggles metadata for only the
session at point.  `RET`/mouse-1 activates the selected row or metadata field;
the model and mode values open their selectors, while a project value opens
that directory in another window.  Groups are collapsed by default, and
session metadata is hidden by default.  `S-TAB` cycles the whole sidebar
through its fold levels, following Org's global-cycle convention: project
headers alone, then their session rows, then each session's metadata, then
back to the headers.  It discards the individual folds made with `TAB`.  A
flat list has no project level, so there `S-TAB` alternates between hiding and
showing metadata for every session.  Each title can wrap within
the narrow sidebar, up to
`agent-shell-vertico-sidebar-title-max-length` characters.
The layout measures the current sidebar body width and reflows titles when the
window is resized.  The configured sidebar width is a maximum: the window asks
for `agent-shell-vertico-sidebar-width` columns but never takes more than the
`agent-shell-vertico-sidebar-max-width-fraction` share of the frame, down to a
floor of 16 columns.  A narrow frame therefore keeps most of its columns.  An
open sidebar is held at that width: a resize timer puts the side window back
whenever it has drifted, whether the frame narrowed around it or a restored
window configuration recreated it at some proportion of the frame.  Workspace
packages such as `persp-mode` restore layouts that way, and the restore drops
the preserved size that held the width, which is why the sidebar is measured
again rather than pinned once.
Customize the ordered `agent-shell-vertico-sidebar-extra-info` list to choose
which expanded-session values are shown: `agent`, `status`, `activity`,
`project`, `model`, `mode`, and `last-user-message`.  Values are packed two
per row.  `status` and `last-user-message` are off by default: the row icon
already carries the status, and the latest prompt is usually visible in the
session itself.  Removing `project` also removes the flat context line.
Activating an agent value starts a new session with that agent in the same
project.
The default `priority` sort puts sessions waiting for attention first, followed
by working and ready sessions.  Attention and working sessions order oldest
first, so the same session `agent-shell-attention-jump` visits leads the
list, and streamed chunks do not reorder working sessions; idle sessions
order by their latest activity, newest first, so reading a finished session
does not drop it below stale idle ones.  In grouped mode, projects follow the
highest-priority session they contain.  `s` switches between priority,
activity, recency, status, and name sorting.

The sidebar follows `agent-shell` events, so a completed turn in another
window is marked for attention.  A failed request, a session waiting for a
permission response, and a session holding unseen output each get their own
mark.  Submitting a new prompt clears any of them, since the previous turn
has by then been seen.

An agent can also produce output with no turn in flight: background tasks
such as subagents keep streaming after a turn ends, and a prompt injected
too late makes the agent start a turn of its own.  `agent-shell` reports
such a session ready, because it has nothing in flight to report.  The
sidebar shows it working while the output arrives, then marks it as
holding unseen output once the stream has been quiet for a few seconds.
No completion event is sent for this kind of work, so the quiet period is
what ends it.  `o` always jumps to the session at point; the other
keys expose the same restart, kill, interrupt, model, mode, traffic, and
transcript operations as the Vertico Embark map.

Marks are drawn with [nerd-icons](https://github.com/rainstormstudio/nerd-icons.el)
when that package is available, and with plain characters otherwise.  Set
`agent-shell-vertico-sidebar-use-nerd-icons` to `t` or nil to force one or the
other.  Project folds keep their `▼` and `▶` characters either way, the
same triangles `agent-shell` uses for its own collapsible fragments.

Sessions under a project header are indented by a `line-prefix` display
property rather than by inserted spaces, so the indentation is visual only:
copying a row yields no leading whitespace, and the two reserved columns
line a session icon up under the project name.

| Meaning | Icon | Character |
| --- | --- | --- |
| Failed request | `nf-cod-error` | `✖` |
| Waiting for a permission response | `nf-cod-stop_circle` | `▲` |
| Finished, output unread | `nf-cod-circle_large_filled` | `●` |
| Working | `nf-md-dots_circle` | `◆` |
| Ready | `nf-cod-circle_large` | `✓` |
| Starting | `nf-cod-dash` | `○` |
| Working directory | `nf-cod-root_folder` | `⌂` |
| Last user message | `nf-cod-arrow_small_right` | `↳` |

Finished-unread and ready are the filled and hollow circle of one family
because they are the same session before and after you look at it: a turn
that completes while its buffer is off screen is marked unread, and selecting
that window clears the mark, leaving an ordinary ready row.

Nerd-icons glyphs fill their cell, so they are drawn with a wider gap than a
plain character needs.  A graphical frame gets half a column, the only
widening a terminal can render is a whole one, and the gap is chosen per
render from the frame the sidebar is on.

The compact activity value is the age of the last observed agent event, not
the total session or turn duration; an actively streaming session therefore
shows `now`.

The header reports the total number of live sessions and compact non-zero
status counts, each using the same mark its rows use, so a failed request, a
waiting session, and an unread completion are counted apart.  Hover a count
for its label.  Project headers summarize the same three counts for the
sessions they contain.

The sidebar hides the regular mode line and uses its compact header for these
statistics instead.

Workspace packages such as persp-mode, used by the Doom Emacs `:ui
workspaces` module, save one window layout per workspace and restore it on
every switch.  Each restored layout therefore carries whatever sidebar
state that workspace was last left in: one saved before the sidebar existed
would remove the sidebar, and one saved with the sidebar open would bring it
back after you closed it.  When persp-mode is loaded, the sidebar is reopened
or closed right after the switch to match the visibility it had before the
switch, so it stays put while you move between workspaces.  Set
`agent-shell-vertico-sidebar-follow-workspaces` to nil to leave each
workspace with only the layout it saved.

Metadata values carry both `help-echo` and `kbd-help`.  With point on a value,
`M-x display-local-help` shows its activation hint in the Echo Area without a
mouse event.  For automatic point help after an idle delay, enable Emacs's
built-in `help-at-pt` support:

```elisp
(with-eval-after-load 'help-at-pt
  (setq help-at-pt-display-when-idle t)
  (help-at-pt-set-timer))
```

```elisp
(use-package agent-shell-vertico-sidebar
  :load-path "/path/to/agent-shell-vertico"
  :after agent-shell-vertico
  :bind (("C-c a S" . agent-shell-vertico-sidebar-toggle))
  :custom
  (agent-shell-vertico-sidebar-side 'left)
  (agent-shell-vertico-sidebar-width 40)
  (agent-shell-vertico-sidebar-max-width-fraction 0.3)
  (agent-shell-vertico-sidebar-title-max-length 80)
  (agent-shell-vertico-sidebar-group-by nil)
  (agent-shell-vertico-sidebar-expand-by-default nil)
  (agent-shell-vertico-sidebar-show-details nil)
  (agent-shell-vertico-sidebar-extra-info
   '(agent project model mode activity))
  (agent-shell-vertico-sidebar-sort-by 'priority)
  (agent-shell-vertico-sidebar-follow-workspaces t))
```

The regular (non-Evil) sidebar map includes `C-j`/`C-k` (move to the next or
previous row, session or project header), `TAB` (fold or session details),
`S-TAB` (cycle all fold levels),
`=` (group/flat), `s` (sort), `g` (refresh), `c` (new session), `k` (kill),
`r` (restart), `i` (interrupt), `m`/`M` (mode/model), `t`/`T`
(traffic/transcript), `?` (show the key reference), and `q` (close the side
window).

In Evil states the sidebar uses a Dired-like direct map: `j`/`k` move between
rows, `C-j`/`C-k` move a whole row at a time, `RET` activates the
current row or metadata field, `o` opens the session,
`O` opens it in another window, `TAB` toggles the current row, and `S-TAB`
cycles every row through the fold levels.  `gr` refreshes, `D`
kills, `R` restarts, and `I` interrupts the current session; `t` opens its
transcript and `T` shows traffic.  `q` closes the sidebar, while `=`, `s`,
`c`, `m`/`M`, and the other mnemonic actions remain available.  `v` remains
Evil's visual-state key.  `?` shows the same key reference.  The local `C-c`
prefix remains available as a fallback (for example, `C-c k` kills).

## Project-scoped shell commands

`agent-shell` splits every send in two: `agent-shell-send-region` takes the
first shell in the current project without asking, and `agent-shell-send-region-to`
(or a prefix argument elsewhere) reads one instead. You choose between the two
before every send, and the silent one picks arbitrarily when a project holds
several shells.

These commands make one binding decide. The project's only shell is used; when
the project has several, they ask which one; with a prefix argument they ask
across every shell, whatever project it belongs to.

- `M-x agent-shell-vertico-send-region`
- `M-x agent-shell-vertico-send-file`
- `M-x agent-shell-vertico-send-other-file`
- `M-x agent-shell-vertico-send-screenshot`
- `M-x agent-shell-vertico-send-clipboard-image`
- `M-x agent-shell-vertico-send-prompt`
- `M-x agent-shell-vertico-queue-prompt`
- `M-x agent-shell-vertico-inject-prompt`
- `M-x agent-shell-vertico-compose`

Each replaces a pair of `agent-shell` commands, so nine bindings cover what
took seventeen.

The shell at point is deliberately not preferred: standing in one session and
sending a region to another is the reason the prompt exists. That also means
composing inside a shell that has text at its prompt can move that text into
another shell's compose buffer, which is `agent-shell-prompt-compose`'s own
transfer behavior applied to the shell you chose.

Every command resolves the shell, then runs the `agent-shell` command it stands
for with resolution pinned to that shell, so what is sent, how a busy shell is
handled, and whether a viewport composes it all stay `agent-shell`'s.

## Shell buffer prompts

Several `agent-shell` commands ask which shell to act on: `agent-shell-send-region`
and the other senders under a prefix argument, `agent-shell-switch-buffer`, the
DWIM commands asked to pick a shell, and the session picker's "switch to another
shell" branch. They all read through one function, which builds its own columns
and declares no completion category.

`agent-shell-vertico-setup` reads those prompts through the same annotated list
the switch commands use.

Candidates become whole buffer names annotated with status, model, mode, title,
and path, sorted by `agent-shell-vertico-sort-by`, and carrying the
`agent-shell-session` category, so the registered Embark actions work there
too. The shells offered are unchanged: a command that names its own buffers
still gets exactly those.

## Session picker

`agent-shell` shows a session picker when `agent-shell-session-strategy` is
`prompt`: starting a shell lists the sessions the agent can resume in the
current directory. The picker reports what `session/list` returns, which is
the directory, the session title, and the date.

`agent-shell-vertico-setup` annotates that picker with what the local
transcripts know.

Each listed session is joined to its transcript by session ID, and annotated
with whether a shell already holds it, the agent, the model, and the first
message of the session. A session with no transcript on this machine still
lists and still resumes; its columns are empty.

With `agent-shell-vertico-consult` loaded, moving through the picker previews
the joined transcript, in the same way transcript search previews its matches.

The picker offers no hook for this, so the setup advises
`agent-shell--prompt-select-session`. It replaces only how the choice is read:
which sessions are offered, what a choice means, and any
`agent-shell-session-choices-function` you have configured all keep working
unchanged.

Annotating costs one pass over the project's transcripts each time the picker
opens, which takes about half a second for a project with several hundred
transcripts.

## Transcript recall

Browsing spans every known project. A prefix argument narrows it to one
selected project, and the `-project` variants operate on the current project
without asking for one.

- `M-x agent-shell-vertico-transcript-browse`
  Select and open a transcript from every known project. With a prefix
  argument, select a known project first.
- `M-x agent-shell-vertico-transcript-browse-project`
  Select and open a transcript in the current project.
- `M-x agent-shell-vertico-transcript-resume`
  Select and resume a session from every known project. With a prefix
  argument, select a known project first.
- `M-x agent-shell-vertico-transcript-resume-project`
  Select and resume a session in the current project.
- `M-x agent-shell-vertico-transcript-search`
  Search transcript contents across known projects with `rg` and Consult.
- `M-x agent-shell-vertico-transcript-search-project`
  Search transcript contents in the current project.
- `M-x agent-shell-vertico-transcript-stats`
  Summarize live, resumable, and transcript-only records and disk usage.
- `M-x agent-shell-vertico-transcript-doctor`
  Report missing tools, undiscovered projects, and transcript metadata issues.

Browse and search selections open the transcript file. Resume commands switch
to a matching live shell when possible, otherwise they resume the recorded
session. When `agent-shell-prefer-viewport-interaction` is non-nil, a resumed
session is shown in its viewport rather than in the shell buffer.

Each candidate is the session title, taken from the transcript's `**Title:**`
header, and falls back to the first user message for transcripts written
without one. Sessions are listed newest first by last change. Annotations run
from most to least identifying: project, first user message, agent,
availability, last change, and start time. They are rendered by a Marginalia
annotator registered for the `agent-shell-transcript` category, so
`marginalia-cycle` turns them off.

`agent-shell-vertico-transcript-candidate-limit` caps how many transcripts a
list offers, 10000 by default, or nil for no cap. The list is newest first, so
the cap drops the oldest, and the prompt then reads `(newest 10000 of 12345)`
rather than presenting the shortened list as everything.

An opened transcript is put in `markdown-ts-view-mode`, the read-only viewing
mode built on `markdown-ts-mode`, which hides the markup and renders inline
images. It is used when Emacs ships it and both the `markdown` and
`markdown-inline` tree-sitter grammars are installed
(`M-x markdown-ts-mode-install-parsers` installs them). Emacs leaves both modes
out of `auto-mode-alist`, so a transcript would otherwise never reach either.
Without the mode or its grammars the reader falls back to `markdown-mode`, and
without that to whatever mode the file itself selects.
`markdown-ts-view-mode-pre-init-hook` is emptied for the mode call, because its
default adds a final newline, which marks the buffer modified for every
transcript that ends without one; the cost is that the grammar can misread
markup at the very end of such a transcript. A buffer already in a
mode built on the chosen one keeps it, so `markdown-mode` derivatives such as
Polymode's `poly-markdown-mode` survive the fallback path.

The reader's own keys win over the view mode's, because minor mode keymaps take
precedence: `n`, `p` and `b` move between messages and browse rather than
walking headings. The view mode's heading motions stay on `C-c C-n`, `C-c C-p`,
`C-c C-f`, `C-c C-b` and `C-c C-u`, and `TAB` still cycles outline folding.

The transcript reader provides:

- `r` smart resume or switch to the live session
- `R` force a new resumed shell
- `c` toggle between clean content and the full transcript
- `b` browse other transcripts from the same project
- `n`/`p` move between user messages
- `N`/`P` move between agent messages
- `]`/`[` move between messages of either speaker
- `i` manually set or repair the session ID header
- `?` show the key reference

Browsing from a transcript leaves it on screen until another one replaces it,
so quitting the prompt returns to what you were reading and `q` walks back
through the transcripts you hopped through.

Evil's state keymaps take precedence over minor mode keymaps, so in Evil
normal and motion states the reader binds two-key sequences instead: `gr`
(resume), `gR` (force resume), `gc` (clean/full toggle), `gb` (browse), `gi`
(session ID), `g?` (key reference), and the vim-unimpaired style motions
`]]`/`[[` (either speaker), `]u`/`[u` (user messages) and `]a`/`[a` (agent
messages). Evil's own `g`, `]` and `[` commands and all text motions keep
working, and the header line shows whichever key set applies.

The clean view stays in the transcript buffer. It hides metadata, thoughts,
tool calls, and tool output with overlays. Markdown headings inside user and
agent messages remain visible. Toggling back restores the full view without
changing the file's text or modified state.

Both current `**Session ID:**` and legacy `**Session:**` headers are understood.
Session IDs are treated as opaque strings, so providers are not restricted to
UUIDs.

Content search runs `rg --json` asynchronously through Consult, aggregates
matches per transcript as they arrive, and previews the first match. A changed
query cancels the previous search process. Loading `agent-shell-vertico-consult`
also gives ordinary transcript browsing live preview. A preview opens in the
same mode as the reader, so a candidate and the transcript it leads to look
alike, with inline images turned off because a preview is scanned rather than
read. The mode is named here rather than taken from `auto-mode-alist`: Consult
previews files with `delay-mode-hooks` bound, which leaves a Markdown mode that
finishes its setup in hooks (Polymode, for example) unable to fontify, and a
file above `consult-preview-partial-size` is previewed in a buffer with no file
name, where the mode cannot be detected at all. Tree-sitter fontification costs
around a quarter of a second per screenful against near-zero for
`markdown-mode`, so previewing a long transcript lags by about that much. No
persistent cache or index is written.

## Session links

`agent-shell-vertico-links` stores stable pointers to sessions as Emacs
bookmarks and Org links.  A pointer records the session id, the agent
identifier, and the working directory.  Opening it reuses a live
matching `agent-shell` buffer when one exists, and otherwise resumes
the session with the agent that issued it, in the stored directory.
A resume the agent cannot complete is reported instead of silently
starting a new session.

```elisp
(use-package agent-shell-vertico-links
  :after agent-shell-vertico
  :config (agent-shell-vertico-links-setup))
```

Then `M-x bookmark-set` and `M-x org-store-link` work from an
`agent-shell` buffer and from the viewport showing it, and
`M-x bookmark-jump` reopens the session.  `M-x org-store-link` stores a
link like `[[agent-shell:SESSION-ID?agent=codex&dir=/path][Session title]]`
that `org-open-at-point` follows.  The link format matches the
standalone `agent-shell-links` package, so links stored by either
package open with the other installed.

With Embark, `embark-act` on such a link opens the session behind it
(`RET` or `o`) or copies its session id (`i`).  When `embark-org` is
loaded, its generic Org link actions, such as the copy variants and
link navigation, join the same keymap.

## Buffer search

`consult-line` shows an `agent-shell` buffer's collapsed blocks as blank
rows, and jumping to a match leaves the block collapsed. agent-shell hides
a folded body with an `invisible` text property, Consult copies that
property onto its candidates, and the minibuffer hides the text there too.
Consult can only open folds built from overlays.

`agent-shell-vertico-setup` enables this integration when Consult is available.
Matches inside a collapsed block then show their text, and both
previewing and selecting one expands the block. Candidates in
`agent-shell` buffers lose their buffer faces, which is the trade for
reading them. Blocks opened while previewing stay open, because Consult's
preview restores only the folds it opened itself.

## Narrowing and grouping

Every prompt this package reads narrows by key, the way Consult's own
commands do. Press `consult-narrow-key`, then a key from the list below,
to keep only the candidates it names; press it twice to widen again, and
`C-h` after it to see the keys. Consult installs the keys, so narrowing
needs `agent-shell-vertico-consult` loaded, and it does nothing until
`consult-narrow-key` has a value:

```elisp
(setq consult-narrow-key "<")
```

Live sessions, in `agent-shell-vertico-switch` and in every prompt
`agent-shell` asks about which shell to act on:

- `r` Ready, `w` Working, `s` Starting — the status column
- `!` Waiting — the agent is asking for permission
- `q` sessions with prompts still queued
- `p` sessions in the project the command was called from

Transcripts, in browse, resume, and search:

- `l` a shell already holds this session
- `r` resumable, `t` transcript only
- `p` this project
- `d` changed today, `w` changed in the last seven days

`agent-shell`'s own session picker:

- `l` a shell already holds it, `r` resumable
- `h` this machine has the transcript, `n` it does not

A session's prompt queue:

- `p` pending prompts, `a` the queue-wide entries, `m` multi-line prompts

Every session list above also narrows by agent: `c` Claude, `x` Codex,
`i` Pi, `g` Gemini, `k` Kiro, `o` OpenCode. A key matches the start of an
agent's name, so `c` also finds `Claude Code` and `Claude(token)`.
Agents are named by whoever configured them, so
`agent-shell-vertico-narrow-agent-keys` is where you add your own. `i`
stands for Pi because `p` is the project key everywhere else.

Narrowing keeps candidates by what they are. To filter by what their
annotation shows instead, orderless matches a component against the
annotation when you prefix it with `&`: `&lyra` in the transcript browser
keeps that project's transcripts, `&Working` in the session switcher keeps the
busy ones. This needs no configuration — `orderless-style-dispatchers` enables
`orderless-affix-dispatch` by default — and nothing from this package: the
annotation Marginalia renders is what gets matched. Two limits follow from
that. It is matched as rendered, so a value cut to fit its column matches by
its visible prefix only, and `&` matches every column rather than one, so
`&Claude` finds an agent and a project called `claude` alike. Plain typing,
with no `&`, still matches the candidate: the buffer name of a session, the
title of a transcript.

Grouping is separate and off by default. Set
`agent-shell-vertico-group-by` to `project`, `agent`, or `status` to
gather each group's candidates under a heading:

```elisp
(setq agent-shell-vertico-group-by 'project)
```

Grouping gathers the candidates of one group together, which overrides
the order `agent-shell-vertico-sort-by` and the transcript readers put
them in. That is the trade, and it is why nothing is grouped by default.
Grouping is plain completion metadata, so unlike narrowing it works
without Consult.

## Setup

```elisp
(use-package agent-shell-vertico
  :load-path "/path/to/agent-shell-vertico"
  :after agent-shell
  :bind (("C-c a b" . agent-shell-vertico-switch)
         ("C-c a p" . agent-shell-vertico-switch-project)
         ("C-c a q" . agent-shell-vertico-prompt-queue)
         ("C-c a r" . agent-shell-vertico-transcript-browse-project)
         ("C-c a R" . agent-shell-vertico-transcript-resume-project)
         ("C-c a s" . agent-shell-vertico-transcript-search-project))
  :config (agent-shell-vertico-setup))

(use-package agent-shell-vertico-sidebar
  :after agent-shell-vertico
  :bind (("C-c a S" . agent-shell-vertico-sidebar-toggle)))

(use-package agent-shell-vertico-links
  :after agent-shell-vertico
  :config (agent-shell-vertico-links-setup))
```

With Embark enabled on an `agent-shell-vertico` candidate, the extra
session actions follow `agent-shell-manager` closely:

- `c` create a new shell
- `k` kill the selected shell process
- `r` restart the selected shell
- `t` view traffic
- `T` open transcript
- `i` interrupt session
- `m` set session mode
- `M` set session model

Normal `embark-buffer-map` actions stay available too.

The unified setup also teaches Embark about the rendered Markdown links
agent-shell prints in a session buffer. With point on a link, `embark-act`
(or `embark-dwim`) offers:

- `RET` open the link — a file link opens in Emacs, jumping to any
  `#Lnnn` line; a binary prompts to open externally; anything else goes
  to `browse-url`
- `o` open a file link in another window, leaving the agent buffer put
- `x` open the link outside Emacs with `embark-open-externally`, the
  same key Embark uses for its own file and URL maps; a file link is
  resolved to a plain path first, dropping any `#Lnnn` line
- `w` copy the link URL to the kill ring

Transcript candidates have a separate Embark map:

- `o`/`b` open in the current window; `O` opens in another window
- `r` smart resume
- `R` force a new resumed shell
- `d` open the recorded working directory
- `c` open the clean reader
- `i` copy the session ID
- `I` set or repair the session ID
- `w` copy the recorded working directory
- `f` copy the transcript file name

`rg` is required only for full-text search. Consult is required by
`agent-shell-vertico-consult`; browsing, resuming, reader mode, statistics, and
diagnostics work without it.
