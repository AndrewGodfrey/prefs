BeforeAll {
    . "$PSScriptRoot/packages_prefs.ps1"
}

Describe "Get-MarkTextPreferencesUpdate" {
    It "returns minimal JSON when input is empty (pre-create case)" {
        $result = Get-MarkTextPreferencesUpdate ""

        $parsed = $result | ConvertFrom-Json
        $parsed.editorLineWidth | Should -Be '100%'
    }

    It "returns minimal JSON when input is null" {
        $result = Get-MarkTextPreferencesUpdate $null

        $parsed = $result | ConvertFrom-Json
        $parsed.editorLineWidth | Should -Be '100%'
    }

    It "returns null when editorLineWidth is already 100%" {
        $existing = '{"editorLineWidth":"100%","theme":"dark"}'

        $result = Get-MarkTextPreferencesUpdate $existing

        $result | Should -BeNullOrEmpty
    }

    It "updates editorLineWidth when set to a different value" {
        $existing = '{"editorLineWidth":"85%","theme":"dark"}'

        $result = Get-MarkTextPreferencesUpdate $existing

        $parsed = $result | ConvertFrom-Json
        $parsed.editorLineWidth | Should -Be '100%'
    }

    It "preserves other fields when updating editorLineWidth" {
        $existing = '{"editorLineWidth":"85%","theme":"dark","autoSave":true}'

        $result = Get-MarkTextPreferencesUpdate $existing

        $parsed = $result | ConvertFrom-Json
        $parsed.theme    | Should -Be 'dark'
        $parsed.autoSave | Should -Be $true
    }
}
