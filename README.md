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

## Jump history

Moving between sessions leaves a trail, the way vim's jump list does for
positions, and three commands walk it:

- `M-x agent-shell-vertico-jump-back`
  Display the session before this one, vim's `C-o`.
- `M-x agent-shell-vertico-jump-forward`
  Undo a step back, vim's `C-i`. Only meaningful while retracing: with no
  step to undo it signals a `user-error`.
- `M-x agent-shell-vertico-jump-history`
  Read the trail with completion, vim's `:jumps`, most recently left
  first. The first candidate is what `jump-back` would display, and
  selecting one steps the history to it, so back and forward carry on from
  there. Annotations, narrowing and Embark actions are the switch
  commands' own, and Consult previews it like any other session list.

Every command here that displays a session records the one it was
displayed from, so the trail follows what you did rather than which
command did it: the switch commands, the sidebar's jumps, the Embark
actions and the session picker all feed one list. Jumps taken from beside
a session — from a file, from magit, from the sidebar — record the session
you last read, which is usually the one you meant. A prefix argument
displays in another window, as elsewhere.

A session is held once, at the point you last left it, so reading two
sessions back and forth does not bury everything older under them; that
also means the list is bounded by how many sessions are live, and
`agent-shell-vertico-jump-history-size` (30) only caps a reader who keeps
more than that. Killed sessions drop out on their own.

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
- `i` steer it into the running turn. The key is left over from when
  agent-shell called this Inject and gave it `i` in the queue's own
  button row; that row now offers Steer on `s`. The prompt leaves the
  queue only once the agent takes it, so an agent that declines, or one
  without mid-turn steering, leaves it pending. Needs an agent-shell
  with `agent-shell-prompt-queue-steer`; an older one reports that
  instead of failing
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
between live sessions without opening a minibuffer.  It is modelled on Claude
Code's agent view, and it has three views; `=` cycles them:

- **state** (the default) puts each session under one of the agent view's
  sections: Pinned, Needs you, Working, Idle and Snoozed.  Empty sections are
  left out.  Snoozed starts folded
  (`agent-shell-vertico-sidebar-folded-sections`), and Idle shows its first
  three sessions (`agent-shell-vertico-sidebar-idle-rows`) and then a
  `… N more` row that `RET` opens; when only one session is left over, it is
  shown instead of a `… 1 more` row.
- **project** puts each session under a foldable project header, with a
  Pinned section above the projects.
- **flat** is one list.

In the state and flat views the default `project` metadata entry is promoted
to a compact context line below each row (for example,
`⌂ agent-shell-vertico`), since no header above the row names the project.

Project labels prefer agent-shell's configured project name and fall back to
the directory basename.  Hover shows the full working directory.

### What a row says

Each session is a title line, a detail line, and in the state and flat views
a project line:

```
✻ Fix the login redirect                 3m
  Allow: Run make check
  ⌂ agent-shell-vertico
```

The detail line appears only when there is something to say: an idle session
whose turn the sidebar never saw finish, for example, has none.

The mark is Claude Code's star, and its colour is the session's state: blue
while it works, yellow while it waits for you, red when its last turn failed,
green when its last turn finished, grey when it stopped or has started and
nobody has prompted it yet, and purple when you snoozed it.  A shell still
starting its agent session counts as working: its star is blue and spins.  A
working star spins through Claude Code's own frames, `· ✢ ✳ ✶ ✻ ✽`; with
`agent-shell-vertico-sidebar-animate-busy` off it is a still `●`.  A session
whose agent process has exited is a dot, `∙`.  Output you have not read makes
the title bold; it does not change the colour or the section, so a finished turn
nobody has read is Idle, exactly as in the agent view.

The detail line is the one line that matters for the state.  A waiting session
says what it waits for (`Allow: Run make check`), a working one shows its
newest entry (the prompt it was sent, then the last line it streamed, or
`✗ title` for a tool call that failed), and a failed one says why.  A finished
turn shows its last line.  Only that last line is read for a marker: when it
is a `result:` line the row shows what follows the colon, when it is a `needs
input:` or `blocked:` line the session waits for you, and when it is a
`failed:` line the turn failed.  The same words earlier in a reply are plain
text and change nothing.  A session nobody has prompted says `Send a
prompt to start`.  In the project and flat views the line starts with the
status word, such as `Waiting · Allow: Run make check`, since there is no
section header to say it.

The age at the right edge is how long the session has been in its current
state, not how old it is.  A working session that has said nothing for
`agent-shell-vertico-sidebar-stuck-after` seconds (15 minutes by default) has
its age drawn yellow.  Titles are cut with `…` to keep every row one line high;
set `agent-shell-vertico-sidebar-wrap-titles` to wrap them instead.

`p` peeks at the session at point: a window opens below the sidebar with what
the session asks and the last message it wrote, and `r` there sends it a reply
without leaving the list.  `RET` opens the session and `q` closes the peek.
Peeking reads the session, so its unread mark goes.

`agent-shell-vertico-sidebar-toggle` shows a hidden sidebar without selecting
its window and closes a visible sidebar; use
`agent-shell-vertico-sidebar-focus` to enter it.  Focusing puts point on the
row of the session you came from, and calling it again from the sidebar returns
to the window you were in before.

`TAB` folds or expands a section or project header, or toggles metadata for
only the session at point.  `RET`/mouse-1 activates the selected row or metadata field;
the model and mode values open their selectors, while a project value opens
that directory in another window.  Groups are collapsed by default, and
session metadata is hidden by default.  `S-TAB` cycles the whole sidebar
through its fold levels, following Org's global-cycle convention: section or
project headers alone, then their session rows, then each session's metadata,
then back to the headers.  It discards the individual folds made with `TAB`.  A
flat list has no project level, so there `S-TAB` alternates between hiding and
showing metadata for every session.  A title is shown up to
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
and the detail line already carry the status, and the detail line shows the
prompt while the session works on it.  Removing `project` also removes the
project line under each row in the state and flat views.
Activating an agent value starts a new session with that agent in the same
project.
The default `priority` sort puts sessions waiting for attention first, followed
by working, idle and starting sessions.  Within the waiting group, sessions
holding output nobody has read come before a session whose permission decision
you have already seen: answering that decision is the only thing that settles
it, so it does not hold the head of the list in the meantime.  Attention and
working sessions order oldest first, so the same session
`agent-shell-vertico-sidebar-jump` visits leads the list, and streamed chunks do
not reorder working sessions; idle sessions order by their latest activity,
newest first, so reading a finished session does not drop it below stale idle
ones.  In the state view each section keeps this order among its own sessions.
In the project view, projects follow the highest-priority session they contain.
`s` switches between priority, activity, recency, status, and name sorting.
Whatever the sort, pinned sessions come first and snoozed ones last.

A fringe marker runs down the rows of the sessions the selected frame is
showing, so the list says where you already are.  The session you are
working in gets a thick bar in the accent colour
(`agent-shell-vertico-sidebar-focused-session`); the others on the frame get
a thin grey one (`agent-shell-vertico-sidebar-current-session`).  Neither
borrows a status colour, since blue, yellow, red and green already mean
working, waiting, failed and done on these rows.  The thick bar follows
the selected window: step to a file, to magit or into the sidebar itself
and every session on the frame is thin, so a frame or workspace is marked
by what it shows and not by where you last were; a session off the frame,
or on another frame, is not marked at all.  This is only the marker,
not what counts as reading a session: unread still clears only when a
session's own window is selected.

`agent-shell-vertico-sidebar-marker-method` selects `fringe` (the default),
`margin`, or nil to disable markers.  The fringe method reserves at least
eight pixels of the left fringe in graphical sidebar windows, including
when a workspace restores a layout with fringes hidden.  It preserves wider
left fringes and the right fringe's width.  Terminal frames need `margin`,
which reserves one text column instead.

A jump taken from inside a session that is waiting for a permission decision
goes to the next session that needs you, since arriving where you already are
settles nothing; with no other session waiting it reports that instead of not
moving.  Answering the decision removes the session from the list.

The sidebar follows `agent-shell` events, so a completed turn in another
window is marked unread.  Submitting a new prompt clears the mark, since the
previous turn has by then been seen, and so does seeing the session in the
selected window.

Displaying a session counts as reading it, so walking into one by mistake
drops its mark.  `u` puts the mark back: the session returns to the head of
the `priority` order and `agent-shell-vertico-sidebar-jump` visits it again.
Both commands work on the row at point in the sidebar and on the session or
viewport buffer itself, so bind `agent-shell-vertico-sidebar-mark-unread`
and `agent-shell-vertico-sidebar-mark-read` in `agent-shell-mode-map`
(`C-c u` and `C-c !` are free there) to mark the session you are standing
in.  The mark carries the session's last activity time rather than
the current time, so a session marked by hand does not jump ahead of one
that has waited longer.  A working session is refused, since its turn marks
itself unread when it finishes away from you.  Leave the session after
marking it: the mark clears again as soon as you are seen looking at the
session.

`!` is the other direction: it drops a mark without visiting the session, so
an error already dealt with elsewhere, or a turn read in the sidebar itself,
stops holding the head of the `priority` order and
`agent-shell-vertico-sidebar-jump` moves on to the next session.  A session
waiting for a permission decision stays in Needs you, because that comes from
its live status rather than from a mark: it cannot proceed until you answer
it.  New output marks the session again, whether a turn finishes or a
background stream goes quiet.

`z` snoozes a session you mean to come back to, which neither `u` nor `!` can
say: `!` loses the reminder, and leaving it unread keeps it at the head of the
list.  A snoozed session's mark turns purple and its title grey, it moves to the
Snoozed section of the state view, and it sorts below every other session in
the other views.  The header counts it as snoozed whatever its state, and
`agent-shell-vertico-sidebar-jump` and the notification function pass over it.
Its title is still bold when it holds unread output.  Looking at it,
marking it read and new output leave it snoozed; sending it a prompt, a new
permission request, an error, `u`, or `z` again wakes it, with whatever it held
back at the age it had.  A working session is refused.  Like `u` and `!`,
`agent-shell-vertico-sidebar-snooze` works from the session buffer too.

`P` pins a session, the opposite of a snooze: it sorts above every other
session whatever the sort, and the state and project views draw it under a
Pinned header at the top.  It keeps its state, so the header still counts it in
its own band.  Pinning wakes a snoozed session, snoozing unpins one, and `P`
again unpins.

A session whose turn has ended but which still has a subagent or an async task
running is shown as `Background`: a blue star that does not spin, in the
Working section, and a line under the row counting what runs, such as `2
subagents · 1 task`.  It takes a prompt, which is what separates it from a
working session, and it sorts just below the working sessions under
`priority`.  It never needs
attention by itself, so `agent-shell-vertico-sidebar-jump` passes over it, but a
finished turn still marks it unread as usual.  The report the agent writes once
the work has ended is announced even though the session is already unread, so
the notification you get is the result, not only the launch.  Any running task
counts, a dev server included.  `S` opens `agent-shell-subagents` for the
session, the list agent-shell keeps of its subagents and tasks, where they can
be opened or stopped.  agent-shell reports none of this as an event, so the
sidebar reads it from the session's state, and checks every two seconds while it
shows something running.

`agent-shell-vertico-sidebar-jump-by-key` picks a session the way
`ace-window` picks a window.  The sessions are listed flat in the sidebar,
each row's status mark replaced by a key from
`agent-shell-vertico-sidebar-jump-keys`, digits `1`-`9` then the home row
by default, in row order; press a key and that session is displayed.  A
hidden sidebar is shown for the read and closed again after it, and a
grouped one is grouped again after, folds as they were, so the command
works from anywhere without changing the sidebar.  The keys follow the
rows, so they are assigned afresh each time and read off the sidebar
rather than remembered: under `priority` sorting a session that just
finished moves up and takes a new key.  A single live session is displayed
without asking, and a prefix argument displays the session in another
window.

Only the rows the sidebar window shows are keyed, and only as many as
there are keys.  Nothing scrolls, because the read cannot be interrupted
to scroll for a key that is off screen.  The prompt counts whatever is
left over, and `agent-shell-vertico-switch` reaches those sessions.

While the keys are up, the frame's other windows are dimmed and the
sidebar is not, so the sidebar is what stands out while the question is
open.  `ace-window` dims every window because a window is chosen by where
it is; a session is chosen by reading its title and project, so dimming
the list would take away what you are looking at.  Inside the sidebar,
only a row that carries no key is dimmed, because such a row is not one
of the answers.  Set `agent-shell-vertico-sidebar-jump-dim-others` to nil
to dim nothing.

A key needs no background of its own against that: it is a red character
in the frame's own font, following your `error` face.  It replaces the mark,
so a failed session's red star is not drawn beside it, and the unkeyed rows
are dimmed, so a red character in the mark column means a key.  The
action list keeps its own colour, since in the echo area there is nothing
to confuse it with.

For a jump with nothing to read, `agent-shell-vertico-sidebar-jump-to-1`
through `agent-shell-vertico-sidebar-jump-to-9` display the session at
that position in the sidebar's order, and
`agent-shell-vertico-sidebar-jump-to-index` takes any position.  These
open no sidebar and count every live session, not only the rows a window
shows, because there is nothing to look at.  One command per position,
generated the way Doom generates `+workspace/switch-to-N`, so each is
bindable without a lambda and reachable through `M-x`.  A position is not
a name for a session: under `priority` sorting a finished turn moves its
session up, and jumping to a session reads it, which moves it too.

`agent-shell-vertico-sidebar-next-session` and
`agent-shell-vertico-sidebar-previous-session` step one row down or up
the sidebar from the session you are in, wrapping at either end; from a
buffer that is no session they start at the top or the bottom row.  The
order is the one the sidebar draws, project groups and side
conversations nested under their parents included, and a folded project
still counts.  Like the numbered jumps, they open no sidebar, and under
`priority` sorting the session you step to can move once it is read.

Each of these jumps is recorded in the jump history above, so
`agent-shell-vertico-jump-back` undoes whichever one you took.

`?` during the read lists the actions in
`agent-shell-vertico-sidebar-jump-dispatch-alist`, one a line with its key
coloured, and pressing an action's key does that to the next session chosen
instead of displaying it, the way `ace-window` dispatches on
`aw-dispatch-alist`.  The shipped actions are `o` open in another window, `x`
kill, `r` restart, `i` interrupt, `m` set mode, `M` set model, `t` open
transcript, `T` view traffic, `u` mark unread, `!` mark read, `z` snooze or
wake, and `S` list subagents.  The prompt names the pending action, the keys
stay drawn while you choose, and the action runs once the sidebar is back as it
was, so a command that asks something of its own has a window to ask in.  Each
entry is a key, a function of one session buffer, and a description, so a custom
action is a three-element list.  A session key wins over an action key, which is
why no shipped action key is also a shipped session key.

An agent can also produce output with no turn in flight: background tasks
such as subagents keep streaming after a turn ends, and a prompt steered in
too late makes the agent start a turn of its own.  `agent-shell` reports
such a session ready, because it has nothing in flight to report.  The
sidebar shows it working while the output arrives, then marks it as
holding unseen output once the stream has been quiet for a few seconds.
No completion event is sent for this kind of work, so the quiet period is
what ends it.  `o` always jumps to the session at point; the other
keys expose the same restart, kill, interrupt, model, mode, traffic, and
transcript operations as the Vertico Embark map.

Every mark is a plain character, so the sidebar needs no icon font and reads
the same in a terminal.  Section and project folds use `▼` and `▶`, the same
triangles `agent-shell` uses for its own collapsible fragments; a row's
project line starts with `⌂` and a message line with `↳`.

Sessions under a project header are indented by a `line-prefix` display
property rather than by inserted spaces, so the indentation is visual only:
copying a row yields no leading whitespace, and the two reserved columns
line a session icon up under the project name.

Point never rests on an icon.  A status mark, a fold triangle, the home on
a project line, the arrow on a message line, and the gap after each are one
field, and point landing in it is moved forward on to the text: standing on
an icon says nothing, and the sidebar draws no cursor to say where point
is.  Row motion lands on the text directly, and anything else — a click, an
arrow key, a workspace package restoring a layout — is corrected before the
next redisplay.

The spin is an overlay over the still star, so a sidebar that is not
animating reads exactly as it did before.
`agent-shell-vertico-sidebar-busy-frames` takes the one-column strings to spin
through, and `agent-shell-vertico-sidebar-busy-frame-interval` sets the rate,
which defaults to `agent-shell`'s own 0.1s so a session spins at the same rate
here as in its shell.  The animation runs only while the sidebar is visible and
something is working.

The status is what the session is, never whether you have read it.  A turn
that completes while its buffer is off screen leaves an ordinary Idle
session with a bold title; selecting that window clears the bold and leaves
the star green.  A failed session stays failed until you send it something,
because that is what it is; reading it only clears the bold.

The `activity` metadata value is the age of the last observed agent event,
not the time in state the title line shows; an actively streaming session
therefore shows `now`.

The header is one line that stays put while the list scrolls.  It counts the
sessions in each band, in the colours the marks use, and names the view at
the right edge:

```
 1 need you · 2 working · 3 idle           state
```

A band with no sessions is left out.  A pinned session is counted in its
band, not as pinned.  When the words do not fit, the counts become coloured
digits and the words move to the tooltip.  Hover the "need you" count to see
which sessions it counts, and click it to run
`agent-shell-vertico-sidebar-jump`.  A project header
shows how many of its sessions need you, and nothing when none does.

The sidebar hides the regular mode line and uses its compact header instead.
Enable `agent-shell-vertico-sidebar-mode-line-mode` to put the "need you"
count in every mode line, with the same tooltip and click, so it is visible
while the sidebar is closed.  It shows nothing when nobody needs you.

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
  :bind (("C-c a S" . agent-shell-vertico-sidebar-toggle)
         ("C-c a j" . agent-shell-vertico-sidebar-jump-by-key))
  :custom
  (agent-shell-vertico-sidebar-side 'left)
  (agent-shell-vertico-sidebar-width 40)
  (agent-shell-vertico-sidebar-max-width-fraction 0.3)
  (agent-shell-vertico-sidebar-title-max-length 80)
  (agent-shell-vertico-sidebar-wrap-titles nil)
  (agent-shell-vertico-sidebar-jump-keys
   '(?1 ?2 ?3 ?4 ?5 ?6 ?7 ?8 ?9 ?a ?s ?d ?f ?g ?h ?j ?k ?l))
  (agent-shell-vertico-sidebar-jump-dim-others t)
  (agent-shell-vertico-sidebar-group-by 'state)
  (agent-shell-vertico-sidebar-folded-sections '(snoozed))
  (agent-shell-vertico-sidebar-idle-rows 3)
  (agent-shell-vertico-sidebar-expand-by-default nil)
  (agent-shell-vertico-sidebar-show-details nil)
  (agent-shell-vertico-sidebar-extra-info
   '(agent project model mode activity))
  (agent-shell-vertico-sidebar-sort-by 'priority)
  (agent-shell-vertico-sidebar-animate-busy t)
  (agent-shell-vertico-sidebar-busy-frames '("·" "✢" "✳" "✶" "✻" "✽"))
  (agent-shell-vertico-sidebar-busy-frame-interval 0.1)
  (agent-shell-vertico-sidebar-follow-workspaces t)
  :config
  (agent-shell-vertico-sidebar-mode-line-mode 1))
```

The regular (non-Evil) sidebar map includes `C-j`/`C-k` (move to the next or
previous row, session, section or project header), `TAB` (fold or session
details), `S-TAB` (cycle all fold levels), `=` (cycle the views), `s` (sort),
`g` (refresh), `c` (new session), `k` (kill), `r` (restart), `i` (interrupt),
`m`/`M` (mode/model), `t`/`T` (traffic/transcript), `u`/`!` (mark unread/read),
`z` (snooze), `P` (pin), `p` (peek), `S` (list subagents), `?` (show the key
reference), and `q` (close the side window).

In Evil states the sidebar uses a Dired-like direct map: `j`/`k` move between
rows, `C-j`/`C-k` move a whole row at a time, `RET` activates the current row or
metadata field, `o` opens the session, `O` opens it in another window, `TAB`
toggles the current row, and `S-TAB` cycles every row through the fold levels.
`gr` refreshes, `D` kills, `R` restarts, and `I` interrupts the current session;
`t` opens its transcript, `T` shows traffic, `u`/`!` mark the session unread or
read, `z` snoozes it, `P` pins it, `p` peeks at it, and `S` lists its
subagents; `!`, `z` and `S` take
precedence over Evil's `evil-shell-command`, `z` prefix (scrolling and folds)
and `evil-change-whole-line` in this read-only list, and `P` and `p` replace
`evil-paste-before` and `evil-paste-after`.  `q` closes the sidebar,
while `=`, `s`, `c`, `m`/`M`, and the other mnemonic actions remain available.
`v` remains Evil's visual-state key.  `?` shows the same key reference.  The
local `C-c` prefix remains available as a fallback (for example, `C-c k` kills).

## Project-scoped shell commands

`agent-shell` splits every send in two: `agent-shell-send-region` takes the
first shell in the current project without asking, and `agent-shell-send-region-to`
(or a prefix argument elsewhere) reads one instead. You choose between the two
before every send, and the silent one picks arbitrarily when a project holds
several shells.

These commands make one binding decide. The project's only shell is used; when
the project has several, they ask which one; with no shell in the project, or
with a prefix argument, they ask across every shell, whatever project it
belongs to. They pick an existing shell and never start one; `agent-shell` and
the `agent-shell-*-start-client` commands start sessions.

- `M-x agent-shell-vertico-send-region`
- `M-x agent-shell-vertico-send-file`
- `M-x agent-shell-vertico-send-other-file`
- `M-x agent-shell-vertico-send-screenshot`
- `M-x agent-shell-vertico-send-clipboard-image`
- `M-x agent-shell-vertico-send-prompt`
- `M-x agent-shell-vertico-queue-prompt`
- `M-x agent-shell-vertico-steer-prompt`
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
handled, and whether a viewport composes it all stay `agent-shell`'s. Sending
displays the session it went to, so the buffer about to be shown is offered to
`agent-shell-vertico-before-display-function` first, exactly as the switch
commands do.

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

With Embark enabled, `embark-act` on a listed session offers the transcript
actions listed under Embark below, because the choice carries the transcript it
was joined to.

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
- `M-x agent-shell-vertico-transcript-open-session`
  Open the transcript of the session at hand, from its shell buffer or from
  a viewport showing it. With a prefix argument, in another window.

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

`agent-shell-open-transcript` and `agent-shell-viewport-open-transcript` visit
the same file with `find-file`, which leaves the mode to the file itself, so a
transcript reached from a live session gets none of this.
`agent-shell-vertico-transcript-open-session` opens it in the reader instead,
from the shell buffer or from its viewport, so bind that in place of the
upstream commands. The reader makes the buffer read-only, so turn
`agent-shell-vertico-transcript-mode` off to edit a transcript.

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
changing the file's text or modified state. Transcripts open in the clean
view; set `agent-shell-vertico-transcript-default-view` to `full` to open
them as written. A search match on a hidden line opens the full view
regardless, so the reader lands on something visible, and a transcript
already open keeps whichever view it was in.

Both current `**Session ID:**` and legacy `**Session:**` headers are understood.
Session IDs are treated as opaque strings, so providers are not restricted to
UUIDs.

Content search runs `rg --json` asynchronously through Consult, one row per
match rather than one per transcript, and previews the match under point. A row
is `TITLE:LINE: TEXT`, and the annotation beside it adds only what the row
cannot say for itself: the project, the agent, and whether the session can still
be reached. rg is asked for the newest transcript first (`--sortr modified`), so
matches stream to the reader in that order and nothing is held back to be sorted.
A changed query cancels the previous search process. Loading `agent-shell-vertico-consult`
also gives ordinary transcript browsing live preview. A preview opens in the
same mode and the same view as the reader, so a candidate and the transcript
it leads to look alike: the clean view by default, which is what lets a
preview show several exchanges rather than the first prompt and the tool
output after it, and the full view for a match on a line the clean view would
hide. Inline images are turned off because a preview is scanned rather than
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

Search offers those, and narrows by who wrote the line a match is on:

- `u` User, `a` Agent, `m` either of them
- `h` the agent's thoughts, `T` a tool call

A transcript is mostly tool output — over ninety percent of the lines rg
can match, in this author's store — so `m` is usually the difference
between reading a search result and scrolling past a hundred lines of
tool output. `T` is upper case because `t` already means transcript only.

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
         ("C-c a [" . agent-shell-vertico-jump-back)
         ("C-c a ]" . agent-shell-vertico-jump-forward)
         ("C-c a J" . agent-shell-vertico-jump-history)
         ("C-c a q" . agent-shell-vertico-prompt-queue)
         ("C-c a r" . agent-shell-vertico-transcript-browse-project)
         ("C-c a R" . agent-shell-vertico-transcript-resume-project)
         ("C-c a s" . agent-shell-vertico-transcript-search-project))
  :config (agent-shell-vertico-setup))

(use-package agent-shell-vertico-sidebar
  :after agent-shell-vertico
  :bind (("C-c a S" . agent-shell-vertico-sidebar-toggle)
         ("C-c a {" . agent-shell-vertico-sidebar-previous-session)
         ("C-c a }" . agent-shell-vertico-sidebar-next-session)))

(use-package agent-shell-vertico-transcript
  :after agent-shell-vertico
  :bind (("C-c a t" . agent-shell-vertico-transcript-open-session)))

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

The session picker's choices take that same map. Each choice carries the
transcript it was joined to, so `embark-act` on a listed session opens,
resumes, or copies from that transcript. `RET` still selects the session
and lets `agent-shell` resume it. A choice with no transcript on this
machine, such as the one that starts a new shell, reports that and does
nothing.

`rg` is required only for full-text search. Consult is required by
`agent-shell-vertico-consult`; browsing, resuming, reader mode, statistics, and
diagnostics work without it.
