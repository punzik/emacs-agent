# ADR-0015: Conversation view and live activity status

Status: implemented; offline verification passed, live UI smoke pending.

The audit-oriented journal is too noisy for ordinary conversation. Preserve
complete structured events and canonical API history, but change their disposable
view. Local Pi/Pigo sources informed the separation of readable conversation,
folded tool/reasoning details and operational status; do not copy a terminal UI
framework or introduce tool-specific execution semantics.

Normal view shows user/assistant text, folded supplied reasoning, paired
`eval_elisp` calls/results with bounded previews, compaction and actionable
failure/pause/recovery notices. Routine audit metadata, IDs, per-response usage
and lifecycle chatter belong in a buffer-local diagnostic view (`D`). Diagnostic
rebuild is explicit, not a per-chunk operation; preserve fold choices and reader
position as far as the changed projection allows. No Markdown rendering yet.

TAB and physical `<tab>` must work on text-button headers and bodies, as must
RET/click. Override the button-local `forward-button` binding instead of only
changing the major-mode map. Collapsing a body leaves point on its header.
Arrows reflect local fold state; folding never modifies source history. Reasoning
is initially folded, not invented or conflated with the busy indicator.

Tool previews do not claim success from arbitrary output text. Keep F3 capture
truncation/unavailable notices visible; expanding a view cannot recover content
not retained in the result. Never read artifacts or execute displayed expressions
to render a view. Streaming remains incremental and preserves reader windows;
callbacks cannot steal focus or recreate closed journals.

A default-enabled, disableable `emacs-agent-status-mode` adds one cached component
to `global-mode-string`, without replacing `mode-line-format`. It aggregates
registered live conversations, distinguishes waiting/responding/eval/compacting/
paused, shows only positive ordinary FIFO counts and hides when idle. No timer,
animation, billing estimates or per-token global redraw. Text/usage deltas do not
scan archived conversations. Custom mode lines must display `global-mode-string`
to show this component.

Native events drive status updates. Runtime-only transitions without an audit
event notify an error-isolated session-state hook, including last-tool completion,
response-end and active-run release. These notifications are not persisted and
must not strand a run if UI code fails. Observe ownership/liveness around hooks;
no new queue, tools, credentials, model projection, session slots or schema.

## Implementation and verification

Normal tool sections are keyed by run/call identity. Result arrival updates only
that block, preserves the expression and reader markers, and does not refold an
expanded tool. Unmatched results remain visible. Explicit details rebuild uses
first-event anchors and local fold choices; details also respect the user's
reasoning-display policy. Unknown service events are inspectable in details,
not rendered as surprise raw metadata in conversation view. Instruction warnings
and recovery user text remain visible without their input IDs. Current compaction
progress belongs in the mode line, not a permanently "compacting" transcript row.

The mode-line module does not require the provider or private summary FSM on
package load. Runtime notifications before WAIT transport are outside the
steering claim/publication window and recheck liveness after hooks. Observer
errors are isolated. Body/usage deltas do not scan the conversation registry;
unchanged state does not request global redisplay. Short journal names use
Emacs's duplicate-name suffixes; selector IDs are unchanged.

306 ERT plus warnings-as-errors compilation and diff-check pass. Coverage includes
real keyboard bindings and cursor movement, RET/button activation, preview/body
fold points, folded streaming, diagnostic rebuild/window anchors, paired/orphan
calls, reader position on result arrival, capture notices, resource warnings,
live/store rendering equivalence and unchanged canonical history. Status tests
cover lifecycle, compaction, aggregation, enable/disable and other mode-line
components, text-delta scan suppression, native tool completion, observer errors
and cancellation before WAIT launch. Fresh offline-process restore tests still
pass without loading gptel. No provider or live user-Emacs UI smoke/hot-load.

Independent read-only review found a reader-anchor failure from blank separator
lines when toggling details. Separators now carry their block's event identity;
a regression covers point/window-start through two toggles. The missing-anchor
fallback no longer walks to the last block. No other verified findings were
reported; the reviewer ran focused probes, not the full suite.

## User-approved visual refinements

Reasoning header and entire body (including appended streaming text and details)
use `emacs-agent-log-reasoning-face`, inheriting `shadow` rather than a fixed gray
or a theme's potentially green comment face. It does not leak into assistant text.

Status defaults are `" AI:wait "`, `" AI:reply "`, `" AI:eval "`,
`" AI:compact "` and `" AI:pause "`. A single prefix is shared across aggregate
labels; repeated states use `×N` and the ordinary queue uses `q:N`. Always pad
active output with one outer space per side, but idle emits nil, not whitespace.
`emacs-agent-status-prefix` and `emacs-agent-status-labels` configure prefix and
all state/queue strings. Customize's setters refresh an enabled cache immediately;
`setq` callers explicitly refresh (or await the next native state transition).
No timers/watchers or per-token formatting are added. Empty prefix suppresses
the colon; missing labels fall back to native state names. Three added regressions
cover reasoning face ranges/streaming/details and customizable padded aggregation,
Unicode/percent labels, fallback and immediate setter refresh.
