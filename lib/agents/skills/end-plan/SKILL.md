---
name: end-plan
description: Finalize and close a completed plan. Runs the final wrap, unregisters from
  Launch-Plan, and deletes the plan file. User-invocable only — do not trigger autonomously.
---

Closes a fully completed plan. The plan file is deleted; only the `*_done.md` file remains.

## Steps

1. **Run `/wrap`** for the final step.

2. **Unregister from Launch-Plan.** Read `~/prat/auto/context/db.json`. Find the entry whose
   `planFile` matches the active plan and remove it from the array. Write back the remaining
   entries as valid JSON. If no matching entry exists, say so and continue.

3. **Delete the plan file.** Confirm the `*_done.md` file exists alongside it first.

4. Tell the user to run `/exit`.
