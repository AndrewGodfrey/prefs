param($installationTracker, [string[]] $Suppress = @())

$stage = $installationTracker.StartStage('agentConfig')

# prefs/CLAUDE.md @-includes CLAUDE_prat.md.
# Copy it from prat/CLAUDE.md. (This copy is .gitignored)
# (We do this instead of "@../prat/CLAUDE.md" because even if CC support for that is added, it may be blocked later
# due to security concerns.)
$pratClaudeMd = Import-TextFile "$home\prat\CLAUDE.md"
Install-TextToFile $stage "$home\prefs\CLAUDE_prat.md" $pratClaudeMd

Install-Folder $stage "$home\.claude"

if ('installHomeClaudeMd' -notin $Suppress) {
    # Standalone mode (no de): assemble $home/.claude/CLAUDE.md from prat base + prefs fragment.
    # When de is running, it suppresses this and assembles with both prefs and de fragments.
    Install-ClaudeUserConfig $stage "$home\prefs\lib\agents\agent-user.md"
}

# Global skills, agents, and commands from prat.
Install-ClaudeSkillSet $stage @("testing", "working-with-git") "$home\prat\lib\agents\skills" "$home/.claude/skills"
Install-ClaudeMarkdownFiles $stage "$home\prat\lib\agents\subagents" "$home/.claude/agents"
Install-ClaudeMarkdownFiles $stage "$home\prat\lib\agents\commands" "$home/.claude/commands"

Install-ClaudeUserSettings $stage

$installationTracker.EndStage($stage)
