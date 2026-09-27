BeforeDiscovery {
    . "$PSScriptRoot/Launch-Plan.ps1"
}

BeforeAll {
    Import-Module "$home/prat/lib/PratBase/PratBase.psd1" -Force
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

    It "uses default harness when absent (legacy entries)" {
        Mock getDefaultHarness { return 'customtool' }

        Set-Content "TestDrive:\db-load-harness1.json" '[{"planFile":"p.md","cwd":"C:/de","sessionIds":[]}]'

        (loadDb "TestDrive:\db-load-harness1.json")[0].harness | Should -Be 'customtool'
    }

    It "preserves an explicit harness value" {
        Set-Content "TestDrive:\db-load-harness2.json" '[{"planFile":"p.md","cwd":"C:/de","sessionIds":[],"harness":"copilot"}]'

        (loadDb "TestDrive:\db-load-harness2.json")[0].harness | Should -Be 'copilot'
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
        $entries = @([pscustomobject]@{planFile = "C:/plans/bar.md"; cwd = "C:/de"; sessionIds = @(); state = "ready-to-refine"})

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

    It "round-trips harness through saveDb/loadDb" {
        $entries = @([pscustomobject]@{planFile = "C:/plans/bar.md"; cwd = "C:/de"; sessionIds = @(); harness = "copilot"})

        saveDb $entries "TestDrive:\rt-harness.json"

        (loadDb "TestDrive:\rt-harness.json")[0].harness | Should -Be 'copilot'
    }

    It "round-trips the launches count and the step it was counted against" {
        $entries = @([pscustomobject]@{planFile = "C:/plans/bar.md"; cwd = "C:/de"; sessionIds = @(); launches = 2; launchesFor = "Step 3: c"})

        saveDb $entries "TestDrive:\rt-launches.json"

        $r = (loadDb "TestDrive:\rt-launches.json")[0]
        $r.launches    | Should -Be 2
        $r.launchesFor | Should -Be "Step 3: c"
    }

    It "defaults a legacy entry with no launches field to a count of 0" {
        Set-Content "TestDrive:\rt-legacy-launches.json" '[{"planFile":"p.md","cwd":"C:/de","sessionIds":[]}]'

        $r = (loadDb "TestDrive:\rt-legacy-launches.json")[0]
        $r.launches    | Should -Be 0
        $r.launchesFor | Should -BeNullOrEmpty
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

Describe "attachEntryInfo" {
    BeforeAll {
        $script:attachRoot = ((New-Item -ItemType Directory "TestDrive:\plans-attach").FullName -replace '\\', '/').TrimEnd('/')

        function newAttachPlan([string] $name, [string] $state) {
            $path = "$script:attachRoot/$name.md"
            Set-Content $path @("# $name", "", "## Step 1: x")
            if ($state) { $null = Set-PlanState -PlanFile $path -State $state }
            return $path
        }
    }

    BeforeEach {
        Mock getSessionInfos { @() }
    }

    It "attaches frontmatter state; a plan without frontmatter gets null" {
        $db = @(
            [pscustomobject]@{planFile = (newAttachPlan 'with' 'ready-for-user-review'); cwd = "C:/de"; sessionIds = @(); launches = 0; launchesFor = $null}
            [pscustomobject]@{planFile = (newAttachPlan 'without' $null); cwd = "C:/de"; sessionIds = @(); launches = 0; launchesFor = $null}
        )

        attachEntryInfo $db

        $db[0].state | Should -Be 'ready-for-user-review'
        $db[1].state | Should -BeNullOrEmpty
    }

    It "attaches the frontmatter next-step pointer" {
        $plan = newAttachPlan 'pointer' 'ready-to-implement'
        $null = Set-PlanState -PlanFile $plan -First 'Step 1: x'
        $db = @([pscustomobject]@{planFile = $plan; cwd = "C:/de"; sessionIds = @(); launches = 0; launchesFor = $null})

        attachEntryInfo $db

        $db[0].nextStep | Should -Be 'Step 1: x'
    }

    It "attaches enterKind resume when resumable sessions exist, fresh when none" {
        Mock getSessionInfos { param($sessionIds) if (@($sessionIds).Count -gt 0) {
            @([pscustomobject]@{sid = 'sid-1'; lastActive = Get-Date; summary = 's'})
        } else { @() } }
        $db = @(
            [pscustomobject]@{planFile = (newAttachPlan 'has-session' 'ready-to-implement'); cwd = "C:/de"; sessionIds = @("sid-1"); launches = 0; launchesFor = $null}
            [pscustomobject]@{planFile = (newAttachPlan 'no-session' 'ready-to-implement'); cwd = "C:/de"; sessionIds = @(); launches = 0; launchesFor = $null}
        )

        attachEntryInfo $db

        $db[0].enterKind | Should -Be 'resume'
        $db[1].enterKind | Should -Be 'fresh'
    }

    It "attaches a legacy checkpointed plan's migrated state" {
        Mock getSessionInfos { @([pscustomobject]@{sid = 'sid-1'; lastActive = Get-Date; summary = 's'}) }
        $path = "$script:attachRoot/ckpt.md"
        Set-Content $path @("---", "current-unit:", "  first: `"Step 1: x`"", "  state: checkpointed", "---", "# ckpt", "", "## Step 1: x")
        $db = @([pscustomobject]@{planFile = $path; cwd = "C:/de"; sessionIds = @("sid-1"); launches = 0; launchesFor = $null})

        attachEntryInfo $db

        $db[0].state     | Should -Be 'ready-to-implement'
        $db[0].enterKind | Should -Be 'resume'
    }
}

Describe "refreshIfChanged" {
    BeforeAll {
        $script:rfRoot = ((New-Item -ItemType Directory "TestDrive:\plans-refresh").FullName -replace '\\', '/').TrimEnd('/')
    }

    BeforeEach {
        function newRefreshPlan([string] $name) {
            $path = "$script:rfRoot/$name.md"
            Set-Content $path "# $name"
            return $path
        }
        function newRefreshEntry([string] $path) {
            [pscustomobject]@{planFile = $path; cwd = "C:/de"; sessionIds = @(); launches = 0; launchesFor = $null}
        }
        function newRefreshDb() {
            $db = [System.Collections.Generic.List[object]]::new()
            foreach ($p in $args) { $db.Add((newRefreshEntry $p)) }
            return $db
        }
    }

    It "initializes mtimes without flagging a change or updating" {
        Mock updateEntryInfo { }
        $a = newRefreshPlan 'a'; $b = newRefreshPlan 'b'
        $db = newRefreshDb $a $b

        refreshIfChanged $db | Should -BeFalse

        $db[0]._mt | Should -Not -BeNull
        $db[1]._mt | Should -Not -BeNull
        Should -Invoke updateEntryInfo -Times 0
    }

    It "updates only the entry whose plan file was touched, and reports the change once" {
        Mock updateEntryInfo { }
        $a = newRefreshPlan 'a'; $b = newRefreshPlan 'b'
        $db = newRefreshDb $a $b
        refreshIfChanged $db | Out-Null

        (Get-Item $b).LastWriteTime = (Get-Date).AddSeconds(60)
        refreshIfChanged $db | Should -BeTrue
        Should -Invoke updateEntryInfo -Times 1

        refreshIfChanged $db | Should -BeFalse
        Should -Invoke updateEntryInfo -Times 1
    }

    It "skips a missing plan file (no mtime recorded, no update)" {
        Mock updateEntryInfo { }
        $a = newRefreshPlan 'a'
        $db = newRefreshDb $a "$script:rfRoot/gone.md"   # does not exist

        refreshIfChanged $db | Should -BeFalse

        $db[1]._mt | Should -Be $null
        Should -Invoke updateEntryInfo -Times 0
    }

    It "refreshes a touched entry's frontmatter, leaving an untouched entry alone" {
        Mock getSessionInfos { @() }
        $a = newRefreshPlan 'a'; $b = newRefreshPlan 'b'
        $null = Set-PlanState -PlanFile $a -State 'ready-to-refine'
        $null = Set-PlanState -PlanFile $b -State 'ready-to-refine'
        $db = newRefreshDb $a $b
        attachEntryInfo $db   # the context's initial read (buildLauncherContext does this)
        $db[0].state | Should -Be 'ready-to-refine'
        $db[1].state | Should -Be 'ready-to-refine'
        refreshIfChanged $db | Should -BeFalse   # first call: initializes mtimes, no change

        $null = Set-PlanState -PlanFile $b -State 'ready-to-implement'
        (Get-Item $b).LastWriteTime = (Get-Date).AddSeconds(60)
        refreshIfChanged $db | Should -BeTrue

        $db[1].state | Should -Be 'ready-to-implement'   # refreshed
        $db[0].state | Should -Be 'ready-to-refine'      # untouched, unchanged
    }
}

Describe "buildLauncherContext" {
    It "includes the last run's report" {
        Mock loadLauncherDb { [System.Collections.Generic.List[object]]::new() }
        Mock saveDb { }
        Mock attachEntryInfo { }
        Mock getHarnessDescriptors { @() }
        Mock getPlansDir { 'C:/plans' }
        Mock getSyncPath { @{ path = $null; notice = $null } }
        Mock readRunReport { [pscustomobject]@{ stepsClosed = @('Step 1: a','Step 2: b') } }

        @((buildLauncherContext).runReport.stepsClosed) | Should -Be @('Step 1: a','Step 2: b')
    }
}

Describe "displayState" {
    It "shows the display label and next-step pointer when both are present" {
        $entry = [pscustomobject]@{state = 'ready-to-implement'; nextStep = 'Step 5: model picker'}
        displayState $entry | Should -Be 'coding: Step 5: model picker'
    }

    It "falls back to the display label alone when there is no pointer" {
        $entry = [pscustomobject]@{state = 'ready-to-refine'; nextStep = $null}
        displayState $entry | Should -Be 'refining'
    }

    It "shows a dash when neither state nor pointer is present" {
        $entry = [pscustomobject]@{state = $null; nextStep = $null}
        displayState $entry | Should -Be '-'
    }

    It "maps ready-for-user-review to reviewing" {
        $entry = [pscustomobject]@{state = 'ready-for-user-review'; nextStep = $null}
        displayState $entry | Should -Be 'reviewing'
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

Describe "getLiveHarnessProcs" {
    It "returns an empty array when no process by that name is found" {
        Mock Get-CimInstance { }

        @(getLiveHarnessProcs 'copilot.exe') | Should -HaveCount 0
    }

    It "queries by the given process name and projects the command line" {
        $script:filterUsed = $null
        Mock Get-CimInstance { param($Filter) $script:filterUsed = $Filter; [pscustomobject]@{CommandLine = 'claude.exe --session-id abc'} }

        $result = @(getLiveHarnessProcs 'claude.exe')

        $result[0].CommandLine | Should -Be 'claude.exe --session-id abc'
        $script:filterUsed     | Should -Match 'claude\.exe'
    }
}

Describe "getLiveSessionRecords" {
    It "extracts session_id, cwd, and harness from a fresh copilot session cmdline" {
        Mock getLiveHarnessProcs { @([pscustomobject]@{ CommandLine = 'copilot.exe -C C:\roles\de --session-id 11111111-2222-3333-4444-555555555555 --add-dir C:\de' }) }

        $r = getLiveSessionRecords 'copilot' 'copilot.exe'

        $r.Count         | Should -Be 1
        $r[0].session_id | Should -Be '11111111-2222-3333-4444-555555555555'
        $r[0].cwd        | Should -Be 'C:\roles\de'
        $r[0].harness    | Should -Be 'copilot'
    }

    It "extracts session_id from a resumed (--resume=) copilot cmdline with no -C; cwd null" {
        Mock getLiveHarnessProcs { @([pscustomobject]@{ CommandLine = 'copilot.exe --stream off --resume=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee --add-dir C:\de' }) }

        $r = getLiveSessionRecords 'copilot' 'copilot.exe'

        $r[0].session_id | Should -Be 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        $r[0].cwd        | Should -BeNullOrEmpty
    }

    It "extracts a claude session id from a --session-id cmdline; cwd null (claude carries none)" {
        Mock getLiveHarnessProcs { @([pscustomobject]@{ CommandLine = 'claude.exe --session-id 22222222-3333-4444-5555-666666666666 do the thing' }) }

        $r = getLiveSessionRecords 'claude' 'claude.exe'

        $r[0].session_id | Should -Be '22222222-3333-4444-5555-666666666666'
        $r[0].cwd        | Should -BeNullOrEmpty
        $r[0].harness    | Should -Be 'claude'
    }

    It "extracts a claude session id from a --resume cmdline (space-separated)" {
        Mock getLiveHarnessProcs { @([pscustomobject]@{ CommandLine = 'claude.exe --resume 33333333-4444-5555-6666-777777777777' }) }

        $r = getLiveSessionRecords 'claude' 'claude.exe'

        $r[0].session_id | Should -Be '33333333-4444-5555-6666-777777777777'
    }

    It "dedups the parent+fork processes that share a session id" {
        Mock getLiveHarnessProcs {
            @(
                [pscustomobject]@{ CommandLine = 'copilot.exe -C C:\roles\de --session-id 11111111-2222-3333-4444-555555555555' },
                [pscustomobject]@{ CommandLine = 'copilot.exe -C C:\roles\de --session-id 11111111-2222-3333-4444-555555555555' }
            )
        }

        (getLiveSessionRecords 'copilot' 'copilot.exe').Count | Should -Be 1
    }

    It "returns one record per distinct session" {
        Mock getLiveHarnessProcs {
            @(
                [pscustomobject]@{ CommandLine = 'copilot.exe -C C:\a --session-id 11111111-1111-1111-1111-111111111111' },
                [pscustomobject]@{ CommandLine = 'copilot.exe -C C:\b --session-id 22222222-2222-2222-2222-222222222222' }
            )
        }

        (getLiveSessionRecords 'copilot' 'copilot.exe').Count | Should -Be 2
    }

    It "skips a process cmdline with no session id" {
        Mock getLiveHarnessProcs { @([pscustomobject]@{ CommandLine = 'copilot.exe --help' }) }

        (getLiveSessionRecords 'copilot' 'copilot.exe').Count | Should -Be 0
    }

    It "returns an empty array when no processes are live" {
        Mock getLiveHarnessProcs { @() }

        (getLiveSessionRecords 'claude' 'claude.exe').Count | Should -Be 0
    }

    It "matches a custom-harness session cmdline (e.g. python.exe running a script) when a cmdlineFilter is given" {
        Mock getLiveHarnessProcs { @([pscustomobject]@{ CommandLine = 'python.exe "C:\tools\customtool\customtool.py" --session-id 44444444-5555-6666-7777-888888888888' }) }

        $r = getLiveSessionRecords 'customtool' 'python.exe' 'customtool.py'

        $r.Count         | Should -Be 1
        $r[0].session_id | Should -Be '44444444-5555-6666-7777-888888888888'
        $r[0].harness    | Should -Be 'customtool'
    }

    It "skips a python.exe cmdline that doesn't match the cmdlineFilter (an unrelated python process)" {
        Mock getLiveHarnessProcs { @([pscustomobject]@{ CommandLine = 'python.exe --session-id 44444444-5555-6666-7777-888888888888' }) }

        (getLiveSessionRecords 'customtool' 'python.exe' 'customtool.py').Count | Should -Be 0
    }
}

Describe "resolveHarnessSessions" {
    BeforeEach {
        $script:live       = [System.Collections.Generic.HashSet[string]]::new()
        $script:orphans    = [System.Collections.Generic.List[string]]::new()
        $script:harnessMap = @{}
    }

    It "marks a known session live by id and stamps entry+map harness" {
        $entry   = [pscustomobject]@{planFile='f.md'; cwd='C:/de'; sessionIds=@('sid-1'); harness='claude'}
        $records = @(@{ session_id='sid-1'; cwd=$null; harness='claude' })

        resolveHarnessSessions @($entry) $records $script:live $script:orphans $script:harnessMap $false

        $script:live                | Should -Contain 'sid-1'
        $entry.harness              | Should -Be 'claude'
        $script:harnessMap['sid-1'] | Should -Be 'claude'
    }

    It "cwd-matches a new session to the sole unoccupied entry when cwd-matching is allowed" {
        $entry   = [pscustomobject]@{planFile='f.md'; cwd='C:/de'; sessionIds=@(); harness='copilot'}
        $records = @(@{ session_id='new-sid'; cwd='C:/de'; harness='copilot' })

        resolveHarnessSessions @($entry) $records $script:live $script:orphans $script:harnessMap $true

        $entry.sessionIds | Should -Contain 'new-sid'
        $entry.harness    | Should -Be 'copilot'
        $script:live      | Should -Contain 'new-sid'
        $script:orphans   | Should -Not -Contain 'new-sid'
    }

    It "orphans a new session with a matching cwd when cwd-matching is disallowed (claude)" {
        $entry   = [pscustomobject]@{planFile='f.md'; cwd='C:/de'; sessionIds=@(); harness='claude'}
        $records = @(@{ session_id='new-sid'; cwd='C:/de'; harness='claude' })

        resolveHarnessSessions @($entry) $records $script:live $script:orphans $script:harnessMap $false

        $script:orphans      | Should -Contain 'new-sid'
        @($entry.sessionIds) | Should -HaveCount 0
    }

    It "treats a new session as orphan when no cwd matches" {
        $entry   = [pscustomobject]@{planFile='f.md'; cwd='C:/other'; sessionIds=@(); harness='copilot'}
        $records = @(@{ session_id='new-sid'; cwd='C:/de'; harness='copilot' })

        resolveHarnessSessions @($entry) $records $script:live $script:orphans $script:harnessMap $true

        $script:orphans               | Should -Contain 'new-sid'
        $script:harnessMap['new-sid'] | Should -Be 'copilot'
    }

    It "treats a session with null cwd as orphan when untracked" {
        $entry   = [pscustomobject]@{planFile='f.md'; cwd='C:/de'; sessionIds=@(); harness='copilot'}
        $records = @(@{ session_id='resumed-sid'; cwd=$null; harness='copilot' })

        resolveHarnessSessions @($entry) $records $script:live $script:orphans $script:harnessMap $true

        $script:orphans | Should -Contain 'resumed-sid'
    }

    It "does not cwd-match an entry already occupied by a live session" {
        $entry   = [pscustomobject]@{planFile='f.md'; cwd='C:/de'; sessionIds=@('live-1'); harness='copilot'}
        $records = @(@{ session_id='live-1'; cwd='C:/de'; harness='copilot' }, @{ session_id='new-sid'; cwd='C:/de'; harness='copilot' })

        resolveHarnessSessions @($entry) $records $script:live $script:orphans $script:harnessMap $true

        $script:orphans      | Should -Contain 'new-sid'
        @($entry.sessionIds) | Should -HaveCount 1
    }

    It "orphans a new session when cwd matches multiple entries" {
        $e1      = [pscustomobject]@{planFile='f1.md'; cwd='C:/de'; sessionIds=@(); harness='copilot'}
        $e2      = [pscustomobject]@{planFile='f2.md'; cwd='C:/de'; sessionIds=@(); harness='copilot'}
        $records = @(@{ session_id='new-sid'; cwd='C:/de'; harness='copilot' })

        resolveHarnessSessions @($e1,$e2) $records $script:live $script:orphans $script:harnessMap $true

        $script:orphans   | Should -Contain 'new-sid'
        @($e1.sessionIds) | Should -HaveCount 0
        @($e2.sessionIds) | Should -HaveCount 0
    }

    It "doesn't duplicate an already-present session id" {
        $entry   = [pscustomobject]@{planFile='f.md'; cwd='C:/de'; sessionIds=@('sid-1'); harness='claude'}
        $records = @(@{ session_id='sid-1'; cwd=$null; harness='claude' })

        resolveHarnessSessions @($entry) $records $script:live $script:orphans $script:harnessMap $false

        @($entry.sessionIds) | Should -HaveCount 1
    }
}

Describe "openInEditor" {
    It "does nothing when Open-FileInEditor isn't on PATH" {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Open-FileInEditor' }

        { openInEditor 'C:/plans/foo.md' } | Should -Not -Throw
    }

    It "invokes Open-FileInEditor with the path when available" {
        $script:invoked = $null
        function Open-FileInEditor { param($p) $script:invoked = $p }

        openInEditor 'C:/plans/foo.md'

        $script:invoked | Should -Be 'C:/plans/foo.md'
    }
}

Describe "getResumeArgs" {
    It "claude uses space-separated --resume" {
        $r = getResumeArgs 'claude' 'sid-1'
        $r | Should -Be @('--resume', 'sid-1')
    }

    It "copilot uses the --resume=<id> form" {
        $r = getResumeArgs 'copilot' 'sid-1'
        $r | Should -Be @('--resume=sid-1')
    }

    It "any custom (non-copilot) harness uses space-separated --resume" {
        $r = getResumeArgs 'customtool' 'sid-1'
        $r | Should -Be @('--resume', 'sid-1')
    }
}

Describe "getAgentHarnesses" {
    It "invokes Get-AgentHarnesses and returns its list" {
        function Get-AgentHarnesses { @(@{ name = 'claude' }, @{ name = 'customtool' }) }

        @((getAgentHarnesses).name) | Should -Be @('claude', 'customtool')
    }
}

Describe "getDefaultHarness" {
    It "returns the first entry's name" {
        Mock getAgentHarnesses { @(@{ name = 'customtool' }, @{ name = 'claude' }) }

        getDefaultHarness | Should -Be 'customtool'
    }
}

Describe "getBuiltinHarnessDescriptors" {
    It "includes claude with its live-process and session-info defaults" {
        $claude = @(getBuiltinHarnessDescriptors | Where-Object { $_.name -eq 'claude' })[0]

        $claude.liveProcessName  | Should -Be 'claude.exe'
        $claude.sessionInfoStyle | Should -Be 'claude-projects'
        $claude.pickerKey        | Should -Be 'C'
    }

    It "includes copilot with cwd-matching enabled" {
        $copilot = @(getBuiltinHarnessDescriptors | Where-Object { $_.name -eq 'copilot' })[0]

        $copilot.liveProcessName  | Should -Be 'copilot.exe'
        $copilot.liveCwdMatch     | Should -BeTrue
        $copilot.sessionInfoStyle | Should -Be 'claude-projects'
    }

    It "includes pi, filtered by its script path since it runs as the generic node.exe" {
        $pi = @(getBuiltinHarnessDescriptors | Where-Object { $_.name -eq 'pi' })[0]

        $pi.liveProcessName   | Should -Be 'node.exe'
        $pi.liveCmdlineFilter | Should -Be 'pi-coding-agent'
    }

    It "picker keys are unique across the built-ins" {
        $keys = @(getBuiltinHarnessDescriptors | Where-Object { $_.pickerKey } | ForEach-Object { $_.pickerKey })

        ($keys | Select-Object -Unique).Count | Should -Be $keys.Count
    }
}

Describe "getHarnessDescriptor" {
    It "returns claude's built-in descriptor even if the registry lists it too (de just selects it, doesn't configure it)" {
        Mock getAgentHarnesses { @(@{ name = 'claude'; pickerKey = 'X' }) }

        (getHarnessDescriptor 'claude').liveProcessName | Should -Be 'claude.exe'
        (getHarnessDescriptor 'claude').pickerKey       | Should -Be 'C'
    }

    It "returns the registry's own entry for a harness with no built-in (the augmenting case)" {
        Mock getAgentHarnesses { @(@{ name = 'customtool'; sessionsDir = 'C:/x' }) }

        (getHarnessDescriptor 'customtool').sessionsDir | Should -Be 'C:/x'
    }

    It "returns null for an unregistered, non-built-in harness name" {
        Mock getAgentHarnesses { @(@{ name = 'customtool' }) }

        getHarnessDescriptor 'somethingelse' | Should -BeNullOrEmpty
    }
}

Describe "getHarnessDescriptors" {
    It "only includes a built-in de has actually selected" {
        Mock getAgentHarnesses { @(@{ name = 'claude' }) }

        @((getHarnessDescriptors).name) | Should -Be @('claude')
    }

    It "includes multiple selected built-ins, in registry order" {
        Mock getAgentHarnesses { @(@{ name = 'claude' }, @{ name = 'pi' }) }

        @((getHarnessDescriptors).name) | Should -Be @('claude', 'pi')
    }

    It "ignores a registry entry that just re-selects a built-in by name" {
        Mock getAgentHarnesses { @(@{ name = 'claude'; pickerKey = 'X' }) }

        $claude = @(getHarnessDescriptors | Where-Object { $_.name -eq 'claude' })[0]
        $claude.pickerKey | Should -Be 'C'
    }

    It "appends a registry-only entry that has no built-in, without pulling in unselected built-ins" {
        Mock getAgentHarnesses { @(@{ name = 'claude' }, @{ name = 'customtool'; pickerKey = 'X' }) }

        @((getHarnessDescriptors).name) | Should -Be @('claude', 'customtool')
    }
}

Describe "harnessSupportsHeadless" {
    It "true for a descriptor declaring a headless flag" {
        harnessSupportsHeadless @{ name = 'myharness'; headlessFlag = '--headless' } | Should -BeTrue
    }

    It "false for a descriptor with none" {
        harnessSupportsHeadless @{ name = 'claude' } | Should -BeFalse
    }

    It "false for a null descriptor (unregistered harness)" {
        harnessSupportsHeadless $null | Should -BeFalse
    }
}

Describe "getHeadlessArgs" {
    It "returns the descriptor's own flag" {
        $r = getHeadlessArgs @{ headlessFlag = '--headless' }
        $r | Should -Be @('--headless')
    }

    It "returns nothing for a descriptor with no flag" {
        $r = getHeadlessArgs @{ name = 'claude' }
        $r.Count | Should -Be 0
    }

    It "returns nothing for a null descriptor" {
        $r = getHeadlessArgs $null
        $r.Count | Should -Be 0
    }
}

Describe "getClExtraArgs" {
    It "claude prepends -Harness:claude" {
        $r = getClExtraArgs 'claude' @('a', 'b')
        $r | Should -Be @('-Harness:claude', 'a', 'b')
    }

    It "copilot prepends -Harness:copilot" {
        $r = getClExtraArgs 'copilot' @('a', 'b')
        $r | Should -Be @('-Harness:copilot', 'a', 'b')
    }

    It "claude with no user args yields just -Harness:claude" {
        $r = getClExtraArgs 'claude' @()
        $r | Should -Be @('-Harness:claude')
    }
}

Describe "buildClCommandLine" {
    It "passes a flag token through and quotes a value token" {
        buildClCommandLine @('-Harness:claude', 'do the thing') | Should -Be '& cl -Harness:claude "do the thing"'
    }

    It "leaves a pre-quoted colon-form token intact, so a multi-value parameter arrives as one token" {
        buildClCommandLine @('-CommitRepo:"C:/repos/myrepo","C:/repos/myotherrepo"') |
            Should -Be '& cl -CommitRepo:"C:/repos/myrepo","C:/repos/myotherrepo"'
    }

    It "doubles a quote inside a value" {
        buildClCommandLine @('say "hi"') | Should -Be '& cl "say ""hi"""'
    }

    It "is a bare cl call when there are no args" {
        buildClCommandLine @() | Should -Be '& cl'
    }
}

Describe "buildChildCommand" {
    It "runs the cursor guard, then cl, then the exit propagation" {
        Mock getCursorGuardScript { 'GUARD' }

        buildChildCommand @('-Harness:claude', 'do the thing') |
            Should -Be 'GUARD; & cl -Harness:claude "do the thing"; exit $LASTEXITCODE'
    }

    It "-Unattended: passes it through to getCursorGuardScript" {
        Mock getCursorGuardScript { '' }

        buildChildCommand @() -Unattended

        Should -Invoke getCursorGuardScript -ParameterFilter { $Unattended -eq $true }
    }

    # The reason the trailing exit exists: pwsh adopts $LASTEXITCODE as its own exit code only when
    # the -EncodedCommand script ends on a native command, so a harness that fails inside cl reaches
    # pl as a clean 0, and pl's next redraw wipes whatever the harness printed.
    It "gives the child pwsh the exit code of a native command run inside cl" {
        Mock getCursorGuardScript { '$null = 1' }
        $cmd = 'function cl { pwsh -NoProfile -Command "exit 3" }; ' + (buildChildCommand @())
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))

        $proc = Start-Process pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-EncodedCommand', $encoded) `
            -NoNewWindow -PassThru -Wait

        $proc.ExitCode | Should -Be 3
    }
}

Describe "resolveCommitRepoPath" {
    It "resolves a bare name as a prat repo id" {
        Mock Get-PratRepoRoot { 'C:\repos\myrepo' } -ParameterFilter { $id -eq 'myrepo' }

        resolveCommitRepoPath 'myrepo' | Should -Be 'C:/repos/myrepo'
    }

    It "returns null for an id the repo index doesn't know" {
        Mock Get-PratRepoRoot { $null }

        resolveCommitRepoPath 'nosuchrepo' | Should -BeNullOrEmpty
    }

    It "takes an entry containing a separator as a path" {
        Mock Get-PratRepoRoot { throw 'a path should not be looked up as an id' }

        resolveCommitRepoPath 'C:\repos\myrepo' | Should -Be 'C:/repos/myrepo'
    }

    It "expands a leading ~" {
        Mock Get-PratRepoRoot { throw 'a path should not be looked up as an id' }

        resolveCommitRepoPath '~/myrepo' | Should -Be (normalizePath "$home/myrepo")
    }
}

Describe "getRepoBranch" {
    BeforeAll {
        $script:bareDir = (New-Item -ItemType Directory "TestDrive:\not-a-repo").FullName
        if (& git -C $script:bareDir rev-parse --git-dir 2>$null) {
            throw "TestDrive sits inside a git repo, so the no-working-tree case can't be exercised here."
        }
        $script:repoDir = (New-Item -ItemType Directory "TestDrive:\a-repo").FullName
        & git -C $script:repoDir init --initial-branch=myfeature *> $null
    }

    It "returns the checked-out branch" {
        getRepoBranch $script:repoDir | Should -Be 'myfeature'
    }

    It "returns null where there is no git working tree" {
        getRepoBranch $script:bareDir | Should -BeNullOrEmpty
    }
}
Describe "repoHasBranch" {
    BeforeAll {
        $script:branchRepo = (New-Item -ItemType Directory "TestDrive:\branch-repo").FullName
        & git -C $script:branchRepo init --initial-branch=main *> $null
        & git -C $script:branchRepo config user.email 'test@example.com' *> $null
        & git -C $script:branchRepo config user.name 'Test' *> $null
        & git -C $script:branchRepo commit --allow-empty -m seed *> $null
        & git -C $script:branchRepo branch 'topic/sub' *> $null
        $script:branchBareDir = (New-Item -ItemType Directory "TestDrive:\branch-not-a-repo").FullName
    }

    It "finds a branch that exists" {
        repoHasBranch $script:branchRepo 'topic/sub' | Should -BeTrue
    }

    It "does not find a branch that doesn't exist" {
        repoHasBranch $script:branchRepo 'feature' | Should -BeFalse
    }

    It "does not mistake a branch below a name for the name itself" {
        # `for-each-ref refs/heads/topic` matches refs/heads/topic/sub as well, so the match is on the whole name.
        repoHasBranch $script:branchRepo 'topic' | Should -BeFalse
    }

    It "returns false where there is no git working tree" {
        repoHasBranch $script:branchBareDir 'main' | Should -BeFalse
    }
}


Describe "resolveCommitGrant" {
    BeforeEach {
        Mock Get-PratRepoRoot { "C:/repos/$id" }
        Mock getRepoBranch { 'feature' }
        Mock repoHasBranch { $false }
    }

    It "returns null when the plan declares no grant" {
        resolveCommitGrant ([pscustomobject]@{ CommitBranch = $null; CommitRepos = @() }) | Should -BeNullOrEmpty
    }

    It "resolves every repo, with no problems when each has the branch checked out" {
        $grant = resolveCommitGrant ([pscustomobject]@{ CommitBranch = 'feature'; CommitRepos = @('myrepo', 'myotherrepo') })

        $grant.branch      | Should -Be 'feature'
        @($grant.repoPaths) | Should -Be @('C:/repos/myrepo', 'C:/repos/myotherrepo')
        @($grant.problems)  | Should -HaveCount 0
    }

    It "reports the repo that is on another branch" {
        Mock getRepoBranch { if ($repoPath -like '*myotherrepo*') { 'someoneelses' } else { 'feature' } }

        $grant = resolveCommitGrant ([pscustomobject]@{ CommitBranch = 'feature'; CommitRepos = @('myrepo', 'myotherrepo') })

        @($grant.problems) | Should -HaveCount 1
        $grant.problems[0] | Should -BeLike '*myotherrepo*'
        $grant.problems[0] | Should -BeLike "*someoneelses*"
    }

    It "treats a repo on main without the branch as pending, not a problem" {
        # The grant still holds: the session creates the branch there before it commits.
        Mock getRepoBranch { if ($repoPath -like '*myotherrepo*') { 'main' } else { 'feature' } }

        $grant = resolveCommitGrant ([pscustomobject]@{ CommitBranch = 'feature'; CommitRepos = @('myrepo', 'myotherrepo') })

        @($grant.problems) | Should -HaveCount 0
        @($grant.pending)  | Should -Be @('C:/repos/myotherrepo')
    }

    It "reports a repo on main whose branch exists but isn't checked out" {
        # Nothing to create, so the fix is a checkout, which is the user's.
        Mock getRepoBranch { 'main' }
        Mock repoHasBranch { $true }

        $grant = resolveCommitGrant ([pscustomobject]@{ CommitBranch = 'feature'; CommitRepos = @('myrepo') })

        @($grant.problems) | Should -HaveCount 1
        $grant.problems[0] | Should -BeLike '*myrepo*'
        @($grant.pending)  | Should -HaveCount 0
    }

    It "reports a repo that isn't a git working tree at all" {
        Mock getRepoBranch { $null }

        $grant = resolveCommitGrant ([pscustomobject]@{ CommitBranch = 'feature'; CommitRepos = @('myrepo') })

        @($grant.problems) | Should -HaveCount 1
        $grant.problems[0] | Should -BeLike '*C:/repos/myrepo*'
    }

    It "reports an entry no repo id resolves" {
        Mock Get-PratRepoRoot { $null }

        $grant = resolveCommitGrant ([pscustomobject]@{ CommitBranch = 'feature'; CommitRepos = @('nosuchrepo') })

        @($grant.problems)  | Should -HaveCount 1
        $grant.problems[0]  | Should -BeLike '*nosuchrepo*'
        @($grant.repoPaths) | Should -HaveCount 0
    }

    It "reports a grant that names no repos" {
        $grant = resolveCommitGrant ([pscustomobject]@{ CommitBranch = 'feature'; CommitRepos = @() })

        @($grant.problems) | Should -HaveCount 1
        $grant.problems[0] | Should -BeLike '*no repos*'
    }
}

Describe "getCommitGrantArgs" {
    It "renders the branch and the repo list as two pre-quoted tokens" {
        $r = getCommitGrantArgs @{ branch = 'feature'; repoPaths = @('C:/repos/myrepo', 'C:/repos/myotherrepo'); problems = @() }

        $r | Should -Be @('-CommitBranch:"feature"', '-CommitRepo:"C:/repos/myrepo","C:/repos/myotherrepo"')
    }

    It "renders a single repo" {
        $r = getCommitGrantArgs @{ branch = 'feature'; repoPaths = @('C:/repos/myrepo'); problems = @() }

        $r | Should -Be @('-CommitBranch:"feature"', '-CommitRepo:"C:/repos/myrepo"')
    }

    It "renders nothing when the grant has a problem" {
        $r = getCommitGrantArgs @{ branch = 'feature'; repoPaths = @('C:/repos/myrepo'); problems = @('on main') }

        @($r) | Should -HaveCount 0
    }

    It "renders nothing when there is no grant" {
        @(getCommitGrantArgs $null) | Should -HaveCount 0
    }
}

Describe "getLaunchCommitGrantArgs" {
    BeforeAll {
        $script:grantPlansRoot = ((New-Item -ItemType Directory "TestDrive:\plans-grant").FullName -replace '\\', '/').TrimEnd('/')

        # commit-grant is hand-declared frontmatter — Set-PlanState carries the block but never writes it.
        function newGrantPlan([string] $name, [string] $branch, [string] $repos) {
            $path = "$script:grantPlansRoot/$name.md"
            $lines = @('---', 'current-unit:', '  first: "Step 1: first"', '  state: ready-to-implement')
            if ($branch) { $lines += @('commit-grant:', "  branch: `"$branch`"", "  repos: $repos") }
            Set-Content $path ($lines + @('---', "# $name", '', '## Step 1: first'))
            return $path
        }
    }

    BeforeEach {
        Mock Write-Host { }
        Mock Read-Host { '' }
        Mock Get-PratRepoRoot { "C:/repos/$id" }
        Mock getRepoBranch { 'feature' }
        Mock repoHasBranch { $false }
    }

    It "passes the grant the plan declares, without pausing" {
        $plan = newGrantPlan 'granted' 'feature' '[myrepo, myotherrepo]'

        getLaunchCommitGrantArgs $plan | Should -Be @('-CommitBranch:"feature"', '-CommitRepo:"C:/repos/myrepo","C:/repos/myotherrepo"')
        Should -Invoke Read-Host -Times 0
    }

    It "drops the whole grant, and pauses, when one repo is on another branch" {
        Mock getRepoBranch { if ($repoPath -like '*myotherrepo*') { 'someoneelses' } else { 'feature' } }
        $plan = newGrantPlan 'wrong-branch' 'feature' '[myrepo, myotherrepo]'

        @(getLaunchCommitGrantArgs $plan) | Should -HaveCount 0
        Should -Invoke Read-Host -Times 1
        Should -Invoke Write-Host -ParameterFilter { $Object -like '*myotherrepo*' }
    }

    It "keeps the grant, and pauses, for a repo that still needs the branch created" {
        # The pause is the only way the line is read at all: the launcher clears the console next.
        Mock getRepoBranch { if ($repoPath -like '*myotherrepo*') { 'main' } else { 'feature' } }
        $plan = newGrantPlan 'pending' 'feature' '[myrepo, myotherrepo]'

        getLaunchCommitGrantArgs $plan | Should -Be @('-CommitBranch:"feature"', '-CommitRepo:"C:/repos/myrepo","C:/repos/myotherrepo"')
        Should -Invoke Read-Host -Times 1
        Should -Invoke Write-Host -ParameterFilter { $Object -like '*myotherrepo*' }
    }

    It "passes nothing, and doesn't pause, for a plan with no grant" {
        $plan = newGrantPlan 'ungranted' $null $null

        @(getLaunchCommitGrantArgs $plan) | Should -HaveCount 0
        Should -Invoke Read-Host -Times 0
        Should -Invoke getRepoBranch -Times 0
    }

    It "-NoPause: still warns about a refused grant, but never reads the console" {
        Mock getRepoBranch { if ($repoPath -like '*myotherrepo*') { 'someoneelses' } else { 'feature' } }
        $plan = newGrantPlan 'wrong-branch-nopause' 'feature' '[myrepo, myotherrepo]'

        @(getLaunchCommitGrantArgs $plan -NoPause) | Should -HaveCount 0
        Should -Invoke Read-Host -Times 0
        Should -Invoke Write-Host -ParameterFilter { $Object -like '*myotherrepo*' }
    }

    It "-NoPause: still renders the grant for a pending branch, without reading the console" {
        Mock getRepoBranch { if ($repoPath -like '*myotherrepo*') { 'main' } else { 'feature' } }
        $plan = newGrantPlan 'pending-nopause' 'feature' '[myrepo, myotherrepo]'

        getLaunchCommitGrantArgs $plan -NoPause | Should -Be @('-CommitBranch:"feature"', '-CommitRepo:"C:/repos/myrepo","C:/repos/myotherrepo"')
        Should -Invoke Read-Host -Times 0
    }
}

Describe "commitGrantRefusedReason" {
    BeforeAll {
        $script:refusedPlansRoot = ((New-Item -ItemType Directory "TestDrive:\plans-grant-refused").FullName -replace '\\', '/').TrimEnd('/')

        function newRefusedGrantPlan([string] $name, [string] $branch, [string] $repos) {
            $path = "$script:refusedPlansRoot/$name.md"
            $lines = @('---', 'current-unit:', '  first: "Step 1: first"', '  state: ready-to-implement')
            if ($branch) { $lines += @('commit-grant:', "  branch: `"$branch`"", "  repos: $repos") }
            Set-Content $path ($lines + @('---', "# $name", '', '## Step 1: first'))
            return $path
        }
    }

    BeforeEach {
        Mock Get-PratRepoRoot { "C:/repos/$id" }
        Mock getRepoBranch { 'feature' }
        Mock repoHasBranch { $false }
    }

    It "refuses a plan with no grant declared — branch-review can't commit without one" {
        $plan = newRefusedGrantPlan 'none' $null $null
        commitGrantRefusedReason $plan | Should -Be 'no commit grant declared'
    }

    It "null for a grant every repo qualifies for" {
        $plan = newRefusedGrantPlan 'ok' 'feature' '[myrepo]'
        commitGrantRefusedReason $plan | Should -BeNullOrEmpty
    }

    It "null for a grant only pending a branch create — the session can still make progress" {
        Mock getRepoBranch { 'main' }
        $plan = newRefusedGrantPlan 'pending' 'feature' '[myrepo]'
        commitGrantRefusedReason $plan | Should -BeNullOrEmpty
    }

    It "names the problem for a refused grant" {
        Mock getRepoBranch { 'someoneelses' }
        $plan = newRefusedGrantPlan 'refused' 'feature' '[myrepo]'
        commitGrantRefusedReason $plan | Should -Match 'someoneelses'
    }
}

Describe "getModelList" {
    It "returns null when the model-list command is absent" {
        Mock tryInvokeAgentModelList { $null }

        getModelList 'claude' | Should -BeNullOrEmpty
    }

    It "returns null when the harness key is absent from the table" {
        Mock tryInvokeAgentModelList { @{ claude = @{ small = @{ displayName = 'Haiku'; model = 'Haiku'; relativeCost = 1 } } } }

        getModelList 'copilot' | Should -BeNullOrEmpty
    }

    It "returns a cost-sorted list with <default> appended" {
        Mock tryInvokeAgentModelList {
            @{ claude = @{
                large  = @{ displayName = 'Opus';   model = 'Opus';   relativeCost = 5 }
                small  = @{ displayName = 'Haiku';  model = 'Haiku';  relativeCost = 1 }
                medium = @{ displayName = 'Sonnet'; model = 'Sonnet'; relativeCost = 3 }
            } }
        }

        $list = getModelList 'claude'

        @($list.displayName) | Should -Be @('Haiku', 'Sonnet', 'Opus', '<default>')
        $list[-1].model      | Should -BeNullOrEmpty
    }
}

Describe "cycleIndex" {
    It "advances forward" {
        cycleIndex 0 3 1 | Should -Be 1
    }

    It "wraps forward past the end" {
        cycleIndex 2 3 1 | Should -Be 0
    }

    It "moves backward" {
        cycleIndex 2 3 -1 | Should -Be 1
    }

    It "wraps backward past the start" {
        cycleIndex 0 3 -1 | Should -Be 2
    }

    It "stays at 0 for an empty list, rather than dividing by zero" {
        cycleIndex 0 0 1 | Should -Be 0
    }
}

Describe "advanceFreshRowField" {
    It "advances the named field's index, wrapping, and reports the mutation" {
        $row = @{ kind = 'fresh'; modelList = @(1, 2, 3); modelIndex = 2 }

        $changed = advanceFreshRowField $row 'model' 1

        $row.modelIndex | Should -Be 0
        $changed        | Should -BeTrue
    }

    It "cycles any named field the same way, not just 'model'" {
        $row = @{ kind = 'fresh'; fooList = @(1, 2); fooIndex = 0 }

        advanceFreshRowField $row 'foo' 1

        $row.fooIndex | Should -Be 1
    }

    It "is a no-op for a session row" {
        $row = @{ kind = 'session'; modelList = @(1, 2, 3); modelIndex = 0 }

        $changed = advanceFreshRowField $row 'model' 1

        $row.modelIndex | Should -Be 0
        $changed        | Should -BeFalse
    }

    It "is a no-op for a fresh row without that field" {
        $row = @{ kind = 'fresh' }

        $changed = advanceFreshRowField $row 'model' 1

        $row.ContainsKey('modelIndex') | Should -BeFalse
        $changed                       | Should -BeFalse
    }
}

Describe "handleFreshRowKey" {
    BeforeAll {
        $script:freshKeyPlansRoot = ((New-Item -ItemType Directory "TestDrive:\plans-freshkey").FullName -replace '\\', '/').TrimEnd('/')

        function newFreshRow { return @{ kind = 'fresh'; modelList = @(1, 2, 3); modelIndex = 0 } }

        # A fresh row carrying the workflow and harness fields the picker cycles, plus the entry/db it
        # persists into. $workflow defaults to tick-tock; a real plan file backs the workflow write.
        function newCyclableFreshRow([string] $name, [string] $workflow = 'tick-tock', [string] $harness = 'claude') {
            $plan = "$script:freshKeyPlansRoot/$name.md"
            Set-Content $plan @("# $name", "", "## Step 1: first")
            if ($workflow) { $null = Set-PlanState -PlanFile $plan -Workflow $workflow }
            $entry = [pscustomobject]@{planFile = $plan; cwd = 'C:/de'; sessionIds = @(); harness = $harness}
            $db    = [System.Collections.Generic.List[object]]::new(); $db.Add($entry)
            $wf    = if ($workflow) { $workflow } else { 'tick-tock' }
            $wfList = @('tick-tock', 'step-review', 'branch-review')
            $hList  = @('claude', 'customtool')
            return @{
                kind = 'fresh'; entry = $entry; db = $db; phase = 'implement'; nextStep = 'Step 1: first'
                harness = $harness
                phaseLabel = "implement Step 1: first · $wf"
                workflowList = $wfList; workflowIndex = $wfList.IndexOf($wf)
                harnessList = $hList; harnessIndex = $hList.IndexOf($harness)
            }
        }
    }

    It "Left and Right cycle the model" {
        $row = newFreshRow

        handleFreshRowKey $row ([pscustomobject]@{Key = 'RightArrow'}) | Should -BeTrue
        $row.modelIndex | Should -Be 1
        handleFreshRowKey $row ([pscustomobject]@{Key = 'LeftArrow'})  | Should -BeTrue
        $row.modelIndex | Should -Be 0
    }

    It "W cycles the workflow forward and persists it to the plan file" {
        $row = newCyclableFreshRow 'wf-1'   # starts tick-tock
        $plan = $row.entry.planFile

        $changed = handleFreshRowKey $row ([pscustomobject]@{Key = 'W'})

        $changed | Should -BeTrue
        (Get-PlanState -PlanFile $plan).Workflow | Should -Be 'step-review'
        $row.phaseLabel | Should -Match 'step-review'
    }

    It "W into branch-review also prompts for and writes the commit grant" {
        $row = newCyclableFreshRow 'wf-2' 'step-review'   # W → branch-review
        $plan = $row.entry.planFile
        Mock getRepoBranch { 'myBranch' }
        Mock Read-Host { param($Prompt) if ($Prompt -match 'Branch') { '' } else { 'de, prat' } }

        handleFreshRowKey $row ([pscustomobject]@{Key = 'W'})

        $result = Get-PlanState -PlanFile $plan
        $result.Workflow     | Should -Be 'branch-review'
        $result.CommitBranch | Should -Be 'myBranch'
    }

    It "W does not prompt for a grant when cycling to tick-tock or step-review" {
        $row = newCyclableFreshRow 'wf-3'   # tick-tock → step-review
        $plan = $row.entry.planFile
        Mock Read-Host { throw 'should not prompt' }

        handleFreshRowKey $row ([pscustomobject]@{Key = 'W'})

        (Get-PlanState -PlanFile $plan).Workflow | Should -Be 'step-review'
    }

    It "H cycles the harness forward and writes it to the entry and the db" {
        $row = newCyclableFreshRow 'h-1'   # claude (index 0) → customtool
        Mock saveDb { }

        $changed = handleFreshRowKey $row ([pscustomobject]@{Key = 'H'})

        $changed | Should -BeTrue
        $row.entry.harness | Should -Be 'customtool'
        Should -Invoke saveDb -Times 1
    }

    It "ignores any other key" {
        $row = newFreshRow

        handleFreshRowKey $row ([pscustomobject]@{Key = 'X'}) | Should -BeFalse
    }
}

Describe "getCursorGuardScript" {
    It "checks the console cursor position and offers a pause to read startup output" {
        $script = getCursorGuardScript

        $script | Should -Match 'CursorLeft'
        $script | Should -Match 'CursorTop'
        $script | Should -Match 'Read-Host'
    }

    It "-Unattended: no pause, since nobody is at the console to answer it" {
        getCursorGuardScript -Unattended | Should -Be ''
    }
}

Describe "getModelArgs" {
    It "returns no args for a null model (<default>)" {
        $r = getModelArgs $null
        $r.Count | Should -Be 0
    }

    It "returns --model <name> for a chosen model" {
        $r = getModelArgs 'Opus'
        $r | Should -Be @('--model', 'Opus')
    }
}

Describe "pickFromList" {
    BeforeEach {
        Mock Write-Host { }
        Mock clearConsole { }
        Mock getConsoleWidth { 200 }
    }

    It "unhandled keys are no-ops when no onKey is supplied" {
        $keys = [System.Collections.Generic.Queue[object]]::new()
        $keys.Enqueue([pscustomobject]@{Key = 'LeftArrow'})
        $keys.Enqueue([pscustomobject]@{Key = 'RightArrow'})
        $keys.Enqueue([pscustomobject]@{Key = 'Enter'})
        Mock readListKey { $keys.Dequeue() }

        $result = pickFromList @('a', 'b') { param($i) $i }

        $result | Should -Be 0
    }

    It "does not re-invoke the label function on Up/Down navigation (no wasted work for expensive labels)" {
        $keys = [System.Collections.Generic.Queue[object]]::new()
        $keys.Enqueue([pscustomobject]@{Key = 'DownArrow'})
        $keys.Enqueue([pscustomobject]@{Key = 'UpArrow'})
        $keys.Enqueue([pscustomobject]@{Key = 'Enter'})
        Mock readListKey { $keys.Dequeue() }
        $script:labelCalls = 0
        $labelFn = { param($i) $script:labelCalls++; $i }

        pickFromList @('a', 'b') $labelFn

        $script:labelCalls | Should -Be 2   # once per item, computed once up front — not per render
    }

    It "invokes onKey with the selected item and the key, for a key it doesn't handle itself" {
        $keys = [System.Collections.Generic.Queue[object]]::new()
        $keys.Enqueue([pscustomobject]@{Key = 'RightArrow'})
        $keys.Enqueue([pscustomobject]@{Key = 'I'})
        $keys.Enqueue([pscustomobject]@{Key = 'Enter'})
        Mock readListKey { $keys.Dequeue() }
        $calls = [System.Collections.Generic.List[object]]::new()
        $onKey = { param($item, $key) $calls.Add(@{item = $item; key = $key.Key}); $false }
        $item = @{ n = 'x' }

        $result = pickFromList @($item) { param($i) $i.n } 'title' 0 $onKey

        $result        | Should -Be 0
        $calls.Count   | Should -Be 2
        $calls[0].key  | Should -Be 'RightArrow'
        $calls[1].key  | Should -Be 'I'
    }

    It "does not hand the picker's own keys to onKey" {
        $keys = [System.Collections.Generic.Queue[object]]::new()
        $keys.Enqueue([pscustomobject]@{Key = 'DownArrow'})
        $keys.Enqueue([pscustomobject]@{Key = 'UpArrow'})
        $keys.Enqueue([pscustomobject]@{Key = 'Enter'})
        Mock readListKey { $keys.Dequeue() }
        $calls = [System.Collections.Generic.List[object]]::new()
        $onKey = { param($item, $key) $calls.Add($key.Key); $false }

        pickFromList @('a', 'b') { param($i) $i } 'title' 0 $onKey

        $calls.Count | Should -Be 0
    }

    It "recomputes labels when onKey reports a mutation, so it shows before Enter" {
        $keys = [System.Collections.Generic.Queue[object]]::new()
        $keys.Enqueue([pscustomobject]@{Key = 'RightArrow'})
        $keys.Enqueue([pscustomobject]@{Key = 'Enter'})
        Mock readListKey { $keys.Dequeue() }
        $script:writes = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { param($Object) $script:writes.Add([string]$Object) }
        $item = [pscustomobject]@{ n = 0 }
        $onKey = { param($i, $k) $i.n += 1; $true }

        pickFromList @($item) { param($i) "n=$($i.n)" } 'title' 0 $onKey

        ($script:writes -join '|') | Should -Match 'n=1'
    }

    It "leaves labels alone when onKey reports no mutation" {
        $keys = [System.Collections.Generic.Queue[object]]::new()
        $keys.Enqueue([pscustomobject]@{Key = 'RightArrow'})
        $keys.Enqueue([pscustomobject]@{Key = 'Enter'})
        Mock readListKey { $keys.Dequeue() }
        $script:labelCalls = 0
        $onKey = { param($i, $k) $false }

        pickFromList @('a', 'b') { param($i) $script:labelCalls++; $i } 'title' 0 $onKey

        $script:labelCalls | Should -Be 2   # the up-front pass only
    }

    It "Escape returns null" {
        Mock readListKey { [pscustomobject]@{Key = 'Escape'} }

        pickFromList @('a', 'b') { param($i) $i } | Should -BeNullOrEmpty
    }

    It "truncates a label wider than the console instead of letting it wrap" {
        Mock getConsoleWidth { 10 }
        Mock readListKey { [pscustomobject]@{Key = 'Enter'} }
        $script:writes = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { param($Object) $script:writes.Add([string]$Object) }

        pickFromList @('0123456789012345') { param($i) $i }

        ($script:writes -join '|') | Should -Not -Match '0123456789012345'
        ($script:writes -join '|') | Should -Match '…'
    }

    It "Down then Up navigates, wrapping past the start" {
        $keys = [System.Collections.Generic.Queue[object]]::new()
        $keys.Enqueue([pscustomobject]@{Key = 'DownArrow'})
        $keys.Enqueue([pscustomobject]@{Key = 'UpArrow'})
        $keys.Enqueue([pscustomobject]@{Key = 'UpArrow'})   # wraps to the last item
        $keys.Enqueue([pscustomobject]@{Key = 'Enter'})
        Mock readListKey { $keys.Dequeue() }

        $result = pickFromList @('a', 'b') { param($i) $i }

        $result | Should -Be 1
    }

    It "Down past the last item wraps to the first" {
        $keys = [System.Collections.Generic.Queue[object]]::new()
        $keys.Enqueue([pscustomobject]@{Key = 'DownArrow'})
        $keys.Enqueue([pscustomobject]@{Key = 'DownArrow'})   # wraps to the first item
        $keys.Enqueue([pscustomobject]@{Key = 'Enter'})
        Mock readListKey { $keys.Dequeue() }

        pickFromList @('a', 'b') { param($i) $i } | Should -Be 0
    }
}

Describe "truncateLabel" {
    It "returns the label unchanged when it fits" {
        truncateLabel 'abc' 10 | Should -Be 'abc'
    }

    It "truncates and appends an ellipsis when over width, capped at the given width" {
        $r = truncateLabel '0123456789' 5
        $r        | Should -Be '0123…'
        $r.Length | Should -Be 5
    }

    It "hard-truncates with no room for an ellipsis when width is 1" {
        truncateLabel 'abcdef' 1 | Should -Be 'a'
    }

    It "returns an empty string when width is 0 or less" {
        truncateLabel 'abcdef' 0  | Should -Be ''
        truncateLabel 'abcdef' -1 | Should -Be ''
    }
}

Describe "buildRowFields" {
    It "splits a row into two lines: identity (name) on line 1, state/next-step on line 2" {
        $entry = [pscustomobject]@{planFile = 'C:/plans/a.md'; enterKind = 'fresh'; state = 'ready-to-refine'; nextStep = 'Step 9: the launch UI'}

        $f = buildRowFields $entry $false $false $false 10 200

        $f.nameField | Should -Match 'a\.md'
        $f.nameField | Should -Not -Match 'Step 9'
        $f.detail    | Should -Match 'refining'
        $f.detail    | Should -Match 'Step 9'
    }

    It "puts the cross-machine flag on its own field, kept off the name line" {
        $entry = [pscustomobject]@{planFile = 'C:/plans/a.md'; enterKind = 'fresh'; state = 'ready-to-refine'; nextStep = 'Step 1: x'}

        $f = buildRowFields $entry $false $false $true 50 200

        $f.nameField  | Should -Not -Match 'other-machine'
        $f.crossField | Should -Match 'other-machine'
    }

    It "leaves both lines unchanged when the row fits the console width" {
        $entry = [pscustomobject]@{planFile = 'C:/plans/a.md'; enterKind = 'fresh'; state = 'ready-to-refine'; nextStep = 'Step 1: x'}

        $f = buildRowFields $entry $false $false $false 10 200

        $f.nameField | Should -Match 'a\.md'
        $f.detail    | Should -Match 'Step 1'
        $f.detail    | Should -Not -Match '…'
    }

    It "truncates name and detail independently so each line stays within the width" {
        $entry = [pscustomobject]@{planFile = 'C:/plans/a-very-long-plan-file-name-indeed.md'; enterKind = 'fresh'; state = 'ready-to-implement'; nextStep = 'Step 42: another very long next step name'}

        $f = buildRowFields $entry $false $false $false 50 30

        # Line 1 = prefix(2) + status(8) + nameField; line 2 = indent(10) + detail.
        ($f.prefix.Length + $f.status.Length + $f.nameField.Length) | Should -BeLessOrEqual 30
        ($f.indent.Length + $f.detail.Length)                       | Should -BeLessOrEqual 30
        $f.nameField | Should -Match '…'
        $f.detail    | Should -Match '…'
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

        function newEntry([string] $planFile, [string[]] $sessionIds = @(), [string] $harness = 'claude') {
            return [pscustomobject]@{planFile = $planFile; cwd = "C:/de"; sessionIds = $sessionIds; harness = $harness; launches = 0; launchesFor = $null}
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
        Mock tryInvokeAgentModelList { $null }
        Mock pickFromList { return 0 }   # selects the sole fresh row by default now that fresh launches route through the picker too
        $script:launched = $null
        Mock launchCl {
            $script:launched = @{harness = $harness; cwd = $cwd; planFile = $planFile; rest = @($args)}
            return 0
        }
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
        $script:launched.rest     | Should -Contain "Please do the next step in $plan"
    }

    It "ready-to-refine + no sessions: fresh launch with the refine-the-next-step prompt" {
        $plan  = newPlan 'rtp' 'ready-to-refine'
        $entry = newEntry $plan
        $db    = newDb $entry

        openProject $db $entry @()

        $script:launched.rest     | Should -Contain "Please refine the next step in $plan"
    }

    It "ready-to-refine in step-review: the prompt asks for the implementation too" {
        # workflow is declared by hand — Set-PlanState carries the key but never writes it.
        $plan = "$script:plansRoot/rtp-sr.md"
        Set-Content $plan @("---", "current-unit:", "  first: `"Step 1: first`"", "  state: ready-to-refine",
                            "workflow: step-review", "---", "# rtp-sr", "", "## Step 1: first")
        $entry = newEntry $plan
        $db    = newDb $entry

        openProject $db $entry @()

        $script:launched.rest     | Should -Contain "Please refine (if needed) and implement the next step in $plan"
    }

    It "ready-for-user-review + no sessions: fresh launch with the review prompt" {
        $plan  = newPlan 'cc' 'ready-for-user-review'
        $entry = newEntry $plan
        $db    = newDb $entry

        openProject $db $entry @()

        $script:launched.rest | Should -Contain ('The plan, ' + $plan + ", is in ready-for-user-review state. Please read the plan, check you know where the recent context is, e.g. the last session and which commits in repos, then wait for the user's prompt.")
    }

    It "no frontmatter, but the file has steps: treated as ready-to-refine" {
        $plan  = newPlan 'bare' $null
        $entry = newEntry $plan
        $db    = newDb $entry

        openProject $db $entry @()

        $script:launched.rest     | Should -Contain "Please refine the next step in $plan"
    }

    It "fresh launch: updates cwd and saves db" {
        $entry = newEntry (newPlan 'cwd' 'ready-to-implement')
        $entry.cwd = "C:/old"
        $db    = newDb $entry

        openProject $db $entry @()

        $entry.cwd | Should -Be (normalizePath $PWD.Path)
        Should -Invoke saveDb -Times 1
    }

    It "legacy checkpointed plan: reads as an implement launch, writes the migrated state, keeps old sessions" {
        $plan  = newPlan 'ckpt' $null
        Set-Content $plan @("---", "current-unit:", "  first: `"Step 1: first`"", "  state: checkpointed", "---", "# ckpt", "", "## Step 1: first")
        $entry = newEntry $plan @("old-sid")
        $db    = newDb $entry
        Mock getSessionInfos { @(newInfo 'old-sid' (Get-Date)) }
        $script:pickerInitial = $null
        Mock pickFromList { $script:pickerInitial = $initialSelected; return 1 }   # the fresh row

        $result = openProject $db $entry @()

        $result                               | Should -BeTrue
        $script:pickerInitial                 | Should -Be 0        # no launch counted against this unit yet, so the most recent session is the default
        (Get-PlanState -PlanFile $plan).State | Should -Be 'ready-to-implement'
        $script:launched.rest                 | Should -Contain "Please do the next step in $plan"
        @($entry.sessionIds)                  | Should -Contain "old-sid"   # kept, alongside the new fresh session id
    }

    It "one resumable session: picker offers the session plus a start-fresh row" {
        $plan  = newPlan 'res1' 'ready-to-implement'
        $entry = newEntry $plan @("sid-1")
        $db    = newDb $entry
        Mock getSessionInfos { @(newInfo 'sid-1' (Get-Date)) }
        $script:pickerItems = $null
        Mock pickFromList { $script:pickerItems = $items; return 0 }

        $result = openProject $db $entry @()

        $result                     | Should -BeTrue
        @($script:pickerItems)      | Should -HaveCount 2
        $script:pickerItems[1].kind | Should -Be 'fresh'
        $script:launched.rest       | Should -Contain "--resume"
        $script:launched.rest       | Should -Contain "sid-1"
        @($entry.sessionIds)        | Should -Be @("sid-1")    # not clobbered
    }

    It "picking the start-fresh row launches fresh with the state's prompt" {
        $plan  = newPlan 'res-fresh-pick' 'ready-to-implement'
        $entry = newEntry $plan @("sid-1")
        $db    = newDb $entry
        Mock getSessionInfos { @(newInfo 'sid-1' (Get-Date)) }
        Mock pickFromList { return 1 }    # the fresh row (after 1 session)

        $result = openProject $db $entry @()

        $result                   | Should -BeTrue
        $script:launched.rest     | Should -Contain "Please do the next step in $plan"
        $script:launched.rest     | Should -Not -Contain "--resume"
        @($entry.sessionIds)      | Should -Contain "sid-1"   # kept, alongside the new fresh session id
    }

    It "default picker selection: the most recent session until a launch has worked on this unit" -TestCases @(
        @{ Launches = 0; ExpectedInitial = 0 }
        @{ Launches = 1; ExpectedInitial = 2 }   # after the 2 session rows
    ) {
        param($Launches, $ExpectedInitial)
        $plan  = newPlan "res-default-$Launches" 'ready-to-implement'
        $entry = newEntry $plan @("sid-1", "sid-2")
        $entry.launches = $Launches
        $db    = newDb $entry
        Mock getSessionInfos { @((newInfo 'sid-1' (Get-Date)), (newInfo 'sid-2' (Get-Date))) }
        $script:pickerInitial = $null
        Mock pickFromList { $script:pickerInitial = $initialSelected; return $null }

        $null = openProject $db $entry @()

        $script:pickerInitial | Should -Be $ExpectedInitial
    }

    It "counts the launch against the unit in the db entry, not the plan file" {
        $plan  = newPlan 'launch-count' 'ready-to-implement'
        $entry = newEntry $plan
        $db    = newDb $entry
        $planBefore = (Get-Content $plan -Raw)

        openProject $db $entry @()

        $entry.launches    | Should -Be 1
        (Get-Content $plan -Raw) | Should -Be $planBefore   # launching no longer rewrites the plan
        @($entry.sessionIds)  | Should -HaveCount 1   # one fresh session id, not one per getFreshSessionArgs call
    }

    It "counts a resume too — both paths spend a session on the unit" {
        $plan  = newPlan 'launch-count-resume' 'ready-to-implement'
        $entry = newEntry $plan @("sid-1")
        $db    = newDb $entry
        Mock getSessionInfos { @(newInfo 'sid-1' (Get-Date)) }
        Mock pickFromList { return 0 }   # the session row

        openProject $db $entry @()

        $script:launched.rest | Should -Contain "--resume"
        $entry.launches       | Should -Be 1
    }

    It "persists the launch count on a clean resume, so the increment outlives this process" {
        $plan  = newPlan 'launch-count-resume-save' 'ready-to-implement'
        $entry = newEntry $plan @("sid-1")
        $db    = newDb $entry
        Mock getSessionInfos { @(newInfo 'sid-1' (Get-Date)) }
        Mock pickFromList { return 0 }   # the session row

        openProject $db $entry @()

        $entry.launches | Should -Be 1
        Should -Invoke saveDb -Times 1
    }

    It "counts nothing when the picker is escaped out of" {
        $plan  = newPlan 'launch-count-escape' 'ready-to-implement'
        $entry = newEntry $plan
        $db    = newDb $entry
        Mock pickFromList { return $null }

        openProject $db $entry @()

        $entry.launches | Should -Be 0
        Should -Invoke launchCl -Times 0
    }

    It "resumes for ready-to-refine and ready-for-user-review too when sessions exist" -TestCases @(
        @{ State = 'ready-to-refine' }
        @{ State = 'ready-for-user-review' }
    ) {
        param($State)
        $plan  = newPlan "res-$State" $State
        $entry = newEntry $plan @("sid-1")
        $db    = newDb $entry
        Mock getSessionInfos { @(newInfo 'sid-1' (Get-Date)) }
        Mock pickFromList { return 0 }

        openProject $db $entry @()

        $script:launched.rest | Should -Contain "--resume"
    }

    It "multiple sessions: picker shows at most the 3 most recent plus start-fresh; picked one is resumed" {
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

        @($script:pickerItems) | Should -HaveCount 4
        @($script:pickerItems | Where-Object { $_.kind -eq 'session' }).info.sid | Should -Be @("sid-1", "sid-2", "sid-3")
        $script:launched.rest  | Should -Contain "sid-2"
        @($entry.sessionIds)   | Should -HaveCount 4    # not clobbered
    }

    It "picker title identifies the plan (filename and plan title)" {
        $plan  = newPlan 'titled' 'ready-to-implement'
        $entry = newEntry $plan @("sid-1")
        $db    = newDb $entry
        Mock getSessionInfos { @(newInfo 'sid-1' (Get-Date)) }
        $script:pickerTitle = $null
        Mock pickFromList { $script:pickerTitle = $title; return $null }

        $null = openProject $db $entry @()

        $script:pickerTitle | Should -Match ([regex]::Escape((Split-Path $plan -Leaf)))
        $script:pickerTitle | Should -Match 'titled'
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

        $script:launched.rest     | Should -Contain "Please do the next step in $plan"
    }

    It "resume refused (the session log never moved): removes only the failed sid, keeps the rest, returns true" {
        $plan  = newPlan 'res-fail' 'ready-to-implement'
        $entry = newEntry $plan @("sid-1", "sid-2")
        $db    = newDb $entry
        Mock getSessionInfos { @(newInfo 'sid-1' (Get-Date).AddMinutes(-5)) }
        Mock pickFromList { return 0 }
        Mock launchCl { return 1 }

        $result = openProject $db $entry @()

        $result              | Should -BeTrue
        @($entry.sessionIds) | Should -Be @("sid-2")
        Should -Invoke saveDb -Times 1
    }

    # The session worth resuming is exactly the one that ran for a while and then died, so a non-zero
    # exit alone must not cost it its place in the plan.
    It "resume that ran and then failed: keeps the sid" {
        $plan  = newPlan 'res-ran-then-failed' 'ready-to-implement'
        $entry = newEntry $plan @("sid-1", "sid-2")
        $db    = newDb $entry
        Mock getSessionInfos { @(newInfo 'sid-1' (Get-Date).AddMinutes(1)) }
        Mock pickFromList { return 0 }
        Mock launchCl { return 1 }

        $result = openProject $db $entry @()

        $result              | Should -BeTrue
        @($entry.sessionIds) | Should -Be @("sid-1", "sid-2")
    }

    It "fresh launch failure still returns true (TUI refreshes)" {
        $entry = newEntry (newPlan 'fresh-fail' 'ready-to-implement')
        $db    = newDb $entry
        Mock launchCl { return 1 }

        $result = openProject $db $entry @()

        $result | Should -BeTrue
    }

    It "fresh launch: passes the entry's harness through to launchCl" {
        $entry = newEntry (newPlan 'harness-fresh' 'ready-to-implement') @() 'copilot'
        $db    = newDb $entry

        openProject $db $entry @()

        $script:launched.harness | Should -Be 'copilot'
    }

    It "copilot harness resume: uses the combined --resume=<id> arg" {
        $plan  = newPlan 'res-copilot' 'ready-to-implement'
        $entry = newEntry $plan @("sid-1") 'copilot'
        $db    = newDb $entry
        Mock getSessionInfos { @(newInfo 'sid-1' (Get-Date)) }
        Mock pickFromList { return 0 }

        openProject $db $entry @()

        $script:launched.harness  | Should -Be 'copilot'
        $script:launched.rest     | Should -Contain "--resume=sid-1"
    }

    It "claude harness resume: uses the space-separated --resume <id> args" {
        $plan  = newPlan 'res-claude' 'ready-to-implement'
        $entry = newEntry $plan @("sid-1") 'claude'
        $db    = newDb $entry
        Mock getSessionInfos { @(newInfo 'sid-1' (Get-Date)) }
        Mock pickFromList { return 0 }

        openProject $db $entry @()

        $script:launched.rest     | Should -Contain "--resume"
        $script:launched.rest     | Should -Contain "sid-1"
    }

    It "no sessions: routes through the picker with a single fresh row (not a direct launch)" {
        $plan  = newPlan 'fresh-picker' 'ready-to-implement'
        $entry = newEntry $plan
        $db    = newDb $entry
        $script:pickerItems = $null
        Mock pickFromList { $script:pickerItems = $items; return 0 }

        $result = openProject $db $entry @()

        $result                     | Should -BeTrue
        @($script:pickerItems)      | Should -HaveCount 1
        $script:pickerItems[0].kind | Should -Be 'fresh'
    }

    It "the fresh row carries the entry and db, so the picker's key handler can persist workflow and harness" {
        $plan  = newPlan 'fresh-carries' 'ready-to-implement'
        $entry = newEntry $plan @() 'other'
        $db    = newDb $entry
        Mock getAgentHarnesses { @(@{ name = 'customtool'; pickerKey = 'C' }, @{ name = 'other'; pickerKey = 'O' }) }
        $script:pickerItems = $null
        Mock pickFromList { $script:pickerItems = $items; return 0 }

        openProject $db $entry @()

        $row = $script:pickerItems[0]
        $row.entry | Should -Be $entry
        $row.db    | Should -Be $db
        @($row.workflowList) | Should -Be @('tick-tock', 'step-review', 'branch-review')
        $row.workflowIndex   | Should -Be 0   # absent workflow counts as tick-tock
        @($row.harnessList)  | Should -Be @('customtool', 'other')
        # Non-zero index: a missing IndexOf (leaving $null, which the guard would mask to 0) must fail this.
        $row.harnessIndex    | Should -Be 1
    }

    It "fresh row exposes a cost-sorted model list starting at <default> when the harness has one" {
        $plan  = newPlan 'model-list' 'ready-to-implement'
        $entry = newEntry $plan
        $db    = newDb $entry
        Mock tryInvokeAgentModelList { @{ claude = @{
            small = @{ displayName = 'Haiku'; model = 'Haiku'; relativeCost = 1 }
            large = @{ displayName = 'Opus';  model = 'Opus';  relativeCost = 5 }
        } } }
        $script:pickerItems = $null
        Mock pickFromList { $script:pickerItems = $items; return 0 }

        openProject $db $entry @()

        $freshRow = $script:pickerItems[0]
        @($freshRow.modelList.displayName) | Should -Be @('Haiku', 'Opus', '<default>')
        $freshRow.modelIndex               | Should -Be 2
    }

    It "fresh row carries the entry's harness, so the label can name it" {
        $plan  = newPlan 'harness-label' 'ready-to-implement'
        $entry = newEntry $plan @() 'copilot'
        $db    = newDb $entry
        $script:pickerItems = $null
        Mock pickFromList { $script:pickerItems = $items; return 0 }

        openProject $db $entry @()

        $script:pickerItems[0].harness | Should -Be 'copilot'
    }

    It "picking a non-default model passes --model through to launchCl before the prompt" {
        $plan  = newPlan 'model-pick' 'ready-to-implement'
        $entry = newEntry $plan
        $db    = newDb $entry
        Mock tryInvokeAgentModelList { @{ claude = @{
            large = @{ displayName = 'Opus'; model = 'Opus'; relativeCost = 5 }
        } } }
        Mock pickFromList {
            $items[0].modelIndex = 0   # cycle away from <default> to Opus
            return 0
        }

        openProject $db $entry @()

        $script:launched.rest[0]  | Should -Be '--model'
        $script:launched.rest[1]  | Should -Be 'Opus'
        $script:launched.rest     | Should -Contain "Please do the next step in $plan"
    }

    It "picking the default model row omits --model" {
        $plan  = newPlan 'model-default' 'ready-to-implement'
        $entry = newEntry $plan
        $db    = newDb $entry
        Mock tryInvokeAgentModelList { @{ claude = @{
            large = @{ displayName = 'Opus'; model = 'Opus'; relativeCost = 5 }
        } } }
        Mock pickFromList { return 0 }   # default initial selection is <default>

        openProject $db $entry @()

        $script:launched.rest     | Should -Contain "Please do the next step in $plan"
        $script:launched.rest     | Should -Not -Contain '--model'
    }

    It "session rows never carry a model field" {
        $plan  = newPlan 'model-resume' 'ready-to-implement'
        $entry = newEntry $plan @("sid-1")
        $db    = newDb $entry
        Mock getSessionInfos { @(newInfo 'sid-1' (Get-Date)) }
        Mock tryInvokeAgentModelList { @{ claude = @{ large = @{ displayName = 'Opus'; model = 'Opus'; relativeCost = 5 } } } }
        $script:pickerItems = $null
        Mock pickFromList { $script:pickerItems = $items; return 0 }

        openProject $db $entry @()

        $script:pickerItems[0].kind                     | Should -Be 'session'
        $script:pickerItems[0].ContainsKey('modelList') | Should -BeFalse
    }

    It "harness with no model list: fresh row has no model field and no --model arg" {
        $plan  = newPlan 'model-none' 'ready-to-implement'
        $entry = newEntry $plan
        $db    = newDb $entry
        $script:pickerItems = $null
        Mock pickFromList { $script:pickerItems = $items; return 0 }

        openProject $db $entry @()

        $script:pickerItems[0].ContainsKey('modelList') | Should -BeFalse
        $script:launched.rest     | Should -Contain "Please do the next step in $plan"
    }

    It "fresh row phase label names what Enter will launch" {
        $plan  = newPlan 'phase-default' 'ready-to-implement'
        $entry = newEntry $plan
        $db    = newDb $entry
        $script:pickerItems = $null
        Mock pickFromList { $script:pickerItems = $items; return 0 }

        openProject $db $entry @()

        $script:pickerItems[0].phaseLabel | Should -Be 'implement · tick-tock'
    }

    It "the phase label includes the next-step pointer and the declared workflow, when set" {
        $plan = "$script:plansRoot/phase-full.md"
        Set-Content $plan @("---", "current-unit:", "  first: `"Step 1: first`"", "  state: ready-to-implement",
                            "workflow: branch-review", "---", "# phase-full", "", "## Step 1: first")
        $entry = newEntry $plan
        $db    = newDb $entry
        $script:pickerItems = $null
        Mock pickFromList { $script:pickerItems = $items; return 0 }

        openProject $db $entry @()

        $script:pickerItems[0].phaseLabel | Should -Be 'implement Step 1: first · branch-review'
    }

    It "a skeleton with no steps: the plan intent, because there is no next step to refine" {
        $plan = "$script:plansRoot/skeleton.md"
        Set-Content $plan @("# skeleton", "", "notes, no steps yet")
        $entry = newEntry $plan
        $db    = newDb $entry

        openProject $db $entry @()

        $script:launched.rest | Should -Contain "Please work out what the steps should be in $plan"
    }

    It "hands the picker a label function and a key handler wired to the fresh row" {
        $plan  = newPlan 'picker-wiring' 'ready-to-implement'
        $entry = newEntry $plan
        $db    = newDb $entry
        $script:pickerItems   = $null
        $script:pickerLabelFn = $null
        $script:pickerOnKey   = $null
        Mock pickFromList {
            $script:pickerItems   = $items
            $script:pickerLabelFn = $labelFn
            $script:pickerOnKey   = $onKey
            return 0
        }

        openProject $db $entry @()

        $freshRow = $script:pickerItems[0]
        (& $script:pickerLabelFn $freshRow) | Should -Match 'implement'
        (& $script:pickerOnKey $freshRow ([pscustomobject]@{Key = 'X'})) | Should -BeFalse
    }

    It "P key: fresh launch always offers the plan prompt, regardless of state" {
        $plan  = newPlan 'p-key' 'ready-to-implement'
        $entry = newEntry $plan
        $db    = newDb $entry

        openProject $db $entry @() 'P'

        $script:launched.rest | Should -Contain "Please work out what the steps should be in $plan"
    }

    It "P key: still offers to resume when sessions exist, like Enter" {
        $plan  = newPlan 'p-key-resume' 'ready-to-implement'
        $entry = newEntry $plan @("sid-1")
        $db    = newDb $entry
        Mock getSessionInfos { @(newInfo 'sid-1' (Get-Date)) }
        Mock pickFromList { return 0 }   # the session row

        openProject $db $entry @() 'P'

        $script:launched.rest | Should -Contain "--resume"
    }

    It "D key: fresh launch always offers the discuss prompt, regardless of state" {
        $plan  = newPlan 'd-key' 'ready-to-implement'
        $entry = newEntry $plan
        $db    = newDb $entry

        openProject $db $entry @() 'D'

        $script:launched.rest | Should -Contain "Let's discuss the plan, $plan. Please read it and then wait for my questions"
    }

    It "D key: never resumes, even when sessions exist - it's a way to talk, not to continue the work" {
        $plan  = newPlan 'd-key-no-resume' 'ready-to-implement'
        $entry = newEntry $plan @("sid-1")
        $db    = newDb $entry
        Mock getSessionInfos { @(newInfo 'sid-1' (Get-Date)) }
        $script:pickerItems = $null
        Mock pickFromList { $script:pickerItems = $items; return 0 }

        openProject $db $entry @() 'D'

        @($script:pickerItems)      | Should -HaveCount 1
        $script:pickerItems[0].kind | Should -Be 'fresh'
        $script:launched.rest       | Should -Not -Contain "--resume"
    }

    It "branch-review + headless-capable harness: Enter's fresh dispatch hands off to the run instead of a single launch" {
        $plan = "$script:plansRoot/br-loop.md"
        Set-Content $plan @('---', 'current-unit:', '  first: "Step 1: first"', '  state: ready-to-implement',
                             'workflow: branch-review', 'automatable: *', '---', '# br-loop', '', '## Step 1: first')
        $entry = newEntry $plan
        $db    = newDb $entry
        Mock getHarnessDescriptor { @{ name = 'claude'; headlessFlag = '--x' } }
        $script:ranLoop = $false
        Mock runBranchReviewRun { $script:ranLoop = $true }

        $result = openProject $db $entry @()

        $result           | Should -BeTrue
        $script:ranLoop   | Should -BeTrue
        Should -Invoke launchCl -Times 0
    }

    It "branch-review but the harness declares no headless flag: single launch as usual" {
        $plan = "$script:plansRoot/br-noloop.md"
        Set-Content $plan @('---', 'current-unit:', '  first: "Step 1: first"', '  state: ready-to-implement',
                             'workflow: branch-review', 'automatable: *', '---', '# br-noloop', '', '## Step 1: first')
        $entry = newEntry $plan
        $db    = newDb $entry
        Mock getHarnessDescriptor { @{ name = 'claude' } }

        openProject $db $entry @()

        $script:launched.rest | Should -Contain "Please do the next step in $plan"
    }

    It "branch-review + headless-capable harness but the step is not automatable: single launch, not a run" {
        # An absent `automatable` field means nothing is automatable — Enter hand-holds one design
        # step interactively instead of refusing or spinning up an unattended run.
        $plan = "$script:plansRoot/br-noauto.md"
        Set-Content $plan @('---', 'current-unit:', '  first: "Step 1: first"', '  state: ready-to-implement',
                             'workflow: branch-review', '---', '# br-noauto', '', '## Step 1: first')
        $entry = newEntry $plan
        $db    = newDb $entry
        Mock getHarnessDescriptor { @{ name = 'claude'; headlessFlag = '--x' } }
        $script:ranLoop = $false
        Mock runBranchReviewRun { $script:ranLoop = $true }

        $result = openProject $db $entry @()

        $result           | Should -BeTrue
        $script:ranLoop   | Should -BeFalse
        Should -Invoke launchCl -Times 1
    }

    It "clears the run report once a row is picked, whatever it launches" {
        $plan  = newPlan 'clear-report' 'ready-to-implement'
        $entry = newEntry $plan
        $db    = newDb $entry
        $script:reportCleared = $false
        Mock clearRunReport { $script:reportCleared = $true }

        openProject $db $entry @()

        $script:reportCleared | Should -BeTrue
    }
}

Describe "parseAutomatableSteps" {
    It "returns null for an absent value" {
        parseAutomatableSteps $null | Should -BeNullOrEmpty
    }

    It "returns true for a star" {
        parseAutomatableSteps '*' | Should -BeTrue
    }

    It "expands a range" {
        @((parseAutomatableSteps '16-19') | Sort-Object) | Should -Be @(16,17,18,19)
    }

    It "parses a list of numbers" {
        @((parseAutomatableSteps '16, 19') | Sort-Object) | Should -Be @(16,19)
    }

    It "expands a mixed range-and-number list" {
        @((parseAutomatableSteps '16-19, 21') | Sort-Object) | Should -Be @(16,17,18,19,21)
    }

    It "expands a single-element range to one number" {
        @(parseAutomatableSteps '16-16') | Should -Be @(16)
    }
}

Describe "stepIsAutomatable" {
    It "false when the field is absent" {
        stepIsAutomatable $null 'Step 1: a' | Should -BeFalse
    }

    It "true for a star, whatever the step" {
        stepIsAutomatable '*' 'Step 99: z' | Should -BeTrue
    }

    It "true when the step number is in the set" {
        stepIsAutomatable '16-19' 'Step 17: b' | Should -BeTrue
    }

    It "false when the step number is outside the set" {
        stepIsAutomatable '16-19' 'Step 20: b' | Should -BeFalse
    }

    It "false for a heading with no Step N prefix, under a specific set" {
        stepIsAutomatable '16-19' 'No number here' | Should -BeFalse
    }
}

Describe "isBranchReviewLoopable" {
    BeforeEach {
        Mock getHarnessDescriptor { @{ name = 'myharness'; headlessFlag = '--headless' } }
    }

    It "true for a fresh branch-review dispatch into refine, on a headless-capable harness" {
        isBranchReviewLoopable 'branch-review' 'refine' 'myharness' '*' 'Step 1: a' | Should -BeTrue
    }

    It "true for implement too" {
        isBranchReviewLoopable 'branch-review' 'implement' 'myharness' '16-19' 'Step 17: b' | Should -BeTrue
    }

    It "false outside branch-review" {
        isBranchReviewLoopable 'step-review' 'implement' 'myharness' '*' 'Step 1: a' | Should -BeFalse
    }

    It "false for the plan/review phases — P and D fix those regardless of workflow" {
        isBranchReviewLoopable 'branch-review' 'plan'   'myharness' '*' 'Step 1: a' | Should -BeFalse
        isBranchReviewLoopable 'branch-review' 'review' 'myharness' '*' 'Step 1: a' | Should -BeFalse
    }

    It "false for a harness with no headless flag" {
        Mock getHarnessDescriptor { @{ name = 'claude' } }
        isBranchReviewLoopable 'branch-review' 'implement' 'claude' '*' 'Step 1: a' | Should -BeFalse
    }

    It "false when the current step is not automatable" {
        isBranchReviewLoopable 'branch-review' 'implement' 'myharness' '16-19' 'Step 20: c' | Should -BeFalse
    }

    It "false when the field is absent — nothing is automatable" {
        isBranchReviewLoopable 'branch-review' 'implement' 'myharness' $null 'Step 1: a' | Should -BeFalse
    }
}

Describe "planFrontmatterProgressed" {
    BeforeAll {
        function newState([hashtable] $overrides = @{}) {
            $base = @{ State = 'ready-to-implement'; First = 'Step 1: a'; Last = 'Step 1: a'
                       Workflow = 'branch-review'; CommitBranch = 'feature'; Refined = @(); CommitRepos = @() }
            foreach ($k in $overrides.Keys) { $base[$k] = $overrides[$k] }
            return [pscustomobject] $base
        }
    }

    It "false when nothing changed" {
        $a = newState
        $b = newState
        planFrontmatterProgressed $a $b | Should -BeFalse
    }

    It "true when the pointer moved" {
        $a = newState
        $b = newState @{ First = 'Step 2: b'; Last = 'Step 2: b' }
        planFrontmatterProgressed $a $b | Should -BeTrue
    }

    It "true when the state changed with the pointer held" {
        $a = newState @{ State = 'ready-to-refine' }
        $b = newState @{ State = 'ready-to-implement' }
        planFrontmatterProgressed $a $b | Should -BeTrue
    }

    It "true when the refined list changed" {
        $a = newState @{ Refined = @() }
        $b = newState @{ Refined = @('Step 2: b') }
        planFrontmatterProgressed $a $b | Should -BeTrue
    }

    It "true when a step closed even though the pointer moved — the wrap's own signal" {
        $a = newState @{ StepHeadings = @('Step 1: a','Step 2: b') }
        $b = newState @{ First = 'Step 2: b'; Last = 'Step 2: b'; StepHeadings = @('Step 2: b') }
        planFrontmatterProgressed $a $b | Should -BeTrue
    }
}

Describe "getStepsClosedByRun" {
    It "lists the steps that left the plan between two reads" {
        @(getStepsClosedByRun @('Step 1: a','Step 2: b','Step 3: c') @('Step 3: c')) |
            Should -Be @('Step 1: a','Step 2: b')
    }

    It "empty when nothing closed" {
        @(getStepsClosedByRun @('Step 1: a','Step 2: b') @('Step 1: a','Step 2: b')) | Should -Be @()
    }

    It "lists every step when the run closed the whole plan" {
        @(getStepsClosedByRun @('Step 1: a','Step 2: b') @()) |
            Should -Be @('Step 1: a','Step 2: b')
    }

    It "empty when the run closed nothing because the plan was already gone" {
        @(getStepsClosedByRun @() @()) | Should -Be @()
    }

    It "matches step ids, not exact headings" {
        @(getStepsClosedByRun @('Step 1: a','Step 2: b') @('Step 2: b')) |
            Should -Be @('Step 1: a')
    }

    It "ignores a step that was re-added (not a close)" {
        @(getStepsClosedByRun @('Step 1: a','Step 2: b') @('Step 2: b','Step 1: a')) | Should -Be @()
    }
}

Describe "getSessionFinalText" {
    BeforeAll {
        $script:logRoot = ((New-Item -ItemType Directory "TestDrive:\session-logs").FullName -replace '\\', '/').TrimEnd('/')
    }

    It "returns the last assistant_text content" {
        $p = "$script:logRoot/a.jsonl"
        Set-Content $p (@(
            '{"type":"user_message","content":"hi"}',
            '{"type":"assistant_text","content":"first"}',
            '{"type":"assistant_thinking","content":"..."}',
            '{"type":"assistant_text","content":"done"}'
        ))
        getSessionFinalText $p | Should -Be 'done'
    }

    It "returns null when there is no log file" {
        getSessionFinalText "$script:logRoot/nope.jsonl" | Should -BeNullOrEmpty
    }

    It "returns null for a log with no assistant_text" {
        $p = "$script:logRoot/none.jsonl"
        Set-Content $p (@( '{"type":"user_message","content":"hi"}' ))
        getSessionFinalText $p | Should -BeNullOrEmpty
    }
}

Describe "getPreflightStopReason" {
    It "stops when the plan file is gone" {
        getPreflightStopReason $false $true 'implement' 0 0.0 | Should -Match 'plan finished'
    }

    It "distinguishes a finished plan from the review checkpoint: a plan with no steps left is done" {
        getPreflightStopReason $true $false 'implement' 0 0.0 | Should -Match 'plan finished'
    }

    It "stops at the review checkpoint when steps still remain — that is the user's checkpoint, not the end" {
        getPreflightStopReason $true $true 'review' 0 0.0 | Should -Match 'review'
    }

    It "stops at the 50-launch budget" {
        getPreflightStopReason $true $true 'implement' 50 0.0 | Should -Match '50-launch'
    }

    It "stops at the 12-hour budget" {
        getPreflightStopReason $true $true 'implement' 0 12.0 | Should -Match '12-hour'
    }

    It "null when none of the above" {
        getPreflightStopReason $true $true 'implement' 49 11.9 | Should -BeNullOrEmpty
    }
}

Describe "getPostflightStopReason" {
    It "stops on a non-zero exit code" {
        getPostflightStopReason 1 $true | Should -Match 'exited with code 1'
    }

    It "stops when the step made no progress" {
        getPostflightStopReason 0 $false | Should -Match 'no progress'
    }

    It "null when the step succeeded and progress was made" {
        getPostflightStopReason 0 $true | Should -BeNullOrEmpty
    }

    It "a non-zero exit outranks a stalled read — the crash is the more useful reason" {
        getPostflightStopReason 1 $false | Should -Match 'exited with code 1'
    }

    It "names the timed-out session and outranks both a crash and a stall" {
        $code = getLaunchTimeoutCode
        $reason = getPostflightStopReason $code $false 'sid-timed' $code
        $reason | Should -Match 'timed out'
        $reason | Should -Match 'sid-timed'
    }

    It "treats a real exit code as a crash, not a timeout, when the sentinel is not the code" {
        # the sentinel is only a timeout when it is the timeout code — a normal crash is not
        $reason = getPostflightStopReason 1 $true 'sid-x' (getLaunchTimeoutCode)
        $reason | Should -Match 'exited with code 1'
    }
}
Describe "launch timeout config" {
    It "caps an unattended launch at the per-launch budget and leaves an interactive one uncapped" {
        getLaunchTimeoutSeconds -Unattended | Should -Be (3 * 60 * 60)
        getLaunchTimeoutSeconds        | Should -Be 0
    }

    It "the timeout code is distinct from any exit code a child can carry" {
        # a child's exit code is 0..65535, or 1 from a launch that never started; the sentinel must
        # sit outside that range so the loop can tell a kill-for-timeout apart from a real crash
        $code = getLaunchTimeoutCode
        $code | Should -BeLessThan 0
        $code | Should -BeGreaterOrEqual -2147483648
    }
}

Describe "waitLaunchProcess" {
    It "returns the child's real exit code when it exits before the cap" {
        $proc = Start-Process pwsh -ArgumentList '-NoLogo','-NoProfile','-c','exit 7' -PassThru -NoNewWindow
        $code = waitLaunchProcess $proc 30
        $code | Should -Be 7
        $proc.HasExited | Should -BeTrue
    }

    It "waits for a normal exit when the cap is unset (an interactive launch)" {
        $proc = Start-Process pwsh -ArgumentList '-NoLogo','-NoProfile','-c','exit 3' -PassThru -NoNewWindow
        $code = waitLaunchProcess $proc 0
        $code | Should -Be 3
    }

    It "returns the timeout sentinel and kills the launched tree when the child outlives the cap" {
        # A grandchild writes a marker only after its own short sleep — if the tree-kill fails to
        # reach it, the marker appears once that sleep elapses, so its absence proves the kill was
        # a tree-kill, not just a kill of the direct child.
        $id     = [guid]::NewGuid().ToString('N')
        $tdir   = ((Get-Item "TestDrive:\").FullName -replace '\\', '/').TrimEnd('/')
        $marker = "$tdir/gd-$id.txt"
        $grand  = "$tdir/gd-$id.ps1"; Set-Content $grand "Start-Sleep 4; Set-Content '$marker' 'done'"
        $child  = "$tdir/ch-$id.ps1"; Set-Content $child "Start-Process pwsh -ArgumentList '-NoLogo','-NoProfile','-File','$grand' -NoNewWindow | Out-Null; Start-Sleep 30"
        $proc = Start-Process pwsh -ArgumentList '-NoLogo','-NoProfile','-File',$child -PassThru -NoNewWindow
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $code = waitLaunchProcess $proc 2
        $sw.Stop()

        $code | Should -Be (getLaunchTimeoutCode)
        $proc.HasExited | Should -BeTrue
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 25   # bounded by the cap, not the 30s child
        Start-Sleep 4   # past the grandchild's 4s sleep; a surviving grandchild would have written
        (Test-Path $marker) | Should -BeFalse
    }
}
Describe "run report round-trip" {
    BeforeEach {
        $script:reportPath = "TestDrive:\report-$([guid]::NewGuid().ToString('N')).json"
    }

    It "reads back what was written" {
        $report = newRunReport 'C:/plans/foo.md' @('Step 1: a','Step 2: b') 'hit the 50-launch budget' 'sid-9'
        writeRunReport $report $script:reportPath

        $read = readRunReport $script:reportPath

        $read.planFile      | Should -Be 'C:/plans/foo.md'
        @($read.stepsClosed) | Should -Be @('Step 1: a','Step 2: b')
        $read.stopReason     | Should -Be 'hit the 50-launch budget'
        $read.lastSessionId  | Should -Be 'sid-9'
    }

    It "null when no report file exists" {
        readRunReport $script:reportPath | Should -BeNullOrEmpty
    }

    It "clearRunReport removes it" {
        writeRunReport (newRunReport 'C:/plans/foo.md' 1 'stopped' 'sid-1') $script:reportPath
        clearRunReport $script:reportPath
        readRunReport $script:reportPath | Should -BeNullOrEmpty
    }

    It "clearRunReport is a no-op when nothing is there" {
        { clearRunReport $script:reportPath } | Should -Not -Throw
    }
}

Describe "getRunReportLines" {
    It "empty for no report" {
        @(getRunReportLines $null) | Should -HaveCount 0
    }

    It "names the plan, the closed steps, the stop reason and the last session" {
        $report = newRunReport 'C:/plans/foo.md' @('Step 1: a','Step 2: b') 'hit the 50-launch budget' 'sid-9'
        $lines  = (getRunReportLines $report) -join "`n"

        $lines | Should -Match 'foo\.md'
        $lines | Should -Match 'closed Step 1, Step 2'
        $lines | Should -Match 'hit the 50-launch budget'
        $lines | Should -Match 'sid-9'
    }

    It "says 'no steps closed' when the run closed none" {
        $report = newRunReport 'C:/plans/foo.md' @() 'hit the 50-launch budget' 'sid-9'
        (getRunReportLines $report) -join "`n" | Should -Match 'no steps closed'
    }

    It "names a single closed step by number only" {
        $report = newRunReport 'C:/plans/foo.md' @('Step 4: do the thing') 'stopped' 'sid-1'
        (getRunReportLines $report) -join "`n" | Should -Match 'closed Step 4'
    }

    It "renders a report that predates the steps-closed field as 'no steps closed'" {
        # a report written by an older pl has no stepsClosed property at all
        $report = [pscustomobject]@{ planFile = 'C:/plans/foo.md'; stopReason = 'stopped'; lastSessionId = 'sid-1' }
        (getRunReportLines $report) -join "`n" | Should -Match 'no steps closed'
    }

    It "shows the session's final text when the report carries it" {
        $report = newRunReport -planFile 'C:/plans/foo.md' -stepsClosed @() -stopReason 'stopped' -lastSessionId 'sid-1' -sessionFinalText 'the step hit a rate limit'
        (getRunReportLines $report) -join "`n" | Should -Match 'the step hit a rate limit'
    }

    It "renders a finished plan's stop reason as completion, not a stall" {
        # a run that closed its last step stops on 'the plan finished' — the report must read as
        # done, with the last step named, rather than as 'no steps closed' or a no-progress stall.
        $report = newRunReport 'C:/plans/foo.md' @('Step 3: final') 'the plan finished' 'sid-7'
        $lines  = (getRunReportLines $report) -join "`n"

        $lines | Should -Match 'closed Step 3'
        $lines | Should -Match 'the plan finished'
        $lines | Should -Not -Match 'no steps closed'
    }

    It "keeps each closed step's full number in the lead" {
        # a variable-length lookbehind anchored the strip after the first digit, collapsing
        # 'Step 22' / 'Step 23' both to 'Step 2' — the report read 'closed Step 2, Step 2'.
        $report = newRunReport 'C:/plans/foo.md' @('Step 22: pl slowness','Step 23: accumulated nits') 'stopped' 'sid-1'
        (getRunReportLines $report) -join "`n" | Should -Match 'closed Step 22, Step 23'
    }

    It "shows the session's final text only when the run closed no steps" {
        # a run that closed steps has a commit to read for the detail; the closing message is only
        # the record when nothing was committed, so the line is gated on stepsClosed being empty.
        $report = newRunReport 'C:/plans/foo.md' @('Step 22: pl slowness') 'stopped' 'sid-1' 'the step hit a rate limit'
        (getRunReportLines $report) -join "`n" | Should -Not -Match 'the step hit a rate limit'
    }
}

Describe "sendRunNotification" {
    BeforeEach {
        function Send-UserNotification { param($Message, $Category) }
        Mock Send-UserNotification { }
    }

    It "does nothing when Send-UserNotification isn't available" {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Send-UserNotification' }
        { sendRunNotification (newRunReport 'C:/p.md' @('Step 1: a') 'stopped' 'sid-1') } | Should -Not -Throw
        Should -Invoke Send-UserNotification -Times 0
    }

    It "sends one notification naming the plan, the closed steps and the stop reason" {
        sendRunNotification (newRunReport 'C:/plans/foo.md' @('Step 1: a','Step 2: b') 'hit the 50-launch budget' 'sid-9')

        Should -Invoke Send-UserNotification -Times 1 -ParameterFilter {
            $Message -like '*foo.md*' -and $Message -like '*closed Step 1, Step 2*' -and $Message -like '*50-launch budget*'
        }
    }
}

Describe "runBranchReviewRun" {
    BeforeAll {
        $script:runRoot = ((New-Item -ItemType Directory "TestDrive:\branch-review-run").FullName -replace '\\', '/').TrimEnd('/')

        function newRunPlan([string] $name, [string[]] $stepNames) {
            $path = "$script:runRoot/$name.md"
            $headings = $stepNames | ForEach-Object { "## $_" }
            Set-Content $path (@('---', 'current-unit:', "  first: `"$($stepNames[0])`"", '  state: ready-to-implement',
                                  'workflow: branch-review', 'automatable: *', '---', "# $name", '') + $headings)
            return $path
        }

        function newRunEntry([string] $planFile) {
            return [pscustomobject]@{ planFile = $planFile; cwd = 'C:/de'; sessionIds = @(); harness = 'myharness'; launches = 0; launchesFor = $null }
        }

        # Mimics /wrap's close: cut the step's body from the plan, then advance the pointer past it.
        # The report derives "steps closed" from which step headings leave the plan, so a mock that
        # only advances the pointer would close nothing and the run report would read empty.
        function closeStep([string] $plan, [string] $stepName) {
            $lines = Get-Content $plan | Where-Object { $_ -ne "## $stepName" }
            Set-Content $plan $lines
            $null = Set-PlanState -PlanFile $plan -Advance
        }
    }

    BeforeEach {
        Mock saveDb { }
        Mock writeRunReport { $script:capturedReport = $report }
        Mock sendRunNotification { $script:notifiedReport = $report }
        Mock getHarnessDescriptor { @{ name = 'myharness'; headlessFlag = '--headless' } }
        Mock commitGrantRefusedReason { $null }   # these plans declare no grant; let them proceed
        $script:capturedReport  = $null
        $script:notifiedReport  = $null
    }

    It "stops before launching when the plan is already gone, closing nothing" {
        $plan  = newRunPlan 'alreadygone' @('Step 1: a')
        Remove-Item -LiteralPath $plan
        $entry = newRunEntry $plan
        $db    = [System.Collections.Generic.List[object]]::new(); $db.Add($entry)
        Mock launchCl { throw 'should not launch' }

        runBranchReviewRun $db $entry @()

        Should -Invoke launchCl -Times 0
        @($script:capturedReport.stepsClosed) | Should -Be @()
        $script:capturedReport.stopReason     | Should -Match 'plan finished'
    }

    It "advances the plan one step per launch, stopping when the plan finishes" {
        $plan  = newRunPlan 'threestep' @('Step 1: a', 'Step 2: b', 'Step 3: c')
        $entry = newRunEntry $plan
        $db    = [System.Collections.Generic.List[object]]::new(); $db.Add($entry)
        $script:launchCount = 0
        Mock launchCl {
            $script:launchCount++
            $state = Get-PlanState -PlanFile $planFile
            if ($state.First -eq 'Step 3: c') { Remove-Item -LiteralPath $planFile } else { closeStep $planFile $state.First }
            return 0
        }

        runBranchReviewRun $db $entry @()

        $script:launchCount                | Should -Be 3
        @($script:capturedReport.stepsClosed) | Should -Be @('Step 1: a','Step 2: b','Step 3: c')
        $script:capturedReport.stopReason  | Should -Match 'plan finished'
        Should -Invoke sendRunNotification -Times 1
    }

    It "reports every step a launch closed, not the launch count" {
        $plan  = newRunPlan 'batched' @('Step 1: a', 'Step 2: b')
        $entry = newRunEntry $plan
        $db    = [System.Collections.Generic.List[object]]::new(); $db.Add($entry)
        $script:launchCount = 0
        Mock launchCl {
            $script:launchCount++
            # one session wraps a two-step unit: cut both step bodies, then the plan is complete
            $lines = Get-Content $planFile | Where-Object { $_ -ne '## Step 1: a' -and $_ -ne '## Step 2: b' }
            Set-Content $planFile $lines
            Remove-Item -LiteralPath $planFile
            return 0
        }

        runBranchReviewRun $db $entry @()

        $script:launchCount                 | Should -Be 1
        @($script:capturedReport.stepsClosed) | Should -Be @('Step 1: a','Step 2: b')
        $script:capturedReport.stopReason   | Should -Match 'plan finished'
    }

    It "passes -Unattended and the harness's headless flag on every launch" {
        $plan  = newRunPlan 'headlesscheck' @('Step 1: a')
        $entry = newRunEntry $plan
        $db    = [System.Collections.Generic.List[object]]::new(); $db.Add($entry)
        Mock launchCl { Remove-Item -LiteralPath $planFile; return 0 }

        runBranchReviewRun $db $entry @()

        Should -Invoke launchCl -ParameterFilter { $Unattended -eq $true -and $args -contains '--headless' }
    }

    It "registers a fresh session id per launch, via getFreshSessionArgs" {
        $plan  = newRunPlan 'sessioncheck' @('Step 1: a', 'Step 2: b')
        $entry = newRunEntry $plan
        $db    = [System.Collections.Generic.List[object]]::new(); $db.Add($entry)
        Mock launchCl { Remove-Item -LiteralPath $planFile; return 0 }

        runBranchReviewRun $db $entry @()

        @($entry.sessionIds) | Should -HaveCount 1
    }

    It "records the session's final text in the report, read from the harness's session log" {
        $logDir = ((New-Item -ItemType Directory "TestDrive:\run-sessions").FullName -replace '\\', '/').TrimEnd('/')
        Mock getHarnessDescriptor { @{ name = 'myharness'; headlessFlag = '--headless'; sessionsDir = $logDir } }
        $plan  = newRunPlan 'finaltext' @('Step 1: a')
        $entry = newRunEntry $plan
        $db    = [System.Collections.Generic.List[object]]::new(); $db.Add($entry)
        Mock launchCl {
            # the headless session's log ends on its closing assistant_text
            Set-Content "$logDir/$($entry.sessionIds[-1]).jsonl" (
                @('{"type":"user_message","content":"do the step"}',
                  '{"type":"assistant_text","content":"the step hit a rate limit; stopping"}'))
            Remove-Item -LiteralPath $planFile
            return 0
        }

        runBranchReviewRun $db $entry @()

        $script:capturedReport.sessionFinalText | Should -Be 'the step hit a rate limit; stopping'
    }

    It "stops on a non-zero exit and reports the code" {
        $plan  = newRunPlan 'failstep' @('Step 1: a', 'Step 2: b')
        $entry = newRunEntry $plan
        $db    = [System.Collections.Generic.List[object]]::new(); $db.Add($entry)
        Mock launchCl { return 1 }

        runBranchReviewRun $db $entry @()

        Should -Invoke launchCl -Times 1
        @($script:capturedReport.stepsClosed) | Should -Be @()   # a failed launch closed no step
        $script:capturedReport.stopReason     | Should -Match 'exited with code 1'
    }

    It "stops when a step makes no progress" {
        $plan  = newRunPlan 'stalled' @('Step 1: a', 'Step 2: b')
        $entry = newRunEntry $plan
        $db    = [System.Collections.Generic.List[object]]::new(); $db.Add($entry)
        Mock launchCl { return 0 }   # never advances the pointer

        runBranchReviewRun $db $entry @()

        Should -Invoke launchCl -Times 1
        @($script:capturedReport.stepsClosed) | Should -Be @()   # a stalled launch closed no step
        $script:capturedReport.stopReason     | Should -Match 'no progress'
    }

    It "stops when a launch times out, naming the timed-out session in the report" {
        $plan  = newRunPlan 'timedout' @('Step 1: a', 'Step 2: b')
        $entry = newRunEntry $plan
        $db    = [System.Collections.Generic.List[object]]::new(); $db.Add($entry)
        Mock launchCl { return (getLaunchTimeoutCode) }   # the cap fired; the child was killed

        runBranchReviewRun $db $entry @()

        Should -Invoke launchCl -Times 1
        @($script:capturedReport.stepsClosed) | Should -Be @()   # a killed launch closed no step
        $script:capturedReport.lastSessionId  | Should -Be (@($entry.sessionIds)[-1])
        $script:capturedReport.stopReason     | Should -Match 'timed out'
        $script:capturedReport.stopReason     | Should -Match (@($entry.sessionIds)[-1])
    }

    It "stops at the review checkpoint without spending another launch" {
        $plan  = newRunPlan 'reviewstop' @('Step 1: a', 'Step 2: b')
        $entry = newRunEntry $plan
        $db    = [System.Collections.Generic.List[object]]::new(); $db.Add($entry)
        Mock launchCl { $null = Set-PlanState -PlanFile $planFile -State ready-for-user-review; return 0 }

        runBranchReviewRun $db $entry @()

        Should -Invoke launchCl -Times 1
        $script:capturedReport.stopReason | Should -Match 'review'
    }

    It "reads a last-step close as finished, not as the review checkpoint — one launch, no wasted relaunch" {
        # /wrap on the final step cuts its body, then -Advance lands the plan at ready-for-user-review
        # with no headings. The loop's next preflight must see HasSteps false and stop as finished —
        # not spend another launch against a stepless plan (the old no-progress stall).
        $plan  = newRunPlan 'laststep' @('Step 1: a')
        $entry = newRunEntry $plan
        $db    = [System.Collections.Generic.List[object]]::new(); $db.Add($entry)
        Mock launchCl {
            $lines = Get-Content $planFile | Where-Object { $_ -ne '## Step 1: a' }
            Set-Content $planFile $lines
            $null = Set-PlanState -PlanFile $planFile -Advance   # now lands ready-for-user-review, no headings
            return 0
        }

        runBranchReviewRun $db $entry @()

        Should -Invoke launchCl -Times 1
        @($script:capturedReport.stepsClosed) | Should -Be @('Step 1: a')
        $script:capturedReport.stopReason     | Should -Match 'plan finished'
    }

    It "stops before launching when the commit grant is refused" {
        $plan = "$script:runRoot/grantrefused.md"
        Set-Content $plan @('---', 'current-unit:', '  first: "Step 1: a"', '  state: ready-to-implement',
                             'workflow: branch-review', 'automatable: *', 'commit-grant:', '  branch: "feature"', '  repos: [myrepo]',
                             '---', '# grantrefused', '', '## Step 1: a', '## Step 2: b')
        Mock commitGrantRefusedReason { 'on branch someoneelses, not feature' }
        $entry = newRunEntry $plan
        $db    = [System.Collections.Generic.List[object]]::new(); $db.Add($entry)
        Mock launchCl { throw 'should not launch' }

        runBranchReviewRun $db $entry @()

        Should -Invoke launchCl -Times 0
        $script:capturedReport.stopReason | Should -Match 'grant refused'
    }

    It "stops before launching when the current step is not automatable, naming the step" {
        $plan = "$script:runRoot/notauto.md"
        Set-Content $plan @('---', 'current-unit:', '  first: "Step 1: a"', '  state: ready-to-implement',
                             'workflow: branch-review', 'automatable: 2',
                             '---', '# notauto', '', '## Step 1: a', '## Step 2: b')
        $entry = newRunEntry $plan
        $db    = [System.Collections.Generic.List[object]]::new(); $db.Add($entry)
        Mock launchCl { throw 'should not launch' }

        runBranchReviewRun $db $entry @()

        Should -Invoke launchCl -Times 0
        $script:capturedReport.stopReason | Should -Match 'not automatable'
        $script:capturedReport.stopReason | Should -Match 'Step 1'
    }

    It "proceeds when the current step is in the automatable set" {
        $plan = "$script:runRoot/autook.md"
        Set-Content $plan @('---', 'current-unit:', '  first: "Step 1: a"', '  state: ready-to-implement',
                             'workflow: branch-review', 'automatable: 1-2',
                             '---', '# autook', '', '## Step 1: a', '## Step 2: b')
        $entry = newRunEntry $plan
        $db    = [System.Collections.Generic.List[object]]::new(); $db.Add($entry)
        $script:launchCount = 0
        Mock launchCl {
            $script:launchCount++
            $state = Get-PlanState -PlanFile $planFile
            if ($state.First -eq 'Step 2: b') { Remove-Item -LiteralPath $planFile } else { closeStep $planFile $state.First }
            return 0
        }

        runBranchReviewRun $db $entry @()

        $script:launchCount | Should -Be 2
    }

    It "stops at the 50-launch budget for a run that keeps progressing" {
        $plan  = newRunPlan 'longrun' @('Step 1: a', 'Step 2: b')
        $entry = newRunEntry $plan
        $db    = [System.Collections.Generic.List[object]]::new(); $db.Add($entry)
        $script:launchCount = 0
        Mock launchCl {
            $script:launchCount++
            # advances the pointer but cuts no step body — progress that never closes a step
            $state = Get-PlanState -PlanFile $planFile
            $next  = if ($state.First -eq 'Step 1: a') { 'Step 2: b' } else { 'Step 1: a' }
            $null  = Set-PlanState -PlanFile $planFile -Advance -ToStep $next
            return 0
        }

        runBranchReviewRun $db $entry @()

        $script:launchCount                         | Should -Be 50
        @($script:capturedReport.stepsClosed)       | Should -Be @()
        $script:capturedReport.stopReason           | Should -Match '50-launch budget'
    }
}

Describe "resumeWasRefused" {
    BeforeAll {
        $entry = [pscustomobject]@{ planFile = 'C:/plans/p.md'; harness = 'claude'; sessionIds = @('sid-1') }
    }

    It "treats a session with no log at all as refused" {
        Mock getSessionInfos { @() }

        resumeWasRefused $entry 'sid-1' (Get-Date) | Should -BeTrue
    }

    It "treats a log untouched since the launch as refused" {
        $launchedAt = Get-Date
        Mock getSessionInfos { @([pscustomobject]@{ sid = 'sid-1'; lastActive = $launchedAt.AddSeconds(-1); summary = 's' }) }

        resumeWasRefused $entry 'sid-1' $launchedAt | Should -BeTrue
    }

    It "treats a log written to after the launch as a session that ran" {
        $launchedAt = Get-Date
        Mock getSessionInfos { @([pscustomobject]@{ sid = 'sid-1'; lastActive = $launchedAt.AddSeconds(1); summary = 's' }) }

        resumeWasRefused $entry 'sid-1' $launchedAt | Should -BeFalse
    }

    It "looks the session up under the entry's own harness" {
        $entry.harness = 'customtool'
        $script:harnessAsked = $null
        Mock getSessionInfos { $script:harnessAsked = $harness; @() }

        $null = resumeWasRefused $entry 'sid-1' (Get-Date)

        $script:harnessAsked | Should -Be 'customtool'
    }
}

Describe "getShortId" {
    It "returns the first 8 characters of a long id" {
        getShortId '2d0d11ba-006c-427d-b0b7-9005b885dcb1' | Should -Be '2d0d11ba'
    }

    It "passes through a shorter id unchanged" {
        getShortId '2d0d11ba' | Should -Be '2d0d11ba'
    }
}

Describe "buildLaunchRowLabel" {
    BeforeAll {
        function newFreshLabelRow {
            return @{ kind = 'fresh'; harness = 'claude'; phaseLabel = 'refine Step 1: x · tick-tock' }
        }
    }

    It "a session row shows its short id, start→last dates, and its accomplishment" {
        $row = @{ kind = 'session'; info = [pscustomobject]@{ sid = '2d0d11ba-006c-427d-b0b7-9005b885dcb1';
            startedAt = (Get-Date '2026-06-04 08:15'); lastActive = (Get-Date '2026-06-04 09:30');
            summary = 'did a thing'; accomplished = 'finished the step' } }

        buildLaunchRowLabel $row | Should -Be '2d0d11ba  2026-06-04 08:15 → 2026-06-04 09:30  finished the step'
    }

    It "a session row falls back to its summary when it has no accomplishment" {
        $row = @{ kind = 'session'; info = [pscustomobject]@{ sid = '2d0d11ba-006c-427d-b0b7-9005b885dcb1';
            startedAt = (Get-Date '2026-06-04 08:15'); lastActive = (Get-Date '2026-06-04 09:30');
            summary = 'initial prompt' } }

        buildLaunchRowLabel $row | Should -Be '2d0d11ba  2026-06-04 08:15 → 2026-06-04 09:30  initial prompt'
    }

    It "a session row omits the start date and arrow when the harness records no start" {
        $row = @{ kind = 'session'; info = [pscustomobject]@{ sid = '2d0d11ba'; lastActive = (Get-Date '2026-06-04 09:30'); summary = 'did a thing' } }

        buildLaunchRowLabel $row | Should -Be '2d0d11ba  2026-06-04 09:30  did a thing'
    }

    It "a session row flattens a multi-line accomplishment so the row stays on one line" {
        $row = @{ kind = 'session'; info = [pscustomobject]@{ sid = '2d0d11ba-006c-427d-b0b7-9005b885dcb1';
            lastActive = (Get-Date '2026-06-04 09:30');
            summary = 'initial prompt'; accomplished = "Step 14 is complete.`n**The change** — it now works." } }

        $label = buildLaunchRowLabel $row
        $label | Should -Be '2d0d11ba  2026-06-04 09:30  Step 14 is complete. **The change** — it now works.'
        $label | Should -Not -Match "`n"
    }

    It "a fresh row with no model list names the phase and the harness" {
        $label = buildLaunchRowLabel (newFreshLabelRow)

        $label | Should -Match ([regex]::Escape('refine Step 1: x · tick-tock'))
        $label | Should -Match 'claude'
    }

    It "a fresh row with a chosen model names it and its relative cost" {
        $row = newFreshLabelRow
        $row.modelList  = @([pscustomobject]@{ displayName = 'Opus'; model = 'Opus'; relativeCost = 5 })
        $row.modelIndex = 0

        $label = buildLaunchRowLabel $row

        $label | Should -Match ([regex]::Escape('refine Step 1: x · tick-tock'))
        $label | Should -Match 'Opus'
        $label | Should -Match 'cost x5'
    }

    It "a fresh row on <default> names it without a cost, since there is no model to price" {
        $row = newFreshLabelRow
        $row.modelList  = @([pscustomobject]@{ displayName = '<default>'; model = $null; relativeCost = $null })
        $row.modelIndex = 0

        $label = buildLaunchRowLabel $row

        $label | Should -Match '<default>'
        $label | Should -Not -Match 'cost'
    }
}

Describe "endsRunAtPhaseBoundary" {
    It "is true for tick-tock, and for the values that mean it" -TestCases @(
        @{ Workflow = $null }
        @{ Workflow = 'tick-tock' }
        @{ Workflow = 'nonsense' }
    ) {
        param($Workflow)
        endsRunAtPhaseBoundary $Workflow | Should -BeTrue
    }

    It "is false for the modes where the agent carries on past the boundary" -TestCases @(
        @{ Workflow = 'step-review' }
        @{ Workflow = 'branch-review' }
    ) {
        param($Workflow)
        endsRunAtPhaseBoundary $Workflow | Should -BeFalse
    }
}

Describe "getLaunchPrompt" {
    It "names the activity and the plan file" -TestCases @(
        @{ Phase = 'plan';      Match = 'work out what the steps should be' }
        @{ Phase = 'refine';    Match = 'refine the next step' }
        @{ Phase = 'implement'; Match = 'do the next step' }
    ) {
        param($Phase, $Match)
        $prompt = getLaunchPrompt $Phase 'C:/p/x.md' $null

        $prompt | Should -Match $Match
        $prompt | Should -Match ([regex]::Escape('C:/p/x.md'))
    }

    It "the review prompt names the stored state and asks to catch up on recent context" -TestCases @(
        @{ State = 'ready-for-user-review' }
        @{ State = 'ready-for-refined-step-review' }
    ) {
        param($State)
        getLaunchPrompt 'review' 'C:/p/x.md' $null $State |
            Should -Be "The plan, C:/p/x.md, is in $State state. Please read the plan, check you know where the recent context is, e.g. the last session and which commits in repos, then wait for the user's prompt."
    }

    It "the discuss prompt asks to read the plan and then wait for the user's questions" {
        getLaunchPrompt 'discuss' 'C:/p/x.md' $null |
            Should -Be "Let's discuss the plan, C:/p/x.md. Please read it and then wait for my questions"
    }

    It "the refine prompt asks for refine-then-implement where a run doesn't stop at the boundary" -TestCases @(
        @{ Workflow = 'step-review' }
        @{ Workflow = 'branch-review' }
    ) {
        param($Workflow)
        getLaunchPrompt 'refine' 'C:/p/x.md' $Workflow | Should -Be 'Please refine (if needed) and implement the next step in C:/p/x.md'
    }

    It "the refine prompt asks for the refine alone in tick-tock" -TestCases @(
        @{ Workflow = $null }
        @{ Workflow = 'tick-tock' }
    ) {
        param($Workflow)
        getLaunchPrompt 'refine' 'C:/p/x.md' $Workflow | Should -Be 'Please refine the next step in C:/p/x.md'
    }

    It "the other phases' prompts don't vary by workflow" -TestCases @(
        @{ Phase = 'plan' }
        @{ Phase = 'implement' }
        @{ Phase = 'review' }
        @{ Phase = 'discuss' }
    ) {
        param($Phase)
        getLaunchPrompt $Phase 'C:/p/x.md' 'branch-review' | Should -Be (getLaunchPrompt $Phase 'C:/p/x.md' $null)
    }

    It "the headless prompt appends the one-step contract to the base activity" -TestCases @(
        @{ Phase = 'implement'; Base = 'do the next step' }
        @{ Phase = 'refine';    Base = 'implement the next step' }
    ) {
        param($Phase, $Base)
        $prompt = getLaunchPrompt $Phase 'C:/p/x.md' 'branch-review' $null -Headless

        $prompt | Should -Match $Base
        $prompt | Should -Match 'headless'
        $prompt | Should -Match 'do not start the next step'
        $prompt | Should -Match 'closing message'
    }

    It "the headless contract carries the branch-review close recipe (incl. the design-step case)" -TestCases @(
        @{ Phase = 'implement' }
        @{ Phase = 'refine' }
    ) {
        param($Phase)
        $prompt = getLaunchPrompt $Phase 'C:/p/x.md' 'branch-review' $null -Headless

        $prompt | Should -Match 'ready-for-user-review'
        $prompt | Should -Match 'invoke /wrap'
        $prompt | Should -Match 'record it in the step body'
    }

    It "the contract applies only to refine and implement - review and discuss never launch headless" -TestCases @(
        @{ Phase = 'review' }
        @{ Phase = 'discuss' }
    ) {
        param($Phase)
        getLaunchPrompt $Phase 'C:/p/x.md' $null $null -Headless |
            Should -Be (getLaunchPrompt $Phase 'C:/p/x.md' $null $null)
    }

    It "throws on an unknown phase" {
        { getLaunchPrompt 'nonsense' 'C:/p/x.md' $null } | Should -Throw
    }
}

Describe "getLaunchAction" {
    BeforeAll {
        function newPlanState([string] $state, $hasSteps = $true, [string] $workflow = $null) {
            return [pscustomobject]@{ State = $state; HasSteps = $hasSteps; Workflow = $workflow }
        }
    }

    It "defaults the intent from the unit's state" -TestCases @(
        @{ State = 'ready-to-refine';       Expected = 'refine' }
        @{ State = 'ready-to-implement';    Expected = 'implement' }
        @{ State = 'ready-for-user-review'; Expected = 'review' }
    ) {
        param($State, $Expected)
        $a = getLaunchAction (newPlanState $State) $false

        $a.kind   | Should -Be 'fresh'
        $a.intent | Should -Be $Expected
    }

    It "a refined step awaiting review is the user's checkpoint in tick-tock" -TestCases @(
        @{ Workflow = $null }
        @{ Workflow = 'tick-tock' }
    ) {
        param($Workflow)
        (getLaunchAction (newPlanState 'ready-for-refined-step-review' $true $Workflow) $false).intent |
            Should -Be 'review'
    }

    It "a refined step awaiting review means a stopped session in the other modes, so: implement" -TestCases @(
        @{ Workflow = 'step-review' }
        @{ Workflow = 'branch-review' }
    ) {
        param($Workflow)
        (getLaunchAction (newPlanState 'ready-for-refined-step-review' $true $Workflow) $false).intent |
            Should -Be 'implement'
    }

    It "missing or unrecognized state, with steps in the file: refine" -TestCases @(
        @{ State = $null }
        @{ State = 'discussing' }
    ) {
        param($State)
        (getLaunchAction (newPlanState $State) $false).intent | Should -Be 'refine'
    }

    It "a skeleton — no steps yet — gets the plan intent, since there is no next step to refine" {
        (getLaunchAction (newPlanState $null $false) $false).intent | Should -Be 'plan'
    }

    It "a stepless file whose state is set still follows the state" {
        (getLaunchAction (newPlanState 'ready-to-implement' $false) $false).intent | Should -Be 'implement'
    }

    It "sessions present: resume, for every stored state" -TestCases @(
        @{ State = 'ready-to-refine' }
        @{ State = 'ready-for-refined-step-review' }
        @{ State = 'ready-to-implement' }
        @{ State = 'ready-for-user-review' }
    ) {
        param($State)
        (getLaunchAction (newPlanState $State) $true).kind | Should -Be 'resume'
    }

    It "a resume action still carries the default intent, for the picker's start-fresh row" {
        (getLaunchAction (newPlanState 'ready-to-implement') $true).intent | Should -Be 'implement'
    }
}

Describe "getSessionPickerTitle" {
    BeforeAll {
        $script:titleRoot = ((New-Item -ItemType Directory "TestDrive:\picker-title").FullName -replace '\\', '/').TrimEnd('/')
    }

    It "combines the filename and the plan's heading" {
        $path = "$script:titleRoot/foo.md"
        Set-Content $path @("# Foo Plan", "", "## Step 1: x")

        getSessionPickerTitle $path | Should -Be 'foo.md — Foo Plan'
    }

    It "falls back to just the filename when the plan has no heading" {
        $path = "$script:titleRoot/bar.md"
        Set-Content $path @("no heading here")

        getSessionPickerTitle $path | Should -Be 'bar.md'
    }
}

Describe "getFreshSessionArgs" {
    It "generates a --session-id, returns it, and appends it to entry.sessionIds" {
        $entry = [pscustomobject]@{ sessionIds = @() }

        $got = getFreshSessionArgs 'claude' $entry

        $got[0] | Should -Be '--session-id'
        $got[1] | Should -Match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        $entry.sessionIds | Should -Contain $got[1]
    }

    It "returns no args and leaves sessionIds untouched for copilot (its own launcher supplies one)" {
        $entry = [pscustomobject]@{ sessionIds = @('existing') }

        $got = getFreshSessionArgs 'copilot' $entry

        @($got).Count         | Should -Be 0
        @($entry.sessionIds) | Should -Be @('existing')
    }

    It "generates a --session-id for a custom harness too (it can't detect its own fresh session otherwise)" {
        $entry = [pscustomobject]@{ sessionIds = @() }

        $got = getFreshSessionArgs 'customtool' $entry

        $got[0] | Should -Be '--session-id'
        $got[1] | Should -Match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        $entry.sessionIds | Should -Contain $got[1]
    }
}

Describe "defaultsToFreshPicker" {
    It "is false before any launch against this unit (the resumable sessions predate it)" {
        defaultsToFreshPicker 'ready-to-implement' 0 | Should -BeFalse
    }

    It "is true once a launch has worked on this unit" -TestCases @(
        @{ State = 'ready-to-refine';    Launches = 1 }
        @{ State = 'ready-to-implement'; Launches = 3 }
    ) {
        param($State, $Launches)
        defaultsToFreshPicker $State $Launches | Should -BeTrue
    }

    It "is false in the review states however many launches: the session under review is the one to resume" -TestCases @(
        @{ State = 'ready-for-user-review' }
        @{ State = 'ready-for-refined-step-review' }
    ) {
        param($State)
        defaultsToFreshPicker $State 4 | Should -BeFalse
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

Describe "getSessionInfos (custom harness)" {
    BeforeAll {
        $script:customSessionsDir = ((New-Item -ItemType Directory "TestDrive:\customtool-sessions").FullName -replace '\\', '/').TrimEnd('/')

        function writeFlatLog([string] $sid, [string[]] $lines) {
            Set-Content "$script:customSessionsDir/$sid.jsonl" $lines
        }

        writeFlatLog 'sid-a' @(
            (@{ts = '2026-06-01T06:00:00'; type = 'system_prompt'; content = 'sys'} | ConvertTo-Json -Compress)
            (@{type = 'user_message'; content = 'What does this function do?'} | ConvertTo-Json -Compress)
            (@{type = 'assistant_text'; content = 'I traced the bug to the null check.'} | ConvertTo-Json -Compress)
        )
        (Get-Item "$script:customSessionsDir/sid-a.jsonl").LastWriteTime = Get-Date '2026-06-01'

        writeFlatLog 'sid-b' @(
            (@{ts = '2026-01-01T06:00:00'; type = 'system_prompt'; content = 'sys'} | ConvertTo-Json -Compress)
        )
        (Get-Item "$script:customSessionsDir/sid-b.jsonl").LastWriteTime = Get-Date '2026-01-01'

        writeFlatLog 'sid-longmsg' @(
            (@{ts = '2026-03-01T06:00:00'; type = 'user_message'; content = ('x' * 100)} | ConvertTo-Json -Compress)
        )

        # A log whose events carry no `ts` — exercises the startedAt $null path.
        writeFlatLog 'sid-nots' @(
            (@{type = 'user_message'; content = 'no timestamp here'} | ConvertTo-Json -Compress)
        )
        (Get-Item "$script:customSessionsDir/sid-nots.jsonl").LastWriteTime = Get-Date '2026-02-01'
    }

    BeforeEach {
        Mock getHarnessDescriptor { @{ name = 'customtool'; sessionsDir = $script:customSessionsDir } }
    }

    It "sorts most-recent-first by jsonl mtime" {
        $infos = @(getSessionInfos @('sid-b', 'sid-a') 'unused' 'customtool')

        @($infos.sid) | Should -Be @('sid-a', 'sid-b')
    }

    It "excludes sids with no jsonl file" {
        $infos = @(getSessionInfos @('sid-a', 'sid-missing') 'unused' 'customtool')

        @($infos.sid) | Should -Be @('sid-a')
    }

    It "doesn't record an error for a missing jsonl file (expected, not exceptional)" {
        $Error.Clear()

        $null = getSessionInfos @('sid-missing') 'unused' 'customtool'

        $Error.Count | Should -Be 0
    }

    It "uses the first user_message event's content as the summary" {
        $infos = @(getSessionInfos @('sid-a') 'unused' 'customtool')

        $infos[0].summary | Should -Be 'What does this function do?'
    }

    It "falls back to the sid when the log has no user_message event" {
        $infos = @(getSessionInfos @('sid-b') 'unused' 'customtool')

        $infos[0].summary | Should -Be 'sid-b'
    }

    It "truncates a long user_message to 60 chars" {
        $infos = @(getSessionInfos @('sid-longmsg') 'unused' 'customtool')

        $infos[0].summary.Length | Should -Be 60
        $infos[0].summary        | Should -Match '\.\.\.$'
    }

    It "exposes the first event's ts as startedAt" {
        $infos = @(getSessionInfos @('sid-a') 'unused' 'customtool')

        $infos[0].startedAt | Should -Be (Get-Date '2026-06-01 06:00')
    }

    It "leaves startedAt empty when the log has no timestamped event" {
        $infos = @(getSessionInfos @('sid-nots') 'unused' 'customtool')

        $infos[0].startedAt | Should -BeNullOrEmpty
    }

    It "exposes the last assistant_text as accomplished" {
        $infos = @(getSessionInfos @('sid-a') 'unused' 'customtool')

        $infos[0].accomplished | Should -Be 'I traced the bug to the null check.'
    }

    It "leaves accomplished empty when the log has no assistant_text" {
        $infos = @(getSessionInfos @('sid-b') 'unused' 'customtool')

        $infos[0].accomplished | Should -BeNullOrEmpty
    }

    It "returns the last assistant_text even when the log is longer than the 100-line window" {
        # A >100-line log: the early assistant_text sits outside the trailing window, so only the
        # closing one is in range. Pins the windowing (the last 100 lines, not the first 100) that the
        # accomplishment reader must preserve.
        $lines = 1..200 | ForEach-Object {
            if ($_ -eq 1)      { (@{type = 'assistant_text'; content = 'early'} | ConvertTo-Json -Compress) }
            elseif ($_ -eq 200) { (@{type = 'assistant_text'; content = 'closing'} | ConvertTo-Json -Compress) }
            else               { (@{type = 'tool_call'; content = ('pad' + $_)} | ConvertTo-Json -Compress) }
        }
        writeFlatLog 'sid-window' $lines
        $item = Get-Item "$script:customSessionsDir/sid-window.jsonl"

        getFlatSessionAccomplishment $item | Should -Be 'closing'
    }
    It "returns empty when the harness has no registered descriptor" {
        Mock getHarnessDescriptor { $null }

        @(getSessionInfos @('sid-a') 'unused' 'unknownharness') | Should -HaveCount 0
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

    It "uses default harness when no sessionHarness map is given" {
        Mock getDefaultHarness { return 'customtool' }

        $db    = [System.Collections.Generic.List[object]]::new()
        $entry = [pscustomobject]@{planFile = "C:/plans/foo.md"; cwd = "C:/de"; sessionIds = @()}
        $db.Add($entry)
        $orphans = [System.Collections.Generic.List[string]]::new()
        $orphans.Add("new-sid")
        $live = [System.Collections.Generic.HashSet[string]]::new()
        Mock pickFromList { return 0 }

        registerProject $db $orphans $live

        $entry.harness | Should -Be 'customtool'
    }

    It "stamps harness from the sessionHarness map onto an already-tracked entry" {
        $db    = [System.Collections.Generic.List[object]]::new()
        $entry = [pscustomobject]@{planFile = "C:/plans/foo.md"; cwd = "C:/de"; sessionIds = @(); harness = 'claude'}
        $db.Add($entry)
        $orphans = [System.Collections.Generic.List[string]]::new()
        $orphans.Add("copilot-sid")
        $live = [System.Collections.Generic.HashSet[string]]::new()
        Mock pickFromList { return 0 }

        registerProject $db $orphans $live @{ 'copilot-sid' = 'copilot' }

        $entry.harness | Should -Be 'copilot'
    }

    It "stamps harness from the sessionHarness map onto a newly created entry" {
        $plansDir = "TestDrive:\plans-register-harness"
        $null = New-Item -ItemType Directory $plansDir
        Set-Content "$plansDir\new-plan.md" '# new plan'
        $db      = [System.Collections.Generic.List[object]]::new()
        $orphans = [System.Collections.Generic.List[string]]::new()
        $orphans.Add("copilot-sid")
        $live = [System.Collections.Generic.HashSet[string]]::new()
        Mock getPlansDir { return (Resolve-Path "TestDrive:\plans-register-harness").Path }
        Mock pickFromList { return 0 }

        registerProject $db $orphans $live @{ 'copilot-sid' = 'copilot' }

        $db[0].harness | Should -Be 'copilot'
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

    It "returns full path strings rather than FileInfo objects" {
        $result = getAvailablePlanFiles $script:plansDir
        $result | ForEach-Object { $_ | Should -BeOfType [string] }
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
        Set-Content "TestDrive:\title5.md" @("---", "current-step:", "  state: ready-to-plan", "---", "# Real Title")
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
        Mock getDefaultHarness { return 'claude' }
        Mock getSessionInfos { @() }
        Mock pickFromList { return 0 }
        $script:launched = $null
        Mock launchCl { $script:launched = @{harness = $harness; cwd = $cwd; planFile = $planFile; rest = @($args)}; return 0 }
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

    It "adds a stateless entry and dispatches a frontmatterless plan as ready-to-refine" {
        $plan = newUntrackedPlan 'fresh' $null
        Mock getAvailablePlanFiles { return @($plan) }
        $db = [System.Collections.Generic.List[object]]::new()

        $result = openUntracked $db

        $result         | Should -BeTrue
        $db.Count       | Should -Be 1
        $db[0].planFile | Should -Be $plan
        $db[0].harness  | Should -Be 'claude'
        $script:launched.rest     | Should -Contain "Please refine the next step in $plan"
        Should -Invoke saveDb -Times 1
    }

    It "dispatches a ready-to-implement plan with the do-next-step prompt" {
        $plan = newUntrackedPlan 'rti' 'ready-to-implement'
        Mock getAvailablePlanFiles { return @($plan) }
        $db = [System.Collections.Generic.List[object]]::new()

        $result = openUntracked $db

        $result | Should -BeTrue
        $script:launched.rest     | Should -Contain "Please do the next step in $plan"
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
        @{ Key = 'P'; Expected = 'ready-to-refine';      Initial = 'ready-for-user-review' }
        @{ Key = 'C'; Expected = 'ready-to-implement';    Initial = 'ready-to-refine' }
        @{ Key = 'R'; Expected = 'ready-for-user-review'; Initial = 'ready-to-refine' }
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
        $plan  = newStatePlan 'esc' 'ready-to-refine'
        $entry = [pscustomobject]@{planFile = $plan; cwd = "C:/de"; sessionIds = @(); state = 'ready-to-refine'}
        $db    = [System.Collections.Generic.List[object]]::new()
        $db.Add($entry)
        Mock readStateKey { return [pscustomobject]@{Key = 'Escape'} }

        changeState $db $entry

        (Get-PlanState -PlanFile $plan).State | Should -Be 'ready-to-refine'
        Should -Invoke saveDb -Times 0
    }

    It "I and K are now inert (reused/retired keys from the old code-complete/checkpointed mapping)" -TestCases @(
        @{ Key = 'I' }
        @{ Key = 'K' }
    ) {
        param($Key)
        $plan  = newStatePlan "inert-$Key" 'ready-to-refine'
        $entry = [pscustomobject]@{planFile = $plan; cwd = "C:/de"; sessionIds = @(); state = 'ready-to-refine'}
        $db    = [System.Collections.Generic.List[object]]::new()
        $db.Add($entry)
        Mock readStateKey { return [pscustomobject]@{Key = $Key} }

        changeState $db $entry

        (Get-PlanState -PlanFile $plan).State | Should -Be 'ready-to-refine'
        Should -Invoke saveDb -Times 0
    }
}

Describe "getHarnessPickerOptions" {
    It "includes a selected built-in at its key" {
        Mock getAgentHarnesses { @(@{ name = 'claude' }) }

        (getHarnessPickerOptions)['C'] | Should -Be 'claude'
    }

    It "excludes an unselected built-in even though prefs knows its properties" {
        Mock getAgentHarnesses { @(@{ name = 'claude' }) }

        (getHarnessPickerOptions).Contains('3') | Should -BeFalse
    }

    It "includes a custom harness at its own pickerKey" {
        Mock getAgentHarnesses { @(@{ name = 'customtool'; pickerKey = 'X' }) }

        (getHarnessPickerOptions)['X'] | Should -Be 'customtool'
    }

    It "a registry entry can't add a pickerKey to a built-in (de selects claude/copilot, doesn't configure them)" {
        Mock getAgentHarnesses { @(@{ name = 'copilot'; pickerKey = 'G' }) }

        (getHarnessPickerOptions).Contains('G') | Should -BeFalse
    }

    It "excludes a custom harness with no pickerKey" {
        Mock getAgentHarnesses { @(@{ name = 'claude' }, @{ name = 'customtool' }) }

        @((getHarnessPickerOptions).Keys) | Should -Be @('C')
    }
}

Describe "changeHarness" {
    BeforeEach {
        Mock saveDb { }
        Mock Write-Host { }
        Mock clearConsole { }
        Mock getAgentHarnesses { @(@{ name = 'claude' }, @{ name = 'customtool'; pickerKey = 'X' }) }
    }

    It "writes the picked harness to the db entry" -TestCases @(
        @{ Key = 'C'; Expected = 'claude';     Initial = 'customtool' }
        @{ Key = 'X'; Expected = 'customtool'; Initial = 'claude' }
    ) {
        param($Key, $Expected, $Initial)
        $entry = [pscustomobject]@{planFile = "C:/plans/foo.md"; cwd = "C:/de"; sessionIds = @(); harness = $Initial}
        $db    = [System.Collections.Generic.List[object]]::new()
        $db.Add($entry)
        Mock readStateKey { return [pscustomobject]@{Key = $Key} }

        changeHarness $db $entry

        $entry.harness | Should -Be $Expected
        Should -Invoke saveDb -Times 1
    }

    It "leaves the harness unchanged and does not save on an unrecognized key" {
        $entry = [pscustomobject]@{planFile = "C:/plans/foo.md"; cwd = "C:/de"; sessionIds = @(); harness = 'claude'}
        $db    = [System.Collections.Generic.List[object]]::new()
        $db.Add($entry)
        Mock readStateKey { return [pscustomobject]@{Key = 'Escape'} }

        changeHarness $db $entry

        $entry.harness | Should -Be 'claude'
        Should -Invoke saveDb -Times 0
    }

    It "does not save when the picked harness matches the current one" {
        $entry = [pscustomobject]@{planFile = "C:/plans/foo.md"; cwd = "C:/de"; sessionIds = @(); harness = 'claude'}
        $db    = [System.Collections.Generic.List[object]]::new()
        $db.Add($entry)
        Mock readStateKey { return [pscustomobject]@{Key = 'C'} }

        changeHarness $db $entry

        Should -Invoke saveDb -Times 0
    }
}

Describe "changeWorkflow" {
    BeforeAll {
        $script:workflowPlansRoot = ((New-Item -ItemType Directory "TestDrive:\plans-workflow").FullName -replace '\\', '/').TrimEnd('/')

        function newWorkflowPlan([string] $name) {
            $path = "$script:workflowPlansRoot/$name.md"
            Set-Content $path @("# $name", "", "## Step 1: first")
            return $path
        }
    }

    BeforeEach {
        Mock saveDb { }
        Mock Write-Host { }
        Mock clearConsole { }
    }

    It "writes the picked workflow" -TestCases @(
        @{ Key = 'T'; Expected = 'tick-tock' }
        @{ Key = 'S'; Expected = 'step-review' }
    ) {
        param($Key, $Expected)
        $plan  = newWorkflowPlan "key-$Key"
        $entry = [pscustomobject]@{planFile = $plan; cwd = 'C:/de'; sessionIds = @()}
        $db    = [System.Collections.Generic.List[object]]::new()
        $db.Add($entry)
        Mock readStateKey { return [pscustomobject]@{Key = $Key} }

        changeWorkflow $db $entry

        (Get-PlanState -PlanFile $plan).Workflow | Should -Be $Expected
    }

    It "picking branch-review also prompts for and writes the commit grant" {
        $plan  = newWorkflowPlan 'branch-review'
        $entry = [pscustomobject]@{planFile = $plan; cwd = 'C:/de'; sessionIds = @()}
        $db    = [System.Collections.Generic.List[object]]::new()
        $db.Add($entry)
        Mock readStateKey { return [pscustomobject]@{Key = 'B'} }
        Mock getRepoBranch { 'myBranch' }
        Mock Read-Host { param($Prompt) if ($Prompt -match 'Branch') { '' } else { 'de, prat' } }

        changeWorkflow $db $entry

        $result = Get-PlanState -PlanFile $plan
        $result.Workflow        | Should -Be 'branch-review'
        $result.CommitBranch    | Should -Be 'myBranch'
        @($result.CommitRepos)  | Should -Be @('de', 'prat')
    }

    It "does not prompt for a grant when picking tick-tock or step-review" {
        $plan  = newWorkflowPlan 'no-grant-prompt'
        $entry = [pscustomobject]@{planFile = $plan; cwd = 'C:/de'; sessionIds = @()}
        $db    = [System.Collections.Generic.List[object]]::new()
        $db.Add($entry)
        Mock readStateKey { return [pscustomobject]@{Key = 'T'} }
        Mock Read-Host { throw 'should not prompt' }

        changeWorkflow $db $entry

        (Get-PlanState -PlanFile $plan).CommitBranch | Should -BeNullOrEmpty
    }

    It "leaves the plan unchanged on an unrecognized key" {
        $plan  = newWorkflowPlan 'esc'
        $entry = [pscustomobject]@{planFile = $plan; cwd = 'C:/de'; sessionIds = @()}
        $db    = [System.Collections.Generic.List[object]]::new()
        $db.Add($entry)
        Mock readStateKey { return [pscustomobject]@{Key = 'Escape'} }

        changeWorkflow $db $entry

        (Get-PlanState -PlanFile $plan).Workflow | Should -BeNullOrEmpty
    }
}

Describe "setCommitGrant" {
    BeforeAll {
        $script:grantPlansRoot = ((New-Item -ItemType Directory "TestDrive:\plans-grant").FullName -replace '\\', '/').TrimEnd('/')

        function newGrantPlan([string] $name) {
            $path = "$script:grantPlansRoot/$name.md"
            Set-Content $path @("# $name")
            return $path
        }
    }

    It "defaults the branch to what cwd has checked out; Enter accepts it" {
        $plan = newGrantPlan 'default-branch'
        Mock getRepoBranch { 'inferredBranch' }
        Mock Read-Host { param($Prompt) if ($Prompt -match 'Branch') { '' } else { 'de' } }

        setCommitGrant $plan 'C:/somerepo'

        $result = Get-PlanState -PlanFile $plan
        $result.CommitBranch   | Should -Be 'inferredBranch'
        @($result.CommitRepos) | Should -Be @('de')
    }

    It "a typed branch overrides the inferred default" {
        $plan = newGrantPlan 'override-branch'
        Mock getRepoBranch { 'inferredBranch' }
        Mock Read-Host { param($Prompt) if ($Prompt -match 'Branch') { 'myOwnBranch' } else { '' } }

        setCommitGrant $plan 'C:/somerepo'

        (Get-PlanState -PlanFile $plan).CommitBranch | Should -Be 'myOwnBranch'
    }

    It "splits and trims a comma-separated repo list" {
        $plan = newGrantPlan 'repos'
        Mock getRepoBranch { 'b' }
        Mock Read-Host { param($Prompt) if ($Prompt -match 'Branch') { '' } else { ' de ,prat ,  ~/other ' } }

        setCommitGrant $plan 'C:/somerepo'

        @((Get-PlanState -PlanFile $plan).CommitRepos) | Should -Be @('de', 'prat', '~/other')
    }

    It "writes nothing when there's no default branch and none typed" {
        $plan = newGrantPlan 'no-branch'
        Mock getRepoBranch { $null }
        Mock Read-Host { '' }

        setCommitGrant $plan 'C:/somerepo'

        (Get-PlanState -PlanFile $plan).CommitBranch | Should -BeNullOrEmpty
    }

    It "infers no default branch when cwd is empty" {
        $plan = newGrantPlan 'no-cwd'
        Mock getRepoBranch { throw 'should not be called with no cwd' }
        Mock Read-Host { param($Prompt) if ($Prompt -match 'Branch') { 'typedBranch' } else { '' } }

        setCommitGrant $plan ''

        (Get-PlanState -PlanFile $plan).CommitBranch | Should -Be 'typedBranch'
    }
}

Describe "getErrorLogPath" {
    It "points at a file under prat/auto/context" {
        getErrorLogPath | Should -Match 'prat[/\\]auto[/\\]context[/\\]launch-plan-errors\.log$'
    }
}

Describe "getNewErrorRecords" {
    It "returns an empty array when the error count hasn't changed" {
        $Error.Clear()
        try { throw 'seed' } catch { }

        @(getNewErrorRecords $Error.Count) | Should -HaveCount 0
    }

    It "returns records added since the prior count, oldest first" {
        $Error.Clear()
        try { throw 'seed' } catch { }
        $priorCount = $Error.Count
        try { throw 'second' } catch { }
        try { throw 'third' } catch { }

        $result = getNewErrorRecords $priorCount

        $result.Count                    | Should -Be 2
        $result[0].Exception.Message     | Should -Be 'second'
        $result[1].Exception.Message     | Should -Be 'third'
    }
}

Describe "formatErrorRecord" {
    It "includes the error message" {
        $Error.Clear()
        try { throw 'boom' } catch { }

        formatErrorRecord $Error[0] | Should -Match 'boom'
    }

    It "handles a record with no script stack trace" {
        $exception  = New-Object System.Exception('boom-no-stack')
        $errorRecord = New-Object System.Management.Automation.ErrorRecord(
            $exception, 'id', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)

        formatErrorRecord $errorRecord | Should -Match 'boom-no-stack'
    }
}

Describe "appendErrorLog" {
    It "does nothing when there are no records" {
        $path = "TestDrive:\errlog-empty.log"

        appendErrorLog @() $path

        Test-Path $path | Should -BeFalse
    }

    It "creates parent directories and writes the formatted record" {
        $path = "TestDrive:/errlog-sub/nested/errors.log"
        $Error.Clear()
        try { throw 'boom' } catch { }

        appendErrorLog @($Error[0]) $path

        Test-Path $path | Should -BeTrue
        (Get-Content $path -Raw) | Should -Match 'boom'
    }

    It "appends to an existing file rather than overwriting it" {
        $path = "TestDrive:\errlog-append.log"
        Set-Content $path 'existing line'
        $Error.Clear()
        try { throw 'boom2' } catch { }

        appendErrorLog @($Error[0]) $path

        $content = Get-Content $path -Raw
        $content | Should -Match 'existing line'
        $content | Should -Match 'boom2'
    }
}
