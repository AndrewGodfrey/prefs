# Launch-Plan.ps1  (alias: pl)
# Interactive launcher for plan-based Claude sessions.
# Tracks open plans, detects live/dormant Claude processes, and launches or resumes sessions.

param([switch] $NoSyncBackedWarning)

$dbPath     = "$home/prat/auto/context/db.json"
$runningDir = "$home/prat/auto/context/running"

function main {
    saveConsoleMode
    Import-Module "$home/prat/lib/PratBase/PratBase.psd1" -ErrorAction SilentlyContinue

    $db = [System.Collections.Generic.List[object]]::new()
    foreach ($item in (loadDb $dbPath)) { $db.Add($item) }
    $livePids = getLiveClaudePids
    $resolved = resolveSessionIds $db $runningDir $livePids
    saveDb $db $dbPath
    cleanStaleRunningFiles $runningDir $livePids

    $notices = [System.Collections.Generic.List[string]]::new()
    foreach ($n in $resolved.notices) { $notices.Add($n) }

    if (-not (getPlansDir)) { $notices.Add('No plans directory configured — O and R unavailable. Provide lib/claude/Get-PlansDir.ps1 in your de repo.') }

    $syncResult = getSyncPath
    $syncPath   = $syncResult.path
    if ($syncResult.notice -and -not $NoSyncBackedWarning) { $notices.Add($syncResult.notice) }
    $crossFlags = @()
    if ($syncPath) {
        updatePresenceFile $db $syncPath
        $crossFlags = getCrossMachineFlags $syncPath
    }

    runLauncher $db $resolved.liveSessionIds $resolved.orphans $crossFlags $notices
}

# --- TUI ---

function runLauncher($db, $liveSessionIds, $orphans, $crossFlags, $notices) {
    $selected      = 0
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
                    if (openProject $db $db[$selected] $liveSessionIds) { return }
                }
            }
            { $_ -in 'O', 'o' } {
                [Console]::Clear()
                if (openUntracked $db) { return }
            }
            { $_ -in 'R', 'r' } {
                [Console]::Clear()
                registerProject $db $orphans $liveSessionIds
            }
            { $_ -in 'S', 's' } {
                if ($db.Count -gt 0) {
                    if (isLive $db[$selected] $liveSessionIds) {
                        $transientError = 'Cannot change state of a live session — exit Claude first.'
                    } else {
                        changeState $db $db[$selected]
                    }
                }
            }
            { $_ -in 'U', 'u' } {
                if ($db.Count -gt 0) {
                    if (isLive $db[$selected] $liveSessionIds) {
                        $transientError = 'Cannot unregister a live session — exit Claude first.'
                    } else {
                        $db.RemoveAt($selected)
                        saveDb $db $dbPath
                        if ($selected -ge $db.Count) { $selected = [Math]::Max(0, $db.Count - 1) }
                    }
                }
            }
            { $_ -in 'Q', 'q', 'Escape' } { [Console]::Clear(); return }
        }
    }
}

function renderList($db, $selected, $liveSessionIds, $orphans, $crossFlags, $notices, $transientError) {
    [Console]::Clear()
    Write-Host '  Plan Launcher' -ForegroundColor Cyan
    Write-Host ''

    if ($db.Count -eq 0) { Write-Host '  (no open plans — press O to open one)' -ForegroundColor DarkGray }

    $maxNameLen  = if ($db.Count -gt 0) { ($db | ForEach-Object { (Split-Path $_.planFile -Leaf).Length } | Measure-Object -Maximum).Maximum } else { 0 }
    $maxStateLen = if ($db.Count -gt 0) { ($db | ForEach-Object { $_.state.Length } | Measure-Object -Maximum).Maximum } else { 0 }

    for ($i = 0; $i -lt $db.Count; $i++) {
        $entry    = $db[$i]
        $live     = isLive $entry $liveSessionIds
        $isCross  = $crossFlags -contains $entry.planFile
        $prefix   = if ($i -eq $selected) { '→ ' } else { '  ' }
        $status   = if ($live) { '[live]   ' } else { '[dormant]' }
        $statusFg = if ($live) { 'Green' } else { 'DarkGray' }
        $nameFg   = if ($i -eq $selected) { 'White' } else { 'Gray' }
        $planName = Split-Path $entry.planFile -Leaf

        Write-Host -NoNewline $prefix
        Write-Host -NoNewline $status -ForegroundColor $statusFg
        Write-Host -NoNewline "  $($planName.PadRight($maxNameLen))" -ForegroundColor $nameFg
        Write-Host -NoNewline "  $($entry.state.PadRight($maxStateLen))"
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

function changeState($db, $entry) {
    clearConsole
    Write-Host "  Change state: $(Split-Path $entry.planFile -Leaf)" -ForegroundColor Cyan
    Write-Host ''
    Write-Host "  Current state: $($entry.state)"
    Write-Host ''
    Write-Host '  New state:  [D] Discussing  [I] In-progress  [R] Ready  [Esc] cancel'
    $key = readStateKey
    $newState = switch ($key.Key) {
        'D' { 'discussing' }
        'I' { 'in-progress' }
        'R' { 'ready' }
        default { $null }
    }
    if ($newState -and $newState -ne $entry.state) {
        $entry.state = $newState
        saveDb $db $dbPath
    }
}

function openProject($db, $entry, $liveSessionIds) {
    if (isLive $entry $liveSessionIds) {
        Write-Host 'A Claude session is already live for this plan — switch to it instead.' -ForegroundColor Yellow
        $null = Read-Host 'Press Enter to return'
        return $false
    }
    if ($entry.state -eq 'ready') {
        $entry.state      = 'in-progress'
        $entry.sessionIds = @()
        $entry.cwd        = normalizePath $PWD.Path
        saveDb $db $dbPath
        writeLaunchIntent $entry.planFile $entry.cwd
        $exitCode = launchCl $entry.cwd "Please do the next step in $($entry.planFile)"
        clearLaunchIntent
        showLaunchError $exitCode
        if ($exitCode -ne 0) { return $false }
    } else {
        $sid = pickSessionId $entry
        if ($sid) {
            $entry.sessionIds = @($sid)
            saveDb $db $dbPath
            $script:launchPrewriteSid = $sid
            $script:launchPrewriteCwd = normalizePath $entry.cwd
            $exitCode = launchCl $entry.cwd --resume $sid
            if ($exitCode -ne 0) {
                $entry.sessionIds = @()
                saveDb $db $dbPath
                clearConsole
                Write-Host 'Session not found — session ID cleared. Press Enter again to start fresh.' -ForegroundColor Yellow
                $null = Read-Host 'Press Enter to return'
                return $false
            }
        } else {
            $entry.cwd = normalizePath $PWD.Path
            if ($entry.state -eq 'discussing') { $entry.state = 'in-progress' }
            saveDb $db $dbPath
            writeLaunchIntent $entry.planFile $entry.cwd
            $exitCode = launchCl $entry.cwd "Let's continue work on $($entry.planFile)"
            clearLaunchIntent
            showLaunchError $exitCode
            if ($exitCode -ne 0) { return $false }
        }
    }
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

function launchCl([string] $cwd) {
    resetConsoleMode
    # Use Start-Process -NoNewWindow so the child process inherits the console directly,
    # bypassing PowerShell's pipeline stdout/stderr capture which breaks interactive TUI apps.
    # Use -EncodedCommand (Base64) to avoid Windows command-line quoting issues: Start-Process
    # joins -ArgumentList with spaces without re-quoting, so inner quotes are stripped by argv
    # parsing before pwsh reassembles them for -Command. Base64 has no special characters.
    $argStr   = ($args | ForEach-Object { '"' + ($_ -replace '"', '""') + '"' }) -join ' '
    $cmd      = if ($argStr) { "& cl $argStr" } else { '& cl' }
    $encoded  = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    $spParams = @{ FilePath = 'pwsh'; ArgumentList = @('-NoLogo', '-EncodedCommand', $encoded); NoNewWindow = $true; PassThru = $true }
    if ($cwd) { $spParams.WorkingDirectory = $cwd }
    try {
        $proc = Start-Process @spParams
        # Pre-write the running file so the session shows live immediately, before the first
        # UserPromptSubmit hook fires. Only done for resume launches where the sid is known.
        if ($script:launchPrewriteSid) {
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

function pickSessionId($entry) {
    $ids = @($entry.sessionIds | Where-Object { $_ })
    if ($ids.Count -eq 0) { return $null }
    if ($ids.Count -eq 1) { return $ids[0] }

    Write-Host 'Multiple sessions — pick one:'
    for ($i = 0; $i -lt $ids.Count; $i++) { Write-Host "  [$i] $($ids[$i])" }
    while ($true) {
        $choice = Read-Host 'Number'
        $n = 0
        if ([int]::TryParse($choice, [ref]$n) -and $n -ge 0 -and $n -lt $ids.Count) {
            return $ids[$n]
        }
        Write-Host "  Enter a number between 0 and $($ids.Count - 1)" -ForegroundColor Red
    }
}

function getAvailablePlanFiles([string] $plansDir) {
    $base = normalizePath $plansDir
    return @(Get-ChildItem $plansDir -Filter '*.md' -File -Recurse |
        Where-Object {
            $rel      = (normalizePath $_.FullName).Substring($base.Length + 1)
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
            ($rel -notmatch '(^|/)done/') -and ($baseName -notmatch '_done$')
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

    Write-Host ''
    Write-Host 'Initial state:  [D] Discussing (default)  [I] In-progress  [R] Ready'
    $key = readStateKey
    $state = switch ($key.Key) { 'I' { 'in-progress' } 'R' { 'ready' } default { 'discussing' } }

    $entry = [pscustomobject]@{
        planFile   = $planFile
        state      = $state
        cwd        = normalizePath $PWD.Path
        sessionIds = @()
    }
    $db.Add($entry)

    clearConsole
    if ($state -eq 'ready') {
        $entry.state = 'in-progress'
        saveDb $db $dbPath
        writeLaunchIntent $entry.planFile $entry.cwd
        $exitCode = launchCl $entry.cwd "Please do the next step in $planFile"
        clearLaunchIntent
        showLaunchError $exitCode
        if ($exitCode -ne 0) { return $false }
    } else {
        saveDb $db $dbPath
        writeLaunchIntent $entry.planFile $entry.cwd
        $exitCode = launchCl $entry.cwd "We're starting work on $planFile - please review, and then let's discuss next steps."
        clearLaunchIntent
        showLaunchError $exitCode
        if ($exitCode -ne 0) { return $false }
    }
    return $true
}

function registerProject($db, $orphans, $liveSessionIds) {
    if ($orphans.Count -eq 0) {
        Write-Host 'No unregistered sessions.' -ForegroundColor Yellow
        $null = Read-Host 'Press Enter to return'
        return
    }

    $sidIdx = pickFromList $orphans { param($s) $s } 'Register — pick session'
    if ($null -eq $sidIdx) { return }
    $sid = $orphans[$sidIdx]

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
            state      = 'in-progress'
            cwd        = normalizePath $PWD.Path
            sessionIds = @()
        }
        $db.Add($entry)
    }

    if ($sid -notin $entry.sessionIds) {
        $entry.sessionIds = @($entry.sessionIds) + @($sid)
    }
    $null = $liveSessionIds.Add($sid)
    $orphans.Remove($sid) | Out-Null
    saveDb $db $dbPath
}

function pickFromList($items, $labelFn, $title) {
    $selected = 0
    $labels   = @($items | ForEach-Object { & $labelFn $_ })

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
            state      = $_.state
            cwd        = $_.cwd
            sessionIds = @($_.sessionIds | Where-Object { $_ })
        }
    })
}

function saveDb($db, [string] $path) {
    $null = New-Item -ItemType Directory -Path (Split-Path $path) -Force
    (ConvertTo-Json -InputObject @($db) -Depth 5) | Set-Content $path -Encoding UTF8
}

# --- Process detection ---

function getLiveClaudePids {
    return @(Get-Process claude -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
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

    $unmatched = [System.Collections.Generic.List[object]]::new()

    # Pass 1: resolve sessions already in the db by ID, populating liveSessionIds.
    foreach ($file in Get-ChildItem $rDir -Filter 'pid_*.txt' -ErrorAction SilentlyContinue) {
        $filePid = [int]($file.BaseName -replace 'pid_', '')
        if ($filePid -notin $livePids) { continue }

        $data = Get-Content $file.FullName -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if (-not $data -or -not $data.session_id -or -not $data.cwd) { continue }

        if ($sidMap.ContainsKey($data.session_id)) {
            $null = $liveSessionIds.Add($data.session_id)
        } elseif ($data.planFile) {
            $planEntry = $entries | Where-Object { $_.planFile -eq $data.planFile } | Select-Object -First 1
            if ($planEntry) {
                if ($data.session_id -notin $planEntry.sessionIds) {
                    $planEntry.sessionIds = @($planEntry.sessionIds) + @($data.session_id)
                }
                $sidMap[$data.session_id] = $planEntry
                $null = $liveSessionIds.Add($data.session_id)
            } else {
                $unmatched.Add($data)
            }
        } else {
            $unmatched.Add($data)
        }
    }

    # Pass 2: cwd-match new sessions, excluding entries already occupied by a live session.
    # This lets a new session find the correct entry even when multiple entries share a cwd.
    foreach ($data in $unmatched) {
        $sid        = $data.session_id
        $fileCwd    = normalizePath $data.cwd
        $cwdMatches = @($entries | Where-Object { (normalizePath $_.cwd) -eq $fileCwd -and -not (isLive $_ $liveSessionIds) })
        $cwdEntry   = if ($cwdMatches.Count -eq 1) { $cwdMatches[0] } else { $null }

        if ($cwdEntry) {
            $cwdEntry.sessionIds = @($cwdEntry.sessionIds) + @($sid)
            $sidMap[$sid] = $cwdEntry
        } else {
            $orphans.Add($sid) | Out-Null
        }

        $null = $liveSessionIds.Add($sid)
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
    $configScript = Resolve-PratLibFile 'lib/claude/Get-PlansDir.ps1' -ErrorAction SilentlyContinue
    if ($configScript) { return & $configScript }
    return $null
}

function getSyncPath {
    Import-Module "$home/prat/lib/PratBase/PratBase.psd1" -ErrorAction SilentlyContinue
    $configScript = Resolve-PratLibFile 'lib/claude/Get-PlanTrackingConfig.ps1' -ErrorAction SilentlyContinue
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
    $heading = Get-Content $path -TotalCount 10 | Where-Object { $_ -match '^# ' } | Select-Object -First 1
    if ($heading) { return $heading -replace '^# ', '' }
    return ''
}

function normalizePath([string] $p) { $p -replace '\\', '/' }

function writeLaunchIntent([string] $planFile, [string] $cwd) {
    $null = New-Item -ItemType Directory $runningDir -Force
    [pscustomobject]@{planFile = $planFile; cwd = $cwd} |
        ConvertTo-Json -Compress |
        Set-Content "$runningDir/launch_intent.json" -Encoding UTF8
}

function clearLaunchIntent {
    Remove-Item "$runningDir/launch_intent.json" -Force -ErrorAction SilentlyContinue
}

if ($MyInvocation.InvocationName -ne '.') { main }
