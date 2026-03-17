param($installationTracker)

function main($installationTracker) {
    $stage = $installationTracker.StartStage('windows customizations')

    $isWin10 = [System.Environment]::OSVersion.Version.Build -lt 22000
    if ($isWin10) {
        $stage.EnsureManualStep("windows\incontrol", "Download InControl to my desktop, use it to avoid Win11. grc.com/incontrol")
    }

    installShellCustomization $stage
    installWindowsTerminalCustomization $stage

    $installationTracker.EndStage($stage)
}

function isWin11 {
    $osVersion = [System.Environment]::OSVersion.Version
    return ($osVersion.Major -eq 10 -and $osVersion.Build -ge 22000) -or ($osVersion.Major -gt 10)
}

function installShellCustomization($stage) {
    Install-WindowsStartMenuLocalOnly $stage
    Install-WindowsSecondaryClockUTC $stage
    Install-WindowsTaskbarCleanup $stage

    if (!(isWin11)) {
        # Disable keyboard shortcuts I trigger by accident:
        $stage.EnsureManualStep("windows\textShortcuts", @"

- Win + I (i.e. Settings) > Time & Language > Language > Keyboard > Input language hot keys
  This should open the "Text Services and Input Languages" dialog.
- Change Key Sequence > choose "Not Assigned" for both.
- Language Bar > select "Hidden".
"@)
    }

    $stage.EnsureManualStep("taskbar\taskpaneIcons", @"
  - Right-click taskbar
  - Taskbar settings > Select which icons appear on the taskbar: Show "AutoHotKey", and hide OneDrive.
"@)
}

function installWindowsTerminalCustomization($stage) {
    $settingsFile = "$env:localappdata\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"

    $json = ConvertFrom-Json (Get-Content -Raw $settingsFile) -AsHashtable

    customizeTerminal $json

    $newText = ConvertTo-Json $json -Depth 20
    Install-TextToFile $stage $settingsFile $newText -BackupFile
}

function customizeTerminal($json) {
    $json.initialCols = 140
    $json.initialRows = 50
    $json.profiles.defaults.elevate = $false
    $json.profiles.defaults.font = @{ size = 10 }

    ensurePscoreProfile $json
    $json.defaultProfile = getGuid_PsProfile
}

function findProfileIndex($list, $name) {
    for ([int] $index = 0; $index -lt $list.length; $index++) {
        if ($list[$index].name -eq $name) { return $index }
    }
    return -1
}

function ensureProfile($profiles, $name) {
    $index = findProfileIndex $profiles.list $name
    if ($index -ne -1) { return $profiles.list[$index] }

    $newItem = [ordered] @{ name = $name }
    $profiles.list += $newItem
    return $newItem
}

function ensurePscoreProfile($json) {
    $profile = ensureProfile $json.profiles "PowerShell"

    $profile.background = "#1F2233"
    $profile.commandline = '"C:\Program Files\PowerShell\7\pwsh.exe" -NoLogo'
    $profile.guid = getGuid_PsProfile
    $profile.hidden = $false
    $profile.opacity = 100
    $profile.padding = "4"
    $profile.scrollbarState = "visible"
    $profile.source = "Windows.Terminal.PowershellCore"
    $profile.useAcrylic = $false
}

function getGuid_PsProfile { "{574e775e-4f2a-5b96-ac1e-a2962a402336}" }

main $installationTracker
