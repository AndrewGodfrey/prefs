# Launch-Plan (`pl`)

`Launch-Plan.ps1` (alias `pl`), in `prefs/pathbin/`: an interactive TUI launcher for plan-based agent
sessions. (e.g. Claude Code, Github Copilot, pi)

## Three ledgers

Plan tracking is split across three ledgers with different owners:

1. **Plan-file frontmatter (YAML)** — plan lifecycle state + next-step pointer. Git-synced with the plan.
   Written only by the state script (`prat/lib/agents/PlanState.ps1`, dot-sourced by pl), which the
   agent invokes at deliberate boundaries via skills such as `/wrap` and `/ready-for-user-review`, and
   which pl itself invokes for `launches` — the model never hand-edits these keys. Under `current-unit`:
   - `first`/`last` — the step ids the unit spans (`last` written down only when it differs);
   - `state` — lifecycle word (see table below);
   - `launches` — the launcher's count of sessions spent on this unit;

   and alongside it, `refined` — steps *beyond* the pointer already planned to implementable detail.
2. **Launcher db (`~/prat/auto/context/db.json`)** — machine-local session association only: which sessions
   belong to which plan, plus a launch cwd and harness. Maintained entirely by the launcher.
3. **User agreement ledger** — never in the plan file. Step granularity: the move to `_done.md` (via
   `/wrap`, which only runs on user approval). Hunk granularity: the user's git staging area. Checkboxes in
   the plan file are agent claims, never user agreement.

## States and Enter dispatch

Session existence is inferred (db `sessionIds` × resumable session files), never stored. The "Display
label" column is the word shown in the TUI (`displayState`/`Get-PlanStageLabel`, in
`prat/lib/agents/PlanState.ps1`) — a separate, shorter vocabulary from the stored state, meant for humans
only; agents read/write the stored state.

<!-- prettier-ignore -->
| Stored state                    | Display label | Enters phase   | + no resumable session | + resumable session(s)                     |
|---------------------------------|---------------|----------------|------------------------|--------------------------------------------|
| `ready-to-refine`               | refining      | `refine`       | fresh launch           | picker (see Default selection below)       |
| `ready-for-refined-step-review` | refining      | `review` †     | fresh launch           | picker; always defaults to the session row |
| `ready-to-implement`            | coding        | `implement`    | fresh launch           | picker                                     |
| `ready-for-user-review`         | reviewing     | `review`       | fresh launch           | picker; always defaults to the session row |

† `implement` in `step-review` and `branch-review`: there the agent advances past that checkpoint itself, so
the state can only mean a session refined the step and stopped before implementing it.

`getLaunchAction` is the pure dispatch function: plan state + session availability → kind (`fresh`/`resume`)
+ Enters default phase (see Launch keys below). Missing or unrecognized state is treated as
`ready-to-refine`. A file with no `## Step` headings is a skeleton with no next step to refine, so it
defaults to `plan` instead.

`PlanState.ps1` maps the retired spellings as it reads them, so an unmigrated plan file still dispatches
sensibly: `ready-to-plan` is `ready-to-refine`, and `checkpointed` is `ready-to-implement` with a launch
count of 1.

### Workflow modes

The plan's `workflow` key — `tick-tock`, `step-review` or `branch-review`, absent or unrecognized meaning
`tick-tock` (prat's `plan-format` skill defines them) — says where a run ends. Besides reading it (through
the single test `endsRunAtPhaseBoundary`, which picks Enter's phase at `ready-for-refined-step-review`
above and the wording of the `refine` prompt below), pl can also write it — see `W` below.

### The launch count

The launch count is per-unit and lives on the db entry, not in the plan file: `openProject` bumps
`launches` once the picker has chosen a row, fresh or resume alike, and it says "a pl launch has worked
on this unit", which is what the picker's default row reads. It is stored with a `launchesFor` (the `first`
step it was counted against), and `updateEntryInfo` resets it to 0 whenever the pointer points at a
different step, so it can't outlive the unit it describes. Keeping it out of the plan file matters: bumping
it there would write the plan before a branch-review launch, dirtying a granted tree and tripping
`git_start_branch`'s clean-tree check. Its limit: a `cl` session started outside pl is invisible to it, so
zero means "no pl launch since the pointer moved", not "no work".

## Main view

Two lines per db entry, so the plan's name and where it's pointing stop competing for width:
- Line 1: status marker + plan filename — the identity.
- Line 2: indented under the name, the frontmatter state (`<state>: <next-step>` when a pointer is
  set, else the bare state, else `-`) and, for a plan open on another machine, an `⚠ other-machine`
  flag (see cross-machine visibility below).

The marker on line 1 shows what Enter will do:

- `[live]` — a session for this plan is running now; Enter is blocked (pl can't switch focus to it)
- `[resume]` — Enter opens the session picker
- `[fresh]` — Enter starts a fresh session

While idle, the list stays fresh: pl polls each open plan's file mtime on a 100 ms tick (`refreshIfChanged`)
and re-renders a row only when its plan file was touched — by a session, by hand, or by a run on another
machine — so a row's `state`/`nextStep` doesn't wait for a key to be re-read.

Keys: `Enter` launch, `P` plan, `D` discuss, `V` view plan file, `C` close, `S` state, `W` workflow,
`H` harness, `O` open another plan, `R` register session, `Q`/`Esc` quit.

## Launch keys: Enter, P, D

Three keys launch a session — they share the same picker and machinery (`openProject`), differing
only in which phase's prompt a fresh launch gets. `Enter` launches into whatever phase
`getLaunchAction` derives from state (see the table above); `P` always forces `plan`; `D` always
forces `discuss`.

<!-- prettier-ignore -->
| Phase       | The session is asked to                                                 |
|-------------|-------------------------------------------------------------------------|
| `plan`      | work out what the steps should be                                       |
| `refine`    | refine the next step (see below)                                        |
| `implement` | do the next step                                                        |
| `review`    | read the plan, check the recent context (last session, commits), wait   |
| `discuss`   | read the plan and wait for questions                                    |

`getLaunchPrompt(phase, planFile, workflow, state)` renders these five. `review`'s prompt names the
plan's stored state — `ready-for-user-review` or `ready-for-refined-step-review`, the two states
`Enter` dispatches to `review` from — and asks the agent to get oriented on the recent context
before waiting for the user; `discuss` (the `D` key) is a way to talk about the plan in a fresh
session regardless of what phase the state actually names, without disturbing its progress. `P`'s
prompt is the same one `plan`-phase Enter launches use, offered as its own key since you may want to
work the steps out even when the state says something else.

In `step-review` and `branch-review` the `refine` prompt asks for the implementation too, since a run
there doesn't stop at the phase boundary. Each phase's prompt is handed the plan's `workflow`, so a
later phase can vary with the mode the same way.

The fresh row's label (`getFreshRowPhaseLabel`) names the phase, the next-step pointer (when set) and
the workflow — e.g. `implement Step 9: The launch UI · branch-review` — so it doubles as the check
that the plan is in the state you thought before you commit to a launch.

Every launch goes through the same picker (`pickFromList`), even with zero sessions — the
"(start fresh session)" row is always present, so its inline fields are always reachable. For
`Enter` and `P`, when sessions are resumable, the 3 most recently active are listed above it; older
associations stay in the db, unshown. `D` never offers to resume — it's a way to talk, not to
continue whatever a live session was doing, so its picker always shows the fresh row alone.

Default selection (`defaultsToFreshPicker`): the most-recent session row until a launch has been counted
against the current unit (the frontmatter `launches` count — see States below), and the fresh row after
that, on the grounds that the sessions on offer have already spent themselves on this unit and the plan
file carries the phase forward. The two review states are the exception and always start on the session
row: the session under review is the one that refined the step or did the work.

- **Resume**: the picked session's id rides `--resume`/`--resume=` on `cl`'s command line, so any pl
  instance's next command-line scan (see Live-session detection below) sees it live immediately — no
  hook or pre-write needed. A nonzero exit drops that session id from the entry only when the resume was
  refused, meaning the session log never moved while the child ran (`resumeWasRefused`); a session that
  ran and then died keeps its place, since it is the one most worth resuming. The plan stays tracked
  either way.
- **Fresh**: the entry's cwd is refreshed to the current directory and the phase's prompt is passed
  to `cl`.
  For claude, pl also generates a session id and passes it via `--session-id`, appending it to the entry's
  `sessionIds` immediately (`getFreshSessionArgs`) — claude's own command line carries nothing else
  identifying, so this is what makes the session detectable at all.

### Inline fields (fresh row)

The fresh row carries three inline fields, each cycled by a key and re-derived into the row's label:
- **Model** — ←/→. Present only when `Get-AgentModelList` is on PATH (an optional, de-supplied command)
  and covers the entry's harness: cost-sorted choices plus a trailing `<default>` (no `--model` arg —
  the harness applies its own default), which is the initial selection. Otherwise the field is absent
  and launches carry no `--model` arg.
- **Workflow** — `W`. Cycles `tick-tock` → `step-review` → `branch-review` (wraps), and writes
  immediately through `Set-PlanState`, so the launch reads the new value. Cycling into `branch-review`
  runs the commit-grant prompt (`setCommitGrant`), the same flow the main list's `W` uses. The
  main-list `W` screen stays as the repair path for a plan you haven't launched into yet.
- **Harness** — `H`. Cycles the picker-keyed harnesses (the same set the main list's `H` offers) and
  writes immediately to the db entry, so the launch uses the new harness.

### Session rows

A session is resumable when its `<sid>.jsonl` exists under any `~/.claude/projects/*` dir (the
claude-projects path) or under the harness's own flat `sessionsDir` — searching all project dirs avoids
reimplementing CC's cwd→dirname rule, and the files are sync-backed, so cross-machine sessions count.
Recency is jsonl LastWriteTime, most recent first.

Each row (`buildLaunchRowLabel`) is the session's short id (first 8 chars of the sid, `getShortId`),
its time, and its text:

```
<shortid>  <start> → <last>  <text>
```

`<last>` is the jsonl mtime (LastWriteTime). `<start>` is the first logged event's `ts` — recorded only
for the flat path (the harness's own flat session logs); a claude-projects row shows `<last>` alone.

The text is the session's closing statement — its last `assistant_text` (`getFlatSessionAccomplishment`),
newlines collapsed so the row stays one line — when the harness records one; otherwise its summary.
Closing statements come only from the flat path, so a claude-projects row always shows its summary. The
per-path summary:

- **claude-projects**: from CC's `sessions-index.json` — `summary`, else `firstPrompt` (truncated to
  60 chars), else the sid.
- **flat** (a harness's `sessionsDir`): the first logged `user_message` (truncated to 60 chars), else
  the sid.

## O / R / S / W / H / V / C

- **O — open untracked plan**: lists `*.md` under the plans dir, excluding `done/` paths,
  `_done`/`_ref`/`_background` suffixes, and already-tracked plans. Picking one creates a db entry
  (cwd = current dir, default harness) and goes straight into the Enter flow. There is no initial-state
  prompt — state comes from the file.
- **R — register session**: repair for orphan sessions (live sessions pl can't match to a db entry).
  Two-step picker: session, then plan (tracked + untracked). Creates the db entry if needed and links the
  session id.
- **S — change state**: chiefly a repair tool for when something has gone wrong — normal state changes
  happen via the agent's state script during sessions. It doubles as the sanctioned lightweight advance
  gesture (`S` → `C`) for skipping straight to `ready-to-implement` after a refine that needs no plan
  review; that path bypasses `/wrap`'s planning-close reflect, so use it sparingly. Menu: `[P] refining
  [C] coding [R] reviewing`. Writes through `Set-PlanState`. Blocked while a session is live.
- **W — change workflow** (`changeWorkflow`): menu `[T] tick-tock [S] step-review [B] branch-review`,
  writes through `Set-PlanState -Workflow`. Picking `branch-review` also prompts for the commit grant
  (`setCommitGrant`) — branch first, defaulting to what the entry's `cwd` has checked out
  (`getRepoBranch`), shown and only ever written once confirmed (Enter) or overridden by typing; then a
  comma-separated repo list, with no inferred default. No branch typed and none inferred writes no grant.
  `T`/`S` leave an existing grant untouched. Blocked while a session is live.
- **H — change harness**: picks `claude`, plus any custom harness registered via `Get-AgentHarnesses`
  that carries a `pickerKey` (`changeHarness`/`getHarnessPickerOptions`). Unlike state, harness is a
  db-only field (`saveDb`, not a plan-file write). `copilot` isn't offered here — still fully
  supported, just not reachable from this picker. Blocked while a session is live.
- **V — view plan**: opens the selected plan file via `Open-FileInEditor` (the `e` alias's target;
  prat-deployed, so available in the interactive profile pl runs under). No-op if that alias isn't
  installed.
- **C — close**: removes the db entry (pairs with `O`, which adds one). Blocked while live.

## db.json

`~/prat/auto/context/db.json` — an array of `{planFile, cwd, sessionIds, harness}`. That is the whole
schema: `loadDb` projects to exactly these fields, so a legacy `state` field on disk is silently dropped
and gone after the next save. `sessionIds` accumulate — they are never reset wholesale; sessions simply
stop being offered once their jsonl disappears.

On startup, entries whose plan file no longer exists are dropped (`loadLauncherDb`). The `end-plan` skill
relies on this: deleting the plan file is how a finished plan leaves the launcher.

## CL_PLAN_FILE

Every launch, fresh and resume, wraps `cl` with `Set-EnvTemp @{ CL_PLAN_FILE = <planFile> }` (`launchCl`).
Consumers:

- the statusline — shows the active plan;
- skills' "the active plan" default.

## The commit grant

A plan's `commit-grant: { branch, repos }` frontmatter says the agent may commit, in those repos, on that
branch — declared by hand, or written via `W`'s `setCommitGrant` (see above). Every launch through
`launchCl` carries it, resume and fresh alike, as `-CommitBranch` / `-CommitRepo` on `cl`'s command line.

`resolveCommitGrant` turns each `repos` entry into a path — a prat repo id, or a path of its own when it
contains a separator or a leading `~` — and checks the branch is checked out there. One entry that doesn't
resolve, or one repo on another branch, refuses the whole grant, and the session starts with no commit
rights.

A repo still on `main` that has no branch of that name yet is the exception: the grant holds, and pl prints
what it is about to let happen and pauses for a keypress, rather than refusing. A session whose harness has a
branch-creating tool makes the branch there; one told about the grant in prose can't, and can't commit in
that repo until the branch exists.

## Branch-review run

On `branch-review`, a fresh `Enter` dispatch into `refine`/`implement` — never `P`/`D`, and never
picking a session row — hands off to `runBranchReviewRun` instead of a single `launchCl`, but only
when the current step is in the plan's `automatable` set and the entry's harness declares itself
headless-capable (`headlessFlag` on its descriptor, checked via `harnessSupportsHeadless` /
`isBranchReviewLoopable`); a step outside the set, or a harness with no flag, gets today's single
launch. The `automatable` field is hand-written beside `workflow` and `commit-grant`: `*` for every
step, or a comma list of numbers and inclusive ranges (`16-19`, `16, 19`); an absent field means no
step is automatable, so such a plan never hands off. A de-supplied harness declares its flag via
`headlessFlag` on its `Get-AgentHarnesses.ps1` entry, beside `commitGrantArgs`.

The run is a loop: one fresh, headless launch per step (`getFreshSessionArgs` + `--headless`), each
resolving its own phase/prompt from a fresh `Get-PlanState` read the way Enter's own dispatch does,
until `getPreflightStopReason` (checked before spending a launch) or `getPostflightStopReason`
(checked after one returns) names a reason:

- the plan is finished: its file is gone, or it has no steps left — `/wrap` on the last step cut its
  body, so the plan lands at `ready-for-user-review` (phase `review`) with nothing to point at, and
  the run reads that as completion rather than a stall;
- the state is `ready-for-user-review` and steps remain (`getLaunchAction`'s phase is `review`) —
  the user's checkpoint, which an unattended run can't cross on its own;
- the current step is outside the plan's `automatable` set (an absent field counts as empty) — a
  design step the run stops in front of rather than inventing on its own; the reason names the step;
- 50 launches or 12 hours elapsed (a backstop against a run that keeps moving without getting
  anywhere, not a limit a normal run should meet);
- the launch exited non-zero;
- the launch itself outlived its per-launch cap (3 hours, sized for a slow local model): the run
  killed the session's process tree and stops, naming the timed-out session id in the reason so its
  log is findable in the report. The 50-launch and 12-hour budgets bound the gaps *between*
  launches, never a single launch, which is what this caps (`waitLaunchProcess` + `launchCl`'s
  `-Unattended` gate);
- the frontmatter didn't change (`planFrontmatterProgressed`, everything but `launches` — which the
  launcher, not the agent, increments every launch): a step that wrapped moves the pointer or state,
  a stalled one doesn't.

A commit grant that doesn't qualify (`commitGrantRefusedReason`) stops the run before it spends a
launch, rather than launching without commit rights — the whole point of `branch-review` is the
commit series. Every console pause on the launch path — the cursor guard, both commit-grant pauses —
is suppressed for these launches (`launchCl -Unattended`), since nobody is there to answer one.

The outcome (`newRunReport`: plan, the steps it closed, stop reason, last session id) is written to
`~/prat/auto/context/plan-run-report.json` and rendered above the list (`getRunReportLines`,
`buildLauncherContext` → `renderList`) — pl's list otherwise looks unchanged after a run that quietly
finished several steps. The steps-closed list is derived from the plan's end state: 
`getStepsClosedByRun` diffs the plan's `StepHeadings` before and after the run.
One slot, replacing whatever was there; dismissed by the next launch of *any* plan (cleared alongside
the db-entry launch-count bump, once a row is picked), not by navigating the list or quitting pl.
`sendRunNotification` fires once for the whole run in its place —
a headless launch's own per-turn hook (`prigApp.run`) passes no `notify_turn_completed`, so a run
doesn't also fire one identical "done" notification per step.

## Post-exit loop

After `cl` exits, pl rebuilds its context and re-enters the TUI with the exited plan re-selected. `Q`/`Esc`
are the only real exits. Combined with accumulating `sessionIds`, this gives the instruction-reload cycle:
quit CC → land in pl → Enter → pick the session row (↑ from the fresh row, which the launch just counted
against the unit — see Default selection above).

A failure has to survive that re-entry to be readable, which is what `buildChildCommand`'s trailing
`exit $LASTEXITCODE` is for: pwsh adopts that variable as its own exit code only when the
`-EncodedCommand` script ends on a native command, and `cl` ends on PowerShell, so a harness that printed
an error and exited non-zero otherwise reaches pl as a clean 0 — no message, and the next redraw clears
what the harness printed. With the code propagated, pl prints the exit code and waits for Enter, leaving
the harness's own output on screen above it.

## Live-session detection

Thanks to wrapping harnesses with 'cl', every harness carries its session id on its own live process command line.
So pl scans process command lines directly (`getLiveSessionRecords`, one call per harness) and resolves them
against the db (`resolveHarnessSessions`) — id match first, then (copilot only) a cwd-match fallback
to a sole unoccupied entry. Anything left unmatched is an orphan (`R` is the repair).

- **Claude**: `--session-id <uuid>` (fresh, added by pl — see Resume/Fresh above) or `--resume <sid>`
  (resume). No cwd appears on the command line, and pl-launched claude sessions don't need cwd-matching —
  bare `cl` launches without pl always get a generated `--session-id` too (`Invoke-ClHook` in de's
  `Start-CommandLineAgent.ps1`), so every claude session is at least discoverable as an orphan.
- **Copilot**: session id and cwd are parsed from live `copilot.exe` command lines (`--session-id`/
  `--resume`, `-C`) — copilot's own launcher supplies these unprompted, no pl involvement needed. Unmatched
  sessions are cwd-matched to a sole unoccupied entry, else orphaned.
- **A custom harness** (`Get-AgentHarnesses`, see Configuration below): scanned only if its descriptor
  supplies `liveProcessName`, filtered by `liveCmdlineFilter` when the process name alone would be too
  generic (e.g. a bare interpreter like `python.exe` shared by unrelated processes). No cwd-match
  fallback, same as claude.

## Cross-machine visibility

On each startup pl regenerates `<syncBackedPath>/.plan-tracking/<machineName>.json` — machine name, a
`lastSeen` timestamp, and the machine's current open-plan list. It reads the other machines' files and
flags every plan listed in a file whose `lastSeen` is within the last 7 days (a missing `lastSeen`, from an
older format, is treated as recent). Flagged plans show `⚠ other-machine` — the guard against accidentally
forking a workitem across machines.

The sync-backed path is per-de-instance config (`Resolve-PratLibFile 'lib/agents/Get-PlanTrackingConfig.ps1'`).
When unset, a warning notice appears; suppress with `-NoSyncBackedWarning`.

### Known gap: cross-machine resume hazard

Presence files carry plan paths only, not live session ids — so a session live on machine A gives no
warning when you resume it on machine B (session `.jsonl` files are sync-backed, so the resume works).
Deliberately deferred as of 2026-07; presence files carrying live session ids is a possible later add-on.

## Configuration

- **Plans dir**: `Resolve-PratLibFile 'lib/agents/Get-PlansDir.ps1'` (de-supplied). Without it, `O` is
  unavailable and `R` can only target already-tracked plans.
- **Harness**: each db entry carries a `harness`, defaulted via `getDefaultHarness`
  (`(Get-AgentHarnesses)[0].name`) and stamped by live-process detection when it matches a session.
  `Get-AgentHarnesses` is *required* (unlike the optional `Get-AgentModelList`) but only *selects*
  which harnesses de uses and their order. A harness is fully inactive — not offered in the `H` menu,
  not live-scanned, not resumable — unless its name is listed, even a well-known one: claude/
  copilot/pi's own properties come from prefs's built-in `getBuiltinHarnessDescriptors` and can't be
  reconfigured via the registry, but the registry still has to name them to turn them on (a bare
  `@{ name = 'copilot' }` entry is enough). A name prefs has no built-in for is the *augmenting*
  case: see the next bullet. pi is live-detected (as `node.exe`, filtered by its script path since
  that process name is generic — see `Invoke-AgentSession.ps1` for its launch-arg handling) but not
  resumable: its `--resume` takes no session id (it shows its own interactive menu instead), so pl
  has no way to resume one specific past session non-interactively.
- **`Get-AgentHarnesses`** (de-supplied, required — called bare-name): returns an array of
  `@{ name = '<harness>'; ... }`, first entry = default. Extra properties only matter for a harness
  name prefs doesn't already know (claude/copilot): `pickerKey` (offered in the `H` menu),
  `liveProcessName`/`liveCmdlineFilter` (live-process scan — the filter matters when the process name
  alone is too generic, e.g. a bare interpreter shared by unrelated processes), `liveCwdMatch`
  (cwd-match fallback for a harness whose command line carries one), `sessionsDir` (resumable-session
  lookup reads this harness's own flat `<sessionsDir>/<sid>.jsonl` files — `getFlatSessionInfos`/
  `getFlatSessionSummary`, summarized from the first logged `user_message` event) or `sessionInfoStyle
  = 'claude-projects'` (reads the CC-style `~/.claude/projects/*/<sid>.jsonl` layout instead — claude/
  copilot's built-in style, opt-in-able for a custom harness stored the same way). A custom harness
  with none of these is still launchable, just not live-detected or resumable through pl.
