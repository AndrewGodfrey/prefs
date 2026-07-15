# Launch-Plan (`pl`)

`Launch-Plan.ps1` (alias `pl`), in `prefs/pathbin/`: an interactive TUI launcher for plan-based agent
sessions (Claude Code and GitHub Copilot).

## Three ledgers

Plan tracking is split across three ledgers with different owners:

1. **Plan-file frontmatter (YAML)** — plan lifecycle state + next-step pointer. Git-synced with the plan.
   Written only by the state script (`prat/lib/agents/Set-PlanState.ps1`, dot-sourced by pl), which the
   agent invokes at deliberate boundaries via skills such as `/wrap`, `/wrap-session`, and `/code-complete`
   — the model never hand-edits these keys. Three keys:
   - `state` — lifecycle word (see table below);
   - `next-step` — step id + brief label;
   - `refined` — steps *beyond* the pointer already planned to implementable detail.
2. **Launcher db (`~/prat/auto/context/db.json`)** — machine-local session association only: which sessions
   belong to which plan, plus a launch cwd and harness. Maintained by hooks + the launcher; agents never
   touch it.
3. **User agreement ledger** — never in the plan file. Step granularity: the move to `_done.md` (via
   `/wrap`, which only runs on user approval). Hunk granularity: the user's git staging area. Checkboxes in
   the plan file are agent claims, never user agreement.

## States and Enter dispatch

Four stored states. Session existence is inferred (db `sessionIds` × resumable session files), never stored.

<!-- prettier-ignore -->
| Stored state         | + no resumable session          | + resumable session(s)                            |
|----------------------|---------------------------------|---------------------------------------------------|
| `ready-to-plan`      | fresh planning launch           | picker; defaults to the *fresh* row               |
| `ready-to-implement` | fresh "do the next step" launch | picker; defaults to the most-recent session       |
| `code-complete`      | fresh review launch             | picker; defaults to the most-recent session       |
| `checkpointed`       | consumed → fresh implement launch | same — old sessions are reference-only            |

`getLaunchAction` is the pure dispatch function: state + session availability → kind (`fresh`/`resume`) +
the state's fresh-launch prompt. Missing or unrecognized state is treated as `ready-to-plan`. The
`checkpointed` consume-and-flip (set by `/wrap-session`) is executed by `openProject` as a plan-file write
before the fresh session launches — a rare but meaningful launcher write to the plan file; the old sessions
stay in `sessionIds`, they just stop auto-resuming.

## Main view

One row per db entry: status marker, plan filename, frontmatter state. The marker shows what Enter will do:

- `[live]` — a session for this plan is running now; Enter is blocked (pl can't switch focus to it)
- `[resume]` — Enter opens the session picker
- `[fresh]` — Enter starts a fresh session

Plans open on another machine get an `⚠ other-machine` flag (see cross-machine visibility below).

Keys: `Enter` open, `O` open untracked plan, `R` register orphan session, `S` change state (repair tool),
`U` unregister, `Q`/`Esc` quit.

## Enter: the fresh/resume picker

Every launch goes through the same picker (`pickFromList`), even with zero sessions — the
"(start fresh session)" row is always present, so its inline model field is always reachable. For
`resume`-kind actions the 3 most recently active sessions are listed above it; older associations stay in
the db, unshown.

Default selection: `ready-to-plan` with sessions defaults to the fresh row (post-wrap planning usually
wants a fresh session); every other resumable state defaults to the most-recent session row.

- **Resume**: pl pre-writes the running file with the picked session id immediately after launch, so the
  session shows `[live]` before the first prompt hook fires (claude only). If `cl` exits nonzero, just the
  failed session id is dropped from the entry — the plan stays tracked.
- **Fresh**: the entry's cwd is refreshed to the current directory and the state's prompt is passed to `cl`.

### Model picker (fresh row)

If `Get-AgentModelList` is on PATH (an optional, de-supplied command) and covers the entry's harness, the
fresh row carries an inline model field cycled with ←/→: cost-sorted choices plus a trailing `<default>`
(no `--model` arg — the harness applies its own default), which is the initial selection. Otherwise
(non-de users, unlisted harnesses) the field is absent and launches carry no `--model` arg.

### Session rows

A session is resumable when its `<sid>.jsonl` exists under any `~/.claude/projects/*` dir — searching all
project dirs avoids reimplementing CC's cwd→dirname rule, and the files are sync-backed, so cross-machine
sessions count. Recency is jsonl LastWriteTime, most recent first. Row title comes from CC's
`sessions-index.json`: `summary`, else `firstPrompt` (truncated with ellipsis to 60 chars), else the
session id.

## O / R / S / U

- **O — open untracked plan**: lists `*.md` under the plans dir, excluding `done/` paths,
  `_done`/`_ref`/`_background` suffixes, and already-tracked plans. Picking one creates a db entry
  (cwd = current dir, default harness) and goes straight into the Enter flow. There is no initial-state
  prompt — state comes from the file.
- **R — register session**: repair for orphan sessions (live sessions pl can't match to a db entry).
  Two-step picker: session, then plan (tracked + untracked). Creates the db entry if needed and links the
  session id.
- **S — change state**: a repair tool for when something has gone wrong — normal state changes happen via
  the agent's state script during sessions. Writes through `Set-PlanState`. Blocked while a session is
  live.
- **U — unregister**: removes the db entry. Blocked while live.

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

- the `UserPromptSubmit` hook — stamps `planFile` into the session's running file on every prompt, which
  lets pl re-associate sessions with plans by more than cwd;
- the statusline — shows the active plan;
- skills' "the active plan" default.

## Post-exit loop

After `cl` exits, pl rebuilds its context and re-enters the TUI with the exited plan re-selected. `Q`/`Esc`
are the only real exits. Combined with accumulating `sessionIds`, this gives the instruction-reload cycle:
quit CC → land in pl → Enter resumes.

## Live-session detection

- **Claude**: a `UserPromptSubmit` hook writes `~/prat/auto/context/running/pid_<pid>.txt` containing
  `{session_id, cwd, planFile}`. On startup pl keeps only files whose pid is a live `claude` process, then
  matches by session id, then by the stamped planFile; anything left is an orphan (`R` is the repair).
  Running files for dead pids are cleaned up.
- **Copilot**: no hook needed — session id and cwd are parsed from live `copilot.exe` command lines
  (`--session-id`/`--resume`, `-C`). Unmatched sessions are cwd-matched to a sole unoccupied entry, else
  orphaned.

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
- **Harness**: each db entry carries a `harness` (`claude`/`copilot`), defaulted via `Get-DefaultHarness`
  and stamped by copilot detection when it matches a session.
