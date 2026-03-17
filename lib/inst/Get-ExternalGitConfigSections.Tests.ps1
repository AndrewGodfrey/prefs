BeforeAll {
    . "$PSScriptRoot/gitconfig_prefs.ps1"
}

Describe "Get-ExternalGitConfigSections" {
    It "returns empty string for empty input" {
        Get-ExternalGitConfigSections "" @() | Should -Be ""
    }

    It "returns empty string when all sections are owned" {
        $content = "[user]`n    name = John`n[safe]`n    directory = /foo`n"
        Get-ExternalGitConfigSections $content @('[user]', '[safe]') | Should -Be ""
    }

    It "returns a single external section" {
        $content = "[user]`n    name = John`n[credential `"azrepos:org/O365`"]`n    provider = generic`n"
        $result = Get-ExternalGitConfigSections $content @('[user]')
        $result | Should -Match '\[credential'
        $result | Should -Match 'provider = generic'
        $result | Should -Not -Match '\[user\]'
    }

    It "returns multiple external sections, omitting all owned sections" {
        $content = @"
[user]
    name = John
[credential "azrepos:org/O365Exchange"]
    provider = generic
[color "branch"]
    current = yellow bold
[core]
    autocrlf = false
[safe]
    directory = /foo
"@
        $owned = @('[user]', '[color "branch"]', '[safe]')
        $result = Get-ExternalGitConfigSections $content $owned
        $result | Should -Match '\[credential'
        $result | Should -Match '\[core\]'
        $result | Should -Not -Match '\[user\]'
        $result | Should -Not -Match '\[color'
        $result | Should -Not -Match '\[safe\]'
    }

    It "returns external section that appears first (before any owned section)" {
        $content = "[core]`n    autocrlf = false`n[user]`n    name = John`n"
        $result = Get-ExternalGitConfigSections $content @('[user]')
        $result | Should -Match '\[core\]'
        $result | Should -Not -Match '\[user\]'
    }

    It "handles CRLF line endings" {
        $content = "[user]`r`n    name = John`r`n[core]`r`n    autocrlf = false`r`n"
        $result = Get-ExternalGitConfigSections $content @('[user]')
        $result | Should -Match '\[core\]'
        $result | Should -Not -Match '\[user\]'
    }

    It "preserves indented content lines within the external section" {
        $content = "[credential `"https://dev.azure.com`"]`n    provider = generic`n    helper = manager`n"
        $result = Get-ExternalGitConfigSections $content @()
        $result | Should -Match 'provider = generic'
        $result | Should -Match 'helper = manager'
    }
}
