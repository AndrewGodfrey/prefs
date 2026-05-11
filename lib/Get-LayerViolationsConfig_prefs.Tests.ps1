BeforeAll {
    $script:configFile = "$PSScriptRoot/Get-LayerViolationsConfig_prefs.ps1"
}

Describe "Get-LayerViolationsConfig_prefs" {
    It "returns a hashtable" {
        $result = & $script:configFile

        $result | Should -BeOfType [hashtable]
    }

    It "has a bannedPatterns key that is an array" {
        $result = & $script:configFile

        $result.ContainsKey('bannedPatterns') | Should -Be $true
        ($result.bannedPatterns -is [array]) | Should -Be $true
    }

    It "each entry has a non-empty pattern string" {
        $result = & $script:configFile

        foreach ($entry in $result.bannedPatterns) {
            $entry.pattern | Should -Not -BeNullOrEmpty
            $entry.pattern | Should -BeOfType [string]
        }
    }

    It "each entry has a non-empty description string" {
        $result = & $script:configFile

        foreach ($entry in $result.bannedPatterns) {
            $entry.description | Should -Not -BeNullOrEmpty
            $entry.description | Should -BeOfType [string]
        }
    }

    It "has an augmentPrat.bannedPatterns array with at least one entry" {
        $result = & $script:configFile

        $result.ContainsKey('augmentPrat') | Should -Be $true
        ($result.augmentPrat.bannedPatterns -is [array]) | Should -Be $true
        $result.augmentPrat.bannedPatterns.Count | Should -BeGreaterOrEqual 1
    }

    It "each augmentPrat entry has a non-empty pattern and description string" {
        $result = & $script:configFile

        foreach ($entry in $result.augmentPrat.bannedPatterns) {
            $entry.pattern     | Should -Not -BeNullOrEmpty
            $entry.pattern     | Should -BeOfType [string]
            $entry.description | Should -Not -BeNullOrEmpty
            $entry.description | Should -BeOfType [string]
        }
    }
}
