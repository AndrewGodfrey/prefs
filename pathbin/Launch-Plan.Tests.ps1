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

    It "returns entries with correct fields" {
        $json = '[{"planFile":"C:/plans/foo.md","state":"ready","cwd":"C:/de","sessionIds":["abc"]}]'
        Set-Content "TestDrive:\db-load1.json" $json

        $result = loadDb "TestDrive:\db-load1.json"

        @($result)               | Should -HaveCount 1
        $result[0].planFile      | Should -Be "C:/plans/foo.md"
        $result[0].state         | Should -Be "ready"
        $result[0].cwd           | Should -Be "C:/de"
        @($result[0].sessionIds) | Should -Be @("abc")
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
            state      = "in-progress"
            cwd        = "C:/de"
            sessionIds = @("sid1", "sid2")
        })

        saveDb $entries "TestDrive:\rt.json"
        $result = loadDb "TestDrive:\rt.json"

        @($result)                 | Should -HaveCount 1
        $result[0].planFile        | Should -Be "C:/plans/bar.md"
        $result[0].state           | Should -Be "in-progress"
        @($result[0].sessionIds)   | Should -Be @("sid1", "sid2")
    }

    It "round-trips an empty db as an empty array" {
        $db = [System.Collections.Generic.List[object]]::new()

        saveDb $db "TestDrive:\rt-empty.json"
        $result = @(loadDb "TestDrive:\rt-empty.json")

        $result | Should -HaveCount 0
    }
}

Describe "resolveSessionIds" {
    It "leaves db unchanged when running dir doesn't exist" {
        $db = @([pscustomobject]@{planFile = "f.md"; state = "discussing"; cwd = "C:/de"; sessionIds = @()})

        resolveSessionIds $db "TestDrive:\norunning" @()

        @($db[0].sessionIds) | Should -HaveCount 0
    }

    It "adds session_id when running file cwd matches db entry cwd" {
        $rDir = "TestDrive:\running-match"
        $null = New-Item -ItemType Directory $rDir
        '{"session_id":"abc-123","cwd":"C:/de"}' | Set-Content "$rDir\pid_99.txt"
        $db = @([pscustomobject]@{planFile = "f.md"; state = "discussing"; cwd = "C:/de"; sessionIds = @()})

        resolveSessionIds $db $rDir @(99)

        $db[0].sessionIds | Should -Contain "abc-123"
    }

    It "doesn't duplicate an already-present session_id" {
        $rDir = "TestDrive:\running-nodup"
        $null = New-Item -ItemType Directory $rDir
        '{"session_id":"abc-123","cwd":"C:/de"}' | Set-Content "$rDir\pid_99.txt"
        $db = @([pscustomobject]@{planFile = "f.md"; state = "discussing"; cwd = "C:/de"; sessionIds = @("abc-123")})

        resolveSessionIds $db $rDir @(99)

        @($db[0].sessionIds) | Should -HaveCount 1
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

    It "adds session_id only from live pid files" {
        $rDir = "TestDrive:\running-livePid"
        $null = New-Item -ItemType Directory $rDir
        '{"session_id":"live-sid","cwd":"C:/de"}' | Set-Content "$rDir\pid_99.txt"
        '{"session_id":"dead-sid","cwd":"C:/de"}' | Set-Content "$rDir\pid_77.txt"
        $db = @([pscustomobject]@{planFile = "f.md"; state = "discussing"; cwd = "C:/de"; sessionIds = @()})

        resolveSessionIds $db $rDir @(99)   # only pid 99 is live

        $db[0].sessionIds | Should -Contain "live-sid"
        $db[0].sessionIds | Should -Not -Contain "dead-sid"
    }

    It "returns orphan session_id in result" {
        $rDir = "TestDrive:\running-orphan"
        $null = New-Item -ItemType Directory $rDir
        '{"session_id":"orphan-sid","cwd":"C:/untracked"}' | Set-Content "$rDir\pid_99.txt"
        $db = @([pscustomobject]@{planFile = "f.md"; state = "discussing"; cwd = "C:/de"; sessionIds = @()})

        $result = resolveSessionIds $db $rDir @(99)

        $result.orphans | Should -Contain "orphan-sid"
    }

    It "warns on conflict when session_id is already linked to a different entry" {
        $rDir = "TestDrive:\running-conflict"
        $null = New-Item -ItemType Directory $rDir
        # pid file says cwd=C:/other, but "conflict-sid" is already in entry for C:/de
        '{"session_id":"conflict-sid","cwd":"C:/other"}' | Set-Content "$rDir\pid_99.txt"
        $entry1 = [pscustomobject]@{planFile = "f1.md"; state = "discussing"; cwd = "C:/de"; sessionIds = @("conflict-sid")}
        $entry2 = [pscustomobject]@{planFile = "f2.md"; state = "discussing"; cwd = "C:/other"; sessionIds = @()}
        $db = @($entry1, $entry2)

        resolveSessionIds $db $rDir @(99) -WarningVariable warns
        $warns | Should -Not -BeNullOrEmpty
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
}

Describe "checkSyncPath" {
    It "returns path when it exists" {
        $dir = "TestDrive:\sync-exists"
        $null = New-Item -ItemType Directory $dir

        $result = checkSyncPath (Resolve-Path $dir).Path

        $result | Should -Not -BeNullOrEmpty
    }

    It "returns null and warns when path does not exist" {
        $result = checkSyncPath "TestDrive:\sync-missing" -WarningVariable warns

        $result           | Should -BeNull
        $warns            | Should -Not -BeNullOrEmpty
    }

    It "returns null when path is null" {
        $result = checkSyncPath $null

        $result | Should -BeNull
    }
}

Describe "openProject" {
    BeforeEach {
        Mock saveDb { }
        Mock launchCl { }
        Mock Write-Host { }
    }

    It "ready + not live: transitions to in-progress, clears sessionIds, launches" {
        $db    = [System.Collections.Generic.List[object]]::new()
        $entry = [pscustomobject]@{planFile = "C:/plans/foo.md"; state = "ready"; cwd = "C:/de"; sessionIds = @()}
        $db.Add($entry)

        openProject $db $entry @()

        $entry.state             | Should -Be "in-progress"
        @($entry.sessionIds)     | Should -HaveCount 0
        Should -Invoke launchCl -Times 1
    }

    It "ready + live: does nothing, does not launch" {
        $db    = [System.Collections.Generic.List[object]]::new()
        $entry = [pscustomobject]@{planFile = "C:/plans/foo.md"; state = "ready"; cwd = "C:/de"; sessionIds = @("live-sid")}
        $db.Add($entry)
        Mock Read-Host { "" }

        openProject $db $entry @("live-sid")

        $entry.state | Should -Be "ready"
        Should -Invoke launchCl -Times 0
    }

    It "non-ready + no sid: updates cwd before launching" {
        $db    = [System.Collections.Generic.List[object]]::new()
        $entry = [pscustomobject]@{planFile = "C:/plans/foo.md"; state = "discussing"; cwd = "C:/old"; sessionIds = @()}
        $db.Add($entry)

        openProject $db $entry @()

        $entry.cwd           | Should -Be (normalizePath $PWD.Path)
        Should -Invoke launchCl -Times 1
    }

    It "non-ready + single sid: saves sid and launches resume" {
        $db    = [System.Collections.Generic.List[object]]::new()
        $entry = [pscustomobject]@{planFile = "C:/plans/foo.md"; state = "in-progress"; cwd = "C:/de"; sessionIds = @("sid1")}
        $db.Add($entry)
        $script:capturedArgs = $null
        Mock launchCl { $script:capturedArgs = $args }

        openProject $db $entry @()

        @($entry.sessionIds)        | Should -Be @("sid1")
        $script:capturedArgs        | Should -Contain "--resume"
    }

    It "non-ready + multi-sid: saves picked sid as sole sid" {
        $db    = [System.Collections.Generic.List[object]]::new()
        $entry = [pscustomobject]@{planFile = "C:/plans/foo.md"; state = "in-progress"; cwd = "C:/de"; sessionIds = @("sid1", "sid2")}
        $db.Add($entry)
        Mock Read-Host { "0" }
        $script:capturedArgs = $null
        Mock launchCl { $script:capturedArgs = $args }

        openProject $db $entry @()

        @($entry.sessionIds)        | Should -Be @("sid1")
        $script:capturedArgs        | Should -Contain "--resume"
    }
}

