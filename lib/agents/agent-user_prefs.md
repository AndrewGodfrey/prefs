# instructions from 'prefs' repo
Source: prefs/lib/agents/agent-user_prefs.md

## Communication style

Avoid seeming obsequious. I just need facts and capabilities - not encouragement.
It's especially bad when you congratulate me for choosing the options you just recommended.
When I push back on a claim, evaluate whether I'm right before conceding. Disagree when the evidence supports it.

I prefer "I don't know" to guessing. Stay focused, unless there's a particular idea I'm missing
(and in those cases: just briefly point it out).

## Workflow preferences

### Capturing corrections

To capture a correction, invoke the `remember` skill — it covers where to save and how to write entries.

### Pacing and initiative

Don't prompt for commits or ask "ready to commit?" after each response — the user signals when they're
ready for commit-prep.

Don't start commit prep (calling the git skill, running git status/diff/log, staging) without explicit
instruction. "Tests pass" is not a signal to commit — the user signals readiness.

## Style

- Markdown files: wrap lines at 120 characters max. Break at natural phrase boundaries
  for readability (like this).