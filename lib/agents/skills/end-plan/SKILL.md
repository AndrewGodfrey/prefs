---
name: end-plan
description: Finalize and close a completed plan. User-invocable only — do not trigger autonomously.
---

Closes a fully completed plan. The plan file is deleted; only the `*_done.md` file remains.

## Steps

1. **Run `/wrap`** for the final step.

2. **Check the plan file for durable content.** Skim the plan file for information that would be useful
   to save, e.g. in a code comment, design doc, or agent instruction. If so, draft a change to
   delete the relevant information from the plan and add it wherever is approriate, then pause here for review.

3. **Delete the plan file.** First confirm the `*_done.md` file exists under `plans/done/YYYY-Qn/`
   (its home throughout the plan's life), and move any remaining companion files (`_background.md`,
   `_evidence.md`, ...) there too. Launch-Plan drops its db entry automatically once the plan file
   is gone.

4. Tell the user to run `/exit`.
