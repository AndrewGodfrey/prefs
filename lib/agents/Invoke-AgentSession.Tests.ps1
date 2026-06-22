BeforeAll {
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

    Context "unknown harness" {
        BeforeAll {
            $roleDir  = (New-Item "TestDrive:/role-unk" -ItemType Directory).FullName
            $ctx      = New-MockCtx -RoleDir $roleDir
            $hook = { param($resumeSid, $allArgs) }
        }

        It "throws for unknown harness" {
            { & $script -Harness 'unknown' -LaunchHook $hook -Context $ctx } | Should -Throw "Unknown harness*"
        }
    }
}
