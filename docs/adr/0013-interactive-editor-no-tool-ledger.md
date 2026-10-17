# ADR-0013: Interactive editor, no mandatory tool execution ledger

Status: F7 excluded from the mandatory plan by user decision.

The assistant shares a live editor with the user. Buffers/files may change
between calls: the user can edit, undo/redo, save or revert changes independently
of the assistant. A recorded successful tool outcome describes a past execution,
not the current editor or disk state. Such a ledger would not establish current
correctness; this decision does not claim it has no possible audit value.

Do not implement F7 prepared-intent/completed-outcome storage, mandatory durable
checkpoints before eval dispatch, or automatic reconstruction of missing model
results. Existing best-effort session audit, native undo, explicit save semantics,
stale-tick/OLD guards and fresh state verification remain. No exactly-once or
rollback promise is introduced.

Restart does not resume interrupted work or automatically repeat unknown effects.
For continuation, inspect current buffers/files, respect user changes and report
uncertainty; do not infer present state solely from history or a summary. Explicit
user requests can of course ask for a new action, including repeating an operation.

F7 remains as an excluded historical entry, without renumbering F8. Reconsider
only if an actual interactive workflow demonstrates the need for stronger audit.
The existing shared-live-Emacs prompt and editing contracts already express this
model; no new tools, persistence schema or runtime behavior are added here.

Verification: documentation-only change; `git diff --check`. No provider calls,
user-Emacs changes or test execution required. Commit only on user request.
