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
    $esc = [char]27
    if ($null -ne $rl.five_hour) {
        $fiveH       = $rl.five_hour
        $usedPct     = $fiveH.used_percentage
        $leftPct     = 100 - $usedPct
        $secsLeft    = [math]::Max(0, $fiveH.resets_at - $now)
        $minsLeft    = $secsLeft / 60

        if ($minsLeft -ge 15) {
            $timeStr     = if ($minsLeft -ge 90) { "$([math]::Round($minsLeft / 60, 1))h" } else { "$([math]::Round($minsLeft))m" }
            $elapsedMins = 300 - $minsLeft   # 5h window = 300 min
            $color       = ''
            $creset      = ''
            if ($elapsedMins -gt 5 -and $usedPct -gt 0) {
                $minsToExhaust = $leftPct / ($usedPct / $elapsedMins)
                if ($minsToExhaust -lt $minsLeft) {
                    $color  = if ($minsToExhaust -lt 60) { "$esc[31m" } else { "$esc[33m" }
                    $creset = "$esc[0m"
                }
            }
            $rlBars5  = [math]::Min(5, [math]::Round($usedPct / 100 * 5))
            $rlBar5   = ([string]'▰' * $rlBars5) + ([string]'▱' * (5 - $rlBars5))
            $rlParts += "${color}5h:$rlBar5 $timeStr${creset}"
        }
    }
    if ($null -ne $rl.seven_day) {
        $sevenD      = $rl.seven_day
        $usedPct7    = $sevenD.used_percentage
        $leftPct7    = 100 - $usedPct7
        $secsLeft7   = [math]::Max(0, $sevenD.resets_at - $now)
        $minsLeft7   = $secsLeft7 / 60
        $timeStr7    = if ($minsLeft7 -ge 1440) { "$([math]::Round($minsLeft7 / 1440, 1))d" } `
                       elseif ($minsLeft7 -ge 90) { "$([math]::Round($minsLeft7 / 60))h" } `
                       else { "$([math]::Round($minsLeft7))m" }
        $elapsedMins7 = 10080 - $minsLeft7   # 7d window = 10080 min
        $color7       = ''
        $creset7      = ''
        if ($elapsedMins7 -gt 5 -and $usedPct7 -gt 0) {
            $minsToExhaust7 = $leftPct7 / ($usedPct7 / $elapsedMins7)
            if ($minsToExhaust7 -lt $minsLeft7) {
                $color7  = if ($minsToExhaust7 -lt 1440) { "$esc[31m" } else { "$esc[33m" }
                $creset7 = "$esc[0m"
            }
        }
        $rlBars7  = [math]::Min(7, [math]::Round($usedPct7 / 100 * 7))
        $rlBar7   = ([string]'▰' * $rlBars7) + ([string]'▱' * (7 - $rlBars7))
        $rlParts += "${color7}7d:$rlBar7 $timeStr7${creset7}"
    }
}
$rlStr = if ($rlParts) { " $($rlParts -join ' ')" } else { '' }

# CWD in prompt format (mirrors On-PromptLocationChanged.ps1)
$cwd = $j.cwd
Import-Module "$home\prat\lib\PratBase\PratBase.psd1" -ErrorAction SilentlyContinue
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
