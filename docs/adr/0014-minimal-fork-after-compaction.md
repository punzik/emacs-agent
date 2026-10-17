# ADR-0014: Minimal conversation fork and compaction boundary

Status: accepted scope; implementation pending.

F8 starts with a fork into a separate F6 conversation at a selected completed
history boundary. The source remains unchanged. Do not introduce a session tree,
selected-head machinery, bookmarks or an alternative-summary request for this
slice. No tools are replayed and no buffers, files or processes are rolled back.

The user specified that compaction counts as the first event in the conversation.
For fork selection, interpret this as the first logical event of the effective
history: the latest compaction summary followed by the retained raw suffix.
The earliest available fork boundary is immediately after that summary, even
when no suffix is included. Later boundaries must be completed and must not
split tool call/result pairs. Without compaction, select completed boundaries
from the raw history.

A fork after compaction inherits that summary and only the suffix up to the
chosen boundary. It must not inherit later events. The summarized raw prefix
is not offered as individual fork points: the summary can describe events after
such a point, so inheriting it there would introduce future information.
Original archived records remain intact; treating summary as the first logical
event does not rewrite the source archive or change existing journal rendering.

This records the approved feature scope and compaction rule, not a completed
implementation or a decision on the command/UI details. Those details must be
checked against F6 clone and F4 projection before implementation.
