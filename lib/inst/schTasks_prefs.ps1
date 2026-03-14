param($installationTracker, [string[]] $Suppress = @())

$stage = $installationTracker.StartStage('schTasks')

if ('claudeUpdateDetection' -notin $Suppress) {
    Install-DailyScheduledTask $stage "detectClaudeUpdate" "Detect Claude update" "$home\prefs\lib\schtasks\daily_detectClaudeUpdate.ps1" "1:47AM"
}

# 2026-03-13: task moved from de to prefs; delete old task manually on each machine if present.
if (Get-ScheduledTask -TaskName "de - Detect Claude update" -ErrorAction SilentlyContinue) {
    Write-Warning "Manual step needed: delete scheduled task 'de - Detect Claude update' (replaced by 'Detect Claude update')"
}
$stage.NoteMigrationStep((Get-Date "2026-03-13"))

$installationTracker.EndStage($stage)
