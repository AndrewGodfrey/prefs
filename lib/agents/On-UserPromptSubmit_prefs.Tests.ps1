BeforeDiscovery {
    . "$PSScriptRoot/On-UserPromptSubmit_prefs.ps1"
}

BeforeAll {
    . "$PSScriptRoot/On-UserPromptSubmit_prefs.ps1"
}

Describe "getIntentPlanFile" {
    It "returns null when intent file does not exist" {
        $result = getIntentPlanFile "C:/de" "TestDrive:\no-file.json"

        $result | Should -BeNull
    }

    It "returns null when cwd does not match intent" {
        $intentPath = "TestDrive:\intent-cwd-mismatch.json"
        '{"planFile":"C:/plans/foo.md","cwd":"C:/other"}' | Set-Content $intentPath

        $result = getIntentPlanFile "C:/de" (Get-Item $intentPath).FullName

        $result | Should -BeNull
        Test-Path $intentPath | Should -BeTrue    # not consumed
    }

    It "returns planFile and removes intent file when cwd matches" {
        $intentPath = "TestDrive:\intent-match.json"
        '{"planFile":"C:/plans/foo.md","cwd":"C:/de"}' | Set-Content $intentPath

        $result = getIntentPlanFile "C:/de" (Get-Item $intentPath).FullName

        $result            | Should -Be "C:/plans/foo.md"
        Test-Path $intentPath | Should -BeFalse    # consumed
    }

    It "normalizes backslash cwd from intent file" {
        $intentPath = "TestDrive:\intent-backslash.json"
        '{"planFile":"C:/plans/foo.md","cwd":"C:\\de"}' | Set-Content $intentPath

        $result = getIntentPlanFile "C:/de" (Get-Item $intentPath).FullName

        $result | Should -Be "C:/plans/foo.md"
    }

    It "normalizes backslash cwd argument" {
        $intentPath = "TestDrive:\intent-backslash-arg.json"
        '{"planFile":"C:/plans/foo.md","cwd":"C:/de"}' | Set-Content $intentPath

        $result = getIntentPlanFile 'C:\de' (Get-Item $intentPath).FullName

        $result | Should -Be "C:/plans/foo.md"
    }

    It "returns null when intent file is malformed JSON" {
        $intentPath = "TestDrive:\intent-bad-json.json"
        'not json' | Set-Content $intentPath

        $result = getIntentPlanFile "C:/de" (Get-Item $intentPath).FullName

        $result | Should -BeNull
    }
}

Describe "Get-HarnessPid" {
    Context "harness process not running" {
        BeforeAll {
            function Get-Process { param($Name, $Id, $ErrorAction) $null }
        }

        It "returns null" {
            Get-HarnessPid 'claude' | Should -BeNull
        }
    }

    Context "parent process is the harness" {
        BeforeAll {
            $parentPid = 1234
            function Get-Process {
                param($Name, $Id, [string] $ErrorAction)
                if ($Name -eq 'claude') { return [pscustomobject]@{ Name = 'claude'; Id = 99 } }
                if ($Id -eq $parentPid)  { return [pscustomobject]@{ Name = 'claude'; Id = $parentPid } }
                return [pscustomobject]@{ Name = 'pwsh'; Id = $Id }
            }
            function getParentProcess { param($childPid) $parentPid }
        }

        It "returns the parent PID" {
            Get-HarnessPid 'claude' | Should -Be $parentPid
        }

        It "returns a single integer, not an array" {
            $result = Get-HarnessPid 'claude'
            @($result).Count | Should -Be 1
        }
    }

    Context "harness is two levels up" {
        BeforeAll {
            $grandparentPid = 5678
            $parentPid      = 9999
            function Get-Process {
                param($Name, $Id, [string] $ErrorAction)
                if ($Name -eq 'claude') { return [pscustomobject]@{ Name = 'claude'; Id = 99 } }
                if ($Id -eq $grandparentPid) { return [pscustomobject]@{ Name = 'claude'; Id = $grandparentPid } }
                return [pscustomobject]@{ Name = 'pwsh'; Id = $Id }
            }
            function getParentProcess {
                param($childPid)
                if ($childPid -eq $parentPid) { return $grandparentPid }
                return $parentPid
            }
        }

        It "returns the grandparent PID" {
            Get-HarnessPid 'claude' | Should -Be $grandparentPid
        }
    }

    Context "no harness ancestor within 6 levels" {
        BeforeAll {
            function Get-Process {
                param($Name, $Id, [string] $ErrorAction)
                if ($Name -eq 'claude') { return [pscustomobject]@{ Name = 'claude'; Id = 99 } }
                return [pscustomobject]@{ Name = 'pwsh'; Id = $Id }
            }
            function getParentProcess { param($childPid) $childPid + 1 }
        }

        It "returns null" {
            Get-HarnessPid 'claude' | Should -BeNull
        }
    }
}
