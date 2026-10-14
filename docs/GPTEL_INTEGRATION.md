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

Stage 2 isolates the experimental history format in `emacs-agent-gptel.el`
and tests nil/current/full metadata filtering without mutating stored records.
Tool continuations retain the current turn's initial request data. Before
shipping persistence, extend coverage across actual backend-specific replay. Keep user text, context and provider protocol history separate.
If opaque history cannot be faithfully replayed, fail explicitly rather than
silently sending broken tool linkage.

Streaming callback forms were confirmed from source and live-tested in stage 3
(text chunks, supplied reasoning and per-response completion). Final-run
completion is determined by the request-local FSM lifecycle adapter; do not
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

## Stage 2 live validation

`emacs-agent-gptel.el` now consumes the session FIFO from `emacs-agent-ask`.
Its history builder, provider-ID pairing and callback dispatch isolate the
experimental contracts. Each run captures its source buffer's gptel backend
and model at submission and uses a separate buffer-local transport.

On 2026-10-14, the complete adapter was tested in the running Emacs against
`aiserver` / `main`. Two calls to `emacs-agent-ask` were made with only prompt
input stubbed (no interactive minibuffer interruption):

1. First turn asked for two separate tool calls: insert `STAGE2`, then read it.
2. Second turn was enqueued while the first was active, asking to report the
   prior result using history and no tools.
3. A budget of one paused the first run before its second evaluation. The
   source contained `STAGE2`, first status was `paused`, second was `queued`.
4. Resume delivered the held continuation without retry: tool count became
   two, first completed, and the queued turn started automatically.
5. Both runs completed. Both final answers correctly reported `"STAGE2"`,
   proving real paired tool-history replay into the next user turn.

The journal is `*emacs-agent: global*`, source is
`*emacs-agent-stage2-smoke*`. API keys were not read. No files or shell commands
were accessed by the model. The full batch suite now has 28 passing tests,
including FIFO, independent sessions, duplicate/late callbacks, failure,
source-buffer fallback, pause/resume, self-cancellation result retention and
non-overlapping tool evaluation. Additional regressions cover empty successful
responses, renderer quit and disabled user response tracking. Compilation
passes with warnings as errors.

Final-run completion is observed through request-local FSM terminal handlers,
not inferred from presence of assistant text: gptel can suppress a text
callback for an empty successful response. The private handler table preserves
gptel's handlers and adds DONE/ERRS/ABRT observation; globals are untouched.
Terminal state names and FSM slot access are pinned integration contracts.
The transport locally enables `gptel-track-response` so explicit assistant/tool
roles survive even when the user's unrelated global preference disables it.
After these fixes, another live run with source `gptel-track-response` bound
to nil read `STAGE2` in one call, reported the actual result, reached
`completed`, and released `active-run` to nil. Transport tracking was t; the
source preference was not changed.

## Stage 3 streaming and journal validation

The main adapter now requests streaming by default (`emacs-agent-stream`),
while preserving single-response fallback. Each assistant chunk is a display
event; one assembled assistant message is committed at HTTP completion,
before tool dispatch, or on terminal/error/cancel. `(reasoning . t)` ends a
reasoning section, and plain `t` flushes one HTTP response, **not** the run.
Already received partial text survives cancellation; late chunks are ignored.
Reasoning remains journal-only until opaque replay is validated.

`emacs-agent-log.el` renders only unconsumed event-list entries, appending
adjacent text chunks into marker-delimited sections. Tool/reasoning bodies
use folding overlays and clickable headers. Folding is view-only. Reader
points, window starts and pixel vscroll are preserved; only end-of-buffer
followers advance. Closing the view does not cancel or resurrect it; showing
it again replays retained events. No callback selects a user window.

Live test on 2026-10-14 with `aiserver` / `main` confirmed effective streaming:

- Two separate calls, `(+ 20 22)` and `(buffer-name)`, completed successfully.
- The run received 16 assistant deltas and 46 provider-supplied reasoning
  deltas and reached `completed`, with actual results in the final response.
- A second run's journal was killed while its status was `requesting`; the
  run still completed its `(buffer-name)` call and final response, and the
  journal stayed closed throughout callbacks.
- Explicit rendering recreated the read-only `emacs-agent-log-mode` view,
  with assembled text, foldable sections and the retained final answers.

Source: `*emacs-agent-stage3-smoke*`; journal:
`*emacs-agent: emacs-ai-agent#c576c13636*`. No files, shell or buffer edits
were requested from the model. Input was stubbed, not the live transport.

38 ERT tests pass and compilation remains warning-free. New tests cover
chunk assembly across tool iterations, HTTP-vs-run completion, supplied
reasoning, partial cancellation/error, non-streaming fallback, incremental
append, folding, close/reopen replay and separate reader/follower windows.
Window point/start preservation is tested in batch; pixel-scroll and wrapped
line redisplay are not exhaustively verified across GUI configurations.

## Scope and limitations

The original spike remains stage 0. The main package is stage 3, not the
completed MVP: streaming requests, sessions/context, incremental/foldable
journal, FIFO/cancellation/tool budget and plain-text/paired-tool history
are active. Persistence and opaque provider-history replay remain
unimplemented. Transport/log buffers remain available for inspection; kill
them when finished. The universal evaluator captures `princ`, but does not capture
`message` or backtraces yet. Synchronous Lisp can block the UI. Cancelling does
not undo changes or stop arbitrary subprocesses. Full evaluation can read
secrets, change configuration and delete files: trust the model endpoint.
