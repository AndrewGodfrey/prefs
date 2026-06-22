param(
    [string]      $Harness,
    [scriptblock] $LaunchHook,
    [hashtable]   $Context
)

$resumeSid = $null
for ($i = 0; $i -lt $ARGS.Count - 1; $i++) {
    if ($ARGS[$i] -eq '--resume') { $resumeSid = $ARGS[$i + 1]; break }
}

$ctxArgs = @()
if ($Context.targetRepo) {
    $ctxArgs = @('--add-dir', $Context.targetRepo)
}

Push-Location $Context.roleDir
try {
    switch ($Harness) {
        'claude' {
            $claudeArgs = $ctxArgs
            if ($Context.contextMessage) {
                $claudeArgs = $claudeArgs + @('--append-system-prompt', $Context.contextMessage)
            }
            & $LaunchHook $resumeSid ($claudeArgs + $ARGS)
        }
        'copilot' { & $LaunchHook $resumeSid ($ctxArgs + $ARGS) }
        default   { throw "Unknown harness: $Harness" }
    }
} finally {
    Pop-Location
}
