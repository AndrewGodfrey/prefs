# On-UserPromptSubmit.ps1
# UserPromptSubmit hook: records (harness process PID → session_id, cwd) for Launch-Plan.ps1.
#
# Output: nothing (no additionalContext emitted).

function main($hookData, [string] $harnessName) {
    define_Proc
    Save-PidSessionRecord $hookData $harnessName
    Update-CredentialsIfExpiring
}

# This is to work around a bug in Claude Code, where you get an unnecessary login prompt in a long-running session.
function Update-CredentialsIfExpiring(
    [string] $CredsPath     = "$home/.claude/.credentials.json",
    [string] $TokenEndpoint = 'https://platform.claude.com/v1/oauth/token',
    [string] $ClientId      = '9d1c250a-e61b-44d9-88ed-5944d1962f5e'
) {
    if (-not (Test-Path $CredsPath)) { return }

    $creds = Get-Content $CredsPath -Raw | ConvertFrom-Json
    $oauth = $creds.claudeAiOauth
    if (-not $oauth -or -not $oauth.refreshToken) { return }
    if (-not $oauth.expiresAt) { return }

    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if ([long]$oauth.expiresAt -gt ($nowMs + 10 * 60 * 1000)) { return }

    $body = [ordered]@{
        grant_type    = 'refresh_token'
        refresh_token = $oauth.refreshToken
        client_id     = $ClientId
    } | ConvertTo-Json -Compress

    try {
        $r = Invoke-RestMethod -Uri $TokenEndpoint -Method Post -ContentType 'application/json' -Body $body
        $creds.claudeAiOauth.accessToken = $r.access_token
        $creds.claudeAiOauth.expiresAt   = $nowMs + [long]($r.expires_in * 1000)
        if ($r.PSObject.Properties['refresh_token'] -and $r.refresh_token) {
            $creds.claudeAiOauth.refreshToken = $r.refresh_token
        }
        $creds | ConvertTo-Json -Depth 10 | Set-Content $CredsPath -Encoding UTF8
    } catch {
        # Silent — don't end the hook or block the turn, on failure to refresh credentials
    }
}

function Save-PidSessionRecord($hookData, [string] $harnessName) {
    try {
        $sessionId = $hookData.session_id
        $cwd       = $hookData.cwd
        if (-not $sessionId -or -not $cwd) { return }

        $harnessPid = Get-HarnessPid $harnessName
        if (-not $harnessPid) { return }

        $runningDir = "$home/prat/auto/context/running"
        $intentPath = "$runningDir/launch_intent.json"
        $planFile   = getIntentPlanFile $cwd $intentPath

        $null = New-Item -ItemType Directory -Path $runningDir -Force
        $data = [pscustomobject]@{session_id = $sessionId; cwd = $cwd}
        if ($planFile) { $data | Add-Member -NotePropertyName 'planFile' -NotePropertyValue $planFile }
        ConvertTo-Json -InputObject $data -Compress | Set-Content "$runningDir/pid_$harnessPid.txt" -Encoding UTF8
    } catch {
        # Silent — don't end the hook or block the turn, on failure to record the PID/session mapping.
    }
}

function normalizePath([string] $p) { $p -replace '\\', '/' }

function getIntentPlanFile([string] $cwd, [string] $intentPath) {
    if (-not (Test-Path $intentPath)) { return $null }
    try   { $intent = Get-Content $intentPath -Raw | ConvertFrom-Json }
    catch { return $null }
    if (-not $intent -or -not $intent.planFile -or -not $intent.cwd) { return $null }
    if ((normalizePath $intent.cwd) -ne (normalizePath $cwd)) { return $null }
    Remove-Item $intentPath -Force -ErrorAction SilentlyContinue
    return $intent.planFile
}

function Get-HarnessPid([string] $harnessName) {
    if (-not (Get-Process -Name $harnessName -ErrorAction SilentlyContinue)) { return $null }
    $id = $PID
    # Find the parent harness process (the hook runs in a child or descendant process)
    for ($i = 0; $i -lt 6; $i++) {
        $parentPid = getParentProcess $id
        if ($parentPid -eq 0) { return $null }
        $parent = Get-Process -Id $parentPid -ErrorAction SilentlyContinue

        if ($null -eq $parent) { return $null }
        if ($parent.Name -eq $harnessName) { return $parent.Id }
        $id = $parent.Id
    }
    return $null
}

function define_Proc {
    if ($null -eq ('Proc' -as [type])) {
        Add-Type @"
        using System;
        using System.Runtime.InteropServices;

        public class Proc {
            [DllImport("ntdll.dll")]
            public static extern int NtQueryInformationProcess(
                IntPtr processHandle,
                int processInformationClass,
                ref PROCESS_BASIC_INFORMATION processInformation,
                int processInformationLength,
                out int returnLength);

            public struct PROCESS_BASIC_INFORMATION {
                public IntPtr Reserved1;
                public IntPtr PebBaseAddress;
                public IntPtr Reserved2_0;
                public IntPtr Reserved2_1;
                public IntPtr UniqueProcessId;
                public IntPtr InheritedFromUniqueProcessId;
            }
        }
"@
    }
}

function getParentProcess($childPid) {
    $pbi = New-Object Proc+PROCESS_BASIC_INFORMATION
    [Proc]::NtQueryInformationProcess(
        (Get-Process -Id $childPid).Handle,
        0,
        [ref]$pbi,
        [System.Runtime.InteropServices.Marshal]::SizeOf($pbi),
        [ref]0
    ) | Out-Null

    $parentPid = [long] $pbi.InheritedFromUniqueProcessId
    $parentPid
}

if ($MyInvocation.InvocationName -ne '.') {
    $hookData = ([Console]::In.ReadToEnd()) | ConvertFrom-Json
    main $hookData 'claude' | Out-Null
}
