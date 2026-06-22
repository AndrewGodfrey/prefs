param(
    [string]      $Harness,
    [scriptblock] $LaunchHook,
    [string]      $GetAgentRoleContextScript = "$PSScriptRoot/Get-AgentRoleContext.ps1"
)

$ctx = & $GetAgentRoleContextScript -cwd $PWD

$resumeSid = $null
for ($i = 0; $i -lt $ARGS.Count - 1; $i++) {
    if ($ARGS[$i] -eq '--resume') { $resumeSid = $ARGS[$i + 1]; break }
}

$ctxArgs = @()
if ($ctx.targetRepo) {
    $ctxArgs = @('--add-dir', $ctx.targetRepo)
}

Push-Location $ctx.roleDir
try {
    switch ($Harness) {
        'claude' {
            $claudeArgs = $ctxArgs
            if ($ctx.contextMessage) {
                $claudeArgs = $claudeArgs + @('--append-system-prompt', $ctx.contextMessage)
            }
            & $LaunchHook $resumeSid ($claudeArgs + $ARGS)
        }
        'copilot' { & $LaunchHook $resumeSid ($ctxArgs + $ARGS) }
        default   { throw "Unknown harness: $Harness" }
    }
} finally {
    Pop-Location
}
