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
Write-Host "$sandbox$bar $loc"
