Describe "Get-ClaudeUserSettings_prefs" {
    It "registers a PostToolUse hook matching Edit/Write" {
        $result = & "$PSScriptRoot\Get-ClaudeUserSettings_prefs.ps1"
        $result.hooks.PostToolUse | Should -Not -BeNullOrEmpty
        $result.hooks.PostToolUse[0].matcher | Should -Be "Edit|Write"
    }

    It "PostToolUse hook command runs On-FileEdited and propagates its exit code" {
        $result = & "$PSScriptRoot\Get-ClaudeUserSettings_prefs.ps1"
        $command = $result.hooks.PostToolUse[0].hooks[0].command
        $command | Should -BeLike "*On-FileEdited.ps1*"
        # CC only feeds stderr back to the agent on exit 2; without this the -c wrapper collapses
        # the script's exit code to 1.
        $command | Should -BeLike "*exit `$LASTEXITCODE*"
    }
}
