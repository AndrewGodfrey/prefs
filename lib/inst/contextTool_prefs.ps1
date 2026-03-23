param($installationTracker)

$stage = $installationTracker.StartStage("contextTool")

Install-InteractiveAlias $stage 'pl' 'Launch-Plan'
Install-Folder $stage "$home\prat\auto\context"
Install-Folder $stage "$home\prat\auto\context\running"

$installationTracker.EndStage($stage)
