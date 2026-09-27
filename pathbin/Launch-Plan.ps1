# Launch-Plan.ps1  (alias: pl)
# Interactive launcher for plan-based agent sessions (Claude Code and GitHub Copilot).
# Plan lifecycle state lives in plan-file frontmatter (Get-PlanState/Set-PlanState); the local db
# only associates plans with sessions and a cwd. Enter is state-driven; after a session exits, pl
# returns to its TUI with freshly resolved state.
#
# Design: see docs/Launch-Plan.md

param([switch] $NoSyncBackedWarning)

$dbPath = "$home/prat/auto/context/db.json"

. "$home/prat/lib/agents/PlanState.ps1"

# Per-launch wall-clock cap for a branch-review launch, in seconds. Bounds a single launch itself,
# which the run's preflight budgets (50-launch, 12-hour) do not. Sized for a slow local model
# finishing a step rather than a cloud round trip.
$script:branchReviewLaunchTimeoutSeconds = 3 * 60 * 60

# The exit code a timed-out launch reports, in place of the child's real one. Distinct from any exit
# code a child can carry (0..65535, plus 1 from a launch that never started), so the loop can tell a
# timeout apart from a real crash.
$script:launchTimeoutSentinel = -2147483648
function main {
    saveConsoleMode
    Import-Module "$home/prat/lib/PratBase/PratBase.psd1" -ErrorAction Ignore

    $lastPlan = $null
    while ($true) {
        $ctx = buildLauncherContext
        $lastPlan = runLauncher $ctx.db $ctx.liveSessionIds $ctx.orphans $ctx.crossFlags $ctx.notices $ctx.sessionHarness $lastPlan $ctx.runReport
        if (-not $lastPlan) { return }
    }
}

function buildLauncherContext {
    $db = loadLauncherDb $dbPath

    # For tracking, we arrange for the session id to be on the harness's command line.
    $liveSessionIds = [System.Collections.Generic.HashSet[string]]::new()
    $orphans        = [System.Collections.Generic.List[string]]::new()
    $sessionHarness = @{}
    foreach ($h in (getHarnessDescriptors)) {
        if (-not $h.liveProcessName) { continue }
        resolveHarnessSessions $db (getLiveSessionRecords $h.name $h.liveProcessName $h.liveCmdlineFilter) $liveSessionIds $orphans $sessionHarness ([bool] $h.liveCwdMatch)
    }

    saveDb $db $dbPath
    attachEntryInfo $db

    $notices = [System.Collections.Generic.List[string]]::new()

    if (-not (getPlansDir)) { $notices.Add('No plans directory configured — O and R unavailable. Provide lib/agents/Get-PlansDir.ps1 in your de repo.') }

    $syncResult = getSyncPath
    $syncPath   = $syncResult.path
    if ($syncResult.notice -and -not $NoSyncBackedWarning) { $notices.Add($syncResult.notice) }
    $crossFlags = @()
    if ($syncPath) {
        updatePresenceFile $db $syncPath
        $crossFlags = getCrossMachineFlags $syncPath
    }

    return @{ db = $db; liveSessionIds = $liveSessionIds; orphans = $orphans; crossFlags = $crossFlags; notices = $notices
              sessionHarness = $sessionHarness; runReport = (readRunReport) }
}

function loadLauncherDb([string] $path) {
    $db = [System.Collections.Generic.List[object]]::new()
    foreach ($item in (loadDb $path)) {
        if (Test-Path -LiteralPath $item.planFile) { $db.Add($item) }   # entries for deleted plan files are dropped
    }
    return ,$db
}

# Display-only fields on the in-memory entries (saveDb strips them): the frontmatter state, and
# what Enter will do (enterKind 'resume'|'fresh').
function attachEntryInfo($db) {
    foreach ($entry in $db) { updateEntryInfo $entry }
}

function updateEntryInfo($entry) {
    $planState = Get-PlanState -PlanFile $entry.planFile
    # The launch count is per-unit, stored in the db, not the plan file: it counts launches since the
    # pointer last pointed at a different step, so a pointer move resets it and it can't outlive the
    # unit it was counted against.
    if ($entry.launchesFor -ne $planState.First) { $entry.launches = 0; $entry.launchesFor = $planState.First }
    $resumable = @(getSessionInfos $entry.sessionIds -harness $entry.harness).Count -gt 0
    $entry | Add-Member -NotePropertyName state -NotePropertyValue $planState.State -Force
    $entry | Add-Member -NotePropertyName nextStep -NotePropertyValue $planState.First -Force
    $entry | Add-Member -NotePropertyName enterKind -NotePropertyValue (getLaunchAction $planState $resumable).kind -Force
}

# Re-run updateEntryInfo on the entries whose plan file was touched since it last recorded an mtime
# (a display-only _mt member, like state/nextStep), and record the new mtimes. Cheap per call: one
# Get-Item per entry (≈0.2 ms, versus ≈15 ms for the Get-PlanState parse updateEntryInfo runs, which
# also reads each row's session logs), so runLauncher can call it on every idle tick. Returns whether
# anything changed. The first call initializes every _mt without flagging a change — the initial
# render already reflects the context buildLauncherContext just read.
function refreshIfChanged($db) {
    $changed = $false
    foreach ($entry in $db) {
        $item = Get-Item -LiteralPath $entry.planFile -ErrorAction Ignore
        if (-not $item) { continue }
        if ($entry.PSObject.Properties['_mt'] -and $entry._mt -ne $item.LastWriteTime) {
            updateEntryInfo $entry
            $changed = $true
        }
        $entry | Add-Member -NotePropertyName _mt -NotePropertyValue $item.LastWriteTime -Force
    }
    return $changed
}

# --- TUI ---

# Returns the launched plan's planFile after a cl launch (the caller rebuilds context and
# re-enters, restoring the selection), or $null on quit.
function runLauncher($db, $liveSessionIds, $orphans, $crossFlags, $notices, $sessionHarness, $initialPlanFile, $runReport = $null) {
    $selected      = indexOfPlan $db $initialPlanFile
    $transientError = $null
    $dirty         = $true
    while ($true) {
        # Idle refresh: a plan changed by a session, by hand, or on another machine shows a stale
        # state/nextStep until the next render, so poll the plan-file mtimes each tick and mark the
        # screen dirty when one moved.
        if (refreshIfChanged $db) { $dirty = $true }
        if ($dirty) {
            renderList $db $selected $liveSessionIds $orphans $crossFlags $notices $transientError $runReport
            $transientError = $null
            $dirty = $false
        }
        # Poll for a key instead of blocking: a blocking ReadKey can't act on what the idle refresh
        # learns between keys, so the loop has to give up blocking either way. 100 ms — one mtime pass
        # per tick is ≈2.7 ms over a 12-entry db (≈0.2 ms/entry, measured), so ~2.7% idle CPU and a
        # change lands within a tick.
        $key = $null
        while (-not $key) {
            if ([Console]::KeyAvailable) { $key = [Console]::ReadKey($true) } else { Start-Sleep -Milliseconds 100 }
        }
        # Every consumed key re-renders next pass — navigation, an action's own redraw, or an error
        # line. Set here, before the handler, so a handler that throws (swallowed below) still
        # re-renders its transient error, as the blocking loop did.
        $dirty = $true
        $errCountBefore = $Error.Count
        try {
        switch ($key.Key) {
            'UpArrow'   { $selected = if ($selected -gt 0) { $selected - 1 } else { [Math]::Max(0, $db.Count - 1) } }
            'DownArrow' { $selected = if ($selected -lt ($db.Count - 1)) { $selected + 1 } else { 0 } }
            'Enter' {
                if ($db.Count -gt 0) {
                    [Console]::Clear()
                    if (openProject $db $db[$selected] $liveSessionIds) { return $db[$selected].planFile }
                }
            }
            { $_ -in 'P', 'p' } {
                if ($db.Count -gt 0) {
                    [Console]::Clear()
                    if (openProject $db $db[$selected] $liveSessionIds 'P') { return $db[$selected].planFile }
                }
            }
            { $_ -in 'D', 'd' } {
                if ($db.Count -gt 0) {
                    [Console]::Clear()
                    if (openProject $db $db[$selected] $liveSessionIds 'D') { return $db[$selected].planFile }
                }
            }
            { $_ -in 'O', 'o' } {
                [Console]::Clear()
                if (openUntracked $db) { return $db[$db.Count - 1].planFile }
            }
            { $_ -in 'R', 'r' } {
                [Console]::Clear()
                registerProject $db $orphans $liveSessionIds $sessionHarness
            }
            { $_ -in 'S', 's' } {
                if ($db.Count -gt 0) {
                    if (isLive $db[$selected] $liveSessionIds) {
                        $transientError = 'Cannot change state of a live session — exit the agent first.'
                    } else {
                        changeState $db $db[$selected]
                    }
                }
            }
            { $_ -in 'W', 'w' } {
                if ($db.Count -gt 0) {
                    if (isLive $db[$selected] $liveSessionIds) {
                        $transientError = 'Cannot change workflow of a live session — exit the agent first.'
                    } else {
                        changeWorkflow $db $db[$selected]
                    }
                }
            }
            { $_ -in 'H', 'h' } {
                if ($db.Count -gt 0) {
                    if (isLive $db[$selected] $liveSessionIds) {
                        $transientError = 'Cannot change harness of a live session — exit the agent first.'
                    } else {
                        changeHarness $db $db[$selected]
                    }
                }
            }
            { $_ -in 'V', 'v' } {
                if ($db.Count -gt 0) { openInEditor $db[$selected].planFile }
            }
            { $_ -in 'C', 'c' } {
                if ($db.Count -gt 0) {
                    if (isLive $db[$selected] $liveSessionIds) {
                        $transientError = 'Cannot close a live session — exit the agent first.'
                    } else {
                        $db.RemoveAt($selected)
                        saveDb $db $dbPath
                        if ($selected -ge $db.Count) { $selected = [Math]::Max(0, $db.Count - 1) }
                    }
                }
            }
            { $_ -in 'Q', 'q', 'Escape' } { [Console]::Clear(); return $null }
        }
        } catch {
            # Swallowed here — surfaced via the $Error-based check below, which also catches
            # non-terminating errors (e.g. from Get-ChildItem) that never reach this catch.
        } finally {
            $newErrors = getNewErrorRecords $errCountBefore
            if ($newErrors.Count -gt 0) {
                appendErrorLog $newErrors
                $transientError = "$($newErrors.Count) error(s) during that action — see $(getErrorLogPath)"
            }
        }
    }
}

function displayState($entry) {
    $label = if ($entry.state) { Get-PlanStageLabel $entry.state } else { $null }
    if ($label -and $entry.nextStep) { return "$($label): $($entry.nextStep)" }
    if ($label) { return $label }
    return '-'
}


# TUI selection restore: index of $planFile in the (possibly rebuilt) db; top of list if absent.
function indexOfPlan($db, [string] $planFile) {
    if ($planFile) {
        for ($i = 0; $i -lt $db.Count; $i++) {
            if ($db[$i].planFile -eq $planFile) { return $i }
        }
    }
    return 0
}

# Pure: builds a row's two display lines, each truncated to fit $width. Line 1 is the plan's
# identity (name, padded to the widest name so names align); line 2 is where it's pointing
# (state + next step) plus the cross-machine flag, indented under the name. Keeps prefix/status
# untouched (fixed width) and lets renderList print each field in its own color.
function buildRowFields($entry, [bool] $isSelected, [bool] $live, [bool] $isCross, [int] $maxNameLen, [int] $width) {
    $prefix   = if ($isSelected) { '→ ' } else { '  ' }
    $status   = if ($live) { '[live]  ' } elseif ($entry.enterKind -eq 'resume') { '[resume]' } else { '[fresh] ' }
    $planName = Split-Path $entry.planFile -Leaf
    $indent   = ' ' * ($prefix.Length + $status.Length)

    $nameBudget = [Math]::Max(0, $width - $prefix.Length - $status.Length)
    $nameField  = truncateLabel "  $($planName.PadRight($maxNameLen))" $nameBudget

    $crossField   = if ($isCross) { '  ⚠ other-machine' } else { '' }
    $detailBudget = [Math]::Max(0, $width - $indent.Length - $crossField.Length)
    $detail       = truncateLabel "  $(displayState $entry)" $detailBudget

    return @{ prefix = $prefix; status = $status; statusFg = if ($live) { 'Green' } elseif ($entry.enterKind -eq 'resume') { 'Cyan' } else { 'DarkGray' }
              nameField = $nameField; indent = $indent; detail = $detail; crossField = $crossField }
}

function renderList($db, $selected, $liveSessionIds, $orphans, $crossFlags, $notices, $transientError, $runReport = $null) {
    [Console]::Clear()
    Write-Host '  Plan Launcher' -ForegroundColor Cyan
    Write-Host ''

    # A finished branch-review run leaves no other trace here: the plan file it ran to completion is
    # gone from the list below it, and a run that stopped mid-plan looks like any other row otherwise.
    # Yellow, not the launcher's cyan, so a run that just stopped stands out rather than blending in.
    foreach ($line in (getRunReportLines $runReport)) { Write-Host $line -ForegroundColor Yellow }
    if ($runReport) { Write-Host '' }

    if ($db.Count -eq 0) { Write-Host '  (no open plans — press O to open one)' -ForegroundColor DarkGray }

    $maxNameLen  = if ($db.Count -gt 0) { ($db | ForEach-Object { (Split-Path $_.planFile -Leaf).Length } | Measure-Object -Maximum).Maximum } else { 0 }

    $width = getConsoleWidth
    for ($i = 0; $i -lt $db.Count; $i++) {
        $entry   = $db[$i]
        $live    = isLive $entry $liveSessionIds
        $isCross = $crossFlags -contains $entry.planFile
        $nameFg  = if ($i -eq $selected) { 'White' } else { 'Gray' }
        # Marker = what Enter does: switch to the live session is impossible ([live]), open the
        # session picker ([resume]), or start a fresh session ([fresh]).
        $f = buildRowFields $entry ($i -eq $selected) $live $isCross $maxNameLen $width

        # Line 1: the plan's identity. Line 2: where it's pointing, indented under the name.
        Write-Host -NoNewline $f.prefix
        Write-Host -NoNewline $f.status -ForegroundColor $f.statusFg
        Write-Host -NoNewline $f.nameField -ForegroundColor $nameFg
        Write-Host ''
        Write-Host -NoNewline $f.indent
        Write-Host -NoNewline $f.detail
        if ($f.crossField) { Write-Host -NoNewline $f.crossField -ForegroundColor Yellow }
        Write-Host ''
    }

    Write-Host ''
    Write-Host '  [↑↓] navigate   [Enter] launch   [P] plan   [D] discuss   [V] view file   [C] close   [S] state   [W] workflow   [H] harness' -ForegroundColor DarkCyan
    Write-Host '  [O]  open another plan   [R] register session' -ForegroundColor DarkCyan
    Write-Host '  [Q]  quit' -ForegroundColor DarkCyan

    if (($notices -and $notices.Count -gt 0) -or ($orphans -and $orphans.Count -gt 0)) {
        Write-Host ''
        foreach ($n in $notices) { Write-Host "  ⚠ $n" -ForegroundColor Yellow }
        if ($orphans -and $orphans.Count -gt 0) {
            Write-Host "  ⚠ Untracked session(s): $($orphans -join ', ')" -ForegroundColor Yellow
        }
    }
    if ($transientError) {
        Write-Host ''
        Write-Host "  ✗ $transientError" -ForegroundColor Red
    }
}

# --- Error diagnostics ---

# A key-handler action's own errors (thrown or merely written to the error stream) get wiped by the
# TUI's next screen clear before they can be read — logged here instead. Read with:
#   Get-Content (getErrorLogPath) -Tail 40
function getErrorLogPath { return "$home/prat/auto/context/launch-plan-errors.log" }

# $Error is newest-first; returns the records added since $priorCount, oldest-first.
function getNewErrorRecords([int] $priorCount) {
    if ($Error.Count -le $priorCount) { return @() }
    $records = @($Error.GetRange(0, $Error.Count - $priorCount))
    [array]::Reverse($records)
    return ,$records
}

function formatErrorRecord($errorRecord) {
    $ts    = Get-Date -Format 'o'
    $stack = if ($errorRecord.ScriptStackTrace) { "`n$($errorRecord.ScriptStackTrace)" } else { '' }
    return "[$ts] $($errorRecord.ToString())$stack"
}

function appendErrorLog($errorRecords, [string] $logPath = (getErrorLogPath)) {
    if (@($errorRecords).Count -eq 0) { return }
    $null = New-Item -ItemType Directory -Path (Split-Path $logPath) -Force
    # -Path, not -LiteralPath: LiteralPath skips provider-path normalization and drops a
    # multi-character PSDrive prefix (e.g. Pester's TestDrive:) when the target file is new.
    (@($errorRecords) | ForEach-Object { formatErrorRecord $_ }) -join "`n`n" | Add-Content -Path $logPath -Encoding UTF8
}

# --- Actions ---

# S is chiefly a repair tool for when something has gone wrong — normal state changes happen via
# the agent's state script during sessions. It doubles as the sanctioned lightweight advance
# gesture (S -> C) for skipping straight to ready-to-implement after a refine that needs no plan
# review; that path bypasses /wrap's planning-close reflect, so use it sparingly.
function changeState($db, $entry) {
    clearConsole
    Write-Host "  Change state: $(Split-Path $entry.planFile -Leaf)" -ForegroundColor Cyan
    Write-Host ''
    Write-Host "  Current state: $(displayState $entry)"
    Write-Host ''
    Write-Host '  New state:  [P] refining  [C] coding  [R] reviewing  [Esc] cancel'
    $key = readStateKey
    $newState = switch ($key.Key) {
        'P' { 'ready-to-refine' }
        'C' { 'ready-to-implement' }
        'R' { 'ready-for-user-review' }
        default { $null }
    }
    if ($newState -and $newState -ne $entry.state) {
        $null = Set-PlanState -PlanFile $entry.planFile -State $newState
        updateEntryInfo $entry
    }
}

# Offers every selected harness (via getHarnessDescriptors) that has a 'pickerKey' property.
function getHarnessPickerOptions {
    $options = [ordered]@{}
    foreach ($h in (getHarnessDescriptors)) {
        if ($h.pickerKey) { $options[$h.pickerKey] = $h.name }
    }
    return $options
}

function changeHarness($db, $entry) {
    $options = getHarnessPickerOptions

    clearConsole
    Write-Host "  Change harness: $(Split-Path $entry.planFile -Leaf)" -ForegroundColor Cyan
    Write-Host ''
    Write-Host "  Current harness: $($entry.harness)"
    Write-Host ''
    $menu = ($options.GetEnumerator() | ForEach-Object { "[$($_.Key)] $($_.Value)" }) -join '  '
    Write-Host "  New harness:  $menu  [Esc] cancel"
    $key = readStateKey
    $newHarness = $options[$key.Key.ToString().ToUpper()]
    if ($newHarness -and $newHarness -ne $entry.harness) {
        $entry.harness = $newHarness
        saveDb $db $dbPath
    }
}

# Writes the plan's workflow and, on the transition into branch-review, prompts for the commit grant
# (the grant persists in frontmatter, so it's only re-prompted on that transition). Shared by the
# main list's W screen and the launch picker's inline W field.
function writeWorkflow([string] $planFile, [string] $cwd, [string] $workflow) {
    $null = Set-PlanState -PlanFile $planFile -Workflow $workflow
    if ($workflow -eq 'branch-review') { setCommitGrant $planFile $cwd }
}

function changeWorkflow($db, $entry) {
    clearConsole
    Write-Host "  Change workflow: $(Split-Path $entry.planFile -Leaf)" -ForegroundColor Cyan
    Write-Host ''
    Write-Host "  Current workflow: $((Get-PlanState -PlanFile $entry.planFile).Workflow)"
    Write-Host ''
    Write-Host '  New workflow:  [T] tick-tock  [S] step-review  [B] branch-review  [Esc] cancel'
    $key = readStateKey
    $newWorkflow = switch ($key.Key) {
        'T' { 'tick-tock' }
        'S' { 'step-review' }
        'B' { 'branch-review' }
        default { $null }
    }
    if (-not $newWorkflow) { return }

    writeWorkflow $entry.planFile $entry.cwd $newWorkflow
}

# Prompts for the commit-grant's branch and repos. The branch default comes from what $cwd has
# checked out (inference), but is only ever written once the user confirms it by pressing Enter or
# types an override — the grant itself is always stated, never inferred outright. No branch (no
# default, nothing typed) writes no grant at all.
function setCommitGrant([string] $planFile, [string] $cwd) {
    $defaultBranch = if ($cwd) { getRepoBranch $cwd } else { $null }
    Write-Host ''
    $branchPrompt = if ($defaultBranch) { "  Branch [$defaultBranch]" } else { '  Branch' }
    $branch = Read-Host $branchPrompt
    if (-not $branch) { $branch = $defaultBranch }
    if (-not $branch) { return }

    $reposRaw = Read-Host '  Repos (comma-separated, e.g. prefs, prat)'
    $repos = @($reposRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    $null = Set-PlanState -PlanFile $planFile -CommitBranch $branch -CommitRepos $repos
}

# Which of the three ways of working the plan runs in decides where a run ends: tick-tock hands back
# at each phase boundary, step-review and branch-review carry on through it. An absent or
# unrecognized `workflow` is tick-tock — loosening what a session may do needs a value we recognize.
function endsRunAtPhaseBoundary([string] $workflow) {
    return $workflow -notin @('step-review', 'branch-review')
}

# The opening prompt for a fresh launch, keyed by phase — the word `getLaunchAction` derives from
# state, or the fixed phase `P` (`plan`) and `D` (`discuss`) launch with. `review` names the stored
# state and asks the agent to get oriented on the recent context before waiting; `discuss` asks it
# to read the plan and wait for questions, changing nothing about where the plan stands.
function getLaunchPrompt([string] $phase, [string] $planFile, [string] $workflow, [string] $state, [switch] $Headless) {
    $prompt = switch ($phase) {
        'plan'      { "Please work out what the steps should be in $planFile" }
        'refine'    {
            if (endsRunAtPhaseBoundary $workflow) { "Please refine the next step in $planFile" }
            else { "Please refine (if needed) and implement the next step in $planFile" }
        }
        'implement' { "Please do the next step in $planFile" }
        'review'    {
            "The plan, $planFile, is in $state state. Please read the plan, check you know where the recent context is, e.g. the last session and which commits in repos, then wait for the user's prompt."
        }
        'discuss'   { "Let's discuss the plan, $planFile. Please read it and then wait for my questions" }
        default     { throw "Unknown launch phase '$phase'" }
    }
    if ($Headless -and $phase -in @('refine', 'implement')) { return $prompt + ' ' + (getHeadlessSessionInstruction) }
    return $prompt
}

# The one-step contract for a headless launch: a run is one step per session, so the session does the
# pointed-at step, wraps it in-session, and ends the turn - the loop reads the frontmatter it writes
# and launches the next step. Its closing text is only recovered from the session log unless the run
# report carries it, so it should name the reason it stopped, not narrate the work.
function getHeadlessSessionInstruction {
    return "This session is headless and works exactly one step: do the step the plan points at, then wrap it " +
           "in-session (mark its items done and advance the pointer). Do not start the next step. In branch-review, " +
           "the close is: set the state to ready-for-user-review, then invoke /wrap (the close arm cuts the step to " +
           "the done file and advances the pointer). A design step's deliverable is the design itself — once it is " +
           "written into the step body, the step is done; if it has an implement half, record it in the step body as " +
           "a follow-up. End the turn with a short closing message naming what you stopped on if anything went wrong."
}
# The fresh row's label: what a phase-driven launch key will actually do, so the row doubles as the
# check that the plan is in the state you thought, rather than a name you have to look up.
function getFreshRowPhaseLabel([string] $phase, [string] $nextStep, [string] $workflow) {
    $workflowName = if ($workflow) { $workflow } else { 'tick-tock' }
    if ($nextStep) { return "$phase $nextStep · $workflowName" }
    return "$phase · $workflowName"
}

# Pure dispatch for opening a plan: plan state + session availability → what to do.
# kind 'fresh' launches a new session; kind 'resume' opens the session picker. .intent is the phase
# Enter's fresh row launches into — `P` and `D` override it with their own fixed phase instead.
# A file with no steps yet has nothing to refine, so it defaults to working the steps out;
# missing or unrecognized state on a file that has them is treated as ready-to-refine.
function getLaunchAction($planState, [bool] $hasResumableSessions) {
    $intent = switch ($planState.State) {
        'ready-to-implement'    { 'implement' }
        'ready-for-user-review' { 'review' }
        'ready-to-refine'       { 'refine' }
        # The user's checkpoint in tick-tock. Where the agent carries on past that boundary, this
        # state can only mean a session refined the step and stopped, so the default continues.
        'ready-for-refined-step-review' {
            if (endsRunAtPhaseBoundary $planState.Workflow) { 'review' } else { 'implement' }
        }
        default                 { if ($planState.HasSteps) { 'refine' } else { 'plan' } }
    }
    $kind = if ($hasResumableSessions) { 'resume' } else { 'fresh' }
    return @{ kind = $kind; intent = $intent }
}

# By creating our own guid for fresh sessions, we can identify the corresponding process later.
# Mutates $entry.sessionIds so the new session is tracked immediately, without waiting for the next command-line scan.
function getFreshSessionArgs([string] $harness, $entry) {
    if ($harness -eq 'copilot') { return ,@() }
    $sid = [guid]::NewGuid().ToString()
    $entry.sessionIds = @($entry.sessionIds) + @($sid)
    return ,@('--session-id', $sid)
}

# Which picker row Enter starts on. Once a launch has worked on this unit its sessions are spent —
# the count is cleared when the pointer moves, so a non-zero one means "since this unit". The review
# states are the exception: the session under review is the one that refined the step or did the work.
function defaultsToFreshPicker([string] $state, [int] $launches) {
    if ($state -in @('ready-for-user-review', 'ready-for-refined-step-review')) { return $false }
    return $launches -gt 0
}

# Session GUIDs in the rows don't identify the plan, and openUntracked shares the bare 'Open plan'
# title — disambiguate by naming the plan in the title line instead.
function getSessionPickerTitle([string] $planFile) {
    $name  = Split-Path $planFile -Leaf
    $title = getPlanTitle $planFile
    if ($title) { return "$name — $title" }
    return $name
}

# Whether a non-zero exit from a resumed session means the harness refused the resume, as opposed to
# running and then dying: a session that worked for an hour before hitting a provider error exits
# non-zero too, and that is the one most worth resuming again. A refused resume never writes to the
# session log, so the log's last-active time against the launch instant is the discriminator.
function resumeWasRefused($entry, [string] $sid, [datetime] $launchedAt) {
    $info = @(getSessionInfos @($sid) -harness $entry.harness) | Select-Object -First 1
    if (-not $info) { return $true }
    return $info.lastActive -le $launchedAt
}

# One row of the launch picker. A session row is its short id, its start→last-active times, and what
# it accomplished (its closing statement, or its first prompt when it never answered); the fresh row
# carries the phase label (what a launch key will do) and, when the harness has a model list, the
# cyclable model (‹ ›, i.e. ←/→).
function buildLaunchRowLabel($row) {
    if ($row.kind -ne 'fresh') {
        $text = if ($row.info.accomplished) { $row.info.accomplished } else { $row.info.summary }
        # The text is a full sentence or report, not a title — collapse its newlines so the row stays
        # one line (a raw newline would break the picker's per-line rendering).
        $text = (($text -split '\s+') -join ' ')
        $when = "$($row.info.lastActive.ToString('yyyy-MM-dd HH:mm'))"
        if ($row.info.startedAt) { $when = "$($row.info.startedAt.ToString('yyyy-MM-dd HH:mm')) → $when" }
        return "$(getShortId $row.info.sid)  $when  $text"
    }
    if (-not $row.modelList) { return "(start fresh session)   $($row.phaseLabel)   $($row.harness)" }
    $choice     = $row.modelList[$row.modelIndex]
    $modelLabel = if ($choice.model) { "$($choice.displayName)  (cost x$($choice.relativeCost))" } else { $choice.displayName }
    return "(start fresh session)   $($row.phaseLabel)   $($row.harness): $modelLabel  ‹ ›"
}

# The short form of a session id: its first 8 characters, the form a user names sessions by. A
# shorter id passes through unchanged.
function getShortId([string] $sid) {
    if ($sid.Length -le 8) { return $sid }
    return $sid.Substring(0, 8)
}

# $launchKey is which of the three launch keys opened this: 'Enter' dispatches on the state's own
# phase (via getLaunchAction); 'P' and 'D' fix the phase regardless of state — work the steps out, or
# open a discussion. Only 'D' also changes the machinery: it never offers to resume, since it's
# a way to talk about the plan, not to continue whatever a live session was doing.
function openProject($db, $entry, $liveSessionIds, [string] $launchKey = 'Enter') {
    if (isLive $entry $liveSessionIds) {
        Write-Host 'A session is already live for this plan — switch to it instead.' -ForegroundColor Yellow
        $null = Read-Host 'Press Enter to return'
        return $false
    }

    $planState   = Get-PlanState -PlanFile $entry.planFile
    $offerResume = $launchKey -ne 'D'
    $infos  = if ($offerResume) { @(getSessionInfos $entry.sessionIds -harness $entry.harness) } else { @() }
    $action = getLaunchAction $planState ($infos.Count -gt 0)
    $phase  = switch ($launchKey) {
        'P'     { 'plan' }
        'D'     { 'discuss' }
        default { $action.intent }
    }

    # Every fresh launch goes through the picker (a single "(start fresh session)" row when there
    # are no sessions), so the inline fields below are always reachable. The row carries the entry
    # and db plus the cyclable workflow/harness fields, so the picker's key handler can change them
    # in place and persist — the same pattern as the model field.
    $workflowList = @('tick-tock', 'step-review', 'branch-review')
    $effectiveWorkflow = if ($planState.Workflow) { $planState.Workflow } else { 'tick-tock' }
    $harnessPicker  = getHarnessPickerOptions
    $harnessOptions = @($harnessPicker.Values)
    $harnessIndex   = $harnessOptions.IndexOf($entry.harness)
    if ($harnessIndex -lt 0) { $harnessIndex = 0 }
    $freshRow = @{ kind = 'fresh'; harness = $entry.harness
                   phaseLabel = getFreshRowPhaseLabel $phase $planState.First $effectiveWorkflow
                   entry = $entry; db = $db; phase = $phase; nextStep = $planState.First
                   workflowList = $workflowList; workflowIndex = $workflowList.IndexOf($effectiveWorkflow)
                   harnessList = $harnessOptions; harnessIndex = $harnessIndex }
    $modelList = getModelList $entry.harness
    if ($modelList) {
        # Start on <default> (the last entry) — no --model arg, matching today's behavior.
        $freshRow.modelList  = $modelList
        $freshRow.modelIndex = $modelList.Count - 1
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    if ($offerResume -and $action.kind -eq 'resume') {
        foreach ($info in ($infos | Select-Object -First 3)) { $rows.Add(@{ kind = 'session'; info = $info }) }   # older sessions stay in the db, unshown
    }
    $rows.Add($freshRow)
    $initial = if ($offerResume -and $action.kind -eq 'resume' -and -not (defaultsToFreshPicker $planState.State $entry.launches)) { 0 } else { $rows.Count - 1 }

    $idx = pickFromList $rows { param($r) buildLaunchRowLabel $r } `
        (getSessionPickerTitle $entry.planFile) $initial { param($item, $key) handleFreshRowKey $item $key }
    if ($null -eq $idx) { return $false }

    # Both paths below spend a session on this unit. The count is how the next launch knows the
    # sessions it can offer have already worked on it — the launcher's only per-unit fact, so it
    # lives in the db entry rather than the plan file (writing the plan would dirty a granted tree).
    # Persist it now: the clean-resume path below returns without saving anything else.
    $entry.launches++
    saveDb $db $dbPath
    clearRunReport
    if ($rows[$idx].kind -eq 'session') {
        $picked     = $rows[$idx].info
        $resumeArgs = getResumeArgs $entry.harness $picked.sid
        $launchedAt = Get-Date
        $exitCode   = launchCl $entry.harness $entry.cwd $entry.planFile @resumeArgs
        if ($exitCode -ne 0) {
            # No console clear: the harness printed why it failed, and that is the useful part.
            if (resumeWasRefused $entry $picked.sid $launchedAt) {
                $entry.sessionIds = @($entry.sessionIds | Where-Object { $_ -ne $picked.sid })
                saveDb $db $dbPath
                Write-Host "Resume failed (cl exit $exitCode) — session $($picked.sid) dropped from this plan." -ForegroundColor Yellow
            } else {
                Write-Host "Session $($picked.sid) exited with code $exitCode — kept, it was running." -ForegroundColor Yellow
            }
            $null = Read-Host 'Press Enter to return'
        }
        return $true
    }

    # fresh row picked
    $freshPick   = $rows[$idx]
    $freshModel  = if ($freshPick.modelList) { $freshPick.modelList[$freshPick.modelIndex].model } else { $null }
    $modelArgs   = getModelArgs $freshModel

    # A fresh dispatch into refine/implement, on branch-review with a headless-capable harness, hands
    # off to the unattended run instead of a single launch — see isBranchReviewLoopable.
    if (isBranchReviewLoopable $planState.Workflow $phase $entry.harness $planState.Automatable $planState.First) {
        $entry.cwd = normalizePath $PWD.Path
        saveDb $db $dbPath
        runBranchReviewRun $db $entry $modelArgs
        return $true
    }

    $sessionArgs = getFreshSessionArgs $entry.harness $entry
    $prompt      = getLaunchPrompt $phase $entry.planFile $planState.Workflow $planState.State

    $entry.cwd = normalizePath $PWD.Path
    saveDb $db $dbPath
    $exitCode = launchCl $entry.harness $entry.cwd $entry.planFile @modelArgs @sessionArgs $prompt
    showLaunchError $exitCode
    return $true
}

# --- Branch-review run ---

# The `automatable` field's value as a set of step numbers: `$null` when the field is absent,
# `$true` for `*` (every step), or an array of ints for a specific set (ranges expanded). The parser
# in `PlanState.ps1` already validated the grammar, so this only handles the well-formed cases.
function parseAutomatableSteps([string] $raw) {
    if ($null -eq $raw -or $raw -eq '') { return $null }
    $v = $raw.Trim()
    if ($v -eq '*') { return $true }
    $set = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($item in ($v -split ',')) {
        $t = $item.Trim()
        if ($t -match '^(\d+)-(\d+)$') {
            $lo = [int]$matches[1]; $hi = [int]$matches[2]
            for ($n = $lo; $n -le $hi; $n++) { $null = $set.Add($n) }
        } else {
            $null = $set.Add([int]$t)
        }
    }
    return @($set)
}

# Whether the step named by `$stepHeading` is in the set named by `$automatable`. Absent field →
# nothing is automatable; `*` → everything is; a specific set → membership on the `Step N` number.
# A heading with no `Step N` prefix is never in the set.
function stepIsAutomatable([string] $automatable, [string] $stepHeading) {
    $set = parseAutomatableSteps $automatable
    if ($null -eq $set) { return $false }
    if ($set -is [bool]) { return $set }
    if ($stepHeading -match 'Step\s+(\d+)') { return $set -contains [int]$matches[1] }
    return $false
}

# Whether `Enter`, on this launch, should hand off to an unattended run of every remaining step
# instead of a single launch: only for a fresh dispatch into refine/implement (P and D fix their own
# phase regardless of state, and picking a session row is a human wanting to look at one session),
# only in `branch-review`, only when the current step is in the plan's `automatable` set (an absent
# field means no step is), and only for a harness that declares itself headless-capable — one with
# no such flag gets today's single launch (see harnessSupportsHeadless).
function isBranchReviewLoopable([string] $workflow, [string] $phase, [string] $harness, [string] $automatable, [string] $currentStep) {
    if ($workflow -ne 'branch-review') { return $false }
    if ($phase -notin @('refine', 'implement')) { return $false }
    if (-not (stepIsAutomatable $automatable $currentStep)) { return $false }
    return harnessSupportsHeadless (getHarnessDescriptor $harness)
}

# Whether the frontmatter that matters changed between two Get-PlanState reads, taken before and
# after one launch. A step that wrapped moves the pointer or its state (or both, e.g.
# refine-then-implement in one turn); a stalled one leaves both exactly where they were. A step
# closing also counts as progress on its own — a run that closes the whole plan has no next step to
# point at, so the pointer never moves and only the step headings give the signal away.
function planFrontmatterProgressed($before, $after) {
    foreach ($f in @('State', 'First', 'Last', 'Workflow', 'CommitBranch')) {
        if ($before.$f -ne $after.$f) { return $true }
    }
    if (@(Compare-Object @($before.Refined) @($after.Refined)))         { return $true }
    if (@(Compare-Object @($before.CommitRepos) @($after.CommitRepos))) { return $true }
    if (@(getStepsClosedByRun @($before.StepHeadings) @($after.StepHeadings))) { return $true }
    return $false
}
# Steps that closed between two reads of the plan's step headings — the report's real signal, not a
# launch counter. A wrap deletes the step's body from the plan (Set-PlanState -Advance finds the
# next step among the remaining headings), so a step present before the run but gone after it was
# completed; a step present in neither was never in this plan's scope, and one re-added in between
# was not a close. Matched by step id, so a rename mid-run still counts as the same step closing.
function getStepsClosedByRun([string[]] $before, [string[]] $after) {
    $afterIds = @($after) | ForEach-Object { Get-PlanStepId $_ } | Select-Object -Unique
    return @($before | Where-Object { $afterIds -notcontains (Get-PlanStepId $_) })
}

# Checked before spending a launch: budgets, and whether there's anything an unattended run can still
# do. A missing or stepless plan is finished — the file is gone, or /wrap cut the last step's body and
# nothing is left to point at — and both read as completion. $phase is what getLaunchAction derived for
# the state this iteration read — 'review' is the user's checkpoint, which a run with nobody watching
# can't cross on its own. The 50-launch/12-hour figures are a backstop against a run that keeps moving
# without getting anywhere, not a limit a well-behaved run should meet.
function getPreflightStopReason([bool] $planFileExists, [bool] $hasSteps, [string] $phase, [int] $launchCount, [double] $elapsedHours) {
    if (-not $planFileExists)   { return 'the plan finished' }
    # Same reason for a stepless plan: /wrap on the last step lands it at ready-for-user-review, which
    # maps to phase `review` — indistinguishable from the user's checkpoint without this check.
    if (-not $hasSteps)         { return 'the plan finished' }
    if ($phase -eq 'review')    { return 'the next step needs your review' }
    if ($launchCount -ge 50)    { return 'hit the 50-launch budget' }
    if ($elapsedHours -ge 12)   { return 'hit the 12-hour budget' }
    return $null
}

# Checked after a launch returns: whether the run can safely spend another one. A non-zero exit
# outranks a stalled read — the crash is the more useful reason to report. A timed-out launch
# outranks both: the session was killed for exceeding its own per-launch cap, which is a different
# failure than one that crashed on its own. The sentinel arrives from waitLaunchProcess via the loop.
function getPostflightStopReason([int] $exitCode, [bool] $progressed, [string] $lastSessionId = '', [int] $timeoutCode = 0) {
    if ($exitCode -eq $timeoutCode -and $timeoutCode -ne 0) { return "session $lastSessionId timed out and was killed" }
    if ($exitCode -ne 0)  { return "the session exited with code $exitCode" }
    if (-not $progressed) { return 'the step made no progress' }
    return $null
}

# The last assistant_text a session logged, or $null when the log is missing or has none. A
# completed headless turn ends on its closing assistant_text, so this is what the session said when
# it stopped — the only place a deliberately-stopped run records its reason if the run report doesn't
# carry it (see the plan step for the log tail shape it relies on).
function getSessionFinalText([string] $logPath) {
    if (-not (Test-Path -LiteralPath $logPath)) { return $null }
    $text = $null
    foreach ($line in (Get-Content -LiteralPath $logPath)) {
        if (-not $line.Trim()) { continue }
        try { $event = $line | ConvertFrom-Json } catch { continue }
        if ($event.type -eq 'assistant_text' -and $event.content) { $text = [string] $event.content }
    }
    return $text
}

function getRunReportPath { return "$home/prat/auto/context/plan-run-report.json" }

function newRunReport([string] $planFile, [string[]] $stepsClosed, [string] $stopReason, [string] $lastSessionId, [string] $sessionFinalText = '') {
    return [pscustomobject]@{
        planFile         = $planFile
        stepsClosed      = @($stepsClosed)
        stopReason       = $stopReason
        lastSessionId    = $lastSessionId
        sessionFinalText = $sessionFinalText
        finishedAt       = (Get-Date -Format 'o')
    }
}

function writeRunReport($report, [string] $path = (getRunReportPath)) {
    $null = New-Item -ItemType Directory -Path (Split-Path $path) -Force
    $report | ConvertTo-Json | Set-Content $path -Encoding UTF8
}

function readRunReport([string] $path = (getRunReportPath)) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return Get-Content $path -Raw | ConvertFrom-Json } catch { return $null }
}

# Dismissed by the next launch, whatever it launches — called from openProject right where a picked
# row already spends a session on the unit (its db-entry launch count is bumped), so an escaped picker
# doesn't clear it, and navigating the list or quitting pl doesn't either.
function clearRunReport([string] $path = (getRunReportPath)) {
    Remove-Item -LiteralPath $path -ErrorAction Ignore
}

# Lines to print above the launcher list for the last run's outcome — pl's own list otherwise shows
# no sign a run just finished several steps unattended.
function getRunReportLines($report) {
    if (-not $report) { return @() }
    $lines = @(
        "  ⚑ $(Split-Path $report.planFile -Leaf): $(getRunReportLead $report.stepsClosed) — $($report.stopReason)"
        "     last session: $($report.lastSessionId)"
    )
    # A run that closed nothing and stopped on purpose leaves its reason only here - the session's
    # own closing text, recovered from its log, so "nothing advanced" doesn't read as a stall. When
    # steps closed, the commit carries the detail, so the closing message is noise.
    $closed = @($report.stepsClosed | Where-Object { $_ })
    if ($closed.Count -eq 0 -and $report.sessionFinalText) {
        $lines += "     session said: $($report.sessionFinalText)"
    }
    return $lines
}

# The steps a run closed, as a compact "Step N" list for display — or 'no steps closed' when it
# closed none. The report lines and the notification both lead with it, so it lives here once.
function getRunReportLead([string[]] $stepsClosed) {
    # A report written before the steps-closed field existed reads back as $null for it, and
    # @($null) is a one-element array — drop empties so it renders as "no steps closed", not
    # "closed (blank)".
    $closed = @($stepsClosed | Where-Object { $_ })
    if ($closed.Count -eq 0) { return 'no steps closed' }
    $labels = $closed | ForEach-Object { $_ -replace '^(Step\s+[^\s:]+).*$', '$1' }
    return "closed $($labels -join ', ')"
}

# One notification for the whole run, in place of the per-step one a headless launch no longer sends
# (see prigApp.run) — otherwise an unwatched run fires one identical "done" per step, with the actual
# outcome hidden among them. Absent (same as On-AgentTurnCompleted.ps1's own guard) for non-de users /
# machines with no notification command installed.
function sendRunNotification($report) {
    if (!(Get-Command 'Send-UserNotification' -ErrorAction Ignore)) { return }
    $name = Split-Path $report.planFile -Leaf
    Send-UserNotification "$($name): $(getRunReportLead $report.stepsClosed), $($report.stopReason)" 'prat'
}

# The loop: one headless launch per step, until a stop condition fires. Every launch is fresh (its
# own --session-id via getFreshSessionArgs) — nothing in a run is resumed, so a step that needs a
# human is left for them to pick up interactively afterward. Runs entirely inside this one Enter; pl's
# own TUI doesn't redraw between steps, which is why the outcome goes to a report file
# (getRunReportLines) instead of being visible in how the list looks afterward.
function runBranchReviewRun($db, $entry, [string[]] $modelArgs) {
    $startedAt     = Get-Date
    $runStart      = if (Test-Path -LiteralPath $entry.planFile) { @((Get-PlanState -PlanFile $entry.planFile).StepHeadings) } else { @() }
    $launches      = 0
    $lastSessionId = $null
    $stopReason    = $null

    while ($true) {
        $planFileExists = Test-Path -LiteralPath $entry.planFile
        $planState      = if ($planFileExists) { Get-PlanState -PlanFile $entry.planFile } else { $null }
        $phase          = if ($planState) { (getLaunchAction $planState $false).intent } else { $null }
        $elapsedHours   = ((Get-Date) - $startedAt).TotalHours

        $stopReason = getPreflightStopReason $planFileExists ([bool]$planState.HasSteps) $phase $launches $elapsedHours
        if ($stopReason) { break }
        # A step outside the plan's `automatable` set is a design step a headless run must not do
        # alone (the 2026-09-22 Step 18 case). An absent field means nothing is automatable, so a
        # plan that never declared it stops here rather than sailing through.
        if (-not (stepIsAutomatable $planState.Automatable $planState.First)) {
            $stopReason = "step '$($planState.First)' is not automatable"
            break
        }
        $grantProblem = commitGrantRefusedReason $entry.planFile
        if ($grantProblem) { $stopReason = "commit grant refused: $grantProblem"; break }

        $sessionArgs   = getFreshSessionArgs $entry.harness $entry
        $lastSessionId = @($entry.sessionIds)[-1]
        $prompt        = getLaunchPrompt $phase $entry.planFile $planState.Workflow $planState.State -Headless
        $headlessArgs  = getHeadlessArgs (getHarnessDescriptor $entry.harness)

        $entry.launches++
        saveDb $db $dbPath

        $exitCode = launchCl $entry.harness $entry.cwd $entry.planFile -Unattended @modelArgs @sessionArgs @headlessArgs $prompt
        $launches++

        $after      = Get-PlanState -PlanFile $entry.planFile
        $progressed = planFrontmatterProgressed $planState $after

        # A timed-out launch is named by the session that was killed for it — its id is the only
        # handle to that session's log, so the run's report must carry it.
        $stopReason = getPostflightStopReason $exitCode $progressed $lastSessionId (getLaunchTimeoutCode)
        if ($stopReason) { break }
    }

    # The report names what the run actually closed, read from the plan's end state — a launch
    # counter under-reports a launch that closes several steps (a batched unit) and over-reports one
    # that closed none. A step closes when its body leaves the plan, which /wrap does on the close.
    $endHeadings = if (Test-Path -LiteralPath $entry.planFile) { @((Get-PlanState -PlanFile $entry.planFile).StepHeadings) } else { @() }
    $stepsClosed = getStepsClosedByRun $runStart $endHeadings
    # The last session's closing text is its only record of a deliberate stop - a run that advanced
    # nothing reads as "stuck" without it, so the report carries it when the log has one.
    $descriptor = getHarnessDescriptor $entry.harness
    $finalText  = if ($lastSessionId -and $descriptor.sessionsDir) { getSessionFinalText "$($descriptor.sessionsDir)/$lastSessionId.jsonl" } else { $null }
    $report = newRunReport $entry.planFile $stepsClosed $stopReason $lastSessionId $finalText
    writeRunReport $report
    sendRunNotification $report
}

$script:savedConsoleInMode  = $null
$script:savedConsoleOutMode = $null

function initLpConsoleType {
    if ($null -eq ('LpConsole' -as [type])) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
public class LpConsole {
    public const int STD_INPUT_HANDLE  = -10;
    public const int STD_OUTPUT_HANDLE = -11;
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool SetConsoleCtrlHandler(IntPtr HandlerRoutine, bool Add);
}
"@
    }
}

function saveConsoleMode {
    # Call once before the TUI starts to capture the pristine console mode.
    initLpConsoleType
    $hIn  = [LpConsole]::GetStdHandle([LpConsole]::STD_INPUT_HANDLE)
    $hOut = [LpConsole]::GetStdHandle([LpConsole]::STD_OUTPUT_HANDLE)
    $mIn = 0u; $mOut = 0u
    [LpConsole]::GetConsoleMode($hIn,  [ref]$mIn)  | Out-Null
    [LpConsole]::GetConsoleMode($hOut, [ref]$mOut) | Out-Null
    $script:savedConsoleInMode  = $mIn
    $script:savedConsoleOutMode = $mOut
}

function resetConsoleMode {
    # Restore the exact console mode from before the TUI started, and flush any
    # stale key events left in the input buffer by the TUI loop.
    if ($null -eq $script:savedConsoleInMode) { return }
    initLpConsoleType
    $hIn  = [LpConsole]::GetStdHandle([LpConsole]::STD_INPUT_HANDLE)
    $hOut = [LpConsole]::GetStdHandle([LpConsole]::STD_OUTPUT_HANDLE)
    [LpConsole]::SetConsoleMode($hIn,  $script:savedConsoleInMode)  | Out-Null
    [LpConsole]::SetConsoleMode($hOut, $script:savedConsoleOutMode) | Out-Null
}

# --- Commit grant ---

# One `commit-grant` repos entry as a path: a prat repo id, or a path of its own when it contains a
# separator or a leading '~' — the same vocabulary `c` uses. $null for an id the repo index doesn't know.
function resolveCommitRepoPath([string] $entry) {
    if ($entry -match '[\\/]' -or $entry.StartsWith('~')) { return normalizePath (Expand-TildePath $entry) }
    $root = Get-PratRepoRoot $entry
    if (-not $root) { return $null }
    return normalizePath $root
}

# Thin wrapper (mockable in tests) over the branch query. $null when the path is no git working tree,
# or is one with no branch checked out.
function getRepoBranch([string] $repoPath) {
    $branch = & git -C $repoPath branch --show-current 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $branch) { return $null }
    return @($branch)[0]
}

# Whether a local branch of that name exists there. `for-each-ref` also matches refs/heads/<branch>/...,
# so the name is compared whole.
function repoHasBranch([string] $repoPath, [string] $branch) {
    $found = & git -C $repoPath for-each-ref --format='%(refname:short)' "refs/heads/$branch" 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    return @($found) -contains $branch
}

function resolveCommitGrant($planState) {
    if (-not $planState.CommitBranch) { return $null }
    $branch   = $planState.CommitBranch
    $paths    = @()
    $problems = @()
    $pending  = @()
    foreach ($entry in @($planState.CommitRepos)) {
        $path = resolveCommitRepoPath $entry
        if (-not $path) { $problems += "'$entry' is neither a registered repo id nor a path"; continue }
        $paths += $path
        $onBranch = getRepoBranch $path
        if (-not $onBranch)            { $problems += "$path has no branch checked out (no git working tree there, or a detached HEAD)" }
        elseif ($onBranch -ne $branch) {
            # A repo still on 'main' with no branch of that name is one the session can create it in, so the
            # grant holds. Anything else — a third branch, or that branch existing but not checked out — is
            # the user's to sort out. 'main' is where every repo here cuts branches from.
            if ($onBranch -eq 'main' -and -not (repoHasBranch $path $branch)) { $pending += $path }
            else { $problems += "$path is on '$onBranch', not '$branch'" }
        }
    }
    if ($paths.Count -eq 0 -and $problems.Count -eq 0) { $problems += 'the grant names no repos' }
    return @{ branch = $branch; repoPaths = $paths; problems = $problems; pending = $pending }
}

# cl tokens for a grant, in the colon form with the values already quoted: buildClCommandLine quotes
# each non-flag token on its own, so a multi-value parameter has to arrive as a single token to reach
# cl as an array rather than as one value plus a stray positional.
function getCommitGrantArgs($grant) {
    if (-not $grant -or @($grant.problems).Count -gt 0) { return @() }
    $repoList = (@($grant.repoPaths) | ForEach-Object { quoteClValue $_ }) -join ','
    return @("-CommitBranch:$(quoteClValue $grant.branch)", "-CommitRepo:$repoList")
}

# The grant tokens for this launch, or none. A declared grant whose repos don't qualify prints and
# pauses: the session still starts, without commit rights, and fixing it — check the branch out, or
# edit the frontmatter — is the user's. A repo still waiting for the branch keeps the grant, but pauses
# to notify the user. -NoPause is for an unattended run (runBranchReviewRun): it still prints, but
# never blocks on the console — the run itself decides what a refused grant means (see
# commitGrantRefusedReason), and a pending one is a normal state a headless session can act on.
function getLaunchCommitGrantArgs([string] $planFile, [switch] $NoPause) {
    $grant = resolveCommitGrant (Get-PlanState -PlanFile $planFile)
    if (-not $grant) { return @() }
    if (@($grant.problems).Count -gt 0) {
        Write-Host ''
        Write-Host '  ⚠ commit-grant not honored — this session gets no commit rights:' -ForegroundColor Yellow
        foreach ($problem in $grant.problems) { Write-Host "      $problem" -ForegroundColor Yellow }
        if (-not $NoPause) { $null = Read-Host '  Press Enter to launch anyway' }
    } elseif (@($grant.pending).Count -gt 0) {
        Write-Host ''
        Write-Host "  ℹ commit-grant honored; '$($grant.branch)' doesn't exist everywhere yet:" -ForegroundColor Cyan
        # Whether the session can act on it depends on the harness: one with a branch-creating tool makes
        # the branch, one told about the grant in prose can't, and can't commit there until someone does.
        foreach ($path in $grant.pending) {
            Write-Host "      $path is on 'main'; the session creates it there if its harness can" -ForegroundColor Cyan
        }
        if (-not $NoPause) { $null = Read-Host '  Press Enter to launch' }
    }
    return getCommitGrantArgs $grant
}

# The reason an unattended run can't proceed with this launch's commit grant, or $null when it can
# (every repo qualifies, or a repo is merely pending a branch create — a headless session can still
# make progress there). A launch with no grant at all is refused too: without one the session can't
# do the one thing branch-review exists for, and it would otherwise sail through the preflight and
# stop at the end having advanced nothing. Checked before spending a launch.
function commitGrantRefusedReason([string] $planFile) {
    $grant = resolveCommitGrant (Get-PlanState -PlanFile $planFile)
    if (-not $grant) { return 'no commit grant declared' }
    if (@($grant.problems).Count -eq 0) { return $null }
    return ($grant.problems -join '; ')
}

# --- Launching ---

# pl clears the console right before launching, so a cursor not at (0,0) when the child pwsh
# reaches `& cl` means its profile load printed something above — pause so it can be read before
# `cl`'s own UI overwrites it. -Unattended (a run nobody is watching) skips the guard entirely: a
# pause with nobody to answer it would hang the run forever.
function getCursorGuardScript([switch] $Unattended) {
    if ($Unattended) { return '' }
    return '$__pos = [Console]::CursorLeft, [Console]::CursorTop; if ($__pos[0] -ne 0 -or $__pos[1] -ne 0) { Read-Host "Startup output above - press Enter to continue" }'
}

# One value in the `& cl` command line: double-quoted, with any embedded quote doubled, which is the
# escape pwsh's parser takes when it reassembles the command string.
function quoteClValue([string] $value) { return '"' + ($value -replace '"', '""') + '"' }

# The `& cl ...` command line. A token starting with '-' passes through verbatim — it is a parameter
# name, or a colon-form parameter carrying its own quoting; anything else is one quoted value.
function buildClCommandLine([string[]] $clArgs) {
    $argStr = ($clArgs | ForEach-Object { if ($_.StartsWith('-')) { $_ } else { quoteClValue $_ } }) -join ' '
    if ($argStr) { return "& cl $argStr" }
    return '& cl'
}

# The whole script the child pwsh runs: the cursor guard, the cl call, and an explicit exit so the
# child's status reaches pl. pwsh adopts $LASTEXITCODE as its own exit code only when the
# -EncodedCommand script ends on a native command, and cl ends on PowerShell (its finally blocks), so
# without this a harness that printed an error and exited non-zero arrives as a clean 0: pl says
# nothing and its next redraw wipes the message. $LASTEXITCODE is $null when no native command ran at
# all, and `exit $null` is 0.
function buildChildCommand([string[]] $clArgs, [switch] $Unattended) {
    return "$(getCursorGuardScript -Unattended:$Unattended); $(buildClCommandLine $clArgs); " + 'exit $LASTEXITCODE'
}

# The exit code a timed-out launch reports. Exposed so the loop can compare against it rather than
# spelling the magic number; it is the same value launchCl's wait helper returns.
function getLaunchTimeoutCode { return $script:launchTimeoutSentinel }

# The per-launch wall-clock cap a launch is given, in seconds: the full cap for an unattended launch
# (a branch-review step nobody is watching, where a wedged session would otherwise hold the run open)
# and 0 for an interactive one (wait for as long as the user's session needs). 0 is the sentinel the
# wait helper reads as "no cap".
function getLaunchTimeoutSeconds([switch] $Unattended) {
    if ($Unattended) { return $script:branchReviewLaunchTimeoutSeconds }
    return 0
}

# Wait for a launched child process to exit, or — when it outlives $timeoutSeconds — kill its whole
# process tree and report the timeout sentinel. Only a branch-review launch (nobody is watching, and
# a wedged session would otherwise hold the run open with nothing on screen) passes a timeout; an
# interactive launch waits forever. The tree kill, not a bare Kill, matters: the child's own session
# may have spawned grandchildren (a local model server, a shell) that a single-process kill leaves
# running. The sentinel is returned instead of the child's real exit code — the child's, if any, is
# meaningless once its tree has been torn down.
function waitLaunchProcess($proc, [double] $timeoutSeconds) {
    if ($timeoutSeconds -le 0) { $proc.WaitForExit(); return $proc.ExitCode }
    if ($proc.WaitForExit([int]($timeoutSeconds * 1000))) { return $proc.ExitCode }
    try { $proc.Kill($true) } catch { }
    return $script:launchTimeoutSentinel
}

# -Unattended (a run nobody is watching — runBranchReviewRun) suppresses every console pause on this
# path: the cursor guard, and the commit-grant pauses inside getLaunchCommitGrantArgs.
function launchCl([string] $harness, [string] $cwd, [string] $planFile, [switch] $Unattended) {
    resetConsoleMode
    # Resolved before the clear below, so that a refused grant's message is still on screen when its
    # pause returns.
    $grantArgs = getLaunchCommitGrantArgs $planFile -NoPause:$Unattended
    # The picker's own menu is the last thing drawn on screen (pickFromList clears before
    # rendering, not after) so without this, getCursorGuardScript sees the cursor left wherever
    # the menu's last line landed and pauses even when the child's profile printed nothing.
    clearConsole
    # Use Start-Process -NoNewWindow so the child process inherits the console directly,
    # bypassing PowerShell's pipeline stdout/stderr capture which breaks interactive TUI apps.
    # Use -EncodedCommand (Base64) to avoid Windows command-line quoting issues: Start-Process
    # joins -ArgumentList with spaces without re-quoting, so inner quotes are stripped by argv
    # parsing before pwsh reassembles them for -Command. Base64 has no special characters.
    $clArgs   = getClExtraArgs $harness (@($grantArgs) + @($args))
    $encoded  = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes((buildChildCommand $clArgs -Unattended:$Unattended)))
    $spParams = @{ FilePath = 'pwsh'; ArgumentList = @('-NoLogo', '-EncodedCommand', $encoded); NoNewWindow = $true; PassThru = $true }
    if ($cwd) { $spParams.WorkingDirectory = $cwd }
    # CL_PLAN_FILE rides the process environment into cl — consumed by the statusline and skills'
    # active-plan default.
    $envToken = Set-EnvTemp @{ CL_PLAN_FILE = $planFile }
    try {
        # The child shares this console (-NoNewWindow), so a keyboard Ctrl-C is broadcast to every
        # process attached to it — including this pl process, blocked below in WaitForExit. Without
        # this, pwsh's own Ctrl-C handling can abort pl's own script execution the instant the user
        # interrupts the child's current turn, which then never returns control to pl. Ignoring it
        # here only affects this process; the child (and its own Ctrl-C handling, if any) is
        # unaffected.
        [LpConsole]::SetConsoleCtrlHandler([IntPtr]::Zero, $true) | Out-Null
        $proc = Start-Process @spParams
        return waitLaunchProcess $proc (getLaunchTimeoutSeconds -Unattended:$Unattended)
    } catch {
        return 1
    } finally {
        [LpConsole]::SetConsoleCtrlHandler([IntPtr]::Zero, $false) | Out-Null
        Restore-Env $envToken
        # The child inherited this same console (-NoNewWindow) and may have left its mode mutated —
        # e.g. a Python child's msvcrt-based input handling changes console mode flags that aren't
        # restored on exit. Reset again here so pl's own ReadKey-based loop resumes against a known
        # mode instead of whatever the child last set.
        resetConsoleMode
    }
}

# Thin wrapper so tests can mock it. Absent for non-de users / when the editor alias isn't
# installed — a no-op in that case, matching Get-AgentModelList's optional-command pattern.
function openInEditor([string] $path) {
    $cmd = Get-Command Open-FileInEditor -ErrorAction Ignore
    if ($cmd) { & $cmd $path }
}

function clearConsole   { [Console]::Clear() }        # thin wrapper so tests can mock it
function readStateKey   { [Console]::ReadKey($true) } # thin wrapper so tests can mock it
function readListKey    { [Console]::ReadKey($true) } # thin wrapper so tests can mock it
function getConsoleWidth { [Console]::WindowWidth }   # thin wrapper so tests can mock it

# Truncates $label to at most $width characters, ellipsis-terminated when it doesn't fit — so a
# long label gets shortened instead of the terminal line-wrapping it and breaking column alignment.
function truncateLabel([string] $label, [int] $width) {
    if ($width -le 0) { return '' }
    if ($label.Length -le $width) { return $label }
    if ($width -eq 1) { return $label.Substring(0, 1) }
    return $label.Substring(0, $width - 1) + '…'
}

function showLaunchError([int] $exitCode) {
    # Note: no console clear here — cl's own output is already visible; clearing would erase it.
    if ($exitCode -ne 0) {
        Write-Host "cl exited with code $exitCode" -ForegroundColor Red
        $null = Read-Host 'Press Enter to return'
    }
}

# Resumable-session lookup
function getSessionInfos($sessionIds, [string] $projectsRoot = "$home/.claude/projects", [string] $harness = 'claude') {
    $descriptor = getHarnessDescriptor $harness
    if ($descriptor -and $descriptor.sessionInfoStyle -eq 'claude-projects') { return getClaudeSessionInfos $sessionIds $projectsRoot }
    if ($descriptor -and $descriptor.sessionsDir) { return getFlatSessionInfos $sessionIds $descriptor.sessionsDir }
    return @()
}

# A session is resumable when its jsonl exists under the CC projects root (searching all project
# dirs avoids reimplementing CC's cwd→dirname rule; the files are sync-backed, so cross-machine
# sessions count too). Most-recent-first by jsonl mtime.
function getClaudeSessionInfos($sessionIds, [string] $projectsRoot) {
    $infos = @()
    foreach ($sid in @($sessionIds | Where-Object { $_ })) {
        $jsonl = @(Get-ChildItem -Path "$projectsRoot/*/$sid.jsonl" -File -ErrorAction Ignore) | Select-Object -First 1
        if (-not $jsonl) { continue }
        $infos += [pscustomobject]@{
            sid        = $sid
            lastActive = $jsonl.LastWriteTime
            summary    = getSessionSummary $jsonl
        }
    }
    return @($infos | Sort-Object lastActive -Descending)
}

# For harnesses whose sessions are in flat dir structure (no per-project
# subdirs, no sessions-index.json), so the lookup is a direct path check rather than a recursive
# search.
function getFlatSessionInfos($sessionIds, [string] $sessionsDir) {
    $infos = @()
    foreach ($sid in @($sessionIds | Where-Object { $_ })) {
        $jsonl = Get-Item -LiteralPath "$sessionsDir/$sid.jsonl" -ErrorAction Ignore
        if (-not $jsonl) { continue }
        $infos += [pscustomobject]@{
            sid          = $sid
            lastActive   = $jsonl.LastWriteTime
            startedAt    = getFlatSessionStart $jsonl
            summary      = getFlatSessionSummary $jsonl
            accomplished = getFlatSessionAccomplishment $jsonl
        }
    }
    return @($infos | Sort-Object lastActive -Descending)
}

# Session title for the picker: the first logged user_message event's content (truncated), or the
# session id when the log has none (e.g. a session that never completed a turn).
function getFlatSessionSummary($jsonlItem) {
    foreach ($line in (Get-Content -LiteralPath $jsonlItem.FullName)) {
        if (-not $line.Trim()) { continue }
        try { $event = $line | ConvertFrom-Json } catch { continue }
        if ($event.type -eq 'user_message' -and $event.content) {
            $content = [string] $event.content
            if ($content.Length -gt 60) { return $content.Substring(0, 57) + '...' }
            return $content
        }
    }
    return $jsonlItem.BaseName
}

# The session's start time: the first logged event's `ts`, local. A head read suffices — the first
# event is at the top of the file. $null when the log has no timestamped event (or the log is gone).
function getFlatSessionStart($jsonlItem) {
    foreach ($line in (Get-Content -LiteralPath $jsonlItem.FullName -TotalCount 5 -ErrorAction Ignore)) {
        if (-not $line.Trim()) { continue }
        try { $event = $line | ConvertFrom-Json } catch { continue }
        if ($event.ts) { return [datetime] $event.ts }
    }
    return $null
}

# The session's closing statement: the last assistant_text in the log — what it ended up saying, the
# "what this session accomplished" a picker row needs. It sits within the last ~75 lines of a real
# log, so the last 100 lines always contain it. Read the whole file and slice the last 100 in memory
# rather than using -Tail: a plain Get-Content is fast (≈10 ms on a 2.7 MB log) while Get-Content
# -Tail N is pathologically slow on these logs (≈1.2 s for -Tail 100, ~15 ms per requested line) —
# that was the pl launch/Enter hang, one slow -Tail per session. '' when there is none.
function getFlatSessionAccomplishment($jsonlItem) {
    $text = ''
    $tail = @(Get-Content -LiteralPath $jsonlItem.FullName -ErrorAction Ignore) | Select-Object -Last 100
    foreach ($line in $tail) {
        if (-not $line.Trim()) { continue }
        try { $event = $line | ConvertFrom-Json } catch { continue }
        if ($event.type -eq 'assistant_text' -and $event.content) { $text = [string] $event.content }
    }
    return $text
}

# Session title for picker display, from CC's sessions-index.json cache (may be missing or
# stale): summary → firstPrompt (truncated) → the session id.
function getSessionSummary($jsonlItem) {
    $indexPath = Join-Path $jsonlItem.DirectoryName 'sessions-index.json'
    $indexEntry = $null
    if (Test-Path -LiteralPath $indexPath) {
        try {
            $index = Get-Content $indexPath -Raw | ConvertFrom-Json
            $indexEntry = @($index.entries | Where-Object { $_.sessionId -eq $jsonlItem.BaseName }) | Select-Object -First 1
        } catch { }
    }
    if ($indexEntry -and $indexEntry.summary) { return $indexEntry.summary }
    if ($indexEntry -and $indexEntry.firstPrompt) {
        $fp = $indexEntry.firstPrompt
        if ($fp.Length -gt 60) { return $fp.Substring(0, 57) + '...' }
        return $fp
    }
    return $jsonlItem.BaseName
}

function getAvailablePlanFiles([string] $plansDir) {
    $base = normalizePath $plansDir
    return @(Get-ChildItem $plansDir -Filter '*.md' -File -Recurse |
        Where-Object {
            $rel      = (normalizePath $_.FullName).Substring($base.Length + 1)
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
            ($rel -notmatch '(^|/)(done|paused|waiting|later)/') -and ($baseName -notmatch '_(done|ref|background)$')
        } |
        Select-Object -ExpandProperty FullName |
        ForEach-Object { normalizePath $_ })
}

function openUntracked($db) {
    $plansDir = getPlansDir
    if (-not $plansDir) {
        Write-Host 'No plans directory configured — cannot open untracked plans.' -ForegroundColor Yellow
        $null = Read-Host 'Press Enter to return'
        return $false
    }
    $openPlans = @($db | ForEach-Object { $_.planFile })
    $available = @(getAvailablePlanFiles $plansDir |
        Where-Object { $_ -notin $openPlans })

    if ($available.Count -eq 0) {
        Write-Host 'No unopen plans found.' -ForegroundColor Yellow
        $null = Read-Host 'Press Enter to return'
        return $false
    }

    $base       = normalizePath $plansDir
    $maxNameLen = ($available | ForEach-Object { $_.Substring($base.Length + 1).Length } | Measure-Object -Maximum).Maximum
    $idx = pickFromList $available {
        param($p)
        $name  = (normalizePath $p).Substring($base.Length + 1)
        $title = getPlanTitle $p
        if ($title) { $name.PadRight($maxNameLen) + "  " + $title } else { $name }
    } 'Open plan'
    if ($null -eq $idx) { return $false }
    $planFile = $available[$idx]

    $entry = [pscustomobject]@{
        planFile   = $planFile
        cwd        = normalizePath $PWD.Path
        sessionIds = @()
        harness    = getDefaultHarness
        launches    = 0
        launchesFor = $null
    }
    $db.Add($entry)

    clearConsole
    return openProject $db $entry @()
}

function registerProject($db, $orphans, $liveSessionIds, $sessionHarness = @{}) {
    if ($orphans.Count -eq 0) {
        Write-Host 'No unregistered sessions.' -ForegroundColor Yellow
        $null = Read-Host 'Press Enter to return'
        return
    }

    $sidIdx = pickFromList $orphans { param($s) $s } 'Register — pick session'
    if ($null -eq $sidIdx) { return }
    $sid = $orphans[$sidIdx]
    $harness = if ($sessionHarness -and $sessionHarness[$sid]) { $sessionHarness[$sid] } else { getDefaultHarness }

    # Build plan list: tracked entries + untracked from plansDir
    $trackedPaths = @($db | ForEach-Object { $_.planFile })
    $allPlans     = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $db) { $allPlans.Add($e.planFile) }
    $plansDir = getPlansDir
    if ($plansDir) {
        getAvailablePlanFiles $plansDir |
            Where-Object { $_ -notin $trackedPaths } |
            ForEach-Object { $allPlans.Add($_) }
    }

    if ($allPlans.Count -eq 0) {
        Write-Host 'No plans found.' -ForegroundColor Yellow
        $null = Read-Host 'Press Enter to return'
        return
    }

    $planIdx = pickFromList $allPlans { param($p) Split-Path $p -Leaf } 'Register — pick plan'
    if ($null -eq $planIdx) { return }
    $planFile = $allPlans[$planIdx]

    $entry = $db | Where-Object { $_.planFile -eq $planFile } | Select-Object -First 1
    if (-not $entry) {
        $entry = [pscustomobject]@{
            planFile   = $planFile
            cwd        = normalizePath $PWD.Path
            sessionIds = @()
            harness    = $harness
            launches    = 0
            launchesFor = $null
        }
        $entry | Add-Member -NotePropertyName state -NotePropertyValue (Get-PlanState -PlanFile $planFile).State
        $db.Add($entry)
    } else {
        $entry | Add-Member -NotePropertyName harness -NotePropertyValue $harness -Force
    }

    if ($sid -notin $entry.sessionIds) {
        $entry.sessionIds = @($entry.sessionIds) + @($sid)
    }
    $null = $liveSessionIds.Add($sid)
    $orphans.Remove($sid) | Out-Null
    saveDb $db $dbPath
}

# $onKey (optional): called as `& $onKey $items[$selected] $key` for every key the picker doesn't
# handle itself, to mutate the selected item in place — e.g. cycling a field shown in its label.
# It returns whether it changed anything. Callers that don't pass it get those keys as no-ops.
function pickFromList($items, $labelFn, $title, [int] $initialSelected = 0, $onKey = $null) {
    $selected = [Math]::Min([Math]::Max(0, $initialSelected), @($items).Count - 1)
    $labels   = @($items | ForEach-Object { & $labelFn $_ })

    while ($true) {
        clearConsole
        Write-Host "  $title" -ForegroundColor Cyan
        Write-Host ''
        $width = getConsoleWidth
        for ($i = 0; $i -lt $labels.Count; $i++) {
            $prefix = if ($i -eq $selected) { '→ ' } else { '  ' }
            $fg     = if ($i -eq $selected) { 'White' } else { 'Gray' }
            $label  = truncateLabel $labels[$i] ([Math]::Max(0, $width - $prefix.Length))
            Write-Host "$prefix$label" -ForegroundColor $fg
        }
        Write-Host ''
        Write-Host '  [↑↓] navigate  [Enter] select  [Esc] cancel' -ForegroundColor DarkCyan

        $key = readListKey
        switch ($key.Key) {
            'UpArrow'    { $selected = if ($selected -gt 0) { $selected - 1 } else { [Math]::Max(0, $labels.Count - 1) } }
            'DownArrow'  { $selected = if ($selected -lt ($labels.Count - 1)) { $selected + 1 } else { 0 } }
            'Enter'      { return $selected }
            'Escape'     { return $null }
            # Labels are only re-derived here, after a mutation — not on every render — so callers
            # whose label function does real work (e.g. openUntracked's file-reading getPlanTitle)
            # don't pay for it on every Up/Down keystroke, only when something actually changed.
            default      { if ($onKey -and (& $onKey $items[$selected] $key)) { $labels = @($items | ForEach-Object { & $labelFn $_ }) } }
        }
    }
}

# --- Db ---

function loadDb([string] $path) {
    if (-not (Test-Path $path)) { return @() }
    $raw = Get-Content $path -Raw | ConvertFrom-Json
    return @($raw | Where-Object { $_.planFile } | ForEach-Object {
        [pscustomobject]@{
            planFile   = $_.planFile
            cwd        = $_.cwd
            sessionIds = @($_.sessionIds | Where-Object { $_ })
            harness    = if ($_.harness) { $_.harness } else { getDefaultHarness }
            launches    = if ($null -ne $_.launches) { [int] $_.launches } else { 0 }
            launchesFor = $_.launchesFor
        }
    })
}

function saveDb($db, [string] $path) {
    $null = New-Item -ItemType Directory -Path (Split-Path $path) -Force
    # Project to the persisted fields — in-memory entries also carry a computed state property.
    $persisted = @($db | ForEach-Object {
        [pscustomobject]@{
            planFile = $_.planFile
            cwd      = $_.cwd
            sessionIds = @($_.sessionIds)
            harness  = if ($_.harness) { $_.harness } else { getDefaultHarness }
            launches    = if ($null -ne $_.launches) { [int] $_.launches } else { 0 }
            launchesFor = $_.launchesFor
        }
    })
    (ConvertTo-Json -InputObject $persisted -Depth 5) | Set-Content $path -Encoding UTF8
}

# --- Process detection ---

# Thin wrapper (mockable in tests) over the process command-line query, parameterized by process
# name so claude.exe and copilot.exe scans share this one implementation.
function getLiveHarnessProcs([string] $processName) {
    Get-CimInstance Win32_Process -Filter "Name='$processName'" -ErrorAction Ignore |
        ForEach-Object { [pscustomobject]@{ CommandLine = $_.CommandLine } }
}

# Neither harness needs a hook: copilot's launcher always puts the session id on its own command
# line, and pl does the same for claude (fresh: --session-id, resume: --resume — see
# getFreshSessionArgs/getResumeArgs). Fresh copilot sessions also carry `-C <cwd>`; resumed copilot
# sessions and all claude sessions don't, so cwd stays $null for those. Each session can spawn more
# than one process sharing the same id (e.g. copilot's parent + fork), so dedup by id.
# $cmdlineFilter narrows matches to a substring of the command line — needed when a custom harness's
# liveProcessName is a generic interpreter (e.g. 'python.exe') that would otherwise false-match any
# unrelated process of that name carrying a --session-id/--resume-shaped argument.
function getLiveSessionRecords([string] $harness, [string] $processName, [string] $cmdlineFilter = $null) {
    $sidRx = '--(?:session-id|resume)[ =]([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'
    $cwdRx = '\s-C\s+(\S+)'
    $seen    = @{}
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($proc in (getLiveHarnessProcs $processName)) {
        $cl = $proc.CommandLine
        if (-not $cl) { continue }
        if ($cmdlineFilter -and $cl -notlike "*$cmdlineFilter*") { continue }
        $m = [regex]::Match($cl, $sidRx)
        if (-not $m.Success) { continue }
        $sid = $m.Groups[1].Value
        if ($seen.ContainsKey($sid)) { continue }
        $seen[$sid] = $true
        $cwd = $null
        $cm = [regex]::Match($cl, $cwdRx)
        if ($cm.Success) { $cwd = $cm.Groups[1].Value }
        $records.Add(@{ session_id = $sid; cwd = $cwd; harness = $harness })
    }
    return ,@($records)
}

# Matches live-process records to db entries by session id, then (only when $allowCwdMatch, i.e.
# copilot — claude's command line carries no cwd, and pl-launched claude sessions don't need it)
# by cwd against a sole unoccupied entry. Unions into the shared liveSessionIds/orphans and stamps
# the resolved harness onto both the matched entry and $sessionHarness (session_id -> harness) so
# launch/resume pick the right harness later.
function resolveHarnessSessions($entries, $records, $liveSessionIds, $orphans, $sessionHarness, [bool] $allowCwdMatch) {
    $sidMap = @{}
    foreach ($entry in $entries) {
        foreach ($sid in $entry.sessionIds) { $sidMap[$sid] = $entry }
    }

    $unmatched = [System.Collections.Generic.List[object]]::new()

    # Pass 1: sessions already tracked in the db by id.
    foreach ($rec in $records) {
        $sid = $rec.session_id
        if (-not $sid) { continue }
        if ($sidMap.ContainsKey($sid)) {
            $null = $liveSessionIds.Add($sid)
            $sidMap[$sid].harness = $rec.harness
            $sessionHarness[$sid] = $rec.harness
        } else {
            $unmatched.Add($rec)
        }
    }

    # Pass 2: cwd-match new sessions to a sole unoccupied entry; otherwise orphan.
    foreach ($rec in $unmatched) {
        $sid      = $rec.session_id
        $cwdEntry = $null
        if ($allowCwdMatch -and $rec.cwd) {
            $fileCwd    = normalizePath $rec.cwd
            $cwdMatches = @($entries | Where-Object { (normalizePath $_.cwd) -eq $fileCwd -and -not (isLive $_ $liveSessionIds) })
            if ($cwdMatches.Count -eq 1) { $cwdEntry = $cwdMatches[0] }
        }
        if ($cwdEntry) {
            $cwdEntry.sessionIds = @($cwdEntry.sessionIds) + @($sid)
            $cwdEntry.harness    = $rec.harness
        } else {
            $orphans.Add($sid) | Out-Null
        }
        $sessionHarness[$sid] = $rec.harness
        $null = $liveSessionIds.Add($sid)
    }
}

# The leading comma on each return prevents PowerShell from unrolling a single-element array to a
# bare scalar, which would later splat as individual characters.
function getClExtraArgs([string] $harness, $userArgs) {
    return ,(@("-Harness:$harness") + @($userArgs)) 
}

function getResumeArgs([string] $harness, [string] $sid) {
    if ($harness -eq 'copilot') { return ,@("--resume=$sid") }
    return ,@('--resume', $sid)
}

# --- Harness registry ---

# Thin wrapper (mockable in tests) over the required de-supplied harness list
function getAgentHarnesses {
    return @(Get-AgentHarnesses)
}

function getDefaultHarness {
    return (getAgentHarnesses)[0].name
}

# Noe: pi's --resume takes no session id (it shows its own interactive menu instead), so only live-detection and 
# fresh-launch are supported for now.
#
# Picker keys must stay unique across this list.
function getBuiltinHarnessDescriptors {
    return @(
        @{ name = 'claude'; liveProcessName = 'claude.exe'; sessionInfoStyle = 'claude-projects'; pickerKey = 'C' }
        @{ name = 'copilot'; liveProcessName = 'copilot.exe'; liveCwdMatch = $true; sessionInfoStyle = 'claude-projects' }
        @{ name = 'pi'; liveProcessName = 'node.exe'; liveCmdlineFilter = 'pi-coding-agent'; pickerKey = '3' }
    )
}

# The descriptor for one harness — $null unless it's selected (its name appears in Get-AgentHarnesses,
# even bare). A selected well-known harness (claude/copilot/pi) always resolves to prefs's own
# built-in properties, ignoring anything else its registry entry says; a selected name with no
# built-in (the "augmenting" case) uses its own registry entry directly. A built-in prefs knows about
# but de hasn't selected is fully inactive — not offered, not live-scanned, not resumable.
function getHarnessDescriptor([string] $harness) {
    $selectedNames = @(getAgentHarnesses | Where-Object { $_ -and $_.name } | ForEach-Object { $_.name })
    if ($harness -notin $selectedNames) { return $null }
    $builtin = @(getBuiltinHarnessDescriptors | Where-Object { $_.name -eq $harness }) | Select-Object -First 1
    if ($builtin) { return $builtin }
    return @(getAgentHarnesses | Where-Object { $_ -and $_.name -eq $harness }) | Select-Object -First 1
}

# Every harness de has selected, resolved the same way as getHarnessDescriptor.
function getHarnessDescriptors {
    $selectedNames = @(getAgentHarnesses | Where-Object { $_ -and $_.name } | ForEach-Object { $_.name } | Select-Object -Unique)
    return @($selectedNames | ForEach-Object { getHarnessDescriptor $_ } | Where-Object { $_ })
}

# Whether $descriptor can run a headless launch — the flag it declares (a harness-specific string,
# spelled only in the de-supplied registry) or nothing for one that can't. A harness with none can't
# be looped (see runBranchReviewRun).
function harnessSupportsHeadless($descriptor) {
    return [bool] $descriptor.headlessFlag
}

# The extra launch args a headless run needs, or none.
function getHeadlessArgs($descriptor) {
    if (-not $descriptor.headlessFlag) { return ,@() }
    return ,@($descriptor.headlessFlag)
}

# --- Model picker ---

# Thin wrapper over the optional de-specific model list command (mockable in tests). Bare-name
# invocation. Unlike Get-AgentHarnesses this one is genuinely optional: non-de users and unlisted
# harnesses see no command on PATH, so this returns $null rather than throwing.
function tryInvokeAgentModelList {
    $cmd = Get-Command Get-AgentModelList -ErrorAction Ignore
    if (-not $cmd) { return $null }
    return & Get-AgentModelList
}

# Cost-sorted model choices for $harness, plus a trailing <default> (model = $null — "no --model
# arg, let the harness apply its own default"). $null when the list command is absent or doesn't
# cover this harness — callers then skip the model field entirely.
function getModelList([string] $harness) {
    $table = tryInvokeAgentModelList
    if (-not $table -or -not $table.ContainsKey($harness)) { return $null }
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($e in ($table[$harness].GetEnumerator() | Sort-Object { $_.Value.relativeCost })) {
        $list.Add([pscustomobject]@{ displayName = $e.Value.displayName; model = $e.Value.model; relativeCost = $e.Value.relativeCost })
    }
    $list.Add([pscustomobject]@{ displayName = '<default>'; model = $null; relativeCost = $null })
    return ,$list
}

# Wrapping (+1/-1) step through a list's indices.
function cycleIndex([int] $index, [int] $count, [int] $direction) {
    if ($count -le 0) { return 0 }
    return (($index + $direction) % $count + $count) % $count
}

# Cycles one of the fresh row's inline fields — 'model', 'workflow', or 'harness' — in place, and
# reports whether it moved, so the picker knows to re-derive the labels the field shows in. A session
# row has none, and a row without a given field (no model list, no harness options) leaves it alone.
function advanceFreshRowField($row, [string] $field, [int] $direction) {
    if ($row.kind -ne 'fresh' -or -not $row["${field}List"]) { return $false }
    $row["${field}Index"] = cycleIndex $row["${field}Index"] @($row["${field}List"]).Count $direction
    return $true
}

# pickFromList's $onKey for the launch picker: ←/→ cycle the model, W cycles the workflow (a
# plan-file write, prompting the commit grant on the transition into branch-review), H cycles the
# harness (a db write). Each writes immediately so the launch reads the new value. The phase itself
# no longer cycles here — Enter/P/D are separate keys on the outer list, chosen before the picker opens.
function handleFreshRowKey($row, $key) {
    switch ($key.Key) {
        'LeftArrow'  { return (advanceFreshRowField $row 'model' -1) }
        'RightArrow' { return (advanceFreshRowField $row 'model' 1) }
        'W' {
            if (advanceFreshRowField $row 'workflow' 1) {
                $wf = $row.workflowList[$row.workflowIndex]
                writeWorkflow $row.entry.planFile $row.entry.cwd $wf
                $row.phaseLabel = getFreshRowPhaseLabel $row.phase $row.nextStep $wf
                return $true
            }
        }
        'H' {
            if (advanceFreshRowField $row 'harness' 1) {
                $row.harness = $row.harnessList[$row.harnessIndex]
                $row.entry.harness = $row.harness
                saveDb $row.db $dbPath
                return $true
            }
        }
    }
    return $false
}

# <default> (a null model) contributes no --model arg; any other model becomes @('--model', $model).
function getModelArgs([string] $model) {
    if ($model) { return ,@('--model', $model) }
    return ,@()
}

function isLive($entry, $liveSessionIds) {
    foreach ($sid in $entry.sessionIds) {
        if ($sid -in $liveSessionIds) { return $true }
    }
    return $false
}

# --- Cross-machine visibility ---

function updatePresenceFile($db, [string] $syncPath) {
    $trackingDir = "$syncPath/.plan-tracking"
    $null = New-Item -ItemType Directory -Path $trackingDir -Force
    @{
        machine  = $env:COMPUTERNAME
        lastSeen = (Get-Date -Format 'o')
        plans    = @($db | ForEach-Object { $_.planFile })
    } | ConvertTo-Json | Set-Content "$trackingDir/$env:COMPUTERNAME.json" -Encoding UTF8
}

function getCrossMachineFlags([string] $syncPath) {
    if (-not $syncPath) { return @() }
    $trackingDir = "$syncPath/.plan-tracking"
    if (-not (Test-Path $trackingDir)) { return @() }
    $cutoff  = (Get-Date).AddDays(-7)
    $flagged = @()
    foreach ($file in Get-ChildItem $trackingDir -Filter '*.json' -ErrorAction Ignore) {
        if ($file.BaseName -eq $env:COMPUTERNAME) { continue }
        $other = Get-Content $file.FullName -Raw | ConvertFrom-Json -ErrorAction Ignore
        if (-not $other -or -not $other.plans) { continue }
        # If lastSeen is present and older than 7 days, treat as stale — skip.
        # Missing lastSeen (older format) is treated as recent for backward compatibility.
        $lastSeenDt = [datetime]::MinValue
        if ($other.lastSeen -and [datetime]::TryParse($other.lastSeen, [ref]$lastSeenDt) -and $lastSeenDt -lt $cutoff) { continue }
        $flagged += @($other.plans)
    }
    return $flagged
}

function getPlansDir {
    Import-Module "$home/prat/lib/PratBase/PratBase.psd1" -ErrorAction Ignore
    $configScript = Resolve-PratLibFile 'lib/agents/Get-PlansDir.ps1' -ErrorAction Ignore
    if ($configScript) { return & $configScript }
    return $null
}

function getSyncPath {
    Import-Module "$home/prat/lib/PratBase/PratBase.psd1" -ErrorAction Ignore
    $configScript = Resolve-PratLibFile 'lib/agents/Get-PlanTrackingConfig.ps1' -ErrorAction Ignore
    if (-not $configScript) {
        return @{ path = $null; notice = 'No sync-backed path configured — cross-machine visibility unavailable. (Suppress with -NoSyncBackedWarning)' }
    }
    return checkSyncPath (& $configScript)
}

function checkSyncPath($path) {
    if (-not $path) { return @{ path = $null; notice = $null } }
    if (-not (Test-Path $path)) {
        return @{ path = $null; notice = "Configured sync path '$path' does not exist — cross-machine visibility unavailable." }
    }
    return @{ path = $path; notice = $null }
}

# --- Helpers ---

function getPlanTitle([string] $path) {
    $lines = @(Get-Content $path -TotalCount 40)
    $start = 0
    if ($lines.Count -gt 0 -and $lines[0] -eq '---') {
        $close = -1
        for ($i = 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -eq '---') { $close = $i; break }
        }
        if ($close -ge 0) { $start = $close + 1 }
    }
    if ($start -ge $lines.Count) { return '' }

    $heading = $lines[$start..($lines.Count - 1)] | Where-Object { $_ -match '^# ' } | Select-Object -First 1
    if ($heading) { return $heading -replace '^# ', '' }
    return ''
}

function normalizePath([string] $p) { $p -replace '\\', '/' }

if ($MyInvocation.InvocationName -ne '.') { main }
