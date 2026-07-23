param($installationTracker)

$stage = $installationTracker.StartStage("contextTool")

Install-InteractiveAlias $stage 'pl' 'Launch-Plan'
Install-InteractiveAlias $stage 'cfn' 'Copy-FullNameToClipboard'
Install-Folder $stage "$home\prat\auto\context"
Install-Folder $stage "$home\prat\auto\context\running"

$installationTracker.EndStage($stage)
# OmitFromCoverageReport: pure orchestration, not worth the mocking cost
