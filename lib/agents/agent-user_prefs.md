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

When a tool or scanner produces known false positives, suppress them in code — don't accept repeated
manual review as a substitute.

### Exploratory work

When I say I want to experiment, look ahead, or try something that isn't strictly needed yet — do it.
Don't argue that the change isn't needed, isn't justified yet, or should wait. I've already weighed that.

### Session length

Prefer short sessions with plan-file continuity over long sessions that rely on compaction.

Why (cloud models; local models change this): cached re-reads are ~1/10 price but recur on every
request, so over a session they grow O(n²) with turn count while new tokens grow O(n). Past a
crossover the cached re-reads dominate — a single added turn at the end of a long session can cost
more than the same work done uncached in a fresh session.

### We work in parallel
The following is my typical workflow. Sometimes I might instead ask you to commit a series of changes to a branch, but
I'll clearly ask for that when it's relevant. Usually it's not, and instead:

Before you finish your turn, I typically will already have started reviewing. To keep track of what I've
accepted already, I often move changes from "unstaged" to "staged", and if I've accepted something that
makes a logical step, I may also commit it.

So: Don't expect your changes to stay where you left them. And you don't need to stop and ask if you notice it.

The "staged" area is mine — it tracks my review progress. Git-state writes (staging, committing) are
ACL-blocked for agents; to view changes, run `git diff` (unstaged) and `git diff --cached` (staged)
separately.

On the other hand: You are free to create or edit any file that isn't .gitignored, in any repository
I am monitoring. (That's typically prat, prefs, de, and whichever repo we're working on if that's separate).
I will see those.

Then again: files agents create under gitignored directories are a problem — fork.dev doesn't surface
those (unlike untracked files, which it shows clearly), so messes there can go unnoticed for a long
time. I'll find a better solution, but for now: please announce any you create (coarse-grained is fine).

### Interruptions and sync points

Model 1 interruption as ~30 minutes of my work — humans don't context-switch well. Any turn I must
wait more than ~5 seconds for counts as an interruption. Weigh token costs against human time on
this scale; both are precious.

The goal is few, high-value sync points rather than zero interruptions: some turns are worth far
more than they cost (e.g. my turn after /reflect, which surfaces good and bad ideas from both agent
and user). Batch low-value asks into the valuable sync points instead of adding turns.

### Initiative

Don't propose next steps or ask "ready to proceed to X?" unless I've signaled readiness or
there's actual time pressure. The end-of-turn summary describes what changed; I'll
decide the next step.

For commit-prep specifically: don't ask "ready to commit?" or run git status/diff/log or the git
skill without explicit instruction. "Tests pass" is not a signal to commit — the user signals
readiness.

### Tangents
I apply "slow is smooth, smooth is fast" to coding steps as well. If I see a small mess, my bias is towards fixing
it immediately, rather than let it grow into a big one. This means one planned step may often end up with multiple other
changes attached. That's intentional.

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
  - A PostToolUse hook flags over-limit lines after every edit — heed its findings. For bulk
    checks: `Find-LongMarkdownLines [-Path <file|dir>]` (prat tooling).
  - Headings can't be wrapped either (each `#`-prefixed line becomes its own separate heading) —
    shorten an overlong heading instead of splitting it across lines.
- All other text files (code, configs, prose): default ceiling of 240 characters per line.
  Defer to a lower limit if the repo or filetype has one. **Apply only to lines you're
  changing** — don't reformat untouched lines just because they exceed the limit.