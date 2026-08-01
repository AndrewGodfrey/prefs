# .SYNOPSIS
# Add 'prefs' to Prat's codebase layer list.

param(
    # Override for testing; production callers rely on the default.
    [string]$ScriptRoot = $PSScriptRoot
)

$thisEnv = @(@{
    Name = 'prefs'
    Path = Split-Path -Parent $ScriptRoot
})

$siblingScript = "$(Split-Path -Parent (Split-Path -Parent $ScriptRoot))/prat/pathbin/Get-CodebaseLayers.ps1"
if (-not (Test-Path $siblingScript)) {
    throw "Sibling layer script not found: $siblingScript"
}

return $thisEnv + @(& $siblingScript)
