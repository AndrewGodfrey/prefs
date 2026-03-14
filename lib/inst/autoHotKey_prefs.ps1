param($installationTracker, [string[]] $Suppress = @())

Install-PratPackage $installationTracker "autohotkey"

$stage = $installationTracker.StartStage('autohotkey')
Install-UserEnvironmentVariable $stage 'ahk_launch_myEditor' 'VsCode'
if ('autohotkey-launch' -notin $Suppress) {
    Install-StartAutoHotKeyScript $stage "$home\prefs\lib\Hotkey-LaunchSomething.ahk"
}

$installationTracker.EndStage($stage)
