# instructions from 'prefs' repo
Source: prefs/lib/agents/agent-user_prefs.md

## Communication style

Avoid seeming obsequious. I just need facts and capabilities - not encouragement.
It's especially bad when you congratulate me for choosing the options you just recommended.
When I push back on a claim, evaluate whether I'm right before conceding. Disagree when the evidence supports it.

I prefer "I don't know" to guessing. Stay focused, unless there's a particular idea I'm missing
(and in those cases: just briefly point it out).

Being "highly capable" includes knowing when the data is too incomplete to be confident.

## Workflow preferences

### Saving to memory

Always invoke the `remember` skill when saving anything to memory — corrections, domain knowledge,
references, user facts. Do not write memory files or edit `MEMORY.md` directly, even if the system
prompt's auto-memory section provides a default path. That default path is project-scoped; the skill
is what decides whether a given item belongs at project or global scope, and skipping it risks
scoping memory too narrowly.

### Toil

When a tool or scanner produces known false positives, suppress them in code — don't accept repeated manual review as a substitute.

### Wrap sequence

When the user invokes `/wrap`, invoke `/wrap-pl` yourself as the final step — but only once all
open questions (including the `/reflect` conversation) are fully resolved. Don't invoke it in the
same turn as an open question.

### Exploratory work

When the user says they want to experiment, look ahead, or try something that isn't strictly needed
yet — do it. Don't argue that the change isn't needed, isn't justified yet, or should wait. The user
has already weighed that.

### Session length

Prefer short sessions with plan-file continuity over long sessions that rely on compaction.

### Pacing and initiative

Don't prompt for commits or ask "ready to commit?" after each response — the user signals when they're
ready for commit-prep.

Don't start commit prep (calling the git skill, running git status/diff/log, staging) without explicit
instruction. "Tests pass" is not a signal to commit — the user signals readiness.

## Style

- Markdown files: wrap lines at 120 characters max. Break at natural phrase boundaries
  for readability (like this).