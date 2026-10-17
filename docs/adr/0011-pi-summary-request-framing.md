# ADR-0011: Pi-style summary request framing

Status: implemented; offline checks and one isolated live probe completed.

## Decision

A weak local model returned a textual tool invocation instead of useful
continuity notes. The user approved copying **TypeScript Pi's request framing**,
not adding format validators, retry loops or another tool/model interface.
Reference: `pi/packages/coding-agent/src/core/compaction/utils.ts` (system prompt)
and `compaction.ts` (initial and update checkpoint instructions) in the local Pi
repository inspected during the discussion.

This supersedes only the summary-request wording/framing in ADR-0010. The
original pigo-style gate, reserve/retention settings, estimator, safe boundaries,
atomic persistence, cancellation/FIFO, tool rejection and output acceptance
remain unchanged.

## Request shape

- Dedicated system role: summarize in the specified structured format; do not
  continue the conversation or answer questions inside it.
- One user message: `<conversation>…</conversation>`, then (for updates)
  `<previous-summary>…</previous-summary>`, then the instruction and exact
  Markdown checkpoint format. Optional `Additional focus` follows the template,
  instead of being concatenated to the system message.
- Six sections: Goal, Constraints & Preferences, Progress (Done/In Progress/
  Blocked), Key Decisions, Next Steps, Critical Context. Preserve exact paths,
  function names and errors. Update instructions preserve prior facts and
  incorporate new progress, decisions and next steps.
- The preceding summary appears once, outside the new-message transcript.
  Summary-only omission in the internal projection keeps the saved cut and
  explicit delivered current-run snapshots. Original records/projection are
  never modified while preparing the request; normal task replay is unchanged.

Existing limits remain: 2000 UTF-8 bytes per block (including the separately
framed previous summary), bounded transcript first-quarter/newest-tail layout,
4096-byte focus, actual summary-request budget check. Framing/templates consume
additional request space and are included in that final estimate. This is not
Pi's entire compaction implementation: no split-turn extra request, new output
cap, retry policy, response-section validator or changed clipping policy.

The XML-like tags are formatting cues, not an unforgeable trust boundary.
Requested headings do not enforce factual completeness. Existing complete +
nonblank checks still accept arbitrary text; structured tool dispatch remains
blocked. Already persisted summaries are not rewritten or repaired retroactively.

## Verification

227 ERT cover the existing lifecycle and new initial/update framing, instruction
placement after data, all checkpoint headings, bounded Unicode previous/focus,
previous-summary nonduplication, and preservation of current snapshots/protocol
pairs when omitting prior summary from the transcript. Compilation uses
warnings-as-errors; full-suite, compilation and diff checks pass.

A separate tool-free live probe completed against the configured
`aiserver/main`, using the same original 58-record prefix as the observed bad
summary. Its transcript is 66948 UTF-8 bytes; the new framed user message is
67860 bytes. Recorded expressions remain inert data. The result is written
privately outside the repository and is not applied to any user session.
The provider returned stop `stop`, all requested checkpoint sections, and useful
goal/progress/next-step notes rather than the former one-line tool invocation.
Normalized counters: input 21106, output 1152, cache 0. This is one new-format
probe versus a historical observation, not a controlled A/B trial or proof
about the physical model behind `main`, billing, or token efficiency.

Factual quality is still imperfect: the summary repeats an incorrect historical
explanation that `#` inside Elisp strings caused reader problems. Structure is
not proof of truth. No output validators, retries or automatic correction were
added. The live result was not published to any user session or checkpoint.
Private probe scripts, prompt and response are outside the repository, in a
0700 temporary directory with 0600 files; no private source/log contents are
added to this ADR.

The three updated compiled modules were loaded into an idle F4 Emacs after the
final checks. No session/run/job layout changed, so this framing-only update
needs no restart and does not rewrite existing histories or summaries.
