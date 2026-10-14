# Emacs Agent

An Emacs Lisp agent using gptel and one unrestricted `eval_elisp` tool in the
live editor. Project identities separate conversations, not editor access.

**Status: stage 1 (sessions/context/input), not the finished MVP.**
`emacs-agent-ask` currently queues turns only: it does not send LLM requests.
The separate stage-zero spike can still run real gptel tool loops.

- Specification: [docs/EMACS_AGENT_SPEC.md](docs/EMACS_AGENT_SPEC.md)
- Tested gptel baseline, integration decisions, risks and manual smoke test:
  [docs/GPTEL_INTEGRATION.md](docs/GPTEL_INTEGRATION.md)
- Prototype: `examples/emacs-agent-spike.el`
- Reusable evaluator: `emacs-agent-eval.el`

Next: connect the session FIFO to the gptel adapter with cancellation and
limits (stage 2), then event/streaming UI, context-history policies and
persistence. No global keybindings or user gptel configuration are changed.

## Stage 1 usage

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
view. It currently lists queued user text, not a full event transcript.
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

`emacs-agent-context-history` is declared with default `current`, but API
history filtering is not active until stage 4. Sessions and queues currently
last only for the Emacs process lifetime. Cancel/save/session-list commands
and streaming are not implemented yet.

The tested Emacs 30.2 has no built-in `edit-minibuffer` command; no fictitious
`C-M-c` binding or custom editor is supplied. Existing user minibuffer editing
extensions can use normal minibuffer hooks/keymaps. Editing long prompts in a
separate buffer remains a UX integration item for later polishing.

## Test

Requires Emacs and the gptel revision documented above in an ELPA directory.
The full suite has 16 ERT tests; it uses mocks and dry-run requests, not API
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
