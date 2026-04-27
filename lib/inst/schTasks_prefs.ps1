param($installationTracker, [string[]] $Suppress = @())

$stage = $installationTracker.StartStage('schTasks')

if ('claudeUpdateDetection' -notin $Suppress) {
    Install-DailyScheduledTask $stage "detectClaudeUpdate" "Detect Claude update" "$home\prefs\lib\schtasks\daily_detectClaudeUpdate.ps1" "1:47AM"
}

$installationTracker.EndStage($stage)
