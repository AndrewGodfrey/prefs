BeforeAll {
    Import-Module "$HOME/prat/lib/TextFileEditor/TextFileEditor.psd1" -Force
    . "$PSScriptRoot/windowsCustomizations_prefs.ps1"
}

Describe "customizeTerminal" {
    BeforeAll {
        $script:filename = "test.json"

        # Minimal Windows Terminal settings.json (4-space indent, matching real format).
        $script:baseJson = "{`n" +
            "    `"defaultProfile`": `"{old-guid}`",`n" +
            "    `"initialCols`": 120,`n" +
            "    `"initialRows`": 30,`n" +
            "    `"profiles`": {`n" +
            "        `"defaults`": {},`n" +
            "        `"list`": []`n" +
            "    },`n" +
            "    `"actions`": [],`n" +
            "    `"keybindings`": []`n" +
            "}"
    }

    It "sets initialCols to 145" {
        $result = customizeTerminal $script:baseJson $script:filename "#1F2233"
        (ConvertFrom-Json $result -AsHashtable).initialCols | Should -Be 145
    }

    It "sets initialRows to 50" {
        $result = customizeTerminal $script:baseJson $script:filename "#1F2233"
        (ConvertFrom-Json $result -AsHashtable).initialRows | Should -Be 50
    }

    It "sets defaultProfile to the PowerShell profile guid" {
        $result = customizeTerminal $script:baseJson $script:filename "#1F2233"
        (ConvertFrom-Json $result -AsHashtable).defaultProfile | Should -Be (getGuid_PsProfile)
    }

    It "sets profiles.defaults font face and size" {
        $result = customizeTerminal $script:baseJson $script:filename "#1F2233"
        $defaults = (ConvertFrom-Json $result -AsHashtable).profiles.defaults
        $defaults.font.face | Should -Be "Cascadia Mono"
        $defaults.font.size | Should -Be 10
    }

    It "sets profiles.defaults padding and elevate" {
        $result = customizeTerminal $script:baseJson $script:filename "#1F2233"
        $defaults = (ConvertFrom-Json $result -AsHashtable).profiles.defaults
        $defaults.padding | Should -Be "4"
        $defaults.elevate | Should -Be $false
    }

    It "adds the PowerShell profile with correct properties" {
        $result = customizeTerminal $script:baseJson $script:filename "#1F2233"
        $ps = (ConvertFrom-Json $result -AsHashtable).profiles.list |
              Where-Object { $_['guid'] -eq (getGuid_PsProfile) }
        $ps                | Should -Not -BeNull
        $ps['name']        | Should -Be "PowerShell"
        $ps['commandline'] | Should -BeLike '*pwsh.exe*-NoLogo*'
        $ps['hidden']      | Should -Be $false
        $ps['useAcrylic']  | Should -Be $false
    }

    It "uses the supplied background color for the PowerShell profile" {
        $r1 = customizeTerminal $script:baseJson $script:filename "#1F2233"
        $r2 = customizeTerminal $script:baseJson $script:filename "#1c2423"
        $bg1 = ((ConvertFrom-Json $r1 -AsHashtable).profiles.list | Where-Object { $_['guid'] -eq (getGuid_PsProfile) })['background']
        $bg2 = ((ConvertFrom-Json $r2 -AsHashtable).profiles.list | Where-Object { $_['guid'] -eq (getGuid_PsProfile) })['background']
        $bg1 | Should -Be "#1F2233"
        $bg2 | Should -Be "#1c2423"
    }

    It "adds the PowerShell (Elevated) profile with correct properties" {
        $result = customizeTerminal $script:baseJson $script:filename "#1F2233"
        $el = (ConvertFrom-Json $result -AsHashtable).profiles.list |
              Where-Object { $_['guid'] -eq (getGuid_PsElevatedProfile) }
        $el               | Should -Not -BeNull
        $el['name']       | Should -Be "PowerShell (Elevated)"
        $el['background'] | Should -Be "#3c2423"
        $el['elevate']    | Should -Be $true
        $el['hidden']     | Should -Be $false
    }

    It "puts PowerShell (Elevated) at position 0 and PowerShell at position 1" {
        $result = customizeTerminal $script:baseJson $script:filename "#1F2233"
        $list = (ConvertFrom-Json $result -AsHashtable).profiles.list
        $list[0]['guid'] | Should -Be (getGuid_PsProfile)
        $list[1]['guid'] | Should -Be (getGuid_PsElevatedProfile)
    }

    It "adds shift+enter and ctrl+backspace actions" {
        $result = customizeTerminal $script:baseJson $script:filename "#1F2233"
        $actions = (ConvertFrom-Json $result -AsHashtable).actions

        $shiftEnter = $actions | Where-Object { $_['id'] -eq 'User.sendInput.DFCDAF06' }
        $shiftEnter                    | Should -Not -BeNull
        $shiftEnter['command'].action  | Should -Be 'sendInput'

        $ctrlBackspace = $actions | Where-Object { $_['id'] -eq 'User.sendInput.817164EE' }
        $ctrlBackspace                    | Should -Not -BeNull
        $ctrlBackspace['command'].action  | Should -Be 'sendInput'
    }

    It "adds shift+enter and ctrl+backspace keybindings" {
        $result = customizeTerminal $script:baseJson $script:filename "#1F2233"
        $keybindings = (ConvertFrom-Json $result -AsHashtable).keybindings

        $shiftEnter = $keybindings | Where-Object { $_['id'] -eq 'User.sendInput.DFCDAF06' }
        $shiftEnter            | Should -Not -BeNull
        $shiftEnter['keys']    | Should -Be 'shift+enter'

        $ctrlBackspace = $keybindings | Where-Object { $_['id'] -eq 'User.sendInput.817164EE' }
        $ctrlBackspace         | Should -Not -BeNull
        $ctrlBackspace['keys'] | Should -Be 'ctrl+backspace'
    }

    It "is idempotent: running twice produces the same result" {
        $result1 = customizeTerminal $script:baseJson $script:filename "#1F2233"
        $result2 = customizeTerminal $result1 $script:filename "#1F2233"
        $result2 | Should -Be $result1
    }
}
