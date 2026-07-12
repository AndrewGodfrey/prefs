BeforeDiscovery {
    . "$PSScriptRoot/On-FileEdited.ps1"
}

BeforeAll {
    . "$PSScriptRoot/On-FileEdited.ps1"

    function hookDataFor($path) {
        @{ tool_name = 'Edit'; tool_input = @{ file_path = $path } }
    }

    function writeLf([string] $path) {
        [System.IO.File]::WriteAllText($path, "line1`nline2`n", [System.Text.UTF8Encoding]::new($false))
    }

    function hasCrlf([string] $path) {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        for ($i = 0; $i -lt $bytes.Length - 1; $i++) {
            if ($bytes[$i] -eq 13 -and $bytes[$i + 1] -eq 10) { return $true }
        }
        return $false
    }
}

Describe 'Get-MarkdownWidthFeedback' {
    It 'returns null for a non-markdown file with long lines' {
        $file = Join-Path $TestDrive 'notes.txt'
        Set-Content $file ('x' * 130)
        Get-MarkdownWidthFeedback (hookDataFor $file) | Should -BeNullOrEmpty
    }

    It 'returns null for a markdown file with no long lines' {
        $file = Join-Path $TestDrive 'ok.md'
        Set-Content $file 'short line'
        Get-MarkdownWidthFeedback (hookDataFor $file) | Should -BeNullOrEmpty
    }

    It 'reports each long line with path, line number and length' {
        $file = Join-Path $TestDrive 'doc.md'
        Set-Content $file @('short', ('x' * 130), 'short', ('y' * 125))
        $feedback = Get-MarkdownWidthFeedback (hookDataFor $file)
        $feedback | Should -Match ([regex]::Escape("${file}:2: 130 chars"))
        $feedback | Should -Match ([regex]::Escape("${file}:4: 125 chars"))
    }

    It 'tells the agent what to do about the findings' {
        $file = Join-Path $TestDrive 'doc.md'
        Set-Content $file ('x' * 130)
        Get-MarkdownWidthFeedback (hookDataFor $file) | Should -Match 'wrap'
    }

    It 'uses the 120-char limit' {
        $file = Join-Path $TestDrive 'edge.md'
        Set-Content $file @(('x' * 120), ('y' * 121))
        $feedback = Get-MarkdownWidthFeedback (hookDataFor $file)
        $feedback | Should -Match ([regex]::Escape("${file}:2: 121 chars"))
        $feedback | Should -Not -Match ([regex]::Escape("${file}:1:"))
    }

    It 'matches the extension case-insensitively' {
        $file = Join-Path $TestDrive 'DOC.MD'
        Set-Content $file ('x' * 130)
        Get-MarkdownWidthFeedback (hookDataFor $file) | Should -Not -BeNullOrEmpty
    }

    It 'exempts unwrappable lines (fenced code, table rows)' {
        $file = Join-Path $TestDrive 'exempt.md'
        Set-Content $file @('```', ('x' * 130), '```', ('| ' + 'c' * 130 + ' |'))
        Get-MarkdownWidthFeedback (hookDataFor $file) | Should -BeNullOrEmpty
    }

    It 'returns null when the file does not exist' {
        Get-MarkdownWidthFeedback (hookDataFor (Join-Path $TestDrive 'missing.md')) | Should -BeNullOrEmpty
    }

    It 'returns null when tool_input has no file_path' {
        Get-MarkdownWidthFeedback @{ tool_name = 'Edit'; tool_input = @{} } | Should -BeNullOrEmpty
    }
}

Describe 'Repair-FileLineEndings' -Tag Integration {
    BeforeEach {
        $script:testRoot = Join-Path (Resolve-Path "TestDrive:\").ProviderPath "On-FileEdited.Tests"
        $script:gitDir   = "$testRoot\git"
        $script:noGitDir = "$testRoot\nogit"
        mkdir $gitDir   | Out-Null
        mkdir $noGitDir | Out-Null

        git init $gitDir 2>$null | Out-Null
        git -C $gitDir config user.email "test@example.com" 2>$null | Out-Null
        git -C $gitDir config user.name  "Test"             2>$null | Out-Null
        # Disable autocrlf by default; individual tests opt in explicitly
        git -C $gitDir config core.autocrlf false 2>$null | Out-Null
    }
    AfterEach {
        Remove-Item $testRoot -Recurse -Force
    }

    It "does nothing when file path is null" {
        { Repair-FileLineEndings $null } | Should -Not -Throw
    }

    It "does nothing when file does not exist" {
        { Repair-FileLineEndings "$gitDir\nonexistent.txt" } | Should -Not -Throw
    }

    It "does not convert when file is not inside a git repo" {
        $file = "$noGitDir\test.txt"
        writeLf $file

        Repair-FileLineEndings $file

        hasCrlf $file | Should -BeFalse
    }

    It "does not convert when repo has no eol rule and autocrlf=false" {
        $file = "$gitDir\test.txt"
        writeLf $file

        Repair-FileLineEndings $file

        hasCrlf $file | Should -BeFalse
    }

    It "converts LF to CRLF when .gitattributes specifies eol=crlf" {
        Set-Content "$gitDir\.gitattributes" "* eol=crlf" -Encoding utf8NoBOM
        $file = "$gitDir\test.txt"
        writeLf $file

        Repair-FileLineEndings $file

        hasCrlf $file | Should -BeTrue
    }

    It "does not convert when .gitattributes specifies eol=lf" {
        Set-Content "$gitDir\.gitattributes" "* eol=lf" -Encoding utf8NoBOM
        $file = "$gitDir\test.txt"
        writeLf $file

        Repair-FileLineEndings $file

        hasCrlf $file | Should -BeFalse
    }

    It "converts when autocrlf=true and safecrlf=true" {
        git -C $gitDir config core.autocrlf true 2>$null | Out-Null
        git -C $gitDir config core.safecrlf true 2>$null | Out-Null
        $file = "$gitDir\test.txt"
        writeLf $file

        Repair-FileLineEndings $file

        hasCrlf $file | Should -BeTrue
    }

    It "converts when autocrlf=true and safecrlf=warn" {
        git -C $gitDir config core.autocrlf true 2>$null | Out-Null
        git -C $gitDir config core.safecrlf warn 2>$null | Out-Null
        $file = "$gitDir\test.txt"
        writeLf $file

        Repair-FileLineEndings $file

        hasCrlf $file | Should -BeTrue
    }

    It "does not convert when autocrlf=true but safecrlf=false" {
        git -C $gitDir config core.autocrlf true 2>$null | Out-Null
        git -C $gitDir config core.safecrlf false 2>$null | Out-Null
        $file = "$gitDir\test.txt"
        writeLf $file

        Repair-FileLineEndings $file

        hasCrlf $file | Should -BeFalse
    }

    It "is idempotent: already-CRLF file is not double-converted" {
        Set-Content "$gitDir\.gitattributes" "* eol=crlf" -Encoding utf8NoBOM
        $file = "$gitDir\test.txt"
        [System.IO.File]::WriteAllText($file, "line1`r`nline2`r`n", [System.Text.UTF8Encoding]::new($false))

        Repair-FileLineEndings $file

        $after = [System.IO.File]::ReadAllBytes($file)
        # No \r\r\n sequences
        $doubled = $false
        for ($i = 0; $i -lt $after.Length - 2; $i++) {
            if ($after[$i] -eq 13 -and $after[$i + 1] -eq 13) { $doubled = $true }
        }
        $doubled | Should -BeFalse
    }

    It "skips binary files (null byte present)" {
        Set-Content "$gitDir\.gitattributes" "* eol=crlf" -Encoding utf8NoBOM
        $file = "$gitDir\test.bin"
        [System.IO.File]::WriteAllBytes($file, [byte[]]@(104, 105, 0, 10))

        Repair-FileLineEndings $file

        [System.IO.File]::ReadAllBytes($file) | Should -Be @(104, 105, 0, 10)
    }
}
