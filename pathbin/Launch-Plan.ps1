# Launch-Plan.ps1  (alias: pl)
# Interactive launcher for plan-based agent sessions (Claude Code and GitHub Copilot).
# Plan lifecycle state lives in plan-file frontmatter (Get-PlanState/Set-PlanState); the local db
# only associates plans with sessions and a cwd. Enter is state-driven; after a session exits, pl
# returns to its TUI with freshly resolved state.
#
# Design: see docs/Launch-Plan.md

param([switch] $NoSyncBackedWarning)

$dbPath     = "$home/prat/auto/context/db.json"
$runningDir = "$home/prat/auto/context/running"

. "$home/prat/lib/agents/Set-PlanState.ps1"

function main {
    saveConsoleMode
    Import-Module "$home/prat/lib/PratBase/PratBase.psd1" -ErrorAction SilentlyContinue

    $lastPlan = $null
    while ($true) {
        $ctx = buildLauncherContext
        $lastPlan = runLauncher $ctx.db $ctx.liveSessionIds $ctx.orphans $ctx.crossFlags $ctx.notices $ctx.sessionHarness $lastPlan
        if (-not $lastPlan) { return }
    }
}

function buildLauncherContext {
    $db = loadLauncherDb $dbPath
    $livePids = getLiveClaudePids
    $resolved = resolveSessionIds $db $runningDir $livePids

    # Copilot detection unions into the same live/orphan sets. Claude orphans default to 'claude';
    # resolveCopilotSessions records 'copilot' for the sessions it resolves.
    $sessionHarness = @{}
    foreach ($sid in $resolved.orphans) { $sessionHarness[$sid] = 'claude' }
    $copilotRecords = getLiveCopilotRecords
    resolveCopilotSessions $db $copilotRecords $resolved.liveSessionIds $resolved.orphans $sessionHarness

    saveDb $db $dbPath
    cleanStaleRunningFiles $runningDir $livePids
    attachEntryInfo $db

    $notices = [System.Collections.Generic.List[string]]::new()
    foreach ($n in $resolved.notices) { $notices.Add($n) }

    if (-not (getPlansDir)) { $notices.Add('No plans directory configured — O and R unavailable. Provide lib/agents/Get-PlansDir.ps1 in your de repo.') }

    $syncResult = getSyncPath
    $syncPath   = $syncResult.path
    if ($syncResult.notice -and -not $NoSyncBackedWarning) { $notices.Add($syncResult.notice) }
    $crossFlags = @()
    if ($syncPath) {
        updatePresenceFile $db $syncPath
        $crossFlags = getCrossMachineFlags $syncPath
    }

    return @{ db = $db; liveSessionIds = $resolved.liveSessionIds; orphans = $resolved.orphans; crossFlags = $crossFlags; notices = $notices; sessionHarness = $sessionHarness }
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
    $state     = (Get-PlanState -PlanFile $entry.planFile).State
    $resumable = @(getSessionInfos $entry.sessionIds).Count -gt 0
    $entry | Add-Member -NotePropertyName state -NotePropertyValue $state -Force
    $entry | Add-Member -NotePropertyName enterKind -NotePropertyValue (getLaunchAction $state $resumable $entry.planFile).kind -Force
}

# --- TUI ---

# Returns the launched plan's planFile after a cl launch (the caller rebuilds context and
# re-enters, restoring the selection), or $null on quit.
function runLauncher($db, $liveSessionIds, $orphans, $crossFlags, $notices, $sessionHarness, $initialPlanFile) {
    $selected      = indexOfPlan $db $initialPlanFile
    $transientError = $null
    while ($true) {
        renderList $db $selected $liveSessionIds $orphans $crossFlags $notices $transientError
        $transientError = $null
        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            'UpArrow'   { $selected = if ($selected -gt 0) { $selected - 1 } else { [Math]::Max(0, $db.Count - 1) } }
            'DownArrow' { $selected = if ($selected -lt ($db.Count - 1)) { $selected + 1 } else { 0 } }
            'Enter' {
                if ($db.Count -gt 0) {
                    [Console]::Clear()
                    if (openProject $db $db[$selected] $liveSessionIds) { return $db[$selected].planFile }
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
            { $_ -in 'U', 'u' } {
                if ($db.Count -gt 0) {
                    if (isLive $db[$selected] $liveSessionIds) {
                        $transientError = 'Cannot unregister a live session — exit the agent first.'
                    } else {
                        $db.RemoveAt($selected)
                        saveDb $db $dbPath
                        if ($selected -ge $db.Count) { $selected = [Math]::Max(0, $db.Count - 1) }
                    }
                }
            }
            { $_ -in 'Q', 'q', 'Escape' } { [Console]::Clear(); return $null }
        }
    }
}

function displayState($entry) { if ($entry.state) { $entry.state } else { '-' } }

# TUI selection restore: index of $planFile in the (possibly rebuilt) db; top of list if absent.
function indexOfPlan($db, [string] $planFile) {
    if ($planFile) {
        for ($i = 0; $i -lt $db.Count; $i++) {
            if ($db[$i].planFile -eq $planFile) { return $i }
        }
    }
    return 0
}

function renderList($db, $selected, $liveSessionIds, $orphans, $crossFlags, $notices, $transientError) {
    [Console]::Clear()
    Write-Host '  Plan Launcher' -ForegroundColor Cyan
    Write-Host ''

    if ($db.Count -eq 0) { Write-Host '  (no open plans — press O to open one)' -ForegroundColor DarkGray }

    $maxNameLen  = if ($db.Count -gt 0) { ($db | ForEach-Object { (Split-Path $_.planFile -Leaf).Length } | Measure-Object -Maximum).Maximum } else { 0 }
    $maxStateLen = if ($db.Count -gt 0) { ($db | ForEach-Object { (displayState $_).Length } | Measure-Object -Maximum).Maximum } else { 0 }

    for ($i = 0; $i -lt $db.Count; $i++) {
        $entry    = $db[$i]
        $live     = isLive $entry $liveSessionIds
        $isCross  = $crossFlags -contains $entry.planFile
        $prefix   = if ($i -eq $selected) { '→ ' } else { '  ' }
        # Marker = what Enter does: switch to the live session is impossible ([live]), open the
        # session picker ([resume]), or start a fresh session ([fresh]).
        $status   = if ($live) { '[live]  ' } elseif ($entry.enterKind -eq 'resume') { '[resume]' } else { '[fresh] ' }
        $statusFg = if ($live) { 'Green' } elseif ($entry.enterKind -eq 'resume') { 'Cyan' } else { 'DarkGray' }
        $nameFg   = if ($i -eq $selected) { 'White' } else { 'Gray' }
        $planName = Split-Path $entry.planFile -Leaf

        Write-Host -NoNewline $prefix
        Write-Host -NoNewline $status -ForegroundColor $statusFg
        Write-Host -NoNewline "  $($planName.PadRight($maxNameLen))" -ForegroundColor $nameFg
        Write-Host -NoNewline "  $((displayState $entry).PadRight($maxStateLen))"
        if ($isCross) { Write-Host -NoNewline '  ⚠ other-machine' -ForegroundColor Yellow }
        Write-Host ''
    }

    Write-Host ''
    Write-Host '  [↑↓] navigate  [Enter] open  [O] open  [R] register  [S] state  [U] unregister  [Q] quit' -ForegroundColor DarkCyan

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

# --- Actions ---

# S is a repair tool: normal state changes happen via the agent's state script during sessions.
function changeState($db, $entry) {
    clearConsole
    Write-Host "  Change state: $(Split-Path $entry.planFile -Leaf)" -ForegroundColor Cyan
    Write-Host ''
    Write-Host "  Current state: $(displayState $entry)"
    Write-Host ''
    Write-Host '  New state:  [P] ready-to-plan  [I] ready-to-implement  [C] code-complete  [K] checkpointed  [Esc] cancel'
    $key = readStateKey
    $newState = switch ($key.Key) {
        'P' { 'ready-to-plan' }
        'I' { 'ready-to-implement' }
        'C' { 'code-complete' }
        'K' { 'checkpointed' }
        default { $null }
    }
    if ($newState -and $newState -ne $entry.state) {
        $null = Set-PlanState -PlanFile $entry.planFile -State $newState
        updateEntryInfo $entry
    }
}

# Pure dispatch for opening a plan: lifecycle state + session availability → what to do.
# kind 'fresh' launches a new session; kind 'resume' opens the session picker. .prompt always
# carries the state's fresh-launch prompt — the picker offers it as its start-fresh row.
# Missing/unknown state is treated as ready-to-plan.
function getLaunchAction([string] $state, [bool] $hasResumableSessions, [string] $planFile) {
    if ($state -eq 'checkpointed') {
        # Consume the checkpoint: old sessions are reference-only, launch a fresh implement session.
        return @{ kind = 'fresh'; prompt = "Please do the next step in $planFile"; setState = 'ready-to-implement' }
    }
    $prompt = switch ($state) {
        'ready-to-implement' { "Please do the next step in $planFile" }
        'code-complete'      { "$planFile is code-complete — please load context to review the current step." }
        default              { "Please plan the next step in $planFile" }
    }
    $kind = if ($hasResumableSessions) { 'resume' } else { 'fresh' }
    return @{ kind = $kind; prompt = $prompt; setState = $null }
}

function openProject($db, $entry, $liveSessionIds) {
    if (isLive $entry $liveSessionIds) {
        Write-Host 'A session is already live for this plan — switch to it instead.' -ForegroundColor Yellow
        $null = Read-Host 'Press Enter to return'
        return $false
    }

    $state  = (Get-PlanState -PlanFile $entry.planFile).State
    $infos  = @(getSessionInfos $entry.sessionIds)
    $action = getLaunchAction $state ($infos.Count -gt 0) $entry.planFile
    if ($action.setState) { $null = Set-PlanState -PlanFile $entry.planFile -State $action.setState }

    if ($action.kind -eq 'resume') {
        $rows = @($infos | Select-Object -First 3 | ForEach-Object { @{ kind = 'session'; info = $_ } })   # older sessions stay in the db, unshown
        $rows += @{ kind = 'fresh' }
        # Post-wrap planning usually wants a fresh session; mid-work states default to resuming.
        $initial = if ($state -eq 'ready-to-plan') { $rows.Count - 1 } else { 0 }
        $idx = pickFromList $rows {
            param($r)
            if ($r.kind -eq 'fresh') { '(start fresh session)' }
            else { "$($r.info.lastActive.ToString('yyyy-MM-dd HH:mm'))  $($r.info.summary)" }
        } 'Open plan' $initial
        if ($null -eq $idx) { return $false }

        if ($rows[$idx].kind -eq 'session') {
            $picked = $rows[$idx].info
            if ($entry.harness -eq 'claude') {
                $script:launchPrewriteSid = $picked.sid
                $script:launchPrewriteCwd = normalizePath $entry.cwd
            }
            $resumeArgs = getResumeArgs $entry.harness $picked.sid
            $exitCode = launchCl $entry.harness $entry.cwd $entry.planFile @resumeArgs
            if ($exitCode -ne 0) {
                $entry.sessionIds = @($entry.sessionIds | Where-Object { $_ -ne $picked.sid })
                saveDb $db $dbPath
                clearConsole
                Write-Host "Resume failed (cl exit $exitCode) — session $($picked.sid) dropped from this plan." -ForegroundColor Yellow
                $null = Read-Host 'Press Enter to return'
            }
            return $true
        }
        # fresh row picked — fall through to the fresh launch below
    }

    $entry.cwd = normalizePath $PWD.Path
    saveDb $db $dbPath
    $exitCode = launchCl $entry.harness $entry.cwd $entry.planFile $action.prompt
    showLaunchError $exitCode
    return $true
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

$script:launchPrewriteSid = $null  # set before resume launches to pre-write the running file
$script:launchPrewriteCwd = $null

function launchCl([string] $harness, [string] $cwd, [string] $planFile) {
    resetConsoleMode
    # Use Start-Process -NoNewWindow so the child process inherits the console directly,
    # bypassing PowerShell's pipeline stdout/stderr capture which breaks interactive TUI apps.
    # Use -EncodedCommand (Base64) to avoid Windows command-line quoting issues: Start-Process
    # joins -ArgumentList with spaces without re-quoting, so inner quotes are stripped by argv
    # parsing before pwsh reassembles them for -Command. Base64 has no special characters.
    $clArgs   = getClExtraArgs $harness $args
    $argStr   = ($clArgs | ForEach-Object { if ($_.StartsWith('-')) { $_ } else {'"' + ($_ -replace '"', '""') + '"' }}) -join ' '
    $cmd      = if ($argStr) { "& cl $argStr" } else { '& cl' }
    $encoded  = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    $spParams = @{ FilePath = 'pwsh'; ArgumentList = @('-NoLogo', '-EncodedCommand', $encoded); NoNewWindow = $true; PassThru = $true }
    if ($cwd) { $spParams.WorkingDirectory = $cwd }
    # CL_PLAN_FILE rides the process environment into cl — consumed by the UserPromptSubmit hook
    # (stamps planFile into the running file), the statusline, and skills' active-plan default.
    $envToken = Set-EnvTemp @{ CL_PLAN_FILE = $planFile }
    try {
        $proc = Start-Process @spParams
        # Pre-write the running file so the session shows live immediately, before the first
        # UserPromptSubmit hook fires. Only for claude resume launches (the running-file mechanism
        # is claude-only; copilot detection reads the live command line directly).
        if ($harness -eq 'claude' -and $script:launchPrewriteSid) {
            $runDir = "$home/prat/auto/context/running"
            $null = New-Item -ItemType Directory $runDir -Force
            [pscustomobject]@{session_id = $script:launchPrewriteSid; cwd = $script:launchPrewriteCwd} |
                ConvertTo-Json -Compress |
                Set-Content "$runDir/pid_$($proc.Id).txt" -Encoding UTF8
            $script:launchPrewriteSid = $null
            $script:launchPrewriteCwd = $null
        }
        $proc.WaitForExit()
        return $proc.ExitCode
    } catch {
        return 1
    } finally {
        Restore-Env $envToken
    }
}

function clearConsole { [Console]::Clear() }    # thin wrapper so tests can mock it
function readStateKey  { [Console]::ReadKey($true) }  # thin wrapper so tests can mock it

function showLaunchError([int] $exitCode) {
    # Note: no console clear here — cl's own output is already visible; clearing would erase it.
    if ($exitCode -ne 0) {
        Write-Host "cl exited with code $exitCode" -ForegroundColor Red
        $null = Read-Host 'Press Enter to return'
    }
}

# Resumable-session lookup: a session is resumable when its jsonl exists under the CC projects
# root (searching all project dirs avoids reimplementing CC's cwd→dirname rule; the files are
# sync-backed, so cross-machine sessions count too). Most-recent-first by jsonl mtime.
function getSessionInfos($sessionIds, [string] $projectsRoot = "$home/.claude/projects") {
    $infos = @()
    foreach ($sid in @($sessionIds | Where-Object { $_ })) {
        $jsonl = @(Get-ChildItem -Path "$projectsRoot/*/$sid.jsonl" -File -ErrorAction SilentlyContinue) | Select-Object -First 1
        if (-not $jsonl) { continue }
        $infos += [pscustomobject]@{
            sid        = $sid
            lastActive = $jsonl.LastWriteTime
            summary    = getSessionSummary $jsonl
        }
    }
    return @($infos | Sort-Object lastActive -Descending)
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
            ($rel -notmatch '(^|/)done/') -and ($baseName -notmatch '_(done|ref|background)$')
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
        harness    = 'copilot'
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
    $harness = if ($sessionHarness -and $sessionHarness[$sid]) { $sessionHarness[$sid] } else { 'claude' }

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

function pickFromList($items, $labelFn, $title, [int] $initialSelected = 0) {
    $labels   = @($items | ForEach-Object { & $labelFn $_ })
    $selected = [Math]::Min([Math]::Max(0, $initialSelected), $labels.Count - 1)

    while ($true) {
        [Console]::Clear()
        Write-Host "  $title" -ForegroundColor Cyan
        Write-Host ''
        for ($i = 0; $i -lt $labels.Count; $i++) {
            $prefix = if ($i -eq $selected) { '→ ' } else { '  ' }
            $fg     = if ($i -eq $selected) { 'White' } else { 'Gray' }
            Write-Host "$prefix$($labels[$i])" -ForegroundColor $fg
        }
        Write-Host ''
        Write-Host '  [↑↓] navigate  [Enter] select  [Esc] cancel' -ForegroundColor DarkCyan

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            'UpArrow'   { $selected = if ($selected -gt 0) { $selected - 1 } else { [Math]::Max(0, $labels.Count - 1) } }
            'DownArrow' { $selected = if ($selected -lt ($labels.Count - 1)) { $selected + 1 } else { 0 } }
            'Enter'     { return $selected }
            'Escape'    { return $null }
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
            harness    = if ($_.harness) { $_.harness } else { 'claude' }
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
            harness  = if ($_.harness) { $_.harness } else { 'claude' }
        }
    })
    (ConvertTo-Json -InputObject $persisted -Depth 5) | Set-Content $path -Encoding UTF8
}

# --- Process detection ---

function getLiveClaudePids {
    $procs = Get-Process claude -ErrorAction SilentlyContinue
    if (-not $procs) { return ,@() }
    return ,@($procs | Select-Object -ExpandProperty Id | Where-Object { $_ -is [int] })
}

# Thin wrapper (mockable in tests) over the copilot.exe process query.
function getCopilotProcs {
    Get-CimInstance Win32_Process -Filter "Name='copilot.exe'" -ErrorAction SilentlyContinue |
        ForEach-Object { [pscustomobject]@{ CommandLine = $_.CommandLine } }
}

# Copilot needs no hook: the session id and cwd are already on the copilot.exe command line.
# Fresh sessions carry `--session-id <uuid>` and `-C <cwd>`; resumed sessions carry `--resume=<uuid>`
# and no `-C`. Each session spawns two processes (parent + fork) with the same id, so dedup by id.
function getLiveCopilotRecords {
    $sidRx = '--(?:session-id|resume)[ =]([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'
    $cwdRx = '\s-C\s+(\S+)'
    $seen    = @{}
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($proc in (getCopilotProcs)) {
        $cl = $proc.CommandLine
        if (-not $cl) { continue }
        $m = [regex]::Match($cl, $sidRx)
        if (-not $m.Success) { continue }
        $sid = $m.Groups[1].Value
        if ($seen.ContainsKey($sid)) { continue }
        $seen[$sid] = $true
        $cwd = $null
        $cm = [regex]::Match($cl, $cwdRx)
        if ($cm.Success) { $cwd = $cm.Groups[1].Value }
        $records.Add(@{ session_id = $sid; cwd = $cwd })
    }
    return ,@($records)
}

# Mirrors resolveSessionIds for Copilot: match records to entries by id, then by cwd, unioning into
# the shared liveSessionIds/orphans. Stamps the matched entry's harness and records it in
# $sessionHarness (session_id -> 'copilot') so launch/resume pick the right harness later.
function resolveCopilotSessions($entries, $records, $liveSessionIds, $orphans, $sessionHarness) {
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
            $sidMap[$sid].harness   = 'copilot'
            $sessionHarness[$sid]   = 'copilot'
        } else {
            $unmatched.Add($rec)
        }
    }

    # Pass 2: cwd-match new sessions to a sole unoccupied entry; otherwise orphan.
    foreach ($rec in $unmatched) {
        $sid      = $rec.session_id
        $cwdEntry = $null
        if ($rec.cwd) {
            $fileCwd    = normalizePath $rec.cwd
            $cwdMatches = @($entries | Where-Object { (normalizePath $_.cwd) -eq $fileCwd -and -not (isLive $_ $liveSessionIds) })
            if ($cwdMatches.Count -eq 1) { $cwdEntry = $cwdMatches[0] }
        }
        if ($cwdEntry) {
            $cwdEntry.sessionIds = @($cwdEntry.sessionIds) + @($sid)
            $cwdEntry.harness    = 'copilot'
        } else {
            $orphans.Add($sid) | Out-Null
        }
        $sessionHarness[$sid] = 'copilot'
        $null = $liveSessionIds.Add($sid)
    }
}

# The leading comma on each return prevents PowerShell from unrolling a single-element array to a
# bare scalar, which would later splat as individual characters.
function getClExtraArgs([string] $harness, $userArgs) {
    return ,(@("-Harness:$harness") + @($userArgs)) 
}

# Resume flag differs by harness: claude wants `--resume <id>` (two tokens), copilot `--resume=<id>`.
function getResumeArgs([string] $harness, [string] $sid) {
    if ($harness -eq 'claude') { return ,@('--resume', $sid) }
    return ,@("--resume=$sid")
}

function resolveSessionIds($entries, [string] $rDir, $livePids) {
    $liveSessionIds = [System.Collections.Generic.HashSet[string]]::new()
    $orphans        = [System.Collections.Generic.List[string]]::new()
    $notices        = [System.Collections.Generic.List[string]]::new()

    # Build reverse map: session_id → entry
    $sidMap = @{}
    foreach ($entry in $entries) {
        foreach ($sid in $entry.sessionIds) { $sidMap[$sid] = $entry }
    }

    if (-not (Test-Path $rDir)) { return @{ liveSessionIds = $liveSessionIds; orphans = $orphans; notices = $notices } }

    # Match running files by session ID, then by the planFile the hook stamped from CL_PLAN_FILE.
    # Anything else is an orphan — R-register is the repair path.
    foreach ($file in Get-ChildItem $rDir -Filter 'pid_*.txt' -ErrorAction SilentlyContinue) {
        $filePid = [int]($file.BaseName -replace 'pid_', '')
        if ($filePid -notin $livePids) { continue }

        $data = Get-Content $file.FullName -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if (-not $data -or -not $data.session_id -or -not $data.cwd) { continue }

        if (-not $sidMap.ContainsKey($data.session_id)) {
            $planEntry = $null
            if ($data.planFile) {
                $planEntry = $entries | Where-Object { $_.planFile -eq $data.planFile } | Select-Object -First 1
            }
            if ($planEntry) {
                if ($data.session_id -notin $planEntry.sessionIds) {
                    $planEntry.sessionIds = @($planEntry.sessionIds) + @($data.session_id)
                }
                $sidMap[$data.session_id] = $planEntry
            } else {
                $orphans.Add($data.session_id) | Out-Null
            }
        }
        $null = $liveSessionIds.Add($data.session_id)
    }

    return @{ liveSessionIds = $liveSessionIds; orphans = $orphans; notices = $notices }
}

function isLive($entry, $liveSessionIds) {
    foreach ($sid in $entry.sessionIds) {
        if ($sid -in $liveSessionIds) { return $true }
    }
    return $false
}

function cleanStaleRunningFiles([string] $rDir, $livePids) {
    if (-not (Test-Path $rDir)) { return }
    foreach ($file in Get-ChildItem $rDir -Filter 'pid_*.txt' -ErrorAction SilentlyContinue) {
        $filePid = [int]($file.BaseName -replace 'pid_', '')
        if ($filePid -notin $livePids) { Remove-Item $file.FullName -ErrorAction SilentlyContinue }
    }
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
    foreach ($file in Get-ChildItem $trackingDir -Filter '*.json' -ErrorAction SilentlyContinue) {
        if ($file.BaseName -eq $env:COMPUTERNAME) { continue }
        $other = Get-Content $file.FullName -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
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
    Import-Module "$home/prat/lib/PratBase/PratBase.psd1" -ErrorAction SilentlyContinue
    $configScript = Resolve-PratLibFile 'lib/agents/Get-PlansDir.ps1' -ErrorAction SilentlyContinue
    if ($configScript) { return & $configScript }
    return $null
}

function getSyncPath {
    Import-Module "$home/prat/lib/PratBase/PratBase.psd1" -ErrorAction SilentlyContinue
    $configScript = Resolve-PratLibFile 'lib/agents/Get-PlanTrackingConfig.ps1' -ErrorAction SilentlyContinue
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
