# .SYNOPSIS
# Add 'prefs' to Prat's dev environment list.

$thisEnv = @(@{
    Name = 'prefs'
    Path = Split-Path -Parent $PSScriptRoot
})

return $thisEnv + @(&$home/prat/pathbin/Get-DevEnvironments.ps1)
