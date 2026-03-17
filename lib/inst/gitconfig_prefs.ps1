param($installationTracker, [hashtable] $Config = @{})

function Get-GitConfigHeaders([string] $content) {
    if (-not $content) { return @() }

    ($content -replace "`r`n", "`n") -split "`n" |
        Where-Object { $_ -match '^\[' } |
        ForEach-Object { $_.Trim() }
}

function Get-ExternalGitConfigSections([string] $content, [string[]] $ownedHeaders) {
    if (-not $content) { return "" }

    $lines = ($content -replace "`r`n", "`n") -split "`n"

    $result = [System.Text.StringBuilder]::new()
    $inExternalSection = $false

    foreach ($line in $lines) {
        if ($line -match '^\[') {
            $header = $line.Trim()
            $inExternalSection = -not ($ownedHeaders -icontains $header)
        }
        if ($inExternalSection) {
            [void]$result.AppendLine($line)
        }
    }

    return $result.ToString().TrimEnd()
}

if ($MyInvocation.InvocationName -ne ".") {
    $stage = $installationTracker.StartStage('gitconfig')

    $userEmail     = $Config['userEmail']
    $userName      = $Config['userName']
    $extraSafeDirs = $Config['gitSafeDirectories'] ?? @()

    $text = ""

    if ($userEmail -or $userName) {
        $text += "[user]`n"
        if ($userName)  { $text += "    name = $userName`n" }
        if ($userEmail) { $text += "    email = $userEmail`n" }
    }

    $text += @"
[color "branch"]
	current = yellow bold
	local = green bold
	remote = cyan bold
[color "diff"]
	meta = yellow bold
	frag = magenta bold
	old = red bold
	new = green bold
	whitespace = red reverse
[color "status"]
	added = green bold
	changed = yellow bold
	untracked = red bold
"@ + "`n"

    $safeDirs = (@("$home/prefs", "$home/prat") + $extraSafeDirs) | ForEach-Object { $_ -replace '\\', '/' }
    $text += "[safe]`n"
    $text += ($safeDirs | ForEach-Object { "    directory = $_`n" }) -join ""

    $extraGitConfig = $Config['extraGitConfig']
    if ($extraGitConfig) {
        $text += "`n$extraGitConfig"
    }

    $existingContent = if (Test-Path "$home\.gitconfig") { Get-Content "$home\.gitconfig" -Raw } else { "" }
    $externalSections = Get-ExternalGitConfigSections $existingContent (Get-GitConfigHeaders $text)
    if ($externalSections) {
        $text += "`n$externalSections"
    }

    Install-TextToFile $stage "$home\.gitconfig" $text -Backup

    $installationTracker.EndStage($stage)
}
