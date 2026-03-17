param($installationTracker, [string[]] $Suppress = @())

if ("chrome/install" -notin $Suppress) {
    $stage = $installationTracker.StartStage('chrome')
    # Chrome isn't my default browser, but it seems to be the best PDF viewer.
    $stage.EnsureManualStep("chrome\install", "https://www.google.com/chrome/")

    $installationTracker.EndStage($stage)
}