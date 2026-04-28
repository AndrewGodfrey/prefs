BeforeAll {
    Import-Module "$HOME/prat/lib/TextFileEditor/TextFileEditor.psd1" -Force
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
