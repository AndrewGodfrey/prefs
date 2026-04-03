BeforeAll {
    Import-Module "$HOME/prat/lib/TextFileEditor/TextFileEditor.psd1" -Force
    . "$PSScriptRoot/vscode_prefs.ps1"
}

Describe "setVscodeColorTheme" {
    BeforeAll {
        $script:filename = "test-settings.json"
    }

    It "updates colorTheme when set to a different value" {
        $json = "{`n" +
            "    `"workbench.colorTheme`": `"Default Dark+`"`n" +
            "}"
        $result = setVscodeColorTheme $json $script:filename

        (ConvertFrom-Json $result -AsHashtable).'workbench.colorTheme' | Should -Be "Dark Modern"
    }

    It "leaves colorTheme unchanged when already correct" {
        $json = "{`n" +
            "    `"workbench.colorTheme`": `"Dark Modern`"`n" +
            "}"
        $result = setVscodeColorTheme $json $script:filename

        $result | Should -Be $json
    }

    It "preserves other settings" {
        $json = "{`n" +
            "    `"editor.fontSize`": 14,`n" +
            "    `"workbench.colorTheme`": `"Default Dark+`",`n" +
            "    `"editor.tabSize`": 4`n" +
            "}"
        $result = setVscodeColorTheme $json $script:filename
        $parsed = ConvertFrom-Json $result -AsHashtable

        $parsed.'editor.fontSize' | Should -Be 14
        $parsed.'editor.tabSize'  | Should -Be 4
        $parsed.'workbench.colorTheme' | Should -Be "Dark Modern"
    }

    It "is idempotent" {
        $json = "{`n" +
            "    `"workbench.colorTheme`": `"Default Dark+`"`n" +
            "}"
        $result1 = setVscodeColorTheme $json $script:filename
        $result2 = setVscodeColorTheme $result1 $script:filename

        $result2 | Should -Be $result1
    }
}
