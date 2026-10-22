# Development

This document describes the current implementation and verification workflow.
Installation, commands, configuration, hooks and helper usage are documented in
[README.md](../README.md). Accepted decisions and their historical rationale
live in [adr/](adr/); milestone plans are not a specification of current behavior.

## Environment and checks

The package declares Emacs 28.1 and gptel 0.9.9.5 as minimum dependencies. The
integration baseline is **Emacs 30.2, gptel 0.9.9.5**, upstream commit
`fc6963634af2f76a9909ad674e2c0b3f005e60b5`. Emacs 28.1 has not been runtime-tested.
Runtime guards require the exact gptel version string and expected internal
contracts; they do not verify the Git commit. Pin the commit for reproducibility.

There is no project `flake.nix` or `shell.nix`. On NixOS, with Emacs and the
pinned gptel/dependencies already installed:

```sh
nix-shell -p gnumake --run 'make clean test compile'
```

With make available:

```sh
make clean
make test
make compile
# Override the package directory and/or Emacs executable when needed:
make EMACS=/path/to/emacs ELPA=/path/to/elpa test compile
```

`ELPA` defaults to `$HOME/.emacs.d/elpa`; `EMACS` defaults to `emacs`.
The Makefile runs `emacs -Q --batch`, initializes packages from that directory,
and adds the repository and `examples/` to `load-path`. `test` explicitly loads
the ERT files and calls `ert-run-tests-batch-and-exit`; `compile` treats warnings
as errors. `clean` removes generated package/spike `.elc` files. Run clean before
tests to avoid testing stale bytecode. Do not use parallel make for the combined
clean/test/compile sequence.

Some foundational tests can run without gptel:

```sh
emacs -Q --batch -L . -l test/emacs-agent-session-test.el \
  -l test/emacs-agent-context-test.el -f ert-run-tests-batch-and-exit
```

The full automated suite uses mocks, dry-run requests and the installed gptel
parsers; it needs no API keys or live endpoint. A passing offline suite is not a
claim of provider compatibility or a completed live UI test. Avoid fixed test
counts in documentation; the suite changes as features are added.

## Module map

| Module | Responsibility |
| --- | --- |
| `emacs-agent.el` | User commands, minibuffer and list-view orchestration, model system prompt |
| `emacs-agent-session.el` | Conversation identity/selection, session/run structs, FIFO and event dispatch |
| `emacs-agent-input.el` | Frozen input lifecycle, steering, pending bounds and recovery |
| `emacs-agent-context.el` | Editor snapshots and framed context rendering |
| `emacs-agent-resources.el` | Root instruction capture and system-prompt composition |
| `emacs-agent-user-helpers.el` | Runtime helper registration and compact description snapshots |
| `emacs-agent-gptel.el` | Private transports, gptel lifecycle, replay validation, dispatch, budget and cancellation |
| `emacs-agent-compaction.el` | Pure estimates, retention planning, transcript clipping and summary prompts |
| `emacs-agent-compact.el` | Summary request FSM, durable projection commit and main-request integration |
| `emacs-agent-eval.el` | Sequential unrestricted evaluation, scoped text payloads, diagnostics and output artifacts |
| `emacs-agent-helpers.el` | Live buffer reads, guarded edits and synchronous process helper |
| `emacs-agent-sexps.el` | Non-evaluating Lisp inspection/checking and guarded balanced edits |
| `emacs-agent-jobs.el` | Local asynchronous processes and bounded output reads |
| `emacs-agent-log.el` | Incremental journal rendering, folds, diagnostic details and final-response preview |
| `emacs-agent-status.el` | Cached global activity indicator |
| `emacs-agent-usage.el` | Per-HTTP and run/session normalized usage accounting |
| `emacs-agent-store.el` | Snapshot validation, atomic writes, catalog and project selections |
| `examples/emacs-agent-spike.el` | Historical integration prototype, still compiled and tested |

Buffer/edit/process/sexp/job functions are ordinary helpers invoked through the
single `eval_elisp` tool. Do not mistake the prototype for the production entry
point or add a second transport/tool framework around it.

## State and representation invariants

### Conversation ownership and live editor state

- A scope is a canonical project root or `global`; it can contain multiple
  independent conversations. Project selection is durable, global selection is
  process-local and starts fresh on implicit use.
- Each conversation owns at most one active run. Ordinary inputs are FIFO;
  paused runs retain ownership. Different conversations can request concurrently.
- A global evaluation guard prevents overlapping Lisp execution even when a
  tool enters a recursive event loop. Async jobs are separate shared runtime
  objects, not agent runs or automatic continuation triggers.
- Callbacks must verify registered session/run object identity and active
  ownership. A late callback must not mutate a cancelled/replaced run or release
  a newer owner's slot. HTTP stream end is not terminal FSM completion.
- Conversation operations save before publishing the new selection. Failed
  save/pointer transactions must leave the old selection and history usable.
- Project scoping is not a security boundary. The editor remains shared mutable
  state. Never infer current text/disk/process state solely from past results.
- No automatic tool replay, network retry or exactly-once execution guarantee.
  Cancellation cannot undo effects already performed.

See [ADR-0007](adr/0007-steering-boundaries.md),
[ADR-0012](adr/0012-multiple-conversations.md) and
[ADR-0013](adr/0013-interactive-editor-no-tool-ledger.md).

### Three separate representations

1. **Canonical model records** retain ordered user/assistant/tool messages,
   original call IDs, arguments/results and replayable protocol fields.
2. **Structured events** form the audit/journal source: lifecycle, text chunks,
   reasoning, tool activity, usage, warnings and persistence notices.
3. **Rendered buffers** are disposable read-only projections, never parsed to
   reconstruct model history.

Record canonical results before notifying UI observers. Observer errors/quits
must not lose results, prevent other observers or strand a run. Streaming text
is assembled into one canonical assistant message per HTTP response, not one
message per fragment. Folding, details and reasoning visibility are display
policies, not deletion. Snapshot fragment compaction changes only the saved
copy and does not cross run/type/tool/end/unknown-metadata boundaries.

See [ADR-0003](adr/0003-durable-streaming-blocks.md) and
[ADR-0015](adr/0015-conversation-ui-and-activity-status.md).

### Input and instruction snapshots

Capture editor origin/positions before minibuffer entry. On accepted submission,
freeze context policy, model/backend configuration, budgets, saved root
instructions and registered-helper descriptions. Keep displayed user text
separate from context metadata. Queued runs, tool continuations and recovery
must not silently read replacement settings or instruction files.

`current` context includes delivered steering snapshots; elide only adjacent
identical snapshots, preserving A→B→A. Deliver steering after a complete tool
batch. If its target finishes before delivery, preserve FIFO semantics by
converting it into an ordinary input. Pending editing withdraws before prompt
entry; aborted editing must retain recoverable text and its original capture.

Root discovery selects one common AGENTS/CLAUDE file by priority, then independent
`EMACSAGENT.md`, then the registered-helper block. Per-file errors do not suppress
the other source. Helper registration describes already-loaded functions; it
never loads or executes examples, and unregistering does not revoke eval access.

See [ADR-0005](adr/0005-root-project-instructions.md),
[ADR-0018](adr/0018-scoped-text-payloads.md),
[ADR-0023](adr/0023-emacsagent-instructions.md) and
[ADR-0024](adr/0024-user-helper-registration.md).

## gptel integration contract

Supported transports are exact `gptel-openai` Chat Completions backends, not the
Responses API or other backend classes. gptel owns HTTP, provider serialization,
tool-call/result construction and within-run continuations. The package wraps
that loop rather than implementing a competing HTTP state machine.

Private/experimental dependencies are isolated primarily in
`emacs-agent-gptel.el` **and `emacs-agent-compact.el`**:

- Structured history insertion/parsing (`gptel--parse-list-and-insert`,
  `gptel--parse-buffer`) and generated wire-message shapes.
- Original provider tool IDs/order, gptel's formatted IDs and paired results.
- Restoration of textual `reasoning`/`reasoning_content` on assistant tool
  messages. Final-answer reasoning without tools is journal-only.
- Per-request FSM handler tables, particularly WAIT/TOOL and terminal
  DONE/ERRS/ABRT ownership; tool-free summary requests use the same boundary.
- Callback shapes and usage timing, including usage arriving at response end.
- The WAIT launch boundary: validate/rebuild history, apply complete-batch
  steering, check compaction and establish ownership before transport dispatch.

Transport buffers are private; ambient gptel UI history truncation, prompt
transforms and selected tools must not alter their frozen run configuration.
Do not install global advice/hooks to implement per-request behavior.

Malformed/unsupported replay data fails closed before evaluation. A durable
unsupported-protocol record blocks later replay rather than silently dropping
fields. This cannot detect fields upstream gptel discards before exposing them;
there is no universal proprietary-extension compatibility guarantee.

For a gptel update, inspect both adapter modules, update guards deliberately,
and run real pinned-parser/serialization contracts in addition to mocked
lifecycle tests. Test initial requests, tool continuations, restored history and
summary requests separately, both streaming and non-streaming. Preserve original
IDs, ordering and textual reasoning on every path.

## Evaluation and helper contracts

`eval_elisp` evaluates multiple forms sequentially, binds invocation-local copied
`emacs-agent-texts`, captures stdout/final value or error, and applies the output
budget. Earlier effects survive a later read/eval failure. Diagnostics must not
open the user's debugger or dump argument/closure contents. Source-change
footers concern only the actual source buffer, not every affected resource.

Read helpers preserve editor state and return bounded complete plists; sexp
inspection returns valid complete JSON or errors. Keep coordinate units explicit:
absolute character positions, 1-based lines, display columns for reading helpers
versus character columns in evaluator diagnostics. Guard continuation with ticks.

Edits validate OLD/tick, narrowing, disk conflict, writability and undo before
mutation. Batch matches refer to the original text and apply bottom-up. Atomic
rollback covers buffer edits, not external hook effects. Sexp editing preflights
source copies and validates after hooks inside the same rollback group. No edit
helper automatically saves. Process helpers must not silently save, retry or
interpret empty output as success. Full-output artifact failures must never
repeat evaluation.

Relevant decisions: [ADR-0001](adr/0001-f0-buffer-helpers.md),
[ADR-0002](adr/0002-buffer-native-editing.md),
[ADR-0004](adr/0004-efficient-model-io.md),
[ADR-0009](adr/0009-simple-full-tool-output.md),
[ADR-0016](adr/0016-evaluation-error-diagnostics.md),
[ADR-0017](adr/0017-edit-save-check-workflow.md),
[ADR-0019](adr/0019-process-helper.md),
[ADR-0022](adr/0022-async-jobs.md), and
[ADR-0025](adr/0025-sexp-helpers.md).

## Persistence and compaction

The current snapshot schema is **3**, adapter identifier
`chat-completions-v1`. Files are `conversations/<conversation-ID-hex>.eld`, not a
second hash of the ID; project selection pointers use a hash of the root.
Validate serializable data, identity, schema, adapter and history before
registration. Read as UTF-8 Lisp data, never load/evaluate snapshots. Write via
a same-directory temporary file and atomic rename, with private permissions.
Use per-record serialization rather than recursive pretty-printing in callbacks.

Restoration retains interrupted audit/partial text and recovery-only inputs,
not execution handles, credentials, closures or permission to resume. Reconnect
source identities only to already-open matching buffers. Catalog refresh must
not overwrite live objects. There is no schema-1/2 import or compatibility reader;
unsupported current-namespace files fail explicitly on direct restore.
Concurrent multi-process writers are not supported.

Compaction changes the model projection, not archival records. Estimates and
retention must preserve complete protocol boundaries. Retained call/result IDs
and reasoning remain paired; fork points cannot enter a summarized prefix.
The summary request is tool-free and its input is intentionally clipped/lossy.
Only nonblank completion plus successful snapshot persistence commits a new
projection; save/cancel failure preserves the old one. Automatic compaction
requires autosave; manual compaction saves even when autosave is off. A committed
summary is not rolled back because the rebuilt request still exceeds budget.
Usage accounting remains separate from context estimation and model history.

See [ADR-0008](adr/0008-responsive-snapshots.md),
[ADR-0010](adr/0010-pigo-style-compaction.md),
[ADR-0011](adr/0011-pi-summary-request-framing.md),
[ADR-0014](adr/0014-minimal-fork-after-compaction.md),
[ADR-0020](adr/0020-session-info.md), and
[ADR-0021](adr/0021-id-handle-file-name.md).

## Verification workflow

For a change, add focused regression tests and run the full test/compile sequence.
Test failures and side effects, not only happy paths:

- Mock callbacks, terminal ownership, late callbacks and recursive event loops.
- Use actual gptel parsing/dry-run serialization for wire contracts; mock HTTP,
  not the protocol behavior being asserted.
- Verify FIFO, steering handoff, pauses/cancel, pending limits and recovery.
- Exercise snapshot round trips and fresh-process restoration; assert no tool
  execution or automatic submission on restore.
- Check exact helper text/metadata, Unicode/escaping, narrowing, stale ticks,
  undo/no-ops, hook failures and output-artifact write failures.
- Keep prompt examples executable on disposable buffers/visited files; a helper
  contract change can invalidate the model system prompt as well as the README.
- Test compaction save-before-publish failures, tool pairing and post-summary forks.
- Check journal folds/reader position, killed views, notifications and cached
  activity without relying on model output.

Use temporary data directories and disposable buffers/files/processes. Never
commit private prompts, endpoint credentials, real transcripts or output artifacts
as fixtures. Update the Makefile's explicit test/compile lists for new files.

### Opt-in live smoke checks

Only run against an explicitly configured trusted endpoint in a disposable
conversation with harmless test data. Loading the package must not request.
Check streaming and non-streaming, supplied reasoning if available, a two-tool
batch and next-turn replay, cancellation, budget pause/resume, steering between
batches, queued asks, and closing/reopening the journal without callback focus
changes. Separately check manual/automatic compaction and restart recovery;
inspect files/buffers for effects before continuing interrupted work.

`test/manual-history-smoke.el` is an opt-in live replay probe, not part of the
offline suite; read it before use and remove its observer afterward. Its request
captures may contain sensitive data. A single successful provider probe is not a
full lifecycle matrix, a token-savings benchmark or a guarantee of summary quality.

## Documentation maintenance

Keep all user-facing behavior, installation, examples, options and hooks in
[README.md](../README.md); keep implementation/testing contracts here. Record new
architectural decisions in ADRs without treating old plans or dated experiment
results as current promises. Do not duplicate test counts, benchmark anecdotes
or completed stage checklists in maintained documentation. Planned capabilities
(skills/templates, MCP, subagents or retries) are not implemented guarantees;
there is deliberately no durable execution ledger or automatic side-effect replay.
