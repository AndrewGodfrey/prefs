param([switch] $NoCwd)
Import-Module "$home\prat\lib\PratBase\PratBase.psd1" -ErrorAction SilentlyContinue

# Returns a formatted rate-limit display string, or nothing if the window is too new or too close to reset.
# Color: yellow-green = on pace to exhaust; yellow = within $yellowThresholdMins; orange = within $redThresholdMins; red = completely out.
function Get-RateLimitDisplay($window, $label, $barWidth, $totalMins, $yellowThresholdMins, $redThresholdMins, $minMinsLeft, $now) {
    if ($null -eq $window) { return }
    $usedPct  = $window.used_percentage
    $minsLeft = [math]::Max(0, $window.resets_at - $now) / 60
    if ($minsLeft -lt $minMinsLeft) { return }

    $timeStr = Format-Duration ($minsLeft * 60)

    $elapsedMins = $totalMins - $minsLeft
    $color = $creset = ''
    if ($usedPct -ge 100) {
        $color  = "`e[38;2;220;50;50m"    # red: completely out
        $creset = "`e[0m"
    } elseif ($elapsedMins -gt 5 -and $usedPct -gt 0) {
        $elapsedPct = $elapsedMins / $totalMins * 100
        if ($usedPct -gt $elapsedPct) {
            $minsToExhaust = (100 - $usedPct) * $elapsedMins / $usedPct
            $color = if ($minsToExhaust -lt $redThresholdMins) {
                "`e[38;2;255;120;0m"       # orange: exhaustion imminent
            } elseif ($minsToExhaust -lt $yellowThresholdMins) {
                "`e[38;2;255;200;0m"       # yellow: in-between
            } else {
                "`e[38;2;140;185;35m"      # yellow-green: on pace to exhaust
            }
            $creset = "`e[0m"
        }
    }

    $filledBars = [math]::Min($barWidth, [math]::Round($usedPct / 100 * $barWidth))
    $rlBar = ([string]'▰' * $filledBars) + ([string]'▱' * ($barWidth - $filledBars))
    "${color}${label}:$rlBar $timeStr${creset}"
}

# Claude Code sends context_window.used_percentage; Copilot CLI sends current_context_used_percentage (top-level).
# $fixedPct: system prompt + tools + mandatory memory files — not in user's control (~8%). Recheck periodically.
# $bufferPct: autocompact buffer (~16.5%). Recheck periodically.
function Get-ContextBar($j) {
    $fixedPct  = 8.0
    $bufferPct = 16.5
    $usablePct = 100 - $fixedPct - $bufferPct   # 75.5% — the range from session-start to autocompact
    $rawPct    = if ($null -ne $j.context_window.used_percentage) { $j.context_window.used_percentage }
                 elseif ($null -ne $j.current_context_used_percentage) { $j.current_context_used_percentage }
                 else { 0 }
    $consumed  = [math]::Max(0, $rawPct - $fixedPct)
    $bars      = if ($usablePct -gt 0) { [math]::Min(5, [math]::Round($consumed / $usablePct * 5)) } else { 5 }
    ([string]'▰' * $bars) + ([string]'▱' * (5 - $bars))
}

# Rate limit usage (only present for Pro/Max, only after first API call)
function Get-RateLimitBarString($rl, $now) {
    if (-not $rl) { return '' }
    $rlParts = @()
    $part = Get-RateLimitDisplay $rl.five_hour '5h' 5 300   180  60   15 $now
    if ($part) { $rlParts += $part }
    $part = Get-RateLimitDisplay $rl.seven_day '7d' 7 10080 4320 1440 0  $now
    if ($part) { $rlParts += $part }
    if ($rlParts) { " $($rlParts -join ' ')" } else { '' }
}

# CWD in prompt format (mirrors On-PromptLocationChanged.ps1)
function Format-LocationString($project, $cwd) {
    if ($project) {
        $subdir  = if ($project.subdir) { " $($project.subdir)/" -replace '\\', '/' } else { '' }
        $bk      = if ($project.buildKind) { "($($project.buildKind))" } else { '' }
        " [$($project.id.ToLower())]$bk$subdir"
    } else {
        " $cwd"
    }
}

function Get-StatusLineString($j, $now, [switch] $NoCwd) {
    $bar = Get-ContextBar $j
    $rlStr = Get-RateLimitBarString $j.rate_limits $now

    $loc = ''
    if (-not $NoCwd) {
        # Prefer the dir 'cl' was launched from over Claude Code's reported cwd, which is the role dir
        # (see CL_LAUNCH_CWD in Invoke-AgentSession.ps1). Falls back to $j.cwd for non-'cl' sessions.
        $cwd = if ($env:CL_LAUNCH_CWD) { $env:CL_LAUNCH_CWD } else { $j.cwd }
        $project = Get-PratProject $cwd -ErrorAction SilentlyContinue
        $loc = Format-LocationString $project $cwd
    }

    # Active plan, set by the pl launcher (Launch-Plan.ps1); absent for plain cl sessions.
    # ASCII marker on purpose: symbol glyphs come from fallback fonts with unpredictable cell
    # width (observed: U+270E rendered 2 cells), which can trigger repaint artifacts.
    $planStr = if ($env:CL_PLAN_FILE) { " plan:$([System.IO.Path]::GetFileNameWithoutExtension($env:CL_PLAN_FILE))" } else { '' }

    # Set by cl (Start-CommandLineAgent.ps1) at launch; absent for sessions not launched that way.
    $sandboxWarn = if ($env:CL_SANDBOX_MODE -ne '1') { "`e[38;2;255;200;0m*`e[0m " } else { '' }

    # Model used for the last turn (Claude Code sends the model active for the response just completed)
    $modelStr = if ($j.model.display_name) { "   ($($j.model.display_name))" } else { '' }

    "$sandboxWarn$bar$loc$planStr$rlStr$modelStr"
}

if ($MyInvocation.InvocationName -ne '.') {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $j = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Write-Host (Get-StatusLineString $j $now -NoCwd:$NoCwd)
}
