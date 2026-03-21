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
