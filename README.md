# Emacs Agent

An Emacs Lisp agent using gptel and one unrestricted `eval_elisp` tool in the
live editor. Project identities separate conversations, not editor access.

**Status: stage 5 implemented — persistent Chat Completions agent.**
`emacs-agent-ask` sends through your configured Chat Completions backend/model.
Turns are FIFO within a session; different sessions can request concurrently.

- Specification: [docs/EMACS_AGENT_SPEC.md](docs/EMACS_AGENT_SPEC.md)
- Pi/Pigo research and proposed post-MVP implementation plan:
  [docs/POST_MVP_ROADMAP.md](docs/POST_MVP_ROADMAP.md)
- Tested gptel baseline, integration decisions, risks and manual smoke test:
  [docs/GPTEL_INTEGRATION.md](docs/GPTEL_INTEGRATION.md)
- Prototype: `examples/emacs-agent-spike.el`
- Reusable evaluator: `emacs-agent-eval.el`
- Accepted architectural decisions: [docs/adr](docs/adr)
- Live buffer reading helpers (F0): `emacs-agent-helpers.el`

No global keybindings or user gptel configuration are changed. The adapter
uses the pinned gptel revision documented below. A separate shell tool remains
out of scope; shell execution is available through unrestricted Lisp.

## Installation and usage

Tested with Emacs 30.2 and gptel 0.9.9.5 at commit
`fc6963634af2f76a9909ad674e2c0b3f005e60b5` (see integration notes for
installed package/dependency versions). The declared minimum Emacs is 28.1,
not yet tested. Install/pin gptel using your normal Emacs package management,
configure its Chat Completions backend/model, then add this repository to
`load-path`. Package loading does not send requests. Unsupported gptel
versions fail before network submission rather than silently replaying data.

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
run statuses. `emacs-agent-stream` defaults to t; supported backends without
streaming may return a single response, and nil requests non-streaming.
Supplied reasoning is streamed as received, never reconstructed. Context metadata is kept
separate from displayed user text.

The journal is updated incrementally, without erasing/redrawing old entries.
Adjacent text/reasoning chunks share a section; model history contains one
assembled assistant message per HTTP response, not one message per token.
An HTTP stream-end signal does not release the FIFO; only the run's terminal
FSM state does. Cancel/error preserves already received partial text.

Tool arguments/results are initially folded (`emacs-agent-log-collapse-tools`);
reasoning is initially visible (`emacs-agent-log-collapse-reasoning`).
`emacs-agent-show-reasoning` can hide it in newly rendered views without
removing stored/replay data; reopen the journal to apply it to old sections.
`TAB`
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

`emacs-agent-context-history` defaults to `current`: the active run's input
snapshots are sent, including every tool continuation. Adjacent identical
snapshots are elided without dropping input text; A→B→A is retained. `full`
includes all captured snapshots; nil sends no automatic context. Tool arguments/results
and assistant/user text are never removed by this policy. Policy is frozen at
submission, so queued runs and their tool continuations cannot switch modes
mid-turn. Filtering never mutates stored snapshots or history records.
Ambient gptel prompt transforms and chat UI history truncation are disabled
for the private transport only; user's gptel settings/hooks are unchanged.

### Steering and pending input

`M-x emacs-agent-steer` captures its own context and queues clarification for the
current active run (paused runs too). It delivers after the **entire tool batch**,
never between tools. It does not change that run's execution buffer, settings or
system instructions. With no active run it errors; ordinary `ask` remains FIFO.
If the captured target completes during input or before delivery, clarification
becomes a new FIFO run behind older asks, with its own frozen configuration and
instructions. Cancel/error retains undelivered steering for explicit recovery;
independent ordinary queued asks keep their existing FIFO behavior.

`M-x emacs-agent-pending` opens a read-only list of pending asks and steering:
`g` refresh, `e` edit, `d` withdraw, `r` resubmit, `D` forget withdrawn input with
confirmation, `RET` full text. Editing withdraws **before** opening the minibuffer;
`C-g` keeps the original withdrawn text. `RET` resubmits at the tail with original
context/config/instructions, not a new capture from the pending view. Live-target
steering stays steering; stopped/restarted recovery becomes an ordinary ask.
Lifecycle updates refresh an already open view without selecting windows.

`emacs-agent-pending-input-limit` defaults to 8 undelivered entries per session,
including withdrawn recovery. `emacs-agent-pending-byte-limit` defaults to 256 KiB
of UTF-8 frozen run payloads (text/context/instructions included). Overflow
rejects the new submission without evicting existing input. Withdraw does not
free recovery space; reuse or explicitly forget it. These are not audit retention
limits. Persistence remains best-effort with visible save warnings.

After restart inputs are recovery-only, never automatically sent. Recovery checks
live source identity and configured backend, prompting if unavailable; credentials
are not saved. Context/instructions/model settings stay frozen. Offline inspection
does not require gptel. Journal shortcuts: `C-c C-s` steer, `C-c C-p` pending.

Offline coverage includes real pinned streaming/non-streaming parsing with mocked
HTTP, lifecycle/reentrancy, bounds and recovery. Live F2 smoke is still separate.
F2 introduced state structs requiring restart on upgrade. F6 later replaced the
storage namespace: pre-F6 snapshots are not imported (see Persistence below). See
[ADR-0007](docs/adr/0007-steering-boundaries.md).

Snapshot autosave uses fast per-record Lisp serialization, not recursive
pretty-printing in network callbacks. Schema, immediate boundary saves, partial
checkpoints and atomic writes are unchanged. A private ~391 KB session benchmark
reduced full save from ~976 ms to ~14 ms; the user subsequently confirmed that
the input stalls disappeared during the repeated live test. See [ADR-0008](docs/adr/0008-responsive-snapshots.md).

### Temporary final-answer message

Successful completion echoes a short preview without opening a buffer. By
default it shows the beginning, up to **3 screen lines** including wrapping
and any `...` marker. The complete answer remains in the journal/history;
reasoning, tool commentary and failed/cancelled runs do not notify. If the
selected window already shows that session's journal, the duplicate echo is
suppressed. A background journal, another session's journal or an instructions
view does not suppress the notification.

```elisp
(setq emacs-agent-final-response-lines 3)   ; 0 disables the message
(setq emacs-agent-final-response-part 'start) ; or 'end
```

This is a normal transient `message`, not a persistent minibuffer view or a
separate timer. Previews are not copied into `*Messages*` and do not replay
when the journal is reopened. See [ADR-0006](docs/adr/0006-final-response-echo.md).

### Project instructions (F1)

New inputs read **one saved file from the project root only**, in this order:
`AGENTS.override.md` → `AGENTS.md` → `AGENTS.MD` → `CLAUDE.md` → `CLAUDE.MD`.
There is no global/parent/nested-directory discovery and no template support.
An empty higher-priority file still wins. A selected unreadable/bad file logs
warnings and contributes no instructions; it does not silently fall back.
No project or no matching file is normal. Reading follows normal filesystem
symlinks and is not a sandbox boundary.

Instructions are captured from disk on submission, after prompt entry and
before enqueue. Unsaved instruction-buffer changes are not used. The source
buffer/root/editor point are still captured before entering the minibuffer.
The snapshot is appended to the current run's system prompt, independently of
`emacs-agent-context-history`; changes to files/settings while waiting in FIFO
or running do not replace it. Earlier snapshots stay in audit, not API history.
Instruction files never execute Lisp or configure gptel.

Set `emacs-agent-project-instructions` to nil to opt out for new submissions;
`setq-local` in a source buffer provides a local opt-out. The journal shows
status/path/warnings. `M-x emacs-agent-show-instructions` shows the **captured**
text for the active run, or the last submitted snapshot if idle, without
rereading disk. Restored snapshots remain inspectable; nothing resumes itself.
See [ADR-0005](docs/adr/0005-root-project-instructions.md).

### Model I/O efficiency (F0c)

A string final value from `eval_elisp` is printed without text properties.
For example, returning `(buffer-string)` no longer serializes font-lock/eglot
metadata into the model context. Source strings/buffers are not modified.
Use `buffer-substring-no-properties` for explicit plain-text reads; do not
mutate a buffer just to inspect or verify it. Explicit property inspection,
non-string Lisp values and explicit `prin1` output retain their semantics.
Output limits still apply to the useful text.

Read results now use one literal `:text` plus range metadata, without per-line
plists. Batch exact-text edits and per-HTTP/run usage accounting are implemented.
The system prompt has executable examples for all
helpers, field extraction, continuation, read→batch and separate saving. Tests
run the actual examples through the evaluator on disposable visited files;
local variables do not survive another tool call. F0b optimizes the disk archive,
not the model's history. Findings and contracts:
[ADR-0004](docs/adr/0004-efficient-model-io.md). Token savings must be measured
with the same model/settings and comparable usage/cache metrics.

### Usage accounting

The journal records `usage` for each HTTP response and `usage-total` for the
run, separately from model history. Counts are explicitly **gptel-normalized**:
input-uncached, cache-read, output, input-total (input + cache), and total.
`:tokens-full` is retained only for reconciliation, never added repeatedly.
Missing usage is `unknown`, not zero; one missing request makes that field's
run total unknown. Zero cache in gptel's normalized data is not proof that the
provider reported zero: gptel defaults some absent raw fields to zero.
These counters measure expenditure over requests, not context-window size or
billing. Configured backend/model names can still be aliases.

Usage survives snapshot/restart, including interrupted-run audit, and is shown
when the journal is reopened. No usage is injected into API history. Both
streaming and non-streaming were checked against the available real gptel model
using temporary source data; this is not a token-savings benchmark.

### Context budget and compaction (F4)

Pigo-style compaction is enabled before each model request, including after a
complete tool batch. Defaults:

```elisp
(setq emacs-agent-context-tokens 262144
      emacs-agent-context-reserve 16384
      emacs-agent-compaction-keep-recent 20000
      emacs-agent-auto-compact t)
```

These are **configured local budgets**, not discovered capabilities of the model
or the `main` alias. Set them to suit the actual model. Reserve + retention must
be strictly below context. Settings freeze with each accepted input.

Above context minus reserve, one summary request runs without tools, then the
normal request is rebuilt and checked once more. Failure or a still-oversized
request stops explicitly; nothing is silently dropped and tools are never
reexecuted to repair history. Provider context errors do not trigger a retry loop.
The estimate uses Unicode characters/4 plus framing, calibrated by the latest
known normalized input+cache+output and estimated delta when available. It is
not a tokenizer, exact context measurement, or billing count.

`M-x emacs-agent-compact` manually summarizes an idle session. `C-u` asks for
retention (including **0** to summarize all) and optional focus. Existing cancel
also cancels in-flight compaction. Queued asks wait for it. Manual compaction
always persists before publishing; automatic compaction requires autosave so
turning autosave off does not unexpectedly write history.

Summary requests now use Pi's dedicated summarizer system prompt, explicit
`<conversation>` / `<previous-summary>` blocks and initial/update checkpoint
instructions **after** the data. Six sections are requested: Goal, Constraints
& Preferences, Progress, Key Decisions, Next Steps, Critical Context. Previous
summary appears once in its separate block (with the existing 2000-byte limit).
Focus follows the template. Headings are requested, not validated; no retry or
new acceptance rule was added. Existing saved summaries are not rewritten.
See [ADR-0011](docs/adr/0011-pi-summary-request-framing.md).

Original messages, snapshots, tool pairs and the journal remain intact. Only the
model projection changes to summary + recent suffix. Retention is a target;
boundary adjustment can retain less. Repeated compaction includes the previous
summary, not its old raw prefix. Retained call IDs and protocol reasoning remain
paired. Under `current`, delivered current-run snapshots remain explicit even
if their old text was summarized; `full` applies to retained raw history, with
older snapshots represented by summary; nil omits snapshots.

Like pigo, summary input is lossy: each block keeps a UTF-8-safe **2000-byte
prefix**, and total transcript uses a bounded first-quarter/newest-tail layout.
Long values/errors/file references can therefore be omitted from the summary
input; their original journal records and any F3 files are not removed.
Only a completed nonblank summary and successful snapshot write change the
projection. Cancel while generating or failed saving leaves the previous
projection. An already committed summary remains if the rebuilt request is still
too large. Restart never resumes
an interrupted summary automatically. Auto summary HTTP usage belongs to the
owning run; manual summary has its own audit/usage run.

**Restart Emacs after updating from pre-F4 code:** session/run structures changed;
do not hot-load the new structs into existing sessions. 227 offline ERT and
warnings-as-errors compilation pass. The user exercised manual compaction;
one isolated tool-free probe of the new framing on `aiserver/main` produced a
structured summary, with a remaining factual error. This is not a full live
lifecycle matrix or a guarantee of summary quality. See
[ADR-0010](docs/adr/0010-pigo-style-compaction.md).

### Reading live buffers (F0)

Loading `emacs-agent` also loads three ordinary Lisp helpers, usable through
`eval_elisp` without adding any model tools:

```elisp
(emacs-agent-buffer-info "example.el")
(emacs-agent-read-lines "example.el" 14 20 :widen t)
(emacs-agent-read-around "example.el" 367 :before 2 :after 2 :widen t)
```

Use an explicit live buffer or its exact name. Helpers read unsaved text and
preserve point, mark, restrictions and windows. Lines are absolute, 1-based;
columns are 0-based display columns (tabs expanded), positions are character
positions. Empty lines count, including the last empty line after a newline.
`line-beginning-position` takes a **relative** argument, not an absolute line.
Without explicit `:widen t`, inaccessible or partially inaccessible lines are
rejected, not silently clipped. Invalid ranges/positions and dead buffers fail.

Results are plists with buffer metadata once and one literal `:text`, without
numbering or per-line rows. Both reading helpers and `buffer-info` include
`:total-lines`: the absolute whole-buffer line count, even under narrowing.
An empty buffer has one line; a terminal newline adds an empty line. Bound
requested END by this value rather than guessing EOF; it does not authorize
reading outside narrowing. Return the read result intact to retain metadata;
extract fields locally when consuming a result inside one eval. `:start`/exclusive `:end` are buffer positions;
`:start-line`/`:end-line` are the lines of those positions (end may be at the
next line's beginning after a returned newline). Internal newlines and empty
lines are preserved; the newline after requested END is excluded. Around adds
`:at` with coordinates and symbol at the supplied position. The old `:lines`
format was removed in deep alpha, without a compatibility mode.
`:limit` defaults to 4096 text characters; printed-output budgeting can reduce
it further. On `:truncated t`, `:next-position` equals `:end`: resume with the
same line range and `:from NEXT-POSITION :tick TICK` from the result, concatenating
`:text` without adding separators, even if a chunk ends at/on a newline. Supplying an old modification
tick fails after a text edit. Without an expected tick, a still-in-range old
position cannot be identified as stale. Names can also be reused after a kill;
these snapshots are not persistent identities or live markers.

Use the helper as the sole final form, without stdout: its printed plist plus
`=>` prefix is budgeted against `emacs-agent-eval-output-limit`. If metadata
cannot fit, the helper errors rather than returning an incomplete plist.
Wrapping the result or printing extra output can still trigger the evaluator's
general truncation.

### Full tool output (F3)

`eval_elisp` still returns a plain string. If it exceeds
`emacs-agent-eval-output-limit` (default 32768 characters), the full text is saved
as UTF-8 in a unique 0600 file under `emacs-agent-data-directory/tool-output/`.
The model receives a **tail** and a notice with the quoted absolute path. The
notice counts toward the limit; if it alone exceeds the limit, it is returned
intact without a tail. Exact-limit results do not create a file.

This normally retains final `=> VALUE` / ERROR / QUIT after noisy stdout. A value
that itself exceeds the tail can still be cut; the complete text is in the file.
Use ordinary Elisp (`insert-file-contents` and buffer APIs) to inspect needed
ranges; never load saved output as code. No new tool, helper or viewer is added.

Write failure returns an explicit unavailable warning, never a partial-file
reference, and **never repeats evaluation**. Files are private, not encrypted;
there is no registry, automatic deletion or storage quota. Delete them manually.
Removing/moving files can invalidate old references. Output is still collected
in memory before saving; this is not a memory or execution limit.
See [ADR-0009](docs/adr/0009-simple-full-tool-output.md).
See [ADR-0001](docs/adr/0001-f0-buffer-helpers.md) for the contract.

### Editing live buffers with undo

Prefer one exact-text batch through `eval_elisp`:

```elisp
(emacs-agent-replace-texts "example.el"
  '((:old "unique old text" :new "replacement")
    (:old "another unique fragment" :new "another replacement"))
  :tick TICK)
```

Take TICK from a fresh read. Every nonempty OLD must match exactly once in the
original accessible text, case-sensitively (overlapping occurrences also count).
All ranges are validated before any edit; overlaps/duplicates fail, adjacency
is allowed. Apply bottom-up regardless of list order: NEW text is never used
to locate a later OLD. Empty NEW deletes; for insertion, include a unique OLD
anchor in NEW. All replacements share one atomic undo step and one initial
tick check, with rollback of the entire buffer edit on error. No manual offsets,
per-edit tick updates or hand-written transaction wrappers are needed.

Result: `:buffer`, final `:tick`, `:modified` and integer `:changed` (number of
non-no-op edits), not full source/diff. An all-no-op batch preserves tick and
undo. Normal hooks run; external hook side effects cannot be rolled back.

For an explicit-coordinate replacement, the existing
`(emacs-agent-replace-region BUFFER START END OLD NEW :tick TICK)` remains
available. Positions are absolute characters, END exclusive. Supply
exact OLD text and the modification tick from a fresh read. Empty OLD with
START=END inserts; empty NEW deletes. `:widen t` explicitly permits editing
outside narrowing. Dead buffers, stale text/tick, read-only buffers, disabled
undo and external visited-file changes fail rather than being overridden.

String indices (`substring`, `aref`, `string-match`) start at 0, unlike buffer
positions. Index I in text captured from position BASE maps to BASE+I; for
`buffer-string`, BASE is `point-min` at capture, not necessarily 1 when narrowed.
Prefer positions from reading helpers. On OLD mismatch or stale tick, reread
and recompute the range/text/tick; do not guess offsets or bypass the rejection
with direct edits. Mismatch errors include range, tick and an escaped preview
of up to 160 actual characters, explicitly marked if truncated. This is only
diagnostic text, not permission to apply a replacement. The evaluator may
further truncate errors under a small output limit.

A replacement is atomic and one undo step, separate from existing user undo.
Normal change hooks run; hook errors roll back the target buffer's text, not
arbitrary external side effects. Point/mark and narrowing track the edit as
Emacs markers. The small region-helper result reports `:buffer`, `:start`, exclusive new
`:end`, `:tick`, `:modified` and `:changed`. Identical text is a no-op.

Neither helper saves. When saving is intended, use
`(with-current-buffer BUFFER (save-buffer))`. This saves the whole buffer,
including pre-existing user modifications, and keeps undo, file timestamps,
backups and save hooks working normally. A save failure leaves the buffer edit
available for inspection and undo. Do not fake saving with
`set-buffer-modified-p nil`: three-argument `write-region` does not update the
visited-file timestamp and can cause a spurious reload warning. Do not use
shell writes or `revert-buffer` as routine synchronization for visited files.

The model receives these guidelines in its system prompt; unrestricted eval
can still bypass them. Undo is subject to normal Emacs size limits and buffer
lifetime, not persisted across restarts. See
[ADR-0002](docs/adr/0002-buffer-native-editing.md).

### Replay support boundary

Currently supported: trusted **OpenAI Chat Completions** configurations using
plain text, `eval_elisp` function calls and optional textual `reasoning` /
`reasoning_content` on assistant tool messages. These fields are retained and
restored to generated wire messages, along with original provider call IDs.
Final answer reasoning without a tool call remains journal-only.

Responses API, Anthropic, Gemini and other backend types fail before sending
a request: their opaque reasoning/signature formats are not safely replayable
through this gptel adapter. Observed unknown assistant/tool protocol fields,
signatures, encrypted data or callback shapes also fail explicitly, before
tool execution. That session receives a non-replayable history marker; future
turns fail rather than silently omit unsupported data. There is no reset UI:
archive the affected snapshot and restart, or start a fresh Emacs with a new
data directory. Restarting alone intentionally retains the failure marker.

This is not a universal detector for proprietary Chat extensions: upstream
gptel can discard unrecognized streaming fields before exposing them. Use
only endpoints whose protocol fits the stated support boundary; arbitrary
OpenAI-compatible vendors with hidden/opaque requirements are not supported.
Known textual tool reasoning is preserved; opaque blobs are not reconstructed.

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

The editor is shared live state: the user can edit, undo/redo or save changes
between tool calls. History/results describe past actions, not proof of current
buffer or disk contents. Reinspect current state before continuing and preserve
user changes. F7's separate execution ledger/durable dispatch gate was excluded;
existing audit remains best-effort, with no automatic replay after interruption.
See [ADR-0013](docs/adr/0013-interactive-editor-no-tool-ledger.md).

## Conversations (F6)

Multiple independent conversations share each project/global scope:

- `M-x emacs-agent-session-new`: save the previous conversation and select an empty one;
  `C-u` asks for an optional name.
- `M-x emacs-agent-session-rename`: save a name; empty clears it. Names need not be unique.
- `M-x emacs-agent-session-select`: choose a conversation **in the current scope**.
- `M-x emacs-agent-session-search`: regexp search over local names/history/summary/events
  across scopes, without a model, external artifact reads or an index.
- `M-x emacs-agent-session-clone`: select an independent copy; `C-u` asks for a name.

Journal labels include name, scope and a short conversation ID. In
`emacs-agent-session-list`, `Current` marks the in-process scope selection.
**RET only opens a journal; it does not select it.** Explicit new/select/clone
focus the chosen journal. Commands in a nonselected
journal explicitly target its owner; working buffers use their scope's selection.
Ask captures an existing conversation before minibuffer entry, never retargeting
silently if selection changes while typing.

Each new Emacs process starts a **fresh global conversation** on first implicit
use. Old F6 globals can be explicitly selected for that process, but are never
implicitly restored next time. Project selections persist. Showing journals,
listing/searching, or reloading the same package version does not create duplicate
globals or select archives.

New/select/clone require involved conversations idle: no active/paused run,
ordinary queue, compaction or prepared/queued input. Withdrawn recovery may stay
with its original conversation. Rename requires its target idle. Save/pointer
failure leaves the old choice and history intact. A written candidate may remain
unselected if pointer persistence fails. Explicit conversation operations save
regardless of `emacs-agent-auto-save`; initial project identity/selection also
persists even when chat autosave is off.

Clone copies archival messages/events and compaction with source-ID provenance,
not pending recovery, queues, usage anchor, source/backend/transport handles or
execution authority. Historical tool IDs/reasoning stay paired; nothing executes.
F3 paths remain references to the same original files. Invoking new/select/clone
from a working buffer explicitly binds that buffer for future journal asks;
cloning from an archive alone does not inherit its old execution source.

**Restart Emacs after this update**, since struct/registry meanings changed.
No migration: pre-F6 `global.eld` / `project-*.eld` stay untouched but do not appear
in the F6 catalog. See [ADR-0012](docs/adr/0012-multiple-conversations.md).

## Persistence and recovery

`emacs-agent-data-directory` defaults to `emacs-agent/` below
`user-emacs-directory`, not the active project. **Schema 3** conversations use
`conversations/<hash-of-conversation-id>.eld`; project pointers use
`selections/<hash-of-root>.eld`. There is no persisted global selection.
Files are read as Lisp **data**, never loaded/evaluated as code. Writes use a
same-directory temporary file and atomic rename (new directories 0700, files
0600). Schema 1/2 and old root-level snapshots are not read/imported or rewritten.
Old files can stay in the data directory as untouched archives. F3 full-output
files still use the separate `tool-output/` directory.
No encryption is provided. If your Emacs directory is tracked in dotfiles,
ignore this subdirectory or configure an untracked/private location.

`emacs-agent-auto-save` defaults to t. Meaningful events, tool boundaries,
completion/cancellation and partial-response completion trigger checkpoints.
Streaming deltas are checkpointed at most every five seconds. Explicit
`M-x emacs-agent-save` saves the current session, including currently received
partial text, without flushing/changing its live run. A renderer failure
cannot suppress autosave; an autosave failure is reported but does not retry
or terminate the model/tool loop. Persistence writes are synchronous I/O.

F0b stores adjacent assistant/reasoning fragments as compact blocks in a
**snapshot copy** only. Live events, incremental UI cursors and stream
accumulators are unchanged; canonical model messages/protocol fields stay
independent. Block text is concatenated literally, without crossing type/run,
end/tool/status or unknown-metadata boundaries. Each block retains first
`:id`/`:time`, `:last-id`/`:last-time` and `:state`. `complete` means an immediately
following matching `*-end`, not a successful HTTP response: a flush on error
or cancel also closes assistant text. Otherwise the block is conservatively
`partial`, including earlier interleaved segments. Intermediate per-delta IDs
and delivery times are intentionally not retained. Reasoning remains stored
regardless of display policy. Restored blocks render directly, not as recreated
token events, and new events can still be appended normally.

Snapshots use fast per-record `prin1` serialization, not recursive pretty-print
layout (newlines inside strings stay escaped).
Synthetic fixture: 4,002 events become 4; a roughly 460 KB schema-1-style
snapshot becomes 11 KB, about 42x smaller. This fixture has no model messages;
real savings depend on the session's text/tools/history. Saving still copies
and traverses the full live history; F0b does not promise lower UI memory use
or a constant-time checkpoint. See [ADR-0003](docs/adr/0003-durable-streaming-blocks.md).

`M-x emacs-agent-session-list` loads independent snapshots and shows sessions;
`RET` opens a read-only journal, `g` refreshes. Asking/showing from a project
lazily restores its selected conversation; global starts fresh in each process.
Catalog loading only registers conversations, never selects them. Existing
in-memory conversations are never overwritten by a disk refresh. Backend/model are chosen
from the current gptel configuration on each new run; stored settings are
an audit, not code that alters user configuration.

After restart, active/paused and queued tasks become `interrupted` events.
**Nothing is automatically resumed or reexecuted.** Completed results and
partial text remain in history. Pending user text is retained in the journal,
not silently submitted to the model; copy/resubmit it deliberately. Already
performed effects may remain even when a result was not checkpointed. Inspect
interrupted runs before requesting continuation.

Only source buffer name/file identities are saved. They reconnect to matching
already-open buffers when available, otherwise remain unavailable. No file is
automatically opened; no buffer/window/process/marker/closure/backend credential
object or HTTP handle is restored.

A corrupt/unsupported file in the new namespace does not prevent other
conversations from loading. Direct selected-target restore fails explicitly;
it is not silently replaced with an empty session. Unsupported files inside the
new namespace require a separate data directory or manually archiving the file;
there is no compatibility reader or migration command. Snapshots are plaintext and can contain secrets
from prompts, reasoning and tool results; do not publish them. Concurrent
writers from multiple Emacs processes are not supported (last rename wins).
Transport-buffer reclamation is still not automatic.

## Long prompts

The tested Emacs has no built-in `edit-minibuffer`/`minibuffer-edit` command,
so no fictitious `C-M-c` binding is installed. A dependency-free standard
workflow is to compose/edit the prompt in an ordinary draft buffer, copy it
with `M-w`, switch to the intended working buffer, invoke `emacs-agent-ask`,
then `C-y` and `RET`. Multiline text is retained; context comes from the working
buffer, not the draft. Existing minibuffer-editing extensions can also use
normal minibuffer hooks/keymaps; the agent does not supply a custom editor.

## Test

Requires Emacs and the gptel revision documented above in an ELPA directory.
The full suite has 252 ERT tests; it uses mocks and dry-run requests, not API
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
back changes or guarantee termination of subprocesses. Saved history has no
separate encryption; protect the data directory and backups.
