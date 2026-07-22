#Requires -Version 5.1

BeforeAll {
    $logScript = Join-Path -Path $PSScriptRoot -ChildPath '..\..\src\WebService\OfflineJoinLogging.ps1'
    . (Resolve-Path -LiteralPath $logScript).Path

    $script:FixedUtc = [datetime]::new(2026, 7, 22, 10, 15, 30, [System.DateTimeKind]::Utc)
}

Describe 'ConvertTo-OdjAuditToken' {

    It 'Returns a dash for null or empty input' {
        ConvertTo-OdjAuditToken -Value $null | Should -Be '-'
        ConvertTo-OdjAuditToken -Value '' | Should -Be '-'
    }

    It 'Strips CR, LF and TAB to prevent log injection' {
        $out = ConvertTo-OdjAuditToken -Value "line1`r`nline2`ttab"
        $out | Should -Not -Match "[`r`n`t]"
        $out | Should -Be 'line1 line2 tab'
    }

    It 'Trims surrounding whitespace' {
        ConvertTo-OdjAuditToken -Value '  value  ' | Should -Be 'value'
    }
}

Describe 'Format-OdjAuditEvent' {

    It 'Emits an ISO-8601 UTC timestamp ending in Z' {
        $line = Format-OdjAuditEvent -EventName 'auth' -Outcome 'ok' -TimestampUtc $script:FixedUtc
        $line | Should -BeLike '2026-07-22T10:15:30*Z*'
    }

    It 'Includes the event name and outcome as key=value tokens' {
        $line = Format-OdjAuditEvent -EventName 'provision' -Outcome 'allow' -TimestampUtc $script:FixedUtc
        $line | Should -BeLike '*evt=provision*'
        $line | Should -BeLike '*outcome=allow*'
    }

    It 'Includes the reason only when provided' {
        $withReason = Format-OdjAuditEvent -EventName 'auth' -Outcome 'fail' -Reason 'invalid-api-key' -TimestampUtc $script:FixedUtc
        $withReason | Should -BeLike '*reason=invalid-api-key*'

        $noReason = Format-OdjAuditEvent -EventName 'auth' -Outcome 'ok' -TimestampUtc $script:FixedUtc
        $noReason | Should -Not -BeLike '*reason=*'
    }

    It 'Preserves the order of the supplied fields' {
        $fields = [ordered]@{ ip = '10.0.0.1'; client = 'svc'; name = 'RESA-WEB01' }
        $line = Format-OdjAuditEvent -EventName 'provision' -Outcome 'allow' -Field $fields -TimestampUtc $script:FixedUtc
        $line | Should -BeLike '*ip=10.0.0.1 client=svc name=RESA-WEB01*'
    }

    It 'Sanitizes field values so crafted input cannot forge a new line' {
        $fields = [ordered]@{ name = "RESA`r`nevt=fake outcome=allow" }
        $line = Format-OdjAuditEvent -EventName 'provision' -Outcome 'deny' -Field $fields -TimestampUtc $script:FixedUtc
        $line | Should -Not -Match "[`r`n]"
        $line | Should -BeLike '*name=RESA evt=fake outcome=allow*'
    }
}

Describe 'Get-OdjEventCategory' {

    It 'Maps authentication events to category 1' {
        Get-OdjEventCategory -EventName 'auth' | Should -Be 1
    }

    It 'Maps provisioning events (API and UI) to category 2' {
        Get-OdjEventCategory -EventName 'provision' | Should -Be 2
        Get-OdjEventCategory -EventName 'provision-ui' | Should -Be 2
    }

    It 'Maps service lifecycle events to category 3' {
        Get-OdjEventCategory -EventName 'service' | Should -Be 3
    }

    It 'Maps unknown events to category 0' {
        Get-OdjEventCategory -EventName 'something-else' | Should -Be 0
    }
}

Describe 'Write-OdjAuditEvent' {

    It 'Creates the parent directory and writes the line' {
        $path = Join-Path -Path $TestDrive -ChildPath 'sub\dir\audit.log'
        Write-OdjAuditEvent -Path $path -Line 'test-line-1'
        Test-Path -LiteralPath $path | Should -BeTrue
        (Get-Content -LiteralPath $path -Raw) | Should -BeLike '*test-line-1*'
    }

    It 'Appends subsequent lines' {
        $path = Join-Path -Path $TestDrive -ChildPath 'append.log'
        Write-OdjAuditEvent -Path $path -Line 'first'
        Write-OdjAuditEvent -Path $path -Line 'second'
        $lines = @(Get-Content -LiteralPath $path)
        $lines.Count | Should -Be 2
        $lines[0] | Should -Be 'first'
        $lines[1] | Should -Be 'second'
    }

    It 'Does not throw when the Event Log block is disabled' {
        $path = Join-Path -Path $TestDrive -ChildPath 'disabled.log'
        $eventLog = @{ Enabled = $false; LogName = 'Application'; Source = 'OfflineJoinService' }
        { Write-OdjAuditEvent -Path $path -Line 'no-eventlog' -EventLog $eventLog } | Should -Not -Throw
        (Get-Content -LiteralPath $path -Raw) | Should -BeLike '*no-eventlog*'
    }
}
