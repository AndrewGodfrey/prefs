BeforeAll {
    $prefsScript = Resolve-Path "$PSScriptRoot/Get-CodebaseLayers.ps1"
    $root        = "TestDrive:/stack"
}

Describe "Get-CodebaseLayers (prefs) - sibling chaining" {
    BeforeEach {
        Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
    }

    It "Resolves the sibling via the script's own root, not `$home (prefs standalone: prefs+prat, no de)" {
        New-Item -ItemType Directory -Force "$root/prat/pathbin" | Out-Null
        Set-Content "$root/prat/pathbin/Get-CodebaseLayers.ps1" `
            -Value "return @(@{ Name = 'sentinel'; Path = 'sentinel-path' })"

        $result = @(& $prefsScript -ScriptRoot "$root/prefs/pathbin")

        $result.Count | Should -Be 2
        $result[0].Name | Should -Be 'prefs'
        $result[0].Path | Should -Be (Split-Path -Parent "$root/prefs/pathbin")
        $result[1].Name | Should -Be 'sentinel'
        $result[1].Path | Should -Be 'sentinel-path'
    }

    It "Throws naming the missing sibling script, when prat is absent" {
        { & $prefsScript -ScriptRoot "$root/prefs/pathbin" } | Should -Throw "*prat/pathbin/Get-CodebaseLayers.ps1*"
    }
}