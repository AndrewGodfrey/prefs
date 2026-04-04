param($installationTracker)

$stage = $installationTracker.StartStage("contextTool")

Install-InteractiveAlias $stage 'pl' 'Launch-Plan'
Install-InteractiveAlias $stage 'gfn' 'Get-FullName'
Install-Folder $stage "$home\prat\auto\context"
Install-Folder $stage "$home\prat\auto\context\running"

$installationTracker.EndStage($stage)
