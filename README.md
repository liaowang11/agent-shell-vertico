# agent-shell-vertico

`agent-shell-vertico` adds a Vertico-friendly switcher for `agent-shell`
buffers and an Embark action map for controlling the selected session.

## Commands

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
```

With Embark enabled on an `agent-shell-vertico` candidate, the extra
session actions follow `agent-shell-manager` closely:

- `c` create a new shell
- `k` kill the selected shell process
- `r` restart the selected shell
- `t` view traffic
- `T` open transcript
- `l` toggle logging
- `i` interrupt session
- `m` set session mode
- `M` set session model

Normal `embark-buffer-map` actions stay available too.
