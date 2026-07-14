# On-UserPromptSubmit.ps1
# UserPromptSubmit hook: records (harness process PID → session_id, cwd, planFile) for
# Launch-Plan.ps1. planFile comes from CL_PLAN_FILE, which the pl launcher sets for the whole
# session (fresh and resumed), so it is re-stamped on every prompt.
#
# Output: nothing (no additionalContext emitted).

function main($hookData, [string] $harnessName) {
    define_Proc
    Save-PidSessionRecord $hookData $harnessName
}

function Save-PidSessionRecord($hookData, [string] $harnessName, [string] $runningDir = "$home/prat/auto/context/running") {
    try {
        $sessionId = $hookData.session_id
        $cwd       = $hookData.cwd
        if (-not $sessionId -or -not $cwd) { return }

        $harnessPid = Get-HarnessPid $harnessName
        if (-not $harnessPid) { return }

        $null = New-Item -ItemType Directory -Path $runningDir -Force
        $data = [pscustomobject]@{session_id = $sessionId; cwd = $cwd}
        if ($env:CL_PLAN_FILE) { $data | Add-Member -NotePropertyName 'planFile' -NotePropertyValue $env:CL_PLAN_FILE }
        ConvertTo-Json -InputObject $data -Compress | Set-Content "$runningDir/pid_$harnessPid.txt" -Encoding UTF8
    } catch {
        # Silent — don't end the hook or block the turn, on failure to record the PID/session mapping.
    }
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
