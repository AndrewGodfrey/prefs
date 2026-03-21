# For consumption by PratBase (Get-PratProject, Find-ProjectShortcut etc.)
@{
    "." = @{
        repos = @{
            prefs = @{
                root   = $PSScriptRoot
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
        }
    }
}
