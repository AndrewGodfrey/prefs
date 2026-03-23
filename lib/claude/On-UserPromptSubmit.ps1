# On-UserPromptSubmit.ps1
# UserPromptSubmit hook: records (claude PID → session_id, cwd) for Launch-Plan.ps1
# to use for process detection and session matching.
# NOTE: Do not emit to stdout — Claude Code interprets hook stdout as instructions.

function Get-ClaudePid {
    $id = $PID
    # Find the parent 'claude' process (the hook runs in a child or descendant process)
    for ($i = 0; $i -lt 6; $i++) {
        $row = Get-CimInstance Win32_Process -Filter "ProcessId = $id" -ErrorAction SilentlyContinue
        if (-not $row) { return $null }
        $parent = Get-Process -Id $row.ParentProcessId -ErrorAction SilentlyContinue
        if (-not $parent) { return $null }
        if ($parent.Name -eq 'claude') { return $parent.Id }
        $id = $parent.Id
    }
    return $null
}

function main($hookData) {
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

if ($MyInvocation.InvocationName -ne '.') {
    $hookData = ([Console]::In.ReadToEnd()) | ConvertFrom-Json
    main $hookData | Out-Null
}
