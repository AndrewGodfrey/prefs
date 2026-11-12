BeforeAll {
    Import-Module "$HOME/prat/lib/TextFileEditor/TextFileEditor.psd1" -Force
    Import-Module "$HOME/prat/lib/Installers/Installers.psd1" -Force
    . "$PSScriptRoot/powerToys_prefs.ps1"
}

Describe "Set-PowerToysEnabledModules" {
    BeforeAll {
        $script:filename = "test.json"
    }

    It "disables all modules when keepEnabled is empty" {
        $json = "{`n  `"enabled`": {`n    `"FancyZones`": true,`n    `"AlwaysOnTop`": true,`n    `"ColorPicker`": true`n  }`n}"

        $result = Set-PowerToysEnabledModules $json @() $script:filename

        $parsed = ConvertFrom-Json $result -AsHashtable
        $parsed.enabled.FancyZones  | Should -Be $false
        $parsed.enabled.AlwaysOnTop | Should -Be $false
        $parsed.enabled.ColorPicker | Should -Be $false
    }

    It "keeps listed modules enabled and disables the rest" {
        $json = "{`n  `"enabled`": {`n    `"FancyZones`": false,`n    `"AlwaysOnTop`": true,`n    `"ColorPicker`": true`n  }`n}"

        $result = Set-PowerToysEnabledModules $json @("FancyZones") $script:filename

        $parsed = ConvertFrom-Json $result -AsHashtable
        $parsed.enabled.FancyZones  | Should -Be $true
        $parsed.enabled.AlwaysOnTop | Should -Be $false
        $parsed.enabled.ColorPicker | Should -Be $false
    }

    It "enables only the requested module in compact JSON regardless of property order" -TestCases @(
        @{ enabled = '"FancyZones":false,"AlwaysOnTop":true' }
        @{ enabled = '"AlwaysOnTop":true,"FancyZones":false' }
    ) {
        param($enabled)
        $json = '{"enabled":{' + $enabled + '}}'

        $result = Set-PowerToysEnabledModules $json @("FancyZones") $script:filename

        $parsed = ConvertFrom-Json $result -AsHashtable
        $parsed.enabled.FancyZones | Should -Be $true
        $parsed.enabled.AlwaysOnTop | Should -Be $false
    }

    It "preserves unrelated values when updating compact JSON" {
        $json = '{"startup":true,"enabled":{"FancyZones":false,"AlwaysOnTop":true},"show_tray_icon":true,"run_elevated":false,"other":{"text":"true false","items":[1,2]}}'

        $result = Set-PowerToysEnabledModules $json @("FancyZones") $script:filename

        $parsed = ConvertFrom-Json $result -AsHashtable
        $parsed.startup | Should -Be $true
        $parsed.show_tray_icon | Should -Be $true
        $parsed.run_elevated | Should -Be $false
        $parsed.other.text | Should -BeExactly "true false"
        $parsed.other.items | Should -Be @(1, 2)
    }

    It "leaves an already-enabled module enabled" {
        $json = "{`n  `"enabled`": {`n    `"FancyZones`": true,`n    `"AlwaysOnTop`": false`n  }`n}"

        $result = Set-PowerToysEnabledModules $json @("FancyZones") $script:filename

        $parsed = ConvertFrom-Json $result -AsHashtable
        $parsed.enabled.FancyZones  | Should -Be $true
        $parsed.enabled.AlwaysOnTop | Should -Be $false
    }

    It "preserves surrounding JSON structure" {
        $json = "{`n  `"enabled`": {`n    `"FancyZones`": false`n  },`n  `"other`": `"value`"`n}"

        $result = Set-PowerToysEnabledModules $json @("FancyZones") $script:filename

        $result | Should -Match '"FancyZones": true'
        $result | Should -Match '"other": "value"'
    }
}

Describe "Get-FancyZonesEditorParams" {
    BeforeEach {
        $script:editorParamsFile = Join-Path $TestDrive "editor-parameters.json"
        '{"monitors":[{"monitor-number":1}]}' | Set-Content $script:editorParamsFile
        (Get-Item $script:editorParamsFile).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-1)
        $script:refreshMonitors = $true
        $script:editorOpen = $false
        Mock Invoke-FancyZonesEditorToggle {
            $script:editorOpen = -not $script:editorOpen
            if ($script:editorOpen -and $script:refreshMonitors) {
                '{"monitors":[{"monitor-number":97},{"monitor-number":98}]}' |
                    Set-Content $script:editorParamsFile
            }
        }
        Mock Get-Process {
            if ($script:editorOpen) { [pscustomobject]@{ Id = 123 } }
        }
        Mock Start-Sleep {}
    }

    It "requests fresh monitor metadata before reading it" {
        $result = Get-FancyZonesEditorParams $script:editorParamsFile

        $result.monitors.'monitor-number' | Should -Be @(97, 98)
        $script:editorOpen | Should -Be $false
        Should -Invoke Get-Process -Exactly 1 -ParameterFilter { $Id -eq 123 }
    }

    It "creates the first snapshot without requiring the editor to be opened" {
        Remove-Item $script:editorParamsFile

        $result = Get-FancyZonesEditorParams $script:editorParamsFile

        $result.monitors.Count | Should -Be 2
    }

    It "rejects a stale snapshot and closes the editor after a refresh timeout" {
        $script:refreshMonitors = $false

        { Get-FancyZonesEditorParams $script:editorParamsFile } |
            Should -Throw "*did not refresh*"
        $script:editorOpen | Should -Be $false
    }

    It "leaves an existing editor session untouched" {
        $script:editorOpen = $true

        { Get-FancyZonesEditorParams $script:editorParamsFile } |
            Should -Throw "*Close the FancyZones editor*"
        Should -Invoke Invoke-FancyZonesEditorToggle -Exactly 0
        $script:editorOpen | Should -Be $true
    }

    It "accepts an editor that exits before cleanup starts waiting" {
        Mock Get-Process { $null } -ParameterFilter { $Id -eq 123 }

        $result = Get-FancyZonesEditorParams $script:editorParamsFile

        $result.monitors.Count | Should -Be 2
        $script:editorOpen | Should -Be $false
    }

    It "reports an editor that does not exit after the close request" {
        Mock Get-Process { [pscustomobject]@{ Id = 123 } } -ParameterFilter { $Id -eq 123 }

        { Get-FancyZonesEditorParams $script:editorParamsFile } |
            Should -Throw "*did not close*"
    }

    It "rejects refreshed metadata with no monitors" {
        $script:refreshMonitors = $false
        Mock Start-Sleep {
            '{"monitors":[]}' | Set-Content $script:editorParamsFile
        }

        { Get-FancyZonesEditorParams $script:editorParamsFile } |
            Should -Throw "*no monitors*"
        $script:editorOpen | Should -Be $false
    }
}

Describe "Get-FancyZonesDeploymentLayouts" {
    It "derives zone counts and UUIDs from the shipped fullscreen and agent definitions" {
        $customLayouts = Get-Content -Raw "$PSScriptRoot\fancyZones\custom-layouts.json" |
            ConvertFrom-Json -AsHashtable

        $layouts = @(Get-FancyZonesDeploymentLayouts $customLayouts)

        $layouts.Count | Should -Be 2
        $layouts[0].uuid | Should -Be $customLayouts.'custom-layouts'[0].uuid
        $layouts[0].'zone-count' | Should -Be 1
        $layouts[1].uuid | Should -Be $customLayouts.'custom-layouts'[1].uuid
        $layouts[1].'zone-count' | Should -Be 4
    }

    It "reports a missing layout rather than writing a partial assignment" {
        { Get-FancyZonesDeploymentLayouts @{ 'custom-layouts' = @() } } |
            Should -Throw "*fullscreen*"
    }
}

Describe "Install-FancyZonesLayouts" {
    It "replaces obsolete monitor associations using refreshed identities and the shipped zone counts" {
        $dir = Join-Path $TestDrive "FancyZones"
        New-Item -ItemType Directory $dir | Out-Null
        '{"applied-layouts":[{"device":{"monitor-instance":"left","monitor-number":1},"applied-layout":{"uuid":"old"}}]}' |
            Set-Content (Join-Path $dir "applied-layouts.json")
        Mock Get-FancyZonesEditorParams {
            @{
                monitors = @(
                    @{ 'monitor' = 'Default_Monitor'; 'monitor-instance-id' = 'left'; 'monitor-number' = 97
                       'monitor-serial-number' = ''; 'virtual-desktop' = '{VD}'; 'left-coordinate' = 0 },
                    @{ 'monitor' = 'Default_Monitor'; 'monitor-instance-id' = 'right'; 'monitor-number' = 98
                       'monitor-serial-number' = ''; 'virtual-desktop' = '{VD}'; 'left-coordinate' = 2560 }
                )
            }
        }
        Mock Install-JsonToFile {
            param($stage, $file, $newText)
            Set-Content $file $newText
        }

        Install-FancyZonesLayouts "stage" $dir

        $result = Get-Content -Raw (Join-Path $dir "applied-layouts.json") | ConvertFrom-Json -AsHashtable
        $entries = $result.'applied-layouts'
        $entries.Count | Should -Be 2
        $entries.device.'monitor-number' | Should -Be @(97, 98)
        $entries[0].'applied-layout'.uuid | Should -Be '{72207334-72A3-4AB6-83FE-01FEE336F1FA}'
        $entries[1].'applied-layout'.uuid | Should -Be '{C00E7BB8-D784-447F-8C0E-B00E3564C6D3}'
        $entries[1].'applied-layout'.'zone-count' | Should -Be 4
        Should -Invoke Get-FancyZonesEditorParams -Exactly 1 -ParameterFilter {
            $editorParamsFile -eq (Join-Path $dir "editor-parameters.json")
        }
    }
}

Describe "Get-AppliedLayoutsFromEditorParams" {
    BeforeAll {
        # Right monitor is listed first in input to verify left-coordinate sorting
        $editorParams = @{
            monitors = @(
                @{
                    'monitor'               = 'RIGHT_MON'
                    'monitor-instance-id'   = 'right-instance'
                    'monitor-serial-number' = 'RIGHT_SERIAL'
                    'monitor-number'        = 2
                    'virtual-desktop'       = '{VDESK}'
                    'left-coordinate'       = 2560
                },
                @{
                    'monitor'               = 'LEFT_MON'
                    'monitor-instance-id'   = 'left-instance'
                    'monitor-serial-number' = 'LEFT_SERIAL'
                    'monitor-number'        = 1
                    'virtual-desktop'       = '{VDESK}'
                    'left-coordinate'       = 0
                }
            )
        }
        $layouts = @(
            @{ uuid = '{LAYOUT_A}'; 'zone-count' = 1 },
            @{ uuid = '{LAYOUT_B}'; 'zone-count' = 3 }
        )
        $script:result = Get-AppliedLayoutsFromEditorParams $editorParams $layouts
        $script:entries = $script:result['applied-layouts']
    }

    It "produces one entry per layout" {
        $script:entries.Count | Should -Be 2
    }

    It "assigns first layout to the left monitor (sorted by left-coordinate)" {
        $script:entries[0].device['monitor']           | Should -Be 'LEFT_MON'
        $script:entries[0]['applied-layout']['uuid']   | Should -Be '{LAYOUT_A}'
    }

    It "assigns second layout to the right monitor" {
        $script:entries[1].device['monitor']           | Should -Be 'RIGHT_MON'
        $script:entries[1]['applied-layout']['uuid']   | Should -Be '{LAYOUT_B}'
    }

    It "maps device keys from editor-parameters format to applied-layouts format" {
        $dev = $script:entries[0].device
        $dev['monitor-instance'] | Should -Be 'left-instance'
        $dev['serial-number']    | Should -Be 'LEFT_SERIAL'
        $dev['monitor-number']   | Should -Be 1
        $dev['virtual-desktop']  | Should -Be '{VDESK}'
    }

    It "sets applied-layout properties correctly" {
        $layout = $script:entries[0]['applied-layout']
        $layout['type']               | Should -Be 'custom'
        $layout['show-spacing']       | Should -Be $false
        $layout['spacing']            | Should -Be 0
        $layout['sensitivity-radius'] | Should -Be 20
        $layout['zone-count']         | Should -Be 1
    }
}

Describe "Get-AppliedLayoutsFromEditorParams merge" {
    BeforeAll {
        $script:layouts = @(
            @{ uuid = '{LAYOUT_A}'; 'zone-count' = 1 },
            @{ uuid = '{LAYOUT_B}'; 'zone-count' = 3 }
        )
    }

    It "preserves existing entries for monitors not in editor-parameters" {
        $editorParams = @{
            monitors = @(
                @{ 'monitor' = 'MON_A'; 'monitor-instance-id' = 'inst-A'; 'monitor-serial-number' = 'SER_A'
                   'monitor-number' = 1; 'virtual-desktop' = '{VD}'; 'left-coordinate' = 0 }
            )
        }
        $existingEntries = @(
            @{ device = @{ 'monitor' = 'MON_A'; 'monitor-instance' = 'inst-A' }
               'applied-layout' = @{ uuid = '{OLD}' } },
            @{ device = @{ 'monitor' = 'OTHER_LOC'; 'monitor-instance' = 'inst-other' }
               'applied-layout' = @{ uuid = '{OTHER_LAYOUT}' } }
        )

        $result = Get-AppliedLayoutsFromEditorParams $editorParams $layouts $existingEntries
        $entries = $result['applied-layouts']

        $entries.Count | Should -Be 2
        $entries[0].device['monitor'] | Should -Be 'MON_A'
        $entries[0]['applied-layout']['uuid'] | Should -Be '{LAYOUT_A}'
        $entries[1].device['monitor'] | Should -Be 'OTHER_LOC'
        $entries[1]['applied-layout']['uuid'] | Should -Be '{OTHER_LAYOUT}'
    }

    It "replaces existing entries for monitors that are in editor-parameters" {
        $editorParams = @{
            monitors = @(
                @{ 'monitor' = 'MON_A'; 'monitor-instance-id' = 'inst-A'; 'monitor-serial-number' = 'SER_A'
                   'monitor-number' = 1; 'virtual-desktop' = '{VD}'; 'left-coordinate' = 0 }
            )
        }
        $existingEntries = @(
            @{ device = @{ 'monitor' = 'MON_A'; 'monitor-instance' = 'inst-A' }
               'applied-layout' = @{ uuid = '{OLD_LAYOUT}'; type = 'priority-grid' } }
        )

        $result = Get-AppliedLayoutsFromEditorParams $editorParams $layouts $existingEntries
        $entries = $result['applied-layouts']

        $entries.Count | Should -Be 1
        $entries[0]['applied-layout']['uuid'] | Should -Be '{LAYOUT_A}'
    }

    It "works with no existing entries (fresh install)" {
        $editorParams = @{
            monitors = @(
                @{ 'monitor' = 'MON_A'; 'monitor-instance-id' = 'inst-A'; 'monitor-serial-number' = 'SER_A'
                   'monitor-number' = 1; 'virtual-desktop' = '{VD}'; 'left-coordinate' = 0 }
            )
        }

        $result = Get-AppliedLayoutsFromEditorParams $editorParams $layouts
        $entries = $result['applied-layouts']

        $entries.Count | Should -Be 1
        $entries[0]['applied-layout']['uuid'] | Should -Be '{LAYOUT_A}'
    }

    It "preserves existing entry for a leftmost monitor skipped by the layout count (e.g. laptop screen)" {
        $editorParams = @{
            monitors = @(
                @{ 'monitor' = 'LEFT';  'monitor-instance-id' = 'inst-1'; 'monitor-serial-number' = 'S1'
                   'monitor-number' = 1; 'virtual-desktop' = '{VD}'; 'left-coordinate' = 0 },
                @{ 'monitor' = 'MID';   'monitor-instance-id' = 'inst-2'; 'monitor-serial-number' = 'S2'
                   'monitor-number' = 2; 'virtual-desktop' = '{VD}'; 'left-coordinate' = 2560 },
                @{ 'monitor' = 'RIGHT'; 'monitor-instance-id' = 'inst-3'; 'monitor-serial-number' = 'S3'
                   'monitor-number' = 3; 'virtual-desktop' = '{VD}'; 'left-coordinate' = 5120 }
            )
        }
        $existingEntries = @(
            @{ device = @{ 'monitor' = 'LEFT'; 'monitor-instance' = 'inst-1' }
               'applied-layout' = @{ uuid = '{EXISTING_LAYOUT}'; type = 'priority-grid' } }
        )

        $result = Get-AppliedLayoutsFromEditorParams $editorParams $layouts $existingEntries
        $entries = $result['applied-layouts']

        # 2 from layouts (MID, RIGHT) + 1 preserved for LEFT (skipped)
        $entries.Count | Should -Be 3
        $entries[0].device['monitor'] | Should -Be 'MID'
        $entries[0]['applied-layout']['uuid'] | Should -Be '{LAYOUT_A}'
        $entries[1].device['monitor'] | Should -Be 'RIGHT'
        $entries[1]['applied-layout']['uuid'] | Should -Be '{LAYOUT_B}'
        $entries[2].device['monitor'] | Should -Be 'LEFT'
        $entries[2]['applied-layout']['uuid'] | Should -Be '{EXISTING_LAYOUT}'
    }

    It "preserves entries from two locations after round-trip" {
        # Simulate: deploy at location A creates entries for A's monitors
        $editorParamsA = @{
            monitors = @(
                @{ 'monitor' = 'LOC_A_LEFT';  'monitor-instance-id' = 'inst-A1'; 'monitor-serial-number' = 'SA1'
                   'monitor-number' = 1; 'virtual-desktop' = '{VD}'; 'left-coordinate' = 0 },
                @{ 'monitor' = 'LOC_A_RIGHT'; 'monitor-instance-id' = 'inst-A2'; 'monitor-serial-number' = 'SA2'
                   'monitor-number' = 2; 'virtual-desktop' = '{VD}'; 'left-coordinate' = 2560 }
            )
        }
        $resultA = Get-AppliedLayoutsFromEditorParams $editorParamsA $layouts

        # Now deploy at location B, merging with location A's entries
        $editorParamsB = @{
            monitors = @(
                @{ 'monitor' = 'LOC_B_LEFT';  'monitor-instance-id' = 'inst-B1'; 'monitor-serial-number' = 'SB1'
                   'monitor-number' = 1; 'virtual-desktop' = '{VD}'; 'left-coordinate' = 0 },
                @{ 'monitor' = 'LOC_B_RIGHT'; 'monitor-instance-id' = 'inst-B2'; 'monitor-serial-number' = 'SB2'
                   'monitor-number' = 2; 'virtual-desktop' = '{VD}'; 'left-coordinate' = 2560 }
            )
        }
        $resultB = Get-AppliedLayoutsFromEditorParams $editorParamsB $layouts @($resultA['applied-layouts'])
        $entries = $resultB['applied-layouts']

        # Should have 4 entries: 2 for location B (current) + 2 for location A (preserved)
        $entries.Count | Should -Be 4
        $entries[0].device['monitor'] | Should -Be 'LOC_B_LEFT'
        $entries[1].device['monitor'] | Should -Be 'LOC_B_RIGHT'
        $entries[2].device['monitor'] | Should -Be 'LOC_A_LEFT'
        $entries[3].device['monitor'] | Should -Be 'LOC_A_RIGHT'
    }

    It "drops existing entries with missing monitor-instance" {
        $editorParams = @{
            monitors = @(
                @{ 'monitor' = 'MON_A'; 'monitor-instance-id' = 'inst-A'; 'monitor-serial-number' = 'SER_A'
                   'monitor-number' = 1; 'virtual-desktop' = '{VD}'; 'left-coordinate' = 0 }
            )
        }
        $existingEntries = @(
            @{ device = @{ 'monitor' = 'CORRUPT' }
               'applied-layout' = @{ uuid = '{CORRUPT_LAYOUT}' } }
        )

        $result = Get-AppliedLayoutsFromEditorParams $editorParams $script:layouts $existingEntries
        $entries = $result['applied-layouts']

        $entries.Count | Should -Be 1
        $entries[0].device['monitor'] | Should -Be 'MON_A'
    }
}
