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

    # Both harnesses now carry their session id on their own command line (claude via
    # --session-id/--resume passed at launch; copilot's launcher does this unprompted), so a
    # single scan per harness replaces the old hook-fed pid-file matching. Only copilot's command
    # line also carries a cwd, so only it gets the cwd-match fallback pass.
    $liveSessionIds = [System.Collections.Generic.HashSet[string]]::new()
    $orphans        = [System.Collections.Generic.List[string]]::new()
    $sessionHarness = @{}
    resolveHarnessSessions $db (getLiveSessionRecords 'claude' 'claude.exe')   $liveSessionIds $orphans $sessionHarness $false
    resolveHarnessSessions $db (getLiveSessionRecords 'copilot' 'copilot.exe') $liveSessionIds $orphans $sessionHarness $true

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

    return @{ db = $db; liveSessionIds = $liveSessionIds; orphans = $orphans; crossFlags = $crossFlags; notices = $notices; sessionHarness = $sessionHarness }
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
    $state     = $planState.State
    $resumable = @(getSessionInfos $entry.sessionIds).Count -gt 0
    $entry | Add-Member -NotePropertyName state -NotePropertyValue $state -Force
    $entry | Add-Member -NotePropertyName nextStep -NotePropertyValue $planState.NextStep -Force
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
            { $_ -in 'V', 'v' } {
                if ($db.Count -gt 0) { openInEditor $db[$selected].planFile }
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

function displayState($entry) {
    if ($entry.state -and $entry.nextStep) { return "$($entry.state): $($entry.nextStep)" }
    if ($entry.state) { return $entry.state }
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

# Pure: builds a row's fixed-width fields, truncating the variable ones (name, state, cross flag —
# in that priority order) so the total stays within $width. Keeps prefix/status untouched (fixed
# width) and lets renderList print each field in its own color.
function buildRowFields($entry, [bool] $isSelected, [bool] $live, [bool] $isCross, [int] $maxNameLen, [int] $maxStateLen, [int] $width) {
    $prefix   = if ($isSelected) { '→ ' } else { '  ' }
    $status   = if ($live) { '[live]  ' } elseif ($entry.enterKind -eq 'resume') { '[resume]' } else { '[fresh] ' }
    $planName = Split-Path $entry.planFile -Leaf

    $nameField  = "  $($planName.PadRight($maxNameLen))"
    $stateField = "  $((displayState $entry).PadRight($maxStateLen))"
    $crossField = if ($isCross) { '  ⚠ other-machine' } else { '' }

    $used = $prefix.Length + $status.Length
    $nameField = truncateLabel $nameField ([Math]::Max(0, $width - $used));  $used += $nameField.Length
    $stateField = truncateLabel $stateField ([Math]::Max(0, $width - $used)); $used += $stateField.Length
    $crossField = truncateLabel $crossField ([Math]::Max(0, $width - $used))

    return @{ prefix = $prefix; status = $status; statusFg = if ($live) { 'Green' } elseif ($entry.enterKind -eq 'resume') { 'Cyan' } else { 'DarkGray' }; nameField = $nameField; stateField = $stateField; crossField = $crossField }
}

function renderList($db, $selected, $liveSessionIds, $orphans, $crossFlags, $notices, $transientError) {
    [Console]::Clear()
    Write-Host '  Plan Launcher' -ForegroundColor Cyan
    Write-Host ''

    if ($db.Count -eq 0) { Write-Host '  (no open plans — press O to open one)' -ForegroundColor DarkGray }

    $maxNameLen  = if ($db.Count -gt 0) { ($db | ForEach-Object { (Split-Path $_.planFile -Leaf).Length } | Measure-Object -Maximum).Maximum } else { 0 }
    $maxStateLen = if ($db.Count -gt 0) { ($db | ForEach-Object { (displayState $_).Length } | Measure-Object -Maximum).Maximum } else { 0 }

    $width = getConsoleWidth
    for ($i = 0; $i -lt $db.Count; $i++) {
        $entry   = $db[$i]
        $live    = isLive $entry $liveSessionIds
        $isCross = $crossFlags -contains $entry.planFile
        $nameFg  = if ($i -eq $selected) { 'White' } else { 'Gray' }
        # Marker = what Enter does: switch to the live session is impossible ([live]), open the
        # session picker ([resume]), or start a fresh session ([fresh]).
        $f = buildRowFields $entry ($i -eq $selected) $live $isCross $maxNameLen $maxStateLen $width

        Write-Host -NoNewline $f.prefix
        Write-Host -NoNewline $f.status -ForegroundColor $f.statusFg
        Write-Host -NoNewline $f.nameField -ForegroundColor $nameFg
        Write-Host -NoNewline $f.stateField
        if ($f.crossField) { Write-Host -NoNewline $f.crossField -ForegroundColor Yellow }
        Write-Host ''
    }

    Write-Host ''
    Write-Host '  [↑↓] navigate  [Enter] open  [O] open  [R] register  [S] state  [V] view  [U] unregister  [Q] quit' -ForegroundColor DarkCyan

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

# S is chiefly a repair tool for when something has gone wrong — normal state changes happen via
# the agent's state script during sessions. It doubles as the sanctioned lightweight advance
# gesture (S -> I) for skipping straight to ready-to-implement after a refine that needs no plan
# review; that path bypasses /wrap's planning-close reflect, so use it sparingly.
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

# claude carries no identifying info on its own process command line, so pl must supply a session
# id for a fresh launch to be detectable there; copilot's own launcher already does this, so this
# is a no-op for any other harness. Mutates $entry.sessionIds so the new session is tracked
# immediately, without waiting for the next command-line scan.
function getFreshSessionArgs([string] $harness, $entry) {
    if ($harness -ne 'claude') { return ,@() }
    $sid = [guid]::NewGuid().ToString()
    $entry.sessionIds = @($entry.sessionIds) + @($sid)
    return ,@('--session-id', $sid)
}

# ready-to-implement's sessions are the spent planning ones, so the picker defaults to a fresh
# session there; ready-to-plan and code-complete default to continuing/approving the existing one.
function defaultsToFreshPicker([string] $state) {
    return $state -eq 'ready-to-implement'
}

# Session GUIDs in the rows don't identify the plan, and openUntracked shares the bare 'Open plan'
# title — disambiguate by naming the plan in the title line instead.
function getSessionPickerTitle([string] $planFile) {
    $name  = Split-Path $planFile -Leaf
    $title = getPlanTitle $planFile
    if ($title) { return "$name — $title" }
    return $name
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

    # Every fresh launch goes through the picker (a single "(start fresh session)" row when there
    # are no sessions), so the inline model field below is always reachable.
    $freshRow = @{ kind = 'fresh'; harness = $entry.harness }
    $modelList = getModelList $entry.harness
    if ($modelList) {
        # Start on <default> (the last entry) — no --model arg, matching today's behavior.
        $freshRow.modelList  = $modelList
        $freshRow.modelIndex = $modelList.Count - 1
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    if ($action.kind -eq 'resume') {
        foreach ($info in ($infos | Select-Object -First 3)) { $rows.Add(@{ kind = 'session'; info = $info }) }   # older sessions stay in the db, unshown
    }
    $rows.Add($freshRow)
    $initial = if ($action.kind -eq 'resume' -and -not (defaultsToFreshPicker $state)) { 0 } else { $rows.Count - 1 }

    $idx = pickFromList $rows {
        param($r)
        if ($r.kind -ne 'fresh') { return "$($r.info.lastActive.ToString('yyyy-MM-dd HH:mm'))  $($r.info.summary)" }
        if (-not $r.modelList) { return "(start fresh session)   $($r.harness)" }
        $choice     = $r.modelList[$r.modelIndex]
        $modelLabel = if ($choice.model) { "$($choice.displayName)  (cost x$($choice.relativeCost))" } else { $choice.displayName }
        return "(start fresh session)   $($r.harness): $modelLabel  ‹ ›"
    } (getSessionPickerTitle $entry.planFile) $initial { param($item, $direction) advanceFreshRowModel $item $direction }
    if ($null -eq $idx) { return $false }

    if ($rows[$idx].kind -eq 'session') {
        $picked = $rows[$idx].info
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

    # fresh row picked
    $freshModel  = if ($rows[$idx].modelList) { $rows[$idx].modelList[$rows[$idx].modelIndex].model } else { $null }
    $modelArgs   = getModelArgs $freshModel
    $sessionArgs = getFreshSessionArgs $entry.harness $entry

    $entry.cwd = normalizePath $PWD.Path
    saveDb $db $dbPath
    $exitCode = launchCl $entry.harness $entry.cwd $entry.planFile @modelArgs @sessionArgs $action.prompt
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

# pl clears the console right before launching, so a cursor not at (0,0) when the child pwsh
# reaches `& cl` means its profile load printed something above — pause so it can be read before
# `cl`'s own UI overwrites it.
function getCursorGuardScript() {
    return '$__pos = [Console]::CursorLeft, [Console]::CursorTop; if ($__pos[0] -ne 0 -or $__pos[1] -ne 0) { Read-Host "Startup output above - press Enter to continue" }'
}

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
    $cmd      = "$(getCursorGuardScript); $cmd"
    $encoded  = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    $spParams = @{ FilePath = 'pwsh'; ArgumentList = @('-NoLogo', '-EncodedCommand', $encoded); NoNewWindow = $true; PassThru = $true }
    if ($cwd) { $spParams.WorkingDirectory = $cwd }
    # CL_PLAN_FILE rides the process environment into cl — consumed by the statusline and skills'
    # active-plan default.
    $envToken = Set-EnvTemp @{ CL_PLAN_FILE = $planFile }
    try {
        $proc = Start-Process @spParams
        $proc.WaitForExit()
        return $proc.ExitCode
    } catch {
        return 1
    } finally {
        Restore-Env $envToken
    }
}

# Thin wrapper so tests can mock it. Absent for non-de users / when the editor alias isn't
# installed — a no-op in that case, matching Get-DefaultHarness/Get-AgentModelList's pattern.
function openInEditor([string] $path) {
    $cmd = Get-Command Open-FileInEditor -ErrorAction SilentlyContinue
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
        harness    = Get-DefaultHarness
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
    $harness = if ($sessionHarness -and $sessionHarness[$sid]) { $sessionHarness[$sid] } else { Get-DefaultHarness }

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

# $onHorizontal (optional): called as `& $onHorizontal $items[$selected] $direction` (+1/-1) on
# Left/Right, to mutate the selected item in place — e.g. cycling a field shown in its label.
# Callers that don't pass it get Left/Right as no-ops.
function pickFromList($items, $labelFn, $title, [int] $initialSelected = 0, $onHorizontal = $null) {
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
            # Labels are only re-derived here, after a mutation — not on every render — so callers
            # whose label function does real work (e.g. openUntracked's file-reading getPlanTitle)
            # don't pay for it on every Up/Down keystroke, only when something actually changed.
            'LeftArrow'  { if ($onHorizontal) { & $onHorizontal $items[$selected] -1; $labels = @($items | ForEach-Object { & $labelFn $_ }) } }
            'RightArrow' { if ($onHorizontal) { & $onHorizontal $items[$selected] 1; $labels = @($items | ForEach-Object { & $labelFn $_ }) } }
            'Enter'      { return $selected }
            'Escape'     { return $null }
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
            harness    = if ($_.harness) { $_.harness } else { Get-DefaultHarness }
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
            harness  = if ($_.harness) { $_.harness } else { Get-DefaultHarness }
        }
    })
    (ConvertTo-Json -InputObject $persisted -Depth 5) | Set-Content $path -Encoding UTF8
}

# --- Process detection ---

# Thin wrapper (mockable in tests) over the process command-line query, parameterized by process
# name so claude.exe and copilot.exe scans share this one implementation.
function getLiveHarnessProcs([string] $processName) {
    Get-CimInstance Win32_Process -Filter "Name='$processName'" -ErrorAction SilentlyContinue |
        ForEach-Object { [pscustomobject]@{ CommandLine = $_.CommandLine } }
}

# Neither harness needs a hook: copilot's launcher always puts the session id on its own command
# line, and pl does the same for claude (fresh: --session-id, resume: --resume — see
# getFreshSessionArgs/getResumeArgs). Fresh copilot sessions also carry `-C <cwd>`; resumed copilot
# sessions and all claude sessions don't, so cwd stays $null for those. Each session can spawn more
# than one process sharing the same id (e.g. copilot's parent + fork), so dedup by id.
function getLiveSessionRecords([string] $harness, [string] $processName) {
    $sidRx = '--(?:session-id|resume)[ =]([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'
    $cwdRx = '\s-C\s+(\S+)'
    $seen    = @{}
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($proc in (getLiveHarnessProcs $processName)) {
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

# Resume flag differs by harness: claude wants `--resume <id>` (two tokens), copilot `--resume=<id>`.
function getResumeArgs([string] $harness, [string] $sid) {
    if ($harness -eq 'claude') { return ,@('--resume', $sid) }
    return ,@("--resume=$sid")
}

# --- Model picker ---

# Thin wrapper over the optional de-specific model list command (mockable in tests). Bare-name
# invocation, same pattern as Get-DefaultHarness: non-de users and unlisted harnesses see no
# command on PATH, so this returns $null rather than throwing.
function tryInvokeAgentModelList {
    $cmd = Get-Command Get-AgentModelList -ErrorAction SilentlyContinue
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

# Wrapping Left(-1)/Right(+1) step through a model list's indices.
function cycleModelIndex([int] $index, [int] $count, [int] $direction) {
    if ($count -le 0) { return 0 }
    return (($index + $direction) % $count + $count) % $count
}

# pickFromList's $onHorizontal for the fresh row: no-op for session rows and for a fresh row with
# no model list (harness/environment fallback); otherwise advances $row.modelIndex in place.
function advanceFreshRowModel($row, [int] $direction) {
    if ($row.kind -eq 'fresh' -and $row.modelList) {
        $row.modelIndex = cycleModelIndex $row.modelIndex $row.modelList.Count $direction
    }
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
