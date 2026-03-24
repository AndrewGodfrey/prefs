# Launch-Plan.ps1  (alias: pl)
# Interactive launcher for plan-based Claude sessions.
# Tracks open plans, detects live/dormant Claude processes, and launches or resumes sessions.

param([switch] $NoSyncBackedWarning)

$dbPath     = "$home/prat/auto/context/db.json"
$runningDir = "$home/prat/auto/context/running"

function main {
    Import-Module "$home/prat/lib/PratBase/PratBase.psd1" -ErrorAction SilentlyContinue

    $db = [System.Collections.Generic.List[object]]::new()
    foreach ($item in (loadDb $dbPath)) { $db.Add($item) }
    $livePids = getLiveClaudePids
    $resolved = resolveSessionIds $db $runningDir $livePids
    saveDb $db $dbPath
    cleanStaleRunningFiles $runningDir $livePids

    if ($resolved.orphans.Count -gt 0) {
        Write-Warning "lp: untracked Claude session(s): $($resolved.orphans -join ', ')"
    }

    $syncPath   = getSyncPath
    $crossFlags = @()
    if ($syncPath) {
        updatePresenceFile $db $syncPath
        $crossFlags = getCrossMachineFlags $syncPath
    }

    runLauncher $db $resolved.liveSessionIds $resolved.orphans $crossFlags
}

# --- TUI ---

function runLauncher($db, $liveSessionIds, $orphans, $crossFlags) {
    $selected = 0
    while ($true) {
        renderList $db $selected $liveSessionIds $crossFlags
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
            { $_ -in 'Q', 'q', 'Escape' } { [Console]::Clear(); return }
        }
    }
}

function renderList($db, $selected, $liveSessionIds, $crossFlags) {
    [Console]::Clear()
    Write-Host '  Plan Launcher' -ForegroundColor Cyan
    Write-Host ''

    if ($db.Count -eq 0) { Write-Host '  (no open plans — press O to open one)' -ForegroundColor DarkGray }

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
        Write-Host -NoNewline "  $planName" -ForegroundColor $nameFg
        Write-Host -NoNewline "  $($entry.state)"
        if ($isCross) { Write-Host -NoNewline '  ⚠ other-machine' -ForegroundColor Yellow }
        Write-Host ''
    }

    Write-Host ''
    Write-Host '  [↑↓] navigate  [Enter] open  [O] open untracked  [R] register session  [Q] quit' -ForegroundColor DarkCyan
}

# --- Actions ---

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
        launchCl "Please do the next step in $($entry.planFile)"
    } else {
        $sid = pickSessionId $entry
        if ($sid) {
            $entry.sessionIds = @($sid)
            saveDb $db $dbPath
            launchCl --resume $sid
        } else {
            $entry.cwd = normalizePath $PWD.Path
            saveDb $db $dbPath
            launchCl "Let's continue work on $($entry.planFile)"
        }
    }
    return $true
}

function launchCl {
    $tmpErr = [System.IO.Path]::GetTempFileName()
    try {
        & cl @args 2>$tmpErr
        if ($LASTEXITCODE -ne 0) {
            $errText = Get-Content $tmpErr -Raw -ErrorAction SilentlyContinue
            [Console]::Clear()
            Write-Host "cl exited with code $LASTEXITCODE" -ForegroundColor Red
            if ($errText) { Write-Host $errText -ForegroundColor Red }
            $null = Read-Host 'Press Enter to return'
        }
    } finally {
        Remove-Item $tmpErr -ErrorAction SilentlyContinue
    }
}

function pickSessionId($entry) {
    $ids = @($entry.sessionIds | Where-Object { $_ })
    if ($ids.Count -eq 0) { return $null }
    if ($ids.Count -eq 1) { return $ids[0] }

    Write-Host 'Multiple sessions — pick one:'
    for ($i = 0; $i -lt $ids.Count; $i++) { Write-Host "  [$i] $($ids[$i])" }
    $choice = Read-Host 'Number'
    return $ids[[int]$choice]
}

function openUntracked($db) {
    $plansDir = getPlansDir
    if (-not $plansDir) {
        Write-Host 'No plans directory configured — cannot open untracked plans.' -ForegroundColor Yellow
        $null = Read-Host 'Press Enter to return'
        return
    }
    $openPlans = @($db | ForEach-Object { $_.planFile })
    $available = @(Get-ChildItem $plansDir -Filter '*.md' -File |
        Where-Object { (normalizePath $_.FullName) -notin $openPlans } |
        Select-Object -ExpandProperty FullName |
        ForEach-Object { normalizePath $_ })

    if ($available.Count -eq 0) {
        Write-Host 'No unopen plans found.' -ForegroundColor Yellow
        $null = Read-Host 'Press Enter to return'
        return
    }

    $idx = pickFromList $available {
        param($p)
        $name  = Split-Path $p -Leaf
        $title = getPlanTitle $p
        if ($title) { "$name  —  $title" } else { $name }
    } 'Open plan'
    if ($null -eq $idx) { return $false }
    $planFile = $available[$idx]

    Write-Host ''
    Write-Host 'Initial state:  [D] Discussing (default)  [I] In-progress  [R] Ready'
    $key = [Console]::ReadKey($true)
    $state = switch ($key.Key) { 'I' { 'in-progress' } 'R' { 'ready' } default { 'discussing' } }

    $entry = [pscustomobject]@{
        planFile   = $planFile
        state      = $state
        cwd        = normalizePath $PWD.Path
        sessionIds = @()
    }
    $db.Add($entry)

    if ($state -eq 'ready') {
        $entry.state = 'in-progress'
        saveDb $db $dbPath
        launchCl "Please do the next step in $planFile"
    } else {
        saveDb $db $dbPath
        launchCl "We're starting work on $planFile"
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
        Get-ChildItem $plansDir -Filter '*.md' -File |
            Where-Object { (normalizePath $_.FullName) -notin $trackedPaths } |
            ForEach-Object { $allPlans.Add((normalizePath $_.FullName)) }
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
    while ($true) {
        [Console]::Clear()
        Write-Host "  $title" -ForegroundColor Cyan
        Write-Host ''
        for ($i = 0; $i -lt $items.Count; $i++) {
            $prefix = if ($i -eq $selected) { '→ ' } else { '  ' }
            $label  = & $labelFn $items[$i]
            $fg     = if ($i -eq $selected) { 'White' } else { 'Gray' }
            Write-Host "$prefix$label" -ForegroundColor $fg
        }
        Write-Host ''
        Write-Host '  [↑↓] navigate  [Enter] select  [Esc] cancel' -ForegroundColor DarkCyan

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            'UpArrow'   { $selected = if ($selected -gt 0) { $selected - 1 } else { [Math]::Max(0, $items.Count - 1) } }
            'DownArrow' { $selected = if ($selected -lt ($items.Count - 1)) { $selected + 1 } else { 0 } }
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

function resolveSessionIds {
    [CmdletBinding()] param($entries, [string] $rDir, $livePids)
    $liveSessionIds = [System.Collections.Generic.HashSet[string]]::new()
    $orphans        = [System.Collections.Generic.List[string]]::new()

    # Build reverse map: session_id → entry
    $sidMap = @{}
    foreach ($entry in $entries) {
        foreach ($sid in $entry.sessionIds) { $sidMap[$sid] = $entry }
    }

    if (-not (Test-Path $rDir)) { return @{ liveSessionIds = $liveSessionIds; orphans = $orphans } }

    foreach ($file in Get-ChildItem $rDir -Filter 'pid_*.txt' -ErrorAction SilentlyContinue) {
        $filePid = [int]($file.BaseName -replace 'pid_', '')
        if ($filePid -notin $livePids) { continue }

        $data = Get-Content $file.FullName -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if (-not $data -or -not $data.session_id -or -not $data.cwd) { continue }

        $sid      = $data.session_id
        $fileCwd  = normalizePath $data.cwd
        $cwdEntry = $entries | Where-Object { (normalizePath $_.cwd) -eq $fileCwd } | Select-Object -First 1

        if ($sidMap.ContainsKey($sid)) {
            $mapEntry = $sidMap[$sid]
            if ($cwdEntry -and $mapEntry -ne $cwdEntry) {
                Write-Warning "lp: session '$sid' conflicts: recorded under '$($mapEntry.planFile)' but cwd matches '$($cwdEntry.planFile)'"
            }
        } elseif ($cwdEntry) {
            $cwdEntry.sessionIds = @($cwdEntry.sessionIds) + @($sid)
            $sidMap[$sid] = $cwdEntry
        } else {
            $orphans.Add($sid) | Out-Null
        }

        $null = $liveSessionIds.Add($sid)
    }

    return @{ liveSessionIds = $liveSessionIds; orphans = $orphans }
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
    $flagged = @()
    foreach ($file in Get-ChildItem $trackingDir -Filter '*.json' -ErrorAction SilentlyContinue) {
        if ($file.BaseName -eq $env:COMPUTERNAME) { continue }
        $other = Get-Content $file.FullName -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($other -and $other.plans) { $flagged += @($other.plans) }
    }
    return $flagged
}

function getPlansDir {
    Import-Module "$home/prat/lib/PratBase/PratBase.psd1" -ErrorAction SilentlyContinue
    $configScript = Resolve-PratLibFile 'lib/claude/Get-PlansDir.ps1' -ErrorAction SilentlyContinue
    if ($configScript) { return & $configScript }
    Write-Warning 'lp: no plans directory configured — open-untracked unavailable. Provide lib/claude/Get-PlansDir.ps1 in your de repo.'
    return $null
}

function getSyncPath {
    Import-Module "$home/prat/lib/PratBase/PratBase.psd1" -ErrorAction SilentlyContinue
    $configScript = Resolve-PratLibFile 'lib/claude/Get-PlanTrackingConfig.ps1' -ErrorAction SilentlyContinue
    if (-not $configScript) {
        if (-not $NoSyncBackedWarning) {
            Write-Warning 'lp: no sync-backed path configured — cross-machine visibility unavailable. (Suppress with -NoSyncBackedWarning)'
        }
        return $null
    }
    return checkSyncPath (& $configScript)
}

function checkSyncPath {
    [CmdletBinding()] param($path)
    if (-not $path) { return $null }
    if (-not (Test-Path $path)) {
        if (-not $NoSyncBackedWarning) {
            Write-Warning "lp: configured sync path '$path' does not exist — cross-machine visibility unavailable."
        }
        return $null
    }
    return $path
}

# --- Helpers ---

function getPlanTitle([string] $path) {
    $heading = Get-Content $path -TotalCount 10 | Where-Object { $_ -match '^# ' } | Select-Object -First 1
    if ($heading) { return $heading -replace '^# ', '' }
    return ''
}

function normalizePath([string] $p) { $p -replace '\\', '/' }

if ($MyInvocation.InvocationName -ne '.') { main }
