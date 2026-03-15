# For consumption by PratBase (Get-PratProject, Find-ProjectShortcut etc.)
@{
    "." = @{
        repos = @{
            prefs = @{
                root   = $PSScriptRoot
                deploy = {
                    param($project, [hashtable]$CommandParameters = @{})
                    $force = [bool]($CommandParameters['Force'])
                    pwsh -File "$($project.root)/lib/deploy_prefs.ps1" -Force:$force
                }
            }
        }
        shortcuts = @{
            pinst = "lib/inst"
        }
    }
}
