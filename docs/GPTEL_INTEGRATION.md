# gptel integration — stage 0

## Tested baseline

Inspected the actual installed source, not examples from a different release:

- Emacs **30.2**; proposed package minimum **28.1** (not tested yet).
- gptel package **20260805.313**, internal version **0.9.9.5**.
- Commit **fc6963634af2f76a9909ad674e2c0b3f005e60b5** from `gptel-pkg.el`.
- Installed source: `~/.emacs.d/elpa/gptel-20260805.313/`.
- Dependencies in the tested installation: compat 31.0.0.2 and transient
  20260806.1211. The repository does not vendor or automatically update gptel.

This is the supported experimental baseline, not a claim of compatibility
with every gptel release. Load this revision for reproducible contract tests.

## Confirmed interfaces

`gptel-request` takes an optional prompt and keyword arguments including
`:callback`, `:buffer`, `:system`, `:stream`, `:context`, `:dry-run`, and
`:transforms`. It returns a state machine, not an HTTP process.

The callback receives `(response info)`. Publicly documented responses:

- string: assistant content; with streaming, one chunk at a time;
- nil: error/no response; `info` provides `:status`;
- `abort`: aborted;
- `(tool-call . ((TOOL ARGS CONTINUATION) ...))`: pending tool calls;
- `(tool-result . ((TOOL ARGS RESULT) ...))`: completed tools;
- `(reasoning . TEXT)`: supplied reasoning;
- streaming `t`: HTTP response completion, **not necessarily whole-run
  completion**, because another tool iteration may follow.

`gptel-make-tool` accepts `:name`, `:function`, `:description`, `:args`,
`:confirm`, and other slots. It registers a tool in gptel's known-tool registry,
which is an intentional public API effect. The spike does not change the
user's selected `gptel-tools`, backend, model, or hooks.

`gptel-abort BUFFER` aborts requests associated with that buffer. Each spike
has a dedicated transport buffer, so cancelling it does not abort a user's
unrelated gptel chat.

## Tool loop decision

Reuse gptel's existing network/tool continuation loop. Build agent scheduling,
events and terminal-state guards around it rather than reimplementing HTTP.
The spike sets `gptel-confirm-tool-calls` and tool `:confirm` locally to `t`
**only to route calls to the callback**. The callback executes them immediately:
there is no approval UI. This permits cancellation guards and deduplication
before execution, rather than letting gptel invoke Lisp before our callback.

The callback's public pending-call tuple does not contain the provider ID.
`emacs-agent-spike--ids` isolates access to the undocumented `info :tool-use`
plists. The pinned implementation builds pending callbacks using `push`, in
reverse provider order. The spike reverses the callbacks before executing
side effects and associates them with the original ID order. An actual-gptel
contract test verifies two calls execute in order and are not repeated.
This contract needs revisiting when gptel changes.

The spike is non-streaming. Text accompanying a tool call is not treated as a
final answer. It supports sequential requests with several tool iterations,
and multiple calls in one response. Cancellation ignores late callbacks.
There is no automatic retry of side-effecting Lisp.

## History boundary and risks before stages 1–5

A plain list of alternating strings is public but cannot represent tool
history. The implementation additionally accepts explicit entries:

```elisp
((prompt "user text")
 (response "assistant text")
 (tool :id "provider-id" :name "eval_elisp"
       :args (:expression "(+ 1 1)") :result "2")
 (prompt "next turn"))
```

This format is explicitly **experimental** in `gptel--parse-list-and-insert`.
A real `gptel-request :dry-run t` test confirms Chat Completions preserves the
call ID and result linkage. The actual default OpenAI host selects the
Responses API in this revision, regardless of a supplied chat endpoint;
the test uses a different offline host to exercise Chat Completions.
Responses API / Anthropic opaque reasoning and replay have **not** been
validated for persistence. Do not discard reasoning signatures or replay
provider-specific data as plain text.

Before shipping sessions/persistence, isolate the experimental history format
in one adapter and test nil/current/full metadata filtering with multi-call
continuations. Keep user text, context and provider protocol history separate.
If opaque history cannot be faithfully replayed, fail explicitly rather than
silently sending broken tool linkage.

Streaming callback forms were confirmed from source, not yet live-tested.
Non-streaming reasoning callbacks were also observed with the real local LLM. Final-run detection needs its own tested lifecycle adapter; do not
mistake a per-HTTP streaming `t` for the end of a tool loop. Existing tool hooks
must not be globally overwritten. Backend/model should be captured from the
source buffer on each new run and kept local to its transport buffer.

## Reproduction

From this repository, on the tested NixOS environment:

```sh
nix-shell -p gnumake --run 'make clean test compile'
# Elsewhere, point ELPA at a package directory containing the pinned gptel:
make ELPA=/path/to/elpa test compile
```

Five offline ERT tests pass. They cover actual multiple-form Lisp evaluation,
errors/quit/truncation, a fixed two-iteration request mock, duplicate/late
callbacks, real gptel multi-call dispatch/order, and real dry-run history
construction. Byte compilation of both implementation files passes with
warnings treated as errors. Mocks do not prove real provider behavior.

Optional manual end-to-end test in an Emacs with a trusted configured gptel:

```elisp
(add-to-list 'load-path "/path/to/emacs-ai-agent")
(add-to-list 'load-path "/path/to/emacs-ai-agent/examples")
(require 'emacs-agent-spike)
;; Evaluate in a disposable working buffer:
(setq my-agent-run
      (emacs-agent-spike-start
       "Use eval_elisp to insert SPIKE in the current buffer, then use a second tool call to read buffer-string. Report the actual result."))
(display-buffer (emacs-agent-spike-log my-agent-run))
;; If necessary:
(emacs-agent-spike-cancel my-agent-run)
```

Expected: two tool-call/result events, visible buffer modification, then a
final assistant response. Run again with invalid Lisp to test recovery.
A real local-provider smoke test was run on 2026-10-14 through the running
Emacs server, using backend `aiserver`, model `main`. It completed five tool
calls: an initial buffer-name error, checking/creating the buffer, inserting
`SPIKE`, then reading it in a separate call. The final answer reported the
actual `"SPIKE"` result. This confirms real tool continuation, error recovery,
and supplied reasoning. The initial error arose because the model dropped
the leading space in a hidden test-buffer name; avoid ambiguous names in
manual prompts. Only disposable test buffers were used.

A second clean test with `*emacs-agent-live-smoke-2*` completed exactly two
separate tool calls: `(insert "SPIKE") (buffer-name)` followed by
`(buffer-string)`. The source buffer contained `SPIKE`, the second result was
`"SPIKE"`, and the run reached `completed`. This also live-tests multiple
forms in one expression and the default source-buffer execution context.
The transcript remains in `*emacs-agent-spike*<2>` for inspection.

Credentials were not read. Batch tests did not load user configuration; the
live test intentionally used the existing configured Emacs process.

## Scope and limitations

The spike remains stage 0, not the completed MVP. The separate stage 1
modules now provide project/global identity, captured context, minibuffer
input and a queued-turn view (see README), but do not yet call this adapter.
Metadata history policy, persistent history, streaming UI and configurable
tool-call budget remain unimplemented. Transport/log buffers remain available
for inspection; kill them when finished. The universal evaluator captures `princ`, but does not capture
`message` or backtraces yet. Synchronous Lisp can block the UI. Cancelling does
not undo changes or stop arbitrary subprocesses. Full evaluation can read
secrets, change configuration and delete files: trust the model endpoint.
