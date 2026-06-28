BeforeDiscovery {
    . "$PSScriptRoot/On-UserPromptSubmit_prefs.ps1"
}

BeforeAll {
    . "$PSScriptRoot/On-UserPromptSubmit_prefs.ps1"
}

Describe "getIntentPlanFile" {
    It "returns null when intent file does not exist" {
        $result = getIntentPlanFile "C:/de" "TestDrive:\no-file.json"

        $result | Should -BeNull
    }

    It "returns null when cwd does not match intent" {
        $intentPath = "TestDrive:\intent-cwd-mismatch.json"
        '{"planFile":"C:/plans/foo.md","cwd":"C:/other"}' | Set-Content $intentPath

        $result = getIntentPlanFile "C:/de" (Get-Item $intentPath).FullName

        $result | Should -BeNull
        Test-Path $intentPath | Should -BeTrue    # not consumed
    }

    It "returns planFile and removes intent file when cwd matches" {
        $intentPath = "TestDrive:\intent-match.json"
        '{"planFile":"C:/plans/foo.md","cwd":"C:/de"}' | Set-Content $intentPath

        $result = getIntentPlanFile "C:/de" (Get-Item $intentPath).FullName

        $result            | Should -Be "C:/plans/foo.md"
        Test-Path $intentPath | Should -BeFalse    # consumed
    }

    It "normalizes backslash cwd from intent file" {
        $intentPath = "TestDrive:\intent-backslash.json"
        '{"planFile":"C:/plans/foo.md","cwd":"C:\\de"}' | Set-Content $intentPath

        $result = getIntentPlanFile "C:/de" (Get-Item $intentPath).FullName

        $result | Should -Be "C:/plans/foo.md"
    }

    It "normalizes backslash cwd argument" {
        $intentPath = "TestDrive:\intent-backslash-arg.json"
        '{"planFile":"C:/plans/foo.md","cwd":"C:/de"}' | Set-Content $intentPath

        $result = getIntentPlanFile 'C:\de' (Get-Item $intentPath).FullName

        $result | Should -Be "C:/plans/foo.md"
    }

    It "returns null when intent file is malformed JSON" {
        $intentPath = "TestDrive:\intent-bad-json.json"
        'not json' | Set-Content $intentPath

        $result = getIntentPlanFile "C:/de" (Get-Item $intentPath).FullName

        $result | Should -BeNull
    }
}

Describe "Update-CredentialsIfExpiring" {
    BeforeAll {
        $calls = [System.Collections.Generic.List[hashtable]]::new()

        function Invoke-RestMethod {
            param($Uri, $Method, $ContentType, $Body)
            $calls.Add(@{ Uri = $Uri; Body = ($Body | ConvertFrom-Json) })
            return [PSCustomObject]@{ access_token = 'new-access'; refresh_token = 'new-refresh'; expires_in = 3600 }
        }

        function Write-CredFile($path, $accessToken, $refreshToken, $expiresAtMs) {
            $oauth = [ordered]@{ accessToken = $accessToken; expiresAt = $expiresAtMs }
            if ($null -ne $refreshToken) { $oauth['refreshToken'] = $refreshToken }
            @{ claudeAiOauth = $oauth } | ConvertTo-Json -Depth 5 | Set-Content $path -Encoding UTF8
        }
    }

    BeforeEach {
        $calls.Clear()
        $testDir = "TestDrive:\creds-$([Guid]::NewGuid())"
        New-Item -ItemType Directory $testDir | Out-Null
        $base = ((Get-Item $testDir).FullName -replace '\\', '/').TrimEnd('/')
        $script:credsPath = "$base/.credentials.json"
        $script:logPath   = "$base/token_refresh.log"
    }

    Context "fast path — token valid with >10 min remaining" {
        It "makes no HTTP call" {
            $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            Write-CredFile $script:credsPath 'orig-access' 'orig-refresh' ($nowMs + 20 * 60 * 1000)

            Update-CredentialsIfExpiring -CredsPath $script:credsPath -LogPath $script:logPath

            $calls.Count | Should -Be 0
        }

        It "leaves the file unchanged" {
            $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            Write-CredFile $script:credsPath 'orig-access' 'orig-refresh' ($nowMs + 20 * 60 * 1000)
            $before = Get-Content $script:credsPath -Raw

            Update-CredentialsIfExpiring -CredsPath $script:credsPath -LogPath $script:logPath

            (Get-Content $script:credsPath -Raw) | Should -Be $before
        }
    }

    Context "token near expiry (<= 10 min remaining)" {
        BeforeEach {
            $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            Write-CredFile $script:credsPath 'orig-access' 'orig-refresh' ($nowMs + 5 * 60 * 1000)
        }

        It "calls the token endpoint" {
            Update-CredentialsIfExpiring -CredsPath $script:credsPath -LogPath $script:logPath -TokenEndpoint 'https://example.com/token'

            $calls.Count | Should -Be 1
            $calls[0].Uri | Should -Be 'https://example.com/token'
        }

        It "sends the existing refresh token and client_id in the request body" {
            Update-CredentialsIfExpiring -CredsPath $script:credsPath -LogPath $script:logPath -ClientId 'test-client'

            $calls[0].Body.refresh_token | Should -Be 'orig-refresh'
            $calls[0].Body.client_id     | Should -Be 'test-client'
            $calls[0].Body.grant_type    | Should -Be 'refresh_token'
        }

        It "writes the new access token" {
            Update-CredentialsIfExpiring -CredsPath $script:credsPath -LogPath $script:logPath

            $updated = (Get-Content $script:credsPath -Raw | ConvertFrom-Json).claudeAiOauth
            $updated.accessToken | Should -Be 'new-access'
        }

        It "writes the new refresh token" {
            Update-CredentialsIfExpiring -CredsPath $script:credsPath -LogPath $script:logPath

            $updated = (Get-Content $script:credsPath -Raw | ConvertFrom-Json).claudeAiOauth
            $updated.refreshToken | Should -Be 'new-refresh'
        }

        It "writes a future expiresAt (approximately now + expires_in)" {
            $before = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            Update-CredentialsIfExpiring -CredsPath $script:credsPath -LogPath $script:logPath
            $after = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

            $updated = (Get-Content $script:credsPath -Raw | ConvertFrom-Json).claudeAiOauth
            $updated.expiresAt | Should -BeGreaterThan $before
            $updated.expiresAt | Should -BeLessOrEqual ($after + 3600 * 1000)
        }
    }

    Context "token already expired" {
        It "refreshes" {
            $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            Write-CredFile $script:credsPath 'orig-access' 'orig-refresh' ($nowMs - 1000)

            Update-CredentialsIfExpiring -CredsPath $script:credsPath -LogPath $script:logPath

            $calls.Count | Should -Be 1
        }
    }

    Context "response has no new refresh_token" {
        It "preserves the original refresh token" {
            function Invoke-RestMethod {
                param($Uri, $Method, $ContentType, $Body)
                return [PSCustomObject]@{ access_token = 'new-access'; expires_in = 3600 }
            }
            $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            Write-CredFile $script:credsPath 'orig-access' 'orig-refresh' ($nowMs - 1000)

            Update-CredentialsIfExpiring -CredsPath $script:credsPath -LogPath $script:logPath

            $updated = (Get-Content $script:credsPath -Raw | ConvertFrom-Json).claudeAiOauth
            $updated.refreshToken | Should -Be 'orig-refresh'
        }
    }

    Context "credentials file missing" {
        It "does not throw and makes no HTTP call" {
            { Update-CredentialsIfExpiring -CredsPath 'C:/nonexistent/.credentials.json' -LogPath $script:logPath } | Should -Not -Throw

            $calls.Count | Should -Be 0
        }
    }

    Context "refreshToken missing from credentials" {
        It "makes no HTTP call" {
            $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            Write-CredFile $script:credsPath 'orig-access' $null ($nowMs - 1000)

            Update-CredentialsIfExpiring -CredsPath $script:credsPath -LogPath $script:logPath

            $calls.Count | Should -Be 0
        }
    }

    Context "HTTP call fails" {
        It "does not throw and leaves the file unchanged" {
            function Invoke-RestMethod { param($Uri, $Method, $ContentType, $Body); throw 'network error' }
            $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            Write-CredFile $script:credsPath 'orig-access' 'orig-refresh' ($nowMs - 1000)
            $before = Get-Content $script:credsPath -Raw

            { Update-CredentialsIfExpiring -CredsPath $script:credsPath -LogPath $script:logPath } | Should -Not -Throw

            (Get-Content $script:credsPath -Raw) | Should -Be $before
        }
    }
}

Describe "Get-HarnessPid" {
    Context "harness process not running" {
        BeforeAll {
            function Get-Process { param($Name, $Id, $ErrorAction) $null }
        }

        It "returns null" {
            Get-HarnessPid 'claude' | Should -BeNull
        }
    }

    Context "parent process is the harness" {
        BeforeAll {
            $parentPid = 1234
            function Get-Process {
                param($Name, $Id, [string] $ErrorAction)
                if ($Name -eq 'claude') { return [pscustomobject]@{ Name = 'claude'; Id = 99 } }
                if ($Id -eq $parentPid)  { return [pscustomobject]@{ Name = 'claude'; Id = $parentPid } }
                return [pscustomobject]@{ Name = 'pwsh'; Id = $Id }
            }
            function getParentProcess { param($childPid) $parentPid }
        }

        It "returns the parent PID" {
            Get-HarnessPid 'claude' | Should -Be $parentPid
        }

        It "returns a single integer, not an array" {
            $result = Get-HarnessPid 'claude'
            @($result).Count | Should -Be 1
        }
    }

    Context "harness is two levels up" {
        BeforeAll {
            $grandparentPid = 5678
            $parentPid      = 9999
            function Get-Process {
                param($Name, $Id, [string] $ErrorAction)
                if ($Name -eq 'claude') { return [pscustomobject]@{ Name = 'claude'; Id = 99 } }
                if ($Id -eq $grandparentPid) { return [pscustomobject]@{ Name = 'claude'; Id = $grandparentPid } }
                return [pscustomobject]@{ Name = 'pwsh'; Id = $Id }
            }
            function getParentProcess {
                param($childPid)
                if ($childPid -eq $parentPid) { return $grandparentPid }
                return $parentPid
            }
        }

        It "returns the grandparent PID" {
            Get-HarnessPid 'claude' | Should -Be $grandparentPid
        }
    }

    Context "no harness ancestor within 6 levels" {
        BeforeAll {
            function Get-Process {
                param($Name, $Id, [string] $ErrorAction)
                if ($Name -eq 'claude') { return [pscustomobject]@{ Name = 'claude'; Id = 99 } }
                return [pscustomobject]@{ Name = 'pwsh'; Id = $Id }
            }
            function getParentProcess { param($childPid) $childPid + 1 }
        }

        It "returns null" {
            Get-HarnessPid 'claude' | Should -BeNull
        }
    }
}
