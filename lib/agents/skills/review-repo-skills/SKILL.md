---
name: review-repo-skills
description: Audits repository skills. Use for additions, removals, renames, changes, or membership.
---

# Review repository skills

Review repository-owned skills that I may or may not currently have loaded in the current agent role.

This is both for curation of skills in the repo, and to determine/re-evaluate which repo skills should be
loaded in a given agent role, weighing permanent context cost versus skill value, quality, and
relevance to a particular agent role.
Use for additions, removals, renames, changes, or membership.


## Find the current policy and baseline

1. Run `& "$home/prefs/lib/agents/Get-AgentRoleContext.ps1" <target-repository-path>` and use its
   `roleName` and `repoSkills`. Use `Get-AgentRoles` to inspect the full resolved role. Read the
   layered `roles_<layer>.ps1` files when source-level policy or history is needed.
2. Enumerate each configured source and the repository's other conventional skill trees, such as
   `.github/skills` and `.claude/skills`.
3. Use an explicit user-provided baseline when available. Otherwise, use the last allowlist change as
   an approximate review date and inspect repository history since then. Label that baseline as a proxy.

Check included skills for missing or renamed targets, source collisions, changed frontmatter, and material
body changes. Check excluded skills that are new, renamed, or materially changed since the baseline.

## Treat frontmatter as the primary cost

Every exposed skill adds its name and description to every session for that role. The body loads only when
the skill triggers. Sum the rendered `name` and `description` value lengths for exposed repository skills,
excluding YAML keys, delimiters, formatting, optional fields, and bodies. Report the before/after totals
and delta as a character or word proxy, never as tokens.

A thin pointer skill still pays this permanent frontmatter cost. Its small body reduces triggered cost and
maintenance risk, but does not make inclusion free.

## Inclusion criteria

Recommend inclusion only when:

- the skill applies often enough, or prevents a sufficiently expensive recurring mistake, to justify its
  permanent frontmatter;
- its trigger is precise enough to load the body when needed without firing broadly;
- it adds distinct value beyond installed skills, scoped instructions, tools, and agents;
- its body is accurate, actionable, and consistent with the user's workflow; and
- it is trusted enough to consume live from the repository, where upstream improvements and regressions
  become effective without a separate copy or approval step.

Prefer consolidating overlapping skills over adding another trigger. Reject generic guidance, narrow
one-off knowledge, vague triggers, duplicated procedures, and skills whose workflow the user would not
want an agent to follow.

## Report before editing

Report:

- the current allowlist and any broken, renamed, duplicated, or materially changed entries;
- the aggregate frontmatter proxy before and after the recommendations;
- candidate additions and removals, each with role relevance, trigger precision, distinct value, body
  trust, and recommendation; and
- uncertain judgments that require reading history, validating claims, or asking the user.

Do not change the allowlist unless the user asked to apply the recommendations.
