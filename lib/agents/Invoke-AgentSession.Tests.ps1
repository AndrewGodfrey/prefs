BeforeAll {
    # Invoke-AgentSession.ps1 calls Set-EnvTemp/Restore-Env assuming the caller's profile already
    # loaded PratBase (true for the real 'cl' launch path) — the test process needs it explicitly.
    Import-Module "$home/prat/lib/PratBase/PratBase.psd1" -Force
    $script = "$PSScriptRoot/Invoke-AgentSession.ps1"

    function New-MockCtx {
        param([string] $RoleDir, [string] $TargetRepo = $null, [string] $ContextMessage = $null)
        @{ roleName = 'testrole'; roleDir = $RoleDir; targetRepo = $TargetRepo; contextMessage = $ContextMessage }
    }
}

Describe "Invoke-AgentSession" {
    Context "unbound project — null targetRepo" {
        BeforeAll {
            $roleDir  = (New-Item "TestDrive:/role-unbound" -ItemType Directory).FullName
            $ctx      = New-MockCtx -RoleDir $roleDir
            $captured = @{}
            $hook = { param($resumeSid, $allArgs) $captured.resumeSid = $resumeSid; $captured.allArgs = $allArgs }
        }

        It "calls hook with null resumeSid and no --add-dir" {
            & $script -Harness 'claude' -LaunchHook $hook -Context $ctx 'someArg'
            $captured.resumeSid | Should -BeNull
            $captured.allArgs   | Should -Not -Contain '--add-dir'
        }

        It "passes through extra args to hook" {
            & $script -Harness 'claude' -LaunchHook $hook -Context $ctx 'foo' 'bar'
            $captured.allArgs | Should -Contain 'foo'
            $captured.allArgs | Should -Contain 'bar'
        }
    }

    Context "bound-repo project — targetRepo and contextMessage set" {
        BeforeAll {
            $roleDir  = (New-Item "TestDrive:/role-bound" -ItemType Directory).FullName
            $ctx      = New-MockCtx -RoleDir $roleDir -TargetRepo 'C:/repos/myrepo' -ContextMessage 'work on C:/repos/myrepo'
            $captured = @{}
            $hook = { param($resumeSid, $allArgs) $captured.resumeSid = $resumeSid; $captured.allArgs = $allArgs }
        }

        It "includes --add-dir <targetRepo> in hook args" {
            & $script -Harness 'claude' -LaunchHook $hook -Context $ctx
            $idx = [array]::IndexOf([object[]]$captured.allArgs, '--add-dir')
            $idx | Should -BeGreaterOrEqual 0
            $captured.allArgs[$idx + 1] | Should -Be 'C:/repos/myrepo'
        }

        It "includes --append-system-prompt mentioning targetRepo in hook args" {
            & $script -Harness 'claude' -LaunchHook $hook -Context $ctx
            $idx = [array]::IndexOf([object[]]$captured.allArgs, '--append-system-prompt')
            $idx | Should -BeGreaterOrEqual 0
            $captured.allArgs[$idx + 1] | Should -BeLike '*C:/repos/myrepo*'
        }
    }

    Context "claude's args come from prefs's own built-in, not a switch case — but de can't reconfigure them" {
        BeforeAll {
            $roleDir  = (New-Item "TestDrive:/role-claude-override" -ItemType Directory).FullName
            $ctx      = New-MockCtx -RoleDir $roleDir -TargetRepo 'C:/repos/myrepo' -ContextMessage 'work on C:/repos/myrepo'
            $captured = @{}
            $hook = { param($resumeSid, $allArgs) $captured.allArgs = $allArgs }
        }

        It "keeps --add-dir and --append-system-prompt even if the registry tries to reconfigure claude (de selects, doesn't configure)" {
            function Get-AgentHarnesses { @(@{ name = 'claude'; supportsAddDir = $false; contextArgStyle = 'none' }) }

            & $script -Harness 'claude' -LaunchHook $hook -Context $ctx
            $captured.allArgs | Should -Contain '--add-dir'
            $captured.allArgs | Should -Contain '--append-system-prompt'
        }
    }

    Context "--resume <sid> in passthrough args" {
        BeforeAll {
            $roleDir  = (New-Item "TestDrive:/role-resume" -ItemType Directory).FullName
            $ctx      = New-MockCtx -RoleDir $roleDir
            $captured = @{}
            $hook = { param($resumeSid, $allArgs) $captured.resumeSid = $resumeSid; $captured.allArgs = $allArgs }
        }

        It "extracts sid and passes non-null resumeSid to hook" {
            & $script -Harness 'claude' -LaunchHook $hook -Context $ctx '--resume' 'abc123'
            $captured.resumeSid | Should -Be 'abc123'
        }

        It "leaves --resume args in allArgs for the harness" {
            & $script -Harness 'claude' -LaunchHook $hook -Context $ctx '--resume' 'abc123'
            $captured.allArgs | Should -Contain '--resume'
            $captured.allArgs | Should -Contain 'abc123'
        }
    }

    Context "CWD management" {
        BeforeAll {
            $roleDir    = (New-Item "TestDrive:/role-cwd" -ItemType Directory).FullName
            $startDir   = (New-Item "TestDrive:/start-cwd" -ItemType Directory).FullName
            $ctx        = New-MockCtx -RoleDir $roleDir
            $captured = @{}
            $hook = { param($resumeSid, $allArgs) $captured.pwdInHook = $PWD.Path }
        }

        It "sets CWD to roleDir when hook is called" {
            & $script -Harness 'claude' -LaunchHook $hook -Context $ctx
            $captured.pwdInHook | Should -Be $roleDir
        }

        It "restores CWD after hook returns" {
            Push-Location $startDir
            try {
                & $script -Harness 'claude' -LaunchHook $hook -Context $ctx
                $PWD.Path | Should -Be $startDir
            } finally {
                Pop-Location
            }
        }
    }

    Context "CL_LAUNCH_CWD env var" {
        BeforeAll {
            $roleDir  = (New-Item "TestDrive:/role-launchcwd" -ItemType Directory).FullName
            $startDir = (New-Item "TestDrive:/start-launchcwd" -ItemType Directory).FullName
            $ctx      = New-MockCtx -RoleDir $roleDir
            $captured = @{}
            $hook = { param($resumeSid, $allArgs) $captured.envDuringHook = $env:CL_LAUNCH_CWD }
        }

        BeforeEach {
            Remove-Item Env:\CL_LAUNCH_CWD -ErrorAction SilentlyContinue
        }

        It "sets CL_LAUNCH_CWD to the pre-Push-Location dir during hook invocation" {
            Push-Location $startDir
            try {
                & $script -Harness 'claude' -LaunchHook $hook -Context $ctx
                $captured.envDuringHook | Should -Be $startDir
            } finally {
                Pop-Location
            }
        }

        It "clears CL_LAUNCH_CWD after the hook returns" {
            & $script -Harness 'claude' -LaunchHook $hook -Context $ctx
            $env:CL_LAUNCH_CWD | Should -BeNullOrEmpty
        }

        It "does not leave CL_LAUNCH_CWD set when Push-Location fails" {
            # Push-Location on a missing path is a non-terminating error by default — force it
            # terminating (as e.g. a caller-set 'Stop' preference would) to exercise the failure path.
            $badCtx = New-MockCtx -RoleDir "TestDrive:/does-not-exist"
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Stop'
            try {
                { & $script -Harness 'claude' -LaunchHook $hook -Context $badCtx } | Should -Throw
            } finally {
                $ErrorActionPreference = $prevEap
            }
            $env:CL_LAUNCH_CWD | Should -BeNullOrEmpty
        }
    }

    Context "copilot harness — bound-repo project" {
        BeforeAll {
            $roleDir  = (New-Item "TestDrive:/role-copilot" -ItemType Directory).FullName
            $ctx      = New-MockCtx -RoleDir $roleDir -TargetRepo 'C:/repos/myrepo' -ContextMessage 'work on C:/repos/myrepo'
            $captured = @{}
            $hook = { param($resumeSid, $allArgs) $captured.allArgs = $allArgs }
        }

        It "passes --add-dir but not --append-system-prompt" {
            & $script -Harness 'copilot' -LaunchHook $hook -Context $ctx
            $captured.allArgs | Should -Contain '--add-dir'
            $captured.allArgs | Should -Not -Contain '--append-system-prompt'
        }
    }

    Context "pi harness — bound-repo project" {
        BeforeAll {
            $roleDir  = (New-Item "TestDrive:/role-pi" -ItemType Directory).FullName
            $ctx      = New-MockCtx -RoleDir $roleDir -TargetRepo 'C:/repos/myrepo' -ContextMessage 'work on C:/repos/myrepo'
            $captured = @{}
            $hook = { param($resumeSid, $allArgs) $captured.allArgs = $allArgs }
        }

        It "never gets --add-dir, even with a bound repo (preserved from its old switch case)" {
            & $script -Harness 'pi' -LaunchHook $hook -Context $ctx
            $captured.allArgs | Should -Not -Contain '--add-dir'
        }

        It "includes --append-system-prompt mentioning targetRepo" {
            & $script -Harness 'pi' -LaunchHook $hook -Context $ctx
            $idx = [array]::IndexOf([object[]]$captured.allArgs, '--append-system-prompt')
            $idx | Should -BeGreaterOrEqual 0
            $captured.allArgs[$idx + 1] | Should -BeLike '*C:/repos/myrepo*'
        }

        It "includes --skill ./.claude/skills/ (its built-in additionalArgs)" {
            & $script -Harness 'pi' -LaunchHook $hook -Context $ctx
            $idx = [array]::IndexOf([object[]]$captured.allArgs, '--skill')
            $idx | Should -BeGreaterOrEqual 0
            $captured.allArgs[$idx + 1] | Should -Be './.claude/skills/'
        }
    }

    Context "pi harness — unbound project (no contextMessage)" {
        BeforeAll {
            $roleDir  = (New-Item "TestDrive:/role-pi-unbound" -ItemType Directory).FullName
            $ctx      = New-MockCtx -RoleDir $roleDir
            $captured = @{}
            $hook = { param($resumeSid, $allArgs) $captured.allArgs = $allArgs }
        }

        It "still includes --skill even with no contextMessage (additionalArgs isn't coupled to it)" {
            & $script -Harness 'pi' -LaunchHook $hook -Context $ctx
            $captured.allArgs | Should -Contain '--skill'
        }
    }

    Context "registered custom harness — bound-repo project" {
        BeforeAll {
            $roleDir  = (New-Item "TestDrive:/role-custom" -ItemType Directory).FullName
            $ctx      = New-MockCtx -RoleDir $roleDir -TargetRepo 'C:/repos/myrepo' -ContextMessage 'work on C:/repos/myrepo'
            $captured = @{}
            $hook = { param($resumeSid, $allArgs) $captured.allArgs = $allArgs }
        }

        It "passes through args with no --add-dir and no --append-system-prompt (bare passthrough)" {
            function Get-AgentHarnesses { @(@{ name = 'customtool' }) }

            & $script -Harness 'customtool' -LaunchHook $hook -Context $ctx 'someArg'
            $captured.allArgs | Should -Not -Contain '--add-dir'
            $captured.allArgs | Should -Not -Contain '--append-system-prompt'
            $captured.allArgs | Should -Contain 'someArg'
        }
    }

    Context "unknown harness" {
        BeforeAll {
            $roleDir  = (New-Item "TestDrive:/role-unk" -ItemType Directory).FullName
            $ctx      = New-MockCtx -RoleDir $roleDir
            $hook = { param($resumeSid, $allArgs) }
        }

        It "throws for unknown harness" {
            { & $script -Harness 'unknown' -LaunchHook $hook -Context $ctx } | Should -Throw "Unknown harness*"
        }

        It "throws for a harness absent from Get-AgentHarnesses even when the command exists" {
            function Get-AgentHarnesses { @(@{ name = 'customtool' }) }

            { & $script -Harness 'somethingelse' -LaunchHook $hook -Context $ctx } | Should -Throw "Unknown harness*"
        }
    }

    Context "commit grant — a descriptor that renders its own flags" {
        BeforeEach {
            $roleDir  = (New-Item "TestDrive:/role-grant-flags" -ItemType Directory -Force).FullName
            $ctx      = New-MockCtx -RoleDir $roleDir -ContextMessage 'work on C:/repos/myrepo'
            $captured = @{}
            $hook = { param($resumeSid, $allArgs) $captured.allArgs = $allArgs }
            # A renderer wins over the prose even for a harness that could carry prose, so a harness
            # that writes its own grant section is never told twice.
            function Get-AgentHarnesses {
                @(@{ name = 'flagtool'; contextArgStyle = 'append-system-prompt'
                     commitGrantArgs = { param([string] $branch, [string[]] $repoPaths)
                                         @($repoPaths | ForEach-Object { '--grant-repo'; $_ }) + @('--grant-branch', $branch) } })
            }
        }

        It "passes the rendered flags to the hook" {
            & $script -Harness 'flagtool' -LaunchHook $hook -Context $ctx -CommitBranch 'feature' -CommitRepo @('C:/repos/myrepo', 'C:/repos/myotherrepo')

            $captured.allArgs | Should -Contain '--grant-repo'
            $captured.allArgs | Should -Contain 'C:/repos/myotherrepo'
            $idx = [array]::IndexOf([object[]]$captured.allArgs, '--grant-branch')
            $captured.allArgs[$idx + 1] | Should -Be 'feature'
        }

        It "adds no grant prose to the context message" {
            & $script -Harness 'flagtool' -LaunchHook $hook -Context $ctx -CommitBranch 'feature' -CommitRepo @('C:/repos/myrepo')

            $idx = [array]::IndexOf([object[]]$captured.allArgs, '--append-system-prompt')
            $captured.allArgs[$idx + 1] | Should -Be 'work on C:/repos/myrepo'
        }
    }

    Context "commit grant — a harness told in prose" {
        BeforeEach {
            $roleDir  = (New-Item "TestDrive:/role-grant-prose" -ItemType Directory -Force).FullName
            $ctx      = New-MockCtx -RoleDir $roleDir -ContextMessage 'work on C:/repos/myrepo'
            $captured = @{}
            $hook = { param($resumeSid, $allArgs) $captured.allArgs = $allArgs }
        }

        It "appends the grant to the appended system prompt, keeping the context message" {
            & $script -Harness 'claude' -LaunchHook $hook -Context $ctx -CommitBranch 'feature' -CommitRepo @('C:/repos/myrepo', 'C:/repos/myotherrepo')

            $idx = [array]::IndexOf([object[]]$captured.allArgs, '--append-system-prompt')
            $appended = $captured.allArgs[$idx + 1]
            $appended | Should -BeLike '*work on C:/repos/myrepo*'
            $appended | Should -BeLike '*feature*'
            $appended | Should -BeLike '*C:/repos/myotherrepo*'
            $appended | Should -BeLike '*one commit per step*'
            $appended | Should -BeLike '*wrap*'
        }

        It "says nothing about committing when no grant was passed" {
            & $script -Harness 'claude' -LaunchHook $hook -Context $ctx

            $idx = [array]::IndexOf([object[]]$captured.allArgs, '--append-system-prompt')
            $captured.allArgs[$idx + 1] | Should -Be 'work on C:/repos/myrepo'
        }

        It "reaches copilot through its instructions file" {
            $hook = { param($resumeSid, $allArgs)
                      $captured.instructions = Get-Content (Join-Path $env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS 'session-context.instructions.md') -Raw }

            & $script -Harness 'copilot' -LaunchHook $hook -Context $ctx -CommitBranch 'feature' -CommitRepo @('C:/repos/myrepo')

            $captured.instructions | Should -BeLike '*work on C:/repos/myrepo*'
            $captured.instructions | Should -BeLike '*one commit per step*'
        }

        It "carries the grant with no context message of its own to carry it in" {
            $bareCtx = New-MockCtx -RoleDir $roleDir

            & $script -Harness 'claude' -LaunchHook $hook -Context $bareCtx -CommitBranch 'feature' -CommitRepo @('C:/repos/myrepo')

            $idx = [array]::IndexOf([object[]]$captured.allArgs, '--append-system-prompt')
            $captured.allArgs[$idx + 1] | Should -BeLike '*one commit per step*'
        }
    }

    Context "commit grant — a harness that can express neither" {
        BeforeEach {
            $roleDir  = (New-Item "TestDrive:/role-grant-neither" -ItemType Directory -Force).FullName
            $ctx      = New-MockCtx -RoleDir $roleDir
            $captured = @{}
            $hook = { param($resumeSid, $allArgs) $captured.allArgs = $allArgs }
            function Get-AgentHarnesses { @(@{ name = 'customtool' }) }
        }

        It "warns, and launches with no grant flags" {
            Mock Write-Warning { }

            & $script -Harness 'customtool' -LaunchHook $hook -Context $ctx -CommitBranch 'feature' -CommitRepo @('C:/repos/myrepo') 'someArg'

            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*commit*' }
            @($captured.allArgs) | Should -Be @('someArg')
        }
    }

    Context "commit grant — half a grant" {
        BeforeEach {
            $roleDir = (New-Item "TestDrive:/role-grant-half" -ItemType Directory -Force).FullName
            $ctx     = New-MockCtx -RoleDir $roleDir
            $hook    = { param($resumeSid, $allArgs) }
        }

        It "throws when the branch arrives without repos" {
            { & $script -Harness 'claude' -LaunchHook $hook -Context $ctx -CommitBranch 'feature' } |
                Should -Throw '*commit grant*'
        }

        It "throws when repos arrive without a branch" {
            { & $script -Harness 'claude' -LaunchHook $hook -Context $ctx -CommitRepo @('C:/repos/myrepo') } |
                Should -Throw '*commit grant*'
        }
    }

    Context "repoSkills present — syncs junctions" {
        BeforeAll {
            $roleDir = (New-Item "TestDrive:/role-reposkills" -ItemType Directory).FullName
            $ctx     = New-MockCtx -RoleDir $roleDir
            $ctx.repoSkills = @(@{ repo = 'huggingface'; from = '/claude/skills'; skills = @('x') })
            $hook = { param($resumeSid, $allArgs) }
        }

        It "calls Sync-RepoSkillJunctions with the role's .claude/skills dir" {
            Mock Sync-RepoSkillJunctions { }
            & $script -Harness 'claude' -LaunchHook $hook -Context $ctx
            Should -Invoke Sync-RepoSkillJunctions -Times 1 -Exactly -ParameterFilter {
                $SkillsDir -like "*role-reposkills*skills"
            }
        }
    }

    Context "no repoSkills — does not sync" {
        BeforeAll {
            $roleDir = (New-Item "TestDrive:/role-noreposkills" -ItemType Directory).FullName
            $ctx     = New-MockCtx -RoleDir $roleDir
            $hook = { param($resumeSid, $allArgs) }
        }

        It "does not call Sync-RepoSkillJunctions" {
            Mock Sync-RepoSkillJunctions { }
            & $script -Harness 'claude' -LaunchHook $hook -Context $ctx
            Should -Invoke Sync-RepoSkillJunctions -Times 0 -Exactly
        }
    }

    Context "repoAgents present — syncs agent junctions" {
        BeforeAll {
            $roleDir = (New-Item "TestDrive:/role-repoagents" -ItemType Directory).FullName
            $ctx     = New-MockCtx -RoleDir $roleDir
            $ctx.repoAgents = @(@{ repo = 'foo'; from = '.claude/agents' })
            $hook = { param($resumeSid, $allArgs) }
        }

        It "calls Sync-RoleAgents with the role dir" {
            Mock Sync-RoleAgents { }
            & $script -Harness 'claude' -LaunchHook $hook -Context $ctx
            Should -Invoke Sync-RoleAgents -Times 1 -Exactly -ParameterFilter {
                $RoleDir -like "*role-repoagents"
            }
        }
    }

    Context "no repoAgents — still syncs, so a de-listed config self-heals" {
        BeforeAll {
            $roleDir = (New-Item "TestDrive:/role-norepoagents" -ItemType Directory).FullName
            $ctx     = New-MockCtx -RoleDir $roleDir
            $hook = { param($resumeSid, $allArgs) }
        }

        It "still calls Sync-RoleAgents with null repoAgents" {
            Mock Sync-RoleAgents { }
            & $script -Harness 'claude' -LaunchHook $hook -Context $ctx
            Should -Invoke Sync-RoleAgents -Times 1 -Exactly -ParameterFilter {
                $null -eq $RepoAgents
            }
        }
    }

    Context "repoInstructions present — passes through to Sync-RoleAgents" {
        BeforeAll {
            $roleDir = (New-Item "TestDrive:/role-repoinst" -ItemType Directory).FullName
            $ctx     = New-MockCtx -RoleDir $roleDir
            $ctx.repoInstructions = @(@{ repo = 'bar'; from = '.github/instructions' })
            $hook = { param($resumeSid, $allArgs) }
        }

        It "passes RepoInstructions to Sync-RoleAgents" {
            Mock Sync-RoleAgents { }
            & $script -Harness 'claude' -LaunchHook $hook -Context $ctx
            Should -Invoke Sync-RoleAgents -Times 1 -Exactly -ParameterFilter {
                $null -ne $RepoInstructions -and @($RepoInstructions)[0].repo -eq 'bar'
            }
        }
    }
}
