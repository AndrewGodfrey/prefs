param($installationTracker, [string[]] $Suppress = @())

# Compute the new contents of MarkText's preferences.json given its current contents
# ($null/empty if the file doesn't yet exist). Returns $null if no update is needed.
# Pre-creating the file with just our setting lets MarkText pick it up on first launch,
# avoiding the chicken-and-egg where settings only apply after MarkText has run once.
function Get-MarkTextPreferencesUpdate([string] $existingJson) {
    $targetLineWidth = '100%'
    if ([string]::IsNullOrWhiteSpace($existingJson)) {
        return ([ordered]@{ editorLineWidth = $targetLineWidth } | ConvertTo-Json -Depth 20)
    }
    $prefs = $existingJson | ConvertFrom-Json -Depth 20
    if ($prefs.editorLineWidth -eq $targetLineWidth) {
        return $null
    }
    $prefs.editorLineWidth = $targetLineWidth
    return ($prefs | ConvertTo-Json -Depth 20)
}

if ($MyInvocation.InvocationName -ne ".") {
    foreach ($packageId in @("pwsh", "wget", "df", "ditto", "sysinternals", "claude", "gh", "python", "nuget", "powertoys", "marktext")) {
        if ("pkg/$packageId" -notin $Suppress) {
            Install-PratPackage $installationTracker $packageId
        }
    }


    if ("pkg/marktext" -notin $Suppress) {
        $stage = $installationTracker.StartStage('marktext-settings')
        Install-InteractiveAlias $stage 'mt' "$home\AppData\Local\Programs\MarkText\MarkText.exe"
        $prefsFile = "$env:APPDATA/marktext/preferences.json"
        $existingContent = if (Test-Path $prefsFile) { Get-Content $prefsFile -Raw } else { $null }
        $newContent = Get-MarkTextPreferencesUpdate $existingContent
        if ($null -ne $newContent) {
            $prefsDir = Split-Path $prefsFile -Parent
            if (!(Test-Path $prefsDir)) { New-Item -ItemType Directory -Path $prefsDir | Out-Null }
            Set-Content $prefsFile -Value $newContent -Encoding utf8NoBOM
            Write-Host "Updated MarkText preferences (editorLineWidth=100%)"
        }
        $installationTracker.EndStage($stage)
    }

    if ("pkg/winmerge" -notin $Suppress) {
        # WinMerge: used for move-block detection when reviewing Claude-assisted reorganizations.
        # Beyond Compare is the fallback for harder cases.
        # TODO: Develop a tool for capturing registry changes made via UI preference dialogs,
        #       so that settings like the one below can be automated.
        Install-PratPackage $installationTracker "winmerge"
        $stage = $installationTracker.StartStage('winmerge-settings')
        $stage.EnsureManualStep("winmerge\movedBlockDetection", @"
Enable moved block detection (off by default):
WinMerge -> Edit -> Options -> Compare
Check "Enable moved block detection"
"@)
        $installationTracker.EndStage($stage)
        # TODO: WinMerge has some popups with questions - ignore EOL differences; auto-load content. Save my answers (yes and yes).
    }

    if ("pkg/pushoverNotification" -notin $Suppress) {
        # pushoverNotification: token path is environment-specific.
        $getPratTokensScript = Resolve-PratLibFile "lib/inst/Get-PratTokens.ps1"
        if ($null -ne $getPratTokensScript) {
            $tokenFile = & $getPratTokensScript "pushoverTokens"
            Install-PratPackage $installationTracker "pushoverNotification" $tokenFile
        }
    }
}