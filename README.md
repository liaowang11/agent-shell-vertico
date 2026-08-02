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
default; `G` switches to project groups.  In flat mode, the default `project`
metadata entry is promoted to a compact context line below each title (for
example, `⌂ agent-shell-vertico`); labels prefer agent-shell's configured
project name and fall back to the directory basename.  Hover shows the full
working directory.
`TAB` folds or expands a project header, or toggles metadata for only the
session at point.  `RET`/mouse-1 activates the selected row or metadata field;
the model and mode values open their selectors, while a project value opens
that directory in another window.  Groups are collapsed by default, and
session metadata is hidden by default.  `S-TAB` toggles that default for all
sessions, following Org's global-cycle convention.  Each title can wrap within
the narrow sidebar, up to
`agent-shell-vertico-sidebar-title-max-length` characters.
The layout measures the current sidebar body width and reflows titles when the
window is resized.
Customize the ordered `agent-shell-vertico-sidebar-extra-info` list to choose
which expanded-session values are shown: `status`, `activity`, `project`,
`model`, `mode`, and `last-user-message`.  Values are packed two per row; the
default omits `last-user-message`.  Removing `project` also removes the flat
context line.
The default `priority` sort puts sessions waiting for attention first, followed
by working and ready sessions; in grouped mode, projects follow the
highest-priority session they contain.  `s` switches between priority, activity,
recency, status, and name sorting.

The sidebar follows `agent-shell` events, so a completed turn in another
window is marked for attention.  `o` always jumps to the session at point; the
other keys expose the same restart, kill, interrupt, model, mode, traffic, and
transcript operations as the Vertico Embark map.

The compact activity value is the age of the last observed agent event, not
the total session or turn duration; an actively streaming session therefore
shows `now`.

The header reports the total number of live sessions and compact non-zero
status counts using the row icons (`▲` attention, `◆` working, `✓` ready, and
`○` starting); hover a count for its label.

The sidebar hides the regular mode line and uses its compact header for these
statistics instead.

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
  (agent-shell-vertico-sidebar-title-max-length 80)
  (agent-shell-vertico-sidebar-group-by nil)
  (agent-shell-vertico-sidebar-expand-by-default nil)
  (agent-shell-vertico-sidebar-show-details nil)
  (agent-shell-vertico-sidebar-extra-info
   '(status project model mode activity))
  (agent-shell-vertico-sidebar-sort-by 'priority))
```

The regular (non-Evil) sidebar map includes `TAB` (fold or session details),
`S-TAB` (all details),
`G` (group/flat), `s` (sort), `g` (refresh), `c` (new session), `k` (kill),
`r` (restart), `i` (interrupt), `m`/`M` (mode/model), `t`/`T`
(traffic/transcript), `?` (show the key reference), and `q` (close the side
window).

In Evil states the sidebar uses a Dired-like direct map: `j`/`k` move between
rows, `RET` activates the current row or metadata field, `o` opens the session,
`O` opens it in another window, `TAB` toggles the current row, and `S-TAB`
toggles details for all sessions.  `gr` refreshes, `D`
kills, `R` restarts, and `I` interrupts the current session; `t` opens its
transcript and `T` shows traffic.  `q` closes the sidebar, while `G`, `s`,
`c`, `m`/`M`, and the other mnemonic actions remain available.  `v` remains
Evil's visual-state key.  `?` shows the same key reference.  The local `C-c`
prefix remains available as a fallback (for example, `C-c k` kills).

## Transcript recall

Browsing is project-first. The `-project` variants operate on the current
project without asking for one.

- `M-x agent-shell-vertico-transcript-browse`
  Select and open a transcript in a selected known project.
- `M-x agent-shell-vertico-transcript-browse-project`
  Select and open a transcript in the current project.
- `M-x agent-shell-vertico-transcript-resume`
  Select and resume a session in a selected project.
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
session. The transcript reader provides:

- `r` smart resume or switch to the live session
- `R` force a new resumed shell
- `c` show only user and agent messages
- `b` browse other transcripts from the same project
- `n`/`p` move between user messages
- `N`/`P` move between agent messages
- `i` manually set or repair the session ID header

Both current `**Session ID:**` and legacy `**Session:**` headers are understood.
Session IDs are treated as opaque strings, so providers are not restricted to
UUIDs.

Content search runs `rg --json` asynchronously through Consult, aggregates
matches per transcript as they arrive, and previews the first match. A changed
query cancels the previous search process. Loading `agent-shell-vertico-consult`
also gives ordinary transcript browsing live preview. No persistent cache or
index is written.

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
