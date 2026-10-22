# Emacs Agent

An Emacs Lisp agent using gptel and one unrestricted `eval_elisp` tool in the
live editor. It reads and edits live buffers, runs Lisp and processes, and keeps
independent persistent conversations per project or global scope. Project
identity separates histories, **not access to the editor**.

## Contents

- [Installation](#installation)
- [Quick start](#quick-start)
- [Conversation view](#conversation-view)
- [Steering and pending input](#steering-and-pending-input)
- [Conversations and forks](#conversations-and-forks)
- [Context and project instructions](#context-and-project-instructions)
- [Configuration](#configuration)
- [Context budget and compaction](#context-budget-and-compaction)
- [Lisp helpers and examples](#lisp-helpers-and-examples)
- [Hooks](#hooks)
- [Persistence and recovery](#persistence-and-recovery)
- [Supported backends and limitations](#supported-backends-and-limitations)
- [Security](#security)

Developer documentation: [docs/development.md](docs/development.md).
Architectural decision history: [docs/adr](docs/adr).

## Installation

Tested with Emacs 30.2 and gptel 0.9.9.5 at commit
`fc6963634af2f76a9909ad674e2c0b3f005e60b5`. The declared minimum Emacs is
28.1; it has not been tested. Pin gptel with your normal package manager: the
adapter depends on its internal API, not just the package version number.

1. Install that gptel revision and configure a trusted **OpenAI Chat Completions**
   backend, model and credentials in gptel. Other backend types are unsupported.
2. Clone this repository and add its directory to `load-path`.
3. Load the package:

```elisp
(require 'gptel)
;; Set gptel-backend, gptel-model and credentials for your endpoint here.
(add-to-list 'load-path "/path/to/emacs-agent")
(require 'emacs-agent)

;; Optional: no global keybindings are installed by the package.
(global-set-key (kbd "C-c a a") #'emacs-agent-ask)
(global-set-key (kbd "C-c a s") #'emacs-agent-show)
```

Loading sends no requests and does not change your gptel configuration or hooks.
Offline history inspection does not require gptel. Requests use the current
gptel backend/model, frozen when each input is accepted. Unsupported gptel
contracts fail before network submission.

## Quick start

From a working buffer, run `M-x emacs-agent-ask` and enter, for example:

- “Explain the selected code without changing it.”
- “Find the cause of this error; inspect the current buffers first.”
- “Replace this function, leave the buffer unsaved, and check its Lisp syntax.”

The source buffer, window, point and region are captured **before** the
minibuffer opens. `RET` submits, `C-j` inserts a newline, `C-g` aborts, and
`M-p`/`M-n` browse prompt history. Blank input creates no conversation or turn.
For long prompts, compose in an ordinary draft buffer, copy with `M-w`, return
to the working buffer, ask, then `C-y` and `RET`. Context comes from the working
buffer, not the draft; there is no custom full-buffer prompt editor.

| Command | Purpose |
| --- | --- |
| `emacs-agent-ask` | Queue a new turn in the current conversation |
| `emacs-agent-show` | Open its read-only conversation journal |
| `emacs-agent-cancel` | Cancel its active run; allow the next queued turn |
| `emacs-agent-resume` | Grant another tool-call budget to a paused run |
| `emacs-agent-steer` | Send clarification to the active run |
| `emacs-agent-pending` | Inspect/edit/withdraw/recover pending input |
| `emacs-agent-show-instructions` | Inspect captured instructions, without rereading disk |
| `emacs-agent-compact` | Summarize an idle conversation |
| `emacs-agent-save` | Save the current conversation explicitly |

Turns are FIFO within a conversation; different conversations can request
concurrently. All tool evaluation is serialized across conversations, including
recursive Emacs event loops. At the tool-call limit a run pauses **before** the
next evaluation and keeps its slot until resumed or cancelled. Resume does not
repeat completed tools. There are no automatic network or evaluation retries.

Tools default to the live source buffer, or the run's transport buffer if the
source died. Captured point, region and windows are context, not restored editor
state. Asking from a journal uses its owner's last live working buffer; if that
buffer died, ask from a working buffer to establish a new source.

## Conversation view

The journal displays user/assistant text, supplied reasoning, paired tool
calls/results and run status. It updates incrementally during streaming;
cancellation and errors preserve already received text. Context metadata is
separate from displayed user text.

Tool bodies initially show a preview of up to three logical lines/400
characters. Expansion shows the retained expression, indexed `texts` payloads
and result. Output truncation/unavailable notices stay visible when folded;
expansion does not fetch external output files. Reasoning is folded by default
and only displays what the provider actually supplied. Customize
`emacs-agent-log-reasoning-face` to change its theme-aware `shadow` appearance.

| Journal key | Action |
| --- | --- |
| `TAB`, `<tab>`, `RET`, header click | Toggle a foldable section |
| `D` | Toggle diagnostic details: IDs, lifecycle, configuration, usage |
| `a` | Ask |
| `C-c C-k` | Cancel |
| `C-c C-c` | Resume |
| `C-c C-s` | Steer |
| `C-c C-p` | Pending input |
| `g` | Render any unconsumed events |

Readers of old text keep their position and scroll; only a point already at
the end follows output. Callbacks do not select windows. Closing the journal
neither cancels a run nor causes it to reopen on new output. Show replays the
retained events. Reopen to apply changed reasoning visibility to old sections.

Successful completion echoes up to three screen lines of the final answer,
without opening a buffer or copying the preview to `*Messages*`. The full answer
stays in history. Failed/cancelled runs do not notify; a selected window already
showing that conversation suppresses the duplicate preview.

### Activity and usage

`emacs-agent-status-mode` is enabled on initial load. It adds a cached component
to `global-mode-string`: `AI:wait`, `AI:reply`, `AI:eval`, `AI:compact` or
`AI:pause`. Multiple conversations aggregate (for example,
` AI:reply×2 eval q:1 `); `q:N` counts ordinary pending turns. Idle is completely
hidden. Disable with `M-x emacs-agent-status-mode`. A custom mode line must
include `global-mode-string`; the package does not replace `mode-line-format`.

Usage in journal details and session info is **gptel-normalized** expenditure
per HTTP response and per run: input-uncached, cache-read, output, input-total
(input + cache), and total. Missing fields are unknown, not zero; one missing
request makes that total unknown. A normalized zero cache count need not mean
the provider reported zero. These are not context-window sizes or billing
estimates. Usage survives restart and is never injected into model history.

## Steering and pending input

`emacs-agent-steer` captures its own context and delivers clarification after the
**entire tool batch**, never between tools. It works for paused runs, but errors
without an active run. It does not replace that run's source buffer, settings or
instructions. If the target completes before delivery, steering becomes a new
FIFO turn behind older asks, with its own captured configuration. Cancel/error
retains undelivered steering for explicit recovery.

In `emacs-agent-pending`: `g` refreshes, `e` edits, `d` withdraws, `r` resubmits,
`D` forgets withdrawn input with confirmation, and `RET` shows full text.
Editing withdraws **before** opening the minibuffer; `C-g` keeps the original
withdrawn text. Submitting the edit appends it at the tail with its original
context/configuration/instructions, not a capture from the pending view.
Live-target steering stays steering; stopped/restarted recovery becomes an ask.

Defaults allow eight undelivered entries per conversation and 256 KiB of UTF-8
frozen payloads, including context and instructions. Withdrawn recovery counts
toward both limits. Overflow rejects new input without eviction; withdrawing
does not free space, but reuse or explicit forgetting does.

After restart inputs are recovery-only, never automatically sent. Recovery
checks the live source identity and configured backend, prompting if unavailable.
Credentials are not saved; context, instructions and model settings stay frozen.

## Conversations and forks

Files in a project share a canonical root scope; non-project buffers use the
global scope. Local symlinked roots are resolved when possible; remote roots
are not locally canonicalized. Same-basename projects remain separate.

| Command | Purpose |
| --- | --- |
| `emacs-agent-session-new` | Save the old conversation and select an empty one; `C-u` asks for a name |
| `emacs-agent-session-rename` | Save a name; empty clears it; names need not be unique |
| `emacs-agent-session-select` | Select a conversation within the current scope, newest activity first |
| `emacs-agent-session-list` | List saved conversations; `g` refreshes, `RET` opens a journal |
| `emacs-agent-session-search` | Regexp search across local names/history/summaries/events in all scopes |
| `emacs-agent-session-clone` | Select an independent copy; `C-u` asks for a name |
| `emacs-agent-session-fork` | Select a completed turn and fork through it; `C-u` also asks for a name |
| `emacs-agent-session-info-show` | Show IDs, scope, source liveness, state, history, usage and save status |

`emacs-agent-session-info` also returns the information as a plist, accepting a
session object or ID, without requesting, loading archives or creating views.
Search needs no model/index and does not read external output artifacts.

Selectors show a short conversation ID and the original first user request,
normalized and clipped to minibuffer width. Empty conversations show their name
or `(empty)`. Colliding short IDs extend automatically. The ID suffix matches
the saved filename. **RET in the session list opens but does not select**;
new/select/clone/fork explicitly select and focus a journal. Commands from an
unselected journal still target its owner. Ask captures its existing target
before prompt entry, so selection changes while typing do not retarget it.

Each Emacs process starts a fresh global conversation on first implicit use.
Old globals remain explicitly selectable; project selections persist. Merely
listing/searching/showing archives does not select them.

New/select/clone/fork require involved conversations idle: no active/paused run,
ordinary queue, compaction or prepared/queued input. Rename requires its target
idle. Withdrawn recovery may remain. Explicit conversation operations persist
even when autosave is off; save/selection failure leaves the old selection intact.
A candidate written before a pointer-save failure may remain unselected on disk.

Clone copies archival messages/events and compaction with provenance, not pending
recovery, queues, usage anchor, runtime handles or execution authority. A working
buffer invoking new/select/clone becomes the new source; an archive-only clone
does not inherit an execution source. Output artifact references remain shared.

Fork endpoints are successful completed turns, including their delivered
steering and tool pairs, not individual tools, failed/cancelled turns or active
work. After compaction the latest summary is the first logical endpoint: fork
after it alone or a retained completed turn, not inside the summarized prefix.
The fork inherits the summary and chosen suffix, excluding later work and queued
input. From a journal it uses the last working buffer only if still live.
The original is unchanged. **Buffers, files and processes are not rolled back;
tools are never replayed.**

## Context and project instructions

Snapshots capture absolute character positions, widening-aware 1-based lines
and 0-based columns, narrowing bounds, file/mode/directory and optional region
text. Selections over `emacs-agent-region-text-limit` retain bounds only. No full
buffer is automatically captured. Context uses framed JSON and is separate from
user text.

`emacs-agent-context-history` controls automatic snapshots sent to the model:

- `current` (default): the active run's inputs, including tool continuations;
- `full`: all retained captured snapshots;
- `nil`: no automatic editor context.

Adjacent identical snapshots are elided, but A→B→A remains. This never removes
user/assistant text or tool arguments/results, nor changes stored history. The
policy freezes at submission. Private transport disables ambient gptel prompt
transforms/history truncation without changing the user's gptel settings.

### Instruction files

For each new input, read **one saved common file from the project root only**,
in this priority order:

`AGENTS.override.md` → `AGENTS.md` → `AGENTS.MD` → `CLAUDE.md` → `CLAUDE.MD`.

Then append optional **`EMACSAGENT.md`** from the same root, even if no common
file exists. Each file gets its own path heading. No global, parent or nested
search and no templates are supported. An empty higher-priority file wins;
a selected unreadable/bad file warns rather than silently falling back. Errors
in one file do not suppress the other. Symlinks are followed normally.

Instructions are captured from disk after prompt entry and before enqueue;
unsaved changes are not used. The snapshot is added to that run's system prompt,
independently of context-history policy, and stays frozen through FIFO waits,
continuations and recovery. Earlier instruction snapshots remain in audit, not
API history. Files do not execute Lisp or configure gptel.

Set `emacs-agent-project-instructions` to nil to opt out of both files for new
inputs; `setq-local` in a source buffer provides a local opt-out. The journal
shows paths/status/warnings. `emacs-agent-show-instructions` shows captured text
for the active run or last submitted snapshot without rereading disk.

## Configuration

Use `M-x customize-group RET emacs-agent` or set the variables below. Defaults:

| Variable | Default | Meaning |
| --- | --- | --- |
| `emacs-agent-stream` | `t` | Request streaming; nil requests a single response |
| `emacs-agent-max-tool-calls` | `100` | Tool calls per budget block; zero pauses before any evaluation |
| `emacs-agent-context-history` | `current` | Automatic snapshot policy: `current`, `full`, nil |
| `emacs-agent-region-text-limit` | `8192` | Maximum captured region characters |
| `emacs-agent-project-instructions` | `t` | Read root instruction files for new inputs |
| `emacs-agent-context-tokens` | `262144` | Configured context budget, not model discovery |
| `emacs-agent-context-reserve` | `16384` | Headroom before compaction |
| `emacs-agent-compaction-keep-recent` | `20000` | Recent-history retention target in estimated tokens |
| `emacs-agent-auto-compact` | `t` | Compact before an oversized request; requires autosave |
| `emacs-agent-pending-input-limit` | `8` | Undelivered inputs per conversation, including withdrawn recovery |
| `emacs-agent-pending-byte-limit` | `262144` | Frozen pending payload budget in UTF-8 bytes |
| `emacs-agent-eval-output-limit` | `32768` | Returned tool text limit in characters |
| `emacs-agent-data-directory` | `emacs-agent/` under `user-emacs-directory` | Private snapshots and full tool output |
| `emacs-agent-auto-save` | `t` | Best-effort automatic conversation checkpoints |
| `emacs-agent-show-reasoning` | `t` | Display supplied reasoning; stored data is unaffected |
| `emacs-agent-log-collapse-tools` | `t` | Initially fold tool bodies |
| `emacs-agent-log-collapse-reasoning` | `t` | Initially fold supplied reasoning |
| `emacs-agent-final-response-lines` | `3` | Preview screen lines; zero disables |
| `emacs-agent-final-response-part` | `start` | Preview beginning or `end` of final answer |
| `emacs-agent-status-prefix` | `"AI"` | Activity prefix; empty omits it and the colon |
| `emacs-agent-status-labels` | See below | Activity-label alist; missing keys fall back to state names |

```elisp
(setq emacs-agent-final-response-lines 0
      emacs-agent-status-labels
      '((waiting . "wait") (responding . "reply") (eval_elisp . "eval")
        (compacting . "compact") (paused . "pause") (queued . "q")))
;; Customize refreshes automatically; after setq refresh the status explicitly:
(emacs-agent-status-update)
```

The package also exposes `emacs-agent-minibuffer-map` for prompt keybindings and
`emacs-agent-prompt-history` for user-written prompt history. It defines no
project-specific environment variables; backend credentials/configuration belong
to gptel.

## Context budget and compaction

Set the budget for your actual model; it is not discovered from its name/alias.
Reserve + retention must be strictly below context. Settings freeze per input.
Above context minus reserve, automatic compaction makes one tool-free summary
request, then rebuilds and checks the normal request once. Failure or a still
oversized request stops explicitly: no silent history dropping, tool replay or
provider-error retry loop. The estimate uses characters/4 plus framing, with
usage-based calibration when available; it is not a tokenizer or billing count.

`emacs-agent-compact` summarizes an idle session. `C-u` asks for retention
(including zero to summarize all) and optional focus. Cancel also cancels
compaction; queued asks wait for it. Manual compaction always saves before
publishing. Automatic compaction requires autosave and does not write history
when autosave is disabled.

The model projection becomes summary + recent suffix; original messages,
snapshots, tool pairs and journal remain stored. Retention is a target; safe
boundaries can retain less. Repeated compaction uses the previous summary, not
its raw prefix. Under `current`, delivered current-run snapshots remain explicit;
under `full`, old summarized snapshots are represented by the summary.

Summary input is **lossy**: each block keeps a UTF-8-safe 2000-byte prefix, and
the total transcript keeps a bounded first-quarter/newest-tail layout. Details,
errors and paths may be omitted. Requested summary sections are Goal, Constraints
& Preferences, Progress, Key Decisions, Next Steps and Critical Context; quality
and headings are not guaranteed. Only a completed nonblank summary and successful
save change the projection. Failed save/cancel leaves the previous projection;
an already committed summary remains if the rebuilt request is still too large.
Restart never resumes a summary automatically.

## Lisp helpers and examples

Helpers are ordinary Lisp functions available through the **same** `eval_elisp`
tool, not additional model tools. `C-h f` provides their full contracts.
The model receives core helper examples and edit/save/check guidance in its
system prompt. Unrestricted Lisp can still bypass these helpers.

### Reading live buffers

```elisp
(emacs-agent-buffer-info "example.el")
(emacs-agent-read-lines "example.el" 14 20 :widen t)
(emacs-agent-read-around "example.el" 367 :before 2 :after 2 :widen t)
```

Use an explicit live buffer or exact name. Reads include unsaved text and
preserve point, mark, narrowing and windows. Lines are absolute and 1-based;
columns are 0-based display columns; positions are characters. Empty buffers
have one line, and a terminal newline adds an empty line. Bound END using
`:total-lines` from the result, not guessed EOF. Without explicit `:widen t`,
inaccessible or partially inaccessible lines are rejected, not clipped.

Results are plists with metadata and one literal `:text`. `:start`/exclusive
`:end` are positions; `:total-lines` counts the whole buffer even under
narrowing. The newline after requested END is excluded. Around adds `:at`.
`:limit` defaults to 4096 text characters, possibly reduced by output budgeting.
On `:truncated t`, resume the same range with `:from NEXT-POSITION :tick TICK`
from the result, concatenating `:text` without extra separators. A stale tick
fails; names and unguarded positions are not persistent identities.

Return a read helper as the sole final form without stdout so its complete
plist fits the tool budget. If metadata cannot fit, the helper errors rather
than returning an incomplete plist. Wrapping/printing more can still trigger
general output truncation. Final string values are printed without text
properties; use `buffer-substring-no-properties` for explicit plain-text reads.

### Editing and saving

```elisp
;; Replace TICK with the integer from a fresh read.
(emacs-agent-replace-texts "example.el"
  '((:old "unique old text" :new "replacement")
    (:old "another unique fragment" :new "another replacement"))
  :tick TICK)

(emacs-agent-replace-region "example.el" START END OLD NEW :tick TICK)
;; Save separately, only when intended:
(with-current-buffer "example.el" (save-buffer))
```

Batch OLD strings must be nonempty and match exactly once, case-sensitively,
in the original accessible text. All ranges are validated before editing;
overlap/duplicates fail, adjacency is allowed. Application is bottom-up, so
replacement text never locates a later OLD. Empty NEW deletes; include an OLD
anchor in NEW to insert. Results report buffer, tick, modified state and the
number of changed edits, not full source. All-no-op edits preserve tick/undo.

Region positions are absolute characters, END exclusive; empty OLD at START=END
inserts. `:widen t` explicitly allows editing outside narrowing. Stale tick/text,
dead/read-only buffers, disabled undo and external visited-file changes fail.
Reread and recompute on rejection; do not guess offsets or bypass guards.
String indices are 0-based, unlike buffer positions: index I captured from BASE
maps to BASE+I, where BASE may not be 1 under narrowing.

Edits are atomic and one undo step, separate from existing undo. Normal hooks
run; rollback covers target text, not arbitrary external hook effects. Point,
mark and narrowing track changes as markers. Neither helper saves.
`save-buffer` saves the **whole buffer**, including pre-existing user changes;
a save failure leaves edits inspectable/undoable. Do not fake saves with
`set-buffer-modified-p nil`, shell writes or routine `revert-buffer`.
Undo follows normal Emacs limits and is not persisted across restart.

### Text payloads

Avoid embedding large/quoted text in Lisp string literals by passing optional
`texts`, a JSON array of strings:

```json
{
  "expression": "(emacs-agent-replace-region \"test.ml\" 1 4 (nth 0 emacs-agent-texts) (nth 1 emacs-agent-texts) :tick 210)",
  "texts": ["old", "let () = print_endline \"Привет\"\n"]
}
```

Adapt buffer/range/tick to a fresh read. Text is escaped for JSON only; no extra
unescaping, joining or evaluation occurs. `emacs-agent-texts` is a fresh list
bound during that invocation, usable across buffers and with native Lisp.
Omitted `texts` or `[]` means empty; null/non-string arrays are rejected before
execution. Runtime strings are copies; nested calls restore outer bindings.
Direct `emacs-agent-eval` callers may supply a vector or proper list as the
optional second argument. Payloads are ordinary retained tool arguments, visible
in the journal and included in context budgets, not a secret channel or sandbox.

### Lisp structure

```elisp
(emacs-agent-check-sexps "example.el")
(emacs-agent-inspect-sexps "example.el" :depth 2 :limit 32)
(emacs-agent-replace-sexp "example.el" START END OLD NEW :tick TICK)
```

No paredit dependency is needed. Check reads without evaluation and returns
`:ok`, `:forms-read` and the first `:diagnostic` with absolute character position,
1-based line, 0-based display column and bounded literal context. EOF locations
are hints, not certain fixes. Source symbols are read into an isolated symbol
table; hash-table records are read generically without user-defined hash tests
or native constructor-specific validation.

Inspect returns a JSON string with source ranges, kind, completeness, preview,
expandability and requested children. It retains readable children of incomplete
forms. Lists, vectors and quote prefixes expand; other constructs are opaque.
`:depth` is 0..8 (default 1); `:limit` is 1..1000 total nodes (default 64).
Truncation is explicit; `next-position` resumes omitted top-level forms only.
Explore nested ranges explicitly. Oversized JSON errors rather than returning
invalid partial JSON; request fewer nodes/lower depth.

Both readers accept `:start`, `:end`, `:tick`, `:widen`, defaulting to accessible
text. A narrowed/ranged check validates a standalone fragment, not the whole file.
Replace requires exact OLD, a fresh integer TICK and one whole inspected form.
NEW is exactly one form without surrounding whitespace/comments, or empty to
delete; surrounding accessible text must remain valid. For broken buffers,
`:repair t` allows any nonempty OLD range and arbitrary NEW, but all accessible
text must read successfully afterward. Include an adjacent anchor when inserting
a missing delimiter. Source-copy preflight and atomic post-hook validation
reject invalid edits. No automatic save; reader validity is not correctness.

### Checking code and running processes

Use **edit → explicitly save when intended → check → reread changed ranges after
the last check**. Distinguish edited, saved and checked. Disk commands cannot
validate unsaved text; do not silently save/discard user changes to run them.
Editor diagnostics may check unsaved text, but verify the active backend and
freshness rather than merely finding loaded features/commands.

```elisp
(emacs-agent-run-process "make" ["test"] :directory "/path/to/project/")
```

This synchronous helper uses literal argv (list or vector), no implicit shell,
and combined stdout/stderr. The result contains `:output`, expanded `:directory`,
actual `:command`, and `:exit` (integer or signal string). Require **integer 0**
before claiming success, not empty output. Bare names use PATH; executable paths
with directory components resolve relative to cwd. Remote program names must
use the same host. It does not save, edit, retry, clean generated files or
interpret success. Launch errors/quit propagate. Long synchronous checks block
Emacs; use local async jobs instead:

```elisp
(emacs-agent-job-start "make" ["test"] :directory "/path/to/project/") ; → ID
;; Substitute the returned string for ID in later calls:
(emacs-agent-job-status ID)
(emacs-agent-job-read ID :from 0 :limit 4096)
(emacs-agent-job-list :from 0 :limit 20)
(emacs-agent-job-cancel ID)
(emacs-agent-job-forget ID) ; terminal jobs only
```

Async jobs are local only (no TRAMP/implicit shell), with shared UTF-8 stdout/
stderr in a private buffer. Status is `running`, `exited`, `signaled` or `failed`;
integer `:exit` exists only for ordinary exit, `:signal` for signal termination.
Read resumes with zero-based character `:next-offset`. `:truncated nil` means
only the end available **now**; `:complete t` also requires a terminal job.
Reads neither wait nor consume output. List is paginated, newest first.

There is no automatic polling, model continuation, save, retry, restart recovery
or link to run cancellation. Jobs are shared across Emacs, not access-isolated.
Full output stays **in memory until forget/restart**; read bounds do not bound
memory. Cancellation does not guarantee stopping descendants or rollback.
Forget removes a terminal job's record/output, not files created by it.

### Evaluation diagnostics and full output

Forms execute sequentially with no rollback, save or repeat. Read errors do not
undo prior forms; evaluation errors may follow mutations within the same form.
Errors/quits include phase, form number, completed-form count and locations
(1-based character positions/lines, 0-based **character** columns). Reader
failures include bounded escaped context and possible syntax hints. Execution
errors may include up to eight function names/signatures, not argument/closure
dumps. Debugger capture is local, noninteractive and best effort.

A compact footer reports net changes in the actual source buffer, including
rename/kill/modified state; it does not check other buffers or external effects.
It preserves point, narrowing and undo but does not repair or certify saved data.

If output exceeds `emacs-agent-eval-output-limit`, full text is saved as UTF-8 in
a unique 0600 file under `emacs-agent-data-directory/tool-output/`. The model
receives a **tail** plus a quoted absolute-path notice. The notice counts toward
the limit; if it alone exceeds it, the notice is returned intact. Exact-limit
results create no file. Small budgets can truncate even diagnostics/final values.
Write failure returns an unavailable warning, never repeats evaluation or points
to a partial file. Inspect artifacts as data with `insert-file-contents`, never
load them as code. Files have no automatic deletion/quota; delete manually.
Moving/deleting them invalidates old references. Collection is still in memory:
this is neither a memory nor execution limit.

### Registering user helpers

Load an ordinary function, then advertise a compact description:

```elisp
(require 'my-diagnostics) ; load your implementation separately
(emacs-agent-register-helper
 'my-diagnostics
 :description "Read current buffer diagnostics."
 :returns "List of (:line :column :severity :message)."
 :constraints "Requires an active checker; does not save or modify buffers."
 :example "(my-diagnostics \"main.ml\")")
;; Stop advertising it to future inputs:
(emacs-agent-unregister-helper 'my-diagnostics)
```

`:description` and `:returns` are required nonempty strings. Omit optional
`:constraints`/`:example` instead of passing nil. Signature/name are automatic;
full docstrings are not sent. Keep purpose/result shape concise; mention effects,
preconditions, errors, coordinate units and continuation rules as appropriate.
Examples are literal text, not executed. Prose whitespace is collapsed; example
text is preserved. See `C-h f emacs-agent-register-helper` for the full contract.

The global runtime registry contributes a name-sorted block after project
instructions, even without a project or with file instructions opted out.
Re-register after redefining a function. Autoloads, undefined functions, macros
and special forms are rejected; registration never loads code. Unsupported
signatures require a Lisp wrapper. New inputs freeze descriptions; queued turns,
continuations, recovery and instructions views use saved text, not the registry.
Descriptions count toward pending/context budgets. Snapshots restore neither
function code nor registry entries. Unregistering is **not access revocation**:
older runs retain descriptions and eval remains unrestricted.

## Hooks

These abnormal hooks observe sessions; use `add-hook`/`remove-hook`:

| Hook | Callback arguments | When |
| --- | --- | --- |
| `emacs-agent-session-event-functions` | `SESSION EVENT` | After a structured event is appended |
| `emacs-agent-session-state-functions` | `SESSION` | After a runtime-only state transition; no durable event implied |

EVENT is a plist with `:id`, `:time`, `:session-id`, `:run-id`, `:type` and
`:payload`. Payload shape depends on event type. Callbacks run synchronously;
keep them fast and observational, without mutating history or issuing recursive
agent commands. Errors/quits are reported without stopping other observers or
stranding the run. Built-in observers handle rendering, pending views, status
and autosave; do not replace the hook lists wholesale.

```elisp
(defun my-emacs-agent-observe (session event)
  (when (eq (plist-get event :type) 'error)
    (message "Agent error in %s: %S"
             (emacs-agent-session-id session) (plist-get event :payload))))
(add-hook 'emacs-agent-session-event-functions #'my-emacs-agent-observe)
;; (remove-hook 'emacs-agent-session-event-functions #'my-emacs-agent-observe)
```

Views also have normal derived-mode hooks: `emacs-agent-log-mode-hook`,
`emacs-agent-session-list-mode-hook` and `emacs-agent-pending-mode-hook`.
`emacs-agent-status-mode-hook` observes toggling the global status mode.

## Persistence and recovery

Snapshots live in `emacs-agent-data-directory`, not the project. Schema 3 uses
`conversations/<64-hex-conversation-ID-suffix>.eld`; project selection pointers
use `selections/<hash-of-root>.eld`. There is no persisted global selection.
Files are read as Lisp **data**, never loaded/evaluated. Writes use a same-directory
temporary file and atomic rename; new directories are 0700 and files 0600.

Autosave checkpoints meaningful events, tool boundaries and completion/cancel;
streaming checkpoints occur at most every five seconds. Explicit save includes
received partial text without changing the live run. Save failures warn but do
not retry or terminate the loop. I/O is synchronous. Streaming fragments are
compacted in snapshot copies; model messages remain separate from journal events.
Saving still traverses full history and is not a constant-time operation.

After restart active/paused and queued work becomes interrupted. **Nothing is
automatically resumed or reexecuted.** Results and partial text stay available;
pending inputs require deliberate recovery. Side effects may exist even when a
result was not checkpointed: inspect current editor/files/processes first.
Only source buffer name/file identities reconnect to matching already-open
buffers. No file is automatically opened; windows, processes, markers, closures,
credentials and HTTP handles are not restored.

Catalog refresh never overwrites in-memory conversations. Corrupt/unsupported
files do not block unrelated catalog entries, but direct restoration of a bad
selected target fails explicitly rather than substituting an empty conversation.
Schema 1/2 and old root-level `global.eld`/`project-*.eld` files are not imported,
rewritten or shown in the current catalog. There is no migration/reset UI: use a
separate data directory or manually archive incompatible files. Restart after
updates that change session/run structures rather than hot-loading them into
live sessions.

Snapshots and output files are private but **unencrypted**, can contain secrets,
and have no automatic quota/deletion. Keep the directory out of dotfiles/version
control. Concurrent writers from multiple Emacs processes are unsupported (last
rename wins). Transport-buffer reclamation is not automatic.

## Supported backends and limitations

Supported: trusted OpenAI **Chat Completions** with plain text, `eval_elisp`
function calls and optional textual `reasoning`/`reasoning_content` on assistant
tool messages. Original tool IDs and known textual reasoning are retained for
replay. Final-answer reasoning without tools remains journal-only.

Responses API, Anthropic, Gemini and other backend types fail before sending:
opaque reasoning/signature formats cannot be safely replayed by this adapter.
Observed unknown protocol fields/callback shapes fail explicitly before tool
execution and mark history non-replayable. Future turns remain blocked, including
after restart; archive that snapshot/use a fresh conversation or data directory.
Upstream gptel can discard unknown streaming fields before exposure, so this is
not a universal detector for proprietary extensions. Endpoints requiring hidden
or opaque fields are unsupported.

The editor is shared live state: you can edit, undo or save between calls.
History describes past actions, not proof of current buffer/disk contents.
Reinspect before continuing and preserve user changes. Audit is best effort,
not an exactly-once execution ledger.

## Security

Only connect to a trusted endpoint. `eval_elisp` can read secrets, execute shell
commands, change editor configuration and delete files **without confirmation**.
Instruction files, context, prompts and tool output are sent to the configured
model. Project scoping, registered helpers and payload bindings are not security
boundaries. Lisp executes synchronously and can block Emacs. Cancellation ignores
late callbacks but does not roll back changes or guarantee termination of Lisp
or subprocesses. Protect saved history and full-output files accordingly.
