# .SYNOPSIS
# Add 'prefs' to Prat's codebase layer list.

$thisEnv = @(@{
    Name = 'prefs'
    Path = Split-Path -Parent $PSScriptRoot
})

return $thisEnv + @(&$home/prat/pathbin/Get-CodebaseLayers.ps1)
