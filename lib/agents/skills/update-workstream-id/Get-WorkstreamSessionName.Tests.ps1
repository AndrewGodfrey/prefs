BeforeAll {
    $script:formatter = Join-Path $PSScriptRoot 'Get-WorkstreamSessionName.ps1'
}

Describe 'Get-WorkstreamSessionName' {
    It 'uses the bare ID when no original title is supplied' {
        & $formatter -WorkstreamId '12345-startupPerf' | Should -Be '12345-startupPerf'
    }

    It 'rejects a bare ID longer than the tool limit' {
        { & $formatter -WorkstreamId ('a' * 41) -MaxLength 40 } | Should -Throw '*exceeds*'
    }

    It 'prefixes the original title with the supplied bare ID' {
        & $formatter -WorkstreamId '12345' -OriginalSessionName 'Allocation cleanup' |
            Should -Be '12345: Allocation cleanup'
    }

    It 'preserves punctuation in the original title' {
        & $formatter -WorkstreamId '12345' -OriginalSessionName '2026: Review changes' |
            Should -Be '12345: 2026: Review changes'
    }

    It 'produces the same name on repeated updates and replaces the work ID' {
        $original = 'Allocation cleanup'
        $first = & $formatter -WorkstreamId '12345' -OriginalSessionName $original

        & $formatter -WorkstreamId '12345' -OriginalSessionName $original | Should -Be $first
        & $formatter -WorkstreamId '67890' -OriginalSessionName $original | Should -Be '67890: Allocation cleanup'
    }

    It 'keeps a title that exactly fits the tool limit' {
        $original = 'a' * 33

        & $formatter -WorkstreamId '12345' -OriginalSessionName $original -MaxLength 40 |
            Should -Be "12345: $original"
    }

    It 'shortens only the original title when the tool limit is exceeded' {
        $result = & $formatter -WorkstreamId '12345' -OriginalSessionName ('a' * 100) -MaxLength 40

        $result | Should -Be ('12345: ' + ('a' * 33))
        $result.Length | Should -Be 40
    }

    It 'does not split a surrogate pair at the truncation boundary' {
        $symbol = [char]::ConvertFromUtf32(0x1F600)
        $original = ('a' * 32) + $symbol + 'end'
        $result = & $formatter -WorkstreamId '12345' -OriginalSessionName $original -MaxLength 40

        $result | Should -Be ('12345: ' + ('a' * 32))
    }

    It 'rejects limits that leave no room for the original title' {
        { & $formatter -WorkstreamId '12345' -OriginalSessionName 'Title' -MaxLength 7 } |
            Should -Throw '*no room*'
    }

    It 'rejects malformed IDs and multiline titles' {
        { & $formatter -WorkstreamId '12345: other' -OriginalSessionName 'Title' } | Should -Throw '*WorkstreamId*'
        { & $formatter -WorkstreamId '12345' -OriginalSessionName "Two`nlines" } | Should -Throw '*OriginalSessionName*'
    }
}

Describe 'update-workstream-id skill discovery' {
    It 'is given to every role, whatever roles the top layer composes' {
        Import-Module "$home/prat/lib/PratBase/PratBase.psd1" -Force
        $contributions = @(
            (& "$home/prat/lib/agents/roles_prat.ps1")
            (& (Join-Path $PSScriptRoot '..\..\roles_prefs.ps1'))
            @{ roles = @{ anyrole = @{ skills = @('x') } } }
        )

        (Get-AgentRoles -Contributions $contributions).anyrole.skills | Should -Contain 'update-workstream-id'
    }

    It 'ships the formatter its SKILL.md links to' {
        $skill = Get-Content (Join-Path $PSScriptRoot 'SKILL.md') -Raw -ErrorAction Stop
        $skill | Should -Match '(?m)^name: update-workstream-id\r?$'
        $links = [regex]::Matches($skill, '\]\(([^:)]+)\)')

        $links.Count | Should -BeGreaterThan 0
        foreach ($link in $links) {
            $link.Groups[1].Value | Should -Not -Match '[/\\]'
            Test-Path (Join-Path $PSScriptRoot $link.Groups[1].Value) | Should -BeTrue
        }
    }
}
