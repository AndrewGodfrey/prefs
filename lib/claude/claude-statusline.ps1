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

if ($MyInvocation.InvocationName -ne '.') {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $j = [Console]::In.ReadToEnd() | ConvertFrom-Json

    # 5-bar context indicator
    # $fixedPct: system prompt + tools + mandatory memory files — not in user's control (~8%). Recheck periodically.
    # $bufferPct: autocompact buffer (~16.5%). Recheck periodically.
    $fixedPct  = 8.0
    $bufferPct = 16.5
    $usablePct = 100 - $fixedPct - $bufferPct   # 75.5% — the range from session-start to autocompact
    $consumed  = [math]::Max(0, $j.context_window.used_percentage - $fixedPct)
    $bars      = if ($usablePct -gt 0) { [math]::Min(5, [math]::Round($consumed / $usablePct * 5)) } else { 5 }
    $bar       = ([string]'▰' * $bars) + ([string]'▱' * (5 - $bars))

    # Rate limit usage (only present for Pro/Max, only after first API call)
    $rlParts = @()
    $rl = $j.rate_limits
    if ($rl) {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $part = Get-RateLimitDisplay $rl.five_hour '5h' 5 300   180  60   15 $now
        if ($part) { $rlParts += $part }
        $part = Get-RateLimitDisplay $rl.seven_day '7d' 7 10080 4320 1440 0  $now
        if ($part) { $rlParts += $part }
    }
    $rlStr = if ($rlParts) { " $($rlParts -join ' ')" } else { '' }

    # CWD in prompt format (mirrors On-PromptLocationChanged.ps1)
    $cwd = $j.cwd
    $project = Get-PratProject $cwd -ErrorAction SilentlyContinue
    if ($project) {
        $subdir  = if ($project.subdir) { " $($project.subdir)/" -replace '\\', '/' } else { '' }
        $bk      = if ($project.buildKind) { "($($project.buildKind))" } else { '' }
        $loc     = "[$($project.id.ToLower())]$bk$subdir"
    } else {
        $loc = $cwd
    }

    $shouldWarn = & (Resolve-PratLibFile "lib/claude/Get-ShouldWarnOutsideSandbox.ps1")
    $sandbox = if ($shouldWarn) { '⚠️ ' } else { '' }
    Write-Host "$sandbox$bar $loc$rlStr"
}
