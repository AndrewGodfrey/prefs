# For consumption by PratBase (Get-PratProject, Find-ProjectShortcut etc.)
@{
    "." = @{
        repos = @{
            prefs = @{
                root   = $PSScriptRoot
                trustAgentInstructions = $true
                test   = "$home/prat/lib/Test-PratLayer.ps1"
                deploy = {
                    param($project, [hashtable]$CommandParameters = @{})
                    $force = [bool]($CommandParameters['Force'])
                    $script = Resolve-PratLibFile "lib/deployEnv.ps1"
                    pwsh -File $script -Force:$force
                }
            }
        }
        shortcuts = @{
            pinst = "lib/inst"
            prag  = "lib/agents"
        }
    }
}
# OmitFromCoverageReport: a unit test would just restate it - static repo metadata
