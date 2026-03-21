BeforeAll {
    Import-Module "$home/prat/lib/PratBase/PratBase.psd1" -Force
    . "$PSScriptRoot/claude-statusline.ps1"

    $script:now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    function MakeWindow($usedPct, $minsLeft) {
        @{ used_percentage = $usedPct; resets_at = $script:now + [int]($minsLeft * 60) }
    }

    function CallRlDisplay($usedPct, $minsLeft, $label = '5h', $barWidth = 5, $totalMins = 300, $redMins = 60, $minMinsLeft = 0) {
        Get-RateLimitDisplay (MakeWindow $usedPct $minsLeft) $label $barWidth $totalMins $redMins $minMinsLeft $script:now
    }
}

Describe "claude-statusline" {
    Context "rate limit warnings" {
        # usedPct=50, minsLeft=120: elapsedMins=180, elapsedPct=60% — behind pace
        It "no color when on pace" {
            CallRlDisplay 50 120 | Should -Not -Match '\[3[13]m'
        }

        # usedPct=70, minsLeft=120: elapsedPct=60%; minsToExhaust=30*180/70=77 min → yellow
        It "yellow when ahead of pace but minsToExhaust >= redThreshold" {
            CallRlDisplay 70 120 | Should -Match '\[33m'
            CallRlDisplay 70 120 | Should -Not -Match '\[31m'
        }

        # usedPct=90, minsLeft=200: elapsedPct=33%; minsToExhaust=10*100/90=11 min → red
        It "red when minsToExhaust < redThreshold" {
            CallRlDisplay 90 200 | Should -Match '\[31m'
        }

        # elapsedMins=2 ≤ 5 — guard clause, no warning even at 90% used
        It "no warning when elapsed <= 5 minutes" {
            CallRlDisplay 90 298 | Should -Not -Match '\[3[13]m'
        }

        It "hidden when minsLeft < minMinsLeft" {
            CallRlDisplay 50 10 -minMinsLeft 15 | Should -BeNullOrEmpty
        }
    }

    Context "7-day window" {
        # usedPct=70, minsLeft=5000: elapsedMins=5080, elapsedPct=50.4%; minsToExhaust=30*5080/70=2177 min → yellow
        It "yellow when ahead of pace but minsToExhaust >= 1440" {
            CallRlDisplay 70 5000 -label '7d' -barWidth 7 -totalMins 10080 -redMins 1440 | Should -Match '\[33m'
        }

        # usedPct=90, minsLeft=9000: elapsedMins=1080, elapsedPct=10.7%; minsToExhaust=10*1080/90=120 min → red
        It "red when minsToExhaust < 1440" {
            CallRlDisplay 90 9000 -label '7d' -barWidth 7 -totalMins 10080 -redMins 1440 | Should -Match '\[31m'
        }

        It "shows days format (1dp) when minsLeft >= 1440" {
            CallRlDisplay 10 2880 -label '7d' -barWidth 7 -totalMins 10080 -redMins 1440 | Should -Match '7d:.*2\.0d'
        }

        It "shows seconds when minsLeft < 1" {
            CallRlDisplay 10 0.5 -label '7d' -barWidth 7 -totalMins 10080 -redMins 1440 | Should -Match '7d:.*30s'
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
            CallRlDisplay 10 120 -label '7d' -barWidth 7 -totalMins 10080 -redMins 1440 | Should -Match '7d:.*2\.0h'
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
            $out = ($json | pwsh -NoProfile -File "$PSScriptRoot/claude-statusline.ps1") -join ''
            $out | Should -Match '5h:'
        }
    }

    Context "no rate limits" {
        It "no rl section when rate_limits absent" {
            $json = @{ context_window = @{ used_percentage = 10 }; cwd = $env:TEMP } | ConvertTo-Json
            $out = ($json | pwsh -NoProfile -File "$PSScriptRoot/claude-statusline.ps1") -join ''
            $out | Should -Not -Match '5h:|7d:'
        }
    }
}
