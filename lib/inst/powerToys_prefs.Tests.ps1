BeforeAll {
    . "$PSScriptRoot/powerToys_prefs.ps1"
}

Describe "Set-PowerToysEnabledModules" {
    It "disables all modules when keepEnabled is empty" {
        $enabled = @{ FancyZones = $true; AlwaysOnTop = $true; ColorPicker = $true }

        Set-PowerToysEnabledModules $enabled @()

        $enabled.FancyZones  | Should -Be $false
        $enabled.AlwaysOnTop | Should -Be $false
        $enabled.ColorPicker | Should -Be $false
    }

    It "keeps listed modules enabled and disables the rest" {
        $enabled = @{ FancyZones = $false; AlwaysOnTop = $true; ColorPicker = $true }

        Set-PowerToysEnabledModules $enabled @("FancyZones")

        $enabled.FancyZones  | Should -Be $true
        $enabled.AlwaysOnTop | Should -Be $false
        $enabled.ColorPicker | Should -Be $false
    }

    It "leaves an already-disabled module disabled" {
        $enabled = @{ FancyZones = $false; AlwaysOnTop = $false }

        Set-PowerToysEnabledModules $enabled @("FancyZones")

        $enabled.FancyZones  | Should -Be $true
        $enabled.AlwaysOnTop | Should -Be $false
    }
}
