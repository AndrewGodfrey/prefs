# On-UserPromptSubmit.ps1
# UserPromptSubmit hook:
#   1. Records (claude PID → session_id, cwd) for Launch-Plan.ps1
#   2. Emits git state diff as additionalContext if git state changed since last turn
#
# Output: additionalContext JSON on stdout when git state changed; nothing otherwise.

. "$home/prat/lib/Get-GitCwdState.ps1"

function main($hookData) {
    define_Proc
    Save-PidSessionRecord $hookData
    Emit-GitStateDiff $hookData
}

function Save-PidSessionRecord($hookData) {
    $sessionId = $hookData.session_id
    $cwd       = $hookData.cwd
    if (-not $sessionId -or -not $cwd) { return }

    $claudePid = Get-ClaudePid
    if (-not $claudePid) { return }

    $runningDir = "$home/prat/auto/context/running"
    $intentPath = "$runningDir/launch_intent.json"
    $planFile   = getIntentPlanFile $cwd $intentPath

    $null = New-Item -ItemType Directory -Path $runningDir -Force
    $data = [pscustomobject]@{session_id = $sessionId; cwd = $cwd}
    if ($planFile) { $data | Add-Member -NotePropertyName 'planFile' -NotePropertyValue $planFile }
    ConvertTo-Json -InputObject $data -Compress | Set-Content "$runningDir/pid_$claudePid.txt" -Encoding UTF8
}

function Emit-GitStateDiff($hookData, $snapshotDir = "$home/prat/auto/context/gitStateSnapshot") {
    $sessionId = $hookData.session_id
    $cwd       = $hookData.cwd
    if (-not $sessionId -or -not $cwd) { return }

    $snapFile = Get-SnapshotPath $snapshotDir $sessionId $cwd
    if (-not (Test-Path $snapFile)) { return }

    $oldState = Get-Content $snapFile -Raw | ConvertFrom-Json -AsHashtable
    $newState = Get-GitCwdState $cwd
    if ($null -eq $newState) { return }

    # Update snapshot before comparing so next prompt sees fresh baseline
    $null = New-Item -ItemType Directory -Path $snapshotDir -Force
    $newState | ConvertTo-Json -Depth 5 | Set-Content $snapFile -Encoding UTF8

    $showRepoNames = $newState.Keys.Count -gt 1
    $diffs = [ordered]@{}
    foreach ($repoPath in $newState.Keys) {
        if (-not $oldState.ContainsKey($repoPath)) { continue }
        $diff = Get-RepoDiff $oldState[$repoPath] $newState[$repoPath]
        if ($null -ne $diff) { $diffs[$repoPath] = $diff }
    }
    if ($diffs.Count -eq 0) { return }

    @{additionalContext = (Format-GitStateMessage $diffs $showRepoNames)} | ConvertTo-Json -Compress
}

function Get-RepoDiff($old, $new) {
    $diff = @{}

    if ($old.branch -ne $new.branch) {
        $diff['branchOld'] = $old.branch
        $diff['branchNew'] = $new.branch
    }
    if ($old.log -ne $new.log -or $diff.ContainsKey('branchOld')) {
        $diff['logNew'] = $new.log
    }
    if ($old.status -ne $new.status) {
        $diff['statusNew'] = $new.status
    }
    $oldH = if ($old.uncommittedHashes) { $old.uncommittedHashes } else { @{} }
    $newH = if ($new.uncommittedHashes) { $new.uncommittedHashes } else { @{} }
    if (-not (Compare-HashtablesEqual $oldH $newH) -and -not $diff.ContainsKey('statusNew')) {
        $diff['uncommittedChanged'] = $true
    }

    if ($diff.Count -gt 0) { return $diff }
}

function Compare-HashtablesEqual($a, $b) {
    if ($a.Count -ne $b.Count) { return $false }
    foreach ($key in $a.Keys) {
        if (-not $b.ContainsKey($key) -or $a[$key] -ne $b[$key]) { return $false }
    }
    return $true
}

function Format-GitStateMessage($diffs, [bool]$showRepoNames) {
    $lines = @('[git state changed since last turn]')

    foreach ($repoPath in $diffs.Keys) {
        $diff = $diffs[$repoPath]

        if ($showRepoNames) {
            $lines += ''
            $lines += "[$(Split-Path $repoPath -Leaf)]"
        }
        if ($diff.ContainsKey('branchOld')) {
            $lines += "Branch: $($diff['branchOld']) → $($diff['branchNew'])"
        }
        if ($diff.ContainsKey('logNew') -and $diff['logNew']) {
            $lines += 'Commits:'
            foreach ($line in ($diff['logNew'] -split "`n")) {
                if ($line) { $lines += "  $line" }
            }
        }
        if ($diff.ContainsKey('statusNew') -and $diff['statusNew']) {
            $lines += 'Status:'
            foreach ($line in ($diff['statusNew'] -split "`n")) {
                if ($line) { $lines += "  $line" }
            }
        }
        if ($diff['uncommittedChanged']) {
            $lines += 'Uncommitted file content changed'
        }
    }

    return $lines -join "`n"
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

function Get-ClaudePid {
    $id = $PID
    # Find the parent 'claude' process (the hook runs in a child or descendant process)
    for ($i = 0; $i -lt 6; $i++) {
        $parentPid = getParentProcess $id
        if ($parentPid -eq 0) { return $null }
        $parent = Get-Process -Id $parentPid -ErrorAction SilentlyContinue

        if ($null -eq $parent) { return $null }
        if ($parent.Name -eq 'claude') { return $parent.Id }
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
    $contextJson = main $hookData
    if ($contextJson) { Write-Output $contextJson }
}
