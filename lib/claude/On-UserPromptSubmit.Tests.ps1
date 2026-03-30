BeforeDiscovery {
    . "$PSScriptRoot/On-UserPromptSubmit.ps1"
}

BeforeAll {
    . "$PSScriptRoot/On-UserPromptSubmit.ps1"
}

Describe "getIntentPlanFile" {
    It "returns null when intent file does not exist" {
        $result = getIntentPlanFile "C:/de" "TestDrive:\no-file.json"

        $result | Should -BeNull
    }

    It "returns null when cwd does not match intent" {
        $intentPath = "TestDrive:\intent-cwd-mismatch.json"
        '{"planFile":"C:/plans/foo.md","cwd":"C:/other"}' | Set-Content $intentPath

        $result = getIntentPlanFile "C:/de" (Get-Item $intentPath).FullName

        $result | Should -BeNull
        Test-Path $intentPath | Should -BeTrue    # not consumed
    }

    It "returns planFile and removes intent file when cwd matches" {
        $intentPath = "TestDrive:\intent-match.json"
        '{"planFile":"C:/plans/foo.md","cwd":"C:/de"}' | Set-Content $intentPath

        $result = getIntentPlanFile "C:/de" (Get-Item $intentPath).FullName

        $result            | Should -Be "C:/plans/foo.md"
        Test-Path $intentPath | Should -BeFalse    # consumed
    }

    It "normalizes backslash cwd from intent file" {
        $intentPath = "TestDrive:\intent-backslash.json"
        '{"planFile":"C:/plans/foo.md","cwd":"C:\\de"}' | Set-Content $intentPath

        $result = getIntentPlanFile "C:/de" (Get-Item $intentPath).FullName

        $result | Should -Be "C:/plans/foo.md"
    }

    It "normalizes backslash cwd argument" {
        $intentPath = "TestDrive:\intent-backslash-arg.json"
        '{"planFile":"C:/plans/foo.md","cwd":"C:/de"}' | Set-Content $intentPath

        $result = getIntentPlanFile 'C:\de' (Get-Item $intentPath).FullName

        $result | Should -Be "C:/plans/foo.md"
    }

    It "returns null when intent file is malformed JSON" {
        $intentPath = "TestDrive:\intent-bad-json.json"
        'not json' | Set-Content $intentPath

        $result = getIntentPlanFile "C:/de" (Get-Item $intentPath).FullName

        $result | Should -BeNull
    }
}

Describe 'Get-RepoDiff' {
    BeforeAll {
        $script:base = @{
            branch            = 'main'
            log               = "abc1234 commit one`ndef5678 commit two`nghi9012 commit three"
            status            = ''
            uncommittedHashes = @{}
        }
    }

    It 'returns null when state is identical' {
        Get-RepoDiff $base ($base.Clone()) | Should -BeNullOrEmpty
    }
    It 'detects branch change and includes log' {
        $new = $base.Clone(); $new.branch = 'feature'
        $diff = Get-RepoDiff $base $new
        $diff | Should -Not -BeNullOrEmpty
        $diff.branchOld | Should -Be 'main'
        $diff.branchNew | Should -Be 'feature'
        $diff.ContainsKey('logNew') | Should -BeTrue
    }
    It 'detects log change without branch change' {
        $new = $base.Clone(); $new.log = "newcommit step 4`nabc1234 commit one`ndef5678 commit two"
        $diff = Get-RepoDiff $base $new
        $diff.ContainsKey('logNew') | Should -BeTrue
        $diff.ContainsKey('branchOld') | Should -BeFalse
    }
    It 'detects status change' {
        $new = $base.Clone(); $new.status = 'M lib/foo.ps1'
        (Get-RepoDiff $base $new).statusNew | Should -Be 'M lib/foo.ps1'
    }
    It 'sets uncommittedChanged when only content changed (status same)' {
        $old = @{branch='main'; log=''; status='M lib/foo.ps1'; uncommittedHashes=@{'lib/foo.ps1'='OLDHASH'}}
        $new = @{branch='main'; log=''; status='M lib/foo.ps1'; uncommittedHashes=@{'lib/foo.ps1'='NEWHASH'}}
        $diff = Get-RepoDiff $old $new
        $diff.uncommittedChanged | Should -BeTrue
        $diff.ContainsKey('statusNew') | Should -BeFalse
    }
    It 'does not set uncommittedChanged when status also changed' {
        $old = @{branch='main'; log=''; status='';              uncommittedHashes=@{}}
        $new = @{branch='main'; log=''; status='?? newfile.ps1'; uncommittedHashes=@{'newfile.ps1'='HASH'}}
        $diff = Get-RepoDiff $old $new
        $diff.statusNew | Should -Be '?? newfile.ps1'
        $diff.ContainsKey('uncommittedChanged') | Should -BeFalse
    }
    It 'detects multiple changes' {
        $new = $base.Clone(); $new.branch = 'feature'; $new.status = 'M lib/foo.ps1'
        $diff = Get-RepoDiff $base $new
        $diff.ContainsKey('branchOld') | Should -BeTrue
        $diff.statusNew | Should -Be 'M lib/foo.ps1'
    }
}

Describe 'Format-GitStateMessage' {
    It 'includes header line' {
        $diffs = [ordered]@{'C:/foo' = @{statusNew='M lib/foo.ps1'}}
        Format-GitStateMessage $diffs $false | Should -BeLike '*git state changed since last turn*'
    }
    It 'formats branch change with commits' {
        $diffs = [ordered]@{'C:/foo' = @{branchOld='main'; branchNew='feature'; logNew="abc1234 step 1`ndef5678 step 2"}}
        $msg = Format-GitStateMessage $diffs $false
        $msg | Should -BeLike '*Branch: main → feature*'
        $msg | Should -BeLike '*abc1234 step 1*'
    }
    It 'formats status change with indented lines' {
        $diffs = [ordered]@{'C:/foo' = @{statusNew="M lib/foo.ps1`n?? newfile.ps1"}}
        $msg = Format-GitStateMessage $diffs $false
        $msg | Should -BeLike '*Status:*'
        $msg | Should -BeLike '*  M lib/foo.ps1*'
    }
    It 'formats uncommitted content change' {
        $diffs = [ordered]@{'C:/foo' = @{uncommittedChanged=$true}}
        Format-GitStateMessage $diffs $false | Should -BeLike '*Uncommitted file content changed*'
    }
    It 'omits repo name when showRepoNames is false' {
        $diffs = [ordered]@{'C:/repos/myrepo' = @{statusNew='M lib/foo.ps1'}}
        Format-GitStateMessage $diffs $false | Should -Not -Match '\[myrepo\]'
    }
    It 'includes repo name when showRepoNames is true' {
        $diffs = [ordered]@{'C:/repos/de' = @{branchOld='main'; branchNew='feature'; logNew='abc step'}}
        Format-GitStateMessage $diffs $true | Should -BeLike '*[de]*'
    }
    It 'includes names for each changed repo in multi-repo output' {
        $diffs = [ordered]@{
            'C:/repos/de'    = @{branchOld='main'; branchNew='feature'; logNew='abc step'}
            'C:/repos/prefs' = @{statusNew='M lib/foo.ps1'}
        }
        $msg = Format-GitStateMessage $diffs $true
        $msg | Should -BeLike '*[de]*'
        $msg | Should -BeLike '*[prefs]*'
    }
}

Describe 'Emit-GitStateDiff' {
    BeforeAll {
        $script:emitDir = (New-Item -ItemType Directory 'TestDrive:/emit-snaps').FullName
    }

    It 'emits nothing when no snapshot file exists' {
        Mock Get-GitCwdState { @{'C:/repo' = @{branch='main'; log=''; status=''; uncommittedHashes=@{}}} }
        $dir    = (New-Item -ItemType Directory 'TestDrive:/emit-snaps/no-snap').FullName
        $output = Emit-GitStateDiff @{session_id='s1'; cwd='C:/repo'} $dir
        $output | Should -BeNullOrEmpty
    }

    It 'emits nothing when state is unchanged' {
        $state = @{'C:/repo' = @{branch='main'; log='abc'; status=''; uncommittedHashes=@{}}}
        Mock Get-GitCwdState { $state }
        $dir  = (New-Item -ItemType Directory 'TestDrive:/emit-snaps/unchanged').FullName
        $snap = Get-SnapshotPath $dir 's2' 'C:/repo'
        $state | ConvertTo-Json -Depth 5 | Set-Content $snap
        Emit-GitStateDiff @{session_id='s2'; cwd='C:/repo'} $dir | Should -BeNullOrEmpty
    }

    It 'emits additionalContext JSON when state changed' {
        $old = @{'C:/repo' = @{branch='main';    log='abc'; status=''; uncommittedHashes=@{}}}
        $new = @{'C:/repo' = @{branch='feature'; log='abc'; status=''; uncommittedHashes=@{}}}
        Mock Get-GitCwdState { $new }
        $dir  = (New-Item -ItemType Directory 'TestDrive:/emit-snaps/changed').FullName
        $snap = Get-SnapshotPath $dir 's3' 'C:/repo'
        $old | ConvertTo-Json -Depth 5 | Set-Content $snap
        $output = Emit-GitStateDiff @{session_id='s3'; cwd='C:/repo'} $dir
        $output | Should -Not -BeNullOrEmpty
        ($output | ConvertFrom-Json).additionalContext | Should -BeLike '*Branch: main → feature*'
    }

    It 'updates snapshot after emitting' {
        $old = @{'C:/repo' = @{branch='main';    log='old'; status=''; uncommittedHashes=@{}}}
        $new = @{'C:/repo' = @{branch='feature'; log='new'; status=''; uncommittedHashes=@{}}}
        Mock Get-GitCwdState { $new }
        $dir  = (New-Item -ItemType Directory 'TestDrive:/emit-snaps/update').FullName
        $snap = Get-SnapshotPath $dir 's4' 'C:/repo'
        $old | ConvertTo-Json -Depth 5 | Set-Content $snap
        Emit-GitStateDiff @{session_id='s4'; cwd='C:/repo'} $dir | Out-Null
        $updated = Get-Content $snap -Raw | ConvertFrom-Json -AsHashtable
        $updated['C:/repo'].branch | Should -Be 'feature'
    }
}
