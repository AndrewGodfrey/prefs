# The agent harnesses prefs knows how to launch, find live and resume. Selecting which ones this dev
# environment uses (and in which order: the first is the default) is up to a higher layer's
# harnesses_<layer>.ps1, which can also describe a harness of its own or override a property here.
# See agentHarnesses.ps1 for how layers merge.
#
# Properties, by consumer:
#  - Launch-Plan.ps1: pickerKey (unique across harnesses), liveProcessName, liveCmdlineFilter,
#    liveCwdMatch, sessionInfoStyle, sessionsDir, headlessFlag
#  - Invoke-AgentSession.ps1: supportsAddDir, contextArgStyle, additionalArgs, commitGrantArgs.
#    copilot has its own case there (a file-based context injection these properties can't express).
#  - Get-CurrentAgentSessionId: sessionIdEnvVar, the variable the harness sets in its agent shells.
#
# pi: its --resume takes no session id (it shows its own interactive menu instead), so only
# live-detection and fresh-launch are supported. It has no supportsAddDir (it has never gotten
# --add-dir), and no sessionIdEnvVar is known for it.
@{
    harnesses = @{
        claude  = @{
            pickerKey        = 'C'
            liveProcessName  = 'claude.exe'
            sessionInfoStyle = 'claude-projects'
            supportsAddDir   = $true
            contextArgStyle  = 'append-system-prompt'
            sessionIdEnvVar  = 'CLAUDE_CODE_SESSION_ID'
        }
        copilot = @{
            liveProcessName  = 'copilot.exe'
            liveCwdMatch     = $true
            sessionIdEnvVar  = 'COPILOT_AGENT_SESSION_ID'
        }
        pi      = @{
            pickerKey         = '3'
            liveProcessName   = 'node.exe'
            liveCmdlineFilter = 'pi-coding-agent'
            contextArgStyle   = 'append-system-prompt'
            additionalArgs    = @('--skill', './.claude/skills/')
        }
    }
}
# OmitFromCoverageReport: a unit test would just restate it - static harness data
