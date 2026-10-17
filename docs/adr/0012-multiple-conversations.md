# ADR-0012: Multiple conversations per scope, without migration

Status: implemented and verified offline; no-migration choice confirmed by user.

## Decision

User deferred F5 in favor of F6 and explicitly chose **no migration**. Existing
root-level `global.eld` and `project-*.eld` remain untouched archives, not loaded,
listed or continued by F6. Pre-existing Pi summary framing/ADR-0011 changes are
independent working-tree changes and must be preserved.

Conversation ID identifies a registered object. Immutable scope remains `global`
or the canonical project root. Registry is ID→object; a separate scope→ID map
holds selection. Callback/input/compaction ownership checks registration and
object identity, never whether the conversation is currently selected. Opening
a journal does not change selection; commands in a nonselected journal explicitly
target its owner. Working buffers target the selected conversation for their scope.

New schema-3 snapshots live in `conversations/` under the private data directory,
with filenames derived from conversation IDs, not names/roots. Project selection
pointers live separately under `selections/`; normal autosaves do not change them.
Initial project selection is durable, including an empty conversation identity;
autosave-off still prevents automatic persistence of subsequent chat history.
Global selection is process-local: first implicit global use creates one new
empty conversation, reused for this process. Catalog inspection does not select
an old global conversation or create duplicate globals. Explicit old-global
selection lasts only until restart. Project selection survives restart. No
branching/reset/merge/import machinery or cross-project reassignment is added.

New/select/clone require the selected/source/target conversations involved to be
idle: no active/paused run, ordinary queue, prepared/queued input or summary job.
Withdrawn recovery stays with its original conversation. Rename requires its
own target idle. A short mutation lock rejects reentrant new admissions/selections/recovery
while persistence is in progress. Already accepted F2 final-boundary work in
other conversations remains runnable; it is not a new user admission. No operation cancels work or transfers queues.

Persist the old selection, the candidate, and project pointer (if applicable)
before publishing a new selection. Failure leaves the old in-memory selection,
history and queue unchanged; a successfully written but unselected candidate may
remain available after pointer-write failure. Rename similarly saves a preview
before modifying live metadata. No file rollback deletes a valid conversation.
All files are data read with Emacs `read`, not loaded/evaluated; files 0600,
new directories 0700, atomic temporary-file/rename writes, no backend credentials.

Clone uses a fresh ID and explicit source-ID/time provenance. Deep-copy canonical
messages, archive events and compaction; rewrite event session IDs to the clone.
Historical run/input/tool IDs stay historical, never execute. Clear usage anchor,
active/queued/pending recovery, source/editor/transport handles and summary job.
Copied usage/events are historical audit, not new spending or executed actions.
No authority is obtained from old event payloads. A working-buffer UI invocation
may bind that explicit current buffer after selection; cloning from an archive
does not inherit its former source. Artifact paths remain references
to the original F3 files; cloning neither reads nor duplicates those files.

Interactive commands use `emacs-agent-session-new/rename/select/search/clone`,
consistent with `emacs-agent-session-list`. Internal operations are
`emacs-agent-session--new/rename/select/clone`, avoiding name collisions.
The user approved this naming change without aliases for the former short names.

Names are metadata, not filenames or identity; duplicate names are distinguished
by IDs. Listing/searching/showing are local read-only operations, usable during
execution without a model/backend/network. Search does not build an index.

## Verification

Baseline current working tree (including pre-existing ADR-0011 work): 227 ERT.
Final `nix-shell -p gnumake --run 'make clean test compile'`: 252/252 ERT,
warnings-as-errors compilation; `git diff --check` passes.

Core/store regressions cover multiple same-scope conversations, all snapshot/
pointer failure stages, orphan candidates, immutable scope, withdrawn recovery,
metadata validation-before-registration, collision checks, private permissions,
legacy files untouched/excluded and normal autosave not overwriting pointers.
UI/integration regressions cover public new/name/select/clone/search, simultaneous
selected/nonselected ownership with a real pinned tool dispatch, minibuffer
selection changes and no implicit retargeting, actual cloned wire/reasoning/tool
IDs across context policies, and recovery untouched under the mutation lock.
Another conversation's already accepted F2 conversion runs inside a rename save.

Two fresh backend-free `emacs -Q` processes prove new global IDs, old-global
explicit continuation, preserved project selection and no duplicate on reload
of the same F6 definitions. Existing streaming/save/recovery/wire tests were
adapted to explicit ID restore instead of automatic old-global restore.
An independent read-only F6 review reported no concrete supported findings;
it did not run the final full suite. All fixtures are disposable synthetic data.

No provider calls or user-Emacs struct hot-load were performed. Restart is
required after the structural/registry change. Existing user journals and legacy
snapshots were not used as test input. Commit only on explicit user request.
