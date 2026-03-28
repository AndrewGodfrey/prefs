---
description: After /wrap, mark the active plan as ready in db.json so Launch-Plan (pl) offers a
  fresh session next time. Run after /wrap completes, then /exit.
---

The "active plan" is the plan file most relevant to this session — infer from context (same as
for `/wrap`). If context is ambiguous (multiple in-progress entries in db.json and no clear active
plan), list the candidates and ask the user to confirm before proceeding.

1. Read `~/prat/auto/context/db.json`.
2. Find the entry whose `planFile` matches the active plan.
   - If no matching entry is found, say so — do not create one.
   - If the entry's state is already `"ready"`, say so and stop (no change needed).
   - If the entry's state is `"plan-complete"`, warn before overwriting — confirm with the user.
3. Set `state` to `"ready"` and `sessionIds` to `[]`. Write back the full array as valid JSON.
4. Confirm what was updated, then tell the user to run `/exit`.
