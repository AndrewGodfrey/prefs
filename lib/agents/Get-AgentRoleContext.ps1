param([string] $cwd)

$project   = Get-PratProject $cwd
$agentRole = if ($project -and $project.agentRole) { $project.agentRole } else { 'default' }
$roleDir   = ("$home/agentRoles/$agentRole") -replace '\\', '/'

if (-not (Test-Path $roleDir)) {
    throw "Agent role dir not found: $roleDir (has 'd' been run since the roles change?)"
}

$targetRepo         = $null
$targetRepoSentence = $null
if ($project -and $project.root) {
    $targetRepo         = $project.root
    $targetRepoSentence = "Your target repository for this session is at $($project.root). The launch directory is the agent-role dir (it carries your skills); treat $($project.root) as the repo you're working on."
}

# Context files, resolved to absolute paths (dedup key, so a coincidental overlap collapses
# instead of loading the same content twice):
#  - de/prat/prefs always load. This "prat ecosystem" cluster is tightly coupled enough that a
#    session rooted in any one of them routinely touches the others too, and Claude Code has no
#    way to load that reactively as it happens - so all three load unconditionally at launch.
#  - any other repo only contributes its own instructions file if its codebaseProfile entry
#    explicitly opts in via `trustAgentInstructions = $true`. The filename loaded is
#    "AGENTS.md" by default, or can be specified with `agentInstructionsFile` (relative to the repo root).
$contextFilePaths = [ordered]@{}
# Get-CodebaseLayers returns highest-to-lowest (de, prefs, prat) - the right order for merge
# precedence, but for reading order we want the reverse: foundational-to-specific.
$layers = @(Get-CodebaseLayers)
[array]::Reverse($layers)
foreach ($layer in $layers) {
    if ($layer.Name -in @('de', 'prat', 'prefs')) {
        $contextFilePaths["$($layer.Path)/AGENTS.md"] = $true
    }
}
if ($project -and $project.trustAgentInstructions -eq $true -and $targetRepo) {
    $instructionsFile = if ($project.agentInstructionsFile) { $project.agentInstructionsFile } else { "AGENTS.md" }
    $contextFilePaths["$targetRepo/$instructionsFile"] = $true
}

$agentsMdSnippets = @()
foreach ($path in $contextFilePaths.Keys) {
    if (Test-Path $path) {
        $agentsMdSnippets += "<!-- $path -->`n`n" + (Get-Content -Raw $path)
    }
}

$contextParts = @()
if ($targetRepoSentence) { $contextParts += $targetRepoSentence }
$contextParts += $agentsMdSnippets

$contextMessage = if ($contextParts.Count -gt 0) { $contextParts -join "`n`n" } else { $null }

$allRoles   = Get-AgentRoles
$repoSkills = if ($allRoles.ContainsKey($agentRole)) { $allRoles[$agentRole].repoSkills } else { $null }
$repoAgents = if ($allRoles.ContainsKey($agentRole)) { $allRoles[$agentRole].repoAgents } else { $null }

return @{ roleName = $agentRole; roleDir = $roleDir; targetRepo = $targetRepo; contextMessage = $contextMessage; repoSkills = $repoSkills; repoAgents = $repoAgents }
