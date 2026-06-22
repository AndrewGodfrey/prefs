BeforeAll {
    $script = "$PSScriptRoot/Invoke-AgentSession.ps1"

    function New-MockCtxScript {
        param([string] $Name, [string] $RoleDir, [string] $TargetRepo = '$null', [string] $ContextMessage = '$null')
        $roleDirLiteral = $RoleDir -replace '\\', '/'
        $content = "param(`$cwd) @{ roleDir = '$roleDirLiteral'; targetRepo = $TargetRepo; contextMessage = $ContextMessage }"
        $item = New-Item "TestDrive:/$Name" -ItemType File -Value $content
        return $item.FullName
    }
}

Describe "Invoke-AgentSession" {
    Context "unbound project — null targetRepo" {
        BeforeAll {
            $roleDir  = (New-Item "TestDrive:/role-unbound" -ItemType Directory).FullName
            $mockPath = New-MockCtxScript -Name 'ctx-unbound.ps1' -RoleDir $roleDir
            $captured = @{}
            $hook = { param($resumeSid, $allArgs) $captured.resumeSid = $resumeSid; $captured.allArgs = $allArgs }
        }

        It "calls hook with null resumeSid and no --add-dir" {
            & $script -Harness 'claude' -LaunchHook $hook -GetAgentRoleContextScript $mockPath 'someArg'
            $captured.resumeSid | Should -BeNull
            $captured.allArgs   | Should -Not -Contain '--add-dir'
        }

        It "passes through extra args to hook" {
            & $script -Harness 'claude' -LaunchHook $hook -GetAgentRoleContextScript $mockPath 'foo' 'bar'
            $captured.allArgs | Should -Contain 'foo'
            $captured.allArgs | Should -Contain 'bar'
        }
    }

    Context "bound-repo project — targetRepo and contextMessage set" {
        BeforeAll {
            $roleDir  = (New-Item "TestDrive:/role-bound" -ItemType Directory).FullName
            $mockPath = New-MockCtxScript -Name 'ctx-bound.ps1' -RoleDir $roleDir `
                -TargetRepo "'C:/repos/myrepo'" -ContextMessage "'work on C:/repos/myrepo'"
            $captured = @{}
            $hook = { param($resumeSid, $allArgs) $captured.resumeSid = $resumeSid; $captured.allArgs = $allArgs }
        }

        It "includes --add-dir <targetRepo> in hook args" {
            & $script -Harness 'claude' -LaunchHook $hook -GetAgentRoleContextScript $mockPath
            $idx = [array]::IndexOf([object[]]$captured.allArgs, '--add-dir')
            $idx | Should -BeGreaterOrEqual 0
            $captured.allArgs[$idx + 1] | Should -Be 'C:/repos/myrepo'
        }

        It "includes --append-system-prompt mentioning targetRepo in hook args" {
            & $script -Harness 'claude' -LaunchHook $hook -GetAgentRoleContextScript $mockPath
            $idx = [array]::IndexOf([object[]]$captured.allArgs, '--append-system-prompt')
            $idx | Should -BeGreaterOrEqual 0
            $captured.allArgs[$idx + 1] | Should -BeLike '*C:/repos/myrepo*'
        }
    }

    Context "--resume <sid> in passthrough args" {
        BeforeAll {
            $roleDir  = (New-Item "TestDrive:/role-resume" -ItemType Directory).FullName
            $mockPath = New-MockCtxScript -Name 'ctx-resume.ps1' -RoleDir $roleDir
            $captured = @{}
            $hook = { param($resumeSid, $allArgs) $captured.resumeSid = $resumeSid; $captured.allArgs = $allArgs }
        }

        It "extracts sid and passes non-null resumeSid to hook" {
            & $script -Harness 'claude' -LaunchHook $hook -GetAgentRoleContextScript $mockPath '--resume' 'abc123'
            $captured.resumeSid | Should -Be 'abc123'
        }

        It "leaves --resume args in allArgs for the harness" {
            & $script -Harness 'claude' -LaunchHook $hook -GetAgentRoleContextScript $mockPath '--resume' 'abc123'
            $captured.allArgs | Should -Contain '--resume'
            $captured.allArgs | Should -Contain 'abc123'
        }
    }

    Context "CWD management" {
        BeforeAll {
            $roleDir    = (New-Item "TestDrive:/role-cwd" -ItemType Directory).FullName
            $startDir   = (New-Item "TestDrive:/start-cwd" -ItemType Directory).FullName
            $mockPath   = New-MockCtxScript -Name 'ctx-cwd.ps1' -RoleDir $roleDir
            $captured = @{}
            $hook = { param($resumeSid, $allArgs) $captured.pwdInHook = $PWD.Path }
        }

        It "sets CWD to roleDir when hook is called" {
            & $script -Harness 'claude' -LaunchHook $hook -GetAgentRoleContextScript $mockPath
            $captured.pwdInHook | Should -Be $roleDir
        }

        It "restores CWD after hook returns" {
            Push-Location $startDir
            try {
                & $script -Harness 'claude' -LaunchHook $hook -GetAgentRoleContextScript $mockPath
                $PWD.Path | Should -Be $startDir
            } finally {
                Pop-Location
            }
        }
    }

    Context "copilot harness — bound-repo project" {
        BeforeAll {
            $roleDir  = (New-Item "TestDrive:/role-copilot" -ItemType Directory).FullName
            $mockPath = New-MockCtxScript -Name 'ctx-copilot.ps1' -RoleDir $roleDir `
                -TargetRepo "'C:/repos/myrepo'" -ContextMessage "'work on C:/repos/myrepo'"
            $captured = @{}
            $hook = { param($resumeSid, $allArgs) $captured.allArgs = $allArgs }
        }

        It "passes --add-dir but not --append-system-prompt" {
            & $script -Harness 'copilot' -LaunchHook $hook -GetAgentRoleContextScript $mockPath
            $captured.allArgs | Should -Contain '--add-dir'
            $captured.allArgs | Should -Not -Contain '--append-system-prompt'
        }
    }

    Context "unknown harness" {
        BeforeAll {
            $roleDir  = (New-Item "TestDrive:/role-unk" -ItemType Directory).FullName
            $mockPath = New-MockCtxScript -Name 'ctx-unk.ps1' -RoleDir $roleDir
            $hook = { param($resumeSid, $allArgs) }
        }

        It "throws for unknown harness" {
            { & $script -Harness 'unknown' -LaunchHook $hook -GetAgentRoleContextScript $mockPath } | Should -Throw "Unknown harness*"
        }
    }
}
