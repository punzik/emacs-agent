# ADR-0014: Minimal conversation fork and compaction boundary

Status: implemented; offline tests and warnings-as-errors compilation pass.

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

## Implementation

`M-x emacs-agent-session-fork` offers successfully completed whole model turns
plus the summary boundary, defaults to the newest, and accepts `C-u` for a name.
Delivered steering belongs to its run. Failed/cancelled/paused turns and
individual tool pairs are not endpoints. Prefixes may still contain earlier
failed historical turns. Recheck registration, involved idle sessions and
selection; changes to message/event tails or compaction during the minibuffer
require choosing again. No point-sensitive UI or extra keybinding is introduced.

The private clone transaction accepts an optional canonical end. Keep a deep
copy of raw records `[0,end)` including the summarized prefix, with the original
absolute compaction cut: F4 validates this archive and can retain current-run
snapshots across that cut. Do not synthesize a canonical summary role. The
model projection stays summary + retained suffix, with protocol pairs/reasoning
and historical IDs unchanged. Source/queue/runtime authority and usage anchors
are not inherited. Persistence/publication ordering remains F6's.

For a completed endpoint, copy audit events only through the matching completion
and only for runs in the inherited canonical prefix. In particular, a future
queued input may have audit events before this completion and must be excluded.
For a summary-only fork, copy no raw audit events: an arbitrary within-run cut
must not pull in later events from that same run. Compacted forks prepend one
inert `inherited-summary` entry; no model request or event hooks are invoked.
The original journal is unchanged. New fork journals remain archive views, not
sources for API history reconstruction.

Schema 3 gains an optional `:boundary` in source-ID/time provenance, recording
`:kind`, absolute `:end` and completed run/event IDs when applicable. Validate
it locally without loading the source or introducing ancestry machinery. The
historical end can be less than the current archive length after continuation;
a summary boundary is not tied to a later compaction cut. F6 clone provenance
without a boundary remains valid. No session/run slots or migration are added.

## Verification

275 ERT and warnings-as-errors compilation pass, including actual pinned-gptel
wire comparisons across context policies, tool IDs/reasoning, mid-run summary
cuts, summary-only continuation and fork-of-fork, future queued-audit exclusion,
late/duplicate completion rejection, failed writes/pointers, idle and stale
minibuffer guards, inert deep copying, malformed provenance, subsequent growth/
compaction and backend-free fresh-process restore/fork. Provider/live UI smoke
has not been run. No user-Emacs hot-load or runtime changes were performed.

Independent read-only review found no verified supported-path issues. A focused
offline probe also passed completed fork → growth → actual F4 recompaction →
summary fork → growth → fork → save/restore, using mocked summary delivery rather
than a provider call. The reviewer did not rerun the full suite.
