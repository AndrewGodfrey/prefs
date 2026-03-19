param($installationTracker, [string[]] $Suppress = @())

foreach ($packageId in @("pwsh", "wget", "df", "ditto", "sysinternals", "claude", "python", "nuget", "powertoys")) {
    if ("pkg/$packageId" -notin $Suppress) {
        Install-PratPackage $installationTracker $packageId
    }
}

if ("pkg/winmerge" -notin $Suppress) {
    # WinMerge: used for move-block detection when reviewing Claude-assisted reorganizations.
    # Beyond Compare is the fallback for harder cases.
    # TODO: Develop a tool for capturing registry changes made via UI preference dialogs,
    #       so that settings like the one below can be automated.
    Install-PratPackage $installationTracker "winmerge"
    $stage = $installationTracker.StartStage('winmerge-settings')
    $stage.EnsureManualStep("winmerge\movedBlockDetection", @"
Enable moved block detection (off by default):
WinMerge -> Edit -> Options -> Compare
Check "Enable moved block detection"
"@)
    $installationTracker.EndStage($stage)
    # TODO: WinMerge has some popups with questions - ignore EOL differences; auto-load content. Save my answers (yes and yes).
}

if ("pkg/pushoverNotification" -notin $Suppress) {
    # pushoverNotification: token path is environment-specific.
    $getPratTokensScript = Resolve-PratLibFile "lib/inst/Get-PratTokens.ps1"
    if ($null -ne $getPratTokensScript) {
        $tokenFile = & $getPratTokensScript "pushoverTokens"
        Install-PratPackage $installationTracker "pushoverNotification" $tokenFile
    }
}