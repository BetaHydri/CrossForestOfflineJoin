#Requires -Version 5.1

BeforeAll {
    $manifest = Join-Path -Path $PSScriptRoot -ChildPath '..\..\src\OfflineJoin\OfflineJoin.psd1'
    Import-Module -Name (Resolve-Path -LiteralPath $manifest).Path -Force

    $script:ValidOU = 'OU=Server,DC=res-a,DC=example,DC=com'
    $script:ValidName = 'RESA-WEB01'
    $script:Domain = 'res-a.example.com'
}

AfterAll {
    Remove-Module -Name OfflineJoin -Force -ErrorAction SilentlyContinue
}

Describe 'New-OfflineDomainJoinBlob' {

    It 'Rejects an invalid computer name via parameter validation' {
        {
            New-OfflineDomainJoinBlob -Domain $script:Domain -MachineName 'bad name' -MachineOU $script:ValidOU -WhatIf
        } | Should -Throw
    }

    It 'Rejects an invalid OU DistinguishedName via parameter validation' {
        {
            New-OfflineDomainJoinBlob -Domain $script:Domain -MachineName $script:ValidName -MachineOU 'not-a-dn' -WhatIf
        } | Should -Throw
    }

    It 'Throws when djoin.exe is not present' {
        Mock -CommandName Test-Path -ModuleName OfflineJoin -MockWith { $false } -ParameterFilter {
            $LiteralPath -match 'djoin\.exe$'
        }

        {
            New-OfflineDomainJoinBlob -Domain $script:Domain -MachineName $script:ValidName -MachineOU $script:ValidOU
        } | Should -Throw '*djoin.exe was not found*'
    }

    It 'Does nothing and returns nothing under -WhatIf' {
        $result = New-OfflineDomainJoinBlob -Domain $script:Domain -MachineName $script:ValidName -MachineOU $script:ValidOU -WhatIf
        $result | Should -BeNullOrEmpty
    }
}
