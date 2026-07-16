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

    It "defaults harness to claude when absent (legacy entries)" {
        Set-Content "TestDrive:\db-load-harness1.json" '[{"planFile":"p.md","cwd":"C:/de","sessionIds":[]}]'

        (loadDb "TestDrive:\db-load-harness1.json")[0].harness | Should -Be 'claude'
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

    It "round-trips harness through saveDb/loadDb" {
        $entries = @([pscustomobject]@{planFile = "C:/plans/bar.md"; cwd = "C:/de"; sessionIds = @(); harness = "copilot"})

        saveDb $entries "TestDrive:\rt-harness.json"

        (loadDb "TestDrive:\rt-harness.json")[0].harness | Should -Be 'copilot'
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
            [pscustomobject]@{planFile = (newAttachPlan 'with' 'code-complete'); cwd = "C:/de"; sessionIds = @()}
            [pscustomobject]@{planFile = (newAttachPlan 'without' $null); cwd = "C:/de"; sessionIds = @()}
        )

        attachEntryInfo $db

        $db[0].state | Should -Be 'code-complete'
        $db[1].state | Should -BeNullOrEmpty
    }

    It "attaches the frontmatter next-step pointer" {
        $plan = newAttachPlan 'pointer' 'ready-to-implement'
        $null = Set-PlanState -PlanFile $plan -NextStep 'Step 1: x'
        $db = @([pscustomobject]@{planFile = $plan; cwd = "C:/de"; sessionIds = @()})

        attachEntryInfo $db

        $db[0].nextStep | Should -Be 'Step 1: x'
    }

    It "attaches enterKind resume when resumable sessions exist, fresh when none" {
        Mock getSessionInfos { param($sessionIds) if (@($sessionIds).Count -gt 0) {
            @([pscustomobject]@{sid = 'sid-1'; lastActive = Get-Date; summary = 's'})
        } else { @() } }
        $db = @(
            [pscustomobject]@{planFile = (newAttachPlan 'has-session' 'ready-to-implement'); cwd = "C:/de"; sessionIds = @("sid-1")}
            [pscustomobject]@{planFile = (newAttachPlan 'no-session' 'ready-to-implement'); cwd = "C:/de"; sessionIds = @()}
        )

        attachEntryInfo $db

        $db[0].enterKind | Should -Be 'resume'
        $db[1].enterKind | Should -Be 'fresh'
    }

    It "attaches enterKind fresh for a checkpointed plan even with sessions" {
        Mock getSessionInfos { @([pscustomobject]@{sid = 'sid-1'; lastActive = Get-Date; summary = 's'}) }
        $db = @(
            [pscustomobject]@{planFile = (newAttachPlan 'ckpt' 'checkpointed'); cwd = "C:/de"; sessionIds = @("sid-1")}
        )

        attachEntryInfo $db

        $db[0].enterKind | Should -Be 'fresh'
    }
}

Describe "displayState" {
    It "shows state and next-step pointer when both are present" {
        $entry = [pscustomobject]@{state = 'ready-to-implement'; nextStep = 'Step 5: model picker'}
        displayState $entry | Should -Be 'ready-to-implement: Step 5: model picker'
    }

    It "falls back to state alone when there is no pointer" {
        $entry = [pscustomobject]@{state = 'ready-to-plan'; nextStep = $null}
        displayState $entry | Should -Be 'ready-to-plan'
    }

    It "shows a dash when neither state nor pointer is present" {
        $entry = [pscustomobject]@{state = $null; nextStep = $null}
        displayState $entry | Should -Be '-'
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

Describe "cycleModelIndex" {
    It "advances forward" {
        cycleModelIndex 0 3 1 | Should -Be 1
    }

    It "wraps forward past the end" {
        cycleModelIndex 2 3 1 | Should -Be 0
    }

    It "moves backward" {
        cycleModelIndex 2 3 -1 | Should -Be 1
    }

    It "wraps backward past the start" {
        cycleModelIndex 0 3 -1 | Should -Be 2
    }
}

Describe "advanceFreshRowModel" {
    It "advances the fresh row's model index, wrapping" {
        $row = @{ kind = 'fresh'; modelList = @(1, 2, 3); modelIndex = 2 }

        advanceFreshRowModel $row 1

        $row.modelIndex | Should -Be 0
    }

    It "is a no-op for a session row" {
        $row = @{ kind = 'session'; modelList = @(1, 2, 3); modelIndex = 0 }

        advanceFreshRowModel $row 1

        $row.modelIndex | Should -Be 0
    }

    It "is a no-op for a fresh row with no model list" {
        $row = @{ kind = 'fresh' }

        advanceFreshRowModel $row 1

        $row.ContainsKey('modelIndex') | Should -BeFalse
    }
}

Describe "getCursorGuardScript" {
    It "checks the console cursor position and offers a pause to read startup output" {
        $script = getCursorGuardScript

        $script | Should -Match 'CursorLeft'
        $script | Should -Match 'CursorTop'
        $script | Should -Match 'Read-Host'
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

    It "Left/Right are no-ops when no onHorizontal is supplied" {
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

    It "invokes onHorizontal with the selected item and direction on Left/Right" {
        $keys = [System.Collections.Generic.Queue[object]]::new()
        $keys.Enqueue([pscustomobject]@{Key = 'RightArrow'})
        $keys.Enqueue([pscustomobject]@{Key = 'Enter'})
        Mock readListKey { $keys.Dequeue() }
        $calls = [System.Collections.Generic.List[object]]::new()
        $onHorizontal = { param($item, $direction) $calls.Add(@{item = $item; direction = $direction}) }
        $item = @{ n = 'x' }

        $result = pickFromList @($item) { param($i) $i.n } 'title' 0 $onHorizontal

        $result             | Should -Be 0
        $calls.Count        | Should -Be 1
        $calls[0].direction | Should -Be 1
    }

    It "recomputes labels after an onHorizontal mutation, so it shows before Enter" {
        $keys = [System.Collections.Generic.Queue[object]]::new()
        $keys.Enqueue([pscustomobject]@{Key = 'RightArrow'})
        $keys.Enqueue([pscustomobject]@{Key = 'Enter'})
        Mock readListKey { $keys.Dequeue() }
        $script:writes = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { param($Object) $script:writes.Add([string]$Object) }
        $item = [pscustomobject]@{ n = 0 }
        $onHorizontal = { param($i, $d) $i.n += 1 }

        pickFromList @($item) { param($i) "n=$($i.n)" } 'title' 0 $onHorizontal

        ($script:writes -join '|') | Should -Match 'n=1'
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
    It "leaves fields unchanged when the row fits the console width" {
        $entry = [pscustomobject]@{planFile = 'C:/plans/a.md'; enterKind = 'fresh'; state = 'ready-to-plan'; nextStep = $null}

        $f = buildRowFields $entry $false $false $false 10 20 200

        $f.nameField  | Should -Match 'a\.md'
        $f.crossField | Should -Be ''
    }

    It "truncates fields so the total row stays within the console width" {
        $entry = [pscustomobject]@{planFile = 'C:/plans/a-very-long-plan-file-name-indeed.md'; enterKind = 'fresh'; state = 'ready-to-implement'; nextStep = $null}

        $f = buildRowFields $entry $false $false $true 50 20 30

        ($f.prefix.Length + $f.status.Length + $f.nameField.Length + $f.stateField.Length + $f.crossField.Length) |
            Should -BeLessOrEqual 30
        $f.nameField | Should -Match '…'
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
            return [pscustomobject]@{planFile = $planFile; cwd = "C:/de"; sessionIds = $sessionIds; harness = $harness}
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

    It "ready-to-plan + no sessions: fresh launch with plan-the-next-step prompt" {
        $plan  = newPlan 'rtp' 'ready-to-plan'
        $entry = newEntry $plan
        $db    = newDb $entry

        openProject $db $entry @()

        $script:launched.rest     | Should -Contain "Please plan the next step in $plan"
    }

    It "code-complete + no sessions: fresh launch with review prompt" {
        $plan  = newPlan 'cc' 'code-complete'
        $entry = newEntry $plan
        $db    = newDb $entry

        openProject $db $entry @()

        $joined = $script:launched.rest -join ' '
        $joined | Should -Match 'code-complete'
        $joined | Should -Match 'review'
    }

    It "no frontmatter: treated as ready-to-plan" {
        $plan  = newPlan 'bare' $null
        $entry = newEntry $plan
        $db    = newDb $entry

        openProject $db $entry @()

        $script:launched.rest     | Should -Contain "Please plan the next step in $plan"
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

    It "default picker selection: most recent for ready-to-plan, start-fresh for ready-to-implement" -TestCases @(
        @{ State = 'ready-to-plan';      ExpectedInitial = 0 }
        @{ State = 'ready-to-implement'; ExpectedInitial = 2 }   # after the 2 session rows
    ) {
        param($State, $ExpectedInitial)
        $plan  = newPlan "res-default-$State" $State
        $entry = newEntry $plan @("sid-1", "sid-2")
        $db    = newDb $entry
        Mock getSessionInfos { @((newInfo 'sid-1' (Get-Date)), (newInfo 'sid-2' (Get-Date))) }
        $script:pickerInitial = $null
        Mock pickFromList { $script:pickerInitial = $initialSelected; return $null }

        $null = openProject $db $entry @()

        $script:pickerInitial | Should -Be $ExpectedInitial
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

    It "failed resume: removes only the failed sid, keeps the rest, returns true" {
        $plan  = newPlan 'res-fail' 'ready-to-implement'
        $entry = newEntry $plan @("sid-1", "sid-2")
        $db    = newDb $entry
        Mock getSessionInfos { @(newInfo 'sid-1' (Get-Date)) }
        Mock pickFromList { return 0 }
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

    It "resume actions still carry the fresh-launch prompt (for the picker's start-fresh row)" {
        (getLaunchAction 'ready-to-plan' $true 'C:/p/x.md').prompt      | Should -Match 'plan the next step'
        (getLaunchAction 'ready-to-implement' $true 'C:/p/x.md').prompt | Should -Match 'do the next step'
    }

    It "checkpointed: fresh implement launch + state flip, even with sessions" {
        $a = getLaunchAction 'checkpointed' $true 'C:/p/x.md'

        $a.kind     | Should -Be 'fresh'
        $a.prompt   | Should -Be 'Please do the next step in C:/p/x.md'
        $a.setState | Should -Be 'ready-to-implement'
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

    It "returns no args and leaves sessionIds untouched for a non-claude harness (its own launcher supplies one)" {
        $entry = [pscustomobject]@{ sessionIds = @('existing') }

        $got = getFreshSessionArgs 'copilot' $entry

        @($got).Count         | Should -Be 0
        @($entry.sessionIds) | Should -Be @('existing')
    }
}

Describe "defaultsToFreshPicker" {
    It "is true for ready-to-implement (its sessions are the spent planning ones)" {
        defaultsToFreshPicker 'ready-to-implement' | Should -BeTrue
    }

    It "is false for ready-to-plan and code-complete (continue/approve the existing session)" -TestCases @(
        @{ State = 'ready-to-plan' }
        @{ State = 'code-complete' }
    ) {
        param($State)
        defaultsToFreshPicker $State | Should -BeFalse
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

    It "defaults harness to claude when no sessionHarness map is given" {
        $db    = [System.Collections.Generic.List[object]]::new()
        $entry = [pscustomobject]@{planFile = "C:/plans/foo.md"; cwd = "C:/de"; sessionIds = @()}
        $db.Add($entry)
        $orphans = [System.Collections.Generic.List[string]]::new()
        $orphans.Add("new-sid")
        $live = [System.Collections.Generic.HashSet[string]]::new()
        Mock pickFromList { return 0 }

        registerProject $db $orphans $live

        $entry.harness | Should -Be 'claude'
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
        Mock Get-DefaultHarness { return 'claude' }
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

    It "adds a stateless entry and dispatches a frontmatterless plan as ready-to-plan" {
        $plan = newUntrackedPlan 'fresh' $null
        Mock getAvailablePlanFiles { return @($plan) }
        $db = [System.Collections.Generic.List[object]]::new()

        $result = openUntracked $db

        $result         | Should -BeTrue
        $db.Count       | Should -Be 1
        $db[0].planFile | Should -Be $plan
        $db[0].harness  | Should -Be 'claude'
        $script:launched.rest     | Should -Contain "Please plan the next step in $plan"
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