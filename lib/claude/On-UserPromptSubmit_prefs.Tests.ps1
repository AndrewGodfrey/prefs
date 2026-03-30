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
