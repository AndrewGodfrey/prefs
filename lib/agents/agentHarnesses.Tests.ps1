BeforeAll {
    Import-Module "$home/prat/lib/PratBase/PratBase.psd1" -Force
    . "$PSScriptRoot/agentHarnesses.ps1"
    $script:testRoot = ((Get-Item "TestDrive:\").FullName -replace '\\', '/').TrimEnd('/')
}

Describe "Resolve-AgentHarnessDescriptors" {
    It "returns the selected harnesses in the top layer's order, merging each one's properties across layers" {
        $contributions = @(
            @{ harnesses = @{ alpha = @{ pickerKey = 'A'; liveProcessName = 'alpha.exe' }; beta = @{ pickerKey = 'B' } } }
            @{ selected = @('beta', 'alpha'); harnesses = @{ alpha = @{ pickerKey = 'X'; sessionsDir = 'C:/s' } } }
        )

        $r = @(Resolve-AgentHarnessDescriptors $contributions)

        @($r.name) | Should -Be @('beta', 'alpha')
        $r[1].pickerKey       | Should -Be 'X'
        $r[1].liveProcessName | Should -Be 'alpha.exe'
        $r[1].sessionsDir     | Should -Be 'C:/s'
    }

    It "takes the selection from the highest layer that declares one" {
        $contributions = @(@{ selected = @('alpha') }, @{ selected = @('beta') }, @{ harnesses = @{ gamma = @{} } })

        @((Resolve-AgentHarnessDescriptors $contributions).name) | Should -Be @('beta')
    }

    It "excludes a known harness that isn't selected" {
        $contributions = @(@{ harnesses = @{ alpha = @{}; beta = @{} } }, @{ selected = @('alpha') })

        @((Resolve-AgentHarnessDescriptors $contributions).name) | Should -Be @('alpha')
    }

    It "returns a bare descriptor for a selected name no layer describes" {
        $r = @(Resolve-AgentHarnessDescriptors @(@{ selected = @('custom') }))

        $r.Count   | Should -Be 1
        $r[0].name | Should -Be 'custom'
    }

    It "returns nothing when no layer selects any harness" {
        @(Resolve-AgentHarnessDescriptors @(@{ harnesses = @{ alpha = @{} } })) | Should -HaveCount 0
    }

    It "-All returns every known harness, selected or not" {
        $contributions = @(@{ harnesses = @{ alpha = @{ pickerKey = 'A' }; beta = @{} } }, @{ selected = @('custom') })

        $r = @(Resolve-AgentHarnessDescriptors $contributions -All)

        @($r.name | Sort-Object) | Should -Be @('alpha', 'beta', 'custom')
        ($r | Where-Object name -eq 'alpha').pickerKey | Should -Be 'A'
    }

    It "doesn't modify the contributed descriptors" {
        $alpha = @{ pickerKey = 'A' }
        $null = Resolve-AgentHarnessDescriptors @(@{ selected = @('alpha'); harnesses = @{ alpha = $alpha } })

        $alpha.ContainsKey('name') | Should -BeFalse
    }
}

Describe "Get-AgentHarnessContributions" {
    It "evaluates the layer files base-first" {
        Set-Content "$testRoot/harnesses_hi.ps1" "@{ selected = @('hi') }"
        Set-Content "$testRoot/harnesses_lo.ps1" "@{ selected = @('lo') }"

        $c = @(Get-AgentHarnessContributions -HarnessFiles @("$testRoot/harnesses_hi.ps1", "$testRoot/harnesses_lo.ps1"))

        @($c.selected) | Should -Be @('lo', 'hi')
    }

    Context "a higher layer still supplying the legacy Get-AgentHarnesses command" {
        BeforeAll {
            Set-Content "$testRoot/harnesses_base.ps1" "@{ harnesses = @{ claude = @{ pickerKey = 'C' } } }"
            function Get-AgentHarnesses { @(@{ name = 'custom'; pickerKey = 'X' }, @{ name = 'claude'; pickerKey = 'Z' }) }
        }

        It "selects its list, contributing properties only for harnesses no layer file describes" {
            Mock Write-Warning { }

            $r = @(Resolve-AgentHarnessDescriptors (Get-AgentHarnessContributions -HarnessFiles @("$testRoot/harnesses_base.ps1")))

            @($r.name)     | Should -Be @('custom', 'claude')
            $r[0].pickerKey | Should -Be 'X'
            $r[1].pickerKey | Should -Be 'C'
        }

        It "warns that it needs migrating" {
            Mock Write-Warning { }

            $null = Get-AgentHarnessContributions -HarnessFiles @("$testRoot/harnesses_base.ps1")

            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -match 'harnesses_<layer>\.ps1' }
        }

        It "is ignored once a layer file declares a selection" {
            Set-Content "$testRoot/harnesses_top.ps1" "@{ selected = @('claude') }"
            Mock Write-Warning { }

            $r = @(Resolve-AgentHarnessDescriptors (Get-AgentHarnessContributions -HarnessFiles @("$testRoot/harnesses_top.ps1", "$testRoot/harnesses_base.ps1")))

            @($r.name) | Should -Be @('claude')
            Should -Invoke Write-Warning -Times 0
        }
    }
}

Describe "Get-CurrentAgentSessionId" {
    BeforeAll {
        $script:descriptors = @(
            @{ name = 'alpha'; sessionIdEnvVar = 'PREFS_TEST_ALPHA_SID' }
            @{ name = 'beta'; sessionIdEnvVar = 'PREFS_TEST_BETA_SID' }
            @{ name = 'gamma' }
        )
    }
    BeforeEach {
        $script:savedEnv = Save-Env @('PREFS_TEST_ALPHA_SID', 'PREFS_TEST_BETA_SID')
        Remove-Item Env:\PREFS_TEST_ALPHA_SID, Env:\PREFS_TEST_BETA_SID -ErrorAction SilentlyContinue
    }
    AfterEach { Restore-Env $script:savedEnv }

    It "returns the session id of the harness whose variable is set" {
        $env:PREFS_TEST_BETA_SID = 'sess-123'

        Get-CurrentAgentSessionId -Descriptors $descriptors | Should -Be 'sess-123'
    }

    It "returns nothing outside an agent session" {
        Get-CurrentAgentSessionId -Descriptors $descriptors | Should -BeNullOrEmpty
    }

    It "throws when more than one harness's variable is set (a session launched from another's shell)" {
        $env:PREFS_TEST_ALPHA_SID = 'a'
        $env:PREFS_TEST_BETA_SID  = 'b'

        { Get-CurrentAgentSessionId -Descriptors $descriptors } | Should -Throw '*alpha*beta*'
    }

    It "defaults to every known harness" {
        Mock Get-AgentHarnessDescriptors { $descriptors } -ParameterFilter { $All }
        $env:PREFS_TEST_ALPHA_SID = 'sess-a'

        Get-CurrentAgentSessionId | Should -Be 'sess-a'
    }
}

Describe "prefs's built-in harnesses" {
    BeforeAll { $script:builtins = (& "$PSScriptRoot/harnesses_prefs.ps1").harnesses }

    It "picker keys are unique" {
        $keys = @($builtins.Values | Where-Object { $_.pickerKey } | ForEach-Object { $_.pickerKey })

        $keys.Count | Should -BeGreaterThan 0
        ($keys | Select-Object -Unique).Count | Should -Be $keys.Count
    }

    It "selects nothing, leaving the choice to a higher layer" {
        (& "$PSScriptRoot/harnesses_prefs.ps1").ContainsKey('selected') | Should -BeFalse
    }
}
