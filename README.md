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
- `M-x agent-shell-vertico-setup-embark`
  Register the `agent-shell-session` Embark category.

Candidates keep the recent ordering from `agent-shell-buffers` and show
consult-style annotations for status, model, mode, title, and path.

## Session sidebar

`agent-shell-vertico-sidebar` provides a compact side window for jumping
between live sessions without opening a minibuffer.  It shows a flat list by
default; `=` switches to project groups.  In flat mode, the default `project`
metadata entry is promoted to a compact context line below each title (for
example, `⌂ agent-shell-vertico`); labels prefer agent-shell's configured
project name and fall back to the directory basename.  Hover shows the full
working directory.
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
floor of 16 columns.  A narrow frame therefore keeps most of its columns, and
the cap shrinks the sidebar when the frame narrows without ever widening it.
Customize the ordered `agent-shell-vertico-sidebar-extra-info` list to choose
which expanded-session values are shown: `status`, `activity`, `project`,
`model`, `mode`, and `last-user-message`.  Values are packed two per row; the
default omits `last-user-message`.  Removing `project` also removes the flat
context line.
The default `priority` sort puts sessions waiting for attention first, followed
by working and ready sessions; working sessions keep the order in which their
current turns entered the busy state, so streamed chunks do not make them
jump.  In grouped mode, projects follow the highest-priority session they
contain.  `s` switches between priority, activity, recency, status, and name
sorting.

The sidebar follows `agent-shell` events, so a completed turn in another
window is marked for attention.  A failed request, a session waiting for a
permission response, and a session holding unseen output each get their own
mark.  Submitting a new prompt clears any of them, since the previous turn
has by then been seen.  `o` always jumps to the session at point; the other
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
   '(status project model mode activity))
  (agent-shell-vertico-sidebar-sort-by 'priority)
  (agent-shell-vertico-sidebar-follow-workspaces t))
```

The regular (non-Evil) sidebar map includes `TAB` (fold or session details),
`S-TAB` (cycle all fold levels),
`=` (group/flat), `s` (sort), `g` (refresh), `c` (new session), `k` (kill),
`r` (restart), `i` (interrupt), `m`/`M` (mode/model), `t`/`T`
(traffic/transcript), `?` (show the key reference), and `q` (close the side
window).

In Evil states the sidebar uses a Dired-like direct map: `j`/`k` move between
rows, `RET` activates the current row or metadata field, `o` opens the session,
`O` opens it in another window, `TAB` toggles the current row, and `S-TAB`
cycles every row through the fold levels.  `gr` refreshes, `D`
kills, `R` restarts, and `I` interrupts the current session; `t` opens its
transcript and `T` shows traffic.  `q` closes the sidebar, while `=`, `s`,
`c`, `m`/`M`, and the other mnemonic actions remain available.  `v` remains
Evil's visual-state key.  `?` shows the same key reference.  The local `C-c`
prefix remains available as a fallback (for example, `C-c k` kills).

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

The transcript reader provides:

- `r` smart resume or switch to the live session
- `R` force a new resumed shell
- `c` show only user and agent messages
- `b` browse other transcripts from the same project
- `n`/`p` move between user messages
- `N`/`P` move between agent messages
- `]`/`[` move between messages of either speaker
- `i` manually set or repair the session ID header
- `?` show the key reference

Evil's state keymaps take precedence over minor mode keymaps, so in Evil
normal and motion states the reader binds two-key sequences instead: `gr`
(resume), `gR` (force resume), `gc` (clean reader), `gb` (browse), `gi`
(session ID), `g?` (key reference), and the vim-unimpaired style motions
`]]`/`[[` (either speaker), `]u`/`[u` (user messages) and `]a`/`[a` (agent
messages). Evil's own `g`, `]` and `[` commands and all text motions keep
working, and the header line shows whichever key set applies.

Both current `**Session ID:**` and legacy `**Session:**` headers are understood.
Session IDs are treated as opaque strings, so providers are not restricted to
UUIDs.

Content search runs `rg --json` asynchronously through Consult, aggregates
matches per transcript as they arrive, and previews the first match. A changed
query cancels the previous search process. Loading `agent-shell-vertico-consult`
also gives ordinary transcript browsing live preview. Previews open in plain
`markdown-mode`: Consult previews files with `delay-mode-hooks` bound, which
leaves a Markdown mode that finishes its setup in hooks (Polymode, for example)
unable to fontify, and a file above `consult-preview-partial-size` is previewed
in a buffer with no file name, where the mode cannot be detected at all. No
persistent cache or index is written.

## Setup

```elisp
(use-package agent-shell-vertico
  :load-path "/path/to/agent-shell-vertico"
  :after agent-shell
  :bind (("C-c a b" . agent-shell-vertico-switch)
         ("C-c a p" . agent-shell-vertico-switch-project))
  :config
  (with-eval-after-load 'embark
    (agent-shell-vertico-setup-embark)))

(use-package agent-shell-vertico-sidebar
  :after agent-shell-vertico
  :bind (("C-c a S" . agent-shell-vertico-sidebar-toggle)))

(use-package agent-shell-vertico-transcript
  :after agent-shell-vertico
  :bind (("C-c a r" . agent-shell-vertico-transcript-browse-project)
         ("C-c a R" . agent-shell-vertico-transcript-resume-project)))

(use-package agent-shell-vertico-consult
  :after (agent-shell-vertico-transcript consult)
  :bind (("C-c a s" . agent-shell-vertico-transcript-search-project))
  :config
  (with-eval-after-load 'embark
    (agent-shell-vertico-transcript-setup-embark)))
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

`agent-shell-vertico-setup-embark` also teaches Embark about the
rendered Markdown links agent-shell prints in a session buffer. With
point on a link, `embark-act` (or `embark-dwim`) offers:

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
