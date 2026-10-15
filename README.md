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

`emacs-agent-context-history` defaults to `current`: only the active user
turn's snapshot is sent, including every tool continuation. `full` includes
all user snapshots; nil sends no automatic context. Tool arguments/results
and assistant/user text are never removed by this policy. Policy is frozen at
submission, so queued runs and their tool continuations cannot switch modes
mid-turn. Filtering never mutates stored snapshots or history records.
Ambient gptel prompt transforms and chat UI history truncation are disabled
for the private transport only; user's gptel settings/hooks are unchanged.

### Model I/O efficiency (F0c, in progress)

A string final value from `eval_elisp` is printed without text properties.
For example, returning `(buffer-string)` no longer serializes font-lock/eglot
metadata into the model context. Source strings/buffers are not modified.
Use `buffer-substring-no-properties` for explicit plain-text reads; do not
mutate a buffer just to inspect or verify it. Explicit property inspection,
non-string Lisp values and explicit `prin1` output retain their semantics.
Output limits still apply to the useful text.

Read results now use one literal `:text` plus range metadata, without per-line
plists. Remaining F0c work is batch exact-text buffer edits and cache-aware
usage accounting; these are not yet implemented. F0b optimizes
the disk archive, not the model's history. Findings and contracts:
[ADR-0004](docs/adr/0004-efficient-model-io.md). Token savings must be measured
with the same model/settings and comparable usage/cache metrics.

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
numbering or per-line rows. `:start`/exclusive `:end` are buffer positions;
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
general truncation. Full tool-output artifacts are deferred to F3.
See [ADR-0001](docs/adr/0001-f0-buffer-helpers.md) for the contract.

### Editing live buffers with undo

Prefer `(emacs-agent-replace-region BUFFER START END OLD NEW :tick TICK)`
through `eval_elisp`. Positions are absolute characters, END exclusive. Supply
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
Emacs markers. The small result reports `:buffer`, `:start`, exclusive new
`:end`, `:tick`, `:modified` and `:changed`. Identical text is a no-op.

The helper does not save. When saving is intended, use
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

## Persistence and recovery

`emacs-agent-data-directory` defaults to `emacs-agent/` below
`user-emacs-directory`, not the active project. Each session has an independent
versioned `.eld` data file: `global.eld` or a canonical-root hash. Files are
read as Lisp **data**, never loaded/evaluated as code. Writes use a same-directory
temporary file and atomic rename (new directory 0700, snapshot files 0600).
Current format is **schema 2**; deep-alpha schema 1 is unsupported and no
migration is provided. For a fresh test, choose a new private
`emacs-agent-data-directory` before asking/loading sessions; existing archives
are not automatically deleted or converted.
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

Snapshots are pretty-printed Lisp data (newlines inside strings stay escaped).
Synthetic fixture: 4,002 events become 4; a roughly 460 KB schema-1-style
snapshot becomes 11 KB, about 42x smaller. This fixture has no model messages;
real savings depend on the session's text/tools/history. Saving still copies
and traverses the full live history; F0b does not promise lower UI memory use
or a constant-time checkpoint. See [ADR-0003](docs/adr/0003-durable-streaming-blocks.md).

`M-x emacs-agent-session-list` loads independent snapshots and shows sessions;
`RET` opens a read-only journal, `g` refreshes. Asking/showing from a project
or global buffer lazily restores that canonical session. Existing in-memory
sessions are never overwritten by a disk refresh. Backend/model are chosen
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

A corrupt/unsupported file does not prevent other sessions from loading.
Direct access to its session fails with its path and an explicit error;
it is not silently replaced with an empty session. Unsupported schema/adapter
versions require a separate data directory or manually archiving the file;
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
The full suite has 103 ERT tests; it uses mocks and dry-run requests, not API
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
