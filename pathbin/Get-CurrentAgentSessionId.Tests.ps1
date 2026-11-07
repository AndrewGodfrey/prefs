BeforeAll {
    Import-Module "$home/prat/lib/PratBase/PratBase.psd1" -Force
    . "$PSScriptRoot/../lib/agents/agentHarnesses.ps1"
    # Every harness's variable, so the session this test itself runs in can't leak into it.
    $script:sidVars = @(Get-AgentHarnessDescriptors -All | Where-Object { $_.sessionIdEnvVar } | ForEach-Object { $_.sessionIdEnvVar })
}

Describe "Get-CurrentAgentSessionId" {
    BeforeEach {
        $script:saved = Save-Env $sidVars
        foreach ($v in $sidVars) { Remove-Item "Env:\$v" -ErrorAction SilentlyContinue }
    }
    AfterEach { Restore-Env $script:saved }

    It "returns the session id a built-in harness exposes to agent shells" -TestCases @(
        @{ Var = 'CLAUDE_CODE_SESSION_ID' }
        @{ Var = 'COPILOT_AGENT_SESSION_ID' }
    ) {
        param($Var)
        Set-Item "Env:\$Var" 'sess-123'

        & "$PSScriptRoot/Get-CurrentAgentSessionId.ps1" | Should -Be 'sess-123'
    }

    It "returns nothing outside an agent session" {
        & "$PSScriptRoot/Get-CurrentAgentSessionId.ps1" | Should -BeNullOrEmpty
    }
}
