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
budgets signal errors. Full output artifacts were deferred at this milestone;
the later minimal F3 behavior is documented below.

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

## Post-MVP F0c: model I/O efficiency

A user comparison found 37 vs 3 tool calls and 136,919 vs 3,483 characters of
textual tool results. `buffer-string` had serialized font-lock/eglot properties;
verbose per-line helper metadata, redundant reads and a destructive verification
followed by recovery also contributed. These are character counts, not provider
usage: those original Emacs logs did not record usage; Pi has 4,349 uncached input+output
and 13,213 including cache reads. The actual model behind Emacs alias `main`
was not established. Full evidence/remaining contracts:
[ADR-0004](adr/0004-efficient-model-io.md). No private logs are test fixtures.

The first slice strips properties from string final values before printing
and reads captured stdout without properties; it does not mutate source data
or recursively rewrite arbitrary non-string Lisp values. Explicit printing
inside evaluated Lisp is not intercepted. Tool definition/count, protocol
history and gptel lifecycle are unchanged. The prompt now recommends plain
reads, avoiding redundant whole-file reads and never mutating a buffer just
to inspect it. Compact read results are now implemented: one literal `:text` and range
metadata, no `:lines` rows or line numbering. Internal newlines are preserved,
the newline after requested END is excluded. Exclusive end is the continuation
position; concatenate chunks without adding separators, including when split
on a newline. Around retains `:at`. This intentionally changes the alpha helper
API, without a compatibility mode. Per-HTTP/run usage is now implemented below;
its implementation is not evidence of token savings on the original task.

`emacs-agent-replace-texts` now takes a list of unique OLD/NEW pairs and one
expected tick for the entire batch. It finds all literal, case-sensitive OLD
ranges in the original accessible text, rejects ambiguity/self-overlap/range
overlap before edits, applies bottom-up, and uses one atomic undo group.
Normal hooks remain active; OLD is rechecked at each planned position. Any
error, including output-budget failure, rolls back all edits in that buffer.
A shared replacement primitive anchors insertion across deletion hooks, checks
OLD after before-change hooks, and resets point after hooks that move it.
Region-helper result bounds also track markers when hooks shift the anchor.
The result is only buffer/tick/modified/changed-count; saving is separate with
`save-buffer`. This remains ordinary Lisp through the sole `eval_elisp`, not a
new tool or unrestricted-eval rollback guarantee. The system prompt now prefers
this batch API instead of computing offsets or managing per-edit ticks.

Validation: **135 offline ERT tests** and byte compilation with warnings-as-errors
via `nix-shell -p gnumake --run 'make clean test compile'`. Tests cover properties
without source/undo changes, huge property metadata under a small output budget,
Unicode/empty strings, explicit property inspection/printing and real pinned
gptel dry-run wire content, including the actual compact-read tool message.
Continuation coverage now includes newline characters, EOF empty lines,
mid-line fragments and printed-budget shrinking with properties/escaping.
Existing stdout/errors/limits/replay tests pass. A synthetic 100-line fixture
shrinks from about 7,532 to 2,144 printed characters (~72%, not a token count).
The prompt now gives 7 executable examples instead of placeholder-only API
hints: tests extract the actual fenced code and run metadata/read/continuation,
read→batch, around, read→region and save in disposable visited files. Stale
continuation ticks fail; local bindings are not assumed across tool calls.
Reading and buffer-info metadata now include absolute :total-lines (including
the terminal empty line). The primary prompt example bounds END by this count
and returns the full helper result; field extraction stays local to a consuming
eval. Tests also run that exact example on empty, short and >100-line files.
The structured prompt is 4,984 vs the former 5,037 characters, not a token measure.
The user-run compact-read test subsequently showed 18 tools/12,298 result
characters and exposed a manually built batch failing after its first edit.
New batch tests cover all-or-nothing/undo/history, ambiguity/case/overlaps,
no-op/read-only/hooks/narrowing, conflict/save behavior and one actual wire tool
call with compact output. Subsequent user-run batch smoke confirmed six
replacements in one call, 5 tools/10,151 result characters/0 errors. Metadata-only
guidance then removed a redundant text read: 6 tools/7,795 characters, with one
invented :fields API error before any edit. The executable-example prompt's
user-run smoke returned 7 tools/3,065 characters/1 EOF error: six changes and a
save succeeded, with no post-edit read. That run discarded read metadata and
guessed END=200, then needed buffer-size/count-lines recovery. The :total-lines
and full-result revision then passed user smoke: 4 tools/7,609 characters/0 errors.
Its verification returned :truncated t and left 550 characters unread. The latest
prompt now forbids claiming full verification from partial reads: continue the
same range/tick until complete, or explicitly state the checked scope. Checking
only changed ranges is sufficient; whole-file rereads are not mandated. This
latest prompt's user smoke returned 5 tools/7,685 characters/1 validation error
(an empty replacement pair, rejected before edits). The corrected six-edit
batch and save succeeded. Verification contained all six NEW blocks completely;
only 75 characters of unchanged function body remained unread. This establishes
changed-block coverage, not full-file verification. Task-specific documentation
quality is a model issue, not a new agent constraint.
These are character counts, not usage measurements;
undo/rollback were not directly tested in these successful live batches.
Reload `emacs-agent-helpers.el` and `emacs-agent.el` before testing; use a clean session
for a fair size/usage comparison, since previous tool results are not rewritten.

### Per-HTTP and run usage

Pinned gptel 0.9.9.5 Chat Completions exposes current-response `:tokens` and
cumulative `:tokens-full` plists. WAIT clears current tokens. Streaming TYPE is
entered on headers, before body usage exists; successful empty/tool-only
non-streaming responses need not deliver a text callback. We therefore prepend
private WAIT bookkeeping and TOOL/DONE/ERRS/ABRT observers, before tool dispatch
can recurse into a new WAIT. No global gptel handlers, hooks or advice change.
Callbacks update a copied observation, not a sum. Cancellation reads FSM info
before terminal guards: stream usage may have been parsed without another
callback. Assistant chunks are flushed before usage events so durable block
completion still sees adjacent assistant-end.

`emacs-agent-usage.el` emits one `usage` event per closed HTTP attempt and a
`usage-total` event per run. Active snapshot run audit also contains `:usage`;
an unfinished request remains unknown after interrupted restore. Existing schema
2 event persistence/replay handles these serializable fields; no canonical
message changes and no migration are needed. Both event types display explicit
counts in the journal, including when reopened.

Counts carry `:source gptel-normalized`. `:input` is uncached input, `:cached`
cache-read, `:output` output; input-total adds input and cached, total then adds
output once. A missing/invalid count is `unknown`, not zero; a missing request
makes the corresponding run total unknown. `:tokens-full` is copied only for
reconciliation, never repeatedly summed. A critical limitation: gptel already
defaults some absent raw provider fields to zero. Normalized cached=0 cannot
prove that the provider reported no caching. Billing, context-window size,
raw field presence and server-resolved physical model are not inferred.

135 ERT and warnings-as-errors compilation pass, including real pinned
normalization, recursive TOOL→TRET→WAIT (only HTTP stubbed), duplicate/late
observations, missing usage with old cumulative, empty success, early TYPE,
parse-without-callback cancellation, independent sessions, pending restart,
complete durable non-stream blocks, journal replay and unchanged API history.
Independent review reproduced the cancellation timing bug; the FSM snapshot fix
and regression were applied before the final live check.

Authorized live smoke used the already-running Emacs's configured `aiserver` /
`main` (physical model unknown), on temporary empty buffers. Both streaming and
non-streaming completed one `(+ 17 25)` tool call and two HTTP requests, returned
42, and left source unchanged. Final request sums matched final cumulative:

| Mode | Uncached input | Output | Cache-read | Input total | Total |
| --- | ---: | ---: | ---: | ---: | ---: |
| Streaming | 262 | 85 | 3041 | 3303 | 3388 |
| Non-streaming | 333 | 85 | 3256 | 3589 | 3674 |

Private snapshots/metrics were 0600 under temporary directories, not fixtures or
committed logs. The second mode inherited the first turn's history, so these
numbers validate accounting only, not comparative mode efficiency or savings
against Pi. A fresh same-task/model/cache-state benchmark remains optional.

## Post-MVP F6: conversations without migration

F5 is deferred. F6 separates immutable global/project scope from conversation ID.
The registry is ID→object; scope→selected-ID is a separate map. Run, input and
summary callback liveness uses registration/object identity, not selection. A
nonselected journal remains an explicit target; opening it never selects it.
Working-buffer ask captures an existing target before reading the minibuffer.

New `emacs-agent-session-new`, `-rename`, `-select`, `-search` and `-clone` commands use
existing journals. Selection is scope-local; search/list inspect all scopes
without a model/backend/index or following F3 artifact references. Name is only
metadata; IDs distinguish duplicate names and same-basename roots. List RET
shows without selection. New/select/clone require involved conversations idle;
rename requires its own idle target. Prepared/queued inputs, paused runs and
compaction count as busy; withdrawn recovery stays with the original archive.

Schema **3** uses `conversations/<hash-ID>.eld` and project selection pointers
in `selections/<hash-root>.eld`. Per explicit user decision, root-level legacy
`global.eld`/`project-*.eld` are untouched but never imported, listed or selected.
There is no migration or schema-1/2 reader. The remaining milestone sections
below describe their historical schemas, not current compatibility promises.
Data-only reading, validation-before-registration, private 0600/0700 modes,
atomic rename, linear writer and inert restart recovery remain.

The first implicit global use in each Emacs process creates a fresh conversation;
loading catalogs does not select old globals. Explicit old-global selection lasts
for that process, not the next restart. Project selection restores from its
validated pointer. Missing/corrupt targets fail explicitly. Normal autosave writes
only a conversation, never a pointer. Initial project identity/pointer is durable
even with autosave off, but does not force later chat checkpoints.

New/select/clone save old/source/candidate and project pointer before publishing.
Failure leaves the prior in-memory choice/history/queue unchanged; a durable
candidate can remain unselected. Rename saves a preview before changing metadata.
A short mutation lock rejects reentrant new admissions and explicit recovery
before ledger/source mutation. Already accepted F2 final-boundary work in other
conversations is not blocked. There is no implicit cancel, queue transfer or
cross-project reassignment.

Clone allocates a fresh ID with source-ID/time provenance; deep-copies messages,
events and compaction, rewriting event session IDs while preserving historical
run/input/tool IDs. It clears inputs/queues, usage anchor and source/backend/
transport/summary handles. Nothing executes; old F3 paths remain references.
The UI may freshly bind an explicit working buffer after selecting a conversation,
never deriving execution authority from copied event payloads.

252 ERT and warnings-as-errors compilation/diff-check pass. Fresh backend-free
subprocess tests prove global restart uniqueness, explicit old-global continuation,
project selection and no reload duplicates. Real pinned-gptel dry-run/tool tests
cover nonselected owners and cloned wire/reasoning/IDs across context policies.
Failure injection and mutation reentrancy regressions pass. An independent
read-only review found no supported F6 issues; it did not run the full suite.
No real-provider F6 smoke or user-Emacs hot-load was performed. Restart is required.
See [ADR-0012](adr/0012-multiple-conversations.md).

### F8: completed-boundary fork

`emacs-agent-session-fork` creates/selects an independent F6 conversation after a
completed whole run or the latest compaction summary. Summary is the earliest
logical point, including when its cut falls inside a run. No tree, bookmark,
extra summary request, tool replay or editor rollback is introduced.

The clone transaction copies canonical `[0,end)` and the same absolute compaction
cut. Model projection is exactly summary + suffix through the chosen boundary;
raw summarized records stay available for existing F4 validation. Completed-turn
forks retain only the event prefix through that completion, filtered by inherited
canonical run IDs (not future queued inputs). Summary-only forks retain no raw
audit events; compacted forks prepend an inert inherited-summary entry. The
original archive/journal stays unchanged. Source-ID/time provenance gains an
optional locally validated `:boundary`; it remains historical after later growth
or compaction. Schema 3, slots and F6 identity/selection rules are unchanged.

The completion picker defaults to newest, `C-u` asks for a name, and the command
rejects changed history/selection after either minibuffer. Source and involved
selections must remain idle. Failed/cancelled turns, individual tools and partial
turns are not endpoints; tool pairs/protocol reasoning stay intact. A fork has no
pending recovery, handles, usage anchor or execution source in the core copy.
The UI binds the invoking working buffer, or the journal owner's last working
buffer if still live. It captures that reference before prompting and checks
liveness when showing the fork; it never substitutes a journal/selected buffer or
loads an execution source from copied event payloads. This fixes immediate ask
from a journal-created fork; a genuinely closed source still requires a working-
buffer invocation.

276 ERT plus warnings-as-errors compile and diff-check pass. Tests cover real
pinned-gptel dry-run wire comparisons, mid-run and summary-only boundaries,
continuation/fork-of-fork, late/duplicate completions, excluded future queued audit,
provenance validation, save/pointer failures and backend-free offline subprocess
restore/fork. Independent read-only review found no supported issues; its focused
offline growth/recompaction/fork/restore probe passed using mocked summary delivery.
No provider or live user-Emacs UI smoke was performed.
See [ADR-0014](adr/0014-minimal-fork-after-compaction.md).

### Conversation UI and activity status

`emacs-agent-log.el` now projects normal conversation separately from diagnostic
`D` details. Normal view hides routine metadata/IDs/usage, pairs tool call/results
by run/call ID, shows bounded previews with F3 notices and initially folds
reasoning. Errors, instruction warnings and unsent user text stay visible.
Details expose complete audit records and formatted usage, respecting the user's
reasoning visibility choice. TAB and `<tab>` override the text-button keymap;
RET/click still work. Local fold arrows, first-event anchors and marker-preserving
result updates keep the reader near their content. Rebuilds occur only on explicit
details toggles/reopening, never on every streaming fragment. No Markdown yet.

`emacs-agent-status.el` caches aggregate live activity in `global-mode-string`.
It is enabled once on initial package load and can be disabled without replacing
`mode-line-format`. Waiting/responding/eval/compacting/paused and positive ordinary
FIFO counts are shown; idle is hidden. No timers, fabricated billing or global
per-token redisplay. Status uses short, space-padded `AI:wait/reply/eval/compact/pause`
labels; `emacs-agent-status-prefix` and `emacs-agent-status-labels` customize them
and the queue label. Customize refreshes the cache immediately; after `setq`,
call `emacs-agent-status-update`. Reasoning header/body inherit `shadow` via
`emacs-agent-log-reasoning-face`, including subsequent streamed text and details. Text/usage events do not scan archived conversations. Custom
mode lines must display `global-mode-string` to show the indicator.

Native event hooks and the new runtime-only `emacs-agent-session-state-functions`
keep status current. The latter covers response-end, last-tool return, active-run
release and WAIT before HTTP. Errors are isolated, liveness is rechecked after
WAIT observers, and no observer is inserted into steering's claim-to-transport
transaction. These notifications add no durable events, schema fields or model
messages. Status loading does not require the provider/private summary FSM.

The session picker is sorted by `updated-at` descending (stable ID tie-break),
with `scope#short-id: original first user request…` labels sized to the minibuffer.
Compacted raw prefixes still supply the original request. Empty entries use a
name/placeholder; colliding short hashes are extended. Completion metadata keeps
activity order rather than alphabetic/history sorting; prompt-preview labels are
not saved in global minibuffer history. Core selection/identity and persistence
are unchanged; displaying choices never updates activity timestamps.

310 ERT, warnings-as-errors compilation and diff-check pass, including actual
keymap dispatch, fold/preview/reader regressions, diagnostics and canonical-history
isolation, private snapshot roundtrips, native status transitions, error/cancel
observers and offline subprocess restore. No provider/live UI smoke or user-Emacs
hot-load. Independent review found a separator-line reader-anchor bug on `D`;
event-owned separators and a regression test fix the jump. No other verified
findings were reported. See [ADR-0015](adr/0015-conversation-ui-and-activity-status.md).

## Evaluation error and source-state diagnostics

`emacs-agent-eval.el` keeps sequential unrestricted read/eval and the existing
single-tool/plain-string contract. Failure feedback adds phase, form/completed
counts, character positions, bounded source excerpts and best-effort open-string/
list hints. ERROR/QUIT remains the last line, preserving short failures in F3's
tail. Evaluation errors may carry at most eight function names and a loaded
signature: no argument/environment dumps, autoload or dynamic documentation lookup.
A local noninteractive debugger captures before unwinding; ordinary caught errors,
throws, cleanup and quits retain their behavior. The internal repeated-debugger
counter is locally bound/reset, never globally changed. Unavailable/stale stacks
are reported as such. This is best effort, not a sandbox.

Only the actual source buffer is inspected before/after, without reading text or
moving point/restriction/undo. Net changes produce a compact identity/delta footer
with `(before after)` pairs and `:whole-characters` counts. Other buffers/files
are not checked, no rollback/save/retry is introduced, and read-only successes
keep their prior output. All diagnostics still use F3's private artifact limiter.

333 offline ERT and warnings-as-errors compilation; Emacs 30.2 runtime, 28.1 API
compatibility inspected but not separately runtime-tested. No provider/user-Emacs
calls or replay of the private transcript. See [ADR-0016](adr/0016-evaluation-error-diagnostics.md).

## Edit/save/check instruction recipe

The system prompt now distinguishes edited/saved/checked and requires rereading
changed ranges after the last check. Unsaved edits are not checked by disk
commands; there is no implicit save/discard. Loaded features/commands do not prove
an active language backend or actual fresh diagnostics. Inspect mode variables,
not mode commands, and query the configured checker or project check command.

An eighth executable example uses `process-file` with a fresh disposable output
buffer and combined stdout/stderr, returning exit/output/cwd/file identity. It
refuses unsaved/unvisited buffers before execution. Only integer exit 0 supports
success claims or running built binaries. CHECKER/argv/cwd remain project choices;
there is no new tool, runner/backend adapter or runtime enforcement gate. All
seven earlier examples stay intact; prompt length is 5033 characters (<5037).
EOF helper errors now show requested and available whole-buffer line ranges.

341 ERT and strict compilation include the actual prompt examples, edit/save/check/
reread workflow, empty failure/signal results, output isolation and one real
synthetic subprocess with stderr/exit 2. No model/provider or user-Emacs calls.
See [ADR-0017](adr/0017-edit-save-check-workflow.md).

## Post-MVP F4: pigo-style compaction

`emacs-agent-compaction.el` contains provider-independent config, estimates,
cut planning and bounded summary input. `emacs-agent-compact.el` owns the private
summary FSM, session lock and durable projection. Normal private WAIT checks
before every generation, after the entire prior batch. Defaults match pigo:
context 262144, reserve 16384, retention target 20000, auto enabled. These are
local configured budgets, not discovered model windows (including `main`).

The gate includes actual system/tool data and previews pending steering without
claiming it. One automatic summary attempt is followed by request reconstruction
and one budget recheck. Existing TRET→WAIT delivery still owns steering claims
and transport-launch rollback; inputs arriving during summary are caught up.
Canonical paired records, tool counts and side effects are never replayed.

Summary uses Pi-style summarizer system text, `<conversation>` and separate
`<previous-summary>` blocks, followed by initial/update checkpoint instructions
and optional bounded focus. Requested Markdown sections are not validated;
existing summaries are not rewritten. See
[ADR-0011](adr/0011-pi-summary-request-framing.md). The request uses the
selected/frozen model/backend, nonstream public text and **no tools**. Private
WAIT strips tool-related native parameters; private TOOL rejects dispatch.
Transcript uses 2000-byte UTF-8-safe block prefixes and at most
min(128 KiB, context/3) bytes, preserving first quarter + newest tail. This is
intentionally lossy like pigo, including possible omission of long result tails.
Accept only completed nonblank text. No output-token cap is installed by reserve.

Original history remains; optional snapshot `:compaction` records an absolute
canonical cut + summary, model/backend/time and estimated tokens before. Latest
summary is a user-role prompt followed by raw suffix. Retained normalized tool
records are atomic call/result pairs, preserving protocol reasoning/IDs. `current`
keeps delivered current-run snapshots explicit across a cut; `full` includes raw
retained snapshots, with older ones represented by summary; nil omits them.
A new summary is atomically saved before publication; generation/cancel/save
failure keeps the previous projection. Commit claim ends cancellability. Restart
never resumes a summary HTTP request or queued work.

`:usage-anchor` persists normalized positive input (uncached+cached) + output
with its fallback baseline and backend/model/cut provenance. Estimates apply only
the subsequent fallback delta; backend/model changes and compaction clear it.
Unknown usage stays unknown. Auto summary HTTP belongs to owner-run usage;
manual summary has its own audit run. Cumulative gptel snapshots are not run
contributions and can reset between the task FSM and the separate summary FSM.
Frozen `:context-config` is included in pending input data/quota and saved run
metadata. Optional fields preserve readable schema-2 snapshots; validation still
precedes registry mutation and offline inspection does not require gptel.

`M-x emacs-agent-compact` requires idle; prefix asks retention (zero allowed) and
focus. Existing cancellation and FIFO integrate with the lock; journal header
shows compacting. No new advertised tool, tokenizer dependency, provider-overflow
recovery loop, branch UI or automatic raw-history deletion. Auto compaction
requires autosave; manual compaction explicitly persists even if autosave is off.

227 offline ERT, real pinned-gptel dry-run FSM/wire tests, compilation with
warnings-as-errors and diff-check pass. A separate read-only lifecycle review
reported no supported findings. Initial F4 had no assistant-driven real-provider
smoke; the user subsequently exercised manual compaction. One separate tool-free
live probe of the new framing produced structured notes, not a perfect factual
summary. This is not a full live lifecycle matrix. Pre-F4 structs still require
restart; the framing change does not alter them. Details:
[ADR-0010](adr/0010-pigo-style-compaction.md).

## Post-MVP F3: simple full-output files

The agreed KISS implementation keeps `eval_elisp` and its plain string result.
Above `emacs-agent-eval-output-limit` (32768 characters by default), the complete
formatted text is written once as UTF-8 to a unique 0600 `eval-*.txt` under
`emacs-agent-data-directory/tool-output/` (new directories 0700). The model gets
a character-safe tail plus a quoted absolute-path notice, counted in the budget;
if the notice alone is too long it remains intact without a tail. Exact-limit
results do not create files. Final value/error follows stdout and normally
survives the tail; oversized values can still be cut, with full text in the file.

Create/write/quit failure cleans partial files best-effort and returns an explicit
unavailable warning, never reexecuting Lisp or advertising a full-file reference.
No structured channels, registry, extra helper/tool, viewer, timers, quotas or
automatic cleanup. Files stay until manually removed; normal Elisp can inspect
ranges. Data must not be loaded as code. Result references remain ordinary strings
in existing history; no session schema or gptel transport changes. Full text is
still assembled in memory before saving, not streamed like pigo's Bash spool.
The common data-directory option now lives in eval, retaining name/default/value.

196 ERT and warnings-as-errors compile pass; nine new tests cover boundaries,
Unicode/quoted paths, final value/error/nil/quit, permissions, independent files
and failed saves without repeated effects. No new model call was used. See
[ADR-0009](adr/0009-simple-full-tool-output.md).

## Post-MVP F2: steering and editable pending input

User-approved context semantics: `current` retains original plus delivered
steering snapshots of the active run, eliding only adjacent whole-snapshot
equality; text is always delivered, A→B→A survives. Pending inputs do not alter
model context. `full` and nil retain their meanings. On final boundary, an
undelivered clarification becomes a separate ordinary FIFO run, not another
HTTP request in the completed run. Cancel/error remains explicit recovery,
not automatic resubmission. See [ADR-0007](adr/0007-steering-boundaries.md).

Production private WAIT now wraps the pinned default handler, after complete
protocol restoration. Only TRET with all batch results can claim queued steering;
initial/repeated WAIT cannot deliver it. Canonical history, copied wire and input
identities commit without event hooks before transport invocation. Launch failures
restore undelivered recovery, whereas errors from post-request hooks after a
successful launch preserve delivered history. Temporary forwarding bindings
observe curl/url return for the exact FSM and delegate other FSMs unchanged;
no global advice/handlers/hooks are installed. This is a launch boundary, not
provider acknowledgement. Usage stays one observation per HTTP, not per input.
Tests parse actual pinned SSE and non-streaming fixtures with only HTTP mocked.
Budget=1 pauses before the second tool and preserves input until batch completion.

Terminal status and the whole pending disposition are claimed before assistant-end
or any other event hook. Successful final conversion appends frozen independent
runs behind older asks, before publishing hooks, so new reentrant submissions
cannot overtake existing clarifications. Repeated DONE cannot convert twice.
Tool-call hooks are followed by a liveness check before evaluation; effects of
already-started self-cancelling Lisp still retain their result.

The old canonical validator rejected every second user record of a run. It now
permits additional user inputs only with a nonempty unique `:input-id`, within
a contiguous run group. Missing/duplicate/invalid IDs and returning to an old
run after a newer one still fail. Input IDs are metadata, never API fields.
Old single-input records remain valid. `current` dedup is a pure projection:
region/text/narrowing changes count even at the same point; raw history is
unchanged and full retains every snapshot. gptel may merge adjacent user wire
messages, so assertions count context blocks, not just message objects.

`emacs-agent-steer` targets the captured active run, including paused runs;
initially idle is an error. Pending view includes ordinary queued asks and
steering, with edit/withdraw/explicit recovery/confirmed forget/full-text commands.
Editing withdraws before recursive minibuffer input: C-g retains the original;
RET resubmits at the tail with the same snapshots. Default limits are 8
undelivered entries (withdrawn included), 256 KiB UTF-8 serialized frozen payload.
Overflow never evicts older input. Credentials/backend objects are not persisted.
Optional schema-2 :inputs restores only withdrawn recovery, never transports or
execution queues; missing live source/backend must be explicitly rebound.
Independent ordinary queued asks retain their existing cancellation/FIFO policy.

187 ERT and warnings-as-errors compile pass. Independent review's three reproduced
races now have regressions (assistant-end FIFO ownership, tool-call cancellation,
post-launch-hook rollback). No new provider call or live interactive F2 smoke
occurred. New structs have not been hot-loaded into the user's pre-F2 Emacs;
restart before using the new state definitions. Existing schema-2 snapshots read
without migration. Fast autosave retained ~15 ms on the prior ~391 KB private
sample (5 full atomic saves, no GC); the synchronous pretty-print fix remains.

## Post-MVP F1: project-root instructions

Scope was explicitly narrowed: one project-root file, no global/ancestor/child
search, templates deferred. Priority is `AGENTS.override.md`, `AGENTS.md`,
`AGENTS.MD`, `CLAUDE.md`, `CLAUDE.MD`. `emacs-agent-resources.el` reads saved
disk data without visiting files or executing local variables. The first
existing candidate wins, including empty files. Bad/unreadable selected files
produce recorded warnings without fallback; missing files/root are normal.
Normal symlink semantics apply, not a filesystem sandbox.

`emacs-agent-session-enqueue` freezes the snapshot and source opt-out after
nonempty input, retaining the existing pre-minibuffer editor/root capture.
The adapter appends that snapshot as a separate block to the run's system
prompt, independent of context-history. FIFO start does not rediscover files
or reevaluate opt-out. gptel owns that composed system prompt for all tool
iterations. Canonical user/tool/assistant history is unchanged; previous
snapshots are never added to subsequent system prompts.

`instructions` events retain status/root/path/text/warnings and render a compact
status in the journal; active/pending audit also contains `:instructions`.
Existing schema 2 serialization restores these records without executable work
or migration. `emacs-agent-show-instructions` uses the active snapshot, otherwise
the last submitted event, including after restart. The view is read-only and
never rereads resources. `emacs-agent-project-instructions` defaults to t and
can be set buffer-locally to nil in the original source.

148 ERT and warnings-as-errors compilation cover priorities, root-only I/O,
empty and invalid candidates, opt-out/no-project without I/O, no local eval,
saved vs unsaved contents, source/view state, submission timing, frozen queued
snapshots despite file/config changes, interrupted restore and journal/view.
Actual gptel dry-run confirms the composed system message, unchanged user text,
no prior snapshot replay, and independence from disabled editor context.
Real TOOL→TRET→WAIT continuation (only HTTP stubbed) retains the same system
block despite changed files/opt-out. Additional regressions cover blank/aborted
input without resource I/O, fresh-only snapshots after restart, and restored
warning visibility in both journal and view.
No new real-provider F1 smoke was run; these are offline tests, not live HTTP.
See [ADR-0005](adr/0005-root-project-instructions.md).

## Post-MVP F0b: durable streaming blocks (schema 2)

The F0b milestone wrote **schema 2** (F6 now writes schema 3 in a new namespace),
readable Lisp data with one top-level
field / message / event / run record per line. Recursive `pp` layout was removed
from synchronous autosave: on a private ~391 KB real-session copy, full atomic
save measured ~976 ms before and ~14 ms afterward (3 repetitions, no GC).
Snapshot construction itself was ~6 ms. Validation, immediate boundary saves,
5-second stream checkpoints, permissions and atomic rename remain unchanged;
parsed values are identical. 162 ERT and warnings-as-errors compile pass,
including a regression forbidding pretty-layout calls during save and checking
exact serialized roundtrip. No new provider call was used for this benchmark;
the user subsequently reran the live test and confirmed that input stalls
disappeared. Separate renderer
batch timings were near-linear and do not rule out real redisplay costs.
See [ADR-0008](adr/0008-responsive-snapshots.md). Schema 1 is
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
for unsupported schema/adapter files; the later deep-alpha schema 2 deliberately
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
