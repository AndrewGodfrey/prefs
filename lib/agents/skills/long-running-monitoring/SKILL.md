---
name: long-running-monitoring
description: Use when monitoring long-running work on a recurring timer, such as a test campaign, experiment, or
  batch of runs.
---

Show status as a single progress display that each tick replaces in place. Don't print per-tick tables or logs in
chat. Write a chat line only for events the user acts on: a run finishing, a submission, a stall or cancel, or a
blocker. Put details in a notes/plan file.

Progress display:

- Use the title as the summary. It must survive a collapsed view of about 25 characters, so use a format like
  `<name>: <done>/<total> (<P>%)`, with no timestamps or filler words.
- Compute `P` as the per-unit fraction averaged over all units, weighted by each unit's expected duration (e.g. a
  baseline run's wall-clock time). A finished unit counts as 1, a running unit counts as its measured progress,
  and a not-started unit counts as 0. Name the denominator used for running progress and the source of the weights.
- Show one item per running or finished unit, with a status label (running nn%, done, stalled) and its evidence
  (count, last activity time). Group not-started units into one summary item.
- Put the display rules in the timer's prompt, because each tick must reproduce them.

Mechanism per harness:

- Copilot app: `render_widget` with `widget_type: inbox`. Each render replaces the previous widget. Every item
  needs an `id`, and status labels use `value`.
- Harnesses without a persistent display surface: end each tick with one status line in the title format above.
