BeforeAll {
    $script = "$PSScriptRoot/Get-AgentRoleContext.ps1"
}

Describe "Get-AgentRoleContext" {
    Context "unbound project — default role" {
        BeforeAll {
            function Get-PratProject { param($Location) $null }
            function Test-Path { param($Path) $true }
        }

        It "returns default roleDir" {
            $result = & $script -cwd "C:/some/project"
            $result.roleDir | Should -Be "$home/agentRoles/default"
        }

        It "returns null targetRepo and contextMessage" {
            $result = & $script -cwd "C:/some/project"
            $result.targetRepo     | Should -BeNull
            $result.contextMessage | Should -BeNull
        }
    }

    Context "bound-repo project — agentRole and root set" {
        BeforeAll {
            function Get-PratProject { param($Location) @{ agentRole = 'myrole'; root = 'C:/repos/myrepo' } }
            function Test-Path { param($Path) $true }
        }

        It "returns role-specific roleDir" {
            $result = & $script -cwd "C:/repos/myrepo"
            $result.roleDir | Should -Be "$home/agentRoles/myrole"
        }

        It "returns targetRepo from project root" {
            $result = & $script -cwd "C:/repos/myrepo"
            $result.targetRepo | Should -Be "C:/repos/myrepo"
        }

        It "returns contextMessage mentioning the target repo" {
            $result = & $script -cwd "C:/repos/myrepo"
            $result.contextMessage | Should -BeLike "*C:/repos/myrepo*"
        }
    }

    Context "project has root but no agentRole" {
        BeforeAll {
            function Get-PratProject { param($Location) @{ root = 'C:/repos/myrepo' } }
            function Test-Path { param($Path) $true }
        }

        It "uses default role and populates targetRepo and contextMessage" {
            $result = & $script -cwd "C:/repos/myrepo"
            $result.roleDir        | Should -Be "$home/agentRoles/default"
            $result.targetRepo     | Should -Be "C:/repos/myrepo"
            $result.contextMessage | Should -BeLike "*C:/repos/myrepo*"
        }
    }

    Context "missing roleDir" {
        BeforeAll {
            function Get-PratProject { param($Location) $null }
            function Test-Path { param($Path) $false }
        }

        It "throws with a descriptive message" {
            { & $script -cwd "C:/some/project" } | Should -Throw "*Agent role dir not found*"
        }
    }
}
