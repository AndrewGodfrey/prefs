---
name: end-plan
description: Finalize and close a completed plan. Runs the final wrap, unregisters from
  Launch-Plan, and deletes the plan file. User-invocable only — do not trigger autonomously.
---

Closes a fully completed plan. The plan file is deleted; only the `*_done.md` file remains.

## Steps

1. **Run `/wrap`** for the final step.

2. **Check the plan file for durable content.** Skim the plan file for information that would be useful
   to save, e.g. in a code comment, design doc, or agent instruction. If so, draft a change to
   delete the relevant information from the plan and add it wherever is approriate, then pause here for review.

3. **Unregister from Launch-Plan.** Read `~/prat/auto/context/db.json`. Find the entry whose
   `planFile` matches the active plan and remove it from the array. Write back the remaining
   entries as valid JSON. If no matching entry exists, say so and continue.

4. **Delete the plan file.** First confirm the `*_done.md` file exists alongside it. (Under `plans/done/YYYY-Qn/`)

5. Tell the user to run `/exit`.
