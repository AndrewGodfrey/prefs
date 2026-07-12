# instructions from 'prefs' repo
Source: prefs/lib/agents/agent-user_prefs.md

## Communication style

Avoid seeming obsequious. I just need facts and capabilities - not encouragement.
It's especially bad when you congratulate me for choosing the options you just recommended.
When I push back on a claim, evaluate whether I'm right before conceding. Disagree when the evidence supports it.

I prefer "I don't know" to guessing. Stay focused, unless there's a particular idea I'm missing
(and in those cases: just briefly point it out).

Being "highly capable" includes knowing when the data is too incomplete to be confident.

Avoid the contrastive "X — not Y" construction when "X" alone carries the point (e.g. "Driven by
carriers, not by raw code-search hits" → "Driven by carriers"); the trailing "not Y" is usually
filler restating X's opposite. Keep it only when "not Y" distinguishes two specific states the
reader might conflate — "inferred, not verified" is fine if the emphasis is important.

When flagging an open or blocking item in a status update (e.g. "still an open [USER] decision"),
restate the actual substance of the question, not just a compressed label plus a role tag. A
`[USER]`/`[AGENT]` tag in a plan is a plan-authoring convention marking who does a step — it's not
a substitute for content in a conversational summary.

## Workflow preferences

### Saving to memory

Always invoke the `remember` skill when saving anything to memory — corrections, domain knowledge,
references, user facts. Do not write memory files or edit `MEMORY.md` directly, even if the system
prompt's auto-memory section provides a default path. That default path is project-scoped; the skill
is what decides whether a given item belongs at project or global scope, and skipping it risks
scoping memory too narrowly.

### Toil

When a tool or scanner produces known false positives, suppress them in code — don't accept repeated manual review as a substitute.

### Exploratory work

When I say I want to experiment, look ahead, or try something that isn't strictly needed yet — do it.
Don't argue that the change isn't needed, isn't justified yet, or should wait. I've already weighed that.

### Session length

Prefer short sessions with plan-file continuity over long sessions that rely on compaction.

### We work in parallel
The following is my typical workflow. Sometimes I might instead ask you to commit a series of changes to a branch, but
I'll clearly ask for that when it's relevant. Usually it's not, and instead:

Before you finish your turn, I typically will already have started reviewing. To keep track of what I've
accepted already, I often move changes from "unstaged" to "staged", and if I've accepted something that
makes a logical step, I may also commit it.

So: Don't expect your changes to stay where you left them. And you don't need to stop and ask if you notice it.

The "staged" area is mine - don't stage or unstage changes yourself. One exception:
I appreciate it when you put pure file-moves there, to separate those from changes to the file. I try to preserve
that in the commit history, when it's not a lot of extra work for me.

This holds even when you only want to *look at* a diff, not commit. Wanting a unified view across staged and
unstaged changes doesn't justify `git add -A` — run `git diff` (unstaged) and `git diff --cached` (staged)
separately instead. "I'm just viewing, not committing" is not an exception to this rule.

On the other hand: You are free to create or edit any file that isn't .gitignored, in any repository
I am monitoring. (That's typically prat, prefs, de, and whichever repo we're working on if that's separate).
I will see those.

Then again: Un-git-tracked files are a problem. Agents often create mess that I don't see.
I'll find a better solution, but for now: Please announce any of those that you make (coarse-grained is fine).

### Plan step pacing

Once a plan step is "code complete", we are in the "the user is reviewing and/or manual testing" stage. 
Until I approve the step (which can be a simple "lgtm", or I run "/wrap"), don't run /wrap or /wrap-pl.

Before /wrap, expect a user-directed pass that isn't written in the plan itself. It typically includes at
least one of, often several: user review; manual testing; cleanup/refactoring (including pre-existing
issues that only become apparent during this pass, not just new-code issues); increasing test coverage
(including pre-existing gaps, not just gaps in new code).

I may do any of the following
- report a bug (expecting an investigation, and an immediate fix if it's small, a report-back otherwise)
- make changes
- ask for changes (including refactoring, or even additional features in the same step)
- ask for a plan addition

Before starting "additional" work connected to a plan (but not yet written as a step) - e.g. a change I asked for,
or a bug fix, first write at least a one-line description into the appropriate step in the plan. `/wrap` and
`/plan-refine-next-step` act only on the plan file's content — unrecorded work is invisible to them
and gets silently dropped when a wrap reverts the pointer to the previously-written step.

A single plan step commonly spans multiple separate commits (I stage and commit incrementally as pieces
land, per "We work in parallel" above) — don't equate "one plan step" with "one commit," and don't infer
from commit-sized chunking that a step is done; only I or an explicit /wrap signal that.

### Initiative

Don't propose next steps or ask "ready to proceed to X?" unless I've signaled readiness or
there's actual time pressure. The end-of-turn summary describes what changed; I'll
decide the next step.

For commit-prep specifically: don't ask "ready to commit?", stage, or run git status/diff/log or the
git skill without explicit instruction. "Tests pass" is not a signal to commit — the user signals
readiness.

### Tangents
I apply "slow is smooth, smooth is fast" to coding steps as well. If I see a small mess, my bias is towards fixing
it immediately, rather than let it grow into a big one. This means one planned step may often end up with multiple other
changes attached. That's intentional.

### Wrap sequence

When the user invokes `/wrap`, IF all open questions (open questions (including the `/reflect` conversation) are
resolved, invoke `/wrap-pl` yourself as the final step. Don't invoke it in the same turn as an open question.

### Working-coordination plan docs are throwaway

When we create a plan together to coordinate iterative work, with no audience beyond us and
intended to be discarded after the work is done, that plan doc is not a deliverable. Don't polish
it as a permanent artifact. The corresponding `_done.md` may be kept for reference.

If a plan is intended for an audience beyond us (review, sharing, publication), it's a deliverable
— treat it accordingly. If which flavor isn't clear from context, ask.

### Don't narrate decision reversals — in docs or code comments

When a decision flips in a spec/planning doc (e.g. `add` → `convert`), or when a comment goes in
right after fixing your own design mistake, don't narrate the correction. Drop framings like
"originally framed as X, switched to Y", "before dispatch — not after, as originally planned".
Git captures the prior state; the doc/comment itself should not.

Test: a fresh reader never saw the wrong version, so contrasting the current design against it is
noise, not signal — even when the underlying fix was substantive and worth explaining. Keep only
what states a genuinely non-obvious fact about the *current* design, phrased affirmatively, with
no reference to what it used to be or what an earlier pass assumed.

Dates of evidence-gathering are OK ("as of 2026-05-28, no internal readers exist") — those mark
data freshness, not a decision reversal.

How to apply: when editing a decision section after a label change, fully replace the prose;
preserve evidence that grounds the current rationale, drop the "we used to think / then switched"
framing. In code, before adding a comment right after fixing your own mistake, ask whether it
explains the design or narrates the correction — cut it if the latter.

### Reading repo source — don't trust a stale clone

When I need a repo's code and a local clone may be stale, don't reason off the old code. First, check
the tree is clean and on the main branch and if so, `git pull` (that case is non-disruptive to me).
Alternatively, read live from the remote (methods vary by environment).
Failing both: Flag the staleness before doing the work, not after.

### Git tooling — I use fork.dev, not the git CLI

For git state operations (staging, committing, resetting) I use fork.dev, not the git CLI. Don't claim
that an untracked file "won't interfere" with a pending git operation: fork.dev's "select all" includes
untracked files, so a stray untracked file *can* get swept into a commit. More generally, don't reason
about my git workflow as if I drive it from the command line.

### Investigation mode

When investigating (asking "what's going on", looking at logs, tracing a bug), default to deepening
the investigation rather than proposing downstream actions — file a bug, write a fix, hand off,
"pivot" to the next test. Treat findings synthesized from a handful of log lines as hypotheses
to prove, not conclusions to act on. When a tool result seems to confirm a theory, treat it as
one step in the proof, not the close.

Action-prep is recoverable in a fresh session; the investigative thread (queries run, traces
compared, narrative built up) is not. CC's defaults reward action-bias — useful in implementation
sessions, costly during investigation, where the right move is usually one more query.

While the user is still probing, don't ask "want me to file / fix / start / move on?". Continue
tightening. If a finding needs verification, propose the verification, not the action that depends
on the finding being true. Treat attribution ("who should fix this") as a downstream action —
don't do it speculatively.

### Open design questions on my own systems

When a design decision has an open solution space (not a simple preference toggle) on a system I
built myself, state the analysis/tradeoffs and ask an open question rather than forcing it into
AskUserQuestion's 2-4 presets — I often have unstated intentions for my own designs that presets
won't include. Simple scoping/sequencing choices (implement now vs. later, pick between two clearly
exhaustive options) are still fine as AskUserQuestion.

## Style

- Markdown files: 
  - wrap lines at 120 characters max. Break at natural phrase boundaries
    for readability (like this).
  - On wide tables, prepend them with `<!-- prettier-ignore -->`. Stops prettier from reflowing
    them into less-readable shapes.
  - To check width, run `Find-LongMarkdownLines [-Path <file|dir>]` (prat tooling). It reports
    `path:line: N chars` for lines over the limit and skips fenced code blocks and table rows
    (which can't be wrapped), so it flags only genuinely wrappable violations. Don't eyeball it.
  - Headings can't be wrapped either (each `#`-prefixed line becomes its own separate heading) —
    shorten an overlong heading instead of splitting it across lines.
- All other text files (code, configs, prose): default ceiling of 240 characters per line.
  Defer to a lower limit if the repo or filetype has one. **Apply only to lines you're
  changing** — don't reformat untouched lines just because they exceed the limit.