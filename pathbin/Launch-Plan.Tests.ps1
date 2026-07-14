BeforeDiscovery {
    . "$PSScriptRoot/Launch-Plan.ps1"
}

BeforeAll {
    . "$PSScriptRoot/Launch-Plan.ps1"
}

Describe "loadDb" {
    It "returns empty array when file doesn't exist" {
        @(loadDb "TestDrive:\nonexistent.json") | Should -HaveCount 0
    }

    It "returns entries with correct fields, ignoring a legacy state field" {
        $json = '[{"planFile":"C:/plans/foo.md","state":"ready","cwd":"C:/de","sessionIds":["abc"]}]'
        Set-Content "TestDrive:\db-load1.json" $json

        $result = loadDb "TestDrive:\db-load1.json"

        @($result)               | Should -HaveCount 1
        $result[0].planFile      | Should -Be "C:/plans/foo.md"
        $result[0].cwd           | Should -Be "C:/de"
        @($result[0].sessionIds) | Should -Be @("abc")
        $result[0].PSObject.Properties['state'] | Should -BeNull
    }

    It "returns empty sessionIds array when field is absent" {
        Set-Content "TestDrive:\db-load2.json" '[{"planFile":"p.md","state":"discussing","cwd":"C:/de"}]'

        $result = loadDb "TestDrive:\db-load2.json"

        @($result[0].sessionIds) | Should -HaveCount 0
    }

    It "skips entries with null planFile" {
        Set-Content "TestDrive:\db-load-null.json" '[{"planFile":null,"state":null,"cwd":null,"sessionIds":[]}]'

        $result = @(loadDb "TestDrive:\db-load-null.json")

        $result | Should -HaveCount 0
    }

    It "returns empty array when file contains null" {
        Set-Content "TestDrive:\db-load-nullfile.json" 'null'

        $result = @(loadDb "TestDrive:\db-load-nullfile.json")

        $result | Should -HaveCount 0
    }
}

Describe "saveDb / loadDb round-trip" {
    It "preserves all fields including multiple sessionIds" {
        $entries = @([pscustomobject]@{
            planFile   = "C:/plans/bar.md"
            cwd        = "C:/de"
            sessionIds = @("sid1", "sid2")
        })

        saveDb $entries "TestDrive:\rt.json"
        $result = loadDb "TestDrive:\rt.json"

        @($result)                 | Should -HaveCount 1
        $result[0].planFile        | Should -Be "C:/plans/bar.md"
        @($result[0].sessionIds)   | Should -Be @("sid1", "sid2")
    }

    It "does not persist a computed state property" {
        $entries = @([pscustomobject]@{planFile = "C:/plans/bar.md"; cwd = "C:/de"; sessionIds = @(); state = "ready-to-plan"})

        saveDb $entries "TestDrive:\rt-nostate.json"

        (Get-Content "TestDrive:\rt-nostate.json" -Raw) | Should -Not -Match 'state'
    }

    It "round-trips a List with entries" {
        $db = [System.Collections.Generic.List[object]]::new()
        $db.Add([pscustomobject]@{planFile = "C:/plans/foo.md"; cwd = "C:/de"; sessionIds = @()})

        saveDb $db "TestDrive:\rt-list.json"
        $result = loadDb "TestDrive:\rt-list.json"

        @($result)           | Should -HaveCount 1
        $result[0].planFile  | Should -Be "C:/plans/foo.md"
    }

    It "round-trips an empty db as an empty array" {
        $db = [System.Collections.Generic.List[object]]::new()

        saveDb $db "TestDrive:\rt-empty.json"
        $result = @(loadDb "TestDrive:\rt-empty.json")

        $result | Should -HaveCount 0
    }
}

Describe "loadLauncherDb" {
    It "drops entries whose planFile no longer exists" {
        $plansDir = ((New-Item -ItemType Directory "TestDrive:\plans-stale").FullName -replace '\\', '/').TrimEnd('/')
        Set-Content "$plansDir/alive.md" '# alive'
        @(
            @{planFile = "$plansDir/alive.md"; cwd = "C:/de"; sessionIds = @()}
            @{planFile = "$plansDir/deleted.md"; cwd = "C:/de"; sessionIds = @("sid-1")}
        ) | ConvertTo-Json | Set-Content "TestDrive:\db-stale.json"

        $db = loadLauncherDb "TestDrive:\db-stale.json"

        @($db.planFile) | Should -Be @("$plansDir/alive.md")
    }

    It "keeps an entry whose planFile contains glob characters" {
        $plansDir = ((New-Item -ItemType Directory "TestDrive:\plans-glob").FullName -replace '\\', '/').TrimEnd('/')
        Set-Content -LiteralPath "$plansDir/plan[1].md" '# glob'
        @(@{planFile = "$plansDir/plan[1].md"; cwd = "C:/de"; sessionIds = @()}) |
            ConvertTo-Json -AsArray | Set-Content "TestDrive:\db-glob.json"

        $db = loadLauncherDb "TestDrive:\db-glob.json"

        @($db.planFile) | Should -Be @("$plansDir/plan[1].md")
    }
}

Describe "attachPlanStates" {
    It "attaches frontmatter state; a plan without frontmatter gets null" {
        $plansDir = ((New-Item -ItemType Directory "TestDrive:\plans-attach").FullName -replace '\\', '/').TrimEnd('/')
        Set-Content "$plansDir/with.md" @('# t', '', '## Step 1: x')
        Set-Content "$plansDir/without.md" '# t'
        $null = Set-PlanState -PlanFile "$plansDir/with.md" -State 'code-complete'
        $db = @(
            [pscustomobject]@{planFile = "$plansDir/with.md"; cwd = "C:/de"; sessionIds = @()}
            [pscustomobject]@{planFile = "$plansDir/without.md"; cwd = "C:/de"; sessionIds = @()}
        )

        attachPlanStates $db

        $db[0].state | Should -Be 'code-complete'
        $db[1].state | Should -BeNullOrEmpty
    }
}

Describe "indexOfPlan" {
    BeforeAll {
        $script:idxDb = @(
            [pscustomobject]@{planFile = "C:/plans/a.md"; cwd = "C:/de"; sessionIds = @()}
            [pscustomobject]@{planFile = "C:/plans/b.md"; cwd = "C:/de"; sessionIds = @()}
        )
    }

    It "returns the index of the matching planFile" {
        indexOfPlan $script:idxDb "C:/plans/b.md" | Should -Be 1
    }

    It "returns 0 when the planFile is not in the list" {
        indexOfPlan $script:idxDb "C:/plans/gone.md" | Should -Be 0
    }

    It "returns 0 for a null planFile" {
        indexOfPlan $script:idxDb $null | Should -Be 0
    }
}

Describe "resolveSessionIds" {
    It "leaves db unchanged when running dir doesn't exist" {
        $db = @([pscustomobject]@{planFile = "f.md"; state = "discussing"; cwd = "C:/de"; sessionIds = @()})

        resolveSessionIds $db "TestDrive:\norunning" @()

        @($db[0].sessionIds) | Should -HaveCount 0
    }

    It "treats a cwd-matching untracked session as an orphan (no cwd fallback)" {
        $rDir = "TestDrive:\running-match"
        $null = New-Item -ItemType Directory $rDir
        '{"session_id":"abc-123","cwd":"C:/de"}' | Set-Content "$rDir\pid_99.txt"
        $db = @([pscustomobject]@{planFile = "f.md"; cwd = "C:/de"; sessionIds = @()})

        $result = resolveSessionIds $db $rDir @(99)

        @($db[0].sessionIds)   | Should -HaveCount 0
        $result.orphans        | Should -Contain "abc-123"
        $result.liveSessionIds | Should -Contain "abc-123"
    }

    It "doesn't duplicate an already-present session_id" {
        $rDir = "TestDrive:\running-nodup"
        $null = New-Item -ItemType Directory $rDir
        '{"session_id":"abc-123","cwd":"C:/de"}' | Set-Content "$rDir\pid_99.txt"
        $db = @([pscustomobject]@{planFile = "f.md"; state = "discussing"; cwd = "C:/de"; sessionIds = @("abc-123")})

        resolveSessionIds $db $rDir @(99)

        @($db[0].sessionIds) | Should -HaveCount 1
    }

    It "does not cwd-match an untracked session even when only one entry shares the cwd" {
        $rDir = "TestDrive:\running-unoccupied"
        $null = New-Item -ItemType Directory $rDir
        '{"session_id":"live-sid","cwd":"C:/de"}' | Set-Content "$rDir\pid_99.txt"
        '{"session_id":"new-sid","cwd":"C:/de"}'  | Set-Content "$rDir\pid_100.txt"
        $entry1 = [pscustomobject]@{planFile = "f1.md"; cwd = "C:/de"; sessionIds = @("live-sid")}
        $entry2 = [pscustomobject]@{planFile = "f2.md"; cwd = "C:/de"; sessionIds = @()}
        $db = @($entry1, $entry2)

        $result = resolveSessionIds $db $rDir @(99, 100)

        @($entry1.sessionIds) | Should -HaveCount 1     # live-sid not duplicated
        @($entry2.sessionIds) | Should -HaveCount 0
        $result.orphans       | Should -Contain "new-sid"
    }

    It "treats session as orphan when cwd matches multiple entries" {
        $rDir = "TestDrive:\running-ambig"
        $null = New-Item -ItemType Directory $rDir
        '{"session_id":"new-sid","cwd":"C:/de"}' | Set-Content "$rDir\pid_99.txt"
        $entry1 = [pscustomobject]@{planFile = "f1.md"; state = "discussing"; cwd = "C:/de"; sessionIds = @()}
        $entry2 = [pscustomobject]@{planFile = "f2.md"; state = "discussing"; cwd = "C:/de"; sessionIds = @()}
        $db = @($entry1, $entry2)

        $result = resolveSessionIds $db $rDir @(99)

        @($entry1.sessionIds) | Should -HaveCount 0
        @($entry2.sessionIds) | Should -HaveCount 0
        $result.orphans        | Should -Contain "new-sid"
    }

    It "matches session by planFile even when cwd matches multiple entries" {
        $rDir = "TestDrive:\running-planfile-ambig"
        $null = New-Item -ItemType Directory $rDir
        '{"session_id":"new-sid","cwd":"C:/de","planFile":"f1.md"}' | Set-Content "$rDir\pid_99.txt"
        $entry1 = [pscustomobject]@{planFile = "f1.md"; state = "discussing"; cwd = "C:/de"; sessionIds = @()}
        $entry2 = [pscustomobject]@{planFile = "f2.md"; state = "discussing"; cwd = "C:/de"; sessionIds = @()}
        $db = @($entry1, $entry2)

        $result = resolveSessionIds $db $rDir @(99)

        $entry1.sessionIds    | Should -Contain "new-sid"
        @($entry2.sessionIds) | Should -HaveCount 0
        $result.orphans       | Should -Not -Contain "new-sid"
        $result.liveSessionIds | Should -Contain "new-sid"
    }

    It "treats session as orphan when planFile doesn't match any db entry" {
        $rDir = "TestDrive:\running-planfile-miss"
        $null = New-Item -ItemType Directory $rDir
        '{"session_id":"new-sid","cwd":"C:/de","planFile":"unknown.md"}' | Set-Content "$rDir\pid_99.txt"
        $entry = [pscustomobject]@{planFile = "f1.md"; cwd = "C:/de"; sessionIds = @()}
        $db = @($entry)

        $result = resolveSessionIds $db $rDir @(99)

        @($entry.sessionIds) | Should -HaveCount 0
        $result.orphans      | Should -Contain "new-sid"
    }

    It "doesn't add session_id when cwd doesn't match" {
        $rDir = "TestDrive:\running-nomatch"
        $null = New-Item -ItemType Directory $rDir
        '{"session_id":"abc-123","cwd":"C:/de"}' | Set-Content "$rDir\pid_99.txt"
        $db = @([pscustomobject]@{planFile = "f.md"; state = "discussing"; cwd = "C:/other"; sessionIds = @()})

        resolveSessionIds $db $rDir @()

        @($db[0].sessionIds) | Should -HaveCount 0
    }

    It "ignores pid file whose pid is not live" {
        $rDir = "TestDrive:\running-stalePid"
        $null = New-Item -ItemType Directory $rDir
        '{"session_id":"stale-sid","cwd":"C:/de"}' | Set-Content "$rDir\pid_99.txt"
        $db = @([pscustomobject]@{planFile = "f.md"; state = "discussing"; cwd = "C:/de"; sessionIds = @()})

        resolveSessionIds $db $rDir @(42)   # pid 99 not in live list

        @($db[0].sessionIds) | Should -HaveCount 0
    }

    It "processes only live pid files" {
        $rDir = "TestDrive:\running-livePid"
        $null = New-Item -ItemType Directory $rDir
        '{"session_id":"live-sid","cwd":"C:/de","planFile":"f.md"}' | Set-Content "$rDir\pid_99.txt"
        '{"session_id":"dead-sid","cwd":"C:/de","planFile":"f.md"}' | Set-Content "$rDir\pid_77.txt"
        $db = @([pscustomobject]@{planFile = "f.md"; cwd = "C:/de"; sessionIds = @()})

        $result = resolveSessionIds $db $rDir @(99)   # only pid 99 is live

        $db[0].sessionIds      | Should -Contain "live-sid"
        $db[0].sessionIds      | Should -Not -Contain "dead-sid"
        $result.liveSessionIds | Should -Not -Contain "dead-sid"
    }

    It "returns orphan session_id in result" {
        $rDir = "TestDrive:\running-orphan"
        $null = New-Item -ItemType Directory $rDir
        '{"session_id":"orphan-sid","cwd":"C:/untracked"}' | Set-Content "$rDir\pid_99.txt"
        $db = @([pscustomobject]@{planFile = "f.md"; state = "discussing"; cwd = "C:/de"; sessionIds = @()})

        $result = resolveSessionIds $db $rDir @(99)

        $result.orphans | Should -Contain "orphan-sid"
    }

    It "does not flag a notice when session_id is already correctly linked by ID" {
        $rDir = "TestDrive:\running-conflict"
        $null = New-Item -ItemType Directory $rDir
        # pid file cwd matches entry2, but session is already recorded under entry1 by ID
        '{"session_id":"conflict-sid","cwd":"C:/other"}' | Set-Content "$rDir\pid_99.txt"
        $entry1 = [pscustomobject]@{planFile = "f1.md"; state = "discussing"; cwd = "C:/de"; sessionIds = @("conflict-sid")}
        $entry2 = [pscustomobject]@{planFile = "f2.md"; state = "discussing"; cwd = "C:/other"; sessionIds = @()}
        $db = @($entry1, $entry2)

        $result = resolveSessionIds $db $rDir @(99)
        $result.notices | Should -BeNullOrEmpty
    }

    It "returns liveSessionIds set" {
        $rDir = "TestDrive:\running-liveSet"
        $null = New-Item -ItemType Directory $rDir
        '{"session_id":"live-sid","cwd":"C:/de"}' | Set-Content "$rDir\pid_99.txt"
        $db = @([pscustomobject]@{planFile = "f.md"; state = "discussing"; cwd = "C:/de"; sessionIds = @()})

        $result = resolveSessionIds $db $rDir @(99)

        $result.liveSessionIds | Should -Contain "live-sid"
    }
}

Describe "isLive" {
    It "returns true when entry has a session_id in the live set" {
        $entry = [pscustomobject]@{sessionIds = @("abc-123")}
        isLive $entry @("abc-123", "other-sid") | Should -BeTrue
    }

    It "returns false when entry has no session_ids in the live set" {
        $entry = [pscustomobject]@{sessionIds = @("abc-123")}
        isLive $entry @("other-sid") | Should -BeFalse
    }

    It "returns false when entry has no session_ids" {
        $entry = [pscustomobject]@{sessionIds = @()}
        isLive $entry @("abc-123") | Should -BeFalse
    }

    It "returns false when live set is empty" {
        $entry = [pscustomobject]@{sessionIds = @("abc-123")}
        isLive $entry @() | Should -BeFalse
    }
}

Describe "getLiveClaudePids" {
    It "returns an empty array when no claude process is found" {
        Mock Get-Process { }

        $result = getLiveClaudePids

        $result -is [array] | Should -BeTrue
        $result.Count       | Should -Be 0
    }

    It "returns the PID of each running claude process" {
        Mock Get-Process { [pscustomobject]@{Id = 1234}; [pscustomobject]@{Id = 5678} }

        $result = getLiveClaudePids

        $result | Should -HaveCount 2
        $result | Should -Contain 1234
        $result | Should -Contain 5678
    }
}

Describe "cleanStaleRunningFiles" {
    It "removes pid files whose pids are not live" {
        $rDir = "TestDrive:\clean-stale"
        $null = New-Item -ItemType Directory $rDir
        Set-Content "$rDir\pid_99.txt" '{"session_id":"s1","cwd":"C:/de"}'

        cleanStaleRunningFiles $rDir @(42)   # pid 99 not live

        Test-Path "$rDir\pid_99.txt" | Should -BeFalse
    }

    It "keeps pid files whose pids are live" {
        $rDir = "TestDrive:\clean-keep"
        $null = New-Item -ItemType Directory $rDir
        Set-Content "$rDir\pid_99.txt" '{"session_id":"s1","cwd":"C:/de"}'

        cleanStaleRunningFiles $rDir @(99)

        Test-Path "$rDir\pid_99.txt" | Should -BeTrue
    }

    It "does nothing when running dir doesn't exist" {
        { cleanStaleRunningFiles "TestDrive:\clean-nodir" @() } | Should -Not -Throw
    }
}

Describe "updatePresenceFile" {
    It "writes a presence file with current machine's plan files" {
        $syncDir = "TestDrive:\presence-write"
        $null = New-Item -ItemType Directory $syncDir
        $db = @([pscustomobject]@{planFile = "C:/plans/mine.md"; state = "ready"; cwd = "C:/de"; sessionIds = @()})

        updatePresenceFile $db $syncDir

        $ownFile = "$syncDir/.plan-tracking/$env:COMPUTERNAME.json"
        Test-Path $ownFile           | Should -BeTrue
        $data = Get-Content $ownFile -Raw | ConvertFrom-Json
        $data.plans                  | Should -Contain "C:/plans/mine.md"
        $data.machine                | Should -Be $env:COMPUTERNAME
    }
}

Describe "getCrossMachineFlags" {
    It "returns empty when syncPath is null" {
        getCrossMachineFlags $null | Should -HaveCount 0
    }

    It "flags a plan that appears on another machine" {
        $syncDir = "TestDrive:\cross-flags1"
        $null = New-Item -ItemType Directory "$syncDir/.plan-tracking" -Force
        @{machine = "other-pc"; plans = @("C:/plans/foo.md")} | ConvertTo-Json |
            Set-Content "$syncDir/.plan-tracking/other-pc.json"

        $flags = getCrossMachineFlags $syncDir

        $flags | Should -Contain "C:/plans/foo.md"
    }

    It "doesn't flag a plan not present on any other machine" {
        $syncDir = "TestDrive:\cross-flags2"
        $null = New-Item -ItemType Directory "$syncDir/.plan-tracking" -Force
        @{machine = "other-pc"; plans = @("C:/plans/something-else.md")} | ConvertTo-Json |
            Set-Content "$syncDir/.plan-tracking/other-pc.json"

        $flags = getCrossMachineFlags $syncDir

        $flags | Should -Not -Contain "C:/plans/not-there.md"
    }

    It "does not read own machine file as cross-machine" {
        $syncDir = "TestDrive:\cross-flags3"
        $null = New-Item -ItemType Directory "$syncDir/.plan-tracking" -Force
        # Write a presence file named after THIS machine
        @{machine = $env:COMPUTERNAME; plans = @("C:/plans/own.md")} | ConvertTo-Json |
            Set-Content "$syncDir/.plan-tracking/$env:COMPUTERNAME.json"

        $flags = getCrossMachineFlags $syncDir

        $flags | Should -Not -Contain "C:/plans/own.md"
    }

    It "ignores entries whose lastSeen is older than 7 days" {
        $syncDir = "TestDrive:\cross-stale"
        $null = New-Item -ItemType Directory "$syncDir/.plan-tracking" -Force
        @{machine = "other-pc"; plans = @("C:/plans/stale.md"); lastSeen = (Get-Date).AddDays(-8).ToString('o')} |
            ConvertTo-Json | Set-Content "$syncDir/.plan-tracking/other-pc.json"

        $flags = getCrossMachineFlags $syncDir

        $flags | Should -Not -Contain "C:/plans/stale.md"
    }

    It "includes entries whose lastSeen is within 7 days" {
        $syncDir = "TestDrive:\cross-recent"
        $null = New-Item -ItemType Directory "$syncDir/.plan-tracking" -Force
        @{machine = "other-pc"; plans = @("C:/plans/recent.md"); lastSeen = (Get-Date).AddDays(-1).ToString('o')} |
            ConvertTo-Json | Set-Content "$syncDir/.plan-tracking/other-pc.json"

        $flags = getCrossMachineFlags $syncDir

        $flags | Should -Contain "C:/plans/recent.md"
    }
}

Describe "checkSyncPath" {
    It "returns path when it exists" {
        $dir = "TestDrive:\sync-exists"
        $null = New-Item -ItemType Directory $dir

        $result = checkSyncPath (Resolve-Path $dir).Path

        $result.path   | Should -Not -BeNullOrEmpty
        $result.notice | Should -BeNullOrEmpty
    }

    It "returns null path and notice when path does not exist" {
        $result = checkSyncPath "TestDrive:\sync-missing"

        $result.path   | Should -BeNull
        $result.notice | Should -Not -BeNullOrEmpty
    }

    It "returns null path and no notice when path is null" {
        $result = checkSyncPath $null

        $result.path   | Should -BeNull
        $result.notice | Should -BeNullOrEmpty
    }
}

Describe "openProject" {
    BeforeAll {
        $script:plansRoot = ((New-Item -ItemType Directory "TestDrive:\plans-open").FullName -replace '\\', '/').TrimEnd('/')

        # Creates a plan file with one step heading; $state $null leaves it without frontmatter.
        function newPlan([string] $name, [string] $state) {
            $path = "$script:plansRoot/$name.md"
            Set-Content $path @("# $name", "", "## Step 1: first")
            if ($state) { $null = Set-PlanState -PlanFile $path -State $state }
            return $path
        }

        function newDb($entry) {
            $db = [System.Collections.Generic.List[object]]::new()
            $db.Add($entry)
            return ,$db
        }

        function newEntry([string] $planFile, [string[]] $sessionIds = @()) {
            return [pscustomobject]@{planFile = $planFile; cwd = "C:/de"; sessionIds = $sessionIds}
        }

        function newInfo([string] $sid, [datetime] $lastActive) {
            return [pscustomobject]@{sid = $sid; lastActive = $lastActive; summary = "summary of $sid"}
        }
    }

    BeforeEach {
        Mock saveDb { }
        Mock Write-Host { }
        Mock clearConsole { }
        Mock Read-Host { "" }
        Mock getSessionInfos { @() }
        Mock pickFromList { }
        $script:launched = $null
        Mock launchCl { $script:launched = @{cwd = $cwd; planFile = $planFile; rest = @($args)}; return 0 }
    }

    It "live entry: does not launch, returns false" {
        $entry = newEntry (newPlan 'live' 'ready-to-implement') @("live-sid")
        $db    = newDb $entry

        $result = openProject $db $entry @("live-sid")

        $result | Should -BeFalse
        Should -Invoke launchCl -Times 0
    }

    It "ready-to-implement + no sessions: fresh launch with do-the-next-step prompt" {
        $plan  = newPlan 'rti' 'ready-to-implement'
        $entry = newEntry $plan
        $db    = newDb $entry

        $result = openProject $db $entry @()

        $result                   | Should -BeTrue
        $script:launched.planFile | Should -Be $plan
        $script:launched.rest[0]  | Should -Be "Please do the next step in $plan"
    }

    It "ready-to-plan + no sessions: fresh launch with plan-the-next-step prompt" {
        $plan  = newPlan 'rtp' 'ready-to-plan'
        $entry = newEntry $plan
        $db    = newDb $entry

        openProject $db $entry @()

        $script:launched.rest[0] | Should -Be "Please plan the next step in $plan"
    }

    It "code-complete + no sessions: fresh launch with review prompt" {
        $plan  = newPlan 'cc' 'code-complete'
        $entry = newEntry $plan
        $db    = newDb $entry

        openProject $db $entry @()

        $script:launched.rest[0] | Should -Match 'code-complete'
        $script:launched.rest[0] | Should -Match 'review'
    }

    It "no frontmatter: treated as ready-to-plan" {
        $plan  = newPlan 'bare' $null
        $entry = newEntry $plan
        $db    = newDb $entry

        openProject $db $entry @()

        $script:launched.rest[0] | Should -Be "Please plan the next step in $plan"
    }

    It "fresh launch: updates cwd and saves db" {
        $entry = newEntry (newPlan 'cwd' 'ready-to-implement')
        $entry.cwd = "C:/old"
        $db    = newDb $entry

        openProject $db $entry @()

        $entry.cwd | Should -Be (normalizePath $PWD.Path)
        Should -Invoke saveDb -Times 1
    }

    It "checkpointed: flips file state to ready-to-implement, launches fresh, keeps old sessions" {
        $plan  = newPlan 'ckpt' 'checkpointed'
        $entry = newEntry $plan @("old-sid")
        $db    = newDb $entry
        Mock getSessionInfos { @(newInfo 'old-sid' (Get-Date)) }

        $result = openProject $db $entry @()

        $result                               | Should -BeTrue
        (Get-PlanState -PlanFile $plan).State | Should -Be 'ready-to-implement'
        $script:launched.rest[0]              | Should -Be "Please do the next step in $plan"
        @($entry.sessionIds)                  | Should -Be @("old-sid")
    }

    It "one resumable session: resumes it directly without a picker" {
        $plan  = newPlan 'res1' 'ready-to-implement'
        $entry = newEntry $plan @("sid-1")
        $db    = newDb $entry
        Mock getSessionInfos { @(newInfo 'sid-1' (Get-Date)) }
        Mock pickFromList { throw 'picker should not be shown for a single session' }

        $result = openProject $db $entry @()

        $result               | Should -BeTrue
        $script:launched.rest | Should -Contain "--resume"
        $script:launched.rest | Should -Contain "sid-1"
        @($entry.sessionIds)  | Should -Be @("sid-1")    # not clobbered
    }

    It "resumes for ready-to-plan and code-complete too when sessions exist" -TestCases @(
        @{ State = 'ready-to-plan' }
        @{ State = 'code-complete' }
    ) {
        param($State)
        $plan  = newPlan "res-$State" $State
        $entry = newEntry $plan @("sid-1")
        $db    = newDb $entry
        Mock getSessionInfos { @(newInfo 'sid-1' (Get-Date)) }

        openProject $db $entry @()

        $script:launched.rest | Should -Contain "--resume"
    }

    It "multiple sessions: picker shows at most the 3 most recent; picked one is resumed" {
        $plan  = newPlan 'res-multi' 'ready-to-implement'
        $entry = newEntry $plan @("sid-1", "sid-2", "sid-3", "sid-4")
        $db    = newDb $entry
        Mock getSessionInfos { @(
            newInfo 'sid-1' (Get-Date '2026-06-04')
            newInfo 'sid-2' (Get-Date '2026-06-03')
            newInfo 'sid-3' (Get-Date '2026-06-02')
            newInfo 'sid-4' (Get-Date '2026-06-01')
        ) }
        $script:pickerItems = $null
        Mock pickFromList { $script:pickerItems = $items; return 1 }

        openProject $db $entry @()

        @($script:pickerItems).sid | Should -Be @("sid-1", "sid-2", "sid-3")
        $script:launched.rest      | Should -Contain "sid-2"
        @($entry.sessionIds)       | Should -HaveCount 4    # not clobbered
    }

    It "picker canceled: returns false without launching" {
        $plan  = newPlan 'res-cancel' 'ready-to-implement'
        $entry = newEntry $plan @("sid-1", "sid-2")
        $db    = newDb $entry
        Mock getSessionInfos { @((newInfo 'sid-1' (Get-Date)), (newInfo 'sid-2' (Get-Date))) }
        Mock pickFromList { return $null }

        $result = openProject $db $entry @()

        $result | Should -BeFalse
        Should -Invoke launchCl -Times 0
    }

    It "sessions in db but none resumable (no jsonl): falls back to fresh launch" {
        $plan  = newPlan 'res-gone' 'ready-to-implement'
        $entry = newEntry $plan @("gone-sid")
        $db    = newDb $entry

        openProject $db $entry @()

        $script:launched.rest[0] | Should -Be "Please do the next step in $plan"
    }

    It "failed resume: removes only the failed sid, keeps the rest, returns true" {
        $plan  = newPlan 'res-fail' 'ready-to-implement'
        $entry = newEntry $plan @("sid-1", "sid-2")
        $db    = newDb $entry
        Mock getSessionInfos { @(newInfo 'sid-1' (Get-Date)) }
        Mock launchCl { return 1 }

        $result = openProject $db $entry @()

        $result              | Should -BeTrue
        @($entry.sessionIds) | Should -Be @("sid-2")
        Should -Invoke saveDb -Times 1
    }

    It "fresh launch failure still returns true (TUI refreshes)" {
        $entry = newEntry (newPlan 'fresh-fail' 'ready-to-implement')
        $db    = newDb $entry
        Mock launchCl { return 1 }

        $result = openProject $db $entry @()

        $result | Should -BeTrue
    }
}

Describe "getLaunchAction" {
    It "ready-to-plan, no sessions: fresh plan prompt" {
        $a = getLaunchAction 'ready-to-plan' $false 'C:/p/x.md'

        $a.kind     | Should -Be 'fresh'
        $a.prompt   | Should -Be 'Please plan the next step in C:/p/x.md'
        $a.setState | Should -BeNullOrEmpty
    }

    It "ready-to-implement, no sessions: fresh implement prompt" {
        $a = getLaunchAction 'ready-to-implement' $false 'C:/p/x.md'

        $a.kind   | Should -Be 'fresh'
        $a.prompt | Should -Be 'Please do the next step in C:/p/x.md'
    }

    It "code-complete, no sessions: fresh review prompt" {
        $a = getLaunchAction 'code-complete' $false 'C:/p/x.md'

        $a.kind   | Should -Be 'fresh'
        $a.prompt | Should -Match 'code-complete'
        $a.prompt | Should -Match 'review'
    }

    It "missing or unknown state: treated as ready-to-plan" -TestCases @(
        @{ State = $null }
        @{ State = 'discussing' }
    ) {
        param($State)
        (getLaunchAction $State $false 'C:/p/x.md').prompt | Should -Match 'plan the next step'
    }

    It "sessions present: resume, for each stored state except checkpointed" -TestCases @(
        @{ State = 'ready-to-plan' }
        @{ State = 'ready-to-implement' }
        @{ State = 'code-complete' }
    ) {
        param($State)
        (getLaunchAction $State $true 'C:/p/x.md').kind | Should -Be 'resume'
    }

    It "checkpointed: fresh implement launch + state flip, even with sessions" {
        $a = getLaunchAction 'checkpointed' $true 'C:/p/x.md'

        $a.kind     | Should -Be 'fresh'
        $a.prompt   | Should -Be 'Please do the next step in C:/p/x.md'
        $a.setState | Should -Be 'ready-to-implement'
    }
}

Describe "getSessionInfos" {
    BeforeAll {
        $script:projRoot = ((New-Item -ItemType Directory "TestDrive:\cc-projects").FullName -replace '\\', '/').TrimEnd('/')
        $null = New-Item -ItemType Directory "$script:projRoot/proj-a"
        $null = New-Item -ItemType Directory "$script:projRoot/proj-b"
        Set-Content "$script:projRoot/proj-a/sid-old.jsonl" '{}'
        Set-Content "$script:projRoot/proj-a/sid-new.jsonl" '{}'
        Set-Content "$script:projRoot/proj-a/sid-longfp.jsonl" '{}'
        Set-Content "$script:projRoot/proj-b/sid-other.jsonl" '{}'
        (Get-Item "$script:projRoot/proj-a/sid-old.jsonl").LastWriteTime    = Get-Date '2026-01-01'
        (Get-Item "$script:projRoot/proj-a/sid-new.jsonl").LastWriteTime    = Get-Date '2026-06-01'
        (Get-Item "$script:projRoot/proj-a/sid-longfp.jsonl").LastWriteTime = Get-Date '2025-12-01'
        (Get-Item "$script:projRoot/proj-b/sid-other.jsonl").LastWriteTime  = Get-Date '2026-03-01'
        @{version = 1; entries = @(
            @{sessionId = 'sid-new'; summary = 'Newest session'; firstPrompt = 'fp-new'}
            @{sessionId = 'sid-old'; firstPrompt = 'old first prompt'}
            @{sessionId = 'sid-longfp'; firstPrompt = ('x' * 100)}
        )} | ConvertTo-Json -Depth 5 | Set-Content "$script:projRoot/proj-a/sessions-index.json"
    }

    It "sorts most-recent-first by jsonl mtime, across project dirs" {
        $infos = @(getSessionInfos @('sid-old', 'sid-other', 'sid-new') $script:projRoot)

        @($infos.sid) | Should -Be @('sid-new', 'sid-other', 'sid-old')
    }

    It "excludes sids with no jsonl anywhere" {
        $infos = @(getSessionInfos @('sid-new', 'sid-missing') $script:projRoot)

        @($infos.sid) | Should -Be @('sid-new')
    }

    It "returns empty for an empty sid list" {
        @(getSessionInfos @() $script:projRoot) | Should -HaveCount 0
    }

    It "uses the index summary when present" {
        $infos = @(getSessionInfos @('sid-new') $script:projRoot)

        $infos[0].summary | Should -Be 'Newest session'
    }

    It "falls back to firstPrompt when the index entry has no summary" {
        $infos = @(getSessionInfos @('sid-old') $script:projRoot)

        $infos[0].summary | Should -Be 'old first prompt'
    }

    It "truncates a long firstPrompt to 60 chars" {
        $infos = @(getSessionInfos @('sid-longfp') $script:projRoot)

        $infos[0].summary.Length | Should -Be 60
        $infos[0].summary        | Should -Match '\.\.\.$'
    }

    It "falls back to the sid when the project dir has no index" {
        $infos = @(getSessionInfos @('sid-other') $script:projRoot)

        $infos[0].summary | Should -Be 'sid-other'
    }

    It "exposes the jsonl mtime as lastActive" {
        $infos = @(getSessionInfos @('sid-new') $script:projRoot)

        $infos[0].lastActive | Should -Be (Get-Date '2026-06-01')
    }
}

Describe "registerProject" {
    BeforeEach {
        Mock saveDb { }
        Mock Write-Host { }
        Mock Read-Host { "" }
    }

    It "does nothing when no orphans" {
        $db    = [System.Collections.Generic.List[object]]::new()
        $entry = [pscustomobject]@{planFile = "C:/plans/foo.md"; state = "discussing"; cwd = "C:/de"; sessionIds = @()}
        $db.Add($entry)
        $orphans = [System.Collections.Generic.List[string]]::new()
        $live    = [System.Collections.Generic.HashSet[string]]::new()

        registerProject $db $orphans $live

        @($entry.sessionIds) | Should -HaveCount 0
        Should -Invoke saveDb -Times 0
    }

    It "shows no-plans message when db is empty and no plans dir configured" {
        $db      = [System.Collections.Generic.List[object]]::new()
        $orphans = [System.Collections.Generic.List[string]]::new()
        $orphans.Add("sid-x")
        $live    = [System.Collections.Generic.HashSet[string]]::new()
        Mock getPlansDir { return $null }
        Mock pickFromList { return 0 }   # picks session; plan list will be empty

        registerProject $db $orphans $live

        Should -Invoke saveDb -Times 0
    }

    It "links session to plan, updates live set, removes from orphans" {
        $db    = [System.Collections.Generic.List[object]]::new()
        $entry = [pscustomobject]@{planFile = "C:/plans/foo.md"; state = "discussing"; cwd = "C:/de"; sessionIds = @()}
        $db.Add($entry)
        $orphans = [System.Collections.Generic.List[string]]::new()
        $orphans.Add("new-sid")
        $live    = [System.Collections.Generic.HashSet[string]]::new()
        Mock pickFromList { return 0 }

        registerProject $db $orphans $live

        $entry.sessionIds      | Should -Contain "new-sid"
        $live                  | Should -Contain "new-sid"
        $orphans               | Should -Not -Contain "new-sid"
        Should -Invoke saveDb -Times 1
    }

    It "creates db entry and links session for untracked plan" {
        $plansDir = "TestDrive:\plans-register"
        $null = New-Item -ItemType Directory $plansDir
        Set-Content "$plansDir\new-plan.md" '# new plan'
        $db      = [System.Collections.Generic.List[object]]::new()
        $orphans = [System.Collections.Generic.List[string]]::new()
        $orphans.Add("new-sid")
        $live    = [System.Collections.Generic.HashSet[string]]::new()
        Mock getPlansDir { return (Resolve-Path "TestDrive:\plans-register").Path }
        Mock pickFromList { return 0 }

        registerProject $db $orphans $live

        $db.Count            | Should -Be 1
        $db[0].sessionIds    | Should -Contain "new-sid"
        $live                | Should -Contain "new-sid"
        $orphans             | Should -Not -Contain "new-sid"
        Should -Invoke saveDb -Times 1
    }

    It "does not duplicate session already in entry" {
        $db    = [System.Collections.Generic.List[object]]::new()
        $entry = [pscustomobject]@{planFile = "C:/plans/foo.md"; state = "discussing"; cwd = "C:/de"; sessionIds = @("new-sid")}
        $db.Add($entry)
        $orphans = [System.Collections.Generic.List[string]]::new()
        $orphans.Add("new-sid")
        $live    = [System.Collections.Generic.HashSet[string]]::new()
        Mock pickFromList { return 0 }

        registerProject $db $orphans $live

        @($entry.sessionIds) | Should -HaveCount 1
    }

    It "does nothing when user cancels session pick" {
        $db    = [System.Collections.Generic.List[object]]::new()
        $entry = [pscustomobject]@{planFile = "C:/plans/foo.md"; state = "discussing"; cwd = "C:/de"; sessionIds = @()}
        $db.Add($entry)
        $orphans = [System.Collections.Generic.List[string]]::new()
        $orphans.Add("new-sid")
        $live    = [System.Collections.Generic.HashSet[string]]::new()
        Mock pickFromList { return $null }

        registerProject $db $orphans $live

        @($entry.sessionIds) | Should -HaveCount 0
        Should -Invoke saveDb -Times 0
    }

    It "does nothing when user cancels plan pick" {
        $db    = [System.Collections.Generic.List[object]]::new()
        $entry = [pscustomobject]@{planFile = "C:/plans/foo.md"; state = "discussing"; cwd = "C:/de"; sessionIds = @()}
        $db.Add($entry)
        $orphans = [System.Collections.Generic.List[string]]::new()
        $orphans.Add("new-sid")
        $live    = [System.Collections.Generic.HashSet[string]]::new()
        $script:pickCallCount = 0
        Mock pickFromList { if ($script:pickCallCount++ -eq 0) { return 0 } else { return $null } }

        registerProject $db $orphans $live

        @($entry.sessionIds) | Should -HaveCount 0
        Should -Invoke saveDb -Times 0
    }
}

Describe "getAvailablePlanFiles" {
    BeforeAll {
        $script:plansDir = (New-Item -ItemType Directory "TestDrive:\plans-avail").FullName
        $null = New-Item -ItemType Directory "$script:plansDir/done"
        $null = New-Item -ItemType Directory "$script:plansDir/sub"
        $null = New-Item -ItemType Directory "$script:plansDir/sub/done"
        Set-Content "$script:plansDir/active.md"             ""
        Set-Content "$script:plansDir/sub/nested.md"         ""
        Set-Content "$script:plansDir/done/archived.md"      ""
        Set-Content "$script:plansDir/foo_done.md"           ""
        Set-Content "$script:plansDir/sub/done/deep.md"      ""
        Set-Content "$script:plansDir/sub/bar_done.md"       ""
        Set-Content "$script:plansDir/foo_ref.md"            ""
        Set-Content "$script:plansDir/foo_background.md"     ""
        Set-Content "$script:plansDir/sub/baz_background.md" ""
    }

    It "returns top-level and nested .md files" {
        $result = getAvailablePlanFiles $script:plansDir
        $names = $result | ForEach-Object { Split-Path $_ -Leaf }
        $names | Should -Contain 'active.md'
        $names | Should -Contain 'nested.md'
    }

    It "excludes files under a done/ folder" {
        $result = getAvailablePlanFiles $script:plansDir
        $names = $result | ForEach-Object { Split-Path $_ -Leaf }
        $names | Should -Not -Contain 'archived.md'
        $names | Should -Not -Contain 'deep.md'
    }

    It "excludes files whose name ends with _done" {
        $result = getAvailablePlanFiles $script:plansDir
        $names = $result | ForEach-Object { Split-Path $_ -Leaf }
        $names | Should -Not -Contain 'foo_done.md'
        $names | Should -Not -Contain 'bar_done.md'
    }

    It "excludes companion files (_ref / _background)" {
        $result = getAvailablePlanFiles $script:plansDir
        $names = $result | ForEach-Object { Split-Path $_ -Leaf }
        $names | Should -Not -Contain 'foo_ref.md'
        $names | Should -Not -Contain 'foo_background.md'
        $names | Should -Not -Contain 'baz_background.md'
    }
}

Describe "getPlanTitle" {
    It "returns title from first heading" {
        Set-Content "TestDrive:\title1.md" "# My Plan Title"
        getPlanTitle (Get-Item "TestDrive:\title1.md").FullName | Should -Be 'My Plan Title'
    }

    It "returns empty string when no heading" {
        Set-Content "TestDrive:\title2.md" "some text"
        getPlanTitle (Get-Item "TestDrive:\title2.md").FullName | Should -Be ''
    }

    It "finds heading not on the first line" {
        Set-Content "TestDrive:\title3.md" @("preamble", "more text", "# Late Heading")
        getPlanTitle (Get-Item "TestDrive:\title3.md").FullName | Should -Be 'Late Heading'
    }

    It "ignores ## subheadings before the first # heading" {
        Set-Content "TestDrive:\title4.md" @("## Sub", "# Real Title")
        getPlanTitle (Get-Item "TestDrive:\title4.md").FullName | Should -Be 'Real Title'
    }

    It "skips a frontmatter block and finds the heading after it" {
        Set-Content "TestDrive:\title5.md" @("---", "state: ready-to-plan", "---", "# Real Title")
        getPlanTitle (Get-Item "TestDrive:\title5.md").FullName | Should -Be 'Real Title'
    }

    It "finds the heading even when a long frontmatter block pushes it past line 10" {
        $fm = @('---') + (1..10 | ForEach-Object { "refined-entry-${_}: true" }) + @('---', '# Late Real Title')
        Set-Content "TestDrive:\title6.md" $fm
        getPlanTitle (Get-Item "TestDrive:\title6.md").FullName | Should -Be 'Late Real Title'
    }
}

Describe "openUntracked" {
    BeforeAll {
        $script:untrackedRoot = ((New-Item -ItemType Directory "TestDrive:\plans-untracked").FullName -replace '\\', '/').TrimEnd('/')

        function newUntrackedPlan([string] $name, [string] $state) {
            $path = "$script:untrackedRoot/$name.md"
            Set-Content $path @("# $name", "", "## Step 1: first")
            if ($state) { $null = Set-PlanState -PlanFile $path -State $state }
            return $path
        }
    }

    BeforeEach {
        Mock saveDb { }
        Mock Write-Host { }
        Mock Read-Host { "" }
        Mock clearConsole { }
        Mock getPlansDir { return $script:untrackedRoot }
        Mock getSessionInfos { @() }
        Mock pickFromList { return 0 }
        $script:launched = $null
        Mock launchCl { $script:launched = @{cwd = $cwd; planFile = $planFile; rest = @($args)}; return 0 }
    }

    It "returns false when no plans directory configured" {
        $db = [System.Collections.Generic.List[object]]::new()
        Mock getPlansDir { return $null }

        $result = openUntracked $db

        $result | Should -BeFalse
        Should -Invoke launchCl -Times 0
    }

    It "returns false when no untracked plans remain" {
        $plan  = newUntrackedPlan 'only' $null
        Mock getAvailablePlanFiles { return @($plan) }
        $db    = [System.Collections.Generic.List[object]]::new()
        $db.Add([pscustomobject]@{planFile = $plan; cwd = "C:/de"; sessionIds = @()})

        $result = openUntracked $db

        $result | Should -BeFalse
        Should -Invoke launchCl -Times 0
    }

    It "returns false when user cancels plan selection" {
        Mock getAvailablePlanFiles { return @(newUntrackedPlan 'cancel' $null) }
        $db = [System.Collections.Generic.List[object]]::new()
        Mock pickFromList { return $null }

        $result = openUntracked $db

        $result | Should -BeFalse
        Should -Invoke launchCl -Times 0
    }

    It "does not prompt for an initial state" {
        Mock getAvailablePlanFiles { return @(newUntrackedPlan 'noprompt' $null) }
        Mock readStateKey { throw 'state prompt should be gone' }
        $db = [System.Collections.Generic.List[object]]::new()

        { openUntracked $db } | Should -Not -Throw
    }

    It "adds a stateless entry and dispatches a frontmatterless plan as ready-to-plan" {
        $plan = newUntrackedPlan 'fresh' $null
        Mock getAvailablePlanFiles { return @($plan) }
        $db = [System.Collections.Generic.List[object]]::new()

        $result = openUntracked $db

        $result         | Should -BeTrue
        $db.Count       | Should -Be 1
        $db[0].planFile | Should -Be $plan
        $script:launched.rest[0] | Should -Be "Please plan the next step in $plan"
        Should -Invoke saveDb -Times 1
    }

    It "dispatches a ready-to-implement plan with the do-next-step prompt" {
        $plan = newUntrackedPlan 'rti' 'ready-to-implement'
        Mock getAvailablePlanFiles { return @($plan) }
        $db = [System.Collections.Generic.List[object]]::new()

        $result = openUntracked $db

        $result | Should -BeTrue
        $script:launched.rest[0] | Should -Be "Please do the next step in $plan"
    }

    It "returns true even when cl fails (TUI refreshes)" {
        Mock getAvailablePlanFiles { return @(newUntrackedPlan 'clfail' $null) }
        Mock launchCl { return 1 }
        $db = [System.Collections.Generic.List[object]]::new()

        $result = openUntracked $db

        $result | Should -BeTrue
    }
}

Describe "changeState" {
    BeforeAll {
        $script:statePlansRoot = ((New-Item -ItemType Directory "TestDrive:\plans-state").FullName -replace '\\', '/').TrimEnd('/')

        function newStatePlan([string] $name, [string] $state) {
            $path = "$script:statePlansRoot/$name.md"
            Set-Content $path @("# $name", "", "## Step 1: first")
            if ($state) { $null = Set-PlanState -PlanFile $path -State $state }
            return $path
        }
    }

    BeforeEach {
        Mock saveDb { }
        Mock Write-Host { }
        Mock clearConsole { }
    }

    It "writes the picked state to the plan file, not the db" -TestCases @(
        @{ Key = 'P'; Expected = 'ready-to-plan';      Initial = 'code-complete' }
        @{ Key = 'I'; Expected = 'ready-to-implement'; Initial = 'ready-to-plan' }
        @{ Key = 'C'; Expected = 'code-complete';      Initial = 'ready-to-plan' }
        @{ Key = 'K'; Expected = 'checkpointed';       Initial = 'ready-to-plan' }
    ) {
        param($Key, $Expected, $Initial)
        $plan  = newStatePlan "key-$Key" $Initial
        $entry = [pscustomobject]@{planFile = $plan; cwd = "C:/de"; sessionIds = @(); state = $Initial}
        $db    = [System.Collections.Generic.List[object]]::new()
        $db.Add($entry)
        $script:pickKey = $Key
        Mock readStateKey { return [pscustomobject]@{Key = $script:pickKey} }

        changeState $db $entry

        (Get-PlanState -PlanFile $plan).State | Should -Be $Expected
        $entry.state                          | Should -Be $Expected
        Should -Invoke saveDb -Times 0
    }

    It "leaves the plan file unchanged on an unrecognized key" {
        $plan  = newStatePlan 'esc' 'ready-to-plan'
        $entry = [pscustomobject]@{planFile = $plan; cwd = "C:/de"; sessionIds = @(); state = 'ready-to-plan'}
        $db    = [System.Collections.Generic.List[object]]::new()
        $db.Add($entry)
        Mock readStateKey { return [pscustomobject]@{Key = 'Escape'} }

        changeState $db $entry

        (Get-PlanState -PlanFile $plan).State | Should -Be 'ready-to-plan'
        Should -Invoke saveDb -Times 0
    }
}