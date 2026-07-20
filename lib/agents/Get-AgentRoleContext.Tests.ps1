BeforeAll {
    $script = "$PSScriptRoot/Get-AgentRoleContext.ps1"
    # Neutral defaults so existing contexts (which don't care about AGENTS.md combination) are
    # unaffected - overridden per-context below where that behavior is actually under test.
    function Get-Content { param($Path, [switch] $Raw) "" }
    function Get-CodebaseLayers { @() }
}

Describe "Get-AgentRoleContext" {
    Context "unbound project — default role" {
        BeforeAll {
            function Get-PratProject { param($Location) $null }
            function Test-Path { param($Path) $true }
            function Get-AgentRoles { @{} }
        }

        It "returns default roleDir with forward slashes" {
            $result = & $script -cwd "C:/some/project"
            $result.roleDir | Should -BeLike "*/agentRoles/default"
            $result.roleDir | Should -Not -Match '\\'
        }

        It "returns roleName 'default'" {
            $result = & $script -cwd "C:/some/project"
            $result.roleName | Should -Be 'default'
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
            function Get-AgentRoles { @{} }
        }

        It "returns role-specific roleDir with forward slashes" {
            $result = & $script -cwd "C:/repos/myrepo"
            $result.roleDir | Should -BeLike "*/agentRoles/myrole"
            $result.roleDir | Should -Not -Match '\\'
        }

        It "returns roleName from agentRole" {
            $result = & $script -cwd "C:/repos/myrepo"
            $result.roleName | Should -Be 'myrole'
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

    Context "AGENTS.md content combination — de/prat/prefs cluster always loads" {
        BeforeAll {
            function Get-PratProject { param($Location) $null }
            function Test-Path { param($Path) $true }
            function Get-AgentRoles { @{} }
            function Get-CodebaseLayers {
                @(@{ Name = 'prat'; Path = 'C:/layers/prat' }, @{ Name = 'prefs'; Path = 'C:/layers/prefs' }, @{ Name = 'de'; Path = 'C:/layers/de' }, @{ Name = 'llamacpp'; Path = 'C:/layers/llamacpp' })
            }
            function Get-Content { param($Path, [switch] $Raw) "content-of($Path)" }
        }

        It "includes prat/prefs/de AGENTS.md content even with no bound project" {
            $result = & $script -cwd "C:/some/project"
            $result.targetRepo     | Should -BeNull
            $result.contextMessage | Should -BeLike "*content-of(C:/layers/prat/AGENTS.md)*"
            $result.contextMessage | Should -BeLike "*content-of(C:/layers/prefs/AGENTS.md)*"
            $result.contextMessage | Should -BeLike "*content-of(C:/layers/de/AGENTS.md)*"
        }

        It "does not include a non-cluster layer's AGENTS.md" {
            $result = & $script -cwd "C:/some/project"
            $result.contextMessage | Should -Not -BeLike "*content-of(C:/layers/llamacpp/AGENTS.md)*"
        }
    }

    Context "AGENTS.md content combination — cluster reading order" {
        BeforeAll {
            function Get-PratProject { param($Location) $null }
            function Test-Path { param($Path) $true }
            function Get-AgentRoles { @{} }
            # Realistic Get-CodebaseLayers order: highest-to-lowest (de, prefs, prat) - used for
            # merge precedence elsewhere, not reading order.
            function Get-CodebaseLayers {
                @(@{ Name = 'de'; Path = 'C:/layers/de' }, @{ Name = 'prefs'; Path = 'C:/layers/prefs' }, @{ Name = 'prat'; Path = 'C:/layers/prat' })
            }
            function Get-Content { param($Path, [switch] $Raw) "content-of($Path)" }
        }

        It "reads foundational-to-specific: prat, then prefs, then de" {
            $result = & $script -cwd "C:/some/project"
            $idxPrat  = $result.contextMessage.IndexOf('content-of(C:/layers/prat/AGENTS.md)')
            $idxPrefs = $result.contextMessage.IndexOf('content-of(C:/layers/prefs/AGENTS.md)')
            $idxDe    = $result.contextMessage.IndexOf('content-of(C:/layers/de/AGENTS.md)')
            $idxPrat  | Should -BeLessThan $idxPrefs
            $idxPrefs | Should -BeLessThan $idxDe
        }
    }

    Context "AGENTS.md content combination — a cluster member has no AGENTS.md file" {
        BeforeAll {
            function Get-PratProject { param($Location) $null }
            function Test-Path { param($Path) $Path -ne 'C:/layers/prat/AGENTS.md' }
            function Get-AgentRoles { @{} }
            function Get-CodebaseLayers {
                @(@{ Name = 'prat'; Path = 'C:/layers/prat' }, @{ Name = 'prefs'; Path = 'C:/layers/prefs' })
            }
            function Get-Content { param($Path, [switch] $Raw) "content-of($Path)" }
        }

        It "omits content for a cluster member whose AGENTS.md doesn't exist" {
            $result = & $script -cwd "C:/some/project"
            $result.contextMessage | Should -Not -BeLike "*content-of(C:/layers/prat/AGENTS.md)*"
            $result.contextMessage | Should -BeLike "*content-of(C:/layers/prefs/AGENTS.md)*"
        }
    }

    Context "AGENTS.md content combination — repo opts in via agentInstructionsFile" {
        BeforeAll {
            function Get-PratProject { param($Location) @{ agentRole = 'myrole'; root = 'C:/repos/myrepo'; trustAgentInstructions = $true; agentInstructionsFile = '.github/copilot-instructions.md' } }
            function Test-Path { param($Path) $true }
            function Get-AgentRoles { @{} }
            function Get-CodebaseLayers { @() }
            function Get-Content { param($Path, [switch] $Raw) "content-of($Path)" }
        }

        It "loads the repo's own configured path, relative to the repo root" {
            $result = & $script -cwd "C:/repos/myrepo"
            $result.contextMessage | Should -BeLike "*content-of(C:/repos/myrepo/.github/copilot-instructions.md)*"
        }
    }

    Context "AGENTS.md content combination — trusted repo without agentInstructionsFile defaults to AGENTS.md" {
        BeforeAll {
            function Get-PratProject { param($Location) @{ agentRole = 'myrole'; root = 'C:/repos/myrepo'; trustAgentInstructions = $true } }
            function Test-Path { param($Path) $true }
            function Get-AgentRoles { @{} }
            function Get-CodebaseLayers { @() }
            function Get-Content { param($Path, [switch] $Raw) "content-of($Path)" }
        }

        It "loads AGENTS.md at the repo root" {
            $result = & $script -cwd "C:/repos/myrepo"
            $result.contextMessage | Should -BeLike "*content-of(C:/repos/myrepo/AGENTS.md)*"
        }
    }

    Context "AGENTS.md content combination — repo without trustAgentInstructions doesn't opt in" {
        BeforeAll {
            function Get-PratProject { param($Location) @{ agentRole = 'myrole'; root = 'C:/repos/myrepo' } }
            function Test-Path { param($Path) $true }
            function Get-AgentRoles { @{} }
            function Get-CodebaseLayers { @() }
            function Get-Content { param($Path, [switch] $Raw) "content-of($Path)" }
        }

        It "does not load an AGENTS.md at the repo root just because it exists" {
            $result = & $script -cwd "C:/repos/myrepo"
            $result.contextMessage | Should -Not -BeLike "*content-of(*"
        }
    }

    Context "AGENTS.md content combination — opted-in file missing on disk" {
        BeforeAll {
            function Get-PratProject { param($Location) @{ agentRole = 'myrole'; root = 'C:/repos/myrepo'; trustAgentInstructions = $true; agentInstructionsFile = 'AGENTS.md' } }
            function Test-Path { param($Path) $Path -notlike '*AGENTS.md' }
            function Get-AgentRoles { @{} }
            function Get-CodebaseLayers { @() }
            function Get-Content { param($Path, [switch] $Raw) "content-of($Path)" }
        }

        It "omits it without error" {
            { & $script -cwd "C:/repos/myrepo" } | Should -Not -Throw
            $result = & $script -cwd "C:/repos/myrepo"
            $result.contextMessage | Should -Not -BeLike "*content-of(*"
        }
    }

    Context "AGENTS.md content combination — opted-in path coincides with a cluster member" {
        BeforeAll {
            function Get-PratProject { param($Location) @{ agentRole = 'myrole'; root = 'C:/layers/prat'; trustAgentInstructions = $true; agentInstructionsFile = 'AGENTS.md' } }
            function Test-Path { param($Path) $true }
            function Get-AgentRoles { @{} }
            function Get-CodebaseLayers { @(@{ Name = 'prat'; Path = 'C:/layers/prat' }) }
            function Get-Content { param($Path, [switch] $Raw) "content-of($Path)" }
        }

        It "doesn't duplicate the content in the output" {
            $result = & $script -cwd "C:/layers/prat"
            ([regex]::Matches($result.contextMessage, [regex]::Escape('content-of(C:/layers/prat/AGENTS.md)'))).Count | Should -Be 1
        }
    }

    Context "project has root but no agentRole" {
        BeforeAll {
            function Get-PratProject { param($Location) @{ root = 'C:/repos/myrepo' } }
            function Test-Path { param($Path) $true }
            function Get-AgentRoles { @{} }
        }

        It "uses default role and populates roleName, targetRepo and contextMessage" {
            $result = & $script -cwd "C:/repos/myrepo"
            $result.roleName       | Should -Be 'default'
            $result.roleDir        | Should -BeLike "*/agentRoles/default"
            $result.targetRepo     | Should -Be "C:/repos/myrepo"
            $result.contextMessage | Should -BeLike "*C:/repos/myrepo*"
        }
    }

    Context "role with repoSkills" {
        BeforeAll {
            function Get-PratProject { param($Location) @{ agentRole = 'huggingface'; root = 'C:/repos/hf' } }
            function Test-Path { param($Path) $true }
            function Get-AgentRoles {
                @{ huggingface = @{ skills = @('a'); repoSkills = @(@{ repo = 'huggingface'; from = 'skills'; skills = @('huggingface-local-models') }) } }
            }
        }

        It "attaches the role's repoSkills to the context" {
            $result = & $script -cwd "C:/repos/ct"
            @($result.repoSkills)[0].repo   | Should -Be 'huggingface'
            @($result.repoSkills)[0].skills | Should -Be @('huggingface-local-models')
        }
    }

    Context "role without repoSkills" {
        BeforeAll {
            function Get-PratProject { param($Location) @{ agentRole = 'plain'; root = 'C:/repos/p' } }
            function Test-Path { param($Path) $true }
            function Get-AgentRoles { @{ plain = @{ skills = @('a') } } }
        }

        It "sets repoSkills to null" {
            $result = & $script -cwd "C:/repos/p"
            $result.repoSkills | Should -BeNull
        }

        It "sets repoAgents to null" {
            $result = & $script -cwd "C:/repos/p"
            $result.repoAgents | Should -BeNull
        }
    }

    Context "role with repoAgents" {
        BeforeAll {
            function Get-PratProject { param($Location) @{ agentRole = 'foo'; root = 'C:/repos/foo' } }
            function Test-Path { param($Path) $true }
            function Get-AgentRoles {
                @{ foo = @{ skills = @('a'); repoAgents = @(@{ repo = 'foo'; from = '.github/agents' }) } }
            }
        }

        It "carries the role's repoAgents through to the context" {
            $result = & $script -cwd "C:/repos/foo"
            @($result.repoAgents)[0].repo | Should -Be 'foo'
            @($result.repoAgents)[0].from | Should -Be '.github/agents'
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
