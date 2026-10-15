# gptel integration — stage 0

## Post-MVP: buffer-native editing and undo

`emacs-agent-replace-region` is an ordinary Lisp helper invoked through the
same unrestricted `eval_elisp`. It checks exact old text and an expected tick,
edits the live buffer as one atomic undo step, and never writes disk itself.
Save explicitly with `save-buffer`, which also updates visited-file modtime.
The system prompt now documents this protocol and warns against fake saves,
external writes to visited files, clearing undo or routine revert.

[ADR-0002](adr/0002-buffer-native-editing.md) records the session evidence and
contract. Regression tests reproduce the logged three-argument `write-region`
plus `set-buffer-modified-p nil` bug and verify save/undo/file-modtime behavior.
The follow-up prompt explains zero-based string indices vs buffer positions,
including a narrowed buffer's capture-time `point-min`. OLD mismatch errors
show a bounded escaped actual-text preview; models are told to reread rather
than guess offsets or bypass a rejection. This is guidance, not enforcement.
Validation: 83 offline ERT tests and warning-as-error byte compilation via
`nix-shell -p gnumake --run 'make clean test compile'`. A subsequent user-run
live session confirms six helper replacements, rereading after OLD mismatch
without bypassing the helper, and saving through `save-buffer`. The user also
confirmed that undo works. Post-save file-modtime was not explicitly measured.
For repeatable smoke in a disposable visited file: make a user edit, ask the model for a small helper replacement
and explicit save, check that no reload warning appears, undo the helper
replacement and then the earlier user edit separately. Do not use real work
files for this test. Reload updated Lisp definitions before testing in an
already-running Emacs; an existing in-flight request retains its old prompt.

## Post-MVP F0: live buffer helpers

`emacs-agent` now loads `emacs-agent-helpers.el`: ordinary Lisp functions for
absolute line ranges, explicit-position context and buffer metadata. They are
called through the existing `eval_elisp`; no changes to gptel tool dispatch,
transport, replay, settings or hooks were needed. An adapter test checks that
exactly one tool is selected and that a real helper reads the source buffer
through a mocked provider call. Existing real-gptel dry-run tests still pass.

The helper budgets its printed plist and evaluator prefix together, shrinking
text while retaining continuation metadata. This assumes it is the sole final
form with no stdout; the generic evaluator is unchanged. Impossible metadata
budgets signal errors. Full output artifacts remain F3.

Validation: 69 offline ERT tests pass; warning-as-error byte compilation passes
on the baseline below, via `nix-shell -p gnumake --run 'make clean test compile'`.
F0 real-provider smoke has **not** been run. Optional smoke: use a disposable
buffer with leading/consecutive empty lines, capture a point at a symbol, ask
the model to read that symbol and absolute line 14 with helpers. Check actual
tool results and retained empty lines, not just the final prose. Do not let
this opt-in test modify real project files.

Contract: [ADR-0001](adr/0001-f0-buffer-helpers.md).

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
shipping persistence, extend coverage across actual backend-specific replay.
Keep user text, context and provider protocol history separate.
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

## Stage 4 protocol contracts and live validation

The replay boundary is now explicit: only `gptel-openai` Chat Completions
backends are supported. Responses API (`gptel-openai-responses`), Anthropic,
Gemini and other backend structs fail before network submission. Their
signatures/encrypted reasoning are not safely represented by the experimental
list history API. Backend constructor name alone is insufficient: the default
OpenAI host selects Responses even with a supplied chat endpoint.

Inspected Chat parsing preserves original assistant tool messages in
`:data :messages`; streaming can carry `:reasoning` or `:reasoning_content`.
These known textual fields are copied into canonical tool records and restored
before every WAIT handler sends the generated data. Reasoning without tool
calls remains journal-only. Unknown assistant/tool/function fields and observed
opaque INFO fields cause explicit failure and a non-replayable history marker;
future turns are blocked rather than replaying an incomplete transcript.
No opaque contents are logged/reconstructed, only the failure's field name.

This does **not** guarantee detection of proprietary extensions that upstream
gptel already discarded, especially unknown streaming delta fields. Such
endpoints are outside the supported plain/text-reasoning Chat contract.

Another pinned behavior discovered by actual dry-run tests:
`gptel--openai-format-tool-id` prepends `call_` to some provider IDs. The
request-local WAIT adapter restores original IDs in both assistant calls and
tool results and restores known reasoning fields. Formatted-ID collisions,
duplicate calls, malformed records, unknown protocol fields and cross-turn
records are rejected by validation before sending. Known call indices restore
streaming batch execution order: its parser otherwise reverses `:tool-use`.

Policy is frozen at submission. Stored snapshots remain immutable while the
wire builder filters only editor metadata. Private transports disable gptel
chat UI truncation and use `:transforms '(ignore)` to avoid ambient transforms
adding/removing context. Global settings/hooks remain unchanged.

Live validation on 2026-10-14 used the opt-in fixture in
`test/manual-history-smoke.el` with `aiserver` / `main`. Three FIFO turns with
nil/current/full each completed two tool calls, using only `(+ 20 22)` and
`(buffer-name)`. An earlier synthetic user snapshot seeded the fresh fixture.
Outgoing messages were copied after replay restoration and before HTTP dispatch
(no keys, backend objects or headers):

| Policy | Context blocks on successive requests | Completed tools |
|---|---|---|
| nil | 0, 0 | 2 |
| current | 1, 1, 1 | 2 |
| full | 4, 4 | 2 |

Some responses batched both tools, so not every run needed three requests.
Every observed tool result matched an earlier assistant call ID. All six tool
records retained textual protocol reasoning, and later turns replayed it.
Full included the seed plus all three captured user turns, including metadata
that earlier nil/current policies did not send. The observer advice was removed
after the test; no global gptel hooks were installed or changed.

Optional reproduction in a trusted configured Emacs:

```elisp
(load "/path/to/emacs-ai-agent/test/manual-history-smoke.el")
(emacs-agent-history-smoke-start)
;; After all `emacs-agent-history-smoke-runs' are terminal, inspect
;; `emacs-agent-history-smoke-requests', then always remove the observer:
(emacs-agent-history-smoke-stop-observer)
```

45 ERT tests and warning-as-error compilation pass. New tests use actual gptel
parsing, dispatch and dry-run serialization to verify policies, original IDs,
arguments/results and textual reasoning; additional regressions cover frozen
policy, transform/truncation isolation, unsupported backend preflight, opaque
field poisoning, nested signatures and streaming batch order. Other providers
are deliberately rejected, not claimed to have been integration-tested.

## Post-MVP F0c: model I/O efficiency (first slice)

A user comparison found 37 vs 3 tool calls and 136,919 vs 3,483 characters of
textual tool results. `buffer-string` had serialized font-lock/eglot properties;
verbose per-line helper metadata, redundant reads and a destructive verification
followed by recovery also contributed. These are character counts, not provider
usage: the Emacs log does not record usage; Pi has 4,349 uncached input+output
and 13,213 including cache reads. The actual model behind Emacs alias `main`
was not established. Full evidence/remaining contracts:
[ADR-0004](adr/0004-efficient-model-io.md). No private logs are test fixtures.

The first slice strips properties from string final values before printing
and reads captured stdout without properties; it does not mutate source data
or recursively rewrite arbitrary non-string Lisp values. Explicit printing
inside evaluated Lisp is not intercepted. Tool definition/count, protocol
history and gptel lifecycle are unchanged. The prompt now recommends plain
reads, avoiding redundant whole-file reads and never mutating a buffer just
to inspect it. Compact reads, batch exact-text edits and usage records remain
pending; do not call this a completed token-efficiency fix.

Validation: **99 offline ERT tests** and byte compilation with warnings-as-errors
via `nix-shell -p gnumake --run 'make clean test compile'`. Tests cover properties
without source/undo changes, huge property metadata under a small output budget,
Unicode/empty strings, explicit property inspection/printing and real pinned
gptel dry-run wire content. Existing stdout/errors/limits/replay tests pass.
No real-provider comparison has been run after this slice.

## Post-MVP F0b: durable streaming blocks (schema 2)

The current store writes **schema 2**, pretty-printed Lisp data. Schema 1 is
rejected; no migration or compatibility reader is provided during deep alpha.
Use a new private `emacs-agent-data-directory` for testing without touching old
archives. The stage-5 schema-1 observations below are historical, not a claim
that old snapshots can be loaded by current code.

Only a validated deep snapshot copy of `:events` is compacted. Adjacent string
assistant/reasoning events of the same session/run/type become one block with
literal concatenated payload, first ID/time, last ID/time and partial/complete
state. End/tool/status/type/run/unknown-metadata boundaries remain distinct.
`complete` requires an immediately following matching end marker; it denotes
an accumulator flush, including cancel/error, not success. Interleaved earlier
segments remain conservatively partial. Per-token IDs/times between block
endpoints are intentionally discarded, not retained in a hidden array.

Live event conses, renderer cursor, gptel callbacks and accumulated chunks are
unchanged. Canonical `:messages`, tool IDs/results and protocol reasoning
remain independent. Checkpoint copies of unfinished assistant text are retained
without flushing live state. Restart renders blocks directly and bumps IDs
using `:last-id` too; active/pending runs still become interrupted, never resume.
Atomic rename/permissions, corruption isolation and the five-second stream
checkpoint cadence remain in place. No append-only/tree refactor was added.

Validation: **95 offline ERT tests** and byte compilation with warnings-as-errors
pass via `nix-shell -p gnumake --run 'make clean test compile'`. Tests compare
actual rendered text/fold bounds, interleaving/empty chunks/boundaries, repeated
checkpoints followed by continuation without duplicates, cancel/error,
restored blocks plus new deltas, ID bumping, malformed blocks, schema-1 refusal,
write/rename failure cleanup and independent fresh-process restore without
loading gptel. Actual pinned-gptel dry-run wire JSON is identical before/after
restore for all context policies, including original tool pairs and protocol
reasoning; final-answer reasoning remains in the journal even when absent from
model messages. Synthetic size fixture: 4,002 events -> 4, approximately
460 KB -> 11 KB (~42x); this fixture has no canonical model messages, so it is
not a forecast for arbitrary user archives. Live memory and full-history scan
cost remain. No real-provider F0b smoke has been run. Optional smoke in a new
private store: stream a reply, checkpoint mid-stream, finish/save, restart,
check the journal and continue with one turn. Do not edit old private logs.

Contract and local Pi/Pigo research: [ADR-0003](adr/0003-durable-streaming-blocks.md).

## Stage 5 persistence and restart validation (historical schema 1)

`emacs-agent-store.el` stores one versioned Lisp-data snapshot per canonical
session, below `emacs-agent-data-directory` (default under the user's Emacs
directory). The filename is `global.eld` or a root hash. Schema 1 records the
adapter contract, session identity/root, events/messages, timestamps, source
name/file and durable run audit fields. Backend name/model and agent request
settings are recorded; backend credential objects, HTTP handles, functions,
buffers/windows/markers/processes are never serialized. Data is read, never
loaded/evaluated as code. This stage originally required explicit migration
for unsupported schema/adapter files; current deep-alpha schema 2 deliberately
provides no migration or compatibility reader (see F0b above).

Writes use a same-directory 0600 temporary file and rename; newly created
storage directories are 0700. Serialization rejects live objects, closures,
cycles/deeply nested data and strips string properties. The old snapshot is
left intact on failure. Autosave happens at tool/status boundaries and at
most every five seconds for text/reasoning deltas. A partial assistant message
is copied into a checkpoint without mutating/flushing the live run. Hook
failures are isolated so a broken renderer cannot prevent a later save hook.
Save failures are reported, not turned into side-effecting retries.

Restore is lazy per canonical key; session-list scans files independently.
Corrupt files warn/fail with their path without discarding valid sessions,
and direct access never silently creates a fresh replacement. Pending/active/
paused tasks are represented by `interrupted` events, not runtime runs. Pending
text/audit stays in the journal; no tasks, callbacks or subprocesses are
recreated. Source references reconnect only to matching already-open buffers;
no files are auto-opened. Runtime callback ownership additionally requires the
registered session object, rejecting stale objects after registry replacement.

An independent `emacs -Q --batch` process loaded a scratch-directory snapshot
of the real stage 4 conversation: 14 messages, six original-ID tool pairs and
six textual reasoning fields survived actual gptel dry-run serialization.
Active/pending state was nil. The working editor was **not** restarted and
its backend credentials were not read/copied into the fresh process.

The snapshot was also reloaded into an isolated fixture in the configured
live Emacs. A new real LLM turn, with zero tools, correctly recalled both the
arithmetic result `42` and exact prior buffer name
`*emacs-agent-history-smoke*`, distinct from its new source. All test persistence
was written to a private `/tmp/emacs-agent-persistence-smoke-*` directory,
not the repository/default user's storage. Observer/fixture code did not alter
global gptel hooks/settings.

58 ERT tests and warning-as-error compilation pass. Persistence regressions
cover save/load root mapping, original tool/reasoning replay, partial/queued
interruption without resume, permissions, rename failure/temporary cleanup,
corruption isolation, schema mismatch, no code evaluation, live-object/cycle
rejection, source absence/remote roots, broken render hooks, stale callbacks
and session-list navigation. Review found an unguarded `copy-tree` before cycle
validation; guarded copying and a full save-path regression now reject it
without hanging or replacing the old file.

## Scope and limitations

Stages 0–5 are implemented for the stated Chat Completions boundary:
streaming, sessions/context, incremental/foldable journal, FIFO/cancellation/
tool budget, validated tool/reasoning replay and durable snapshots. Unsupported
opaque protocols still fail explicitly. Transport/log buffers remain available for inspection; kill
them when finished. The universal evaluator captures `princ`, but does not capture
`message` or backtraces yet. Synchronous Lisp can block the UI. Cancelling does
not undo changes or stop arbitrary subprocesses. Full evaluation can read
secrets, change configuration and delete files: trust the model endpoint.
