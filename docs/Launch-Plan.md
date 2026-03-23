# Design for Launch-Plan.ps1

### Overview

A simple interactive command-line tool (`Launch-Plan.ps1`, alias 'pl') in `prefs/pathbin/`.
Eventually may move to `prat` once stable.

Uses a local db (`~/prat/auto/context/db.json`) as the source of truth: a list of open projects,
each with plan file path, current state, and associated Claude session_id(s).

For cross-machine awareness, each machine writes a presence file to a sync-backed path (configured
per `de` instance). The tool reads all presence files on startup to flag plans open on other machines.


### Project states

Each open project has one of these states:

- `ready` — `/wrap` completed, plan and code committed, session exited. A fresh `cl` session
  will be launched with "please do the next step in plans/foo.md".
- `discussing` — plan is still being designed/refined. Resumes the existing session.
- `in-progress` — a step is underway but not yet wrapped. Resumes the existing session.
- `plan-complete` — all current steps done; project may or may not be fully finished.
- Additional states to be added as real cases arise.

The session_id field is a **list** to handle `/compact` and `/fork` (which can create multiple
session_ids for one project). V1 just displays them all and lets the user pick. Smarter
"most-recent-active" selection is a later enhancement.


### Main view

Lists open projects with: plan file, state, session_id(s), and a live/dormant flag (live = a
Claude process is currently running with that session_id).

Plans flagged as open on another machine (from sync-backed presence files) are highlighted — this
is the main guard against accidentally forking a workitem across machines.


### Interactions

**Enter on an existing project:**
- If `ready` → launch fresh `cl` with "please do the next step in plans/foo.md"
- If `discussing` or `in-progress` → resume: `cl --resume <session_id>` (user picks if multiple)
- If Claude is already live for this project → do nothing (can't switch focus programmatically)

**O → open untracked plan:**
- Reads plans dir (configured per `de` instance), excludes already-tracked plans
- User picks from the list
- Tool prompts for initial state (default: `discussing`)
- Launches `cl` with appropriate opening prompt
- Adds entry to db

**R → register session:**
- Lists untracked (orphan) Claude sessions detected at startup
- User picks session, then picks plan (tracked entries + untracked from plans dir)
- Links session to plan; creates db entry if plan wasn't already tracked


### Process detection (live vs. dormant)

A Claude hook (likely `UserPromptSubmit`, fires on every prompt) writes
`~/prat/auto/context/running/pid_<pid>.txt` containing the session_id. Written idempotently
— content doesn't change within a session.

On tool startup: get all live `claude.exe` pids (`(Get-Process claude).Id`), then iterate
`running/` files. Any file whose pid isn't in that set indicates a dormant/exited session.
This guards against pid reuse by other processes. Stale files (exited sessions) are cleaned up
at startup.


### Write paths

Three separate writers, each owning distinct data:

- **Tool**: creates db entry at launch — plan file, cwd, state. Session_id is unknown at this
  point (CC assigns it after startup); entry is left pending.
- **Hook** (`UserPromptSubmit`): writes `running/pid_<pid>.txt` containing `{session_id, cwd}`.
  On next tool startup, pending entries are matched by cwd to fill in session_id.
- **Claude** (via skills such as `/wrap`, or on a manual focus switch): reads and updates
  `db.json` directly — e.g. `/wrap` transitions state from `in-progress` to `ready`. Direct
  writes are safe since Claude and the tool don't run concurrently.


### Cross-machine visibility (sync-backed)

Each machine writes `<syncBackedPath>/.plan-tracking/<machineName>.json` on tool startup,
containing its current open projects + a `lastSeen` timestamp per entry.

The tool reads all machine files and flags any plan that appears in another machine's file.
Entries are kept indefinitely — stale ones (retired machines, abandoned sessions) can be
cleaned up manually.

**Configuration:** The sync-backed path is a config value defined in each `de` instance (home and
work use different paths). The tool reads it from a `de`-supplied config; if not set, it warns
and skips the cross-machine check. Warning is on by default; suppressable via a `-NoSyncBackedWarning`
param (for single-machine users/envs when this eventually moves to `prat`).


### Db format

JSON file at `~/prat/auto/context/db.json`. Simple array of project objects — easy to inspect
and hand-edit for weird cases (retired machines, abandoned sessions, etc.).
