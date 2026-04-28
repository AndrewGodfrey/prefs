param($installationTracker)

function Set-PowerToysEnabledModules([string] $content, [string[]] $keepEnabled, [string] $filename) {
    $json = ConvertFrom-Json $content -AsHashtable
    foreach ($key in @($json.enabled.Keys)) {
        $range = Find-JsonSection $content @("enabled", $key) $filename
        if ($null -ne $range) {
            $line = ((ConvertTo-UnixLineEndings $content) -split "`n")[$range.idxFirst]
            $newBool = if ($key -in $keepEnabled) { 'true' } else { 'false' }
            $newLine = $line -replace '\b(true|false)\b', $newBool
            $content = Format-ReplaceLines $content $range $newLine
        }
    }
    return $content
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
    $editorParamsFile = "$fancyZonesDir\editor-parameters.json"

    if (!(Test-Path $editorParamsFile)) {
        $stage2.EnsureManualStep("fancyZones/firstRun", @"
FancyZones editor-parameters.json not found. Open the FancyZones editor (Win + SHIFT + ``) once, then re-run deploy.
"@)
    } else {
        Install-JsonToFile $stage2 "$fancyZonesDir\custom-layouts.json" (Get-Content -Raw "$PSScriptRoot\fancyZones\custom-layouts.json") -BackupFile

        $editorParams = ConvertFrom-Json (Get-Content -Raw $editorParamsFile) -AsHashtable
        $layouts = @(
            @{ uuid = '{72207334-72A3-4AB6-83FE-01FEE336F1FA}'; 'zone-count' = 1 },  # fullscreen (left monitor)
            @{ uuid = '{C00E7BB8-D784-447F-8C0E-B00E3564C6D3}'; 'zone-count' = 3 }   # agent (right monitor)
        )
        $appliedLayoutsFile = "$fancyZonesDir\applied-layouts.json"
        $existingEntries = @()
        if (Test-Path $appliedLayoutsFile) {
            $existing = ConvertFrom-Json (Get-Content -Raw $appliedLayoutsFile) -AsHashtable
            $existingEntries = @($existing['applied-layouts'])
        }
        $appliedLayouts = Get-AppliedLayoutsFromEditorParams $editorParams $layouts $existingEntries
        Install-JsonToFile $stage2 $appliedLayoutsFile (ConvertTo-Json $appliedLayouts -Depth 10) -BackupFile
    }
    $installationTracker.EndStage($stage2)
}
