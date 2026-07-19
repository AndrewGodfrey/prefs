param($installationTracker, [string[]] $Suppress = @())

$stage = $installationTracker.StartStage('schTasks')

# Claude update-detection task removed: Claude is now pinned (see packages_prefs.ps1) rather than
# tracked to latest.
$stage.NoteMigrationStep((Get-Date "2026-07-19"))
if (Get-ScheduledTask -TaskName "Detect Claude update" -ErrorAction SilentlyContinue) {
    $stage.OnChange()
    Unregister-ScheduledTask -TaskName "Detect Claude update" -Confirm:$false
}

$installationTracker.EndStage($stage)
# OmitFromCoverageReport: pure orchestration, not worth the mocking cost
