# Returns the prefs-layer Claude user settings as a hashtable.
# Merged with other layers by Install-ClaudeUserSettings.
$home_fwd   = ($home -replace '\\', '/').TrimEnd('/')
$home_bash = $home_fwd -replace '^C:', '//c'

return @{
    defaultShell       = "powershell"
    spinnerVerbs       = @{mode = "replace"; verbs = @("Working")}
    spinnerTipsEnabled = $false
    ui                 = @{showStartupTips = $false}
    attribution        = @{commits = $false; pullRequests = $false}
    additionalDirectories = @("$home_fwd/prat", "$home_fwd/prefs")
    statusLine         = @{
        type    = "command"
        command = 'pwsh -c ''& "$home\prefs\lib\agents\agent-statusline.ps1"'''
    }
    permissions        = @{
        allow = @(
            "WebSearch"
            "WebFetch(domain:developers.openai.com)"
            "WebFetch(domain:github.com)"
            "WebFetch(domain:www.anthropic.com)"
        )
    }
    # On-FileEdited fixes line endings and feeds markdown width findings back to the agent.
    # It lives here rather than in prat so the base layer doesn't impose the policy; the trailing
    # `exit $LASTEXITCODE` propagates exit 2, the only code CC feeds stderr back to the agent on.
    hooks = @{
        PostToolUse = @(
            @{
                matcher = "Edit|Write"
                hooks   = @(@{type = "command"; command = 'pwsh -c ''& "$home/prefs/lib/agents/On-FileEdited.ps1"; exit $LASTEXITCODE'''})
            }
        )
    }
}
