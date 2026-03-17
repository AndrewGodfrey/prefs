# Returns the prefs-layer Claude user settings as a hashtable.
# Merged with other layers by Install-ClaudeUserSettings.
$homeFwd   = ($home -replace '\\', '/').TrimEnd('/')
$claudePath = $homeFwd -replace '^C:', '//c'

return @{
    spinnerVerbs       = @{mode = "replace"; verbs = @("Working")}
    spinnerTipsEnabled = $false
    enabledPlugins     = @{"superpowers@claude-plugins-official" = $false}
    ui                 = @{showStartupTips = $false}
    attribution        = @{commits = $false; pullRequests = $false}
    additionalDirectories = @("$homeFwd/prat", "$homeFwd/prefs")
    statusLine         = @{
        type    = "command"
        command = 'pwsh -c ''& "$home\prefs\lib\claude\claude-statusline.ps1"'''
    }
    permissions        = @{
        allow = @(
            "WebSearch"
            "WebFetch(domain:developers.openai.com)"
            "WebFetch(domain:github.com)"
            "WebFetch(domain:www.anthropic.com)"
            "Read($claudePath/prat/**)"
            "Read($claudePath/prefs/**)"
            "Read($claudePath/.claude/**)"
            "Read(//c/tmp/**)"
            "Bash(wc:*)"
            "Bash(t:*)"
        )
    }
    hooks = @{
        Stop = @(
            @{hooks = @(@{type = "command"; command = 'pwsh -c ''& "$home/prat/lib/On-AgentTurnCompleted.ps1"'''})}
        )
        PostToolUse = @(
            @{
                matcher = "Edit|Write"
                hooks   = @(@{type = "command"; command = 'pwsh -c ''& "$home/prat/lib/On-PostToolUse.ps1"'''})
            }
        )
    }
}
