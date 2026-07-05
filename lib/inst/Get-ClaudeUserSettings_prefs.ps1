# Returns the prefs-layer Claude user settings as a hashtable.
# Merged with other layers by Install-ClaudeUserSettings.
$home_fwd   = ($home -replace '\\', '/').TrimEnd('/')
$home_bash = $home_fwd -replace '^C:', '//c'

return @{
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
            "Read($home_bash/prat/**)"
            "Read($home_bash/prefs/**)"
            "Read($home_bash/.claude/**)"
            "Read(//c/tmp/**)"
        )
    }
    hooks = @{
        PostToolUse = @(
            @{
                matcher = "Edit|Write"
                hooks   = @(@{type = "command"; command = 'pwsh -c ''& "$home/prat/lib/On-PostToolUse.ps1"'''})
            }
        )
    }
}
