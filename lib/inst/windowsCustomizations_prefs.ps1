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

    if (!(Test-Path $settingsFile)) {
        $stage.EnsureManualStep("windowsTerminal\firstRun", "Windows Terminal settings.json not found. Open Windows Terminal once, then re-run deploy.")
        return
    }

    $content = Import-TextFile $settingsFile
    $content = customizeTerminal $content $settingsFile
    Install-TextToFile $stage $settingsFile $content -BackupFile
}

# --- Terminal customization (JSON-tools based) ---

function getGuid_PsProfile         { "{574e775e-4f2a-5b96-ac1e-a2962a402336}" }
function getGuid_PsElevatedProfile  { "{c30c622b-46f4-4ea9-a87e-e2522c699a56}" }

# Surgically updates Windows Terminal settings content using JSON tools.
# $bgColor: background color for the PowerShell profile. Defaults to "#1F2233".
# TODO: detect primary vs VM and pick color accordingly — see plans/d_terminal.md.
function customizeTerminal([string] $content, [string] $filename, [string] $bgColor = "#1F2233") {
    $content = setJsonPropertyValue $content @("initialCols")    "145"                          $filename
    $content = setJsonPropertyValue $content @("initialRows")    "50"                           $filename
    $content = setJsonPropertyValue $content @("defaultProfile") "`"$(getGuid_PsProfile)`""     $filename

    $content = Update-JsonSection $content @("profiles", "defaults") (buildDefaultsSection) $filename

    $content = Update-JsonSection $content @("profiles", "list", "[@guid='$(getGuid_PsProfile)']")        (buildPsProfileSection $bgColor) $filename
    $content = Update-JsonSection $content @("profiles", "list", "[@guid='$(getGuid_PsElevatedProfile)']") (buildElevatedProfileSection)    $filename

    $content = Move-JsonArrayElementToFirst $content @("profiles", "list", "[@guid='$(getGuid_PsElevatedProfile)']") $filename
    $content = Move-JsonArrayElementToFirst $content @("profiles", "list", "[@guid='$(getGuid_PsProfile)']")        $filename

    return $content
}

# Replaces a scalar JSON property value, preserving indentation and trailing comma.
# If the key is not found, returns $content unchanged.
function setJsonPropertyValue([string] $content, [string[]] $pathArray, [string] $newJsonValue, [string] $filename) {
    $range = Find-JsonSection $content $pathArray $filename
    if ($null -eq $range) { return $content }

    $line  = ((ConvertTo-UnixLineEndings $content) -split "`n")[$range.idxFirst]
    $indent        = [regex]::Match($line, '^\s*').Value
    $key           = [regex]::Match($line, '"([^"]+)"\s*:').Groups[1].Value
    $trailingComma = if ($line.TrimEnd().EndsWith(',')) { ',' } else { '' }
    return Format-ReplaceLines $content $range "$indent`"$key`": $newJsonValue$trailingComma"
}

function buildDefaultsSection {
    return @(
        '        "defaults": {'
        '            "elevate": false,'
        '            "font": {'
        '                "face": "Cascadia Mono",'
        '                "size": 10'
        '            },'
        '            "padding": "4"'
        '        }'
    ) -join "`n"
}

function buildPsProfileSection([string] $bgColor) {
    $guid = getGuid_PsProfile
    return @(
        '        {'
        "            `"background`": `"$bgColor`","
        '            "commandline": "\"C:\\Program Files\\PowerShell\\7\\pwsh.exe\" -NoLogo",'
        "            `"guid`": `"$guid`","
        '            "hidden": false,'
        '            "name": "PowerShell",'
        '            "opacity": 100,'
        '            "scrollbarState": "visible",'
        '            "source": "Windows.Terminal.PowershellCore",'
        '            "useAcrylic": false'
        '        }'
    ) -join "`n"
}

function buildElevatedProfileSection {
    $guid = getGuid_PsElevatedProfile
    return @(
        '        {'
        '            "background": "#3c2423",'
        '            "commandline": "\"C:\\Program Files\\PowerShell\\7\\pwsh.exe\" -NoLogo",'
        '            "elevate": true,'
        "            `"guid`": `"$guid`","
        '            "hidden": false,'
        '            "name": "PowerShell (Elevated)",'
        '            "opacity": 100,'
        '            "scrollbarState": "visible",'
        '            "useAcrylic": false'
        '        }'
    ) -join "`n"
}

if ($MyInvocation.InvocationName -ne ".") {
    main $installationTracker
}
