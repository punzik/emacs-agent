# Emacs Agent

An Emacs Lisp agent using gptel and one unrestricted `eval_elisp` tool in the
live editor. Project identities separate conversations, not editor access.

**Status: stage 3 (streaming and incremental journal), not the finished MVP.**
`emacs-agent-ask` now sends through your configured gptel backend/model.
Turns are FIFO within a session; different sessions can request concurrently.

- Specification: [docs/EMACS_AGENT_SPEC.md](docs/EMACS_AGENT_SPEC.md)
- Tested gptel baseline, integration decisions, risks and manual smoke test:
  [docs/GPTEL_INTEGRATION.md](docs/GPTEL_INTEGRATION.md)
- Prototype: `examples/emacs-agent-spike.el`
- Reusable evaluator: `emacs-agent-eval.el`

Next: complete history-policy/replay validation (stage 4), then persistence. No global keybindings or user gptel configuration
are changed. The adapter uses the pinned gptel revision documented below.

## Usage

```elisp
(add-to-list 'load-path "/path/to/emacs-ai-agent")
(require 'emacs-agent)
;; Optional user-chosen bindings:
(global-set-key (kbd "C-c a a") #'emacs-agent-ask)
(global-set-key (kbd "C-c a s") #'emacs-agent-show)
```

`M-x emacs-agent-ask` captures the original working buffer/window and editor
positions **before** opening the minibuffer, then queues your text in the
appropriate session. `RET` submits, `C-j` inserts newline, `C-g` aborts;
`M-p`/`M-n` browse user prompt history. Blank input neither creates a session
nor queues a turn. Multiline input uses the ordinary Emacs minibuffer.

`M-x emacs-agent-show` lazily creates/shows the corresponding read-only session
view. It shows user/assistant text, supplied reasoning, tool calls/results and
run statuses. `emacs-agent-stream` defaults to t; unsupported backends may
return a single response, and nil requests non-streaming. Supplied reasoning
is streamed as received, never reconstructed. Context metadata is kept
separate from displayed user text.

The journal is updated incrementally, without erasing/redrawing old entries.
Adjacent text/reasoning chunks share a section; model history contains one
assembled assistant message per HTTP response, not one message per token.
An HTTP stream-end signal does not release the FIFO; only the run's terminal
FSM state does. Cancel/error preserves already received partial text.

Tool arguments/results are initially folded (`emacs-agent-log-collapse-tools`);
reasoning is initially visible (`emacs-agent-log-collapse-reasoning`). `TAB`
or click a foldable header to toggle; folding affects only the live view.
The header line shows active status and queued-turn count. Journal-local
bindings: `a` asks, `C-c C-k` cancels, `C-c C-c` resumes, `g` consumes any
unrendered events. Readers of old text retain point/window-start/pixel scroll;
only points already at the end follow new text. Windows are never selected
by callbacks. Closing the journal does not cancel a run or resurrect the
view on subsequent chunks; `emacs-agent-show` replays all retained events.
Two non-project buffers share the global session; files in one project share
its canonical root key. Symlinked local roots are resolved when possible;
remote roots are never locally canonicalized. Same-basename projects remain
separate, with distinct journal names.

Asking from a journal retains its owner session and captures its last live
working buffer, not the journal. If that buffer died, ask from a working
buffer instead. Showing the journal still works without a live source.

Snapshots store absolute positions and widening-aware line/column (1-based
line, 0-based column), plus narrowing bounds, file/mode/directory and optional
region text. `emacs-agent-region-text-limit` defaults to 8192 characters;
longer selections retain only bounds. No full buffer is captured. Context is
serializable framed JSON, escaped so buffer names/region text cannot forge
section delimiters; it never appears as part of displayed user text.

`emacs-agent-context-history` defaults to `current`: only the active user
turn's snapshot is sent, including every tool continuation. `full` includes
all user snapshots; nil sends no automatic context. Tool arguments/results
and assistant/user text are never removed by this policy. Basic filtering is
already active; opaque provider reasoning/history replay remains a stage 4
validation item (reasoning is currently journal-only).

`M-x emacs-agent-cancel` cancels the active run in the current session and
allows the next queued turn to start. Late callbacks are ignored; prior Lisp
side effects remain. There are no automatic retries of network requests or
side-effecting evaluations.

`emacs-agent-max-tool-calls` defaults to 100. At the limit the run pauses before
the next evaluation and holds pending continuations. `M-x emacs-agent-resume`
grants another block of calls without restarting the request or reexecuting
completed tools. Paused runs retain their session slot until resumed/cancelled.
All tool evaluation is serialized across sessions, including during recursive
Emacs event loops. Tools default to the live source buffer, or the run's
transport if it died; windows and captured point/region are not restored.

Sessions/queues currently last only for the Emacs process lifetime.
Save/session-list commands and transport-buffer reclamation are not
implemented yet.

The tested Emacs 30.2 has no built-in `edit-minibuffer` command; no fictitious
`C-M-c` binding or custom editor is supplied. Existing user minibuffer editing
extensions can use normal minibuffer hooks/keymaps. Editing long prompts in a
separate buffer remains a UX integration item for later polishing.

## Test

Requires Emacs and the gptel revision documented above in an ELPA directory.
The full suite has 38 ERT tests; it uses mocks and dry-run requests, not API
keys. Stage 1 modules do not require gptel and can be tested independently:

```sh
emacs -Q --batch -L . -l test/emacs-agent-session-test.el \
  -l test/emacs-agent-context-test.el -f ert-run-tests-batch-and-exit
```

```sh
nix-shell -p gnumake --run 'make clean test compile'
# Or with make already available:
make ELPA=/path/to/elpa test compile
```

## Security

Only connect to a trusted endpoint. `eval_elisp` can read secrets, execute shell
commands, modify editor configuration and delete files without confirmation.
Lisp executes synchronously and can block Emacs. Cancellation does not roll
back changes or guarantee termination of subprocesses.
