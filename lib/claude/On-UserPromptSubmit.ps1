# On-UserPromptSubmit.ps1
# UserPromptSubmit hook: records (claude PID → session_id, cwd) for Launch-Plan.ps1
# to use for process detection and session matching.
# NOTE: Do not emit to stdout — Claude Code interprets hook stdout as instructions.

function main($hookData) {
    define_Proc

    $sessionId = $hookData.session_id
    $cwd       = $hookData.cwd
    if (-not $sessionId -or -not $cwd) { return }

    $claudePid = Get-ClaudePid
    if (-not $claudePid) { return }

    $runningDir = "$home/prat/auto/context/running"
    $null = New-Item -ItemType Directory -Path $runningDir -Force
    $data = [pscustomobject]@{session_id = $sessionId; cwd = $cwd} | ConvertTo-Json -Compress
    Set-Content "$runningDir/pid_$claudePid.txt" $data -Encoding UTF8
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
    main $hookData | Out-Null
}
