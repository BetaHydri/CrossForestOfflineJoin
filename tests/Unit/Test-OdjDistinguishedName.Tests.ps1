#Requires -Version 5.1

BeforeAll {
    $manifest = Join-Path -Path $PSScriptRoot -ChildPath '..\..\src\OfflineJoin\OfflineJoin.psd1'
    Import-Module -Name (Resolve-Path -LiteralPath $manifest).Path -Force
}

AfterAll {
    Remove-Module -Name OfflineJoin -Force -ErrorAction SilentlyContinue
}

Describe 'Test-OdjDistinguishedName' {

    It 'Accepts a plausible DN <Dn>' -TestCases @(
        @{ Dn = 'OU=Server,DC=res-a,DC=example,DC=com' }
        @{ Dn = 'CN=Computers,DC=example,DC=com' }
        @{ Dn = 'OU=Tier1,OU=Server,DC=res-b,DC=example,DC=com' }
    ) {
        Test-OdjDistinguishedName -DistinguishedName $Dn | Should -BeTrue
    }

    It 'Rejects a DN without a DC component' {
        Test-OdjDistinguishedName -DistinguishedName 'OU=Server' | Should -BeFalse
    }

    It 'Rejects a DN that does not start with OU= or CN=' {
        Test-OdjDistinguishedName -DistinguishedName 'DC=example,DC=com' | Should -BeFalse
    }

    It 'Rejects a DN containing injection character <Dn>' -TestCases @(
        @{ Dn = 'OU=x,DC=y"' }
        @{ Dn = 'OU=x,DC=y|calc' }
        @{ Dn = 'OU=x,DC=y&whoami' }
        @{ Dn = 'OU=x,DC=y;drop' }
        @{ Dn = "OU=x,DC=y`ncmd" }
    ) {
        Test-OdjDistinguishedName -DistinguishedName $Dn | Should -BeFalse
    }
}
