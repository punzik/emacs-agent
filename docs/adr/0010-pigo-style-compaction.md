# ADR-0010: Pigo-style context budget and compaction

Status: implemented and verified offline; user requested the pigo approach, retaining KISS.
Summary request wording/framing was later superseded by
[ADR-0011](0011-pi-summary-request-framing.md), without changing this lifecycle.

## Reference and scope

Reference: `/home/np/projects/personal/pi/pigo`, `internal/compaction/compaction.go`,
`internal/app/compact.go`, and the pre-generation gate in `internal/app/run.go`.
Do not add a tokenizer, recursive summary pipeline, provider-overflow retry,
branching UI, or extra advertised tools.

The defaults are a **local configured budget**, not discovered model capabilities:
262144 context tokens, 16384 reserved, 20000 recent-token target, auto compaction
on. In particular these numbers do not establish the physical window behind
`main`. Limits are configurable and validated: context 1024..10000000, positive
reserve/retention, reserve + retention strictly below context. Manual retention
may be zero to summarize all effective history.

Freeze configuration on accepted input, including ordinary queued asks and
steering final-boundary conversions; include it in private pending payload and
quota accounting. Pre-F4 recovery records without the new field use explicit
package defaults, not a reread of source-local settings.

## One budget gate per provider generation

Before initial HTTP and after the entire completed tool batch, estimate the
actual request, including frozen system instructions, tool definition and
would-be steering. Trigger strictly above context - reserve; equality fits.
Use approximately four Unicode characters/token plus message/tool framing.
This is not a tokenizer or a provider/billing/context-size truth.

When normalized positive prompt usage is available, anchor input (uncached + cached) + output
to the corresponding post-response fallback estimate; apply only subsequent
fallback delta, clamping to one. Anchor is private non-model metadata and
survives snapshots. Clear it on backend/model change or compaction. Unknown
usage never becomes a claimed exact context count.

Automatic compaction makes **one** summary attempt, rebuilds the request and
checks its budget again. If still too large, stop explicitly while keeping the
successful summary. Disabled auto compaction also stops rather than dropping
history. Provider context-overflow errors do not launch another recovery loop.
Reserve is a budgeting allowance, not an installed output-token cap.

Auto compaction requires autosave: disabling autosave must not accidentally
force private history onto disk. Manual compaction is an explicit durable
operation and always saves before publishing, even with autosave disabled.

## Projection and safe cuts

Keep original messages, tool outcomes and journal intact. Store only the latest
`(:cut N :summary TEXT :tokens-before ... :model ... :backend ... :time ...)`.
`N` is an absolute number of original records summarized. Original history is
append-only, so it is a stable boundary without adding IDs to every message.
Repeated compaction starts at the existing cut and includes the previous
summary; it never resurrects already summarized raw records. No-op/re-summarizing
only the previous summary is rejected.

Select a recent suffix by approximate token costs, then prefer a user boundary;
otherwise advance to an assistant boundary. Our canonical tool record already
bundles assistant call + result, so it is itself a safe assistant boundary.
Never split that atomic record; original history validation still runs before
projection. Preserve retained protocol reasoning and exact call/result IDs.
The 20000-token retention is a target, not a guarantee to retain the latest
whole user run; large runs can be compacted between complete tool pairs.

Model history becomes an ordinary user-role summary followed by the raw suffix.
`nil` omits editor snapshots. `full` includes snapshots in retained raw records;
older compacted snapshots are represented by the summary. Under `current`,
all delivered **current-run** snapshots remain explicit even if their old text
was compacted, preserving adjacent whole-snapshot deduplication and A→B→A.
Pending/withdrawn steering remains absent from summary/model history.

## Summary request and lifecycle

A separate private gptel FSM uses the selected Chat Completions backend/model,
nonstreaming public text, a fixed factual-continuity system prompt, optional
bounded focus, and no tools. Strip tool-related request parameters and reject
any attempted tool dispatch before execution. Transcript text, reasoning,
arguments and results each keep a UTF-8-safe 2000-byte prefix; total input
is bounded to min(128 KiB, context/3) bytes with a first-quarter/newest-tail
layout. A separate summary-input budget check reserves min(1024, context/8).
Accept only nonblank text with an explicit completed stop reason. Like pigo,
this bounded source is lossy: long final values/errors and F3 file references
can be outside the per-block prefix. Original journal records/files remain;
a summary is not a guaranteed verbatim ledger of every effect.

Session lock prevents queued asks from overtaking the summary. Manual command
requires idle; it uses the source buffer's selected backend/model and settings
(as an explicit new editor action), without rereading project instructions or
recapturing historical snapshots. Auto uses the original run's frozen settings.
Costs of automatic summary HTTP belong to that run's usage; manual summary has
its own audit/usage run, not a fake user message in API history.

Steering is previewed for budgeting, not claimed before summary. After summary,
catch up newly arrived pending inputs, recheck once and use the existing
TRET→WAIT delivery transaction. Summary failure/cancel leaves steering recovery
semantics and independent ordinary FIFO unchanged. No tool effects are replayed.

Generation failure, cancellation, incomplete/empty summary or save failure
leaves the previous projection unchanged. Successful summary is saved through
an atomic snapshot before publication; cancel is accepted during generation,
not after the commit claim. Completion then resumes a still-live owner or starts
queued work. Terminal state is claimed before hooks/abort to ignore late callbacks.
On restart, no summary transport/queue is restored; an interrupted summary is
inspectable data and does not run automatically. Snapshots validate optional
projection/anchor/config data before registry mutation; old schema-2 snapshots
remain readable without a mandatory migration or installed gptel for inspection.

## Verification

`nix-shell -p gnumake --run 'make clean test compile'`: 224 ERT and
warnings-as-errors compilation. `git diff --check` passes. New tests cover pure
config/estimator/boundary/UTF-8 functions, real pinned-gptel dry-run wire/FSM,
automatic initial and post-whole-batch generation, one attempt/recheck,
steering arriving before/during summary, user/source cancellation without any
reexecuted effects, manual public command/FIFO/reentrant hooks, previous-summary
failure, partial/empty/tool/incomplete replies, failed atomic save, repeated
projection, model-change anchor invalidation, pending frozen-config recovery,
malformed snapshots before registry mutation and inert interrupted restart.
A fresh `emacs -Q` subprocess restores the new summary/anchor without gptel.

An independent read-only review of coordinator/integration lifecycle reported
no supported findings; it did not run the suite or audit the pure implementation.
Integration testing found and fixed actual gptel `:json-false` schema sentinel
handling; frozen configuration also rejects unknown/duplicate fields.

No real-provider calls or user-Emacs F4 hot-load were performed. Private user
buffers/session logs were not used as test data. New session/run slots require restart; do not replace live
struct definitions in a pre-F4 editor. Private synthetic fixture files are
cleaned by the tests. No token-efficiency or model-window-size claim is made.
