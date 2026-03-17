BeforeAll {
    . "$PSScriptRoot/gitconfig_prefs.ps1"
}

Describe "Get-GitConfigHeaders" {
    It "returns empty array for empty input" {
        $result = Get-GitConfigHeaders ""
        $result | Should -BeNullOrEmpty
    }

    It "returns a single header" {
        $result = Get-GitConfigHeaders "[user]`n    name = John`n"
        $result | Should -Be @('[user]')
    }

    It "returns multiple headers" {
        $content = "[user]`n    name = John`n[safe]`n    directory = /foo`n[color `"branch`"]`n    current = yellow`n"
        $result = Get-GitConfigHeaders $content
        $result | Should -Be @('[user]', '[safe]', '[color "branch"]')
    }

    It "handles CRLF line endings" {
        $content = "[user]`r`n    name = John`r`n[safe]`r`n    directory = /foo`r`n"
        $result = Get-GitConfigHeaders $content
        $result | Should -Be @('[user]', '[safe]')
    }
}
