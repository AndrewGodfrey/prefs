param($installationTracker)

function Set-PowerToysEnabledModules([string] $content, [string[]] $keepEnabled, [string] $filename) {
    $json = ConvertFrom-Json $content -AsHashtable
    foreach ($key in @($json.enabled.Keys)) {
        $json.enabled[$key] = $key -in $keepEnabled
    }
    return ConvertTo-Json $json -Depth 100
}

function New-AppliedLayoutEntry($mon, $layout) {
    return [ordered]@{
        device = [ordered]@{
            'monitor'          = $mon['monitor']
            'monitor-instance' = $mon['monitor-instance-id']
            'monitor-number'   = $mon['monitor-number']
            'serial-number'    = $mon['monitor-serial-number']
            'virtual-desktop'  = $mon['virtual-desktop']
        }
        'applied-layout' = [ordered]@{
            uuid                = $layout['uuid']
            type                = 'custom'
            'show-spacing'      = $false
            spacing             = 0
            'zone-count'        = $layout['zone-count']
            'sensitivity-radius' = 20
        }
    }
}

# Build applied-layouts by assigning layouts to monitors by position (left-coordinate order).
# Merges with existing entries: monitors in editor-parameters get layouts by position;
# existing entries for monitors not in editor-parameters are preserved as-is.
function Get-AppliedLayoutsFromEditorParams([hashtable] $editorParams, [hashtable[]] $layouts, [hashtable[]] $existingEntries = @()) {
    $monitors = @($editorParams.monitors | Sort-Object { [int]$_['left-coordinate'] })

    $entries = @()

    # Assign layouts to the rightmost monitors (skipping extras on the left, e.g. laptop screen)
    $assignedInstanceIds = @{}
    $offset = [Math]::Max(0, $monitors.Count - $layouts.Count)
    for ($i = 0; $i -lt [Math]::Min($monitors.Count, $layouts.Count); $i++) {
        $assignedInstanceIds[$monitors[$offset + $i]['monitor-instance-id']] = $true
        $entries += New-AppliedLayoutEntry $monitors[$offset + $i] $layouts[$i]
    }

    # Preserve existing entries for monitors that didn't get a fresh assignment:
    # - monitors in editor-parameters beyond the layout count (e.g. 3rd monitor with only 2 layouts)
    # - monitors from other locations not in editor-parameters at all
    # Entries with no monitor-instance are corrupt/legacy and are dropped.
    foreach ($existing in $existingEntries) {
        $instanceId = $existing.device['monitor-instance']
        if ($instanceId -and -not $assignedInstanceIds.ContainsKey($instanceId)) {
            $entries += $existing
        }
    }

    return [ordered]@{ 'applied-layouts' = $entries }
}

function Invoke-FancyZonesEditorToggle {
    # Shared with PowerToys' editor hotkey and CLI:
    # https://github.com/microsoft/PowerToys/blob/main/src/modules/fancyzones/FancyZonesCLI/CommandLine/Commands/OpenEditorCommand.cs
    $event = [Threading.EventWaitHandle]::OpenExisting('Local\FancyZones-ToggleEditorEvent-1e174338-06a3-472b-874d-073b21c62f14')
    try {
        if (!$event.Set()) {
            throw "Could not signal the FancyZones editor."
        }
    } finally {
        $event.Dispose()
    }
}

function Get-FancyZonesEditorParams([string] $editorParamsFile) {
    if (Get-Process -Name "PowerToys.FancyZonesEditor" -ErrorAction SilentlyContinue) {
        throw "Close the FancyZones editor before deploying layouts; its current session will not be interrupted."
    }
    $previousWrite = if (Test-Path $editorParamsFile) {
        (Get-Item $editorParamsFile).LastWriteTimeUtc
    } else {
        [datetime]::MinValue
    }

    $editor = $null
    Invoke-FancyZonesEditorToggle
    try {
        for ($attempt = 0; $attempt -lt 40; $attempt++) {
            $editor = Get-Process -Name "PowerToys.FancyZonesEditor" -ErrorAction SilentlyContinue
            if ($editor -and (Test-Path $editorParamsFile) -and ((Get-Item $editorParamsFile).LastWriteTimeUtc -gt $previousWrite)) {
                $editorParams = ConvertFrom-Json (Get-Content -Raw $editorParamsFile) -AsHashtable
                if (@($editorParams.monitors).Count -eq 0) {
                    throw "FancyZones refreshed its metadata with no monitors."
                }
                return $editorParams
            }
            Start-Sleep -Milliseconds 50
        }
        throw "FancyZones did not refresh monitor metadata. Enable FancyZones and re-run deploy."
    } finally {
        Invoke-FancyZonesEditorToggle
        if ($editor) {
            for ($attempt = 0; $attempt -lt 100; $attempt++) {
                if (!(Get-Process -Id $editor.Id -ErrorAction SilentlyContinue)) { break }
                Start-Sleep -Milliseconds 50
            }
            if ($attempt -eq 100) {
                throw "The FancyZones editor did not close after refreshing monitor metadata."
            }
        }
    }
}

function Get-FancyZonesDeploymentLayouts([hashtable] $customLayouts) {
    foreach ($name in @("fullscreen", "agent")) {
        $matches = @($customLayouts['custom-layouts'] | Where-Object { $_.name -eq $name })
        if (($matches.Count -ne 1) -or ($matches[0].type -ne "canvas") -or (@($matches[0].info.zones).Count -eq 0)) {
            throw "Expected one nonempty canvas layout named '$name'."
        }
        @{ uuid = $matches[0].uuid; 'zone-count' = @($matches[0].info.zones).Count }
    }
}

function Install-FancyZonesLayouts($stage, [string] $fancyZonesDir) {
    $editorParams = Get-FancyZonesEditorParams "$fancyZonesDir\editor-parameters.json"
    $customLayoutsText = Get-Content -Raw "$PSScriptRoot\fancyZones\custom-layouts.json"
    $layouts = @(Get-FancyZonesDeploymentLayouts (ConvertFrom-Json $customLayoutsText -AsHashtable))
    Install-JsonToFile $stage "$fancyZonesDir\custom-layouts.json" $customLayoutsText -BackupFile

    $appliedLayoutsFile = "$fancyZonesDir\applied-layouts.json"
    $existingEntries = @()
    if (Test-Path $appliedLayoutsFile) {
        $existing = ConvertFrom-Json (Get-Content -Raw $appliedLayoutsFile) -AsHashtable
        $existingEntries = @($existing['applied-layouts'])
    }
    $appliedLayouts = Get-AppliedLayoutsFromEditorParams $editorParams $layouts $existingEntries
    Install-JsonToFile $stage $appliedLayoutsFile (ConvertTo-Json $appliedLayouts -Depth 10) -BackupFile
}

if ($MyInvocation.InvocationName -ne ".") {
    $stage = $installationTracker.StartStage('powerToys-settings')

    $settingsFile = "$env:LOCALAPPDATA\Microsoft\PowerToys\settings.json"

    if (!(Test-Path $settingsFile)) {
        $stage.EnsureManualStep("powerToys/firstRun", @"
PowerToys settings file not found. Launch PowerToys once to create it, then re-run deploy.
"@)
    } else {
        $content = Import-TextFile $settingsFile
        $content = Set-PowerToysEnabledModules $content @("FancyZones") $settingsFile
        Install-JsonToFile $stage $settingsFile $content -BackupFile
    }

    $installationTracker.EndStage($stage)

    $stage2 = $installationTracker.StartStage('fancyZones-layouts')
    $fancyZonesDir = "$env:LOCALAPPDATA\Microsoft\PowerToys\FancyZones"
    Install-FancyZonesLayouts $stage2 $fancyZonesDir
    $installationTracker.EndStage($stage2)
}
