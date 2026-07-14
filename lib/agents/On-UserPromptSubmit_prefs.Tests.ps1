BeforeDiscovery {
    . "$PSScriptRoot/On-UserPromptSubmit_prefs.ps1"
}

BeforeAll {
    . "$PSScriptRoot/On-UserPromptSubmit_prefs.ps1"
}

Describe "Save-PidSessionRecord" {
    BeforeAll {
        function Get-HarnessPid { param([string] $harnessName) 4242 }
    }

    BeforeEach {
        $script:runDir = "TestDrive:\running-$([guid]::NewGuid().ToString('N'))"
        Remove-Item Env:\CL_PLAN_FILE -ErrorAction SilentlyContinue
    }

    AfterEach {
        Remove-Item Env:\CL_PLAN_FILE -ErrorAction SilentlyContinue
    }

    It "stamps planFile from CL_PLAN_FILE into the running file" {
        $env:CL_PLAN_FILE = 'C:/plans/foo.md'

        Save-PidSessionRecord ([pscustomobject]@{session_id = 'sid-1'; cwd = 'C:/de'}) 'claude' $script:runDir

        $data = Get-Content "$script:runDir/pid_4242.txt" -Raw | ConvertFrom-Json
        $data.session_id | Should -Be 'sid-1'
        $data.cwd        | Should -Be 'C:/de'
        $data.planFile   | Should -Be 'C:/plans/foo.md'
    }

    It "omits planFile when CL_PLAN_FILE is unset" {
        Save-PidSessionRecord ([pscustomobject]@{session_id = 'sid-1'; cwd = 'C:/de'}) 'claude' $script:runDir

        $data = Get-Content "$script:runDir/pid_4242.txt" -Raw | ConvertFrom-Json
        $data.session_id | Should -Be 'sid-1'
        $data.PSObject.Properties['planFile'] | Should -BeNull
    }

    It "writes nothing when session_id is missing" {
        Save-PidSessionRecord ([pscustomobject]@{cwd = 'C:/de'}) 'claude' $script:runDir

        Test-Path $script:runDir | Should -BeFalse
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
