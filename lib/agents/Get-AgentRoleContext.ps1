param([string] $cwd)

$project   = Get-PratProject $cwd
$agentRole = if ($project -and $project.agentRole) { $project.agentRole } else { 'default' }
$roleDir   = "$home/agentRoles/$agentRole"

if (-not (Test-Path $roleDir)) {
    throw "Agent role dir not found: $roleDir (has 'd' been run since the roles change?)"
}

$targetRepo     = $null
$contextMessage = $null
if ($project -and $project.root) {
    $targetRepo     = $project.root
    $contextMessage = "Your target repository for this session is at $($project.root). The launch directory is the agent-role dir (it carries your skills); treat $($project.root) as the repo you're working on."
}

return @{ roleDir = $roleDir; targetRepo = $targetRepo; contextMessage = $contextMessage }
