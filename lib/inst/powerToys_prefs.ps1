param($installationTracker)

function Set-PowerToysEnabledModules([hashtable] $enabled, [string[]] $keepEnabled) {
    foreach ($key in @($enabled.Keys)) {
        $enabled[$key] = $key -in $keepEnabled
    }
}

if ($MyInvocation.InvocationName -ne ".") {
    $stage = $installationTracker.StartStage('powerToys-settings')

    $settingsFile = "$env:LOCALAPPDATA\Microsoft\PowerToys\settings.json"

    if (!(Test-Path $settingsFile)) {
        $stage.EnsureManualStep("powerToys/firstRun", @"
PowerToys settings file not found. Launch PowerToys once to create it, then re-run deploy.
"@)
    } else {
        $json = ConvertFrom-Json (Get-Content -Raw $settingsFile) -AsHashtable
        Set-PowerToysEnabledModules $json.enabled @("FancyZones")
        $newText = ConvertTo-Json $json -Depth 10
        Install-TextToFile $stage $settingsFile $newText -BackupFile
    }

    $installationTracker.EndStage($stage)
}
