#Requires -Version 5.1

BeforeAll {
    $manifest = Join-Path -Path $PSScriptRoot -ChildPath '..\..\src\OfflineJoin\OfflineJoin.psd1'
    Import-Module -Name (Resolve-Path -LiteralPath $manifest).Path -Force
}

AfterAll {
    Remove-Module -Name OfflineJoin -Force -ErrorAction SilentlyContinue
}

Describe 'Test-OdjMachineName' {

    It 'Accepts valid NetBIOS name <Name>' -TestCases @(
        @{ Name = 'PC1' }
        @{ Name = 'RESA-WEB01' }
        @{ Name = 'a' }
        @{ Name = 'A1B2C3D4E5F6G12' } # 15 characters
        @{ Name = '0start' }
    ) {
        Test-OdjMachineName -MachineName $Name | Should -BeTrue
    }

    It 'Rejects invalid name <Name>' -TestCases @(
        @{ Name = '-leadinghyphen' }
        @{ Name = 'has space' }
        @{ Name = 'TOOLONGNAME12345' } # 16 characters
        @{ Name = 'under_score' }
        @{ Name = 'dot.name' }
        @{ Name = 'slash/name' }
        @{ Name = 'semicolon;rm' }
    ) {
        Test-OdjMachineName -MachineName $Name | Should -BeFalse
    }

    It 'Throws on an empty name (boundary validation)' {
        { Test-OdjMachineName -MachineName '' } | Should -Throw
    }
}
