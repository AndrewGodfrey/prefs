BeforeAll {
    Import-Module "$home/prat/lib/PratBase/PratBase.psd1" -Force
    . "$PSScriptRoot/sessionWorkstream.ps1"
    $script:sid = '0123abcd-4567-89ef-0123-456789abcdef'
}

Describe "sessionWorkstream" {
    Context "Set-SessionWorkstreamId" {
        It "writes the id to <dir>/<sessionId>.txt" {
            $dir = "TestDrive:\set-write"
            Set-SessionWorkstreamId 'myproj-123' -SessionId $script:sid -WorkstreamDir $dir

            Get-Content "$dir\$($script:sid).txt" -Raw | Should -Be 'myproj-123'
        }

        It "overwrites a previous id" {
            $dir = "TestDrive:\set-overwrite"
            Set-SessionWorkstreamId 'first' -SessionId $script:sid -WorkstreamDir $dir
            Set-SessionWorkstreamId 'second' -SessionId $script:sid -WorkstreamDir $dir

            Get-Content "$dir\$($script:sid).txt" -Raw | Should -Be 'second'
        }

        It "clears the id when given an empty string" {
            $dir = "TestDrive:\set-clear"
            Set-SessionWorkstreamId 'x' -SessionId $script:sid -WorkstreamDir $dir
            Set-SessionWorkstreamId '' -SessionId $script:sid -WorkstreamDir $dir

            Test-Path "$dir\$($script:sid).txt" | Should -BeFalse
        }

        It "throws when no session id is available" {
            { Set-SessionWorkstreamId 'x' -SessionId '' -WorkstreamDir "TestDrive:\set-nosid" } | Should -Throw '*session id*inside an agent session*'
        }

        It "defaults to the current agent session (Get-CurrentAgentSessionId)" {
            Mock Get-CurrentAgentSessionId { 'from-helper' }
            $dir = "TestDrive:\set-default"
            Set-SessionWorkstreamId 'myproj-2' -WorkstreamDir $dir

            Get-Content "$dir\from-helper.txt" -Raw | Should -Be 'myproj-2'
        }

        It "rejects a session id that could escape the workstream dir" {
            { Set-SessionWorkstreamId 'x' -SessionId '..\evil' -WorkstreamDir "TestDrive:\set-evil" } | Should -Throw '*Invalid session id*'
            Test-Path "TestDrive:\evil.txt" | Should -BeFalse
        }

        It "prunes ids older than the retention period, keeping recent ones" {
            $dir = "TestDrive:\set-prune"
            New-Item -ItemType Directory $dir | Out-Null
            Set-Content "$dir\old-session.txt" 'old'
            Set-Content "$dir\recent-session.txt" 'recent'
            (Get-Item "$dir\old-session.txt").LastWriteTime = (Get-Date).AddDays(-31)
            (Get-Item "$dir\recent-session.txt").LastWriteTime = (Get-Date).AddDays(-29)

            Set-SessionWorkstreamId 'new' -SessionId $script:sid -WorkstreamDir $dir

            Test-Path "$dir\old-session.txt"    | Should -BeFalse
            Test-Path "$dir\recent-session.txt" | Should -BeTrue
            Test-Path "$dir\$($script:sid).txt" | Should -BeTrue
        }
    }

    Context "Read-SessionWorkstreamId" {
        It "returns the id written for the session" {
            $dir = "TestDrive:\read-basic"
            Set-SessionWorkstreamId 'myproj-123' -SessionId $script:sid -WorkstreamDir $dir

            Read-SessionWorkstreamId $script:sid $dir | Should -Be 'myproj-123'
        }

        It "returns empty when the session has no id" {
            Read-SessionWorkstreamId $script:sid "TestDrive:\read-none" | Should -Be ''
        }

        It "returns empty when the session id is missing or invalid" {
            Read-SessionWorkstreamId $null "TestDrive:\read-none" | Should -Be ''
            Read-SessionWorkstreamId '..\x' "TestDrive:\read-none" | Should -Be ''
        }

        It "shows only the first line and strips control characters" {
            $dir = "TestDrive:\read-sanitize"
            New-Item -ItemType Directory $dir | Out-Null
            Set-Content "$dir\$($script:sid).txt" "a`e[31mb`tc`r`nsecond line" -NoNewline

            Read-SessionWorkstreamId $script:sid $dir | Should -Be 'a[31mbc'
        }

        It "truncates long ids" {
            $dir = "TestDrive:\read-truncate"
            Set-SessionWorkstreamId ('x' * 60) -SessionId $script:sid -WorkstreamDir $dir

            $out = Read-SessionWorkstreamId $script:sid $dir
            $out.Length | Should -Be 40
            $out | Should -Match '\.\.\.$'
        }
    }

    Context "Get-SessionWorkstreamDir" {
        It "is an absolute path in this repo's auto dir, whichever script calls it" {
            Push-Location $env:TEMP
            try {
                $dir = & { Get-SessionWorkstreamDir }
            } finally { Pop-Location }

            [IO.Path]::IsPathFullyQualified($dir) | Should -BeTrue
            $dir | Should -Be ([IO.Path]::GetFullPath("$PSScriptRoot/../../auto/sessionWorkstreams"))
        }
    }

    Context "pathbin wrapper" {
        It "sets the id for the given session" {
            $dir = (New-Item -ItemType Directory "TestDrive:\wrapper").FullName
            & "$PSScriptRoot/../../pathbin/Set-SessionWorkstreamId.ps1" 'myproj-1' -SessionId $script:sid -WorkstreamDir $dir

            Read-SessionWorkstreamId $script:sid $dir | Should -Be 'myproj-1'
        }

        It "defaults to the current agent session" {
            Mock Get-CurrentAgentSessionId { 'from-helper' }
            $dir = (New-Item -ItemType Directory "TestDrive:\wrapper-default").FullName
            & "$PSScriptRoot/../../pathbin/Set-SessionWorkstreamId.ps1" 'myproj-3' -WorkstreamDir $dir

            Read-SessionWorkstreamId 'from-helper' $dir | Should -Be 'myproj-3'
        }
    }
}
