param($installationTracker, [hashtable] $Config = @{})

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

Install-TextToFile $stage "$home\.gitconfig" $text -Backup

$installationTracker.EndStage($stage)
