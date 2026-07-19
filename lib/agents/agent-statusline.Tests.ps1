BeforeAll {
    Import-Module "$home/prat/lib/PratBase/PratBase.psd1" -Force
    . "$PSScriptRoot/agent-statusline.ps1"

    $script:now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $script:testDriveRoot = ((Get-Item "TestDrive:\").FullName -replace '\\', '/').TrimEnd('/')

    function writePlanFile([string] $name, [string] $content) {
        $path = "$script:testDriveRoot/$name"
        [System.IO.File]::WriteAllText($path, $content)
        return $path
    }

    function MakeWindow($usedPct, $minsLeft) {
        @{ used_percentage = $usedPct; resets_at = $script:now + [int]($minsLeft * 60) }
    }

    function CallRlDisplay($usedPct, $minsLeft, $label = '5h', $barWidth = 5, $totalMins = 300, $yellowMins = 180, $redMins = 60, $minMinsLeft = 0) {
        Get-RateLimitDisplay (MakeWindow $usedPct $minsLeft) $label $barWidth $totalMins $yellowMins $redMins $minMinsLeft $script:now
    }
}

Describe "claude-statusline" {
    Context "rate limit warnings" {
        # usedPct=50, minsLeft=120: elapsedMins=180, elapsedPct=60% — behind pace
        It "no color when on pace" {
            CallRlDisplay 50 120 | Should -Not -Match '\[38;2;'
        }

        # usedPct=70, minsLeft=120: elapsedPct=60%; minsToExhaust=30*180/70=77 min → yellow
        It "yellow when ahead of pace but minsToExhaust >= redThreshold" {
            CallRlDisplay 70 120 | Should -Match '\[38;2;255;200;0m'
            CallRlDisplay 70 120 | Should -Not -Match '\[38;2;255;120;0m'
        }

        # usedPct=90, minsLeft=200: elapsedPct=33%; minsToExhaust=10*100/90=11 min → red
        It "red when minsToExhaust < redThreshold" {
            CallRlDisplay 90 200 | Should -Match '\[38;2;255;120;0m'
        }

        # usedPct=100 — completely out, takes priority over the pace calc regardless of minsLeft
        It "red (completely out) when usedPct >= 100" {
            CallRlDisplay 100 120 | Should -Match '\[38;2;220;50;50m'
        }

        # usedPct=35, minsLeft=200: elapsedMins=100, elapsedPct=33.3%; minsToExhaust=65*100/35=185.7 min → yellow-green
        It "yellow-green when ahead of pace and minsToExhaust >= yellowThreshold" {
            CallRlDisplay 35 200 | Should -Match '\[38;2;140;185;35m'
        }

        # elapsedMins=2 ≤ 5 — guard clause, no warning even at 90% used
        It "no warning when elapsed <= 5 minutes" {
            CallRlDisplay 90 298 | Should -Not -Match '\[38;2;'
        }

        It "hidden when minsLeft < minMinsLeft" {
            CallRlDisplay 50 10 -minMinsLeft 15 | Should -BeNullOrEmpty
        }
    }

    Context "7-day window" {
        # usedPct=70, minsLeft=5000: elapsedMins=5080, elapsedPct=50.4%; minsToExhaust=30*5080/70=2177 min → yellow
        It "yellow when ahead of pace but minsToExhaust >= 1440" {
            CallRlDisplay 70 5000 -label '7d' -barWidth 7 -totalMins 10080 -yellowMins 4320 -redMins 1440 | Should -Match '\[38;2;255;200;0m'
        }

        # usedPct=90, minsLeft=9000: elapsedMins=1080, elapsedPct=10.7%; minsToExhaust=10*1080/90=120 min → red
        It "red when minsToExhaust < 1440" {
            CallRlDisplay 90 9000 -label '7d' -barWidth 7 -totalMins 10080 -yellowMins 4320 -redMins 1440 | Should -Match '\[38;2;255;120;0m'
        }

        It "shows days format (1dp) when minsLeft >= 1440" {
            CallRlDisplay 10 2880 -label '7d' -barWidth 7 -totalMins 10080 -yellowMins 4320 -redMins 1440 | Should -Match '7d:.*2\.0d'
        }

        It "shows seconds when minsLeft < 1" {
            CallRlDisplay 10 0.5 -label '7d' -barWidth 7 -totalMins 10080 -yellowMins 4320 -redMins 1440 | Should -Match '7d:.*30s'
        }
    }

    Context "time formatting" {
        It "shows minutes when minsLeft < 60" {
            CallRlDisplay 10 45 | Should -Match '5h:.*45m'
        }

        It "shows hours (1dp) when minsLeft >= 60" {
            CallRlDisplay 10 90 | Should -Match '5h:.*1\.5h'
        }

        It "7d shows hours (1dp) when 90 <= minsLeft < 1440" {
            CallRlDisplay 10 120 -label '7d' -barWidth 7 -totalMins 10080 -yellowMins 4320 -redMins 1440 | Should -Match '7d:.*2\.0h'
        }
    }

    Context "Get-ContextBar" {
        It "computes bar fill from context_window.used_percentage" {
            Get-ContextBar @{ context_window = @{ used_percentage = 50 } } | Should -Be '▰▰▰▱▱'
        }

        It "falls back to current_context_used_percentage (Copilot CLI shape)" {
            Get-ContextBar @{ current_context_used_percentage = 50 } | Should -Be '▰▰▰▱▱'
        }

        It "shows empty bar when neither field is present" {
            Get-ContextBar @{} | Should -Be '▱▱▱▱▱'
        }

        It "caps at 5 filled bars" {
            Get-ContextBar @{ context_window = @{ used_percentage = 100 } } | Should -Be '▰▰▰▰▰'
        }
    }

    Context "Get-RateLimitBarString" {
        It "returns empty string when rate_limits is absent" {
            Get-RateLimitBarString $null $script:now | Should -Be ''
        }

        It "returns empty string when no window produces a display" {
            Get-RateLimitBarString @{ five_hour = (MakeWindow 50 10) } $script:now | Should -Be ''
        }

        It "prefixes with a leading space when at least one window has a display" {
            Get-RateLimitBarString @{ five_hour = (MakeWindow 50 120) } $script:now | Should -Match '^ 5h:'
        }

        It "joins both windows with a space when both produce a display" {
            $result = Get-RateLimitBarString @{ five_hour = (MakeWindow 50 120); seven_day = (MakeWindow 50 5000) } $script:now
            $result | Should -Match '5h:.*7d:'
        }
    }

    Context "Format-LocationString" {
        It "shows the raw cwd when no project is resolved" {
            Format-LocationString $null 'C:\some\path' | Should -Be ' C:\some\path'
        }

        It "shows [id] with no suffix when project has no subdir or buildKind" {
            Format-LocationString @{ id = 'MyRepo' } 'C:\x' | Should -Be ' [myrepo]'
        }

        It "includes buildKind and subdir when present" {
            Format-LocationString @{ id = 'MyRepo'; subdir = 'sub\dir'; buildKind = 'Debug' } 'C:\x' |
                Should -Be ' [myrepo](Debug) sub/dir/'
        }
    }

    Context "Get-StatusLineString" {
        It "shows the sandbox warning marker when CL_SANDBOX_MODE is not '1'" {
            $prev = $env:CL_SANDBOX_MODE
            try {
                Remove-Item Env:\CL_SANDBOX_MODE -ErrorAction SilentlyContinue
                Get-StatusLineString @{ cwd = $env:TEMP } $script:now -NoCwd | Should -Match '\*'
            } finally {
                if ($null -ne $prev) { $env:CL_SANDBOX_MODE = $prev } else { Remove-Item Env:\CL_SANDBOX_MODE -ErrorAction SilentlyContinue }
            }
        }

        It "hides the sandbox warning marker when CL_SANDBOX_MODE is '1'" {
            $prev = $env:CL_SANDBOX_MODE
            try {
                $env:CL_SANDBOX_MODE = '1'
                Get-StatusLineString @{ cwd = $env:TEMP } $script:now -NoCwd | Should -Not -Match '\*'
            } finally {
                if ($null -ne $prev) { $env:CL_SANDBOX_MODE = $prev } else { Remove-Item Env:\CL_SANDBOX_MODE -ErrorAction SilentlyContinue }
            }
        }

        It "shows the model name when present" {
            Get-StatusLineString @{ cwd = $env:TEMP; model = @{ display_name = 'Sonnet 5' } } $script:now -NoCwd |
                Should -Match '\s{3}\(Sonnet 5\)'
        }

        It "omits the model segment when absent" {
            Get-StatusLineString @{ cwd = $env:TEMP } $script:now -NoCwd | Should -Not -Match '\('
        }

        It "omits location when -NoCwd is set" {
            Get-StatusLineString @{ cwd = 'C:\should-not-appear' } $script:now -NoCwd | Should -Not -Match 'should-not-appear'
        }
    }

    Context "subprocess smoke test" {
        It "produces output when run with -NoProfile" {
            $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $json = @{
                context_window = @{ used_percentage = 10 }
                rate_limits    = @{ five_hour = @{ used_percentage = 50; resets_at = $now + 7200 } }
                cwd            = $env:TEMP
            } | ConvertTo-Json -Depth 5
            $out = ($json | pwsh -NoProfile -File "$PSScriptRoot/agent-statusline.ps1") -join ''
            $out | Should -Match '5h:'
        }
    }

    Context "CL_LAUNCH_CWD precedence" {
        It "prefers CL_LAUNCH_CWD over the json cwd when set" {
            $jsonCwd   = Join-Path $env:TEMP "statusline-test-json-$([guid]::NewGuid().ToString('N'))"
            $launchCwd = Join-Path $env:TEMP "statusline-test-launch-$([guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $jsonCwd, $launchCwd -Force | Out-Null
            try {
                $env:CL_LAUNCH_CWD = $launchCwd
                $out = Get-StatusLineString @{ cwd = $jsonCwd } $script:now
                $out | Should -Match ([regex]::Escape($launchCwd))
                $out | Should -Not -Match ([regex]::Escape($jsonCwd))
            } finally {
                Remove-Item Env:\CL_LAUNCH_CWD -ErrorAction SilentlyContinue
                Remove-Item $jsonCwd, $launchCwd -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "falls back to the json cwd when CL_LAUNCH_CWD is unset" {
            $jsonCwd = Join-Path $env:TEMP "statusline-test-fallback-$([guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $jsonCwd -Force | Out-Null
            try {
                Remove-Item Env:\CL_LAUNCH_CWD -ErrorAction SilentlyContinue
                $out = Get-StatusLineString @{ cwd = $jsonCwd } $script:now
                $out | Should -Match ([regex]::Escape($jsonCwd))
            } finally {
                Remove-Item $jsonCwd -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context "Get-PlanStageLabel" {
        It "maps ready-to-plan to planning" {
            Get-PlanStageLabel 'ready-to-plan' | Should -Be 'planning'
        }

        It "maps ready-to-implement to coding" {
            Get-PlanStageLabel 'ready-to-implement' | Should -Be 'coding'
        }

        It "maps code-complete to reviewing" {
            Get-PlanStageLabel 'code-complete' | Should -Be 'reviewing'
        }

        It "defaults checkpointed to planning (pl always resolves it before a session goes live)" {
            Get-PlanStageLabel 'checkpointed' | Should -Be 'planning'
        }

        It "defaults null/unrecognized state to planning" {
            Get-PlanStageLabel $null | Should -Be 'planning'
            Get-PlanStageLabel 'made-up-state' | Should -Be 'planning'
        }
    }

    Context "CL_PLAN_FILE display" {
        It "shows the plan name (no extension) prefixed with its stage" {
            try {
                $env:CL_PLAN_FILE = writePlanFile 'myplan-upgrade.md' "# Title`r`n`r`nbody`r`n"
                $out = Get-StatusLineString @{ cwd = $env:TEMP } $script:now -NoCwd
                $out | Should -Match 'planning:myplan-upgrade'
                $out | Should -Not -Match 'myplan-upgrade\.md'
            } finally {
                Remove-Item Env:\CL_PLAN_FILE -ErrorAction SilentlyContinue
            }
        }

        It "shows 'coding:' when the plan's state is ready-to-implement" {
            try {
                $env:CL_PLAN_FILE = writePlanFile 'coding-plan.md' "---`r`ncurrent-step:`r`n  state: ready-to-implement`r`n---`r`n"
                $out = Get-StatusLineString @{ cwd = $env:TEMP } $script:now -NoCwd
                $out | Should -Match 'coding:coding-plan'
            } finally {
                Remove-Item Env:\CL_PLAN_FILE -ErrorAction SilentlyContinue
            }
        }

        It "shows 'reviewing:' when the plan's state is code-complete" {
            try {
                $env:CL_PLAN_FILE = writePlanFile 'review-plan.md' "---`r`ncurrent-step:`r`n  state: code-complete`r`n---`r`n"
                $out = Get-StatusLineString @{ cwd = $env:TEMP } $script:now -NoCwd
                $out | Should -Match 'reviewing:review-plan'
            } finally {
                Remove-Item Env:\CL_PLAN_FILE -ErrorAction SilentlyContinue
            }
        }

        It "shows no plan segment when CL_PLAN_FILE is unset" {
            Remove-Item Env:\CL_PLAN_FILE -ErrorAction SilentlyContinue
            $out = Get-StatusLineString @{ cwd = $env:TEMP } $script:now -NoCwd
            $out | Should -Not -Match 'planning:|coding:|reviewing:'
        }
    }

    Context "no rate limits" {
        It "no rl section when rate_limits absent" {
            $out = Get-StatusLineString @{ cwd = $env:TEMP } $script:now -NoCwd
            $out | Should -Not -Match '5h:|7d:'
        }
    }
}
